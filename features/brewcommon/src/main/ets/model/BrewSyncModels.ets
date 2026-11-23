/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

/**
 * W′ 分布式清单同步的数据模型（specs/2026-11-23-brew-manifest-sync-spec.md §3.2）。
 *
 * 全部用 class 并带默认值：`@Prop` / `@State` 传对象需要运行时形态，
 * 反序列化后逐字段填充并 typeof 校验，**不把 JSON.parse 的结果直接当响应对象用**
 * （与 `AiTypes` / `BrewModels` 同一条纪律——字段缺失静默带进渲染层是最坏结局）。
 *
 * 值只存「主动安装」口径：`installedOnRequest === true` 的包（cask 投影恒真），
 * 与 Discover / 「我的」页 chip 的收窄口径同源（round5 §2）。
 */

import { BrewKind } from './BrewModels';

// ---------------------------------------------------------------- 常量（Key 与 storeId）

/**
 * 分布式 KV 库 id。两端必须完全一致，否则 `getKVStore` 打开已有库时报 15100002
 * （spec §3.1——storeId / securityLevel 任一不同都会撞这条）。
 */
export const BREW_SYNC_STORE_ID: string = 'brew_manifest_sync';

/** 同步 schema 版本。向前兼容（旧文件可读）；不向后（新版本拒读，F6）。 */
export const BREW_SYNC_SCHEMA_VERSION: number = 1;

/** 设备清单的 Key 前缀。完整 Key：`device:<deviceId>/manifest`。 */
export const BREW_SYNC_KEY_DEVICE_PREFIX: string = 'device:';

/** 设备清单 Key 的尾段。 */
export const BREW_SYNC_KEY_MANIFEST_SUFFIX: string = '/manifest';

/** AI 配置的 Key（唯一共写键，冲突由 KV 层最后写入生效解决）。 */
export const BREW_SYNC_KEY_AI_CONFIG: string = 'ai/config';

/**
 * ack 的本地 GSKV 存储（**不进同步库**，spec §3.2）：
 * store `brew_sync_state`，键 `ack`，值是 `Record<deviceId, updatedAt>` 的 JSON。
 */
export const BREW_SYNC_PREFS_STORE: string = 'brew_sync_state';
export const BREW_SYNC_PREFS_KEY_ACK: string = 'ack';

// ---------------------------------------------------------------- 清单文档

/** 清单里的一个包。`tap` 为空表示官方 core/cask。 */
export class BrewSyncPackageDoc {
  /** 包名（不带 tap 前缀，如 `python@3.12`）。 */
  public token: string = '';
  /** 'formula' | 'cask'（BrewKind 的取值域）。 */
  public kind: string = BrewKind.FORMULA;
  /** `user/repo` 形式的 tap；空 = 官方。 */
  public tap: string = '';

  /** 与另一个包是否同一 identity（token + kind + tap 三元组）。 */
  public sameAs(other: BrewSyncPackageDoc): boolean {
    return this.token === other.token && this.kind === other.kind && this.tap === other.tap;
  }

  /** 入同步库前的去重键。 */
  public identity(): string {
    return `${this.kind}/${this.tap}/${this.token}`;
  }
}

/**
 * 一台设备的清单文档（`device:<deviceId>/manifest` 的 Value）。
 */
export class BrewSyncManifestDoc {
  /** schema 版本，读取侧不符即 F6 跳过该设备。 */
  public schema: number = BREW_SYNC_SCHEMA_VERSION;
  public deviceId: string = '';
  /** 设备昵称（本机真实名称，`deviceManager.getLocalDeviceSync().deviceName`）。 */
  public deviceName: string = '';
  /** 更新时刻（epoch ms）。接收链以 `updatedAt > ack` 判「有新增」。 */
  public updatedAt: number = 0;
  /** 主动安装的包（token 字典序）。 */
  public packages: BrewSyncPackageDoc[] = [];
  /** 主动安装包涉及的 taps。 */
  public taps: string[] = [];

  /** 是否含给定 identity 的包（入队去重与「已在本机」判定用）。 */
  public hasPackage(identity: string): boolean {
    for (const one of this.packages) {
      if (one.identity() === identity) {
        return true;
      }
    }
    return false;
  }
}

// ---------------------------------------------------------------- AI 配置文档

/**
 * AI 配置的同步文档（`ai/config` 的 Value，spec §3.6）。
 *
 * `key` 仅在用户显式开启「同步 API Key」后才会出现（默认不同步）；
 * 接收侧 `doc.key 非空 && 本机 keySyncOn` 才落本机 Asset Store。
 */
export class BrewSyncAiConfigDoc {
  public schema: number = BREW_SYNC_SCHEMA_VERSION;
  public updatedAt: number = 0;
  /** AI_PROVIDER_DEEPSEEK | AI_PROVIDER_CUSTOM。 */
  public provider: string = '';
  public baseUrl: string = '';
  public model: string = '';
  /** 显式授权后才写入的 API Key。 */
  public key: string = '';
}

// ---------------------------------------------------------------- 反序列化（纪律层）

/** `BrewSyncPackageDoc` 的受控反序列化。字段缺失/类型不符返回 null（跳过该包）。 */
export function parseBrewSyncPackageDoc(raw: Object): BrewSyncPackageDoc | null {
  const obj: Record<string, Object> = raw as Record<string, Object>;
  const out: BrewSyncPackageDoc = new BrewSyncPackageDoc();
  if (typeof obj['token'] === 'string') {
    out.token = obj['token'] as string;
  }
  if (typeof obj['kind'] === 'string') {
    out.kind = obj['kind'] as string;
  }
  if (typeof obj['tap'] === 'string') {
    out.tap = obj['tap'] as string;
  }
  if (out.token.length === 0) {
    return null;
  }
  if (out.kind !== BrewKind.FORMULA && out.kind !== BrewKind.CASK) {
    out.kind = BrewKind.FORMULA;
  }
  return out;
}

/**
 * `BrewSyncManifestDoc` 的受控反序列化。
 * schema 不符返回 null（F6）；其余字段尽量恢复，坏包跳过不拖垮整份清单。
 */
export function parseBrewSyncManifestDoc(raw: Object): BrewSyncManifestDoc | null {
  const obj: Record<string, Object> = raw as Record<string, Object>;
  let schema: number = 0;
  if (typeof obj['schema'] === 'number') {
    schema = obj['schema'] as number;
  }
  if (schema > BREW_SYNC_SCHEMA_VERSION) {
    return null;
  }
  const out: BrewSyncManifestDoc = new BrewSyncManifestDoc();
  out.schema = schema;
  if (typeof obj['deviceId'] === 'string') {
    out.deviceId = obj['deviceId'] as string;
  }
  if (typeof obj['deviceName'] === 'string') {
    out.deviceName = obj['deviceName'] as string;
  }
  if (typeof obj['updatedAt'] === 'number') {
    out.updatedAt = obj['updatedAt'] as number;
  }
  const rawPackages: Object | undefined = obj['packages'];
  if (rawPackages instanceof Array) {
    for (const one of rawPackages as Object[]) {
      const parsed: BrewSyncPackageDoc | null = parseBrewSyncPackageDoc(one);
      if (parsed !== null) {
        out.packages.push(parsed);
      }
    }
  }
  const rawTaps: Object | undefined = obj['taps'];
  if (rawTaps instanceof Array) {
    for (const one of rawTaps as Object[]) {
      if (typeof one === 'string') {
        out.taps.push(one as string);
      }
    }
  }
  if (out.deviceId.length === 0) {
    return null;
  }
  return out;
}

/** `BrewSyncAiConfigDoc` 的受控反序列化。schema 不符返回 null。 */
export function parseBrewSyncAiConfigDoc(raw: Object): BrewSyncAiConfigDoc | null {
  const obj: Record<string, Object> = raw as Record<string, Object>;
  let schema: number = 0;
  if (typeof obj['schema'] === 'number') {
    schema = obj['schema'] as number;
  }
  if (schema > BREW_SYNC_SCHEMA_VERSION) {
    return null;
  }
  const out: BrewSyncAiConfigDoc = new BrewSyncAiConfigDoc();
  out.schema = schema;
  if (typeof obj['updatedAt'] === 'number') {
    out.updatedAt = obj['updatedAt'] as number;
  }
  if (typeof obj['provider'] === 'string') {
    out.provider = obj['provider'] as string;
  }
  if (typeof obj['baseUrl'] === 'string') {
    out.baseUrl = obj['baseUrl'] as string;
  }
  if (typeof obj['model'] === 'string') {
    out.model = obj['model'] as string;
  }
  if (typeof obj['key'] === 'string') {
    out.key = obj['key'] as string;
  }
  return out;
}

// ---------------------------------------------------------------- 状态（@Observed，UI 接）

/**
 * 一台设备在接收链上的投影（`BrewManifestSyncState.devices` 的元素）。
 *
 * 不直接持 doc：设备卡渲染只需要这几个字段，投影后 UI 不再碰原始 JSON。
 */
@Observed
export class BrewSyncDeviceEntry {
  public deviceId: string = '';
  public deviceName: string = '';
  public updatedAt: number = 0;
  public isSelf: boolean = false;
  /** schema 过新被跳过的设备（F6，页面给「清单版本过新」行）。 */
  public schemaTooNew: boolean = false;
  public packages: BrewSyncPackageDoc[] = [];

  /** 设备卡的展示名：本机加「（本机）」标记。 */
  public displayName(): string {
    return this.isSelf ? `${this.deviceName}` : this.deviceName;
  }
}

/**
 * 同步服务的可观察状态（单例里的一份，spec §3.4）。
 *
 * 侧边栏入口的可见性判据是 `pendingNewCount > 0`；本机设备也进 `devices`
 * （设备卡「本机」标记 + Sheet 设备区展示自己的清单），但不进 `pendingNew`。
 */
@Observed
export class BrewManifestSyncState {
  /** KV 库是否打开成功（false = F1 降级：入口不出现、常驻页给失败行）。 */
  public available: boolean = false;
  /** 是否已完成 init（避免 UI 在服务未起时读空态）。 */
  public initialized: boolean = false;
  /** 组网里每台设备一份（含本机；按 deviceName 排序）。 */
  public devices: BrewSyncDeviceEntry[] = [];
  /** 未消费的新增（远端且 updatedAt > ack 且含本机未装包）。 */
  public pendingNew: BrewSyncPackageDoc[] = [];
  /** pendingNew 的来源设备名（互见句「你的 X 新装了 N 个包」）。 */
  public pendingNewFrom: string = '';
  /** 侧边栏入口的 +N。 */
  public pendingNewCount: number = 0;
  /** 最近一次成功同步的时刻（0 = 还没同步过）。 */
  public lastSyncAt: number = 0;
  /** 最近一次同步失败的时刻（0 = 没失败过）。 */
  public lastSyncFailAt: number = 0;
  /** 同步是否执行中（「立即同步」按钮转圈）。 */
  public syncing: boolean = false;
  /** 是否已获授权（F4：未授权显示引导行）。 */
  public permissionGranted: boolean = false;
  /** Sheet 是否展示（bindSheet 绑在 PcMainPage 的 HdsSideBar 节点上）。 */
  public sheetShown: boolean = false;
  /** AI 配置最近一次被远端应用的时刻（设置-AI 配置页显示）。 */
  public aiAppliedAt: number = 0;

  public constructor() {
  }
}

// ---------------------------------------------------------------- 队列模型

/** 一条安装队列条目的状态（spec §3.7）。 */
export enum BrewQueueStatus {
  PENDING = 'pending',
  RUNNING = 'running',
  DONE = 'done',
  FAILED = 'failed',
}

/**
 * 批量安装队列的一条（spec §3.7；落盘 `filesDir/brew_state/install_queue.json`）。
 *
 * 队列是**落盘数据不是内存态**（rejected.md 手机遥控条留下的门）：
 * 任何前端触发同一队列都零架构改动。
 */
export class BrewQueueItem {
  public token: string = '';
  public kind: string = BrewKind.FORMULA;
  public tap: string = '';
  public status: string = BrewQueueStatus.PENDING;
  public queuedAt: number = 0;
  public finishedAt: number = 0;

  /** 与同步包的 identity 对齐（去重判定）。 */
  public identity(): string {
    return `${this.kind}/${this.tap}/${this.token}`;
  }

  /** identity 的静态版（入队查重等不持实例的场景）。 */
  public static identityOf(kind: string, tap: string, token: string): string {
    return `${kind}/${tap}/${token}`;
  }
}

/** 队列的落盘文档。 */
export class BrewQueueDoc {
  public items: BrewQueueItem[] = [];

  public constructor() {
  }
}

/** `BrewQueueItem` 的受控反序列化（坏条目跳过）。 */
export function parseBrewQueueItem(raw: Object): BrewQueueItem | null {
  const obj: Record<string, Object> = raw as Record<string, Object>;
  const out: BrewQueueItem = new BrewQueueItem();
  if (typeof obj['token'] === 'string') {
    out.token = obj['token'] as string;
  }
  if (typeof obj['kind'] === 'string') {
    out.kind = obj['kind'] as string;
  }
  if (typeof obj['tap'] === 'string') {
    out.tap = obj['tap'] as string;
  }
  if (typeof obj['status'] === 'string') {
    out.status = obj['status'] as string;
  }
  if (typeof obj['queuedAt'] === 'number') {
    out.queuedAt = obj['queuedAt'] as number;
  }
  if (typeof obj['finishedAt'] === 'number') {
    out.finishedAt = obj['finishedAt'] as number;
  }
  if (out.token.length === 0) {
    return null;
  }
  if (out.kind !== BrewKind.FORMULA && out.kind !== BrewKind.CASK) {
    out.kind = BrewKind.FORMULA;
  }
  return out;
}

// ---------------------------------------------------------------- 路由参数

/**
 * 设备清单二级页（`BrewManifestDevicePage`）的路由参数。
 * 数据从服务 state 内存取（零等待）；deviceId 找不到时页面退到空态。
 */
export class BrewManifestDeviceParams {
  public deviceId: string = '';
}
