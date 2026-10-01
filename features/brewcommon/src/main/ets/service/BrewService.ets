/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { Logger } from '@ohos/common';
import { BrewSourcePrefs } from './BrewSourcePrefs';
import {
  BREW_BROWSE_HYDRATE_LIMIT,
  BREW_BROWSE_HYDRATE_MS,
  BREW_CATALOG_FRESH_MS,
  BREW_CATALOG_KEEP,
  BREW_CATALOG_STORAGE_KEY,
  BREW_CATALOG_TIMEOUT_MS,
  BREW_CATALOG_TOP_N,
  BREW_HYDRATE_CONCURRENCY,
  BREW_HYDRATE_TIMEOUT_MS,
  BREW_INDEX_MIN_TRUST,
  BREW_LOAD_SLOW_MS,
  BREW_PERF_TRACE,
  CASK_CATEGORY_ORDER,
  FORMULA_CATEGORY_ORDER,
  BREW_LIVE_DATASET_KEY,
  BREW_LIVE_FRESH_MS,
  BREW_LIVE_STORAGE_KEY,
  BREW_MISS_TTL_MS,
  BREW_PAGE_INFLIGHT_JOIN_MS,
} from '../constant/BrewConstants';
import { BrewHttp } from './BrewHttp';
import type { BrewHttpResult } from './BrewHttp';
import { BrewCatalogFile } from './BrewCatalogFile';
import { BREW_DIALECT_HARMONYBREW } from '../constant/BrewSourceConstants';
import {
  BrewCatalogAlgo,
  BREW_CATALOG_BOARDS,
  CatalogSource,
  catalogSources,
} from './BrewCatalogAlgo';
import { BrewSourceStore } from './BrewSourceStore';
import { adapterFor } from './source/BrewSourceAdapter';
import type { BrewSourceAdapter } from './source/BrewSourceAdapter';
import type { BrewCatalogInput } from './source/BrewCatalogInput';
import { BrewSourceUrl } from './BrewSourceUrl';
import { BrewBrowseBuilder } from './BrewBrowseBuilder';
import { BrewLoadLog } from '../util/BrewLoadLog';
import { BrewNetNotice } from '../util/BrewNetNotice';
import { BrewMetaSync } from './BrewMetaSync';
import { BrewCacheEpoch } from './BrewCacheEpoch';
import { BrewTaxonomy } from '../constant/BrewTaxonomy';
import type {
  CatalogAnalyticsDoc,
  CatalogCounts,
  CatalogKindResult,
  CatalogRecord,
} from './BrewCatalogAlgo';
import { catalogThresholdsFor } from '../constant/BrewCatalogThresholds';
import type { CatalogThresholds } from '../constant/BrewCatalogThresholds';
import type { LiveCaskDoc, LiveFormulaDoc } from './BrewApiMapper';
import type {
  BrewCaskDetail,
  BrewCaskCard,
  BrewCaskCategory,
  BrewCaskPageData,
  BrewCategoryCard,
  BrewFormulaDetail,
  BrewFormulaPageData,
  BrewPackageItem,
  BrewPageData,
} from '../model/BrewModels';

const TAG: string = '[BrewService]';

/**
 * 现网文档的缓存条目。
 *
 * `etag` / `lastModified` 是**条件请求的依据**：过期后不再盲重下，而是带着它们
 * 问一句“变了吗”（304 则 0 字节续期），所以这两个字段必须跟 doc 一起落盘。
 */
interface LiveCacheEntry {
  ts: number;
  doc: Object;
  /** 服务端 ETag（含引号，原样回传） */
  etag?: string;
  /** 服务端 Last-Modified */
  lastModified?: string;
}

/**
 * 取数来源计数（会话级）。
 *
 * 为什么需要它：接现网后“到底走的是哪条路”是本层最难验证、也最容易出错的事（缓存？探针续期？
 * 条件请求？真下载？），而逐 key 打日志会产生数百行并让日志管道丢行（真机上已经丢过）。
 * 改成本计数 + 每批一行汇总 → 一条 grep 就能对账。
 */
interface LiveFetchStats {
  /** 新鲜窗口内直接命中 */
  hit: number;
  /** 过期后由数据集探针（HEAD 304）整批续期 */
  renewed: number;
  /** 条件请求 304（0 字节续期） */
  notModified: number;
  /** 真的下载并解析了全文 */
  downloaded: number;
  /** 下载时**带了**条件头（说明服务端 ETag 变了或未按预期返 304） */
  downloadedWithCond: number;
  /** 下载时**没带**条件头（说明本地根本没存到 ETag/Last-Modified） */
  downloadedNoCond: number;
  /** 失败（上层会回落到快照值） */
  failed: number;
  /** 目录（聚合端点）取数失败次数 */
  catalogFailed: number;
}

/** 缺失 token 的拆分结果：值得发请求的 + 被负缓存挡下的（幽灵）数量 */
interface MissingSplit {
  tokens: string[];
  ghosts: number;
}

/** 目录里一个榜的一条：只有 token 与数字。`id` / `desc` / `categoryKey` 由 join 时补 */
export interface CatalogEntry {
  token: string;
  vol30d: number;
  vol365d: number;
  /** 此前 11 个月的月均。0 = 无历史（新包） */
  prior: number;
  velocity: number;
  /** 仅趋势榜有意义，其余榜为 0 */
  score: number;
}

/** 一个 kind 的窗口与规模元信息（目录 meta，外加门槛实测值） */
export interface CatalogKindMeta {
  windowStart: string;
  windowEnd: string;
  totalItems: number;
  totalCount: number;
  rawTokens: number;
  families: number;
  candidates: number;
  thresholds: CatalogThresholds;
  /** 实际分位数（与门槛对比，看基数是否漂移） */
  actualVolP: number;
  actualPriorP: number;
  multiEntryTokens: number;
}

/** 设备端目录（落盘一份，进程内一份） */
export interface BrewCatalog {
  ts: number;
  /** 本次刷新是否 4/4 都是 304（0 字节续期） */
  allNotModified: boolean;
  tookMs: number;
  /** 聚合端点的 Last-Modified（key = url），下次条件请求的基准 */
  stamps: Record<string, string>;
  meta: Record<string, CatalogKindMeta>;
  /** `[kind][boardKey] -> 条目[]`，落盘量 = KEEP（> 展示量，给 join 过滤留补位余量） */
  boards: Record<string, Record<string, CatalogEntry[]>>;
  /**
   * `[kind] -> 按 30d 安装量降序的 token[]`，落盘量 = BROWSE_KEEP。
   *
   * 浏览页的成员来源：榜单要的是"涨得快"，浏览要的是"装得多"，所以两者共用同一份目录、
   * 不同的排序。落盘上限（200）> 浏览上限（100）是为了留冗余，不必为浏览重新拉目录。
   */
  topTokens: Record<string, CatalogEntry[]>;
}

/** 一次目录取数的目标端点（与 catalogSources() 同型，直接用同一接口） */
type CatalogFetchJob = CatalogSource;

/** 一个端点的探测/取数结果 */
interface CatalogProbeResult {
  job: CatalogFetchJob;
  code: number;
  text: string;
  lastModified: string;
}

/** 数据集版本戳（每个 kind 一份）。
 *
 * 实测：**单条文件的 `Last-Modified` 与全量 `formula.json` 完全相同**
 * （都是 `Fri, 18 Sep 2026 02:53:14 GMT`，即整批一次性生成），所以一个 HEAD 探针就能代表全部 240 个文件。
 */
interface DatasetStamp {
  lastModified: string;
  etag: string;
}

/**
 * Homebrew 数据服务。
 *
 * 2026-10 起只有**一条通道**（原先的「内置快照」通道已整条删除，见 `BrewConstants` 顶部注释）：
 *   - **设备端目录**（聚合端点，`BrewCatalogAlgo`）：全量宇宙的安装量与三张榜 → 榜成员、
 *     分类内成员、搜索词池、详情页的安装量；
 *   - **现网单条**（`BrewHttp` 请求 formulae.brew.sh 的 `/api/<kind>/<token>.json`）：
 *     官方字段（版本/依赖/分析量/artifacts）—— 目录里没有这些。
 *
 * 上层（Repository / VM / UI）不需要知道成员是从哪来的 —— 签名与返回类型完全不变，
 * 这正是 docs/brew-api-design.md §7 预留的改动面。目录拿不到时**返回 `undefined` / 空页**
 * 而不是抛错，由 UI 走空态（与 docs/brew-api-design.md 的 C 档口径一致）。
 *
 * **页面加载路径**严禁请求 `formula.json` / `cask.json`（解压后 32.4 MB，见 §7），
 * 只允许单条 `/formula/<token>.json`（~5 KB）与 `/analytics/*`（已按需缓存）；
 * 全量包只给**后台同步**用（`BrewMetaSync`：不阻塞页面、只抽 `token → desc`）。
 */
export class BrewService {
  public static readonly DETAIL_PAGE_DATA: string = 'brew_detail_page_data';

  /**
   * 重置**全部**进程内缓存。清空当前激活源的缓存时必须调它，否则内存里的旧数据
   * 会在下一次 flush 时把盘上刚清掉的内容写回去。
   *
   * 注意 `activeHydrates` **不强制清零**：可能有在途批次正在跑，强清会破坏它的计数配对。
   * 在途写入靠 `BrewCacheEpoch` 丢弃，不需要动这个计数。
   */
  public static resetMemoryCaches(): void {
    BrewService.liveCache = undefined;
    BrewService.cacheDirty = false;
    BrewService.datasetStamps = undefined;
    BrewService.stampsDirty = false;
    BrewService.probeCache.clear();
    BrewService.missCache.clear();
    BrewService.inFlight.clear();
    BrewService.degradedWarned = {};
    BrewService.stats = { hit: 0, renewed: 0, notModified: 0, downloaded: 0, downloadedWithCond: 0,
      downloadedNoCond: 0, failed: 0, catalogFailed: 0 };
    BrewService.catalog = undefined;
    BrewService.catalogLoaded = false;
    BrewService.catalogInFlight = undefined;
    // 作废在途页面构建：自增序号后，旧构建完成时不会清掉新构建的在途字段
    BrewService.formulaPageInFlightId++;
    BrewService.formulaPageInFlight = undefined;
    BrewService.formulaPageInFlightPageSize = 0;
    BrewService.formulaPageInFlightAt = 0;
    BrewService.caskPageInFlightId++;
    BrewService.caskPageInFlight = undefined;
    BrewService.caskPageInFlightPageSize = 0;
    BrewService.caskPageInFlightAt = 0;
    Logger.info(TAG, 'memory caches reset');
  }

  /**
   * 现网文档的进程内缓存（`token -> {ts, doc}`）。
   *
   * 为什么不用 `PreferenceCacheHelper` 的逐 key 读写：一个页面要 hydrate 100 个 token，
   * 逐 key 写会在每次 `putSync` 时序列化并刷盘整份 Record（~1.5MB × 100 次）。
   * 这里改成“内存一份 + 批次结束刷一次”，见 getLiveDoc / flushCache。
   */
  private static liveCache: Record<string, LiveCacheEntry> | undefined = undefined;
  private static cacheDirty: boolean = false;
  private static flushEpoch: number = BrewCacheEpoch.current();
  private static catalogEpoch: number = BrewCacheEpoch.current();
  private static stampEpoch: number = BrewCacheEpoch.current();
  /** 正在跑的 hydrate 批次数（> 0 时单条请求不自己刷盘） */
  private static activeHydrates: number = 0;
  /**
   * 在途请求（`cacheKey -> Promise<entry>`）。
   *
   * **为什么必须有这个**：缓存只有在响应回来后才写入，而同一个 URL 会被多次请求：
   *   1. 页面加载本身会被触发两次（既有行为，相隔 ~130ms；Mock 时读两遍 rawfile 看不出来）；
   *   2. 三个页签并发预加载，token 集合有交集（Discover 榜上的包也出现在 Formulae/Casks 页）；
   *   3. 详情页的 alignCategoryRank / 同分类其他包也会触发整页 hydrate。
   * 只做“批内去重”挡不住这些——第二批查缓存时第一批还在飞，于是同一 URL 发出两份请求。
   * 这里让第二个调用者**直接复用在飞的 Promise**，重复请求才是真地归零。
   * 命中时会打 `live request joined` 日志，所以“到底重没重”是可量的。
   */
  private static inFlight: Map<string, Promise<LiveCacheEntry>> = new Map<string, Promise<LiveCacheEntry>>();

  /** 数据集版本戳（kind -> stamp），与缓存一起落盘；没有基准时探针无从判断“是否变过” */
  private static datasetStamps: Record<string, DatasetStamp> | undefined = undefined;
  private static stampsDirty: boolean = false;
  /** 本次会话的数据集探针结果（kind -> Promise<是否仍新鲜>），每个 kind 只发一次 HEAD */
  private static probeCache: Map<string, Promise<boolean>> = new Map<string, Promise<boolean>>();
  /**
   * 负缓存：`formula_<token>` -> 首次确认“上游没这个包”的时间。
   *
   * 为什么必须有：目录（analytics，含下线/改名史）与索引（当前 formula/cask.json）的差集里，
   * 有相当一部分是上游已不存在的幽灵 token。逐条拉必然 404，而 404 不会写进 `brew_live_data`
   * （失败不缓存）——不记住它就变成“每轮页面重绘重打一遍 404”，把首屏拖到秒级（真机实测 4.8s）。
   * 只记确定性失败（404/410），瞬时失败不记，见 `markMissing`。
   */
  private static missCache: Map<string, number> = new Map<string, number>();
  /**
   * 降级路径的 warn 每个 kind 只打一次。
   *
   * 为什么需要去重：首页会被构建两次（`HdsNavigation` 根内容 + push 进去的 ListView 各渲染
   * 一份 BaseView，两份 `aboutToAppear` 都派发 LOAD），不去重就会把同一件事打两遍，
   * 反而看不出“是不是发生了两次不同的失败”。
   */
  private static degradedWarned: Record<string, boolean> = {};
  /** 取数来源计数（会话级），见 LiveFetchStats */
  private static stats: LiveFetchStats =
    { hit: 0, renewed: 0, notModified: 0, downloaded: 0, downloadedWithCond: 0, downloadedNoCond: 0, failed: 0,
      catalogFailed: 0 };

  /** 设备端目录的进程内副本（与 Preference 同步，见 ensureCatalog / saveCatalog） */
  private static catalog: BrewCatalog | undefined = undefined;
  private static catalogLoaded: boolean = false;
  /** 在途的目录刷新（并发调用直接复用，避免同一批聚合端点被拉两次） */
  private static catalogInFlight: Promise<BrewCatalog | undefined> | undefined = undefined;

  /**
   * 在途的浏览页构建。**同一页会被构建两次**：`BrewFormulaHomeView` 同时渲染了
   * `HdsNavigation` 的根内容与 push 进去的 `BrewFormulaListView` 两份 `BrewFormulaBaseView`
   * （照抄参考实现的写法，组件页同样双载），两份的 `aboutToAppear` 都派发 `LOAD_FORMULA_PAGE`。
   * 不合并的话分类要算两遍（实测 2×420ms），降级路径下 hydrate 还要翻倍。
   *
   * 为什么用两个具名字段而不是 `Map<string, Promise<…>>`：ArkTS 对泛型/`unknown` 的 `as`
   * 转换比 TS 严，用 Map 就得在取出时转型 —— 那是"编译期过、运行期才暴露"的写法。
   */
  private static formulaPageInFlight: Promise<BrewPageData<BrewFormulaPageData> | undefined> | undefined =
    undefined;
  private static formulaPageInFlightPageSize: number = 0;
  private static formulaPageInFlightAt: number = 0;
  /** 递增序号：只有"当前这一个"完成时才允许清空在途字段（理由见下方 tracked 处注释） */
  private static formulaPageInFlightId: number = 0;
  private static caskPageInFlight: Promise<BrewPageData<BrewCaskPageData> | undefined> | undefined =
    undefined;
  private static caskPageInFlightPageSize: number = 0;
  private static caskPageInFlightAt: number = 0;
  private static caskPageInFlightId: number = 0;

  /*
   * ⚠ **join 的两个条件缺一不可**：
   *   - `PageSize` 必须相同 —— 首页是 `BaseHomeViewModel.pageSize = 30`，而详情页
   *     `alignCategoryRank` / 分类二级页走 `SIBLING_PAGE_SIZE = 100`，**两者今天就会并发**；
   *     pageSize 不同却复用同一份，信封里的 `pageSize/totalSize` 就是错的那一份。
   *   - `At` 必须没超时（见 `BREW_PAGE_INFLIGHT_JOIN_MS`）—— 否则一个永不 settle 的构建
   *     会把页面永久卡在 LOADING，而重试按钮也 join 同一个死 Promise。
   *
   * ⚠ **解析出的 page 对象是共享的**：多个调用方拿到同一个 `cards` 数组与同一批
   * `BrewPackageItem`（改动前每次构建都产出独立副本）。目前所有消费点都是只读
   * （`setDataArray` 只存引用、仓库层只 `find/filter/slice`），所以输出不变；
   * 但**将来任何一处对 `formulaContents` 做 `sort`/`splice` 就会污染另一个视图** —— 消费者必须只读。
   */

  /** 一行汇总，拼在 hydrate 日志后面；排查“走的哪条路”就看它 */
  public static statsLine(): string {
    const s: LiveFetchStats = BrewService.stats;
    return `session hit=${s.hit} renewed=${s.renewed} notModified=${s.notModified} ` +
      `dl=${s.downloaded}(cond=${s.downloadedWithCond} nocond=${s.downloadedNoCond}) failed=${s.failed} ` +
      `catalogFailed=${s.catalogFailed}`;
  }

  // ------------------------------------------------------------ 现网：单条详情

  /**
   * 拉单个 formula 的现网文档（`/api/formula/<token>.json`，实测 ~5 KB）。
   *
   * 带 TTL 缓存：命中且未过期则不发请求。缓存命中时也会打日志（`cache hit`），
   * 排查“到底走没走网络”时不用猜。
   */
  public getLiveFormulaDoc(token: string): Promise<LiveFormulaDoc> {
    return this.getLiveDoc<LiveFormulaDoc>(`formula_${token}`, 'formula', token);
  }

  /** 拉单个 cask 的现网文档（`/api/cask/<token>.json`） */
  public getLiveCaskDoc(token: string): Promise<LiveCaskDoc> {
    return this.getLiveDoc<LiveCaskDoc>(`cask_${token}`, 'cask', token);
  }

  /**
   * 现网 GET（带条件请求）+ 缓存。
   *
   * **新鲜度判定顺序**（这就是“主动 probe”的落地）：
   *   1. `ts` 在新鲜窗口内 → 直接用，零请求；
   *   2. 已有人在拉同一个 key → 复用在飞的 Promise（在途去重）；
   *   3. **数据集探针**（每个 kind 一次 HEAD，带 `If-Modified-Since`）：
   *      304 → 整批数据未变 → 续期（`ts = now`）返回旧 doc，**0 字节、不解析、不落盘**；
   *   4. 数据集变了（或探针失败/无基准）→ 对该 token 发**条件请求**
   *      （`If-None-Match`，无 ETag 则 `If-Modified-Since`）：
   *      304 → 0 字节续期；200 → 解析并落盘。
   *
   * 失败时把错误抛给调用方（由上层决定回落策略）—— 不在这里静默吞掉，
   * 否则日志里看不到“现网挂了”，只会看到页面一直显示旧值。
   */
  private getLiveDoc<T extends Object>(cacheKey: string, kind: string, token: string): Promise<T> {
    const cache: Record<string, LiveCacheEntry> = BrewService.ensureCache();
    const hit: LiveCacheEntry | undefined = cache[cacheKey];
    if (hit !== undefined && hit !== null && BrewService.isFresh(hit)) {
      Logger.info(TAG, `live cache hit, key=${cacheKey}, age=${Math.floor((Date.now() - hit.ts) / 1000)}s`);
      BrewService.stats.hit++;
      return Promise.resolve(hit.doc as T);
    }
    // 在途合并：同一个 token 已经有人在拉，就不要再发一份
    const pending: Promise<LiveCacheEntry> | undefined = BrewService.inFlight.get(cacheKey);
    if (pending !== undefined) {
      Logger.info(TAG, `live request joined in-flight, key=${cacheKey}`);
      return pending.then((entry: LiveCacheEntry) => entry.doc as T);
    }
    const task: Promise<LiveCacheEntry> = BrewService.datasetProbe(kind)
      .then((datasetFresh: boolean) => {
        if (datasetFresh && hit !== undefined && hit !== null) {
          // 整批没变：只动时间戳。不解析 JSON、不写 doc、不产生网络流量
          hit.ts = Date.now();
          cache[cacheKey] = hit;
          BrewService.cacheDirty = true;
          // 逐 key 降为 debug：240 条 info 会把日志管道刷爆（真机上已丢行），对账看 hydrate 汇总行
          Logger.debug(TAG, `live cache renewed by dataset probe, key=${cacheKey}`);
          BrewService.stats.renewed++;
          return hit;
        }
        return BrewService.conditionalFetch(cache, cacheKey, kind, token, hit);
      })
      .catch((error: Error) => {
        // 失败必须把在途占位清掉，否则这次失败会被后续调用者“复用”，一直拿不到重试机会
        BrewService.inFlight.delete(cacheKey);
        throw error;
      });
    BrewService.inFlight.set(cacheKey, task);
    return task.then((entry: LiveCacheEntry) => {
      BrewService.inFlight.delete(cacheKey);
      return entry.doc as T;
    });
  }

  /**
   * 带条件请求的取数：先问“变了吗”，再决定要不要拿全文。
   *
   * **用 `If-Modified-Since`（Last-Modified）而不是优先用 ETag** —— 这是实测得出的：
   * formulae.brew.sh 后面是 Fastly + GitHub Pages，同一 URL 在不同节点上会持有**不同代的副本**
   * （实测 `wget.json` 的 `Last-Modified` 有 `02:53:14` 与 `02:53:15` 两种、ETag 前缀就是源文件 mtime，
   * 响应头带 `Vary: Accept-Encoding`）。而 ETag 是**单个文件**的哈希，跨节点不一致 →
   * 带 `If-None-Match` 时命中率实测只有 1/5；而 `Last-Modified` 是**整批生成时间**，
   * 全量包探针上实测命中 4/5。所以顺序是 IMS 优先、ETag 兜底。
   *
   * 拿不到 304 也不是错误：说明该副本比我们的基准新，收下全文并更新基准就行（幂等）。
   */
  private static conditionalFetch(cache: Record<string, LiveCacheEntry>, cacheKey: string, kind: string,
    token: string, hit: LiveCacheEntry | undefined): Promise<LiveCacheEntry> {
    // 世代号在**操作入口**捕获：这一次条件请求会写单条 doc，并可能经 `rememberStamp`
    // 写 `brew_live_dataset`。清空发生在这之前的话，这次的结果必须丢弃。
    // 它是所有单条 doc 取数的共同起点（hydrate 各条、详情页、索引校验都走它）。
    BrewService.stampEpoch = BrewCacheEpoch.current();
    const headers: Record<string, string> = {};
    if (hit?.lastModified !== undefined && hit.lastModified.length > 0) {
      headers['If-Modified-Since'] = hit.lastModified;
    } else if (hit?.etag !== undefined && hit.etag.length > 0) {
      headers['If-None-Match'] = hit.etag;
    }
    const sourceId: string = BrewSourceStore.sessionActive().id;
    const adapter: BrewSourceAdapter = adapterFor(BrewSourceStore.dialectOf(sourceId));
    return adapter.fetchDoc(BrewSourceStore.activeBaseUrl(), token, kind, headers)
      .then((res: BrewHttpResult) => {
      if (res.code === 304 && hit !== undefined) {
        hit.ts = Date.now();
        cache[cacheKey] = hit;
        BrewService.cacheDirty = true;
        Logger.debug(TAG, `live cache revalidated 304, key=${cacheKey}`);
        BrewService.stats.notModified++;
        return hit;
      }
      if (res.code !== 200) {
        // 404/410 = 上游确认没这个包（目录里的幽灵 token）。记下来，别再每轮重绘都试一遍。
        // 其他非 200（429/5xx …）是“这次不行”，不记 —— 下次照旧重试。
        if (res.code === 404 || res.code === 410) {
          BrewService.markMissing(cacheKey);
          Logger.info(TAG, `live doc absent upstream (${res.code}), negative-cached, key=${cacheKey}`);
        }
        throw new Error(`unexpected status ${res.code}`);
      }
      const entry: LiveCacheEntry = {
        ts: Date.now(),
        doc: JSON.parse(res.text) as Object,
        etag: res.headers['etag'] ?? '',
        lastModified: res.headers['last-modified'] ?? '',
      };
      cache[cacheKey] = entry;
      BrewService.cacheDirty = true;
      BrewService.stats.downloaded++;
      if (Object.keys(headers).length > 0) {
        BrewService.stats.downloadedWithCond++;
      } else {
        BrewService.stats.downloadedNoCond++;
      }
      // 单条响应的 Last-Modified 与全量包相同 → 冷启动（无基准）时也能顺便建立探针基准
      BrewService.rememberStamp(kind, entry.lastModified ?? '', res.headers['etag'] ?? '');
      if (BrewService.activeHydrates === 0) {
        BrewService.flushCache();
      }
      return entry;
    });
  }

  /**
   * 数据集探针：**一次 HEAD 代表整批**。
   *
   * 为什么能用一次请求代表 240 个文件：实测单条文件与全量包的 `Last-Modified` 完全相同，
   * 说明整批数据是一次性生成的。所以只要问“`formula.json` 变了吗”，就知道整批要不要重校。
   * 用 `Last-Modified` + `If-Modified-Since` 而不是 ETag：ETag 是单个文件的（32 MB 的哈希），
   * 且**跨节点不一致**（实测同一 URL 在不同 POP 上 ETag/Last-Modified 差 1 秒），
   * 而“批次时间”才是我们要问的东西。
   *
   * 实测（curl，5 次）：HEAD + IMS 探针 `304 304 304 304 200` —— 源站在持续重新生成，
   * 所以探针会说“变了”并不罕见；变了就走条件请求（大多数仍是 0 字节的 304）。
   *
   * 三种返回：
   *   - `true`  数据集未变（304）→ 调用方直接续期；
   *   - `false` 数据集变了 / 没有基准 / 探针失败 → 调用方走条件请求（不会比现在更差）。
   * 探针失败**不当错误**：它只是优化手段，失败就退化成原来的行为。
   */
  private static datasetProbe(kind: string): Promise<boolean> {
    const sourceId: string = BrewSourceStore.sessionActive().id;
    if (BrewSourceStore.dialectOf(sourceId) === BREW_DIALECT_HARMONYBREW) {
      // Harmonybrew 没有全量 HEAD 端点；详情来自本进程启动时落盘的目录。
      // 目录完整时直接续期缓存，目录尚未就绪时交给 fetchDoc 返回 503 并允许重试。
      const hasCatalog: boolean = BrewCatalogFile.has(sourceId);
      Logger.info(TAG, `dataset probe: ${kind} ${hasCatalog ? 'unchanged (local catalog)' : 'not ready (local catalog)'}`);
      return Promise.resolve(hasCatalog);
    }
    const cached: Promise<boolean> | undefined = BrewService.probeCache.get(kind);
    if (cached !== undefined) {
      return cached;
    }
    const stamp: DatasetStamp | undefined = BrewService.ensureStamps()[kind];
    if (stamp === undefined || stamp.lastModified.length === 0) {
      // 没有基准（首次运行 / 缓存被清 / 上一轮没拿到响应头）→ 无从判断，不走探针
      return Promise.resolve(false);
    }
    const headers: Record<string, string> = { 'If-Modified-Since': stamp.lastModified };
    const task: Promise<boolean> = BrewHttp.head(
      BrewSourceUrl.join(BrewSourceStore.activeBaseUrl(), `/${kind}.json`), headers)
      .then((res: BrewHttpResult) => {
        if (res.code === 304) {
          Logger.info(TAG, `dataset probe: ${kind} unchanged (304, 0B)`);
          return true;
        }
        if (res.code === 200) {
          const next: string = res.headers['last-modified'] ?? '';
          Logger.info(TAG, `dataset probe: ${kind} CHANGED, ${stamp.lastModified} -> ${next}`);
          BrewService.rememberStamp(kind, next, res.headers['etag'] ?? '');
          return false;
        }
        Logger.error(TAG, `dataset probe: ${kind} unexpected status ${res.code}`);
        return false;
      })
      .catch((error: Error) => {
        // 探针失败不影响正确性，只是少了优化。清掉占位，下次调用可以重试
        Logger.error(TAG, `dataset probe failed, kind=${kind}, ${error.message}`);
        BrewService.probeCache.delete(kind);
        return false;
      });
    BrewService.probeCache.set(kind, task);
    return task;
  }

  /** `formula_wget` / `cask_google-chrome` 这类 key 的类别前缀 */
  private static kindOf(cacheKey: string): string {
    return cacheKey.startsWith('cask_') ? 'cask' : 'formula';
  }

  /**
   * 记下“上游确认没有这个包”。**只用于确定性失败**（404 / 410）。
   *
   * 超时（`2300028`）、断网、TLS 抽风这类都不算：那些是“这次没拿到”，不是“没有”，
   * 记进去会让网络恢复后也拿不到东西。
   */
  private static markMissing(cacheKey: string): void {
    BrewService.missCache.set(cacheKey, Date.now());
  }

  /** 是否已被判定为“上游没有”（且负缓存未过期；过期时顺手清掉，让它重新有机会被拉到） */
  private static isKnownMissing(cacheKey: string): boolean {
    const ts: number | undefined = BrewService.missCache.get(cacheKey);
    if (ts === undefined) {
      return false;
    }
    if (Date.now() - ts >= BREW_MISS_TTL_MS) {
      BrewService.missCache.delete(cacheKey);
      return false;
    }
    return true;
  }

  /**
   * 把“索引里缺的 token”拆成两份：值得发请求的 + 被负缓存挡下的幽灵数量。
   *
   * **窗口是位置的，不是“跳过后再补”的**：先按目录顺序（安装量降序）取前
   * `BREW_BROWSE_HYDRATE_LIMIT` 个缺失 token，再在窗口内剔除已知幽灵。
   * 否则会退化成“剥洋葱”：每轮重绘跳过已验证的、再试下一批 100 个，
   * 于是一个会话里把上千个必然 404 的 token 全试一遍，而且每轮都把首屏拖到秒级
   * （真机实测：cask 一轮 8s，因为那 100 个是**新**的 404，而不是缓存命中）。
   *
   * 代价：排在窗口外的“上游新增但还没进索引”的包要等下一次同步（进程启动即跑，5s 量级）
   * 才会出现 —— 而同步本来就是权威口径，hydrate 只是它还没跑完时的补位。
   */
  private static splitMissing(rows: CatalogEntry[], descIndex: Record<string, string>,
    kind: string): MissingSplit {
    const out: MissingSplit = { tokens: [], ghosts: 0 };
    const window: CatalogEntry[] = rows
      .filter((row: CatalogEntry) => descIndex[row.token] === undefined)
      .slice(0, BREW_BROWSE_HYDRATE_LIMIT);
    window.forEach((row: CatalogEntry) => {
      if (BrewService.isKnownMissing(`${kind}_${row.token}`)) {
        out.ghosts++;
        return;
      }
      out.tokens.push(row.token);
    });
    return out;
  }

  /** 日志尾缀：本轮有多少幽灵 token 被负缓存挡下了（为 0 时不打印） */
  private static ghostSuffix(split: MissingSplit): string {
    return split.ghosts > 0 ? `, ghosts ${split.ghosts} skipped` : '';
  }

  /** [perf] 分段耗时尾缀。`BREW_PERF_TRACE` 关闭时返回空串，让正常日志不被污染 */
  private static perfSuffix(tStart: number, tCatalog: number, tIndex: number, tSplit: number): string {
    if (!BREW_PERF_TRACE) {
      return '';
    }
    const now: number = Date.now();
    return ` [perf tStart=${tStart} catalogMs=${tCatalog - tStart} indexMs=${tIndex - tCatalog} ` +
      `filterMs=${tSplit - tIndex} hydrate+classifyMs=${now - tSplit}]`;
  }

  /** `descOf` 的长度，用于“有没有可展示文案”的判据（口径仍在 `BrewBrowseBuilder.descOf`） */
  private static descLen(descIndex: Record<string, string>, token: string, docDesc?: string): number {
    return BrewBrowseBuilder.descOf(token, descIndex, docDesc).length;
  }

  /**
   * 浏览页构页完成后的 `[load]` 打点 + 降级 warn。两个 kind 共用一份：
   * 「为什么慢」的判据完全一样（`covered` 是否够闸门），分两份写必然漂移。
   */
  private static logPageLoad(kind: string, trusted: boolean, covered: number, total: number,
    tStart: number, tCatalog: number, tIndex: number, tSplit: number, detail: string): void {
    const buildMs: number = Date.now() - tStart;
    const reason: string = trusted ? 'index-trusted' : BrewService.degradedReason(covered);
    // 数据已就绪（本函数就在 `return page` 之前调用）→ 撤掉常驻提示。
    // 两个浏览页共用这一个函数，所以只需在这里接一次（与 `willFetch` 成对）。
    BrewNetNotice.settle(kind, 'catalog=' + total + ' index=' + covered + ' trusted=' + trusted);
    BrewLoadLog.info(kind, reason, buildMs,
      'catalog=' + total + ' index=' + covered + ' trusted=' + trusted + ' ' + detail +
      ' readCatalogMs=' + (tCatalog - tStart) + ' readIndexMs=' + (tIndex - tCatalog) +
      ' splitMs=' + (tSplit - tIndex) + ' hydrateClassifyMs=' + (Date.now() - tSplit));
    if (!trusted && BrewService.degradedWarned[kind] !== true) {
      BrewService.degradedWarned[kind] = true;
      BrewLoadLog.warn(kind, 'index-untrusted', buildMs,
        '索引只覆盖 ' + covered + '/' + total + ' 条（闸门 BREW_INDEX_MIN_TRUST=' +
        BREW_INDEX_MIN_TRUST + '）→ 走降级路径，逐条 hydrate，预计 5~15s；' +
        '根因通常是 brew_meta_index 没同步成功（看 kind=meta_index 那行的 reason）');
    }
  }

  private static isFresh(entry: LiveCacheEntry): boolean {
    const age: number = Date.now() - entry.ts;
    return age >= 0 && age < BREW_LIVE_FRESH_MS;
  }

  /**
   * 浏览页降级路径的 `[load]` reason（判据 #6）。
   *
   * **`logPageLoad` 与 H3 的 toast 必须同一口径** —— 两边各写一次三元表达式，改一处就会出现
   * 「日志说 degraded-prefix、toast 说 degraded-hydrate」这种对不上账的情况。
   */
  private static degradedReason(covered: number): string {
    return covered > 0 ? 'degraded-hydrate' : 'degraded-prefix';
  }

  /** 记下数据集版本戳。只向前走：新盖旧，避免并发响应把基准回拨到一个更早的批次 */
  private static rememberStamp(kind: string, lastModified: string, etag: string): void {
    if (lastModified.length === 0) {
      return;
    }
    // 世代号在 `conditionalFetch()` 入口捕获。**不在这里改写 epoch**（见 `BrewCacheEpoch` 注释）。
    if (BrewService.stampEpoch !== BrewCacheEpoch.current()) {
      Logger.info(TAG, '[BrewCache] epoch mismatch, dropped write key=brew_live_dataset');
      return;
    }
    const stamps: Record<string, DatasetStamp> = BrewService.ensureStamps();
    const current: DatasetStamp | undefined = stamps[kind];
    if (current !== undefined && current.lastModified.length > 0 && current.lastModified >= lastModified) {
      return;
    }
    stamps[kind] = { lastModified: lastModified, etag: etag };
    BrewService.stampsDirty = true;
    BrewService.probeCache.delete(kind);
  }

  /** 进程内缓存，首次访问时从 Preference 读一次整份 */
  private static ensureCache(): Record<string, LiveCacheEntry> {
    if (BrewService.liveCache === undefined) {
      const t0: number = Date.now();
      const stored: Record<string, LiveCacheEntry> | null =
        BrewSourcePrefs.get<Record<string, LiveCacheEntry>>(BREW_LIVE_STORAGE_KEY);
      BrewService.liveCache = stored ?? {};
      let withEtag: number = 0;
      let withLm: number = 0;
      let fresh: number = 0;
      const now: number = Date.now();
      Object.keys(BrewService.liveCache).forEach((key: string) => {
        const entry: LiveCacheEntry = BrewService.liveCache![key];
        if (entry.etag !== undefined && entry.etag.length > 0) {
          withEtag++;
        }
        if (entry.lastModified !== undefined && entry.lastModified.length > 0) {
          withLm++;
        }
        if (now - entry.ts < BREW_LIVE_FRESH_MS) {
          fresh++;
        }
      });
      const entries: number = Object.keys(BrewService.liveCache).length;
      Logger.info(TAG, `live cache loaded, ${entries} entries ` +
        `(etag=${withEtag} lastModified=${withLm})`);
      BrewLoadLog.info('live_data', stored === null ? 'missing' : 'pref', Date.now() - t0,
        'entries=' + entries + ' fresh=' + fresh + ' etag=' + withEtag + ' lastModified=' + withLm);
    }
    return BrewService.liveCache;
  }

  /** 批次结束时刷一次盘（只在内存里有变更时） */
  private static flushCache(): void {
    // 世代号守卫：清空缓存之后，在途批次的写入必须丢弃，否则「清了没清掉」。
    //
    // ⚠ 世代号在**操作入口**（`hydrate()` 开头）捕获，**不在这里比对时改写** ——
    // 改写等于「只保护 bump 后的第一次写入」，而同一批里更廉价的写入会把这个配额用掉，
    // 真正贵的那几个照写不误。详见 `BrewCacheEpoch` 的注释（终审抓到的 Critical）。
    if (BrewService.flushEpoch !== BrewCacheEpoch.current()) {
      BrewService.cacheDirty = false;
      BrewService.stampsDirty = false;
      Logger.info(TAG, '[BrewCache] epoch mismatch, dropped write key=brew_live_data');
      return;
    }
    let wrote: boolean = false;
    if (BrewService.cacheDirty && BrewService.liveCache !== undefined) {
      BrewSourcePrefs.set<Record<string, LiveCacheEntry>>(
        BREW_LIVE_STORAGE_KEY, BrewService.liveCache);
      BrewService.cacheDirty = false;
      wrote = true;
      Logger.info(TAG, `live cache flushed, ${Object.keys(BrewService.liveCache).length} entries`);
    }
    if (BrewService.stampsDirty && BrewService.datasetStamps !== undefined) {
      BrewSourcePrefs.set<Record<string, DatasetStamp>>(
        BREW_LIVE_DATASET_KEY, BrewService.datasetStamps);
      BrewService.stampsDirty = false;
      wrote = true;
    }
    if (wrote) {
      // `set` 只是写进 GSKV 的内存缓存页。必须显式刷盘，否则进程被杀时这一批写入会丢
      // （真机实测：25s 内被杀 → 下次启动仍 `reason=missing`）。见 `BrewSourcePrefs.persistNow`。
      BrewSourcePrefs.persistNow();
    }
  }

  /** 数据集版本戳的内存副本（与 doc 缓存分开存，两者语义不同：一个是批次时间，一个是包数据） */
  private static ensureStamps(): Record<string, DatasetStamp> {
    if (BrewService.datasetStamps === undefined) {
      const t0: number = Date.now();
      const stored: Record<string, DatasetStamp> | null =
        BrewSourcePrefs.get<Record<string, DatasetStamp>>(BREW_LIVE_DATASET_KEY);
      BrewService.datasetStamps = stored ?? {};
      BrewLoadLog.info('dataset_stamps', stored === null ? 'missing' : 'pref', Date.now() - t0,
        'kinds=' + Object.keys(BrewService.datasetStamps).length);
    }
    return BrewService.datasetStamps;
  }

  // ------------------------------------------------------------ 现网：目录与三张榜

  /**
   * 设备端目录：**全量宇宙**（formula 7.9k + cask 5.9k token）的安装量、三张榜，
   * 以及浏览用的「按安装量降序」token 表（`topTokens`）。
   *
   * 为什么值得单独一层：三张榜的成员必须从**全量分布**里算（门槛是全球分位、还要 family 去重），
   * 客户端只有这一份全量分布（内置快照已于 2026-10 删除），所以成员只能是每次刷新现算的。
   *
   * 数据量与传输（均实测）：4 个端点 raw 1.9 MB / **gzip 358 KB**，且带条件请求，
   * 全 304 时 **0 字节**（源站每天只重新生成一次，所以大多数刷新都是 0 字节）。
   * 与本层现有的单条 hydrate 相比：240 条单条 gzip 合计约 292 KB 且只覆盖白名单 ——
   * 即「多花 66 KB，从 240 个包变成 1.3 万个包」。
   *
   * 失败时返回 `undefined` 而不抛错：目录是**唯一的成员来源**，拿不到就返回空页 / 空态，
   * 页面不该因为聚合端点抖动而变成错误态。
   */
  public getCatalog(): Promise<BrewCatalog | undefined> {
    // 世代号在**操作入口**捕获：`fetchCatalog` 的两个成功分支都会走到 `saveCatalog`。
    // 清空发生在这次取数开始之后的话，这次的结果（可能已是旧源的目录）必须丢弃。
    BrewService.catalogEpoch = BrewCacheEpoch.current();
    const tLoad: number = Date.now();
    const stored: BrewCatalog | undefined = BrewService.ensureCatalog();
    if (stored !== undefined && Date.now() - stored.ts < BREW_CATALOG_FRESH_MS) {
      Logger.info(TAG, `catalog cache hit, age=${Math.floor((Date.now() - stored.ts) / 1000)}s, ` +
        `boards=${BrewService.boardCount(stored)} entries`);
      BrewLoadLog.info('catalog_fetch', 'pref-fresh', Date.now() - tLoad,
        'age=' + Math.floor((Date.now() - stored.ts) / 1000) + 's boards=' +
        BrewService.boardCount(stored) + ' → 零请求');
      return Promise.resolve(stored);
    }
    const pending: Promise<BrewCatalog | undefined> | undefined = BrewService.catalogInFlight;
    if (pending !== undefined) {
      Logger.info(TAG, 'catalog request joined in-flight');
      BrewLoadLog.info('catalog_fetch', 'in-flight', Date.now() - tLoad,
        'age=' + (stored === undefined ? -1 : Math.floor((Date.now() - stored.ts) / 1000)) +
        's → 复用已有请求');
      return pending;
    }
    BrewLoadLog.info('catalog_fetch', stored === undefined ? 'missing' : 'pref-stale',
      Date.now() - tLoad, stored === undefined ?
        '盘上没有目录 → 首次安装 / 数据被清；接下来拉 4 个聚合端点（实测 gzip 合计 ~358KB）' :
        'age=' + Math.floor((Date.now() - stored.ts) / 1000) + 's 超新鲜窗口 ' + BREW_CATALOG_FRESH_MS +
          'ms → 先探针再条件请求');
    // H1（判据 #1/#3，2026-09-23 修订）：**在发起探针之前**通知。
    //
    // 为什么 `missing` 与 `pref-stale` 两态都在这里通知（原设计把 `pref-stale` 留给 H2
    // 在探针之后再判）：真机实测推翻了两条前提 ——
    //   ① 探针不是 HEAD，是带 `If-Modified-Since` 的完整 GET；4 个并行，
    //      设备实测 `catalog_fetch ms=17437`（宿主机同批 5.2s），慢的是这条路本身；
    //   ② 304 也一样慢：`homebrew-core/365d.json` 实测 304 花 24.06s（TTFB 22.5s、0 字节）——
    //      因为边缘 `Cache-Control: max-age=600`（10 分钟）比本模块的新鲜窗口短，
    //      探针必然打在过期的边缘副本上 → 回源。
    // 于是“探针只花几百毫秒、是最大误报源”不成立：**探针就是那段等待**。
    // 按纯预测式原则（spec §2.3「即将等待时提示」），通知必须在发起前 ——
    // 放在探针之后等于“等完了再说”（实测用户先转 17.2s 圈才看到 toast）。
    BrewNetNotice.willFetch(stored === undefined ? 'missing' : 'pref-stale',
      stored === undefined ?
        'brew_catalog 缺失 → 拉 4 个聚合端点（gzip 合计 ~358KB）' :
        'age=' + Math.floor((Date.now() - stored.ts) / 1000) + 's 超 ' +
          (BREW_CATALOG_FRESH_MS / 3600000) + 'h 新鲜窗口 → 4 个端点并行探针（实测设备 17.4s）');
    const task: Promise<BrewCatalog | undefined> = this.fetchCatalog(stored)
      .catch((error: Error) => {
        // 不在日志里静默吞掉：看不到“目录取数挂了”就只会看到“榜一直是旧成员”
        Logger.error(TAG, `catalog fetch failed, ${error.message}`);
        BrewService.stats.catalogFailed++;
        // spec §9.5 的**运行期写入点**：目录取数失败 → 健康记录。
        // 缺了它，`PARTIAL`（「单条文档可用但目录持续失败」，即镜像缺 analytics）
        // 在生产环境永远不可达 —— 真机自检实测过这一点。
        BrewSourceStore.noteError(BrewSourceStore.sessionActive().id, 'catalog', error.message);
        BrewLoadLog.warn('catalog_fetch', 'fetch-failed', Date.now() - tLoad,
          'error=' + error.message + ' → 沿用盘上旧目录（或空）');
        return undefined;
      })
      .then((result: BrewCatalog | undefined) => {
        BrewService.catalogInFlight = undefined;
        return result;
      });
    BrewService.catalogInFlight = task;
    return task;
  }

  /**
   * 取目录：先条件请求问“变了吗”，全 304 就直接沿用（0 字节），否则重取缺的那几个再重算。
   *
   * 为什么不做“逐端点增量合并”：只重取变了的那一个时，另一个窗口的计数拿不到，
   * 而三张榜依赖的是**完整的分布**（分位数、family 去重都建立在全量上）。
   * 所以粒度为「整批」：304 的复用响应体（探针本身就带回响应体）、缺的补取。
   */
  private fetchCatalog(stored: BrewCatalog | undefined): Promise<BrewCatalog | undefined> {
    const startAt: number = Date.now();
    const sourceId: string = BrewSourceStore.sessionActive().id;
    const adapter: BrewSourceAdapter = adapterFor(BrewSourceStore.dialectOf(sourceId));
    if (!adapter.supportsAnalytics) {
      return adapter.synthCatalogDocs(BrewSourceStore.activeBaseUrl())
        .then((inputs: BrewCatalogInput[] | undefined) => {
          if (inputs === undefined) {
            BrewService.noteCatalogStatsFailed(sourceId, startAt, 'harmonybrew stats unavailable');
            return undefined;
          }
          const bodies: CatalogProbeResult[] = inputs.map((input: BrewCatalogInput) =>
            BrewService.toCatalogInputProbeResult(input));
          return this.buildCatalog(bodies, stored, Date.now() - startAt, 0, inputs.length);
        });
    }
    const stamps: Record<string, string> = stored?.stamps ?? {};
    const jobs: CatalogFetchJob[] = BrewService.catalogJobs();
    const probes: Promise<CatalogProbeResult>[] = jobs.map((job: CatalogFetchJob) => {
      const headers: Record<string, string> = {};
      const stamp: string | undefined = stamps[job.url];
      if (stamp !== undefined && stamp.length > 0) {
        headers['If-Modified-Since'] = stamp;
      }
      return BrewHttp.request(job.url, undefined, headers, BREW_CATALOG_TIMEOUT_MS)
        .then((res: BrewHttpResult) => BrewService.toProbeResult(job, res));
    });
    return Promise.all(probes).then((probed: CatalogProbeResult[]) => {
      const notModified: number = probed.filter((one: CatalogProbeResult) => one.code === 304).length;
      if (notModified === probed.length && stored !== undefined) {
        // 整批没变：0 字节续期。榜单不重算（同一份输入必然同一份输出）
        stored.ts = Date.now();
        stored.allNotModified = true;
        BrewService.saveCatalog(stored);
        Logger.info(TAG, `catalog unchanged (${notModified}/${probed.length} 304, 0B), renewed ` +
          `| ${BrewService.catalogMetaLine(stored.meta)}`);
        BrewLoadLog.info('catalog_fetch', 'probe-304', Date.now() - startAt,
          notModified + '/' + probed.length + ' 个端点 304, 0B → 整批未变，榜单不重算');
        BrewService.logCatalogBoards(stored);
        // 整批 304 说明 4 个聚合端点都可达 → 这个镜像是能用的，记一次成功
        BrewSourceStore.noteCatalogOk(BrewSourceStore.sessionActive().id);
        return stored;
      }
      // 原 H2 通知点已删除（2026-09-23）：通知改在 `getCatalog` 发起探针**之前**。
      // 留在这里等于“等完了再说” —— 这段代码在探针 resolve 之后才执行，
      // 而探针实测要 17.4s，所以旧版用户先转 17.2s 圈才看到 toast。
      // 判据日志仍在下面各分支：`[load] kind=catalog_fetch reason=net-200|probe-304`。
      // 有端点变了（或本地没有基准）：把没带回响应体的那几个补取
      const missing: CatalogProbeResult[] = probed.filter((one: CatalogProbeResult) => one.code !== 200);
      const refetches: Promise<CatalogProbeResult>[] = missing.map((one: CatalogProbeResult) =>
        BrewHttp.request(one.job.url, undefined, {}, BREW_CATALOG_TIMEOUT_MS)
          .then((res: BrewHttpResult) => BrewService.toProbeResult(one.job, res)));
      return Promise.all(refetches).then((fetched: CatalogProbeResult[]) => {
        const bodies: CatalogProbeResult[] = probed.filter((one: CatalogProbeResult) => one.code === 200)
          .concat(fetched);
        return this.buildCatalog(bodies, stored, Date.now() - startAt, notModified, probed.length);
      });
    });
  }

  /** 解析 4 份聚合文件 -> 算三张榜 -> 存白名单 -> 落盘 + 判据日志 */
  private buildCatalog(bodies: CatalogProbeResult[], stored: BrewCatalog | undefined,
    tookMs: number, notModified: number, total: number): Promise<BrewCatalog> {
    const sourceId: string = BrewSourceStore.sessionActive().id;
    const dialect: string = BrewSourceStore.dialectOf(sourceId);
    const adapter: BrewSourceAdapter = adapterFor(dialect);
    const counts: Record<string, Record<string, CatalogCounts>> = {};
    const nextStamps: Record<string, string> = {};
    bodies.forEach((one: CatalogProbeResult) => {
      const parsed: CatalogCounts = BrewCatalogAlgo.parseCounts(JSON.parse(one.text) as CatalogAnalyticsDoc);
      if (counts[one.job.kind] === undefined) {
        counts[one.job.kind] = {};
      }
      counts[one.job.kind][one.job.win] = parsed;
      if (one.lastModified.length > 0) {
        nextStamps[one.job.url] = one.lastModified;
      }
    });
    const meta: Record<string, CatalogKindMeta> = {};
    const boards: Record<string, Record<string, CatalogEntry[]>> = {};
    const topTokens: Record<string, CatalogEntry[]> = {};
    Object.keys(counts).forEach((kind: string) => {
      const windows: Record<string, CatalogCounts> = counts[kind];
      const thresholds: CatalogThresholds = catalogThresholdsFor(dialect, kind);
      const result: CatalogKindResult = BrewCatalogAlgo.build(
        kind, windows['30d'].counts, windows['365d'].counts, adapter.priorDivisor, thresholds);
      meta[kind] = BrewService.toKindMeta(windows['30d'], result, thresholds);
      boards[kind] = BrewService.toBoards(result);
      topTokens[kind] = result.byVolume
        .map((row: CatalogRecord) => BrewService.toEntry(row, false));
    });
    const catalog: BrewCatalog = {
      ts: Date.now(),
      allNotModified: notModified === total,
      tookMs: tookMs,
      stamps: nextStamps,
      meta: meta,
      boards: boards,
      topTokens: topTokens,
    };
    BrewService.saveCatalog(catalog);
    Logger.info(TAG, `catalog refreshed, took=${tookMs}ms, notModified=${notModified}/${total} ` +
      `| ${BrewService.catalogMetaLine(meta)}`);
    BrewLoadLog.info('catalog_fetch', 'net-200', tookMs,
      'notModified=' + notModified + '/' + total + ' boards=' + BrewService.boardCount(catalog) +
      ' browse=' + Object.keys(topTokens).map((kind: string) => kind + '=' + topTokens[kind].length).join(' '));
    Logger.info(TAG, 'catalog boards: ' + BrewService.boardCount(catalog) + ' entries, browse tokens: ' +
      Object.keys(topTokens).map((kind: string) => `${kind}=${topTokens[kind].length}`).join(' '));
    BrewService.logCatalogBoards(catalog);
    // 拿到了 4 份聚合文件并算出了榜单 → 这个镜像的 analytics 路径可用，记一次成功
    BrewSourceStore.noteCatalogOk(BrewSourceStore.sessionActive().id);
    return Promise.resolve(catalog);
  }

  /** 4 个聚合端点（URL 来自 `catalogSources()`，不在别处重拼） */
  private static catalogJobs(): CatalogFetchJob[] {
    return catalogSources();
  }

  private static toProbeResult(job: CatalogFetchJob, res: BrewHttpResult): CatalogProbeResult {
    return {
      job: job,
      code: res.code,
      text: res.text,
      lastModified: res.headers['last-modified'] ?? '',
    };
  }

  private static toCatalogInputProbeResult(input: BrewCatalogInput): CatalogProbeResult {
    const job: CatalogFetchJob = new CatalogSource(input.kind, input.win, input.url);
    return { job: job, code: 200, text: input.text, lastModified: input.lastModified };
  }

  private static noteCatalogStatsFailed(sourceId: string, startAt: number, detail: string): void {
    BrewService.stats.catalogFailed++;
    BrewSourceStore.noteError(sourceId, 'catalog', detail);
    BrewLoadLog.warn('catalog_fetch', 'stats-failed', Date.now() - startAt,
      detail + ' → 返回 undefined，沿用盘上旧目录（或空）');
  }

  /** 落盘的榜单条目：只带 token + 数字（id / desc / categoryKey 是内置快照的，join 时补） */
  private static toBoards(result: CatalogKindResult): Record<string, CatalogEntry[]> {
    const boards: Record<string, CatalogEntry[]> = {};
    BREW_CATALOG_BOARDS.forEach((pair: string[]) => {
      const boardKey: string = pair[0];
      const rows: CatalogRecord[] = BREW_CATALOG_BOARDS.indexOf(pair) === 0 ? result.rising :
        (boardKey === 'alltime' ? result.alltime : result.fresh);
      const isTrending: boolean = boardKey === 'trending';
      boards[boardKey] = rows.slice(0, BREW_CATALOG_KEEP)
        .map((row: CatalogRecord) => BrewService.toEntry(row, isTrending));
    });
    return boards;
  }

  /** 落盘用的条目。`withScore` 只在趋势榜为 true（与 generate.py 同口径：其余榜 score 写 0） */
  private static toEntry(row: CatalogRecord, withScore: boolean): CatalogEntry {
    const entry: CatalogEntry = {
      token: row.token,
      vol30d: row.vol30d,
      vol365d: row.vol365d,
      prior: Math.round(row.prior * 10) / 10,
      velocity: Math.round(row.velocity * 100) / 100,
      score: withScore ? Math.round(row.score * 100) / 100 : 0,
    };
    return entry;
  }

  private static toKindMeta(window: CatalogCounts, result: CatalogKindResult,
    thresholds: CatalogThresholds): CatalogKindMeta {
    return {
      windowStart: window.meta.windowStart,
      windowEnd: window.meta.windowEnd,
      totalItems: window.meta.totalItems,
      totalCount: window.meta.totalCount,
      rawTokens: result.rawTokens,
      families: result.families,
      candidates: result.candidates,
      thresholds: thresholds,
      actualVolP: result.actualVolP,
      actualPriorP: Math.round(result.actualPriorP * 10) / 10,
      multiEntryTokens: window.meta.multiEntryTokens,
    };
  }

  /** 一行汇总每个 kind 的规模与门槛实测偏差（对应 check_algo.py 的第 3 条不变量） */
  private static catalogMetaLine(meta: Record<string, CatalogKindMeta>): string {
    const parts: string[] = [];
    Object.keys(meta).forEach((kind: string) => {
      const one: CatalogKindMeta = meta[kind];
      const volDev: number = Math.abs(one.actualVolP - one.thresholds.volFloor) /
        Math.max(1, one.thresholds.volFloor);
      const priorDev: number = Math.abs(one.actualPriorP - one.thresholds.minPrior) /
        Math.max(1, one.thresholds.minPrior);
      parts.push(`${kind} raw=${one.rawTokens} fam=${one.families} cand=${one.candidates} ` +
        `win=${one.windowStart}~${one.windowEnd} total=${one.totalCount} multi=${one.multiEntryTokens} ` +
        `volFloor=${one.thresholds.volFloor}(p89实测 ${one.actualVolP}, 偏差 ${(volDev * 100).toFixed(1)}%) ` +
        `minPrior=${one.thresholds.minPrior}(p55实测 ${one.actualPriorP}, 偏差 ${(priorDev * 100).toFixed(1)}%)`);
    });
    return parts.join(' | ');
  }

  /** 六张榜的前 TOP_N 名（token=30d:velocity）。逐条打出来是为了能与 check_algo.py 的输出逐名对账 */
  private static logCatalogBoards(catalog: BrewCatalog): void {
    Object.keys(catalog.boards).forEach((kind: string) => {
      Object.keys(catalog.boards[kind]).forEach((boardKey: string) => {
        const rows: CatalogEntry[] = catalog.boards[kind][boardKey].slice(0, BREW_CATALOG_TOP_N);
        const text: string = rows.map((row: CatalogEntry, index: number) =>
          `${index + 1}.${row.token}=${row.vol30d}:${row.velocity}`).join(' ');
        Logger.info(TAG, `catalog top ${kind}/${boardKey}: ${text}`);
      });
    });
  }

  private static boardCount(catalog: BrewCatalog): number {
    let total: number = 0;
    Object.keys(catalog.boards).forEach((kind: string) => {
      Object.keys(catalog.boards[kind]).forEach((boardKey: string) => {
        total += catalog.boards[kind][boardKey].length;
      });
    });
    return total;
  }

  /** 目录的内存副本（首次访问从 Preference 读一次整份） */
  private static ensureCatalog(): BrewCatalog | undefined {
    if (BrewService.catalog === undefined && !BrewService.catalogLoaded) {
      BrewService.catalogLoaded = true;
      // [perf] 这一段是主线程 `getSync` + `JSON.parse`（目录约 550KB）。
      // 实测只有 19~22ms —— 记下来是为了防止"瓶颈在 I/O"这个直觉再回来。
      const t0: number = Date.now();
      const stored: BrewCatalog | null =
        BrewSourcePrefs.get<BrewCatalog>(BREW_CATALOG_STORAGE_KEY);
      const readMs: number = Date.now() - t0;
      BrewService.catalog = stored ?? undefined;
      if (BREW_PERF_TRACE) {
        Logger.info(TAG, `[perf] catalog pref read+parse ts=${t0} readMs=${readMs} ` +
          `formula=${stored?.topTokens?.[BrewKindText.FORMULA]?.length ?? 0} ` +
          `cask=${stored?.topTokens?.[BrewKindText.CASK]?.length ?? 0}`);
      }
      BrewLoadLog.info('catalog', stored === null ? 'missing' : 'pref', readMs,
        'formula=' + (stored?.topTokens?.[BrewKindText.FORMULA]?.length ?? 0) +
        ' cask=' + (stored?.topTokens?.[BrewKindText.CASK]?.length ?? 0) +
        ' age=' + (stored === null ? -1 : Math.floor((Date.now() - stored.ts) / 1000)) + 's');
      if (BrewService.catalog !== undefined) {
        Logger.info(TAG, `catalog loaded, age=${Math.floor((Date.now() - BrewService.catalog.ts) / 1000)}s, ` +
          `boards=${BrewService.boardCount(BrewService.catalog)}, ` +
          `browseKinds=${Object.keys(BrewService.catalog.topTokens).length}`);
      }
    }
    return BrewService.catalog;
  }

  private static saveCatalog(catalog: BrewCatalog): void {
    // 世代号在 `getCatalog()` 入口捕获。**不在这里改写 epoch**。
    if (BrewService.catalogEpoch !== BrewCacheEpoch.current()) {
      Logger.info(TAG, '[BrewCache] epoch mismatch, dropped write key=brew_catalog');
      return;
    }
    BrewService.catalog = catalog;
    BrewService.catalogLoaded = true;
    BrewSourcePrefs.set<BrewCatalog>(BREW_CATALOG_STORAGE_KEY, catalog);
    // 目录重下的代价是 4 个聚合端点（实测 gzip 合计 ~358KB、设备 17.4s）。
    // 它写入后马上就可能被用户离开应用/系统回收进程，所以不能等「自然落盘」。
    BrewSourcePrefs.persistNow();
  }

  /** 榜上某一榜的条目（供 Repository 取成员） */
  public static catalogRows(catalog: BrewCatalog, kind: string, boardKey: string): CatalogEntry[] {
    return catalog.boards[kind]?.[boardKey] ?? [];
  }

  // ------------------------------------------------------------ 设备端浏览页（分类 + 成员）

  /**
   * 用目录 + 元数据索引在设备端拼出 Formulae 首页。**拿不到目录时返回 undefined**（UI 走空态）。
   *
   * 两条路径（判据见 `BREW_INDEX_MIN_TRUST`）：
   *
   * **主路径（索引可信）**：候选 = **目录 ∩ 索引**，首屏**一个单条请求都不发**。
   * 索引是从 `formula.json`（上游"存在性"的权威清单）抽出来的，它没有的 token 就是上游没有的
   * —— 已经知道答案就不该再逐条去问。改动前这里会对"目录里有、`formula.json` 里没有"的
   * 93 个 token 逐条 hydrate，实测**全部 404**（`dl=0`），却占掉冷启动 96% 的时间（真机两轮
   * 17.7s / 18.8s，其中 16.5s 在这里）。详见 `docs/superpowers/specs/2026-09-22-brew-coldstart-design.md` §2。
   *
   * **降级路径（索引不可信）**：退化成「前 `BREW_BROWSE_HYDRATE_LIMIT` 个 + 逐条 hydrate」，
   * 与改动前**逐字相同** —— 那种情况下 `desc` 只能一条一条拉，瓶颈就在请求预算上。
   *
   * 为什么主路径不再 hydrate 也不会漏掉新包：`BrewMetaSync` 每次进程启动都在后台重拉全量
   * 索引（约 21.7s），而页面在 0.7s 就构建完了；`descOf()` 读的是内存里的当前索引，所以
   * 新包在**下一次构页**（重进页签）就会出现。这是需求方已接受的 stale-while-revalidate。
   *
   * 这一层不缓存"拼好的页面"：目录或分类口径一变，缓存会挡住新结果（Discover 吃过这个亏）。
   */
  public buildFormulaPage(currentPage: number, pageSize: number):
    Promise<BrewPageData<BrewFormulaPageData> | undefined> {
    // 同一页会被构建两次（见 formulaPageInFlight 的注释）—— 复用第一次的 Promise。
    // 两个条件都满足才 join：pageSize 相同 + 未超时（超时说明那次构建可能永不 settle）
    const pending: Promise<BrewPageData<BrewFormulaPageData> | undefined> | undefined =
      BrewService.formulaPageInFlight;
    if (pending !== undefined && BrewService.formulaPageInFlightPageSize === pageSize &&
      Date.now() - BrewService.formulaPageInFlightAt <= BREW_PAGE_INFLIGHT_JOIN_MS) {
      Logger.info(TAG, 'formula page build joined in-flight');
      return pending;
    }
    const tStart: number = Date.now();
    const catalog: BrewCatalog | undefined = BrewService.ensureCatalog();
    const tCatalog: number = Date.now();
    if (catalog === undefined) {
      BrewLoadLog.warn('formula_page', 'empty-catalog', Date.now() - tStart,
        'brew_catalog 缺失 → 页面空态。' +
        '浏览页从不自己拉目录（只有 Discover 的 getCatalog 会），' +
        '所以首次安装后若没进过 Discover，这里会一直是空态');
      return Promise.resolve(undefined);
    }
    const all: CatalogEntry[] = BrewService.browseRows(catalog, BrewKindText.FORMULA);
    const descIndex: Record<string, string> = BrewMetaSync.descOf(BrewKindText.FORMULA);
    const tIndex: number = Date.now();
    const covered: number = all.filter((row: CatalogEntry) => descIndex[row.token] !== undefined).length;
    const trusted: boolean = covered >= BREW_INDEX_MIN_TRUST;
    // 主路径：目录 ∩ 索引（索引可信时它没有的 token 就是上游没有的）
    // 降级路径：**逐字保留改动前的取法** —— `covered > 0 ? all : 前 N 个`。
    // 注意 `covered ∈ [1, BREW_INDEX_MIN_TRUST)` 时旧代码用的是**目录全量**（不是前 100）：
    // 这里必须原样写回去，否则"索引只扫出几十条"时，索引命中的条目若排名在 100 名之外
    // 就会整片消失（离线时表现为空页），那是比改动前**更差**的行为。
    const candidates: CatalogEntry[] = trusted ?
      all.filter((row: CatalogEntry) => descIndex[row.token] !== undefined) :
      (covered > 0 ? all : all.slice(0, BREW_BROWSE_HYDRATE_LIMIT));
    // **主路径显式短路**，不是"过滤完再让 splitMissing 过滤一遍"：后者结果碰巧也是空，
    // 但意图错，而且将来一改就漏（见 spec §5.2）。
    const split: MissingSplit = trusted ?
      { tokens: [], ghosts: 0 } :
      BrewService.splitMissing(candidates, descIndex, BrewKindText.FORMULA);
    const missing: string[] = split.tokens;
    /** 目录里有、索引里没有的条数。两种成因（上游幽灵 / cask 的 `desc: null`），日志读法见 spec §7 */
    const dropped: number = all.length - covered;
    const tSplit: number = Date.now();
    if (!trusted && missing.length > 0) {
      // H3（判据 #6）：索引不可信 + 真有要逐条拉的 token（幽灵已被 splitMissing 剔除）→ 实测 5~15s。
      // 这个函数同时服务首页 Formulae 与分类二级页（`getFormulaCategories` 走 `pageSize=100`），
      // 所以页面层不需要再各接一次。
      BrewNetNotice.willFetch(BrewService.degradedReason(covered),
        'kind=formula_page hydrate=' + missing.length + ' ghosts=' + split.ghosts + ' covered=' + covered +
        '/' + all.length);
    }
    const docsPromise: Promise<Record<string, LiveFormulaDoc>> = missing.length > 0 ?
      this.hydrateFormulaDocs(missing, BREW_BROWSE_HYDRATE_MS) :
      Promise.resolve<Record<string, LiveFormulaDoc>>({});
    const task: Promise<BrewPageData<BrewFormulaPageData> | undefined> = docsPromise
      .then((docs: Record<string, LiveFormulaDoc>) => {
        // “能上屏”的判据是**有可展示文案**，不是“字段存在”：`desc` 可能是 null/空串。
        const ready: CatalogEntry[] = candidates.filter((row: CatalogEntry) =>
          BrewBrowseBuilder.descOf(row.token, descIndex, docs[row.token]?.desc).length > 0);
        // 降级路径专用：拉到文档但上游没 desc（cask 实测有 2,645 条 `desc: null`）→ 对浏览页
        // 等同于“没有”：也记进负缓存，否则每轮重绘都拿这 100 个占掉 hydrate 预算。
        // 取数失败（doc 为 undefined）**不记**：那是“这次没拿到”，不是“上游没有”。
        // 主路径下 `missing` 是空数组，这段自然空转。
        missing.forEach((token: string) => {
          const doc: LiveFormulaDoc | undefined = docs[token];
          if (doc !== undefined && BrewService.descLen(descIndex, token, doc.desc) === 0) {
            BrewService.markMissing(`${BrewKindText.FORMULA}_${token}`);
          }
        });
        const page: BrewPageData<BrewFormulaPageData> =
          BrewBrowseBuilder.formulaPage(ready, docs, descIndex, FORMULA_CATEGORY_ORDER, pageSize);
        // 分母刻意是 `all.length`（目录全量）而不是 `candidates.length`：
        // `ready/catalog` 才是"这次上屏了多少 / 目录一共有多少"的读数，跨改动可比（spec §9.1 V4）。
        Logger.info(TAG, `browse formula built, ${ready.length}/${all.length} tokens ready ` +
          `(catalog ${all.length}, index ${covered}, dropped ${dropped}, hydrate ${missing.length}` +
          BrewService.ghostSuffix(split) + `, trusted=${trusted}), ` +
          `${page.data.cardData.length} cards, ${BrewService.browseEntryCount(page.data.cardData)} entries, ` +
          `${Date.now() - tStart}ms` + BrewService.perfSuffix(tStart, tCatalog, tIndex, tSplit) + ` | ` +
          BrewService.cardDistLine(page.data.cardData.map(
            (card: BrewCategoryCard) => [card.categoryKey, card.itemCount])) +
          ` | ${BrewService.statsLine()}`);
        BrewService.logPageLoad('formula_page', trusted, covered, all.length, tStart, tCatalog, tIndex, tSplit,
          'hydrate=' + missing.length + ' ghosts=' + split.ghosts + ' ready=' + ready.length +
          ' cards=' + page.data.cardData.length);
        return page;
      });
    // 两个分支都要清空在途字段：漏了失败分支就会把那个已 reject 的 Promise 永久留在字段里，
    // 后续每次构页都拿到它 → 页面永久失败态，直到重启 App（比改动前更糟）。
    // 用序号守卫而不是无条件清空：join 超时后可能已有一个**新的**构建写在字段里，
    // 旧的那次完成时不能把它清掉（否则新构建的去重就失效了）。
    const id: number = BrewService.formulaPageInFlightId + 1;
    BrewService.formulaPageInFlightId = id;
    const tracked: Promise<BrewPageData<BrewFormulaPageData> | undefined> = task.then(
      (page: BrewPageData<BrewFormulaPageData> | undefined) => {
        if (BrewService.formulaPageInFlightId === id) {
          BrewService.formulaPageInFlight = undefined;
        }
        return page;
      },
      (error: Error) => {
        if (BrewService.formulaPageInFlightId === id) {
          BrewService.formulaPageInFlight = undefined;
        }
        throw error;
      });
    BrewService.formulaPageInFlight = tracked;
    BrewService.formulaPageInFlightPageSize = pageSize;
    BrewService.formulaPageInFlightAt = Date.now();
    return tracked;
  }

  /**
   * 同 `buildFormulaPage`（cask 的卡片是「分类 -> 卡 -> 条目」三层）。
   *
   * cask 的 `dropped` 会明显大于 formula。参考量级：`cask.json` 里共有 **2,645 条 `desc: null`**，
   * 落盘索引时故意不写空串，所以这类 token 只要进了目录就必然计入 `dropped`。
   *
   * **但 2645 不是期望值**（也不是下界）：`dropped = |目录| − |目录 ∩ 索引|`，它取决于
   * 有多少条 `desc: null` 的 token 真的进了目录、以及目录里的上游幽灵有多少 —— **一律以 V7 实测为准**。
   * 改动前这类 token 每轮都要被 hydrate 一遍（拿到 doc 但 desc 为空，才 `markMissing`）；
   * 主路径不再发这批请求，所以 cask 的收益预计比 formula 更大。**不要把这个数字当 bug 修**（spec §7）。
   */
  public buildCaskPage(currentPage: number, pageSize: number):
    Promise<BrewPageData<BrewCaskPageData> | undefined> {
    const sourceId: string = BrewSourceStore.sessionActive().id;
    const adapter: BrewSourceAdapter = adapterFor(BrewSourceStore.dialectOf(sourceId));
    if (!adapter.supportsCasks) {
      Logger.info(TAG, 'cask browse unsupported by active source; returning empty page');
      return Promise.resolve(BrewBrowseBuilder.emptyCaskPage(pageSize));
    }
    const pending: Promise<BrewPageData<BrewCaskPageData> | undefined> | undefined =
      BrewService.caskPageInFlight;
    if (pending !== undefined && BrewService.caskPageInFlightPageSize === pageSize &&
      Date.now() - BrewService.caskPageInFlightAt <= BREW_PAGE_INFLIGHT_JOIN_MS) {
      Logger.info(TAG, 'cask page build joined in-flight');
      return pending;
    }
    const tStart: number = Date.now();
    const catalog: BrewCatalog | undefined = BrewService.ensureCatalog();
    const tCatalog: number = Date.now();
    if (catalog === undefined) {
      BrewLoadLog.warn('cask_page', 'empty-catalog', Date.now() - tStart,
        'brew_catalog 缺失 → 页面空态。' +
        '浏览页从不自己拉目录（只有 Discover 的 getCatalog 会），' +
        '所以首次安装后若没进过 Discover，这里会一直是空态');
      return Promise.resolve(undefined);
    }
    const all: CatalogEntry[] = BrewService.browseRows(catalog, BrewKindText.CASK);
    const descIndex: Record<string, string> = BrewMetaSync.descOf(BrewKindText.CASK);
    const tIndex: number = Date.now();
    const covered: number = all.filter((row: CatalogEntry) => descIndex[row.token] !== undefined).length;
    const trusted: boolean = covered >= BREW_INDEX_MIN_TRUST;
    // 降级路径逐字保留改动前的取法（理由同 buildFormulaPage：`covered ∈ [1, MIN_TRUST)`
    // 时旧代码用的是目录全量，不是前 100）
    const candidates: CatalogEntry[] = trusted ?
      all.filter((row: CatalogEntry) => descIndex[row.token] !== undefined) :
      (covered > 0 ? all : all.slice(0, BREW_BROWSE_HYDRATE_LIMIT));
    const split: MissingSplit = trusted ?
      { tokens: [], ghosts: 0 } :
      BrewService.splitMissing(candidates, descIndex, BrewKindText.CASK);
    const missing: string[] = split.tokens;
    const dropped: number = all.length - covered;
    const tSplit: number = Date.now();
    if (!trusted && missing.length > 0) {
      // H3（判据 #6）：同 buildFormulaPage。分类二级页（`getCaskCategories`）也走这里。
      BrewNetNotice.willFetch(BrewService.degradedReason(covered),
        'kind=cask_page hydrate=' + missing.length + ' ghosts=' + split.ghosts + ' covered=' + covered +
        '/' + all.length);
    }
    const docsPromise: Promise<Record<string, LiveCaskDoc>> = missing.length > 0 ?
      this.hydrateCaskDocs(missing, BREW_BROWSE_HYDRATE_MS) :
      Promise.resolve<Record<string, LiveCaskDoc>>({});
    const task: Promise<BrewPageData<BrewCaskPageData> | undefined> = docsPromise
      .then((docs: Record<string, LiveCaskDoc>) => {
        const ready: CatalogEntry[] = candidates.filter((row: CatalogEntry) =>
          BrewBrowseBuilder.descOf(row.token, descIndex, docs[row.token]?.desc).length > 0);
        // 同上：cask 上游大量 `desc: null`，记进负缓存后不会每轮都占住 hydrate 预算
        missing.forEach((token: string) => {
          const doc: LiveCaskDoc | undefined = docs[token];
          if (doc !== undefined && BrewService.descLen(descIndex, token, doc.desc) === 0) {
            BrewService.markMissing(`${BrewKindText.CASK}_${token}`);
          }
        });
        const page: BrewPageData<BrewCaskPageData> = BrewBrowseBuilder.caskPage(ready, docs, descIndex,
          CASK_CATEGORY_ORDER, BrewService.caskCategoryNames(CASK_CATEGORY_ORDER), pageSize);
        Logger.info(TAG, `browse cask built, ${ready.length}/${all.length} tokens ready ` +
          `(catalog ${all.length}, index ${covered}, dropped ${dropped}, hydrate ${missing.length}` +
          BrewService.ghostSuffix(split) + `, trusted=${trusted}), ` +
          `${page.data.caskCategories.length} categories, ${Date.now() - tStart}ms` +
          BrewService.perfSuffix(tStart, tCatalog, tIndex, tSplit) + ` | ` +
          BrewService.cardDistLine(page.data.caskCategories.map((category: BrewCaskCategory) =>
            [category.categoryKey, BrewService.caskContentsOf(category).length] as [string, number])) +
          ` | ${BrewService.statsLine()}`);
        BrewService.logPageLoad('cask_page', trusted, covered, all.length, tStart, tCatalog, tIndex, tSplit,
          'hydrate=' + missing.length + ' ghosts=' + split.ghosts + ' ready=' + ready.length +
          ' categories=' + page.data.caskCategories.length);
        return page;
      });
    // 清空 + 序号守卫的理由同 buildFormulaPage（失败分支不清会永久卡页；
    // 无条件清会清掉超时后新建的那一次）
    const id: number = BrewService.caskPageInFlightId + 1;
    BrewService.caskPageInFlightId = id;
    const tracked: Promise<BrewPageData<BrewCaskPageData> | undefined> = task.then(
      (page: BrewPageData<BrewCaskPageData> | undefined) => {
        if (BrewService.caskPageInFlightId === id) {
          BrewService.caskPageInFlight = undefined;
        }
        return page;
      },
      (error: Error) => {
        if (BrewService.caskPageInFlightId === id) {
          BrewService.caskPageInFlight = undefined;
        }
        throw error;
      });
    BrewService.caskPageInFlight = tracked;
    BrewService.caskPageInFlightPageSize = pageSize;
    BrewService.caskPageInFlightAt = Date.now();
    return tracked;
  }

  /**
   * 目录里某个 token 的 30d 安装量（可能来自榜单或浏览表；没有则 0）。
   *
   * 用途只有一个：详情页**降级**时（现网失败、只剩骨架）至少还能显示安装量 ——
   * 那是详情页上唯一能从目录直接拿到、不必依赖单条请求的数字。
   */
  public catalogInstallsOf(kind: string, token: string): number {
    const catalog: BrewCatalog | undefined = BrewService.ensureCatalog();
    if (catalog === undefined) {
      return 0;
    }
    const inBrowse: CatalogEntry | undefined =
      (catalog.topTokens?.[kind] ?? []).find((row: CatalogEntry) => row.token === token);
    if (inBrowse !== undefined) {
      return inBrowse.vol30d;
    }
    let found: number = 0;
    const boards: Record<string, CatalogEntry[]> = catalog.boards?.[kind] ?? {};
    Object.keys(boards).forEach((boardKey: string) => {
      boards[boardKey].forEach((row: CatalogEntry) => {
        if (row.token === token) {
          found = row.vol30d;
        }
      });
    });
    return found;
  }

  /**
   * 目录里的**全量行**（浏览集 = 目录全量，已按 30d 安装量降序，不裁切）。
   *
   * 搜索要的就是这一份数据，但 `browseRows` 是 `private static` —— TS 的 private 是
   * **类作用域**而不是模块作用域，跨类（`BrewSearchModel`）拿不到，所以在类内部开一个口子。
   * 返回空数组表示「没有这份数据」：目录没拿到（无网 / 首次安装），或者 kind 在目录里
   * 没有对应的 key。两种情况调用方的处理相同 —— 回落 desc 索引。
   */
  public searchRows(kind: string): CatalogEntry[] {
    const catalog: BrewCatalog | undefined = BrewService.ensureCatalog();
    return catalog === undefined ? [] : BrewService.browseRows(catalog, kind);
  }

  /** 浏览集的 token 行（目录里已按 30d 安装量降序，**不裁切**：浏览集就是目录全量） */
  private static browseRows(catalog: BrewCatalog, kind: string): CatalogEntry[] {
    return catalog.topTokens?.[kind] ?? [];
  }

  /** cask 的 chips 用本地化名（UI 侧按 key 查），数据里的 categoryName 只是回落值 */
  private static caskCategoryNames(order: string[]): string[] {
    return order.map((key: string) => BrewBrowseBuilder.categoryEn(BrewKindText.CASK, key));
  }

  /** cask 的条目藏在「分类 -> 卡 -> 条目」三层里 */
  private static caskContentsOf(category: BrewCaskCategory): BrewPackageItem[] {
    const items: BrewPackageItem[] = [];
    (category.caskCards ?? []).forEach((card: BrewCaskCard) => {
      (card.caskContents ?? []).forEach((item: BrewPackageItem) => items.push(item));
    });
    return items;
  }

  /** 每分类条数，一行（与 Python 口径对账用：`terminal=6 devtools=13 …`） */
  private static cardDistLine(pairs: Array<[string, number]>): string {
    return pairs.map((pair: [string, number]) => `${pair[0]}=${pair[1]}`).join(' ');
  }

  private static browseEntryCount(cards: BrewCategoryCard[]): number {
    let total: number = 0;
    cards.forEach((card: BrewCategoryCard) => total += card.formulaContents.length);
    return total;
  }

  // ------------------------------------------------------------ 现网：批量 hydrate

  /**
   * 批量拉一批 formula 的现网文档（列表页用），归一化成 `token -> doc`。
   *
   * 并发受 `BREW_HYDRATE_CONCURRENCY` 限制、总耗时受 `BREW_HYDRATE_TIMEOUT_MS` 限制：
   * 超时后**返回已经拿到的部分**，剩下的请求继续在后台跑完并写进 TTL 缓存
   * （下一次进页面就命中缓存）—— 不把“现网”变成“网差就打不开页面”。
   *
   * 单个 token 失败只记日志：列表里少一个现网值而已，条目仍来自目录。
   */
  public hydrateFormulaDocs(tokens: string[], timeoutMs: number = BREW_HYDRATE_TIMEOUT_MS):
    Promise<Record<string, LiveFormulaDoc>> {
    BrewService.noticeLiveDocs(BrewKindText.FORMULA, tokens);
    return this.hydrate<LiveFormulaDoc>(tokens, (token: string) => this.getLiveFormulaDoc(token),
      BREW_HYDRATE_CONCURRENCY, timeoutMs);
  }

  /** 批量拉一批 cask 的现网文档（列表页用） */
  public hydrateCaskDocs(tokens: string[], timeoutMs: number = BREW_HYDRATE_TIMEOUT_MS):
    Promise<Record<string, LiveCaskDoc>> {
    BrewService.noticeLiveDocs(BrewKindText.CASK, tokens);
    return this.hydrate<LiveCaskDoc>(tokens, (token: string) => this.getLiveCaskDoc(token),
      BREW_HYDRATE_CONCURRENCY, timeoutMs);
  }

  /**
   * H4（判据 #9/#10）：先数一遍 `brew_live_data` 里有多少 token **在新鲜窗口内命中**，
   * 全部命中（0 请求）就不通知；只要有一个要真发请求就通知。
   *
   * 预测放在 `hydrateFormulaDocs` / `hydrateCaskDocs` 这两个**已知道 kind** 的包装里，
   * 而不是 `hydrate()` 本体：后者只拿到 `fetch` 闭包，拿不到缓存 key 的前缀
   * （`formula_` / `cask_`），而命中与否只能按 key 查。
   *
   * 这里是**预测**，不是账：数完之后可能有 token 被别的在途批次写进缓存（那只会多弹一次），
   * 也可能有 token 已在途（`getLiveDoc` 会 join，不会真发请求）—— 都不影响任何数据行为，
   * 只影响「弹不弹」，与 spec §5.2 的取舍一致。
   */
  private static noticeLiveDocs(kind: string, tokens: string[]): void {
    // 去重口径与 `hydrate` 逐字一致（空 token 丢弃、重复只算一次），否则预测的分母会偏大
    const unique: string[] = [];
    tokens.forEach((token: string) => {
      if (token.length > 0 && unique.indexOf(token) < 0) {
        unique.push(token);
      }
    });
    if (unique.length === 0) {
      // 空批次不发请求。**提前返回也避开了 `ensureCache()`**：
      // 它会在首次访问时补一行 `[load] kind=live_data`，而空批次本来不会触发这行日志。
      return;
    }
    const cache: Record<string, LiveCacheEntry> = BrewService.ensureCache();
    let hits: number = 0;
    unique.forEach((token: string) => {
      const entry: LiveCacheEntry | undefined = cache[kind + '_' + token];
      if (entry !== undefined && entry !== null && BrewService.isFresh(entry)) {
        hits++;
      }
    });
    if (hits === unique.length) {
      // 判据 #10：全命中 live 缓存 → 0 请求
      return;
    }
    BrewNetNotice.willFetch('live_docs', 'kind=' + kind + ' tokens=' + unique.length + ' hit=' + hits +
      ' dl≈' + (unique.length - hits));
  }

  /**
   * 并发受限的任务池。
   *
   * 用「固定条数的 worker 链」而不是 `Promise.all(tokens.map(...))`：后者会把 100 个
   * 请求一次性全发出去，既不礼貌也容易被限流。
   */
  private hydrate<T extends Object>(tokens: string[], fetch: (token: string) => Promise<T>,
    concurrency: number = BREW_HYDRATE_CONCURRENCY,
    timeoutMs: number = BREW_HYDRATE_TIMEOUT_MS): Promise<Record<string, T>> {
    // 世代号在**操作入口**捕获：这一批 hydrate 结束时 `flushCache()` 会写
    // `brew_live_data` / `brew_live_dataset`。若清空发生在这一批开始之后，
    // 这批的**全部**写入都应作废（spec §9.2 / G5），而不是只作废第一条。
    BrewService.flushEpoch = BrewCacheEpoch.current();
    const unique: string[] = [];
    tokens.forEach((token: string) => {
      if (token.length > 0 && unique.indexOf(token) < 0) {
        unique.push(token);
      }
    });
    const result: Record<string, T> = {};
    if (unique.length === 0) {
      return Promise.resolve(result);
    }
    const deadline: number = Date.now() + timeoutMs;
    let next: number = 0;
    let ok: number = 0;
    let failed: number = 0;
    const worker = (): Promise<void> => {
      if (next >= unique.length || Date.now() > deadline) {
        return Promise.resolve();
      }
      const token: string = unique[next++];
      return fetch(token)
        .then((doc: T) => {
          result[token] = doc;
          ok++;
        })
        .catch((error: Error) => {
          failed++;
          BrewService.stats.failed++;
          Logger.error(TAG, `hydrate failed, token=${token}, ${error.message}`);
        })
        .then(() => worker());
    };
    const lanes: Promise<void>[] = [];
    const laneCount: number = Math.min(concurrency, unique.length);
    for (let i = 0; i < laneCount; i++) {
      lanes.push(worker());
    }
    BrewService.activeHydrates++;
    return Promise.all(lanes).then(() => {
      BrewService.activeHydrates--;
      if (BrewService.activeHydrates === 0) {
        BrewService.flushCache();
      }
      const tookMs: number = Date.now() - (deadline - timeoutMs);
      Logger.info(TAG, `hydrate done, ${ok}/${unique.length} (failed ${failed}), ${tookMs}ms | ${BrewService.statsLine()}`);
      BrewLoadLog.info('live_docs', 'batch', tookMs,
        'tokens=' + unique.length + ' ok=' + ok + ' failed=' + failed +
        ' concurrency=' + concurrency + ' budgetMs=' + timeoutMs + ' | ' + BrewService.statsLine());
      if (failed > 0) {
        BrewLoadLog.warn('live_docs', 'partial', tookMs,
          'failed=' + failed + '/' + unique.length +
          '（失败不入负缓存，下次还会重试；已拿到的照常用）');
      }
      // spec §9.5 的第三个运行期写入点：失败率超过一半 → 这个源这一次「部分不可用」。
      //
      // 取舍：**只在超阈值时写，成功时不清除**。单条 doc 的失败可能只是个别 token 的上游问题，
      // 不足以证明源不可用；反过来说一次干净的批次也不足以证明它可用。所以 hydrate 通道
      // 只做「报忧」，不参与「报喜」—— `PARTIAL` 因此不会因为一次好批次而被抹掉，
      // 只会被 catalog / meta 的成功（那两者有明确的「端点可达」含义）清掉。
      if (failed * 2 > unique.length) {
        BrewSourceStore.noteError(BrewSourceStore.sessionActive().id, 'hydrate',
          'failed=' + failed + '/' + unique.length);
      }
      if (tookMs >= BREW_LOAD_SLOW_MS) {
        BrewLoadLog.warn('live_docs', 'batch', tookMs,
          '超过 BREW_LOAD_SLOW_MS=' + BREW_LOAD_SLOW_MS + 'ms，已吃掉整个首屏预算' +
          '（首屏验收口径 ≤ 1100ms）');
      }
      return result;
    });
  }

  // ------------------------------------------------------------ Preference 缓存

  public getFormulaDetailByPreference(componentId: number): Promise<BrewFormulaDetail> {
    return BrewSourcePrefs.getSubValue<BrewFormulaDetail>(
      BrewService.DETAIL_PAGE_DATA, `formula_${componentId}`);
  }

  public setFormulaDetailToPreference(componentId: number, data: BrewFormulaDetail): Promise<void> {
    return BrewSourcePrefs.setSubValue<BrewFormulaDetail>(
      BrewService.DETAIL_PAGE_DATA, `formula_${componentId}`, data);
  }

  public getCaskDetailByPreference(componentId: number): Promise<BrewCaskDetail> {
    return BrewSourcePrefs.getSubValue<BrewCaskDetail>(
      BrewService.DETAIL_PAGE_DATA, `cask_${componentId}`);
  }

  public setCaskDetailToPreference(componentId: number, data: BrewCaskDetail): Promise<void> {
    return BrewSourcePrefs.setSubValue<BrewCaskDetail>(
      BrewService.DETAIL_PAGE_DATA, `cask_${componentId}`, data);
  }

  public log(message: string): void {
    Logger.debug(TAG, message);
  }
}

/** kind 的字面量（`BrewKind` 是枚举、值是 'formula'/'cask'，目录与词表都用字面量当 key） */
export class BrewKindText {
  public static readonly FORMULA: string = 'formula';
  public static readonly CASK: string = 'cask';
}
