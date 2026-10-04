/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger, StorageKey } from '@ohos/common';
import { BREW_SOURCE_STORE_PREFIX } from '../constant/BrewSourceConstants';
import { BrewSourceStore } from './BrewSourceStore';

const TAG: string = '[BrewSource]';

/**
 * 每个源一个 Preferences store（`brew_src_<sourceId>`，GSKV 模式）。
 *
 * ## 为什么是「每源一个 store」而不是「共享 store + 键前缀」
 *
 * Preferences 的成本模型是「一个文件 ↔ 一个实例、整份加载、整份落盘」：
 *   - 共享 store 时，**每次 flush 都要重写所有源的缓存之和**（3 个源约 8.4MB），
 *     首次加载也要把所有源解析进内存；
 *   - 独立 store 时，只加载/只重写**当前激活源**（约 2.8MB），未激活源零成本；
 *   - 「删源」从「逐键删 + 全 store 重写」退化成删文件；
 *   - 而且**漏改调用点会编译不过** —— 键前缀方案漏一处就是静默串源。
 *
 * ## 为什么句柄只缓存激活源那一个
 *
 * 这是内存能被压到「同时只有一个源」的地方。维护页访问非激活源时临时打开、用完
 * `releaseFor()` 释放（`removePreferencesFromCacheSync`），不把第二个源的缓存留在内存里。
 *
 * ## GSKV
 *
 * 固定 `StorageType.GSKV`：二进制、无全量重写、支持多进程。
 * 按需求方决定，不做 `isStorageTypeSupported` 探测、不设计 XML 回退。
 *
 * ⚠ **GSKV 不是「写完就在盘上」**。`putSync` 先把数据写进**内存缓存页**，
 * 官方文档在 `removePreferencesFromCache` 一节写明：「若使用 GSKV 存储模式，推荐在进程退出时
 * 手动调用一次该接口。**此操作会将数据缓存页写入磁盘**」。
 * 我们从不依赖优雅退出（进程会被系统回收、被覆盖安装杀掉），所以那些「希望它自然落盘」的写入会丢 ——
 * 这就是 `persistNow()` 存在的原因。别再把「实时落盘」当成「写入即持久」。
 *
 * ## 为什么不复用 `PreferenceManager`
 *
 * `PreferenceManager` 是单 store 单例（`HMosWorldStoreWithNet`），加多 store 能力要改 `common`，
 * 而本轮约束是「不动 common」。所以这里自建薄封装，并复刻它的容错语义
 * （Context 未就绪时重试、JSON 解析失败时删键、所有异常只记日志不外抛）。
 */
export class BrewSourcePrefs {
  private static activeStore: preferences.Preferences | undefined = undefined;
  private static activeStoreId: string = '';
  /** 临时句柄（维护页用），key = sourceId */
  private static temp: Map<string, preferences.Preferences> = new Map<string, preferences.Preferences>();

  public static storeNameOf(sourceId: string): string {
    return BREW_SOURCE_STORE_PREFIX + sourceId;
  }

  /** 会话激活源的键读取。失败/无 Context/无 store 一律返回 `null`（与 `PreferenceManager.getValue` 同语义） */
  public static get<T>(key: string): T | null {
    const store: preferences.Preferences | null = BrewSourcePrefs.active();
    if (store === null) {
      return null;
    }
    let raw: string | undefined = undefined;
    try {
      const res: preferences.ValueType = store.getSync(key, '');
      if (typeof res === 'string') {
        raw = res as string;
      }
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.error(TAG, `prefs getSync ${key} failed, code=${e.code}, msg=${e.message}`);
      return null;
    }
    if (raw === undefined || raw.length === 0) {
      return null;
    }
    try {
      return JSON.parse(raw) as T;
    } catch (parseErr) {
      const e: BusinessError = parseErr as BusinessError;
      // 与 PreferenceManager 同语义：盘上数据坏了就删掉，下次当没有处理
      Logger.error(TAG, `prefs JSON.parse ${key} failed, data may be corrupted, code=${e.code}`);
      try {
        store.deleteSync(key);
      } catch (delErr) {
        Logger.error(TAG, `prefs delete corrupted ${key} failed`);
      }
      return null;
    }
  }

  /**
   * 会话激活源的键写入。
   *
   * ⚠ 这只把数据写进 GSKV 的**内存缓存页**，不等于已落盘。
   * 需要跨进程生效的写入，必须在该批写入结束后调 `persistNow()`（见它的注释与调用点）。
   */
  public static set<T>(key: string, value: T): void {
    const store: preferences.Preferences | null = BrewSourcePrefs.active();
    if (store === null) {
      return;
    }
    try {
      store.putSync(key, JSON.stringify(value));
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.error(TAG, `prefs putSync ${key} failed, code=${e.code}, msg=${e.message}`);
    }
  }

  /**
   * 把该源的缓存页**显式刷到磁盘**，并作废已失效的句柄。
   *
   * ## 为什么必须显式做
   *
   * GSKV 模式下 `putSync` 只写进**内存缓存页**，不等于已落盘；官方文档在 `removePreferencesFromCache`
   * 一节写明：「此操作会将数据缓存页写入磁盘」。所以：
   *   - 只调 `flush()` 不够 —— 那是 XML 模式的持久化路径；
   *   - 只靠「进程退出时自然落盘」也不够 —— **我们从不优雅退出**：进程会被系统内存回收、
   *     会被覆盖安装杀掉。
   *
   * 真机实测（同一份代码，三次启动）：写入后 25s 内进程被杀 → 下一次启动仍读到 `reason=missing`；
   * 写入后进程存活 130s 以上 → 下一次启动读到 `reason=pref`（`age=130s`）。
   *
   * ## 为什么这比「多下一次」严重
   *
   * `BrewCacheAdmin.clear()` 走的是 `clearSync()`：若进程在那之后被杀，
   * **用户刚清掉的缓存会整份回来**。这正是 spec G5「清空必须真正生效」要防的事，
   * 而 `BrewCacheEpoch` 守卫只能覆盖同一会话内的在途写入，跨不了进程。
   *
   * ## 句柄失效（最容易做错的一步）
   *
   * `removePreferencesFromCacheSync` 把实例移出了内存，因此我们缓存的两个句柄
   * （`activeStore` 与 `temp`）**已失效**，必须一起清掉，让下一次访问重新 `getPreferencesSync` 读盘。
   * 忘了这一步会继续用那份已过期的内存副本，表现为「写进去了也读不到 / 清空了又回来」，很难查。
   */
  public static persistNow(sourceId?: string): void {
    const id: string = sourceId !== undefined ? sourceId : BrewSourceStore.sessionActive().id;
    const ctx: Context | undefined = BrewSourcePrefs.context();
    if (ctx === undefined) {
      return;
    }
    const name: string = BrewSourcePrefs.storeNameOf(id);
    const t0: number = Date.now();
    let ok: boolean = true;
    try {
      preferences.removePreferencesFromCacheSync(ctx, name);
    } catch (err) {
      ok = false;
      const e: BusinessError = err as BusinessError;
      Logger.error(TAG, `persistNow failed, id=${id}, name=${name}, code=${e.code}, msg=${e.message}`);
    }
    // 无论成功与否都丢弃句柄：拿不准的时候，「下一次重新读盘」永远比
    // 「继续用一个可能已被移出内存的句柄」安全。
    if (BrewSourcePrefs.activeStoreId === id) {
      BrewSourcePrefs.activeStore = undefined;
      BrewSourcePrefs.activeStoreId = '';
    }
    BrewSourcePrefs.temp.delete(id);
    Logger.info(TAG, `persistNow id=${id} name=${name} ok=${ok} evictMs=${Date.now() - t0}`);
  }

  /**
   * 打开任意源的 store（维护页用）。返回 `null` 表示不可用
   */
  public static openFor(sourceId: string): preferences.Preferences | null {
    if (sourceId === BrewSourceStore.sessionActive().id) {
      return BrewSourcePrefs.active();
    }
    const cached: preferences.Preferences | undefined = BrewSourcePrefs.temp.get(sourceId);
    if (cached !== undefined) {
      return cached;
    }
    const store: preferences.Preferences | null = BrewSourcePrefs.create(sourceId);
    if (store !== null) {
      BrewSourcePrefs.temp.set(sourceId, store);
    }
    return store;
  }

  /** 释放临时句柄（把该源从内存里踢掉） */
  public static releaseFor(sourceId: string): void {
    const store: preferences.Preferences | undefined = BrewSourcePrefs.temp.get(sourceId);
    if (store === undefined) {
      return;
    }
    BrewSourcePrefs.temp.delete(sourceId);
    const ctx: Context | undefined = BrewSourcePrefs.context();
    if (ctx === undefined) {
      return;
    }
    try {
      preferences.removePreferencesFromCacheSync(ctx, BrewSourcePrefs.storeNameOf(sourceId));
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.error(TAG, `removePreferencesFromCache failed, id=${sourceId}, code=${e.code}, msg=${e.message}`);
    }
  }

  /**
   * 删除一个源的 store 文件。**必须先释放句柄**（调用方负责），
   * 否则 `deletePreferences` 会因实例仍被占用而失败。
   *
   * `deletePreferences` 是异步 API 且不允许与其它接口并发 —— 调用方（`BrewCacheAdmin.drop`）
   * 已经把它排在串行队列里。
   */
  public static async deleteStore(sourceId: string): Promise<boolean> {
    const ctx: Context | undefined = BrewSourcePrefs.context();
    if (ctx === undefined) {
      Logger.error(TAG, `deleteStore deferred, uicontext is undefined, id=${sourceId}`);
      return false;
    }
    const name: string = BrewSourcePrefs.storeNameOf(sourceId);
    try {
      await preferences.deletePreferences(ctx, name);
      Logger.info(TAG, `store deleted, id=${sourceId}, name=${name}`);
      return true;
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.error(TAG, `store delete failed, id=${sourceId}, name=${name}, code=${e.code}, msg=${e.message}`);
      return false;
    }
  }

  /** 会话激活源的 store 句柄（懒加载一次） */
  private static active(): preferences.Preferences | null {
    const id: string = BrewSourceStore.sessionActive().id;
    if (BrewSourcePrefs.activeStore !== undefined && BrewSourcePrefs.activeStoreId === id) {
      return BrewSourcePrefs.activeStore;
    }
    const store: preferences.Preferences | null = BrewSourcePrefs.create(id);
    if (store === null) {
      return null;
    }
    BrewSourcePrefs.activeStore = store;
    BrewSourcePrefs.activeStoreId = id;
    return store;
  }

  private static create(sourceId: string): preferences.Preferences | null {
    const ctx: Context | undefined = BrewSourcePrefs.context();
    if (ctx === undefined) {
      // 与 PreferenceManager 一致：Context 未就绪时不是错误，调用方拿到 null 走「无缓存」
      Logger.warn(TAG, `store open deferred, uicontext is undefined, id=${sourceId}`);
      return null;
    }
    const name: string = BrewSourcePrefs.storeNameOf(sourceId);
    try {
      const options: preferences.Options = { name: name, storageType: preferences.StorageType.GSKV };
      const store: preferences.Preferences = preferences.getPreferencesSync(ctx, options);
      Logger.info(TAG, `store open, id=${sourceId}, name=${name}, mode=gskv, ok=true`);
      return store;
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.error(TAG, `store open, id=${sourceId}, name=${name}, mode=gskv, ok=false, ` +
        `code=${e.code}, msg=${e.message}`);
      return null;
    }
  }

  private static context(): Context | undefined {
    const uiContext: UIContext | undefined = AppStorage.get<UIContext>(StorageKey.UI_CONTEXT);
    if (uiContext === undefined) {
      return undefined;
    }
    return uiContext.getHostContext();
  }
}
