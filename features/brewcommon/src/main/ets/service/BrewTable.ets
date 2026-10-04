/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { Logger } from '@ohos/common';
import { BrewSourcePrefs } from './BrewSourcePrefs';
import { BrewSourceStore } from './BrewSourceStore';
import { BrewCacheEpoch } from './BrewCacheEpoch';
import { BrewLoadLog } from '../util/BrewLoadLog';
import { BrewNetNotice } from '../util/BrewNetNotice';
import { BrewHttp } from './BrewHttp';
import type { BrewHttpResult } from './BrewHttp';
import {
  BREW_CATALOG_BOARDS,
  BrewCatalogAlgo,
  CatalogSource,
  catalogSources,
} from './BrewCatalogAlgo';
import type {
  CatalogAnalyticsDoc,
  CatalogCounts,
  CatalogKindResult,
  CatalogRecord,
} from './BrewCatalogAlgo';
import { adapterFor } from './source/BrewSourceAdapter';
import type { BrewSourceAdapter } from './source/BrewSourceAdapter';
import type { BrewCatalogInput } from './source/BrewCatalogInput';
import { catalogThresholdsFor } from '../constant/BrewCatalogThresholds';
import type { CatalogThresholds } from '../constant/BrewCatalogThresholds';
import { BrewBrowseBuilder } from './BrewBrowseBuilder';
import { BrewMetaSync } from './BrewMetaSync';
import type { DescShardOutcome } from './BrewMetaSync';
import { objKeys } from '../util/objkeys';
import {
  BREW_CATALOG_KEEP,
  BREW_CATALOG_TIMEOUT_MS,
  BREW_DESC_FRESH_MS,
  BREW_PERF_TRACE,
  BREW_TABLE_SCHEMA_VERSION,
  BREW_TABLE_STORAGE_KEY,
  BREW_VOL_FRESH_MS,
  CASK_CATEGORY_ORDER,
  FORMULA_CATEGORY_ORDER,
} from '../constant/BrewConstants';
import type { BrewCaskCategory, BrewCategoryCard } from '../model/BrewModels';

const TAG: string = '[BrewTable]';

/** kind 的字面量（`BrewKind` 是枚举、值就是这两个字符串，表与词表都用字面量当键） */
export class BrewKindText {
  public static readonly FORMULA: string = 'formula';
  public static readonly CASK: string = 'cask';
}

/**
 * 目录里一个榜的一条。`prior` / `velocity` / `score` **只有榜单条目会填**。
 *
 * 浏览集条目只填 `token` / `vol30d` / `vol365d`（`vol365d` 仅在算榜时用到），
 * 后三个留 0 —— 浏览页与搜索页都不读它们，而浏览集有一万三千条。
 */
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

/** 一个 kind 的窗口与规模元信息（Discover 页的「基于最近可用数据」与自检日志用） */
export interface CatalogKindMeta {
  windowStart: string;
  windowEnd: string;
  totalItems: number;
  totalCount: number;
  rawTokens: number;
  families: number;
  candidates: number;
  thresholds: CatalogThresholds;
  actualVolP: number;
  actualPriorP: number;
  multiEntryTokens: number;
}

/** 安装量片的一行：两个窗口共用一个 token 键，比拆成两张表省一半键 */
export interface BrewVolRow {
  v30: number;
  v365: number;
}

/** 一个聚合端点的取数结果 */
interface CatalogProbeResult {
  job: CatalogSource;
  code: number;
  text: string;
  lastModified: string;
}

/** 落盘形状。只存原始材料与榜单产物；浏览页结构在内存里派生 */
interface BrewTableStored {
  schemaVersion: number;
  /** `[kind][token] -> {30d, 365d}`，来自 4 个聚合端点 */
  vol: Record<string, Record<string, BrewVolRow>>;
  /** `[kind][token] -> desc`。空描述不写入，于是天然表达「这条没有可展示文案」 */
  desc: Record<string, Record<string, string>>;
  volStamps: Record<string, string>;
  volReadyAt: number;
  descStamps: Record<string, string>;
  descReadyAt: number;
  /** `[kind][boardKey] -> 条目[]`，只在安装量片重算过之后变化 */
  boards: Record<string, Record<string, CatalogEntry[]>>;
  meta: Record<string, CatalogKindMeta>;
}

/**
 * 设备端包表：**一份按 token 的表，两片独立**。
 *
 * - **安装量片**（`vol`）：4 个聚合端点，给出全量包的 30 天与 365 天安装次数。
 *   浏览集排序与三张榜的唯一数字来源。
 * - **描述片**（`desc`）：`formula.json` / `cask.json`，只抽 `token → desc`。
 *   分类（自建词表）与列表主文案的唯一来源；它的键集合同时充当
 *   「上游当前存在这个包」的权威清单。
 *
 * 两片分别取、分别记条件请求基准、分别标记新鲜度，一片失败不牵连另一片。
 *
 * ## 浏览集成员规则：一次相交
 *
 * `vol` 的键 ∩ `desc` 的键。统计窗口天然含历史幽灵（已下线 / 改名 / 弃用的包名），
 * 描述片来自当前清单，取交集等于一次做完「索引可信度闸门 + 逐条探测 + 负缓存」
 * 三样东西拼出来的效果，而且不需要发任何请求去验证。
 *
 * ## 取数只有一个入口
 *
 * `refresh()` 由进程启动与每次页面进入调用，内部按两片各自的新鲜窗口决定发不发请求，
 * **永远 resolve、从不 reject** —— 失败以「某一片的 `readyAt` 没被更新」表达。
 * 页面用 `current()` 与各 `*Browse()` 读内存派生结构，不等网络。
 */
export class BrewTable {
  private static stored: BrewTableStored | undefined = undefined;
  private static loaded: boolean = false;
  /** 浏览集（按 30 天安装量降序）。搜索按这个顺序遍历，顺序变了结果排序就会变，单独留一份 */
  private static flat: Record<string, CatalogEntry[]> = {};
  private static browseFormula: BrewCategoryCard[] = [];
  private static browseCask: BrewCaskCategory[] = [];
  private static inFlight: Promise<void> | undefined = undefined;
  /** 世代号在 `refresh()` 入口捕获一次。原先四个静态字段（live / stamp / catalog / meta）合并成这一个 */
  private static epoch: number = BrewCacheEpoch.current();
  private static observers: Array<() => void> = [];
  private static volFetched: number = 0;
  private static descFetched: number = 0;
  private static failures: number = 0;
  /** 本进程是否已经跑过一次 `refresh()`。用来只在第一次打冷启动原点与跑自检 */
  private static bootstrapped: boolean = false;

  // ------------------------------------------------------------ 读

  /**
   * 内存表。首次访问从 Preference 读一次整份并派生浏览结构。
   *
   * 派生只在**两片之一刚写入后**重做（`rebuild` 的调用点只有 `applyVol` / `applyDesc`），
   * 所以反复读不会重复付出排序与分类的代价。
   */
  public static current(): BrewTableStored {
    if (!BrewTable.loaded) {
      BrewTable.loaded = true;
      const t0: number = Date.now();
      const raw: BrewTableStored | null = BrewSourcePrefs.get<BrewTableStored>(BREW_TABLE_STORAGE_KEY);
      const usable: boolean = raw !== null && raw.vol !== undefined && raw.desc !== undefined &&
        raw.schemaVersion === BREW_TABLE_SCHEMA_VERSION;
      BrewTable.stored = usable ? raw as BrewTableStored : BrewTable.blank();
      BrewTable.derived(Date.now() - t0, usable ? 'pref' : (raw === null ? 'missing' : 'schema'));
    }
    return BrewTable.stored ?? BrewTable.blank();
  }

  /** 安装量片成功过至少一次 */
  public static volReady(): boolean {
    return BrewTable.current().volReadyAt > 0;
  }

  /** 描述片成功过至少一次 */
  public static descReady(): boolean {
    return BrewTable.current().descReadyAt > 0;
  }
  /**
   * 表的当前状态，供页面决定呈现。**三档**：
   *
   * - `ready`：两片都成功过，有内容可上屏；
   * - `building`：安装量片已到、描述片未到 —— 首次安装的正常暂态（描述片实测 21.7 秒，
   *   上游慢时到 578 秒）。榜有成员、行只有 token 与数字；浏览页与搜索还拿不到描述；
   * - `empty`：安装量片未到 —— 浏览集没有成员（它由安装量排序驱动），只有搜索还能用。
   *
   * 判据是**两片分别**有没有成功过，不是「成员是否为空」—— 后者会把
   * 「描述片到了但某个分类恰好没有成员」误判成故障。
   */
  public static state(): string {
    if (BrewTable.volReady() && BrewTable.descReady()) {
      return 'ready';
    }
    return BrewTable.volReady() ? 'building' : 'empty';
  }

  /** 描述片里的描述。空串 = 这一条没被写进来（上游 `desc: null`，或描述片还没到） */
  public static descOf(kind: string, token: string): string {
    return BrewTable.assured().desc[kind]?.[token] ?? '';
  }

  /** 浏览集（按 30 天安装量降序，只含两片都有的 token） */
  public static rows(kind: string): CatalogEntry[] {
    BrewTable.current();
    return BrewTable.flat[kind] ?? [];
  }

  /** Formulae 首页的分类卡（已分组、已排序、已编号）。构页就是读它 */
  public static formulaBrowse(): BrewCategoryCard[] {
    BrewTable.current();
    return BrewTable.browseFormula;
  }

  /** Casks 首页的分类（三层结构） */
  public static caskBrowse(): BrewCaskCategory[] {
    BrewTable.current();
    return BrewTable.browseCask;
  }

  /** 榜上某榜的条目 */
  public static boardRows(kind: string, boardKey: string): CatalogEntry[] {
    return BrewTable.current().boards[kind]?.[boardKey] ?? [];
  }

  /** 一个 kind 的窗口与规模元信息 */
  public static metaOf(kind: string): CatalogKindMeta | undefined {
    return BrewTable.current().meta[kind];
  }

  /** 目录里的 30 天安装量。详情页降级骨架在没有单条文档时用它显示数字 */
  public static installCount(kind: string, token: string): number {
    return BrewTable.current().vol[kind]?.[token]?.v30 ?? 0;
  }

  /** 表体量与两片的时间，一行（`BrewCacheAdmin.stats` 与自检日志用） */
  public static statsLine(): string {
    const one: BrewTableStored = BrewTable.current();
    return `vol=[${BrewTable.countVol()}] desc=[${BrewTable.countDesc()}] ` +
      `browse formula=${(BrewTable.flat[BrewKindText.FORMULA] ?? []).length} ` +
      `cask=${(BrewTable.flat[BrewKindText.CASK] ?? []).length} ` +
      `volAge=${BrewTable.ageOf(one.volReadyAt)}s descAge=${BrewTable.ageOf(one.descReadyAt)}s ` +
      `volFetched=${BrewTable.volFetched} descFetched=${BrewTable.descFetched} failures=${BrewTable.failures}`;
  }

  // ------------------------------------------------------------ 落地通知

  /**
   * 订阅「表已变化」。
   *
   * **必须成对**。页面已经在显示「正在准备本地数据」时，只有靠它才知道什么时候重出内容。
   * 浏览页的生命周期回调会被触发不止一次（双载导致两次 `aboutToAppear`），
   * 所以退订按同一个函数引用做 `indexOf` 删除。
   */
  public static addObserver(observer: () => void): void {
    if (BrewTable.observers.indexOf(observer) < 0) {
      BrewTable.observers.push(observer);
    }
  }

  public static removeObserver(observer: () => void): void {
    const index: number = BrewTable.observers.indexOf(observer);
    if (index >= 0) {
      BrewTable.observers.splice(index, 1);
    }
  }

  /**
   * 通知所有订阅者「表已变化」。
   *
   * `BrewTable.rebuild` 内部调它。`BrewCacheAdmin.clear` 清完激活源也要调 ——
   * 内存副本已重置，但页面还挂着旧卡片。那次调用必须在**清盘完成之后**：
   * 订阅者收到通知会立刻重新读盘，早一步通知就会把还没被清掉的旧内容重新装进内存副本。
   */
  public static notifyObservers(): void {
    // 逐个包 try/catch：一个订阅者抛错不该让其余页面收不到通知
    BrewTable.observers.slice().forEach((observer: () => void) => {
      try {
        observer();
      } catch (error) {
        const err = error as Error;
        Logger.error(TAG, `observer threw, ${err?.message}`);
      }
    });
  }

  // ------------------------------------------------------------ 进程内重置

  /**
   * 清空进程内副本（`BrewCacheAdmin.clear` 清激活源时调）。
   *
   * 观测者**不清** —— 它们属于页面，与盘上数据无关。清了会让正在显示
   * 「正在准备本地数据」的页面永远收不到落地通知；清完之后由
   * `BrewCacheAdmin.clear` 调 `notifyObservers` 让它们重出内容。
   *
   * 世代号**保持原值** —— 它记的是「在场这一轮取数是在哪个世代开始的」，写入点拿它
   * 与 `BrewCacheEpoch.current()` 比对来决定要不要丢弃。这里若改成新值，清空前发起、
   * 此刻仍在途的那一轮会比对成功，把刚清掉的两片整份写回盘里；保持旧值，守卫才会
   * 如实丢弃它。清空之后新开的取数会在自己入口重新捕获，不受影响。
   */
  public static resetMemory(): void {
    BrewTable.stored = undefined;
    BrewTable.loaded = false;
    BrewTable.flat = {};
    BrewTable.browseFormula = [];
    BrewTable.browseCask = [];
    BrewTable.volFetched = 0;
    BrewTable.descFetched = 0;
    BrewTable.failures = 0;
    Logger.info(TAG, 'memory table reset');
  }

  // ------------------------------------------------------------ 取数

  /**
   * 按两片各自的新鲜窗口决定要不要发请求。**永远 resolve**。
   *
   * `force` 供重试按钮用（跳过窗口判定）。撞上在途请求时直接复用同一个 Promise。
   */
  public static refresh(force: boolean = false): Promise<void> {
    const pending: Promise<void> | undefined = BrewTable.inFlight;
    if (pending !== undefined) {
      // 去重是这里最需要被看见的判定：三个首页 + splash 会在同一秒里各调一次，
      // 没有这一行日志，「只发了 6 个请求」会被误读成「只调了一次 refresh」
      BrewLoadLog.debug('table_refresh', 'in-flight', 0,
        `force=${force} 复用已有在途请求，未新开一轮 | ${BrewTable.statsLine()}`);
      return pending;
    }
    // 世代号在**操作入口**捕获：本次取数会写安装量片与描述片。
    // 清空发生在这之后的话，这次的结果必须整份丢弃。
    BrewTable.epoch = BrewCacheEpoch.current();
    const t0: number = Date.now();
    Logger.info(TAG, `[refresh] start force=${force} epoch=${BrewTable.epoch} | ${BrewTable.statsLine()}`);
    const task: Promise<void> = BrewTable.doRefresh(force)
      .catch((error: Error) => {
        // 兜底：两片内部各自已经收敛，这里只防未预料的异常
        Logger.error(TAG, `refresh failed, ${error.message}`);
        BrewTable.failures++;
      })
      .then(() => {
        BrewTable.inFlight = undefined;
        Logger.info(TAG, `[refresh] done in ${Date.now() - t0}ms | ${BrewTable.statsLine()}`);
      });
    BrewTable.inFlight = task;
    return task;
  }

  private static async doRefresh(force: boolean): Promise<void> {
    const t0: number = Date.now();
    BrewTable.bootstrapOnce(t0);
    const one: BrewTableStored = BrewTable.current();
    const needVol: boolean = force || BrewTable.stale(one.volReadyAt, BREW_VOL_FRESH_MS);
    const needDesc: boolean = force || BrewTable.stale(one.descReadyAt, BREW_DESC_FRESH_MS);
    BrewLoadLog.info('table_refresh', `${needVol ? 'vol-stale' : 'vol-fresh'}/${needDesc ? 'desc-stale' : 'desc-fresh'}`,
      Date.now() - t0,
      `volAge=${BrewTable.ageOf(one.volReadyAt)}s/${BREW_VOL_FRESH_MS}ms ` +
      `descAge=${BrewTable.ageOf(one.descReadyAt)}s/${BREW_DESC_FRESH_MS}ms | ${BrewTable.statsLine()}`);
    // 两片都不需要取 → 一条 debug 收尾，因为此时页面拿到的是纯内存结果
    if (!needVol && !needDesc) {
      BrewLoadLog.debug('table_refresh', 'all-fresh', Date.now() - t0,
        '两片都在窗口内，本轮零请求 | ' + BrewTable.statsLine());
    }
    // 常驻提示：**确实要发请求**且**两片都还没到**时才弹，任意一片写入后由 `rebuild` 撒掉。
    //
    // 两个条件缺一不可：
    //   - `needVol || needDesc` —— 排除「两片都在窗口内、一个字节都不发」的情况。
    //     实测踩过：两片新鲜时 `needVol=needDesc=false`，而 `!(needVol && needDesc)` 算出来是 true，
    //     于是每次进页面都弹一次常驻提示。可这一轮没有任何请求，也就没有任何东西会把它撒掉 ——
    //     数据早已就绪，提示却一直挂着（真机截图确认）。
    //   - `!volReady && !descReady` —— 只有「一片都拿不到」才需要额外解释。
    //     一片已到时页面自己有话可说（BUILDING 状态带说明文字），常驻提示是多余的。
    //
    // 与旧设计的关键差别：旧实现的 `settle` 挂在每个页面自己的构页完成上，而
    // `shown` 是全局静态量 —— 一个页面构建完成就能把另一个页面正在等的数据提示撒掉
    // （实测：Discover 还在等 17 秒的目录探针，Formulae 一构建完提示就没了）。
    // 现在提示只有一个主人：表。
    if ((needVol || needDesc) && !BrewTable.volReady() && !BrewTable.descReady()) {
      BrewNetNotice.willFetch('table', 'vol=' + needVol + ' desc=' + needDesc +
        ` volAge=${BrewTable.ageOf(one.volReadyAt)}s descAge=${BrewTable.ageOf(one.descReadyAt)}s`);
    }
    // 两片**并行开始**：下载互不依赖。串行会让 cask 排在 formula 后面干等 ——
    // 上游慢时单文件实测到 578s，那正是原设计里 13.3 分钟的成因。
    const jobs: Promise<void>[] = [];
    if (needVol) {
      jobs.push(BrewTable.refreshVol());
    }
    if (needDesc) {
      jobs.push(BrewTable.refreshDesc());
    }
    await Promise.all(jobs);
    // 本轮结束了，却仍有片没到（取数失败，或被世代号守卫丢弃）→ 撤掉常驻提示。
    //
    // `rebuild` 里那次 settle 只在**两片都到**时执行，而两片同时失败时它根本不执行
    // （没有写入就没有 `rebuild`）。首次安装断网正是这种情形：提示弹出来之后没有任何
    // 东西会撤掉它，只能靠用户点关闭自救。
    if (!BrewTable.volReady() || !BrewTable.descReady()) {
      BrewNetNotice.settle('table', '本轮结束，仍有片未到 | ' + BrewTable.statsLine());
    }
  }

  /**
   * 进程内第一次 `refresh()` 的额外动作：打冷启动原点 + 跑源子系统自检。
   *
   * 原点行的作用是让 `[load]` 时间线**自包含** —— 设备 hilog 环形缓冲只回收到约 12 秒前，
   * 抓日志时 `Ability onCreate` 经常已经被挤掉（实测 `--from 90s` 与 `--from 600s` 同一起点）。
   * 其余 `[load]` 行都自带 `at=`，与本行相减即得相对耗时。
   *
   * 自检放在这里是因为本方法是数据层在进程里的第一个动作（splash 的 preloadResources），
   * 早于任何页面读 `activeBaseUrl`。
   */
  private static bootstrapOnce(t0: number): void {
    if (BrewTable.bootstrapped) {
      return;
    }
    BrewTable.bootstrapped = true;
    BrewLoadLog.info('cold_start', 'origin', 0,
      '数据层冷启动原点（≈ Ability onCreate 后 ~300ms）；其余 [load] 行的 at= 减本行即得相对耗时');
    BrewMetaSync.runDiagnostics();
  }

  /** 从未成功过，或者已超窗口 */
  private static stale(readyAt: number, windowMs: number): boolean {
    if (readyAt <= 0) {
      return true;
    }
    const age: number = Date.now() - readyAt;
    return age >= 0 && age >= windowMs;
  }

  // ------------------------------------------------------------ 安装量片

  private static async refreshVol(): Promise<void> {
    const t0: number = Date.now();
    const sourceId: string = BrewSourceStore.sessionActive().id;
    const base: string = BrewSourceStore.activeBaseUrl();
    const jobs: CatalogSource[] = catalogSources();
    Logger.info(TAG, `[vol] start source=${sourceId} dialect=${BrewSourceStore.dialectOf(sourceId)} ` +
      `endpoints=${jobs.length} base=${base}`);
    // 无聚合端点的源由适配器合成同形状的两份文档
    if (jobs.length === 0) {
      const adapter: BrewSourceAdapter = adapterFor(BrewSourceStore.dialectOf(sourceId));
      const inputs: BrewCatalogInput[] | undefined = await adapter.synthCatalogDocs(base);
      if (inputs === undefined) {
        BrewTable.noteVolFailure(sourceId, t0, '聚合统计不可用');
        return;
      }
      const bodies: CatalogProbeResult[] = [];
      inputs.forEach((input: BrewCatalogInput) => {
        bodies.push(BrewTable.toProbeOf(new CatalogSource(input.kind, input.win, input.url), input.text,
          input.lastModified));
      });
      BrewTable.applyVol(bodies, sourceId, t0, 0, inputs.length);
      return;
    }
    const stamps: Record<string, string> = BrewTable.current().volStamps;
    let probed: CatalogProbeResult[];
    try {
      const probes: Promise<CatalogProbeResult>[] = jobs.map((job: CatalogSource) => {
        const headers: Record<string, string> = {};
        const stamp: string | undefined = stamps[job.url];
        if (stamp !== undefined && stamp.length > 0) {
          headers['If-Modified-Since'] = stamp;
        }
        // 条件请求有没有发出去，直接决定这一轮是 0 字节还是全量下载。
        // 端点逐个打而不是汇总打，因为「哪个端点没带条件请求」是排查的重点
        BrewLoadLog.debug('table_vol', stamp !== undefined && stamp.length > 0 ? 'conditional' : 'full',
          Date.now() - t0, `${job.kind}/${job.win} ${job.url} stamp=[${stamp ?? ''}]`);
        return BrewHttp.request(job.url, undefined, headers, BREW_CATALOG_TIMEOUT_MS)
          .then((res: BrewHttpResult) => {
            Logger.debug(TAG, `[vol] ${job.kind}/${job.win} → ${res.code} ${res.text.length}B ` +
              `${Date.now() - t0}ms lastModified=[${res.headers['last-modified'] ?? ''}]`);
            return BrewTable.toProbe(job, res);
          });
      });
      probed = await Promise.all(probes);
    } catch (error) {
      const err = error as Error;
      BrewTable.noteVolFailure(sourceId, t0, err.message);
      return;
    }
    const notModified: number = probed.filter((one: CatalogProbeResult) => one.code === 304).length;
    BrewLoadLog.debug('table_vol', 'probe-done', Date.now() - t0,
      probed.map((one: CatalogProbeResult) => `${one.job.kind}/${one.job.win}=${one.code}`).join(' ') +
      ` notModified=${notModified}/${probed.length}`);
    if (notModified === probed.length && BrewTable.current().volReadyAt > 0) {
      // 整批没变：0 字节续期。榜单不重算（同输入必然同输出）
      BrewTable.renewVol(sourceId, t0, notModified, probed.length);
      return;
    }
    // 有端点变了（或本地没有基准）：把没带回响应体的补取一遍
    const missing: CatalogProbeResult[] = probed.filter((one: CatalogProbeResult) => one.code !== 200);
    if (missing.length > 0) {
      Logger.info(TAG, `[vol] ${missing.length}/${probed.length} 个端点需要重新取全文: ` +
        missing.map((one: CatalogProbeResult) => `${one.job.kind}/${one.job.win}=${one.code}`).join(' '));
    }
    let fetched: CatalogProbeResult[];
    try {
      const refetches: Promise<CatalogProbeResult>[] = missing.map((one: CatalogProbeResult) =>
        BrewHttp.request(one.job.url, undefined, {}, BREW_CATALOG_TIMEOUT_MS)
          .then((res: BrewHttpResult) => {
            return BrewTable.toProbe(one.job, res);
          }));
      fetched = await Promise.all(refetches);
    } catch (error) {
      const err = error as Error;
      BrewTable.noteVolFailure(sourceId, t0, err.message);
      return;
    }
    const bodies: CatalogProbeResult[] = probed.filter((one: CatalogProbeResult) => one.code === 200)
      .concat(fetched.filter((one: CatalogProbeResult) => one.code === 200));
    BrewTable.applyVol(bodies, sourceId, t0, notModified, probed.length);
  }

  /**
   * 解析聚合文件 → 算三张榜 → 写安装量片。
   *
   * **窗口不齐就整份放弃**：某个窗口的端点持续非 200 时 `counts[kind]['30d']` 是 undefined，
   * 直接喂给 `BrewCatalogAlgo.build` 会在 `Object.keys(undefined)` 上抛 TypeError，
   * 而那个异常在 catch 里只能显示成一句与真实原因无关的话。这里提前判掉，
   * 保留盘上旧片继续用。
   */
  private static applyVol(bodies: CatalogProbeResult[], sourceId: string, t0: number,
    notModified: number, total: number): void {
    const counts: Record<string, Record<string, CatalogCounts>> = {};
    const nextStamps: Record<string, string> = {};
    for (let i = 0; i < bodies.length; i++) {
      const one: CatalogProbeResult = bodies[i];
      let parsed: CatalogCounts;
      try {
        parsed = BrewCatalogAlgo.parseCounts(JSON.parse(one.text) as CatalogAnalyticsDoc);
      } catch (error) {
        const err = error as Error;
        BrewTable.noteVolFailure(sourceId, t0, `${one.job.kind}/${one.job.win} 解析失败 ${err.message}`);
        return;
      }
      if (counts[one.job.kind] === undefined) {
        const emptyWindows: Record<string, CatalogCounts> = {};
        counts[one.job.kind] = emptyWindows;
      }
      counts[one.job.kind][one.job.win] = parsed;
      if (one.lastModified.length > 0) {
        nextStamps[one.job.url] = one.lastModified;
      }
    }
    const dialect: string = BrewSourceStore.dialectOf(sourceId);
    const adapter: BrewSourceAdapter = adapterFor(dialect);
    const kinds: string[] = Object.keys(counts);
    for (let i = 0; i < kinds.length; i++) {
      const windows: Record<string, CatalogCounts> = counts[kinds[i]];
      if (windows['30d'] === undefined || windows['365d'] === undefined) {
        BrewTable.noteVolFailure(sourceId, t0,
          `${kinds[i]} 窗口不齐（只拿到 ${Object.keys(windows).join(',')}）→ 保留盘上旧安装量片`);
        return;
      }
    }
    const nextVol: Record<string, Record<string, BrewVolRow>> = {};
    const nextBoards: Record<string, Record<string, CatalogEntry[]>> = {};
    const nextMeta: Record<string, CatalogKindMeta> = {};
    for (let i = 0; i < kinds.length; i++) {
      const kind: string = kinds[i];
      const windows: Record<string, CatalogCounts> = counts[kind];
      const a30: Record<string, number> = {};
      const a365: Record<string, number> = {};
      const rows: Record<string, BrewVolRow> = {};
      const counts30: Record<string, number> = windows['30d'].counts;
      objKeys(counts30).forEach((token: string) => {
        const v30: number = counts30[token];
        const v365: number = windows['365d'].counts[token] ?? 0;
        const row: BrewVolRow = { v30: v30, v365: v365 };
        rows[token] = row;
        a30[token] = v30;
        a365[token] = v365;
      });
      const thresholds: CatalogThresholds = catalogThresholdsFor(dialect, kind);
      const result: CatalogKindResult =
        BrewCatalogAlgo.build(kind, a30, a365, adapter.priorDivisor, thresholds);
      nextVol[kind] = rows;
      nextBoards[kind] = BrewTable.toBoards(result);
      nextMeta[kind] = BrewTable.toKindMeta(windows['30d'], result, thresholds);
      BrewLoadLog.info('table_vol', 'net-200', Date.now() - t0,
        `kind=${kind} rows=${Object.keys(rows).length} boards=${BrewTable.boardCount(nextBoards[kind])} ` +
        `| ${BrewTable.metaLine(nextMeta[kind])}`);
    }
    BrewTable.writeVol(nextVol, nextStamps, nextBoards, nextMeta, sourceId, t0, notModified, total);
  }

  /** 整批 304：只推进时间戳，榜单不重算 */
  private static renewVol(sourceId: string, t0: number, notModified: number, total: number): void {
    if (BrewTable.epoch !== BrewCacheEpoch.current()) {
      Logger.info(TAG, '[BrewCache] epoch mismatch, dropped write key=brew_table#vol');
      return;
    }
    const stored: BrewTableStored = BrewTable.current();
    stored.volReadyAt = Date.now();
    BrewTable.persist();
    BrewSourceStore.noteVolOk(sourceId);
    BrewTable.rebuild('vol-renewed');
    BrewLoadLog.info('table_vol', 'probe-304', Date.now() - t0,
      `${notModified}/${total} 个端点 304, 0B → 整批未变，榜单不重算 | ${BrewTable.statsLine()}`);
  }

  private static writeVol(nextVol: Record<string, Record<string, BrewVolRow>>,
    nextStamps: Record<string, string>, nextBoards: Record<string, Record<string, CatalogEntry[]>>,
    nextMeta: Record<string, CatalogKindMeta>, sourceId: string, t0: number,
    notModified: number, total: number): void {
    if (BrewTable.epoch !== BrewCacheEpoch.current()) {
      Logger.info(TAG, '[BrewCache] epoch mismatch, dropped write key=brew_table#vol');
      return;
    }
    const stored: BrewTableStored = BrewTable.current();
    stored.vol = nextVol;
    stored.volStamps = nextStamps;
    stored.boards = nextBoards;
    stored.meta = nextMeta;
    stored.volReadyAt = Date.now();
    BrewTable.persist();
    BrewSourceStore.noteVolOk(sourceId);
    BrewTable.volFetched++;
    BrewTable.rebuild('vol-applied');
    BrewLoadLog.info('table_vol', 'net-200', Date.now() - t0,
      `notModified=${notModified}/${total} | ${BrewTable.statsLine()}`);
  }

  private static noteVolFailure(sourceId: string, t0: number, detail: string): void {
    BrewTable.failures++;
    Logger.error(TAG, `vol shard failed, ${detail}`);
    BrewSourceStore.noteError(sourceId, 'vol', detail);
    BrewLoadLog.warn('table_vol', 'fetch-failed', Date.now() - t0,
      detail + ' → 沿用盘上旧安装量片（或空）');
  }

  // ------------------------------------------------------------ 描述片

  /**
   * 描述片。下载与流式扫描在 `BrewMetaSync` 里（taskpool、等待预算、迟到写入这些
   * 已经踩过坑的机制原样保留），本方法只负责发起，结果回来时由回调写表。
   *
   * 注意它**不 await 完整下载**：`fetchDescShards` 在等待预算到期后就 resolve，
   * 每个 kind 真正结束时通过回调写入（迟到写入）。
   */
  private static refreshDesc(): Promise<void> {
    const stored: BrewTableStored = BrewTable.current();
    const hasDesc: Record<string, boolean> = {};
    [BrewKindText.FORMULA, BrewKindText.CASK].forEach((kind: string) => {
      const one: Record<string, string> = stored.desc[kind];
      hasDesc[kind] = one !== undefined && objKeys(one).length > 0;
    });
    // 条件请求只在「盘上已有该 kind 的描述」时才发，所以这两行是描述片会不会走 0 字节的判据
    BrewLoadLog.debug('table_desc', 'start', 0,
      `descOnDisk formula=${BrewTable.sizeOf(stored.desc[BrewKindText.FORMULA])} ` +
      `cask=${BrewTable.sizeOf(stored.desc[BrewKindText.CASK])} ` +
      `stamp formula=[${stored.descStamps[BrewKindText.FORMULA] ?? ''}] ` +
      `cask=[${stored.descStamps[BrewKindText.CASK] ?? ''}]`);
    return BrewMetaSync.fetchDescShards(stored.descStamps, hasDesc, (outcome: DescShardOutcome) => {
      BrewTable.applyDesc(outcome);
    });
  }

  /**
   * 落一个 kind 的描述。
   *
   * **失败或 304 都保留旧表**：304 说明端点可达但内容未变；失败更不能动 ——
   * 浏览集的成员规则是「安装量 ∩ 描述」，描述片一旦被清空，整页就空了。
   */
  public static applyDesc(outcome: DescShardOutcome): void {
    const t0: number = Date.now();
    const sourceId: string = BrewSourceStore.sessionActive().id;
    if (outcome.notModified) {
      if (BrewTable.epoch !== BrewCacheEpoch.current()) {
        return;
      }
      const stored: BrewTableStored = BrewTable.current();
      if (outcome.stamp.length > 0) {
        stored.descStamps[outcome.kind] = outcome.stamp;
      }
      stored.descReadyAt = Date.now();
      BrewTable.persist();
      BrewSourceStore.noteDescOk(sourceId);
      BrewTable.rebuild('desc-renewed');
      BrewLoadLog.info('table_desc', 'net-304', t0,
        `kind=${outcome.kind} 未变（0 字节）→ 保留旧表 ${BrewTable.sizeOf(stored.desc[outcome.kind])} 条`);
      return;
    }
    if (!outcome.ok || objKeys(outcome.table).length === 0) {
      BrewTable.failures++;
      Logger.error(TAG, `desc shard failed, kind=${outcome.kind}, ${outcome.detail}`);
      BrewSourceStore.noteError(sourceId, 'desc', outcome.detail);
      BrewLoadLog.warn('table_desc', 'sync-failed', t0,
        `kind=${outcome.kind} ${outcome.detail} → 保留上一份描述表`);
      return;
    }
    if (BrewTable.epoch !== BrewCacheEpoch.current()) {
      Logger.info(TAG, '[BrewCache] epoch mismatch, dropped write key=brew_table#desc');
      return;
    }
    const stored: BrewTableStored = BrewTable.current();
    if (stored.desc[outcome.kind] === undefined) {
      stored.desc[outcome.kind] = {};
    }
    Object.keys(outcome.table).forEach((token: string) => {
      const desc: string = outcome.table[token];
      // 空描述不写入：这一条对浏览集而言等同于「上游没有」。
      // 与 cask 那 2645 条 `desc: null` 的处理一致，也省得把它们塞进索引。
      if (desc.length > 0) {
        stored.desc[outcome.kind][token] = desc;
      }
    });
    if (outcome.stamp.length > 0) {
      stored.descStamps[outcome.kind] = outcome.stamp;
    }
    stored.descReadyAt = Date.now();
    BrewTable.persist();
    BrewSourceStore.noteDescOk(sourceId);
    BrewTable.descFetched++;
    BrewTable.rebuild('desc-applied');
    BrewLoadLog.info('table_desc', 'net-200', t0,
      `kind=${outcome.kind} pairs=${BrewTable.sizeOf(stored.desc[outcome.kind])} ` +
      `${outcome.detail} → 已写入描述片`);
  }

  // ------------------------------------------------------------ 派生与写盘

  /**
   * 重算内存派生结构：浏览集 + 两个页面的分组结构。
   *
   * 只在两片之一刚写入后调用（`rebuild`）或首次读盘时调用（`current`）。
   */
  private static derived(readMs: number, reason: string): void {
    const stored: BrewTableStored = BrewTable.stored ?? BrewTable.blank();
    const formulaRows: CatalogEntry[] = BrewTable.intersection(BrewKindText.FORMULA);
    const caskRows: CatalogEntry[] = BrewTable.intersection(BrewKindText.CASK);
    BrewTable.flat = {};
    BrewTable.flat[BrewKindText.FORMULA] = formulaRows;
    BrewTable.flat[BrewKindText.CASK] = caskRows;
    BrewTable.browseFormula = BrewBrowseBuilder.formulaPage(formulaRows,
      stored.desc[BrewKindText.FORMULA] ?? {}, FORMULA_CATEGORY_ORDER);
    BrewTable.browseCask = BrewBrowseBuilder.caskPage(caskRows,
      stored.desc[BrewKindText.CASK] ?? {}, CASK_CATEGORY_ORDER);
    if (BREW_PERF_TRACE) {
      Logger.info(TAG, `[perf] table derived reason=${reason} readMs=${readMs} ` +
        `browse formula=${formulaRows.length} cask=${caskRows.length} ` +
        `cards=${BrewTable.browseFormula.length}/${BrewTable.browseCask.length}`);
    }
    if (reason !== 'vol-renewed' && reason !== 'desc-renewed') {
      BrewLoadLog.info('table', reason, readMs, BrewTable.statsLine());
    }
  }

  private static rebuild(reason: string): void {
    const t0: number = Date.now();
    BrewTable.derived(0, reason);
    BrewLoadLog.debug('table', reason, Date.now() - t0,
      `派生完成 browse formula=${(BrewTable.flat[BrewKindText.FORMULA] ?? []).length} ` +
      `cask=${(BrewTable.flat[BrewKindText.CASK] ?? []).length} ` +
      `cards=${BrewTable.browseFormula.length}/${BrewTable.browseCask.length} ` +
      `observers=${BrewTable.observers.length}`);
    // 两片都到 → 数据齐了，撤掉常驻提示。任一片失败时提示会留着，
    // 而页面此时会自己显示「无法获取数据」并给重试按钮。
    if (BrewTable.volReady() && BrewTable.descReady()) {
      BrewNetNotice.settle('table', BrewTable.statsLine());
    }
    const count: number = BrewTable.observers.length;
    if (count > 0) {
      Logger.debug(TAG, `[rebuild] reason=${reason} → 通知 ${count} 个观察者`);
    }
    BrewTable.notifyObservers();
  }

  /** `vol` 的键 ∩ `desc` 的键，按 30 天安装量降序 */
  private static intersection(kind: string): CatalogEntry[] {
    const stored: BrewTableStored = BrewTable.assured();
    const vol: Record<string, BrewVolRow> = stored.vol[kind] ?? {};
    const desc: Record<string, string> = stored.desc[kind] ?? {};
    const rows: CatalogEntry[] = [];
    objKeys(vol).forEach((token: string) => {
      const text: string | undefined = desc[token];
      if (text === undefined || text.length === 0) {
        return;
      }
      const one: BrewVolRow = vol[token];
      const row: CatalogEntry =
        { token: token, vol30d: one.v30, vol365d: one.v365, prior: 0, velocity: 0, score: 0 };
      rows.push(row);
    });
    rows.sort((a: CatalogEntry, b: CatalogEntry) => b.vol30d - a.vol30d);
    return rows;
  }

  /** 已经 `current()` 过的内存副本。派生路径用它，避免再走一遍 `current()` 的判空 */
  private static assured(): BrewTableStored {
    return BrewTable.stored ?? BrewTable.blank();
  }

  /**
   * 一个 kind 的条目数。`undefined` 当 0。
   *
   * 写成方法而不是 `Object.keys(x ?? {}).length`：那个 `{}` 在 `??` 里拿不到上下文类型，
   * ArkTS 会报 `arkts-no-untyped-obj-literals`。
   */
  private static sizeOf(one: Record<string, string> | undefined): number {
    return one === undefined ? 0 : objKeys(one).length;
  }

  private static persist(): void {
    const t0: number = Date.now();
    const one: BrewTableStored = BrewTable.assured();
    BrewSourcePrefs.set<BrewTableStored>(BREW_TABLE_STORAGE_KEY, one);
    // 表是本层最贵的一份写入（上游量级 MB）。GSKV 的 `putSync` 只写进内存缓存页，
    // 不显式刷盘的话进程被回收就丢
    BrewSourcePrefs.persistNow();
    // 写入耗时单独打 info：它是唯一一处会阻塞主线程的同步 I/O，
    // 而它耗在什么时候直接影响「写入后页面卡一下」的归因
    Logger.info(TAG, `[persist] wrote brew_table vol=${BrewTable.countVol()} desc=${BrewTable.countDesc()} ` +
      `in ${Date.now() - t0}ms`);
  }

  private static blank(): BrewTableStored {
    return {
      schemaVersion: BREW_TABLE_SCHEMA_VERSION,
      vol: {},
      desc: {},
      volStamps: {},
      volReadyAt: 0,
      descStamps: {},
      descReadyAt: 0,
      boards: {},
      meta: {},
    };
  }

  // ------------------------------------------------------------ 榜单产物

  private static toProbe(job: CatalogSource, res: BrewHttpResult): CatalogProbeResult {
    return { job: job, code: res.code, text: res.text, lastModified: res.headers['last-modified'] ?? '' };
  }

  /** 适配器合成出来的文档：视作已取到的 200 响应 */
  private static toProbeOf(job: CatalogSource, text: string, lastModified: string): CatalogProbeResult {
    return { job: job, code: 200, text: text, lastModified: lastModified };
  }

  private static toBoards(result: CatalogKindResult): Record<string, CatalogEntry[]> {
    const boards: Record<string, CatalogEntry[]> = {};
    BREW_CATALOG_BOARDS.forEach((pair: string[], index: number) => {
      const boardKey: string = pair[0];
      const rows: CatalogRecord[] = index === 0 ? result.rising :
        (boardKey === 'alltime' ? result.alltime : result.fresh);
      boards[boardKey] = rows.slice(0, BREW_CATALOG_KEEP)
        .map((row: CatalogRecord) => BrewTable.toEntry(row, boardKey === 'trending'));
    });
    return boards;
  }

  private static toEntry(row: CatalogRecord, withScore: boolean): CatalogEntry {
    return {
      token: row.token,
      vol30d: row.vol30d,
      vol365d: row.vol365d,
      prior: Math.round(row.prior * 10) / 10,
      velocity: Math.round(row.velocity * 100) / 100,
      score: withScore ? Math.round(row.score * 100) / 100 : 0,
    };
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

  /** 一个 kind 的规模与门槛实测偏差，一行（与 Python 的 check_algo.py 对账用） */
  private static metaLine(one: CatalogKindMeta): string {
    const volDev: number = Math.abs(one.actualVolP - one.thresholds.volFloor) /
      Math.max(1, one.thresholds.volFloor);
    const priorDev: number = Math.abs(one.actualPriorP - one.thresholds.minPrior) /
      Math.max(1, one.thresholds.minPrior);
    return `raw=${one.rawTokens} fam=${one.families} cand=${one.candidates} ` +
      `win=${one.windowStart}~${one.windowEnd} total=${one.totalCount} multi=${one.multiEntryTokens} ` +
      `volFloor=${one.thresholds.volFloor}(偏差 ${(volDev * 100).toFixed(1)}%) ` +
      `minPrior=${one.thresholds.minPrior}(偏差 ${(priorDev * 100).toFixed(1)}%)`;
  }

  private static boardCount(boards: Record<string, CatalogEntry[]>): number {
    let total: number = 0;
    Object.keys(boards).forEach((boardKey: string) => {
      total += boards[boardKey].length;
    });
    return total;
  }

  private static countVol(): string {
    const vol: Record<string, Record<string, BrewVolRow>> = BrewTable.assured().vol;
    return Object.keys(vol).map((kind: string) => `${kind}=${objKeys(vol[kind]).length}`).join(' ');
  }

  private static countDesc(): string {
    const desc: Record<string, Record<string, string>> = BrewTable.assured().desc;
    return Object.keys(desc).map((kind: string) => `${kind}=${BrewTable.sizeOf(desc[kind])}`).join(' ');
  }

  private static ageOf(at: number): number {
    return at === 0 ? -1 : Math.floor((Date.now() - at) / 1000);
  }
}