/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

/**
 * W′ 分布式清单同步服务（specs/2026-11-23-brew-manifest-sync-spec.md §3）。
 *
 * KV 库形态（§3.1）：storeId `brew_manifest_sync`，SINGLE_VERSION，加密 + S4。
 * Key 按设备前缀隔离（`device:<deviceId>/manifest`）天然无冲突；
 * `ai/config` 是唯一共写键，冲突交给 KV 层「最后写入生效」。
 *
 * 四条链路：
 *   - 发布链（§3.3）：BrewInstalledLoader 的快照变化 → 投影主动安装集合 → 与库内旧值
 *     比对，集合不变不 put（防 updatedAt 漂移）。pc_normal 无 brew，永不发布真实清单。
 *   - 接收链（§3.4）：dataChange(REMOTE) → refresh() 读全部 device: 键 → 与 ack 比对
 *     得 pendingNew；可见性走读路径（彩蛋 put 后 refresh 立即可见，不依赖 REMOTE 事件）。
 *   - 同步时机（§3.5）：init / 视图打开 / 立即同步按钮（PUSH_PULL），put 后（PUSH_ONLY）。
 *   - AI 配置链（§3.6）：本地 save → publishAiConfig；远端 ai/config → 应用到 prefs
 *     （绝不回写 KV，防回环）→ Key 需双开关才落 Asset。
 *
 * 状态是 `@Observed` 单例（BrewCommandState 同款模式）：侧边栏入口 / Sheet / 常驻页 /
 * 设置-AI 配置页各用 `@State` 持同一个实例，改一级属性只刷新受影响的节点。
 */

import { distributedKVStore, preferences } from '@kit.ArkData';
import { UIContext } from '@kit.ArkUI';
import { distributedDeviceManager } from '@kit.DistributedServiceKit';
import { abilityAccessCtrl, bundleManager } from '@kit.AbilityKit';
import type { Permissions } from '@kit.AbilityKit';
import type { BusinessError } from '@kit.BasicServicesKit';
import { Logger, StorageKey } from '@ohos/common';
import { AiSettingsStore } from './AiSettingsStore';
import { BrewInstalledLoader } from './BrewInstalledLoader';
import type { BrewInstalledSnapshot } from './BrewInstalledLoader';
import { AiProviderConfig } from '../model/AiTypes';
import { BrewKind } from '../model/BrewModels';
import {
  BREW_SYNC_KEY_AI_CONFIG,
  BREW_SYNC_KEY_DEVICE_PREFIX,
  BREW_SYNC_KEY_MANIFEST_SUFFIX,
  BREW_SYNC_PREFS_KEY_ACK,
  BREW_SYNC_PREFS_STORE,
  BREW_SYNC_STORE_ID,
  BrewManifestSyncState,
  BrewSyncAiConfigDoc,
  BrewSyncDeviceEntry,
  BrewSyncManifestDoc,
  BrewSyncPackageDoc,
  parseBrewSyncAiConfigDoc,
  parseBrewSyncManifestDoc,
} from '../model/BrewSyncModels';

const TAG: string = '[sync]';

/** 显式 sync 的防抖窗口：init 与视图打开可能连着触发，2s 内只发一次。 */
const BREW_SYNC_MIN_INTERVAL_MS: number = 2000;

/** ack GSKV 里「同步 API Key」开关键（spec §3.6：默认关，设置-AI 配置页的开关行）。 */
export const BREW_SYNC_KEY_AI_KEY_SYNC: string = 'brew_ai_key_sync';

/**
 * W′ 同步服务单例。
 *
 * init 挂在 PcAbility.onCreate（双 product）；UI 侧只读 state + 调公开方法，
 * 绝不直接碰 KV 句柄。KV 打开是异步的：available=true 之后才挂订阅与发布链。
 */
export class BrewManifestSyncService {
  private static instance: BrewManifestSyncService | null = null;

  public static getInstance(): BrewManifestSyncService {
    if (BrewManifestSyncService.instance === null) {
      BrewManifestSyncService.instance = new BrewManifestSyncService();
    }
    return BrewManifestSyncService.instance;
  }

  // ---------------------------------------------------------------- 状态与句柄

  public state: BrewManifestSyncState = new BrewManifestSyncState();

  private kvManager: distributedKVStore.KVManager | null = null;
  private kvStore: distributedKVStore.SingleKVStore | null = null;
  /** 设备管理实例（createDeviceManager 不需要权限；取列表/本机身份需要 DISTRIBUTED_DATASYNC）。 */
  private dm: distributedDeviceManager.DeviceManager | null = null;
  /** ack 与 keySyncOn 的 GSKV 偏好（UIContext → hostContext 模式，与 AiSettingsStore 同构）。 */
  private syncStore: preferences.Preferences | null = null;
  private publishListener: (() => void) | null = null;
  /** 防重入 refresh。 */
  private refreshing: boolean = false;
  /** 上次 sync 发起时刻（防抖）。 */
  private lastSyncStartedAt: number = 0;
  /** 本机设备 id（init 时解析一次）。 */
  private selfDeviceId: string = '';
  private selfDeviceName: string = '';
  /** keySyncOn 开关的 UI 监听（AiSettingView 注册，远端应用后刷新开关行）。 */
  private keySyncListener: ((on: boolean) => void) | null = null;
  /** syncComplete 监听是否已挂（on/off 要成对）。 */
  private syncCompleteBound: boolean = false;

  private constructor() {
  }

  // ---------------------------------------------------------------- init

  /**
   * 服务初始化（PcAbility.onCreate，双 product 都调）。
   *
   * 顺序：解析本机身份 → 打开 ack 偏好 → 打开 KV 库（异步，成功后挂订阅 + 首次
   * refresh + 首次 sync + 发布链）。任何一步失败都不抛：F1 降级
   * （available=false，入口不出现、常驻页给失败行）。
   */
  public init(context: Context): void {
    if (this.state.initialized) {
      return;
    }
    this.state.initialized = true;
    this.createDeviceManager();
    this.resolveSelfIdentity();
    this.openSyncStore();
    this.openKvStore(context);
  }

  /** DeviceManager 实例（createDeviceManager 本身无权限门槛，失败落 F8）。 */
  private createDeviceManager(): void {
    if (this.dm !== null) {
      return;
    }
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      this.dm = distributedDeviceManager.createDeviceManager(info.name);
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.warn(TAG, `device manager create failed code=${e.code} msg=${e.message}`);
    }
  }

  /** KV 库打开（§3.1：加密 + S4 + SINGLE_VERSION + autoSync 辅助）。 */
  private openKvStore(context: Context): void {
    try {
      // bundleName 用 bundleManager 自查询（本 SDK API 26 形态 ApplicationInfo 无 bundleName 字段，
      // 与 BrewSentinelService.selfBundleName 同一条结论）。
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      const manager: distributedKVStore.KVManager = distributedKVStore.createKVManager({
        context: context,
        bundleName: info.name,
      });
      const options: distributedKVStore.Options = {
        createIfMissing: true,
        encrypt: true,
        securityLevel: distributedKVStore.SecurityLevel.S4,
        kvStoreType: distributedKVStore.KVStoreType.SINGLE_VERSION,
        autoSync: true,
        backup: true,
      };
      manager.getKVStore(BREW_SYNC_STORE_ID, options,
        (err: BusinessError, store: distributedKVStore.SingleKVStore) => {
          if (err !== undefined && err !== null) {
            const e: BusinessError = err as BusinessError;
            Logger.error(TAG, `kv open failed store=${BREW_SYNC_STORE_ID} code=${e.code} msg=${e.message}`);
            return;
          }
          this.kvManager = manager;
          this.kvStore = store;
          this.state.available = true;
          Logger.info(TAG, `kv open store=${BREW_SYNC_STORE_ID} encrypt=true sl=S4 ok=true`);
          this.subscribeRemote();
          this.refresh();
          this.sync(false);
          this.attachPublishChain();
        });
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.error(TAG, `kv manager create failed code=${e.code} msg=${e.message}`);
    }
  }

  /**
   * 本机身份（F8：deviceManager 抛则本机不发布、只接收）。
   *
   * getLocalDeviceId/getLocalDeviceName 各返回单值（本 SDK d.ts 无 getLocalDeviceSync 整体形式），
   * 且都要 DISTRIBUTED_DATASYNC（user_grant）——未授权时抛 201 落本 catch，授权后由
   * ensurePermissionGranted 重新解析。
   */
  private resolveSelfIdentity(): void {
    if (this.dm === null) {
      return;
    }
    try {
      this.selfDeviceId = this.dm.getLocalDeviceId();
      this.selfDeviceName = this.dm.getLocalDeviceName();
      Logger.info(TAG, `self identity device=${this.selfDeviceId} name=${this.selfDeviceName}`);
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.warn(TAG, `local device resolve failed code=${e.code} msg=${e.message}`);
    }
  }

  /** 发布链：BrewCli 能力开着才挂（pc_normal 无 brew 永不发布真实清单）。 */
  private attachPublishChain(): void {
    if (this.publishListener !== null || this.kvStore === null) {
      return;
    }
    this.publishListener = (): void => {
      this.publishSelfManifest();
    };
    BrewInstalledLoader.subscribe(this.publishListener);
  }

  // ---------------------------------------------------------------- 发布链（§3.3）

  /**
   * 把本机快照投影成清单并发布。
   *
   * 投影口径（§3.2）：`installedOnRequest === true`（cask 投影恒真）；
   * token=name、tap=fullName 含 `/` 时取首段（官方 core/cask 按空处理）。
   * 集合与库内旧值不变时不 put——防 updatedAt 漂移导致对端误报新增。
   */
  public publishSelfManifest(): void {
    if (!this.state.available || this.kvStore === null || this.selfDeviceId.length === 0) {
      return;
    }
    const snap: BrewInstalledSnapshot | null = BrewInstalledLoader.snapshot();
    if (snap === null) {
      return;
    }
    const startedAt: number = Date.now();
    const doc: BrewSyncManifestDoc = new BrewSyncManifestDoc();
    doc.deviceId = this.selfDeviceId;
    doc.deviceName = this.selfDeviceName;
    doc.updatedAt = startedAt;
    for (const one of snap.sets.installed) {
      if (one.installedOnRequest !== true) {
        continue;
      }
      const pkg: BrewSyncPackageDoc = new BrewSyncPackageDoc();
      pkg.token = one.name;
      pkg.kind = one.kind === BrewKind.CASK ? BrewKind.CASK : BrewKind.FORMULA;
      pkg.tap = BrewManifestSyncService.tapOf(one.fullName);
      doc.packages.push(pkg);
      const tap: string = pkg.tap;
      if (tap.length > 0 && doc.taps.indexOf(tap) < 0) {
        doc.taps.push(tap);
      }
    }
    doc.packages.sort((a: BrewSyncPackageDoc, b: BrewSyncPackageDoc): number => a.token.localeCompare(b.token));
    doc.taps.sort();
    const key: string = this.manifestKey(this.selfDeviceId);
    this.kvStore.get(key).then((oldValue: boolean | string | number | Uint8Array) => {
      const old: BrewSyncManifestDoc | null = this.parseManifestValue(oldValue);
      if (old !== null && BrewManifestSyncService.samePackages(old, doc)) {
        return;
      }
      this.kvStore?.put(key, JSON.stringify(doc)).then((): void => {
        Logger.info(TAG, `publish device=${this.selfDeviceId} packages=${doc.packages.length} ` +
          `taps=${doc.taps.length} ms=${Date.now() - startedAt}`);
        this.sync(true);
      }).catch((putErr: BusinessError): void => {
        Logger.warn(TAG, `publish put failed device=${this.selfDeviceId} code=${putErr.code}`);
      });
    }).catch((): void => {
      // 库里还没有旧值（首次发布）：直接 put
      this.kvStore?.put(key, JSON.stringify(doc)).then((): void => {
        Logger.info(TAG, `publish device=${this.selfDeviceId} packages=${doc.packages.length} ` +
          `taps=${doc.taps.length} ms=${Date.now() - startedAt}`);
        this.sync(true);
      }).catch((putErr: BusinessError): void => {
        Logger.warn(TAG, `publish put failed device=${this.selfDeviceId} code=${putErr.code}`);
      });
    });
  }

  /** fullName → tap（`homebrew/core/wget` → `''` 官方；`user/repo/wget` → `user/repo`）。 */
  private static tapOf(fullName: string): string {
    const slash: number = fullName.indexOf('/');
    if (slash < 0) {
      return '';
    }
    const head: string = fullName.substring(0, slash);
    if (head === 'homebrew') {
      // homebrew/core、homebrew/cask 都是官方 tap，清单里按空处理
      return '';
    }
    return head;
  }

  /** 两份清单的包集合是否相同（token+kind+tap 三元组，与顺序无关）。 */
  private static samePackages(a: BrewSyncManifestDoc, b: BrewSyncManifestDoc): boolean {
    if (a.packages.length !== b.packages.length) {
      return false;
    }
    const setA: Set<string> = new Set<string>();
    for (const one of a.packages) {
      setA.add(one.identity());
    }
    for (const one of b.packages) {
      if (!setA.has(one.identity())) {
        return false;
      }
    }
    return true;
  }

  private parseManifestValue(value: boolean | string | number | Uint8Array | undefined):
    BrewSyncManifestDoc | null {
    if (value === undefined || value === null || typeof value !== 'string') {
      return null;
    }
    try {
      return parseBrewSyncManifestDoc(JSON.parse(value as string) as Object);
    } catch (err) {
      return null;
    }
  }

  // ---------------------------------------------------------------- 接收链（§3.4）

  /** 订阅远端变更（单库 ≤8 listener 的约束内只用 1 个）。 */
  private subscribeRemote(): void {
    if (this.kvStore === null) {
      return;
    }
    try {
      this.kvStore.on('dataChange', distributedKVStore.SubscribeType.SUBSCRIBE_TYPE_REMOTE,
        (notification: distributedKVStore.ChangeNotification) => {
          const changed: distributedKVStore.Entry[] =
            notification.insertEntries.concat(notification.updateEntries);
          let hasAi: boolean = false;
          for (const entry of changed) {
            if (entry.key === BREW_SYNC_KEY_AI_CONFIG) {
              hasAi = true;
            }
          }
          Logger.info(TAG, `remote change keys=${changed.map((entry: distributedKVStore.Entry): string =>
            entry.key).join(',')}`);
          if (hasAi) {
            this.applyRemoteAiConfig();
          }
          this.refresh();
        });
      this.kvStore.on('syncComplete', (results: Array<[string, number]>) => {
        let failed: number = 0;
        for (const one of results) {
          if (one[1] !== 0) {
            failed += 1;
          }
        }
        this.state.syncing = false;
        if (failed > 0) {
          this.state.lastSyncFailAt = Date.now();
          Logger.warn(TAG, `sync complete devices=${results.length} failed=${failed}`);
        } else {
          this.state.lastSyncAt = Date.now();
          Logger.info(TAG, `sync complete devices=${results.length} failed=0`);
        }
      });
      this.syncCompleteBound = true;
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.warn(TAG, `remote subscribe failed code=${e.code} msg=${e.message}`);
    }
  }

  /**
   * 读全部设备清单并重算 pendingNew（可见性的唯一真源）。
   *
   * 本机条目进 devices（带「本机」标记）不进 pendingNew；schema 过新的设备
   * 标记 schemaTooNew（F6）。幂等且防重入；异步完成后 @Observed 状态自然刷 UI。
   */
  public async refresh(): Promise<void> {
    if (!this.state.available || this.kvStore === null || this.refreshing) {
      return;
    }
    this.refreshing = true;
    try {
      const entries: distributedKVStore.Entry[] = await this.kvStore.getEntries(BREW_SYNC_KEY_DEVICE_PREFIX);
      const ack: Map<string, number> = this.loadAck();
      const devices: BrewSyncDeviceEntry[] = [];
      const pending: BrewSyncPackageDoc[] = [];
      let pendingFrom: string = '';
      for (const entry of entries) {
        const doc: BrewSyncManifestDoc | null = this.parseManifestValue(entry.value.value);
        if (doc === null) {
          // 值存在但解析不出：schema 过新（F6）或损坏。本机 Key 只可能是当前版本，跳过。
          if (entry.key === this.manifestKey(this.selfDeviceId)) {
            continue;
          }
          const stale: BrewSyncDeviceEntry = new BrewSyncDeviceEntry();
          stale.deviceId = entry.key.substring(BREW_SYNC_KEY_DEVICE_PREFIX.length,
            entry.key.length - BREW_SYNC_KEY_MANIFEST_SUFFIX.length);
          stale.schemaTooNew = true;
          devices.push(stale);
          continue;
        }
        const item: BrewSyncDeviceEntry = new BrewSyncDeviceEntry();
        item.deviceId = doc.deviceId;
        item.deviceName = doc.deviceName;
        item.updatedAt = doc.updatedAt;
        item.isSelf = doc.deviceId === this.selfDeviceId;
        item.packages = doc.packages;
        devices.push(item);
        if (!item.isSelf) {
          const lastAck: number = ack.get(doc.deviceId) ?? 0;
          if (doc.updatedAt > lastAck) {
            const fresh: BrewSyncPackageDoc[] = this.filterNotInstalled(doc.packages);
            if (fresh.length > 0) {
              pending.push(...fresh);
              if (pendingFrom.length === 0) {
                pendingFrom = doc.deviceName;
              }
            }
          }
        }
      }
      devices.sort((a: BrewSyncDeviceEntry, b: BrewSyncDeviceEntry): number =>
        a.deviceName.localeCompare(b.deviceName));
      this.state.devices = devices;
      this.state.pendingNew = pending;
      this.state.pendingNewFrom = pendingFrom;
      this.state.pendingNewCount = pending.length;
      if (pending.length > 0) {
        Logger.info(TAG, `pending new=${pending.length} from=${pendingFrom}`);
      }
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.warn(TAG, `refresh failed code=${e.code} msg=${e.message}`);
    } finally {
      this.refreshing = false;
    }
  }

  /** 过滤出本机未装的包（「已在本机」判定的数据面）。 */
  private filterNotInstalled(packages: BrewSyncPackageDoc[]): BrewSyncPackageDoc[] {
    const snap: BrewInstalledSnapshot | null = BrewInstalledLoader.snapshot();
    const installed: Set<string> = new Set<string>();
    if (snap !== null) {
      for (const one of snap.sets.installed) {
        installed.add(one.name);
      }
    }
    const out: BrewSyncPackageDoc[] = [];
    for (const one of packages) {
      if (!installed.has(one.token)) {
        out.push(one);
      }
    }
    return out;
  }

  // ---------------------------------------------------------------- ack（§3.2：本地 GSKV）

  private openSyncStore(): void {
    try {
      const uiContext: UIContext | undefined = AppStorage.get<UIContext>(StorageKey.UI_CONTEXT);
      if (uiContext === undefined) {
        return;
      }
      const ctx: Context | undefined = uiContext.getHostContext();
      if (ctx === undefined) {
        return;
      }
      this.syncStore = preferences.getPreferencesSync(ctx, {
        name: BREW_SYNC_PREFS_STORE,
        storageType: preferences.StorageType.GSKV,
      });
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.warn(TAG, `sync store open failed code=${e.code} msg=${e.message}`);
    }
  }

  private loadAck(): Map<string, number> {
    const out: Map<string, number> = new Map<string, number>();
    if (this.syncStore === null) {
      return out;
    }
    try {
      const raw: preferences.ValueType = this.syncStore.getSync(BREW_SYNC_PREFS_KEY_ACK, '');
      if (typeof raw !== 'string' || (raw as string).length === 0) {
        return out;
      }
      const parsed: Object = JSON.parse(raw as string) as Object;
      const obj: Record<string, Object> = parsed as Record<string, Object>;
      const keys: string[] = Object.keys(obj);
      for (const key of keys) {
        const value: Object = obj[key];
        if (typeof value === 'number') {
          out.set(key, value as number);
        }
      }
    } catch (err) {
      Logger.warn(TAG, 'ack load failed, treat as empty');
    }
    return out;
  }

  private saveAck(deviceId: string, updatedAt: number): void {
    if (this.syncStore === null) {
      return;
    }
    const map: Map<string, number> = this.loadAck();
    map.set(deviceId, updatedAt);
    try {
      const obj: Record<string, Object> = {};
      map.forEach((value: number, key: string) => {
        obj[key] = value;
      });
      this.syncStore.putSync(BREW_SYNC_PREFS_KEY_ACK, JSON.stringify(obj));
      Logger.info(TAG, `ack device=${deviceId} at=${updatedAt}`);
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.warn(TAG, `ack save failed code=${e.code}`);
    }
  }

  /**
   * 消费当前 pendingNew（Sheet onWillAppear / 常驻页打开时调）。
   *
   * ack 只认「见过」不认「装了」：装了会经发布链让集合对齐，pendingNew 自然清空。
   */
  public markViewed(): void {
    if (this.state.pendingNewCount === 0) {
      return;
    }
    for (const entry of this.state.devices) {
      if (!entry.isSelf && entry.updatedAt > 0) {
        this.saveAck(entry.deviceId, entry.updatedAt);
      }
    }
    this.refresh();
  }

  // ---------------------------------------------------------------- 显式 sync（§3.5）

  /**
   * 发起一次显式同步。
   *
   * @param pushOnly put 后的补推用 PUSH_ONLY；init / 视图打开 / 按钮用 PUSH_PULL。
   * 防抖 2s；未组网（F8）时本地库照常、跨端静默跳过。
   *
   * sync() 本身返回 void、不抛错：完成态只走 on('syncComplete')（subscribeRemote
   * 已挂）；这里只在发起抛错时复位 syncing。
   */
  public sync(pushOnly: boolean = false): void {
    if (!this.state.available || this.kvStore === null || this.state.syncing) {
      return;
    }
    const now: number = Date.now();
    if (now - this.lastSyncStartedAt < BREW_SYNC_MIN_INTERVAL_MS) {
      return;
    }
    this.lastSyncStartedAt = now;
    const deviceIds: string[] = [];
    try {
      if (this.dm !== null) {
        const available: Array<distributedDeviceManager.DeviceBasicInfo> = this.dm.getAvailableDeviceListSync();
        for (const one of available) {
          deviceIds.push(one.deviceId);
        }
      }
    } catch (err) {
      // F8：deviceManager 不可用（未组网/未授权）——本地库照常，跨端同步静默跳过
      Logger.warn(TAG, 'available device list failed, sync local only');
    }
    if (deviceIds.length === 0) {
      Logger.info(TAG, 'sync skipped reason=no-devices');
      this.state.lastSyncAt = Date.now();
      return;
    }
    this.state.syncing = true;
    const mode: distributedKVStore.SyncMode = pushOnly ?
      distributedKVStore.SyncMode.PUSH_ONLY : distributedKVStore.SyncMode.PUSH_PULL;
    try {
      this.kvStore.sync(deviceIds, mode, 0);
      Logger.info(TAG, `sync started devices=${deviceIds.length} mode=${mode}`);
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      this.state.syncing = false;
      this.state.lastSyncFailAt = Date.now();
      Logger.warn(TAG, `sync throw code=${e.code} msg=${e.message}`);
    }
  }

  // ---------------------------------------------------------------- AI 配置同步（§3.6）

  /**
   * 发布本机 AI 配置（AiSettingVM.save 成功后调）。
   *
   * keySyncOn 时 doc 带 key（值 = Asset Store 现存 Key，异步取）；从开转关时发布
   * 不含 key 的 doc 覆盖对端。日志只打 key=<true|false>，永不拼 Key 值。
   */
  public publishAiConfig(config: AiProviderConfig): void {
    if (!this.state.available || this.kvStore === null) {
      return;
    }
    const doc: BrewSyncAiConfigDoc = new BrewSyncAiConfigDoc();
    doc.updatedAt = Date.now();
    doc.provider = config.provider;
    doc.baseUrl = config.baseUrl;
    doc.model = config.model;
    if (this.keySyncOn() && AiSettingsStore.hasApiKey()) {
      AiSettingsStore.loadApiKey().then((key: string) => {
        doc.key = key;
        this.putAiConfigDoc(doc);
      }).catch(() => {
        this.putAiConfigDoc(doc);
      });
    } else {
      this.putAiConfigDoc(doc);
    }
  }

  private putAiConfigDoc(doc: BrewSyncAiConfigDoc): void {
    if (this.kvStore === null) {
      return;
    }
    this.kvStore.put(BREW_SYNC_KEY_AI_CONFIG, JSON.stringify(doc)).then((): void => {
      Logger.info(TAG, `ai config published provider=${doc.provider} model=${doc.model} ` +
        `key=${doc.key.length > 0}`);
      this.sync(true);
    }).catch((err: BusinessError): void => {
      Logger.warn(TAG, `ai config put failed code=${err.code}`);
    });
  }

  /** 应用远端 AI 配置（dataChange 收到 ai/config 时调；绝不回写 KV——防回环）。 */
  private applyRemoteAiConfig(): void {
    if (this.kvStore === null) {
      return;
    }
    this.kvStore.get(BREW_SYNC_KEY_AI_CONFIG).then((value: boolean | string | number | Uint8Array) => {
      if (value === undefined || value === null || typeof value !== 'string') {
        return;
      }
      let doc: BrewSyncAiConfigDoc | null = null;
      try {
        doc = parseBrewSyncAiConfigDoc(JSON.parse(value as string) as Object);
      } catch (parseErr) {
        return;
      }
      if (doc === null) {
        return;
      }
      const config: AiProviderConfig = new AiProviderConfig();
      config.provider = doc.provider;
      config.baseUrl = doc.baseUrl;
      config.model = doc.model;
      const applied: boolean = AiSettingsStore.saveConfig(config);
      let keyApplied: boolean = false;
      if (doc.key.length > 0 && this.keySyncOn()) {
        keyApplied = true;
        AiSettingsStore.saveApiKey(doc.key).then((): void => {
          Logger.info(TAG, `ai key applied ok`);
        }).catch((): void => {
          Logger.warn(TAG, 'ai key apply failed');
        });
      }
      this.state.aiAppliedAt = Date.now();
      Logger.info(TAG, `ai config applied provider=${doc.provider} model=${doc.model} ` +
        `key=${keyApplied} saved=${applied}`);
    }).catch((): void => {
    });
  }

  // ---------------------------------------------------------------- keySyncOn 开关

  /** Key 同步开关（GSKV 真源，默认关；AiSettingView 的开关行读写）。 */
  public keySyncOn(): boolean {
    const store: preferences.Preferences | null = this.syncStore;
    if (store === null) {
      return false;
    }
    return store.getSync(BREW_SYNC_KEY_AI_KEY_SYNC, false) === true;
  }

  public saveKeySyncOn(on: boolean): void {
    const store: preferences.Preferences | null = this.syncStore;
    if (store === null) {
      return;
    }
    try {
      store.putSync(BREW_SYNC_KEY_AI_KEY_SYNC, on === true);
      Logger.info(TAG, `key sync saved on=${on}`);
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.warn(TAG, `key sync save failed code=${e.code}`);
    }
    this.notifyKeySyncListener(on);
  }

  public subscribeKeySync(listener: (on: boolean) => void): void {
    this.keySyncListener = listener;
  }

  private notifyKeySyncListener(on: boolean): void {
    if (this.keySyncListener !== null) {
      this.keySyncListener(on);
    }
  }

  // ---------------------------------------------------------------- 权限（F4）

  /**
   * 查询分布式数据同步权限状态（spec §4.4：未授权时 UI 换授权引导行）。
   *
   * getSelfPermissionStatus（API 20+）免 tokenID，比 checkAccessToken 适合应用自查。
   */
  public static hasDatasyncPermission(): boolean {
    try {
      const status: abilityAccessCtrl.PermissionStatus =
        abilityAccessCtrl.createAtManager().getSelfPermissionStatus('ohos.permission.DISTRIBUTED_DATASYNC');
      return status === abilityAccessCtrl.PermissionStatus.GRANTED;
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.warn(TAG, `permission status failed code=${e.code} msg=${e.message}`);
      return false;
    }
  }

  /**
   * 动态申请分布式数据同步权限（常驻页 / Sheet 首开时调；init 不弹窗不打扰启动）。
   *
   * 授权成功后：解析本机身份（之前未授权 201 失败落 F8）→ refresh → sync 一并补跑。
   */
  public requestDatasyncPermission(context: Context): Promise<boolean> {
    const perms: Array<Permissions> = ['ohos.permission.DISTRIBUTED_DATASYNC'];
    return new Promise<boolean>((resolve) => {
      try {
        abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, perms)
          .then((result) => {
            const granted: boolean = result.authResults.length > 0 && result.authResults[0] === 0;
            this.state.permissionGranted = granted;
            Logger.info(TAG, `permission grant=${granted} shown=${result.dialogShownResults !== undefined}`);
            if (granted) {
              this.resolveSelfIdentity();
              this.refresh();
              this.sync(false);
            }
            resolve(granted);
          })
          .catch((err: BusinessError) => {
            Logger.warn(TAG, `permission request failed code=${err.code} msg=${err.message}`);
            resolve(false);
          });
      } catch (err) {
        const e: BusinessError = err as BusinessError;
        Logger.warn(TAG, `permission request throw code=${e.code} msg=${e.message}`);
        resolve(false);
      }
    });
  }

  /** 供 Sheet/常驻页查询权限并刷新 state（避免未请求过时 UI 显示错误引导行）。 */
  public refreshPermissionState(): void {
    this.state.permissionGranted = BrewManifestSyncService.hasDatasyncPermission();
  }

  // ---------------------------------------------------------------- 彩蛋（§3.8）

  /**
   * 分布式测试能力（仅 pc_normal）：向自己的 Key 写 3 个固定包。
   *
   * 走旁路直写，不经 BrewInstalledLoader 发布闸（闸管 snapshot 投影链路）；
   * pc_normal 无 brew 永不发布真实清单，该 Key 只承载彩蛋数据；升级 pc_acl 后
   * 下一次发布链 put 会覆盖彩蛋数据（真实清单优先，可接受）。
   */
  public writeEasterEgg(): void {
    if (AppStorage.get<boolean>(StorageKey.BREW_CLI_ENABLED) === true) {
      return;
    }
    if (!this.state.available || this.kvStore === null || this.selfDeviceId.length === 0) {
      return;
    }
    const doc: BrewSyncManifestDoc = new BrewSyncManifestDoc();
    doc.deviceId = this.selfDeviceId;
    doc.deviceName = this.selfDeviceName;
    doc.updatedAt = Date.now();
    const tokens: string[] = ['python@3.12', 'deepseek-harness', 'reasonix'];
    for (const token of tokens) {
      const pkg: BrewSyncPackageDoc = new BrewSyncPackageDoc();
      pkg.token = token;
      pkg.kind = BrewKind.FORMULA;
      pkg.tap = '';
      doc.packages.push(pkg);
    }
    const key: string = this.manifestKey(this.selfDeviceId);
    this.kvStore.put(key, JSON.stringify(doc)).then((): void => {
      Logger.info(TAG, `easter egg written packages=3`);
      this.refresh();
    }).catch((err: BusinessError): void => {
      Logger.warn(TAG, `easter egg put failed code=${err.code}`);
    });
  }

  // ---------------------------------------------------------------- Sheet 与工具

  public getState(): BrewManifestSyncState {
    return this.state;
  }

  public openSheet(): void {
    if (!this.state.sheetShown) {
      this.state.sheetShown = true;
    }
  }

  public closeSheet(): void {
    if (this.state.sheetShown) {
      this.state.sheetShown = false;
    }
  }

  /** 视图打开时（Sheet onWillAppear / 常驻页 aboutToAppear）调：ack + 拉新。 */
  public onSheetWillAppear(): void {
    this.markViewed();
    this.refreshPermissionState();
    this.refresh();
    this.sync(false);
  }

  public selfDeviceIdValue(): string {
    return this.selfDeviceId;
  }

  private manifestKey(deviceId: string): string {
    return `${BREW_SYNC_KEY_DEVICE_PREFIX}${deviceId}${BREW_SYNC_KEY_MANIFEST_SUFFIX}`;
  }
}
