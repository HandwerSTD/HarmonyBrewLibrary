/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { JSON } from '@kit.ArkTS';
import { Logger } from '@ohos/common';
import { SHELL_BREW_PATH_CANDIDATES, SHELL_ERR_TIMEOUT, ShellUtils } from '@ohos/pcnative';
import type { ShellResult } from '@ohos/pcnative';
import type { BrewInstalledPackage } from '../model/BrewModels';
import { BREW_INSTALLED_TTL_MS, BREW_INSTALLED_TIMEOUT_MS } from '../constant/BrewConstants';
import { BrewInstalledParser } from '../util/BrewInstalledParser';

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

/** 三个集合。口径与 `MinePackageSets` 一致，构造在 `loadSets()` 里一次做完 */
export class BrewInstalledSets {
  /** 全部已安装，按名称排序 */
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
 * 本机包读取层。
 *
 * 取数方式是一条命令：`<brew> info --json=v2 --installed`。
 * 命令与输出形状的依据见 `docs/superpowers/specs/2026-10-04-brew-installed-packages-spec.md` §2。
 *
 * 缓存：进程内一份，TTL 60 秒。「我的」页与「本机包」二级页在一次操作里会各取一次，
 * 两次之间数据不可能变，而每次 brew 调用都要付 Ruby 启动成本。不落盘 —— 本机包是
 * 设备上随时可读的现状数据，落盘只会引入失效判定。
 */
export class BrewInstalledLoader {
  /** 进程内缓存的结果；`at` 是写入时刻 */
  private static cache: BrewInstalledOutcome | null = null;
  private static cacheAt: number = 0;

  /** 在途请求。两次并发调用共用同一次执行 */
  private static inFlight: Promise<BrewInstalledSets> | null = null;

  /**
   * 读三个集合。失败抛 `BusinessError`，`message` 是失败分类。
   *
   * 调用方（`MinePackagesUtil`）把异常转成页面的失败态；分类名会进日志，
   * 页面文案保持通用 —— 用户看到「读不到本机包」就够了，不需要知道是超时还是输出形状变了。
   */
  public static async loadSets(force: boolean = false): Promise<BrewInstalledSets> {
    if (!force && BrewInstalledLoader.cache !== null &&
      Date.now() - BrewInstalledLoader.cacheAt < BREW_INSTALLED_TTL_MS) {
      const cached: BrewInstalledOutcome = BrewInstalledLoader.cache;
      if (cached.ok()) {
        return cached.sets;
      }
    }
    if (BrewInstalledLoader.inFlight !== null) {
      return BrewInstalledLoader.inFlight;
    }
    const task: Promise<BrewInstalledSets> = BrewInstalledLoader.loadOnce();
    BrewInstalledLoader.inFlight = task;
    try {
      return await task;
    } finally {
      BrewInstalledLoader.inFlight = null;
    }
  }

  /** 读一次，不碰缓存。给自检与「强制刷新」用 */
  public static async loadOutcome(): Promise<BrewInstalledOutcome> {
    const startedAt: number = Date.now();
    const outcome: BrewInstalledOutcome = new BrewInstalledOutcome();

    const brewPath: string = BrewInstalledLoader.discoverBrewPath();
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

    const result: ShellResult = await ShellUtils.run(
      BrewInstalledLoader.commandOf(brewPath), BREW_INSTALLED_TIMEOUT_MS);
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
      `ms=${outcome.tookMs} brew=${brewPath}`);
    return outcome;
  }

  /**
   * 发现 brew 可执行文件。
   *
   * 顺序：`HOMEBREW_BREW_FILE` -> PATH 里的 `brew` -> 固定候选路径。
   * 候选表在 `@ohos/pcnative` 的 `SHELL_BREW_PATH_CANDIDATES`，与执行通道探针共用一份，
   * 避免两处各写一份路径列表之后漂移。
   *
   * 结果在进程内缓存：这是一次 `test -x` 的探测，但页面上每次进「我的」都会走到这里。
   */
  public static discoverBrewPath(): string {
    if (BrewInstalledLoader.brewPathCache !== null) {
      return BrewInstalledLoader.brewPathCache;
    }
    const fromEnv: string = BrewInstalledLoader.envBrewPath();
    if (fromEnv.length > 0) {
      BrewInstalledLoader.brewPathCache = fromEnv;
      return fromEnv;
    }
    for (const candidate of SHELL_BREW_PATH_CANDIDATES) {
      const check: ShellResult = ShellUtils.runSync(`test -x "${candidate}" && echo yes`, 5000);
      if (check.ok && check.stdout.trim() === 'yes') {
        BrewInstalledLoader.brewPathCache = candidate;
        return candidate;
      }
    }
    return '';
  }

  /** `bin/brew` 的上一级目录。找不到时返回空串 */
  public static prefixOf(brewPath: string): string {
    const suffix: string = '/bin/brew';
    if (brewPath.length <= suffix.length || !brewPath.endsWith(suffix)) {
      return '';
    }
    return brewPath.substring(0, brewPath.length - suffix.length);
  }

  /**
   * 实际执行的命令行。
   *
   * 变量内联进命令行而不是靠子进程继承环境：执行通道是否继承环境变量是探针的 C4 用例，
   * 内联之后这一条不成立也不影响本命令 —— `HOMEBREW_PREFIX` 由 brew 脚本自己按
   * `bin/brew` 的位置推导，其余几个只是「不要做额外的事」的开关。
   */
  public static commandOf(brewPath: string): string {
    const prefix: string = BrewInstalledLoader.prefixOf(brewPath);
    const env: string = 'HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 ' +
      'HOMEBREW_NO_ENV_HINTS=1 NONINTERACTIVE=1';
    const prefixEnv: string = prefix.length > 0 ? ` HOMEBREW_PREFIX="${prefix}"` : '';
    return `${env}${prefixEnv} "${brewPath}" info --json=v2 --installed`;
  }

  /** 清掉进程内缓存。数据源切换、清空缓存之后调用 */
  public static resetMemory(): void {
    BrewInstalledLoader.cache = null;
    BrewInstalledLoader.cacheAt = 0;
    BrewInstalledLoader.brewPathCache = null;
  }

  private static async loadOnce(): Promise<BrewInstalledSets> {
    const outcome: BrewInstalledOutcome = await BrewInstalledLoader.loadOutcome();
    BrewInstalledLoader.cache = outcome;
    BrewInstalledLoader.cacheAt = Date.now();
    if (!outcome.ok()) {
      // 失败分类放在 message 里：调用方按它打日志，页面文案保持通用
      throw new Error(outcome.reason);
    }
    return outcome.sets;
  }

  /** 三个集合。`updated` 取补集，避免两张卡片列同一批包（与 `MinePackageSets` 的口径一致） */
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

  private static envBrewPath(): string {
    // 只有存在 shell 通道时才问环境变量；通道不可用时连 `printenv` 都跑不了
    if (!ShellUtils.available()) {
      return '';
    }
    const result: ShellResult = ShellUtils.runSync('printenv HOMEBREW_BREW_FILE', 5000);
    if (!result.ok) {
      return '';
    }
    const value: string = result.stdout.trim();
    return value.length > 0 ? value : '';
  }

  private static brewPathCache: string | null = null;
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
