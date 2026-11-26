/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { preferences } from '@kit.ArkData';
import type { BusinessError } from '@kit.BasicServicesKit';
import { formBindingData, formProvider } from '@kit.FormKit';
import { bundleManager, common } from '@kit.AbilityKit';
import { Logger } from '@ohos/common';
import { BrewInstalledLoader, BrewInstalledSets, BrewInstalledSnapshot } from './BrewInstalledLoader';
import type { BrewInstalledPackage } from '../model/BrewModels';
import { ReleaseIntelFilter } from './ReleaseIntelFilter';
import {
  SENTINEL_CARD_ITEMS_LIMIT,
  SENTINEL_DATA_AS_OF,
  SENTINEL_DATA_COUNT,
  SENTINEL_DATA_DIMENSION,
  SENTINEL_DATA_FOLLOW_EMPTY,
  SENTINEL_DATA_FORM_ID,
  SENTINEL_DATA_HAS_SNAPSHOT,
  SENTINEL_DATA_ITEMS,
  SENTINEL_DATA_STALE,
  SENTINEL_DIMENSION_2_2,
  SENTINEL_DIMENSION_2_4,
  SENTINEL_DIMENSION_4_4,
  SENTINEL_DIMENSION_DEFAULT,
  SENTINEL_FOLLOW_FORM_NAME,
  SENTINEL_FORM_NAME,
  SENTINEL_KEY_FORM_IDS,
  SENTINEL_KEY_LAST_CARD,
  SENTINEL_KEY_LAST_FOLLOW_CARD,
  SENTINEL_PREFERENCES_NAME,
  SENTINEL_STALE_MS,
} from '../constant/SentinelConstants';
import { UpdateFollowPrefs } from './UpdateFollowPrefs';

const TAG: string = '[sentinel]';

/**
 * 卡片镜像的单条版本对（二期 spec §6.1）。字段直接取自 BrewInstalledPackage，
 * 卡片版本对行零派生渲染。一期镜像的 topNames 字段已废弃。
 */
class SentinelCardItem {
  public name: string = '';
  public version: string = '';
  public latestVersion: string = '';
}

/**
 * formId 登记表条目（F 线 v3 格式）。dimension 是规格归一后的字符串
 * （SENTINEL_DIMENSION_* 之一）；name 是卡种（SENTINEL_FORM_NAME /
 * SENTINEL_FOLLOW_FORM_NAME 之一），推卡按它分流数据镜像。
 */
class SentinelFormEntry {
  public id: string = '';
  public dimension: string = SENTINEL_DIMENSION_DEFAULT;
  public name: string = SENTINEL_FORM_NAME;
}

/**
 * 卡片数据的跨进程镜像（GSKV `sentinel_last_card` / `sentinel_last_follow_card` 键，
 * JSON 序列化，二期 spec §6.1 + F 线双镜像）。
 *
 * 宿主进程每次评估把两份口径的派生结果分别写进来（原卡全部待更新 / 关注卡只看关注）；
 * 扩展进程（P1/P2 定时触发、卡片重添加首渲染）按卡种读对应镜像渲染真实数据。
 * 为什么要镜像：扩展进程读不到 `BrewInstalledLoader` 的盘上快照——能力开关注入项在
 * 扩展进程不存在（AppStorage 按进程隔离），且快照所在的 XML store 官方明确不支持
 * 多进程并发。镜像只存展示所需的最小集（count + ≤6 条版本对 + followEmpty），不搬运
 * 集合明细；坏一条就整条丢弃（loadBase 字段防御）。字段加默认值：JSON 反序列化缺字段时
 * 得到 0/''/false/空数组，loadBase 再按 readAt>0 与 items 数组判真伪。
 * 一期 v1 格式（topNames 无 items）按 miss 处理 → 引导态，宿主一次评估后自愈（W9）。
 */
class SentinelCardBase {
  public readAt: number = 0;
  public count: number = 0;
  /** 用户是否一个关注都没有（F 线，只有关注卡消费；原卡镜像恒 false） */
  public followEmpty: boolean = false;
  public items: SentinelCardItem[] = [];
}

/**
 * 更新哨兵服务：把「本机包快照」翻译成桌面卡片数据。
 *
 * 二期起**只服务卡片**（通知链路整体移除，用户裁定无意义——二期 spec §3）。
 * F 线（关注更新）起**双卡共存**（用户裁定 2026-11-26）：
 *   - 原卡 BrewSentinelCard（推荐更新口径）：照旧展示全部主动安装的待更新包，三规格；
 *   - 关注卡 BrewFollowCard：只展示**关注中的**待更新包（deriveFollowBase），2*4/4*4。
 * 两份口径在宿主一次评估里同时派生、各写各的镜像，推卡按登记表里的卡种分流。
 *
 * 设计基线（一期 spec §3.1 / §6 + 二期 spec §3.2/§6）：
 *   - **只读快照，绝不自己跑命令**。宿主侧数据来源只有 `BrewInstalledLoader.snapshot()` 一条；
 *     刷新时机归 Loader（应用前台打开包管理页时按新鲜窗口刷新），刷新成功经 subscribe
 *     回调进入本服务（接线在 pc_acl 的 SentinelBootstrap）。本文件不 import 任何命令
 *     生成/执行符号，`hmosword-build/brew-sentinel/audit_no_brew_in_touchpoints.mjs` 会拦。
 *   - **跨进程镜像**：宿主评估时把展示最小集写进 GSKV 两个镜像键；扩展进程
 *     （P1/P2 定时触发、卡片重添加首渲染）按卡种读镜像渲染真实数据，读不到才降级
 *     （跳过/引导态）。见探针文档 Q5。
 *   - **公开方法一律接收 context 参数**：宿主进程传 UIAbilityContext，扩展进程（卡片 /
 *     work scheduler 回调）传各自的 context。不读 AppStorage、不读 UI_CONTEXT —— 扩展
 *     进程里两者都不存在。
 *   - **跨进程持久化走 GSKV**：宿主与扩展进程各用 `context.getApplicationContext()` 打开
 *     同名 store（官方 FAQ 口径：应用级 context 才保证两个进程解析到同一份文件）。GSKV
 *     模式支持多进程并发读写并实时落盘，不需要 flush。
 *
 * 三档调度共用这一份代码，只是触发源不同（一期 spec §3.3）：
 *   P3 宿主前台（SentinelBootstrap + onForeground）、P2 卡片定时（FormExtensionAbility
 *   的 onUpdateForm）、P1 work scheduler（BrewWorkSchedulerExtension，默认休眠）。
 * 所有触发源收敛为「写镜像 + 推卡」一件事；扩展触发源与卡片重添加读镜像——
 * P2/P1 因此真正成立。
 */
export class BrewSentinelService {
  private static instance: BrewSentinelService | undefined;

  public static getInstance(): BrewSentinelService {
    if (!BrewSentinelService.instance) {
      BrewSentinelService.instance = new BrewSentinelService();
    }
    return BrewSentinelService.instance;
  }

  /** 进程内缓存的包名。workScheduler 登记要用（P1 探针启用后） */
  private static bundleNameCache: string = '';

  /**
   * 本应用包名。**不走 `context.applicationInfo.bundleName`、也不走 `BundleInfo.bundleName`**：
   * 本 SDK（API 26 形态）的 ApplicationInfo / BundleInfo 都没有 bundleName 字段
   * （API 26 构建实测 10505001；bundleInfo.d.ts 里包名就是 `BundleInfo.name`，
   * applicationInfo.d.ts 对 `name` 的注释「same as bundleName」实锤）。
   * 改走 bundleManager 自查询（无需权限、扩展进程可用）；进程内缓存，同步 IPC 只付一次。
   */
  public static selfBundleName(): string {
    if (BrewSentinelService.bundleNameCache.length > 0) {
      return BrewSentinelService.bundleNameCache;
    }
    const info: bundleManager.BundleInfo =
      bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
    BrewSentinelService.bundleNameCache = info.name;
    Logger.info(TAG, `self bundleName resolved: ${BrewSentinelService.bundleNameCache}`);
    return BrewSentinelService.bundleNameCache;
  }

  /** 进程内缓存的 store 实例。GSKV 实例读的就是共享库数据，跨进程写入对读取方可见 */
  private storeCache: preferences.Preferences | null = null;

  private constructor() {
  }

  // ---------------------------------------------------------------- 卡片生命周期（一期 G13）

  /**
   * 卡片添加：登记 formId + 规格 + 卡种（F 线 v3 登记表）。重复添加按 formId 去重——同一张卡
   * 重复回调不能叠加登记；同 id 重复登记且规格/卡种变化时按新值覆写（resize / 重添加路径）。
   *
   * `dimension` 传空串表示「这次回调没带规格信息」（onUpdateForm 的 name-only 刷新）：
   * 已登记的规格**保持不动**，绝不能拿默认规格顶上——否则 4*4 卡会被一次不带规格的
   * 刷新悄悄降级成 2*2。新登记遇到空串规格才按默认规格兜底。
   *
   * 登记表存 GSKV：扩展进程写、宿主进程读（推卡遍历用），反过来也一样。
   */
  public onFormAdded(context: common.Context, formId: string,
    dimension: string = SENTINEL_DIMENSION_DEFAULT, name: string = SENTINEL_FORM_NAME): void {
    // 空串 = 未携带规格：undefined 哨兵区分「保持既有」与「按默认兜底」两条路
    const normalized: string | undefined =
      dimension.length === 0 ? undefined : this.normalizeDimension(dimension);
    const formName: string = this.normalizeFormName(name);
    const store: preferences.Preferences | null = this.store(context);
    if (store === null) {
      Logger.error(TAG, `register form failed: store unavailable, formId=${formId}`);
      return;
    }
    const entries: SentinelFormEntry[] = this.formEntries(store);
    for (const entry of entries) {
      if (entry.id !== formId) {
        continue;
      }
      if ((normalized !== undefined && entry.dimension !== normalized) || entry.name !== formName) {
        if (normalized !== undefined && entry.dimension !== normalized) {
          entry.dimension = normalized;
        }
        entry.name = formName;
        this.putString(store, SENTINEL_KEY_FORM_IDS, JSON.stringify(entries));
        Logger.info(TAG, `form updated formId=${formId} dimension=${entry.dimension} name=${formName}`);
      } else {
        Logger.info(TAG, `form already registered formId=${formId} dimension=${entry.dimension} name=${formName}`);
      }
      return;
    }
    const fresh: SentinelFormEntry = new SentinelFormEntry();
    fresh.id = formId;
    fresh.dimension = normalized === undefined ? SENTINEL_DIMENSION_DEFAULT : normalized;
    fresh.name = formName;
    entries.push(fresh);
    this.putString(store, SENTINEL_KEY_FORM_IDS, JSON.stringify(entries));
    Logger.info(TAG, `form registered formId=${formId} dimension=${fresh.dimension} name=${formName} total=${entries.length}`);
  }

  /** 卡片移除：注销 formId。登记不清理会让 pushToForms 一直对着空卡失败 */
  public onFormRemoved(context: common.Context, formId: string): void {
    const store: preferences.Preferences | null = this.store(context);
    if (store === null) {
      Logger.error(TAG, `unregister form failed: store unavailable, formId=${formId}`);
      return;
    }
    const entries: SentinelFormEntry[] = this.formEntries(store);
    const remaining: SentinelFormEntry[] = [];
    for (const entry of entries) {
      if (entry.id !== formId) {
        remaining.push(entry);
      }
    }
    if (remaining.length === entries.length) {
      return;
    }
    this.putString(store, SENTINEL_KEY_FORM_IDS, JSON.stringify(remaining));
    Logger.info(TAG, `form unregistered formId=${formId} total=${remaining.length}`);
  }

  /**
   * onAddForm 的首渲染数据（F 线起按卡种读对应镜像）。
   *
   * 优先读宿主写下的卡片镜像（一期 G13：卡片重添加立即显示宿主上次写入的数据与「截至」时刻）；
   * 镜像不存在（宿主从未成功读过本机包）或是一期 v1 旧格式（W9 按 miss）才给**引导态**
   * 而不是 0 假数据（一期 G1）。此时卡片是新增/刚迁移的，引导态不构成覆盖。
   */
  public buildInitialBindingData(context: common.Context, formId: string,
    dimension: string = SENTINEL_DIMENSION_DEFAULT, name: string = SENTINEL_FORM_NAME): formBindingData.FormBindingData {
    const store: preferences.Preferences | null = this.store(context);
    const base: SentinelCardBase | null =
      store === null ? null : this.loadBase(store, this.mirrorKeyOf(this.normalizeFormName(name)));
    const data: Record<string, string | number | boolean> = this.cardData(formId, dimension, base);
    return formBindingData.createFormBindingData(data);
  }

  // ---------------------------------------------------------------- 主流程（三档共用）

  /**
   * 评估一次快照并推卡片。P1/P2/P3 的所有触发源都落到这一个方法；二期起职责只剩
   * 「写镜像 + 推卡」（通知分支已随 N 线整体删除——二期 spec §3.2）。
   * F 线起一次评估派生**两份口径**（原卡 / 关注卡），各写各的镜像，推卡按卡种分流。
   */
  public evaluateAndPush(context: common.Context): void {
    const store: preferences.Preferences | null = this.store(context);
    if (store === null) {
      Logger.error(TAG, 'evaluate skip: store unavailable');
      return;
    }
    const snap: BrewInstalledSnapshot | null = BrewInstalledLoader.snapshot();
    if (snap === null) {
      // 扩展进程路径（P1/P2 定时触发源）：读不到盘上快照（能力开关注入项在扩展进程不存在，
      // 快照所在的 XML store 也不支持多进程并发——探针文档 Q5），改读宿主写下的卡片镜像。
      // 逐卡按卡种读各自镜像：某卡种的镜像也没有（宿主从未成功读过本机包）就跳过那张卡
      // ——推引导态会把宿主上次推的真实数据冲掉。
      const entries: SentinelFormEntry[] = this.formEntries(store);
      let pushed = 0;
      for (const entry of entries) {
        const mirrored: SentinelCardBase | null = this.loadBase(store, this.mirrorKeyOf(entry.name));
        if (mirrored === null) {
          continue;
        }
        pushed++;
        this.pushToForms(context, entry, mirrored);
      }
      if (pushed === 0 && entries.length > 0) {
        Logger.info(TAG, 'evaluate skip: no snapshot and no mirror');
      }
      return;
    }
    // 宿主路径：先把镜像写下去（扩展进程下次定时触发才有数据可读），再推卡
    // Y 接入（release intel spec §3.2 / G6）：被用户「忽略此版本 / 暂停提醒」的包不进
    // 卡片计数——策略只改变「要不要强调」，详情页仍可看到被忽略更新（降显）。
    // 这里浅拷贝一份快照换掉 outdated 数组，snap 原对象不动（其他读者不受影响）；
    // deriveBase / deriveFollowBase 在此之上再按各自口径过滤。
    const cardOutdated: BrewInstalledPackage[] = [];
    for (const one of snap.sets.outdated) {
      if (!ReleaseIntelFilter.isSuppressed(one.name, one.latestVersion)) {
        cardOutdated.push(one);
      }
    }
    const cardSets: BrewInstalledSets = new BrewInstalledSets();
    cardSets.installed = snap.sets.installed;
    cardSets.outdated = cardOutdated;
    cardSets.updated = snap.sets.updated;
    const cardSnap: BrewInstalledSnapshot = new BrewInstalledSnapshot(cardSets, snap.readAt);
    const base: SentinelCardBase = this.deriveBase(cardSnap);
    const followBase: SentinelCardBase = this.deriveFollowBase(cardSnap);
    this.putString(store, SENTINEL_KEY_LAST_CARD, JSON.stringify(base));
    this.putString(store, SENTINEL_KEY_LAST_FOLLOW_CARD, JSON.stringify(followBase));
    const count: number = base.count;
    const age: number = Date.now() - base.readAt;
    const stale: boolean = age > SENTINEL_STALE_MS;
    Logger.info(TAG, `evaluate outdated=${count} followed=${followBase.count} age=${age} stale=${stale} forms=${this.formEntries(store).length}`);
    // 卡片推送：stale 也在职责内（卡片降显「打开应用刷新」，一期 G9 / 二期 W7）
    this.pushAllForms(context, base, followBase);
  }

  // ---------------------------------------------------------------- 内部：GSKV store

  /**
   * 打开哨兵 store。宿主与扩展进程共用这一份文件的关键是**两侧都用应用级 context**
   * （官方 FAQ：不同进程的 context 不同，应用级 context 才解析到同一路径）。
   *
   * GSKV（API 18+）支持多进程并发读写、实时落盘；平台不支持时退回默认 XML——XML 在多进程
   * 下有并发损坏风险，属于降级运行，warn 日志供探针辨认。
   */
  private store(context: common.Context): preferences.Preferences | null {
    if (this.storeCache !== null) {
      return this.storeCache;
    }
    const appContext: common.Context = context.getApplicationContext();
    if (!preferences.isStorageTypeSupported(preferences.StorageType.GSKV)) {
      Logger.warn(TAG, 'gskv unsupported on this platform, fallback to xml (cross-process degraded)');
      return this.openStore(appContext, false);
    }
    return this.openStore(appContext, true);
  }

  private openStore(appContext: common.Context, gskv: boolean): preferences.Preferences | null {
    const options: preferences.Options = gskv
      ? { name: SENTINEL_PREFERENCES_NAME, storageType: preferences.StorageType.GSKV }
      : { name: SENTINEL_PREFERENCES_NAME };
    try {
      this.storeCache = preferences.getPreferencesSync(appContext, options);
      Logger.info(TAG, `store opened gskv=${gskv}`);
      return this.storeCache;
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.error(TAG, `open store failed gskv=${gskv} code=${e.code} message=${e.message}`);
      return null;
    }
  }

  private getString(store: preferences.Preferences, key: string): string {
    try {
      const value: preferences.ValueType = store.getSync(key, '');
      if (typeof value === 'string') {
        return value;
      }
      // 类型漂移（键被外部改写、历史脏数据）一律按缺失处理，调用方各自有 miss 兜底
      return '';
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.warn(TAG, `get ${key} failed code=${e.code}`);
      return '';
    }
  }

  private putString(store: preferences.Preferences, key: string, value: string): void {
    try {
      store.putSync(key, value);
      // GSKV 模式实时落盘，不需要 flush（见 preferences 文档 StorageType 说明）
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.warn(TAG, `put ${key} failed code=${e.code}`);
    }
  }

  /**
   * 读 formId 登记表（F 线 v3）。兼容解析：一期 v1 纯字符串数组 → 规格兜底默认值、
   * 卡种兜底原哨兵卡（下次 onAddForm 按真实值覆写）；二期 v2 对象数组（无 name）同上；
   * v3 对象数组逐条验 id/dimension/name。
   * 登记表坏了按空表处理：下次 onAddForm 会重新登记，卡片推不动但功能不崩。
   */
  private formEntries(store: preferences.Preferences): SentinelFormEntry[] {
    const entries: SentinelFormEntry[] = [];
    const raw: string = this.getString(store, SENTINEL_KEY_FORM_IDS);
    if (raw.length === 0) {
      return entries;
    }
    try {
      const parsed: Object[] = JSON.parse(raw) as Object[];
      if (!Array.isArray(parsed)) {
        return entries;
      }
      for (const element of parsed) {
        if (typeof element === 'string') {
          if (element.length === 0) {
            continue;
          }
          // 一期 v1 格式：纯 formId，规格与卡种未知按默认兜底
          const legacy: SentinelFormEntry = new SentinelFormEntry();
          legacy.id = element;
          entries.push(legacy);
          continue;
        }
        // 二期 v2 / F 线 v3 格式：{"id","dimension"[,"name"]}
        const entry = element as SentinelFormEntry;
        if (typeof entry.id === 'string' && entry.id.length > 0) {
          const fresh: SentinelFormEntry = new SentinelFormEntry();
          fresh.id = entry.id;
          fresh.dimension = this.normalizeDimension(entry.dimension);
          fresh.name = typeof entry.name === 'string' ? this.normalizeFormName(entry.name) : SENTINEL_FORM_NAME;
          entries.push(fresh);
        }
      }
      return entries;
    } catch (err) {
      Logger.warn(TAG, 'form registry corrupted, treat as empty');
      return entries;
    }
  }

  /** 卡种归一：只认 form_config.json 里登记的两个 name，未知值（含空串）兜底原哨兵卡 */
  private normalizeFormName(value: string): string {
    if (value === SENTINEL_FORM_NAME || value === SENTINEL_FOLLOW_FORM_NAME) {
      return value;
    }
    return SENTINEL_FORM_NAME;
  }

  /** 卡种 → 数据镜像键。关注卡读自己的镜像，其余（含历史脏 name）读原卡镜像 */
  private mirrorKeyOf(name: string): string {
    return this.normalizeFormName(name) === SENTINEL_FOLLOW_FORM_NAME ?
      SENTINEL_KEY_LAST_FOLLOW_CARD : SENTINEL_KEY_LAST_CARD;
  }

  /** 规格归一（二期 spec §6.3）：三规格白名单，未知值（含 DIMENSION_KEY 的意外格式）兜底默认规格 */
  private normalizeDimension(value: string): string {
    if (value === SENTINEL_DIMENSION_2_2 || value === SENTINEL_DIMENSION_2_4 || value === SENTINEL_DIMENSION_4_4) {
      return value;
    }
    return SENTINEL_DIMENSION_DEFAULT;
  }

  // ---------------------------------------------------------------- 内部：卡片镜像

  /**
   * 快照 → 原卡镜像（二期 spec §6.1）。镜像只装展示所需的最小集：count + 前
   * SENTINEL_CARD_ITEMS_LIMIT 条版本对（name/version/latestVersion），集合明细不跨进程搬运。
   * 口径：只算主动安装（installedOnRequest，cask 一律按主动安装——BrewInstalledParser
   * 同款口径）的过期包；作为依赖装上的过期随 `brew upgrade` 顺带解决，不占 hero 数字，
   * 也不进版本对列表（用户裁定：卡片只展示主动安装的）。
   * followEmpty 只有关注卡消费，原卡镜像恒 false。
   */
  private deriveBase(snap: BrewInstalledSnapshot): SentinelCardBase {
    const base: SentinelCardBase = new SentinelCardBase();
    base.readAt = snap.readAt;
    const onRequest: BrewInstalledPackage[] = snap.sets.outdated.filter(
      (one: BrewInstalledPackage) => one.installedOnRequest);
    base.count = onRequest.length;
    const limit: number = Math.min(SENTINEL_CARD_ITEMS_LIMIT, onRequest.length);
    for (let i = 0; i < limit; i++) {
      base.items.push(this.itemOf(onRequest[i]));
    }
    return base;
  }

  /**
   * 快照 → 关注卡镜像（F 线新增）。与原卡同一条镜像结构，口径收窄为**只算关注中**：
   *   - 关注过滤（UpdateFollowPrefs）：卡片只提醒用户关注了的包（用户裁定 2026-11-26）；
   *   - 主动安装（installedOnRequest）：作为依赖装上的过期随 `brew upgrade` 顺带解决，
   *     不占 hero 数字，也不进版本对列表；
   *   - 发布策略（ReleaseIntelFilter）在 evaluateAndPush 的上游已过滤，这里不再重复。
   *
   * followEmpty 用「关注表是否为空」而不是「过滤结果是否为空」区分两态：
   * 关注表空 = 关注卡给关注空态（引导去关注）；表非空且 count=0 = 零更新态（关注的都最新）。
   */
  private deriveFollowBase(snap: BrewInstalledSnapshot): SentinelCardBase {
    const base: SentinelCardBase = new SentinelCardBase();
    base.readAt = snap.readAt;
    base.followEmpty = UpdateFollowPrefs.followedCount() === 0;
    const onRequest: BrewInstalledPackage[] = snap.sets.outdated.filter(
      (one: BrewInstalledPackage) => one.installedOnRequest && UpdateFollowPrefs.isFollowed(one.name));
    base.count = onRequest.length;
    const limit: number = Math.min(SENTINEL_CARD_ITEMS_LIMIT, onRequest.length);
    for (let i = 0; i < limit; i++) {
      base.items.push(this.itemOf(onRequest[i]));
    }
    return base;
  }

  /** 版本对条目装配（两条派生路径共用的收尾） */
  private itemOf(one: BrewInstalledPackage): SentinelCardItem {
    const item: SentinelCardItem = new SentinelCardItem();
    item.name = one.name;
    item.version = one.version;
    item.latestVersion = one.latestVersion;
    return item;
  }

  /**
   * 读卡片镜像（F 线起按 key 读，双镜像共用一套字段防御）。字段防御逐条验：readAt>0、
   * count>=0、items 为数组且每条 name/version/latestVersion 为 string。盘上数据按
   * 「可能缺失/被改」处理，坏一条整条当 miss，调用方落到各自的兜底（定时触发跳过、
   * 首渲染引导态）。**一期 v1 镜像（topNames 无 items）也按 miss 处理**（W9）：不迁移、
   * 不崩，宿主下次评估写新格式后自愈。followEmpty 容错：缺字段（历史镜像）按 false 处理，
   * 不判 miss——原卡本就不消费它，关注卡的镜像只由宿主写 v3 格式产生。
   */
  private loadBase(store: preferences.Preferences, key: string): SentinelCardBase | null {
    const raw: string = this.getString(store, key);
    if (raw.length === 0) {
      return null;
    }
    try {
      const parsed: SentinelCardBase = JSON.parse(raw) as SentinelCardBase;
      // 数值字段带 typeof 守卫：JSON 里的字符串数字（"5"）会隐式转 number 骗过 >0/>=0 判定
      if (typeof parsed.readAt !== 'number' || parsed.readAt <= 0) {
        Logger.warn(TAG, 'card mirror readAt invalid, treat as absent');
        return null;
      }
      if (typeof parsed.count !== 'number' || parsed.count < 0) {
        Logger.warn(TAG, 'card mirror count invalid, treat as absent');
        return null;
      }
      if (!Array.isArray(parsed.items)) {
        // 一期 v1 格式（topNames 字符串，无 items 数组）：按 miss → 引导态，宿主自愈
        Logger.warn(TAG, 'card mirror is legacy v1 (topNames, no items), treat as absent for self-heal');
        return null;
      }
      for (const item of parsed.items) {
        if (typeof item.name !== 'string' || item.name.length === 0 ||
          typeof item.version !== 'string' || typeof item.latestVersion !== 'string') {
          Logger.warn(TAG, 'card mirror item invalid, treat as absent');
          return null;
        }
      }
      if (typeof parsed.followEmpty !== 'boolean') {
        parsed.followEmpty = false;
      }
      return parsed;
    } catch (err) {
      Logger.warn(TAG, 'card mirror parse failed, treat as absent');
      return null;
    }
  }

  // ---------------------------------------------------------------- 内部：推卡

  /**
   * 遍历登记表逐张推卡（F 线起按卡种分流镜像）。**每张卡单独 build 一份 bindingData**：
   * formId、规格、卡种都是登记侧概念，要塞进各自的数据里（一期决策 9 + 二期 spec §6.3），
   * 一份共享数据做不到。
   * base 由调用方给出：宿主路径传两份快照派生结果（原卡 / 关注卡），扩展路径已按卡种
   * 读好镜像后逐卡调 pushToForms。
   */
  private async pushAllForms(context: common.Context, sentinelBase: SentinelCardBase,
    followBase: SentinelCardBase): Promise<void> {
    const store: preferences.Preferences | null = this.store(context);
    if (store === null) {
      return;
    }
    const entries: SentinelFormEntry[] = this.formEntries(store);
    if (entries.length === 0) {
      Logger.info(TAG, 'push skip: no registered form');
      return;
    }
    for (const entry of entries) {
      const base: SentinelCardBase = this.normalizeFormName(entry.name) === SENTINEL_FOLLOW_FORM_NAME ?
        followBase : sentinelBase;
      await this.pushToForms(context, entry, base);
    }
  }

  /** 推单张卡：按登记条目的 id / 规格 / 数据口径 build bindingData 并 updateForm。 */
  private async pushToForms(context: common.Context, entry: SentinelFormEntry,
    base: SentinelCardBase): Promise<void> {
    const binding: formBindingData.FormBindingData =
      formBindingData.createFormBindingData(this.cardData(entry.id, entry.dimension, base));
    try {
      await formProvider.updateForm(entry.id, binding);
      Logger.info(TAG, `push ok formId=${entry.id} dimension=${entry.dimension} name=${entry.name}`);
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      // 最常见的失败是卡片已被移除而登记未清（一期 spec §5）：清登记，下次 onAddForm 自然恢复
      Logger.warn(TAG, `push failed formId=${entry.id} code=${e.code}, unregister it`);
      this.onFormRemoved(context, entry.id);
    }
  }

  /** 卡片页消费的全量数据（二期 spec §6.4）。键名常量见 SentinelConstants，卡片侧 LocalStorageProp 一一对应 */
  private cardData(formId: string, dimension: string, base: SentinelCardBase | null): Record<string, string | number | boolean> {
    const data: Record<string, string | number | boolean> = {};
    data[SENTINEL_DATA_FORM_ID] = formId;
    data[SENTINEL_DATA_DIMENSION] = this.normalizeDimension(dimension);
    data[SENTINEL_DATA_HAS_SNAPSHOT] = false;
    data[SENTINEL_DATA_FOLLOW_EMPTY] = false;
    data[SENTINEL_DATA_COUNT] = 0;
    data[SENTINEL_DATA_ITEMS] = '[]';
    data[SENTINEL_DATA_AS_OF] = '';
    data[SENTINEL_DATA_STALE] = false;
    if (base === null) {
      return data;
    }
    // 镜像/快照共用同一份派生口径：asOf 用数据自己的 readAt，随时间自然变陈旧（一期 G9 诚实口径）
    const age: number = Date.now() - base.readAt;
    data[SENTINEL_DATA_HAS_SNAPSHOT] = true;
    data[SENTINEL_DATA_FOLLOW_EMPTY] = base.followEmpty;
    data[SENTINEL_DATA_COUNT] = base.count;
    data[SENTINEL_DATA_ITEMS] = JSON.stringify(base.items);
    data[SENTINEL_DATA_AS_OF] = hhmm(base.readAt);
    data[SENTINEL_DATA_STALE] = age > SENTINEL_STALE_MS;
    return data;
  }
}

/** 时分展示（HH:mm）。卡片「截至 HH:mm」小字的时间口径 */
function hhmm(epochMs: number): string {
  const d: Date = new Date(epochMs);
  return pad2(d.getHours()) + ':' + pad2(d.getMinutes());
}

function pad2(value: number): string {
  return value < 10 ? '0' + value.toString() : value.toString();
}
