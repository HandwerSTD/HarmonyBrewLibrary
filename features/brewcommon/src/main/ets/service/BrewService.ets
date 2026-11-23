/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { Logger } from '@ohos/common';
import { objKeys } from '../util/objkeys';
import { BrewSourcePrefs } from './BrewSourcePrefs';
import { BrewCacheEpoch } from './BrewCacheEpoch';
import { BrewLoadLog } from '../util/BrewLoadLog';
import { BrewTable, BrewKindText } from './BrewTable';
import { adapterFor } from './source/BrewSourceAdapter';
import type { BrewSourceAdapter } from './source/BrewSourceAdapter';
import { BrewSourceStore } from './BrewSourceStore';
import type { BrewHttpResult } from './BrewHttp';
import type { LiveCaskDoc, LiveFormulaDoc } from './BrewApiMapper';
import { BREW_DETAIL_CACHE_KEY, BREW_DETAIL_VIEW_KEY, BREW_LIVE_FRESH_MS } from '../constant/BrewConstants';

const TAG: string = '[BrewService]';

/**
 * 数据源明确回答「没有这个包」（404 / 410）。
 *
 * 与取数失败分开：详情页据此显示「未找到」，不再回退到骨架或历史详情。
 * 抛出点只有 `BrewService.fetchDoc`，消费点只有 `BrewRepository` 与详情页。
 */
export class BrewDocAbsentError extends Error {
  public readonly kind: string;
  public readonly token: string;
  public readonly status: number;

  public constructor(kind: string, token: string, status: number) {
    super('doc absent: kind=' + kind + ' token=' + token + ' status=' + status);
    this.name = 'BrewDocAbsentError';
    this.kind = kind;
    this.token = token;
    this.status = status;
  }
}

/**
 * 详情页的**原始文档**缓存条目（按 `kind_token` 索引）。
 *
 * 存原始文档而不是归一后的视图数据，是因为条件请求的基准（`lastModified`）必须跟着
 * 条目一起活：`If-Modified-Since` 要拿它去问上游，而归一后的视图数据里没有这个字段。
 * 归一后的那份另存于 `brew_detail_view`（按 componentId 索引），充当没有新鲜窗口的回落源。
 *
 * 三个好处：
 *   1. `schemaVersion` 对不上直接当未命中；
 *   2. 1 小时新鲜窗口内不发请求，超窗后靠 `lastModified` 拿 304 的 0 字节续期；
 *   3. 失败时调用方可以退回 `cachedDetail()` 的归一结果，两条路径互不覆盖。
 */
interface DetailCacheEntry<T> {
  ts: number;
  schemaVersion: number;
  lastModified: string;
  data: T;
}

/**
 * 现网单条取数。**详情页是唯一的消费者**。
 *
 * 浏览页、榜单与搜索全部从包表（`BrewTable`）读，一条请求都不发，所以：
 *   - 不再有「一次 hydrate 一百个」的批量路径；
 *   - 也不再需要数据集 HEAD 探针 —— 探针是为「一次问一句、代替一百个条件请求」设计的，
 *     而详情页一次只用 1 个 token，条件请求本身就是 0 字节，多加一次 HEAD 只多一次往返。
 *     于是 `brew_live_dataset` 与那套版本戳机制整层删除。
 *
 * 缓存策略：1 小时新鲜窗口 + `If-Modified-Since` 条件请求 + 取数失败回落。
 */
export class BrewService {
  /** 进程内缓存（`key -> 条目`）。首次访问从 Preference 读一次整份 */
  private static cache: Record<string, DetailCacheEntry<Object>> | undefined = undefined;
  private static cacheLoaded: boolean = false;
  private static cacheDirty: boolean = false;
  /** 世代号在操作入口捕获：清缓存之后本次写入必须丢弃 */
  private static epoch: number = BrewCacheEpoch.current();
  /** 会话级计数，一行汇总 */
  private static hits: number = 0;
  private static notModified: number = 0;
  private static downloaded: number = 0;
  private static failures: number = 0;

  /** 缓存条目的形状版本。归一规则变了就 +1，让旧条目自然当未命中 */
  private static readonly SCHEMA_VERSION: number = 1;

  /**
   * 清空进程内缓存。`BrewCacheAdmin.clear` 清激活源时必须调它，
   * 否则内存里的旧数据会在下一次写入时把盘上刚清掉的内容写回去。
   *
   * 世代号**保持原值**：它记的是「在场这一次取数是在哪个世代开始的」，`flush` 拿它
   * 与 `BrewCacheEpoch.current()` 比对来决定要不要丢弃。这里若改成新值，清空前发起、
   * 此刻仍在途的那一次会比对成功，把刚清掉的内容写回盘里。
   */
  public static resetMemoryCaches(): void {
    BrewService.cache = undefined;
    BrewService.cacheLoaded = false;
    BrewService.cacheDirty = false;
    BrewService.hits = 0;
    BrewService.notModified = 0;
    BrewService.downloaded = 0;
    BrewService.failures = 0;
    Logger.info(TAG, 'memory caches reset');
  }

  private static log(kind: string, detail: string): void {
    Logger.info(TAG, `${kind} ${detail} | ${BrewService.statsLine()}`);
  }

  /** 一行汇总（`[brew-load]` 与 hilog 对账用） */
  public static statsLine(): string {
    return `hit=${BrewService.hits} notModified=${BrewService.notModified} ` +
      `dl=${BrewService.downloaded} failed=${BrewService.failures}`;
  }

  // ------------------------------------------------------------ 详情

  /** 取单个 formula 的现网文档。**失败抛错**，由 `BrewFormulaModel` 决定回落 */
  public static fetchFormulaDoc(token: string): Promise<LiveFormulaDoc> {
    return BrewService.fetchDoc<LiveFormulaDoc>(BrewKindText.FORMULA, token);
  }

  /** 取单个 cask 的现网文档 */
  public static fetchCaskDoc(token: string): Promise<LiveCaskDoc> {
    return BrewService.fetchDoc<LiveCaskDoc>(BrewKindText.CASK, token);
  }

  /**
   * 带条件请求的单条取数。
   *
   * 顺序：TTL 窗口内直接用 → 带 `If-Modified-Since` 请求 → 304 就 0 字节续期 →
   * 200 就解析返回。失败时把错误抛给调用方（不静默吞），否则日志里看不到
   * 「现网挂了」，只看到页面一直显示旧值。
   */
  private static fetchDoc<T>(kind: string, token: string): Promise<T> {
    const cacheKey: string = `${kind}_${token}`;
    const cache: Record<string, DetailCacheEntry<Object>> = BrewService.ensureCache();
    const hit: DetailCacheEntry<Object> | undefined = cache[cacheKey];
    if (hit !== undefined && BrewService.isFresh(hit)) {
      BrewService.hits++;
      BrewService.log(kind, `cache hit, key=${cacheKey}, age=${Math.floor((Date.now() - hit.ts) / 1000)}s`);
      BrewLoadLog.info('detail_doc', 'cache-hit', 0,
        `kind=${kind} token=${token} age=${Math.floor((Date.now() - hit.ts) / 1000)}s / ${BREW_LIVE_FRESH_MS}ms`);
      return Promise.resolve(hit.data as T);
    }
    // 超窗但有基准：带条件请求重问，而不是直接重下。这是详情页唯一会发请求的路径，
    // 走之前先打 debug，说明为什么这次没有直接用缓存
    if (hit !== undefined) {
      BrewLoadLog.debug('detail_doc', 'out-of-window', 0,
        `kind=${kind} token=${token} age=${Math.floor((Date.now() - hit.ts) / 1000)}s ` +
        `schemaOk=${hit.schemaVersion === BrewService.SCHEMA_VERSION} → 带 If-Modified-Since 重问`);
    }
    // 世代号在**操作入口**捕获：这次写入会刷盘
    BrewService.epoch = BrewCacheEpoch.current();
    const headers: Record<string, string> = {};
    if (hit !== undefined && hit.lastModified.length > 0) {
      headers['If-Modified-Since'] = hit.lastModified;
    }
    const adapter: BrewSourceAdapter =
      adapterFor(BrewSourceStore.dialectOf(BrewSourceStore.sessionActive().id));
    // 单条文档的三条结局（缓存命中 / 304 续期 / 下载）都在 `fetchDoc` 里，
    // 每一轮都打一行 `detail_doc`，于是「详情页到底发没发请求」不用再数 `BrewHttp` 的行
    Logger.debug(TAG, `[detail] ${cacheKey} → fetch ifModifiedSince=[${headers['If-Modified-Since'] ?? ''}]`);
    return adapter.fetchDoc(BrewSourceStore.activeBaseUrl(), token, kind, headers)
      .then((res: BrewHttpResult) => {
        if (res.code === 304 && hit !== undefined) {
          hit.ts = Date.now();
          cache[cacheKey] = hit;
          BrewService.cacheDirty = true;
          BrewService.notModified++;
          BrewService.log(kind, `cache revalidated 304, key=${cacheKey}`);
          BrewLoadLog.info('detail_doc', 'not-modified', 0,
            `kind=${kind} token=${token} 0B 续期，条目时间戳已推进`);
          return hit.data as T;
        }
        if (res.code === 404 || res.code === 410) {
          // 404/410 = 上游确认没这个包（详情页可能被历史链接、旧的分类或自定义 tap 的包带进来）。
          // 抛专用类型，让详情页显示「未找到」而不是回退到骨架
          Logger.info(TAG, `doc absent upstream (${res.code}), key=${cacheKey}`);
          BrewLoadLog.warn('detail_doc', 'absent', 0, `kind=${kind} token=${token} 上游返回 ${res.code}`);
          throw new BrewDocAbsentError(kind, token, res.code);
        }
        if (res.code !== 200) {
          Logger.info(TAG, `doc unexpected status (${res.code}), key=${cacheKey}`);
          throw new Error(`unexpected status ${res.code}`);
        }
        const entry: DetailCacheEntry<Object> = {
          ts: Date.now(),
          schemaVersion: BrewService.SCHEMA_VERSION,
          lastModified: res.headers['last-modified'] ?? '',
          data: JSON.parse(res.text) as Object,
        };
        cache[cacheKey] = entry;
        BrewService.cacheDirty = true;
        BrewService.downloaded++;
        BrewService.log(kind, `downloaded, key=${cacheKey}, cond=${headers['If-Modified-Since'] !== undefined}`);
        BrewLoadLog.info('detail_doc', 'downloaded', 0,
          `kind=${kind} token=${token} bytes=${res.text.length} ` +
          `lastModified=[${entry.lastModified}]`);
        return entry.data as T;
      })
      .then((doc: T) => {
        BrewService.flush();
        return doc;
      })
      .catch((error: Error) => {
        // 「数据源里没有这个包」是确定结论，不算取数失败：不计数、不打 fetch-failed
        if (error instanceof BrewDocAbsentError) {
          throw error;
        }
        BrewService.failures++;
        Logger.error(TAG, `fetch failed, key=${cacheKey}, ${error.message}`);
        BrewLoadLog.warn('detail_doc', 'fetch-failed', 0, `kind=${kind} token=${token} ${error.message}`);
        throw error;
      });
  }

  private static isFresh(entry: DetailCacheEntry<Object>): boolean {
    const age: number = Date.now() - entry.ts;
    return entry.schemaVersion === BrewService.SCHEMA_VERSION && age >= 0 && age < BREW_LIVE_FRESH_MS;
  }

  private static ensureCache(): Record<string, DetailCacheEntry<Object>> {
    if (!BrewService.cacheLoaded) {
      BrewService.cacheLoaded = true;
      const t0: number = Date.now();
      const stored: Record<string, DetailCacheEntry<Object>> | null =
        BrewSourcePrefs.get<Record<string, DetailCacheEntry<Object>>>(BREW_DETAIL_CACHE_KEY);
      BrewService.cache = stored ?? {};
      const entries: number = objKeys(BrewService.cache).length;
      const fresh: number = BrewService.countFresh();
      Logger.info(TAG, `detail cache loaded, ${entries} entries, fresh=${fresh}`);
      BrewLoadLog.info('detail_cache', stored === null ? 'missing' : 'pref', Date.now() - t0,
        `entries=${entries} fresh=${fresh}`);    }
    return BrewService.cache ?? {};
  }

  private static countFresh(): number {
    const cache: Record<string, DetailCacheEntry<Object>> = BrewService.cache ?? {};
    let fresh: number = 0;
    objKeys(cache).forEach((key: string) => {
      if (BrewService.isFresh(cache[key])) {
        fresh++;
      }
    });
    return fresh;
  }

  /**
   * 刷盘。世代号在 `fetchDoc` 入口捕获，**不在这里改写** ——
   * 改写等于「只保护 bump 后的第一次写入」，同一批里更廉价的写入会把配额用掉。
   */
  private static flush(): void {
    if (!BrewService.cacheDirty) {
      return;
    }
    if (BrewService.epoch !== BrewCacheEpoch.current()) {
      BrewService.cacheDirty = false;
      Logger.info(TAG, '[BrewCache] epoch mismatch, dropped write key=brew_detail_cache');
      return;
    }
    const cache: Record<string, DetailCacheEntry<Object>> = BrewService.cache ?? {};
    BrewSourcePrefs.set<Record<string, DetailCacheEntry<Object>>>(BREW_DETAIL_CACHE_KEY, cache);
    BrewService.cacheDirty = false;
    // `set` 只写进 GSKV 的内存缓存页，必须显式刷盘，否则进程被回收就丢
    BrewSourcePrefs.persistNow();
    Logger.info(TAG, `detail cache flushed, ${objKeys(cache).length} entries`);
  }

  // ------------------------------------------------------------ 视图缓存（归一后的详情）

  /** 上一次成功归一过的详情。现网失败时的回落 */
  public static cachedDetail<T>(componentId: number): T | null {
    const stored: Record<string, T> | null = BrewSourcePrefs.get<Record<string, T>>(BREW_DETAIL_VIEW_KEY);
    if (stored === null) {
      return null;
    }
    const value: T | undefined = stored[`${componentId}`];
    return value ?? null;
  }

  /** 写入归一后的详情（与单条缓存同一份存储，不同 key） */
  public static saveDetail<T>(componentId: number, data: T): void {
    const stored: Record<string, T> = BrewSourcePrefs.get<Record<string, T>>(BREW_DETAIL_VIEW_KEY) ?? {};
    stored[`${componentId}`] = data;
    BrewSourcePrefs.set<Record<string, T>>(BREW_DETAIL_VIEW_KEY, stored);
    BrewSourcePrefs.persistNow();
  }

  /**
   * 只读访问 store 里的 raw 单条文档（release intel 的 diff 基线预捕获用，
   * spec §3.1：store 缓存是覆盖式的，已装版本的 raw 必须在新抓取前抢救出来）。
   * 返回 raw JSON 文本；无条目 / schema 不符 → 空串。**只读**，不动 ts/lastModified。
   */
  public static cachedRawDocJson(kind: string, token: string): string {
    const cacheKey: string = `${kind}_${token}`;
    const cache: Record<string, DetailCacheEntry<Object>> = BrewService.ensureCache();
    const hit: DetailCacheEntry<Object> | undefined = cache[cacheKey];
    if (hit === undefined || hit.schemaVersion !== BrewService.SCHEMA_VERSION) {
      return '';
    }
    try {
      return JSON.stringify(hit.data);
    } catch (err) {
      return '';
    }
  }

  // ------------------------------------------------------------ 包表转发

  /** 目录里的 30 天安装量。详情页降级骨架用它在没有单条文档时仍能显示数字 */
  public static catalogInstallsOf(kind: string, token: string): number {
    return BrewTable.installCount(kind, token);
  }

  public log(message: string): void {
    Logger.debug(TAG, message);
  }
}