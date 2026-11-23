/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { preferences } from '@kit.ArkData';
import type { BusinessError } from '@kit.BasicServicesKit';
import { notificationManager } from '@kit.NotificationKit';
import { formBindingData, formProvider } from '@kit.FormKit';
import { bundleManager, common, wantAgent } from '@kit.AbilityKit';
import type { WantAgent } from '@kit.AbilityKit';
import { Logger } from '@ohos/common';
import { BrewInstalledLoader, BrewInstalledSets, BrewInstalledSnapshot } from './BrewInstalledLoader';
import type { BrewInstalledPackage } from '../model/BrewModels';
import { ReleaseIntelFilter } from './ReleaseIntelFilter';
import {
  SENTINEL_DATA_AS_OF,
  SENTINEL_DATA_COUNT,
  SENTINEL_DATA_FORM_ID,
  SENTINEL_DATA_HAS_SNAPSHOT,
  SENTINEL_DATA_STALE,
  SENTINEL_DATA_TOP_NAMES,
  SENTINEL_FREQUENCY_DAILY,
  SENTINEL_FREQUENCY_DEFAULT,
  SENTINEL_FREQUENCY_OFF,
  SENTINEL_FREQUENCY_WEEKLY,
  SENTINEL_KEY_FORM_IDS,
  SENTINEL_KEY_FREQUENCY,
  SENTINEL_KEY_LAST_CARD,
  SENTINEL_KEY_LAST_NOTIFY_DATE,
  SENTINEL_KEY_LAST_SET,
  SENTINEL_KEY_NOTIFY_REFUSED,
  SENTINEL_KEY_REMINDED_SET,
  SENTINEL_NOTIFICATION_ID,
  SENTINEL_PREFERENCES_NAME,
  SENTINEL_STALE_MS,
  SENTINEL_TOP_NAMES_LIMIT,
  SENTINEL_WANT_KEY_DISMISS,
  SENTINEL_WANT_KEY_ROUTE,
  SENTINEL_WEEKLY_MIN_MS,
} from '../constant/SentinelConstants';

const TAG: string = '[sentinel]';

/** wantAgent 的 requestCode。两个按钮各建一份 agent，用不同码避免相互覆盖 */
const WANT_REQUEST_ROUTE: number = 0;
const WANT_REQUEST_LATER: number = 1;

/** 用户拒绝通知授权的错误码（官方口径：拒绝后 requestEnableNotification 不再弹窗） */
const ERR_NOTIFICATION_REFUSED: number = 1600004;

/**
 * 卡片数据的跨进程镜像（GSKV `sentinel_last_card` 键，JSON 序列化）。
 *
 * 宿主进程每次评估把快照派生结果写进来；扩展进程（P1/P2 定时触发、卡片重添加首渲染）
 * 读它渲染真实数据。为什么要镜像：扩展进程读不到 `BrewInstalledLoader` 的盘上快照——
 * 能力开关注入项在扩展进程不存在（AppStorage 按进程隔离），且快照所在的 XML store
 * 官方明确不支持多进程并发。镜像只存三个展示字段，不搬运集合明细，坏一条就整条丢弃
 * （loadBase 字段防御）。字段加默认值：JSON 反序列化缺字段时得到 0/''，loadBase 再按
 * readAt>0 判真伪。
 */
class SentinelCardBase {
  public readAt: number = 0;
  public count: number = 0;
  public topNames: string = '';
}

/**
 * 更新哨兵服务：把「本机包快照」翻译成桌面卡片数据与系统通知。
 *
 * 设计基线（spec §3.1 / §6）：
 *   - **只读快照，绝不自己跑命令**。宿主侧数据来源只有 `BrewInstalledLoader.snapshot()` 一条；
 *     刷新时机归 Loader（应用前台打开包管理页时按新鲜窗口刷新），刷新成功经 subscribe
 *     回调进入本服务（接线在 pc_acl 的 SentinelBootstrap）。本文件不 import 任何命令
 *     生成/执行符号，`hmosword-build/brew-sentinel/audit_no_brew_in_touchpoints.mjs` 会拦。
 *   - **跨进程镜像**：宿主评估时把展示三字段（count/topNames/readAt）写进 GSKV
 *     `sentinel_last_card`；扩展进程（P1/P2 定时触发、卡片重添加首渲染）读镜像渲染真实
 *     数据，读不到才降级（跳过/引导态）。见探针文档 Q5。
 *   - **公开方法一律接收 context 参数**：宿主进程传 UIAbilityContext，扩展进程（卡片 /
 *     work scheduler 回调）传各自的 context。不读 AppStorage、不读 UI_CONTEXT —— 扩展
 *     进程里两者都不存在。
 *   - **跨进程持久化走 GSKV**：宿主与扩展进程各用 `context.getApplicationContext()` 打开
 *     同名 store（官方 FAQ 口径：应用级 context 才保证两个进程解析到同一份文件）。GSKV
 *     模式支持多进程并发读写并实时落盘，不需要 flush。
 *
 * 三档调度共用这一份代码，只是触发源不同（spec §3.3）：
 *   P3 宿主前台（SentinelBootstrap + onForeground）、P2 卡片定时（FormExtensionAbility
 *   的 onUpdateForm）、P1 work scheduler（BrewWorkSchedulerExtension，默认休眠）。
 * 宿主有快照时写镜像；扩展触发源与卡片重添加读镜像——P2/P1 因此真正成立，
 * 通知路径只属于宿主分支（扩展触发源既无授权弹窗上下文，镜像也可能陈旧）。
 */
export class BrewSentinelService {
  private static instance: BrewSentinelService | undefined;

  public static getInstance(): BrewSentinelService {
    if (!BrewSentinelService.instance) {
      BrewSentinelService.instance = new BrewSentinelService();
    }
    return BrewSentinelService.instance;
  }

  /** 进程内缓存的包名。wantAgent 与 workScheduler 登记都要用 */
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

  // ---------------------------------------------------------------- 卡片生命周期（G13）

  /**
   * 卡片添加：登记 formId。重复添加按 formId 去重——同一张卡重复回调不能叠加登记。
   * 登记表存 GSKV：扩展进程写、宿主进程读（推卡遍历用），反过来也一样。
   */
  public onFormAdded(context: common.Context, formId: string): void {
    const store: preferences.Preferences | null = this.store(context);
    if (store === null) {
      Logger.error(TAG, `register form failed: store unavailable, formId=${formId}`);
      return;
    }
    const ids: string[] = this.formIds(store);
    if (ids.indexOf(formId) >= 0) {
      Logger.info(TAG, `form already registered formId=${formId}`);
      return;
    }
    ids.push(formId);
    this.putString(store, SENTINEL_KEY_FORM_IDS, JSON.stringify(ids));
    Logger.info(TAG, `form registered formId=${formId} total=${ids.length}`);
  }

  /** 卡片移除：注销 formId。登记不清理会让 pushToForms 一直对着空卡失败 */
  public onFormRemoved(context: common.Context, formId: string): void {
    const store: preferences.Preferences | null = this.store(context);
    if (store === null) {
      Logger.error(TAG, `unregister form failed: store unavailable, formId=${formId}`);
      return;
    }
    const ids: string[] = this.formIds(store);
    const index: number = ids.indexOf(formId);
    if (index < 0) {
      return;
    }
    ids.splice(index, 1);
    this.putString(store, SENTINEL_KEY_FORM_IDS, JSON.stringify(ids));
    Logger.info(TAG, `form unregistered formId=${formId} total=${ids.length}`);
  }

  /**
   * onAddForm 的首渲染数据。
   *
   * 优先读宿主写下的卡片镜像（G13：卡片重添加立即显示宿主上次写入的数据与「截至」时刻）；
   * 镜像不存在（宿主从未成功读过本机包）才给**引导态**而不是 0 假数据（G1）。此时卡片是
   * 新加的、本来就没有旧数据，引导态不构成覆盖。
   */
  public buildInitialBindingData(context: common.Context, formId: string): formBindingData.FormBindingData {
    const store: preferences.Preferences | null = this.store(context);
    const base: SentinelCardBase | null = store === null ? null : this.loadBase(store);
    const data: Record<string, string | number | boolean> = this.cardData(formId, base);
    return formBindingData.createFormBindingData(data);
  }

  // ---------------------------------------------------------------- 主流程（三档共用）

  /**
   * 评估一次快照并推卡片 / 发通知。P1/P2/P3 的所有触发源都落到这一个方法。
   *
   * @param mayRequestAuthorization 是否允许弹通知授权窗。只有宿主 UIAbility 进程的触发源
   *   （SentinelBootstrap / onForeground）才置 true——授权弹窗需要 UIAbilityContext，
   *   扩展进程既没有也没有 UI 可以承载弹窗。
   */
  public evaluateAndPush(context: common.Context, mayRequestAuthorization: boolean = false): void {
    const store: preferences.Preferences | null = this.store(context);
    if (store === null) {
      Logger.error(TAG, 'evaluate skip: store unavailable');
      return;
    }
    const snap: BrewInstalledSnapshot | null = BrewInstalledLoader.snapshot();
    if (snap === null) {
      // 扩展进程路径（P1/P2 定时触发源）：读不到盘上快照（能力开关注入项在扩展进程不存在，
      // 快照所在的 XML store 也不支持多进程并发——探针文档 Q5），改读宿主写下的卡片镜像。
      // 镜像也没有（宿主从未成功读过本机包）就什么都不动——推引导态会把宿主上次推的
      // 真实数据冲掉。镜像命中只推卡、不发通知：定时触发源没有 UIAbilityContext 承载
      // 授权弹窗，镜像数据也可能已经陈旧（spec §5「数据太旧不配打扰」的同一口径）。
      const mirrored: SentinelCardBase | null = this.loadBase(store);
      if (mirrored === null) {
        Logger.info(TAG, 'evaluate skip: no snapshot and no mirror');
        return;
      }
      Logger.info(TAG, `evaluate(extension) count=${mirrored.count} age=${Date.now() - mirrored.readAt}`);
      this.pushToForms(context, mirrored);
      return;
    }
    // 宿主路径：先把镜像写下去（扩展进程下次定时触发才有数据可读），再推卡、再走通知
    // Y 接入（release intel spec §3.2 / G6）：被用户「忽略此版本 / 暂停提醒」的包不进
    // 通知计数与去重集合——策略只改变「要不要打扰」，不改变卡片数据本身的口径。
    // 这里浅拷贝一份快照换掉 outdated 数组，snap 原对象不动（其他读者不受影响）。
    const notifiableOutdated: BrewInstalledPackage[] = [];
    for (const one of snap.sets.outdated) {
      if (!ReleaseIntelFilter.isSuppressed(one.name, one.latestVersion)) {
        notifiableOutdated.push(one);
      }
    }
    const notifiableSets: BrewInstalledSets = new BrewInstalledSets();
    notifiableSets.installed = snap.sets.installed;
    notifiableSets.outdated = notifiableOutdated;
    notifiableSets.updated = snap.sets.updated;
    const notifiable: BrewInstalledSnapshot = new BrewInstalledSnapshot(notifiableSets, snap.readAt);
    const base: SentinelCardBase = this.deriveBase(notifiable);
    this.putString(store, SENTINEL_KEY_LAST_CARD, JSON.stringify(base));
    const count: number = notifiable.sets.outdated.length;
    const age: number = Date.now() - snap.readAt;
    const stale: boolean = age > SENTINEL_STALE_MS;
    Logger.info(TAG, `evaluate outdated=${count} age=${age} stale=${stale} forms=${this.formIds(store).length}`);
    // 卡片推送：stale 也在职责内（卡片降显「打开应用刷新」，G9）
    this.pushToForms(context, base);

    // 通知路径：stale / 空集合 / 频控关 / 同集合 / 已提醒 / 未授权 都要静默跳过（spec §5）
    if (stale) {
      Logger.info(TAG, 'notify skip: snapshot stale');
      return;
    }
    if (count === 0) {
      Logger.info(TAG, 'notify skip: nothing outdated');
      return;
    }
    const frequency: string = this.frequencyOf(store);
    if (frequency === SENTINEL_FREQUENCY_OFF) {
      Logger.info(TAG, 'notify skip: frequency off');
      return;
    }
    const setKey: string = this.setKeyOf(notifiable);
    const reminded: string = this.getString(store, SENTINEL_KEY_REMINDED_SET);
    if (setKey.length > 0 && setKey === reminded) {
      Logger.info(TAG, 'notify skip: current set was dismissed');
      return;
    }
    const lastSet: string = this.getString(store, SENTINEL_KEY_LAST_SET);
    if (setKey === lastSet) {
      Logger.info(TAG, 'notify skip: same set as last publish');
      return;
    }
    const lastDate: string = this.getString(store, SENTINEL_KEY_LAST_NOTIFY_DATE);
    if (!this.frequencyAllows(frequency, lastDate)) {
      Logger.info(TAG, `notify skip: frequency=${frequency} lastNotify=${lastDate}`);
      return;
    }

    if (!notificationManager.isNotificationEnabledSync()) {
      if (!mayRequestAuthorization) {
        // 宿主侧调用方未允许弹授权窗（默认 false）：静默跳过（G8）。扩展触发源在前面
        // 的镜像分支已经 return，走不到这里
        Logger.info(TAG, 'notify skip: not authorized');
        return;
      }
      if (this.getString(store, SENTINEL_KEY_NOTIFY_REFUSED) === '1') {
        Logger.info(TAG, 'notify skip: authorization refused before');
        return;
      }
      const uiContext: common.UIAbilityContext = context as common.UIAbilityContext;
      notificationManager.requestEnableNotification(uiContext).then(() => {
        Logger.info(TAG, 'authorization granted, publish');
        this.publishAsync(context, store, notifiable, setKey);
      }).catch((err: BusinessError) => {
        if (err.code === ERR_NOTIFICATION_REFUSED) {
          // 拒绝后该接口不再弹窗：记标记，之后全部静默降级；设置页保留「去开启」入口（G8）
          this.putString(store, SENTINEL_KEY_NOTIFY_REFUSED, '1');
          Logger.info(TAG, 'authorization refused, silent degrade');
        } else {
          Logger.warn(TAG, `requestEnableNotification failed code=${err.code}`);
        }
      });
      return;
    }
    this.publishAsync(context, store, notifiable, setKey);
  }

  /**
   * 「稍后」的消费端：撤销通知 + 把当次集合键记为已提醒（spec §3.4）。
   *
   * 由 PcAbility 经 want 参数 → AppStorage → PcMainPage 调用（决策 6）。按钮语义是
   * 「别再提醒我这一轮」，绝不触发任何命令。
   */
  public dismissCurrent(context: common.Context): void {
    const store: preferences.Preferences | null = this.store(context);
    if (store === null) {
      Logger.error(TAG, 'dismiss skip: store unavailable');
      return;
    }
    const lastSet: string = this.getString(store, SENTINEL_KEY_LAST_SET);
    if (lastSet.length > 0) {
      this.putString(store, SENTINEL_KEY_REMINDED_SET, lastSet);
    }
    notificationManager.cancel(SENTINEL_NOTIFICATION_ID).then(() => {
      Logger.info(TAG, 'dismiss: notification cancelled');
    }).catch((err: BusinessError) => {
      Logger.warn(TAG, `dismiss cancel failed code=${err.code}`);
    });
    Logger.info(TAG, 'dismiss: current set marked as reminded');
  }

  // ---------------------------------------------------------------- 频控档位（设置页用）

  public getFrequency(context: common.Context): string {
    const store: preferences.Preferences | null = this.store(context);
    if (store === null) {
      return SENTINEL_FREQUENCY_DEFAULT;
    }
    return this.frequencyOf(store);
  }

  public setFrequency(context: common.Context, frequency: string): void {
    const store: preferences.Preferences | null = this.store(context);
    if (store === null) {
      Logger.error(TAG, 'setFrequency skip: store unavailable');
      return;
    }
    this.putString(store, SENTINEL_KEY_FREQUENCY, frequency);
    Logger.info(TAG, `frequency set: ${frequency}`);
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

  private formIds(store: preferences.Preferences): string[] {
    const raw: string = this.getString(store, SENTINEL_KEY_FORM_IDS);
    if (raw.length === 0) {
      return [];
    }
    try {
      const parsed: string[] = JSON.parse(raw) as string[];
      if (!Array.isArray(parsed)) {
        return [];
      }
      return parsed;
    } catch (err) {
      // 登记表坏了按空表处理：下次 onAddForm 会重新登记，卡片推不动但功能不崩
      Logger.warn(TAG, 'form ids corrupted, treat as empty');
      return [];
    }
  }

  private frequencyOf(store: preferences.Preferences): string {
    const raw: string = this.getString(store, SENTINEL_KEY_FREQUENCY);
    if (raw === SENTINEL_FREQUENCY_OFF || raw === SENTINEL_FREQUENCY_DAILY || raw === SENTINEL_FREQUENCY_WEEKLY) {
      return raw;
    }
    return SENTINEL_FREQUENCY_DEFAULT;
  }

  // ---------------------------------------------------------------- 内部：卡片镜像

  /** 快照 → 镜像三字段。镜像只装展示所需的最小集，集合明细不跨进程搬运 */
  private deriveBase(snap: BrewInstalledSnapshot): SentinelCardBase {
    const base: SentinelCardBase = new SentinelCardBase();
    base.readAt = snap.readAt;
    base.count = snap.sets.outdated.length;
    base.topNames = this.topNamesOf(snap);
    return base;
  }

  /**
   * 读卡片镜像。字段防御（readAt>0、count>=0、topNames 为 string）逐条验：
   * 盘上数据按「可能缺失/被改」处理，坏一条整条当 miss，调用方落到各自的兜底
   * （定时触发跳过、首渲染引导态）。
   */
  private loadBase(store: preferences.Preferences): SentinelCardBase | null {
    const raw: string = this.getString(store, SENTINEL_KEY_LAST_CARD);
    if (raw.length === 0) {
      return null;
    }
    try {
      const parsed: SentinelCardBase = JSON.parse(raw) as SentinelCardBase;
      // 数值字段带 typeof 守卫：JSON 里的字符串数字（"5"）会隐式转 number 骗过 >0/>=0 判定
      if (typeof parsed.readAt === 'number' && parsed.readAt > 0 &&
        typeof parsed.count === 'number' && parsed.count >= 0 &&
        typeof parsed.topNames === 'string') {
        return parsed;
      }
      Logger.warn(TAG, 'card mirror fields invalid, treat as absent');
      return null;
    } catch (err) {
      Logger.warn(TAG, 'card mirror parse failed, treat as absent');
      return null;
    }
  }

  // ---------------------------------------------------------------- 内部：推卡

  /**
   * 遍历登记表逐张推卡。**每张卡单独 build 一份 bindingData**：formId 是登记侧概念，
   * 要塞进各自的数据里（决策 9），一张共享数据做不到。base 由调用方给出：宿主路径传
   * 快照派生结果、扩展路径传 loadBase 读出的镜像。
   */
  private async pushToForms(context: common.Context, base: SentinelCardBase): Promise<void> {
    const store: preferences.Preferences | null = this.store(context);
    if (store === null) {
      return;
    }
    const ids: string[] = this.formIds(store);
    if (ids.length === 0) {
      Logger.info(TAG, 'push skip: no registered form');
      return;
    }
    for (const formId of ids) {
      const binding: formBindingData.FormBindingData = formBindingData.createFormBindingData(this.cardData(formId, base));
      try {
        await formProvider.updateForm(formId, binding);
        Logger.info(TAG, `push ok formId=${formId}`);
      } catch (err) {
        const e: BusinessError = err as BusinessError;
        // 最常见的失败是卡片已被移除而登记未清（spec §5）：清登记，下次 onAddForm 自然恢复
        Logger.warn(TAG, `push failed formId=${formId} code=${e.code}, unregister it`);
        this.onFormRemoved(context, formId);
      }
    }
  }

  /** 卡片页消费的全量数据。键名常量见 SentinelConstants，卡片侧 LocalStorageProp 一一对应 */
  private cardData(formId: string, base: SentinelCardBase | null): Record<string, string | number | boolean> {
    const data: Record<string, string | number | boolean> = {};
    data[SENTINEL_DATA_FORM_ID] = formId;
    data[SENTINEL_DATA_HAS_SNAPSHOT] = false;
    data[SENTINEL_DATA_COUNT] = 0;
    data[SENTINEL_DATA_TOP_NAMES] = '';
    data[SENTINEL_DATA_AS_OF] = '';
    data[SENTINEL_DATA_STALE] = false;
    if (base === null) {
      return data;
    }
    // 镜像/快照共用同一份派生口径：asOf 用数据自己的 readAt，随时间自然变陈旧（G9 诚实口径）
    const age: number = Date.now() - base.readAt;
    data[SENTINEL_DATA_HAS_SNAPSHOT] = true;
    data[SENTINEL_DATA_COUNT] = base.count;
    data[SENTINEL_DATA_TOP_NAMES] = base.topNames;
    data[SENTINEL_DATA_AS_OF] = hhmm(base.readAt);
    data[SENTINEL_DATA_STALE] = age > SENTINEL_STALE_MS;
    return data;
  }

  // ---------------------------------------------------------------- 内部：通知

  private async publishAsync(context: common.Context, store: preferences.Preferences,
    snap: BrewInstalledSnapshot, setKey: string): Promise<void> {
    const resMgr = context.resourceManager;
    // 文案按 spec §7 放在 pc_acl 模块（宿主/扩展同模块），经调用方 context 的 resourceManager
    // 按名取串——brewcommon 自身没有这批资源，$r 在这里编译不过。
    const count: number = snap.sets.outdated.length;
    const top: string = this.topNamesOf(snap);
    const title: string = resMgr.getStringByNameSync('sentinel_notify_title').replace('%d', count.toString());
    const body: string = resMgr.getStringByNameSync('sentinel_notify_body')
      .replace('%s', top).replace('%d', count.toString());
    const upgradeLabel: string = resMgr.getStringByNameSync('sentinel_notify_action_upgrade');
    const laterLabel: string = resMgr.getStringByNameSync('sentinel_notify_action_later');
    try {
      const routeAgent: WantAgent = await wantAgent.getWantAgent(this.agentInfo(context, false));
      const laterAgent: WantAgent = await wantAgent.getWantAgent(this.agentInfo(context, true));
      const request: notificationManager.NotificationRequest = {
        id: SENTINEL_NOTIFICATION_ID,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: title,
            text: body,
          },
        },
        wantAgent: routeAgent,
        actionButtons: [
          {
            title: upgradeLabel,
            wantAgent: routeAgent,
          },
          {
            title: laterLabel,
            wantAgent: laterAgent,
          },
        ],
      };
      await notificationManager.publish(request);
      // 发布成功才记账：集合键、上次通知日期、清「稍后」标记。频控跳过时不记账，
      // 集合键只在实际发布后推进——被频控压住的集合在下个窗口还能被提醒。
      this.putString(store, SENTINEL_KEY_LAST_SET, setKey);
      this.putString(store, SENTINEL_KEY_LAST_NOTIFY_DATE, dateStamp(Date.now()));
      this.putString(store, SENTINEL_KEY_REMINDED_SET, '');
      Logger.info(TAG, `notify published count=${count} top=${top}`);
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.warn(TAG, `notify publish failed code=${e.code} message=${e.message}`);
    }
  }

  /**
   * 通知按钮 / 通知本体的 wantAgent：拉起 PcAbility 并带参数。两条路径都只做「带我去」，
   * 不执行任何命令（G4）。
   */
  private agentInfo(context: common.Context, dismiss: boolean): wantAgent.WantAgentInfo {
    const params: Record<string, Object> = dismiss
      ? { 'sentinel_dismiss': '1' }
      : { 'sentinel_route': 'MinePackagesView' };
    const info: wantAgent.WantAgentInfo = {
      wants: [
        {
          deviceId: '',
          bundleName: BrewSentinelService.selfBundleName(),
          abilityName: 'PcAbility',
          parameters: params,
        }
      ],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: dismiss ? WANT_REQUEST_LATER : WANT_REQUEST_ROUTE,
      actionFlags: [wantAgent.WantAgentFlags.CONSTANT_FLAG],
    };
    return info;
  }

  // ---------------------------------------------------------------- 内部：数据口径

  /** 集合键：outdated 的 fullName 排序后 join（spec §3.1）。字符串相等 = 同一集合 */
  private setKeyOf(snap: BrewInstalledSnapshot): string {
    const fullNames: string[] = [];
    for (const one of snap.sets.outdated) {
      fullNames.push(one.fullName);
    }
    fullNames.sort((left: string, right: string) => {
      if (left === right) {
        return 0;
      }
      return left < right ? -1 : 1;
    });
    return fullNames.join(',');
  }

  /** 前 3 个包名（Loader 的 outdated 已按 name 排序，直接取头部） */
  private topNamesOf(snap: BrewInstalledSnapshot): string {
    const names: string[] = [];
    const limit: number = Math.min(SENTINEL_TOP_NAMES_LIMIT, snap.sets.outdated.length);
    for (let i = 0; i < limit; i++) {
      const one: BrewInstalledPackage = snap.sets.outdated[i];
      names.push(one.name);
    }
    return names.join(', ');
  }

  /**
   * 频控判定：以「上次通知日期字符串」为口径（spec §3.4）——哨兵是「有变化才说」，
   * 频控只是变化过于频繁时的限流，不是定时闹钟。
   */
  private frequencyAllows(frequency: string, lastStamp: string): boolean {
    if (lastStamp.length === 0) {
      return true;
    }
    const today: string = dateStamp(Date.now());
    if (frequency === SENTINEL_FREQUENCY_DAILY) {
      return lastStamp !== today;
    }
    if (frequency === SENTINEL_FREQUENCY_WEEKLY) {
      const lastMs: number = Date.parse(lastStamp);
      const todayMs: number = Date.parse(today);
      if (isNaN(lastMs) || isNaN(todayMs)) {
        // 日期串解析不了（历史脏数据）：放行，宁可多提醒一次也不漏报
        return true;
      }
      return todayMs - lastMs >= SENTINEL_WEEKLY_MIN_MS;
    }
    return true;
  }
}

/** 时分展示（HH:mm）。卡片「截至 HH:mm」小字与通知的时间口径共用 */
function hhmm(epochMs: number): string {
  const d: Date = new Date(epochMs);
  return pad2(d.getHours()) + ':' + pad2(d.getMinutes());
}

/** 日历日字符串（yyyy-MM-dd，本地时区）。频控按「日期字符串」比较，跨时区语义稳定 */
function dateStamp(epochMs: number): string {
  const d: Date = new Date(epochMs);
  return d.getFullYear().toString() + '-' + pad2(d.getMonth() + 1) + '-' + pad2(d.getDate());
}

function pad2(value: number): string {
  return value < 10 ? '0' + value.toString() : value.toString();
}
