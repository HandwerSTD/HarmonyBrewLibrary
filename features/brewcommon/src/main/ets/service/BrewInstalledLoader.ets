/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { Logger, PreferenceManager } from '@ohos/common';
import { SHELL_ERR_TIMEOUT, ShellUtils } from '@ohos/pcnative';
import type { ShellResult } from '@ohos/pcnative';
import { BrewKind } from '../model/BrewModels';
import type { BrewInstalledPackage } from '../model/BrewModels';
import {
  BREW_INSTALLED_FRESH_MS,
  BREW_INSTALLED_SNAPSHOT_KEY,
  BREW_INSTALLED_SNAPSHOT_VERSION,
  BREW_INSTALLED_TIMEOUT_MS,
} from '../constant/BrewConstants';
import { BrewInstalledParser } from '../util/BrewInstalledParser';
import { BrewCli } from './BrewCli';
// 与 BrewCommandRunner 互相 import 是有意的：读取要看「现在有没有写命令在执行」（spec §6.2 规则 5），
// 写命令结束要回调本类的 invalidate()（spec §5.3 第 5 点）。两侧都只在方法体内引用对方，不在顶层求值。
import { BrewCommandRunner } from './BrewCommandRunner';

const TAG: string = '[BrewInstalled]';

/**
 * 本机包读取失败的分类。
 *
 * 每一类对应一个可执行的下一步动作，所以不合并成一个「失败」：
 * `not-found` 与 `shell-unavailable` 要换环境，`timeout` 要放宽预算，
 * `bad-output` / `bad-shape` 是上游输出形状变了，`command-failed` 要看 stderr。
 */
export enum BrewInstalledFailure {
  NOT_FOUND = 'brew-not-found',
  SHELL_UNAVAILABLE = 'shell-unavailable',
  TIMEOUT = 'timeout',
  COMMAND_FAILED = 'command-failed',
  BAD_OUTPUT = 'bad-output',
  BAD_SHAPE = 'bad-shape',
}

/** 三个集合。口径与 `MinePackageSets` 一致，构造在 `buildSets()` 里一次做完 */
export class BrewInstalledSets {
  /** 全部已安装（formula 与 cask 混在一起），按名称排序 */
  public installed: BrewInstalledPackage[] = [];
  /** 有新版本可升级，按名称排序 */
  public outdated: BrewInstalledPackage[] = [];
  /** 版本已是最新，按 installedAt 倒序 */
  public updated: BrewInstalledPackage[] = [];
}

/** 一次读取的结果。失败时 `sets` 为空、`reason` 有值 */
export class BrewInstalledOutcome {
  public sets: BrewInstalledSets = new BrewInstalledSets();
  /** 空串表示成功 */
  public reason: string = '';
  public detail: string = '';
  public tookMs: number = 0;
  /** 原始输出的长度，用于判断「命令到底有没有吐东西」 */
  public stdoutBytes: number = 0;

  public ok(): boolean {
    return this.reason.length === 0;
  }
}

/**
 * 一份可用快照：三个集合加上读取时刻。
 *
 * `sets` 由 `installed` 派生（`buildSets()`），所以内存与磁盘存的是同一份事实，
 * 不存在「盘上的 outdated 是旧的、内存里是新的」这种不一致。
 */
export class BrewInstalledSnapshot {
  public sets: BrewInstalledSets;
  /** 这次成功读取的时刻（epoch ms），新鲜窗口与日志里的 `age` 都用它 */
  public readAt: number;

  constructor(sets: BrewInstalledSets, readAt: number) {
    this.sets = sets;
    this.readAt = readAt;
  }
}

/**
 * 盘上快照的形状。字段一律按可能缺失处理：盘上数据是被本应用之外的因素改过的。
 *
 * 只存 `installed` 一个集合：`outdated` 与 `updated` 读时用 `buildSets()` 派生，
 * 两个派生集合各有自己的排序口径，多存一份迟早会漂。
 */
interface BrewInstalledSnapshotDoc {
  version?: number;
  readAt?: number;
  packages?: BrewInstalledPackage[];
}

/**
 * 本机包读取层。
 *
 * 取数方式是一条命令：`<brew> info --json=v2 --installed`，命令行的拼装在 `BrewCli`。
 * 命令与输出形状的依据见 `docs/superpowers/specs/2026-10-04-brew-installed-packages-spec.md` §2。
 * 这一条命令同时返回已安装的 formula 与 cask（`cmd/info.rb` 的 `print_json` 在 `--installed`
 * 下产出 `{"formulae": [...], "casks": [...]}`），两个数组都进模型与三个集合。
 *
 * 快照：内存一份 + 盘上一份（`brew_installed_snapshot` 键），新鲜窗口 10 分钟。
 * 冷启动先用盘上快照立刻显示，再按窗口决定要不要执行命令 —— 每次 brew 调用都要付
 * Ruby 启动成本（首跑 2–3 秒），而「我的」页、包详情页、子页面会各取一次。
 *
 * 两条硬规则：
 *   - **只保存成功的读取**。失败既不写内存也不写磁盘、不推进新鲜窗口，
 *     快照恒等于「最近一次成功读取」；有旧快照时页面继续用旧数据。
 *   - **写命令执行期间的读取不写快照**（见 `read()`），因为那时的 Cellar 处于中间状态。
 */
export class BrewInstalledLoader {
  /** 内存快照。null 表示本进程还没有成功的读取结果 */
  private static memory: BrewInstalledSnapshot | null = null;
  /** 盘上快照是否已经懒加载过。避免每次访问都去读一次存储 */
  private static prefLoaded: boolean = false;
  /** 快照是否已被 `invalidate()` 标记过期。数据保留，只是不再算新鲜 */
  private static expired: boolean = false;
  /** 在途请求。等待路径与后台刷新共用同一次执行 */
  private static inFlight: Promise<BrewInstalledSets> | null = null;
  private static listeners: (() => void)[] = [];

  /**
   * 读三个集合。失败抛 `Error`，`message` 是失败分类。
   *
   * 三种结局（有快照且新鲜 / 有快照但超窗 / 没有快照）见 spec §6.2 的表格：
   * 前两种都不等待命令，第三种执行一次命令并等待。
   *
   * 调用方（`MinePackagesUtil`）把异常转成页面的失败态；分类名会进日志，
   * 页面文案保持通用 —— 用户看到「读不到本机包」就够了，不需要知道是超时还是输出形状变了。
   */
  public static async loadSets(force: boolean = false): Promise<BrewInstalledSets> {
    if (!BrewCli.isEnabled()) {
      // 能力关闭：静默返回空集合。不执行命令、不写日志、不抛异常，调用方按「没有本机包」处理
      return new BrewInstalledSets();
    }
    const snap: BrewInstalledSnapshot | null = BrewInstalledLoader.currentSnapshot();
    if (!force && snap !== null) {
      const age: number = Date.now() - snap.readAt;
      if (!BrewInstalledLoader.expired && age < BREW_INSTALLED_FRESH_MS) {
        Logger.info(TAG, `skip fresh age=${age}`);
        return snap.sets;
      }
      // 有快照但超出新鲜窗口：先把旧数据给页面，同时在后台刷新一次
      Logger.info(TAG, `stale age=${age}, refresh in background`);
      BrewInstalledLoader.startBackgroundRefresh();
      return snap.sets;
    }
    // 没有任何快照（或调用方显式强制刷新）：执行一次命令并等待结果
    return await BrewInstalledLoader.waitForRead();
  }

  /** 同步取当前可用的快照（内存优先，其次盘上懒加载）。不执行命令 */
  public static snapshot(): BrewInstalledSnapshot | null {
    if (!BrewCli.isEnabled()) {
      return null;
    }
    return BrewInstalledLoader.currentSnapshot();
  }

  /** 快照里按包名找一条。token 是不带 tap 前缀的包名（与本机包的 `name` 同一口径） */
  public static installedOf(token: string): BrewInstalledPackage | null {
    if (token.length === 0) {
      return null;
    }
    const snap: BrewInstalledSnapshot | null = BrewInstalledLoader.snapshot();
    if (snap === null) {
      return null;
    }
    for (const one of snap.sets.installed) {
      if (one.name === token) {
        return one;
      }
    }
    return null;
  }

  /**
   * 把快照标记为过期（数据保留）并触发一次后台刷新（在途请求合并）。
   *
   * 写命令结束时由 `BrewCommandRunner` 调用：那一刻命令已经结束，
   * 这一次读取得到的是稳定状态，会写进快照并通知订阅者。
   */
  public static invalidate(): void {
    if (!BrewCli.isEnabled()) {
      return;
    }
    BrewInstalledLoader.expired = true;
    BrewInstalledLoader.startBackgroundRefresh();
  }

  /** 快照更新通知（后台刷新成功、写命令结束后的刷新） */
  public static subscribe(listener: () => void): void {
    if (BrewInstalledLoader.listeners.indexOf(listener) < 0) {
      BrewInstalledLoader.listeners.push(listener);
    }
  }

  public static unsubscribe(listener: () => void): void {
    const index: number = BrewInstalledLoader.listeners.indexOf(listener);
    if (index >= 0) {
      BrewInstalledLoader.listeners.splice(index, 1);
    }
  }

  /** 清掉进程内快照（数据源切换、清空缓存之后调用）。盘上快照不动 */
  public static resetMemory(): void {
    BrewInstalledLoader.memory = null;
    BrewInstalledLoader.expired = false;
  }

  /** 读一次命令。给自检与「强制刷新」用。失败走 `BrewInstalledOutcome.reason`，不自己抛 */
  public static async loadOutcome(): Promise<BrewInstalledOutcome> {
    const startedAt: number = Date.now();
    const outcome: BrewInstalledOutcome = new BrewInstalledOutcome();

    const brewPath: string = BrewCli.brewPath();
    if (brewPath.length === 0) {
      outcome.reason = BrewInstalledFailure.NOT_FOUND;
      outcome.detail = 'no candidate path is executable';
      outcome.tookMs = Date.now() - startedAt;
      Logger.warn(TAG, `load failed reason=${outcome.reason} detail=${outcome.detail}`);
      return outcome;
    }
    if (!ShellUtils.available()) {
      outcome.reason = BrewInstalledFailure.SHELL_UNAVAILABLE;
      outcome.detail = 'shell channel is not available';
      outcome.tookMs = Date.now() - startedAt;
      Logger.warn(TAG, `load failed reason=${outcome.reason} detail=${outcome.detail}`);
      return outcome;
    }

    const commandLine: string = BrewCli.commandLine('info --json=v2 --installed');
    if (commandLine.length === 0) {
      outcome.reason = BrewInstalledFailure.NOT_FOUND;
      outcome.detail = 'command line is empty';
      outcome.tookMs = Date.now() - startedAt;
      Logger.warn(TAG, `load failed reason=${outcome.reason} detail=${outcome.detail}`);
      return outcome;
    }

    // 工作目录由 `BrewCli` 给：brew 的 prefix，取不到时用通道的默认目录
    const result: ShellResult = await ShellUtils.run(
      commandLine, BREW_INSTALLED_TIMEOUT_MS, BrewCli.workingDirectory());
    outcome.tookMs = Date.now() - startedAt;
    outcome.stdoutBytes = result.stdout.length;

    if (result.errorCode === SHELL_ERR_TIMEOUT) {
      outcome.reason = BrewInstalledFailure.TIMEOUT;
      outcome.detail = `timeout after ${outcome.tookMs}ms`;
      Logger.warn(TAG, `load failed reason=${outcome.reason} detail=${outcome.detail}`);
      return outcome;
    }
    if (!result.ok) {
      outcome.reason = BrewInstalledFailure.COMMAND_FAILED;
      outcome.detail = `code=${result.exitCode} error=${result.errorCode} stderr=${firstChars(result.stderr, 200)}`;
      Logger.warn(TAG, `load failed reason=${outcome.reason} detail=${outcome.detail}`);
      return outcome;
    }

    let packages: BrewInstalledPackage[] = [];
    try {
      packages = BrewInstalledParser.parse(result.stdout);
    } catch (error) {
      outcome.reason = BrewInstalledFailure.BAD_OUTPUT;
      outcome.detail = `stdout=${firstChars(result.stdout, 200)}`;
      Logger.warn(TAG, `load failed reason=${outcome.reason} detail=${outcome.detail}`);
      return outcome;
    }
    if (packages.length === 0 && result.stdout.trim().length === 0) {
      outcome.reason = BrewInstalledFailure.BAD_SHAPE;
      outcome.detail = 'empty stdout';
      Logger.warn(TAG, `load failed reason=${outcome.reason} detail=${outcome.detail}`);
      return outcome;
    }

    outcome.sets = BrewInstalledLoader.buildSets(packages);
    Logger.info(TAG, `load ok installed=${outcome.sets.installed.length} ` +
      `outdated=${outcome.sets.outdated.length} updated=${outcome.sets.updated.length} ` +
      `formula=${countKind(packages, BrewKind.FORMULA)} cask=${countKind(packages, BrewKind.CASK)} ` +
      `ms=${outcome.tookMs} brew=${brewPath}`);
    return outcome;
  }

  /** 内存优先；没有内存快照时把盘上快照懒加载进内存 */
  private static currentSnapshot(): BrewInstalledSnapshot | null {
    if (BrewInstalledLoader.memory !== null) {
      return BrewInstalledLoader.memory;
    }
    const loaded: BrewInstalledSnapshot | null = BrewInstalledLoader.readSnapshot();
    BrewInstalledLoader.memory = loaded;
    return loaded;
  }

  /** 读盘上快照。进程内只读一次，形状不对或读失败都按「没有快照」处理 */
  private static readSnapshot(): BrewInstalledSnapshot | null {
    if (BrewInstalledLoader.prefLoaded) {
      return null;
    }
    BrewInstalledLoader.prefLoaded = true;
    const doc: BrewInstalledSnapshotDoc | null =
      PreferenceManager.getInstance().getValue<BrewInstalledSnapshotDoc>(BREW_INSTALLED_SNAPSHOT_KEY);
    if (doc === null) {
      Logger.info(TAG, 'snapshot pref absent');
      return null;
    }
    const packages: BrewInstalledPackage[] | undefined = doc.packages;
    if (doc.version !== BREW_INSTALLED_SNAPSHOT_VERSION || !Array.isArray(packages)) {
      Logger.warn(TAG, `snapshot pref invalid version=${doc.version}`);
      return null;
    }
    const list: BrewInstalledPackage[] = packages as BrewInstalledPackage[];
    const snap: BrewInstalledSnapshot = new BrewInstalledSnapshot(
      BrewInstalledLoader.buildSets(list), doc.readAt ?? 0);
    Logger.info(TAG, `snapshot pref age=${Date.now() - snap.readAt} installed=${snap.sets.installed.length}`);
    return snap;
  }

  /** 成功读取之后写内存与磁盘，再通知订阅者。顺序固定：订阅者读到的一定是新数据 */
  private static saveSnapshot(sets: BrewInstalledSets): void {
    const snap: BrewInstalledSnapshot = new BrewInstalledSnapshot(sets, Date.now());
    BrewInstalledLoader.memory = snap;
    BrewInstalledLoader.expired = false;
    const doc: BrewInstalledSnapshotDoc = {
      version: BREW_INSTALLED_SNAPSHOT_VERSION,
      readAt: snap.readAt,
      packages: sets.installed,
    };
    PreferenceManager.getInstance().setValue<BrewInstalledSnapshotDoc>(BREW_INSTALLED_SNAPSHOT_KEY, doc);
    Logger.info(TAG, `snapshot saved installed=${sets.installed.length}`);
    BrewInstalledLoader.notifyListeners();
  }

  /**
   * 执行一次读取，按结果决定写不写快照。
   *
   * 「写命令执行期间的读取不写快照」在这里落地：`concurrent` 在**开始时**取 ——
   * 一次读取横跨几秒，期间命令状态可能已经变了，只有开始时的那一刻能代表这次读取的性质。
   */
  private static async read(): Promise<BrewInstalledSets> {
    const concurrent: boolean = BrewCommandRunner.getInstance().isRunning();
    const outcome: BrewInstalledOutcome = await BrewInstalledLoader.loadOutcome();
    if (!outcome.ok()) {
      // 失败不碰快照：失败分类放在 message 里，调用方按它打日志，页面文案保持通用
      throw new Error(outcome.reason);
    }
    if (concurrent) {
      Logger.warn(TAG, 'concurrent read skip-save');
    } else {
      BrewInstalledLoader.saveSnapshot(outcome.sets);
    }
    return outcome.sets;
  }

  /** 等待一次读取结果。已有在途请求时直接复用，不重复执行命令 */
  private static async waitForRead(): Promise<BrewInstalledSets> {
    const existing: Promise<BrewInstalledSets> | null = BrewInstalledLoader.inFlight;
    if (existing !== null) {
      return await existing;
    }
    const task: Promise<BrewInstalledSets> = BrewInstalledLoader.read();
    BrewInstalledLoader.inFlight = task;
    try {
      return await task;
    } finally {
      BrewInstalledLoader.releaseInFlight(task);
    }
  }

  /**
   * 后台刷新：结果照常写快照，失败只记日志（旧快照保留，页面继续用旧数据）。
   *
   * 没有在途请求时才发起：多次进入页面会合并成同一次执行。
   */
  private static startBackgroundRefresh(): void {
    if (BrewInstalledLoader.inFlight !== null) {
      return;
    }
    const task: Promise<BrewInstalledSets> = BrewInstalledLoader.read();
    BrewInstalledLoader.inFlight = task;
    BrewInstalledLoader.settleInFlight(task);
  }

  /** 后台路径必须吞掉异常，否则它会变成一次没人接的拒绝；调用方不受影响 */
  private static async settleInFlight(task: Promise<BrewInstalledSets>): Promise<void> {
    try {
      await task;
    } catch (error) {
      Logger.warn(TAG, 'background refresh failed, keep current snapshot');
    }
    BrewInstalledLoader.releaseInFlight(task);
  }

  /** 只释放「还是自己在途」的那一个，避免把后起的请求标记提前摘掉 */
  private static releaseInFlight(task: Promise<BrewInstalledSets>): void {
    if (BrewInstalledLoader.inFlight === task) {
      BrewInstalledLoader.inFlight = null;
    }
  }

  private static notifyListeners(): void {
    const current: (() => void)[] = BrewInstalledLoader.listeners.slice();
    for (const listener of current) {
      listener();
    }
  }

  /**
   * 三个集合。`updated` 取补集，避免两张卡片列同一批包（与 `MinePackageSets` 的口径一致）。
   *
   * formula 与 cask 混在同一个集合里：用户看到的是「这台机器上装了什么」，两者由筛选 chips
   * 与行组件的 `kind` 区分。
   */
  private static buildSets(packages: BrewInstalledPackage[]): BrewInstalledSets {
    const sets: BrewInstalledSets = new BrewInstalledSets();
    const installed: BrewInstalledPackage[] = packages.slice();
    installed.sort((a: BrewInstalledPackage, b: BrewInstalledPackage) => compareName(a.name, b.name));
    sets.installed = installed;

    const outdated: BrewInstalledPackage[] = installed.filter((one: BrewInstalledPackage) => one.outdated);
    outdated.sort((a: BrewInstalledPackage, b: BrewInstalledPackage) => compareName(a.name, b.name));
    sets.outdated = outdated;

    const outdatedNames: Set<string> = new Set<string>();
    for (const one of outdated) {
      outdatedNames.add(one.fullName);
    }
    const updated: BrewInstalledPackage[] = installed.filter((one: BrewInstalledPackage) =>
      !outdatedNames.has(one.fullName));
    updated.sort((a: BrewInstalledPackage, b: BrewInstalledPackage) => b.installedAt - a.installedAt);
    sets.updated = updated;
    return sets;
  }
}

/** 名称排序。不用 localeCompare：ArkTS 对它的支持没有保证，普通比较足够且结果稳定 */
function compareName(left: string, right: string): number {
  if (left === right) {
    return 0;
  }
  return left < right ? -1 : 1;
}

/** 日志明细里的截断。换行会打断「一行一条判据」的格式 */
function firstChars(raw: string, limit: number): string {
  const oneLine: string = raw.replace(/\r?\n/g, '\\n');
  return oneLine.length > limit ? oneLine.substring(0, limit) : oneLine;
}

/** 按类型计数，只用于 `load ok` 一行的日志明细 */
function countKind(packages: BrewInstalledPackage[], kind: string): number {
  let count: number = 0;
  for (const one of packages) {
    if (one.kind === kind) {
      count++;
    }
  }
  return count;
}
