/*
 * Copyright (c) 2025 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/**
 * 元数据索引：后台同步**全量**元数据（`formula.json` / `cask.json`），只抽 `token → desc`。
 *
 * 为什么要有它（见 docs/brew-catalog-fullsync-spec.md）：
 * 官方 API **没有分类字段**，分类是自建词表看 `desc` 算的；而 `desc` 过去只能一条一条拉
 * （`/api/<kind>/<token>.json`），于是"能分类的包数"被压成了前 100 个 —— 那就是浏览集的硬裁切。
 * 全量包一次就能拿到所有 `desc`：实测 gzip 5.29 MB（解压 32,364,877 B）/ 2.05 MB，2 个请求，
 * 比逐条拉（13,779 次请求、约 22 MB）省两个数量级。有了它，浏览集就是**目录全量**。
 *
 * 几条刻意的取舍：
 * 1. **下载必须在 `@Concurrent` 函数内部**：taskpool 跨线程序列化上限 16MB
 *    （harmonyos-guides/serializable-overview.md:15），32MB 文本根本传不进去；
 *    只有抽出来的索引（约 1MB）可以回传。
 * 2. **用流式扫描而不是 `JSON.parse`**：整份解析会建一棵几万条记录的对象树，
 *    而扫描只认 `"name"` / `"desc"` 两个字段、就地丢弃文本，内存是常数级；
 *    主线程大 JSON 解析也是官方点名的卡顿反模式（harmonyos-faqs/faq-stability-66.md:116）。
 * 3. **落盘只存 desc**：绝不能沿用 `brew_live_data` 那种"整份 doc ~5KB/条"的口径
 *    （1.3 万条 ≈ 65MB，且每次整份 flush）。索引约 1MB，与目录分开存。
 * 4. **索引只用于分类/列表主文案**：详情页仍然读整份 doc（它要的是版本/依赖/许可等全字段）。
 */
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '@ohos/common';
import { BrewSourcePrefs } from './BrewSourcePrefs';
import { BrewHttp } from './BrewHttp';
import { BrewLoadLog } from '../util/BrewLoadLog';
import { BrewSourceDiagnostics } from './BrewSourceDiagnostics';
import { BrewCacheEpoch } from './BrewCacheEpoch';
import { BrewCatalogFile } from './BrewCatalogFile';
import { BrewKind } from '../model/BrewModels';
import { BrewSourceStore } from './BrewSourceStore';
import { BrewSourceUrl } from './BrewSourceUrl';
import { BREW_DIALECT_HARMONYBREW } from '../constant/BrewSourceConstants';
import { adapterFor } from './source/BrewSourceAdapter';
import type { BrewCatalogResult, BrewSourceAdapter } from './source/BrewSourceAdapter';
import {
  BREW_META_INDEX_KEY,
  BREW_META_STAMP_KEY,
  BREW_META_SYNC,
  BREW_META_SYNC_BUDGET_MS,
  BREW_META_VERIFY,
  BREW_PERF_TRACE,
} from '../constant/BrewConstants';

const TAG: string = '[BrewMetaSync]';
/** 抽样对账条数 / 并发（并发与 BrewService.hydrate 一致） */
const VERIFY_COUNT: number = 200;
const VERIFY_CONCURRENCY: number = 6;

/** 落盘 DTO（与 `BrewCatalog` 同风格）。按 kind 分表：token 在不同 kind 下可能同名 */
export interface BrewMetaIndex {
  ts: number;
  formula: Record<string, string>;
  cask: Record<string, string>;
}

/** 原始文档的最小投影（对账用） */
interface MetaRawDoc {
  name?: string;
  desc?: string;
}

/**
 * 一个 kind 的同步结果。**三种结局**：拿到新表（`table`） / 304 未变（`notModified`） /
 * 失败（两者都空，看 `detail`）。分开表达而不是用 `undefined` 一词多用，是因为
 * “未变”与“失败”在上层的行为完全不同：前者只落基准、不重写表，后者要保留旧表并告警。
 */
interface MetaKindResult {
  table?: Record<string, string>;
  notModified: boolean;
  lastModified: string;
  detail: string;
  /** 仅 Harmonybrew 全量下载结果携带；上游不落本地目录。 */
  catalogJson?: string;
  catalogPairs?: number;
}

/**
 * 元数据索引的入口。两类调用者：
 *   - 页面（`BrewService.buildFormulaPage/buildCaskPage`）：**同步**读 `descOf()`，只读内存/落盘，绝不发请求；
 *   - 进程启动：`start()` 在后台同步一次（一个进程最多一次，失败就等下次启动，不做退避/重试队列）。
 */
export class BrewMetaSync {
  private static started: boolean = false;
  private static index: BrewMetaIndex | undefined = undefined;
  /** 全量包的 `Last-Modified` 基准（kind → 值），条件请求用；首次访问从 Preference 读一次 */
  private static stamps: Record<string, string> | undefined = undefined;
  private static epoch: number = BrewCacheEpoch.current();

  /**
   * 重置进程内索引。清空当前激活源缓存时调用。
   *
   * **`started` 保持不动**：清缓存不应该触发一次 5.29MB 的全量重下。索引留空，
   * 下次进程启动时 `start()` 自然会重新同步。代价是清空后浏览页会降级 —— 这是预期行为。
   */
  public static resetMemoryIndex(): void {
    BrewMetaSync.index = undefined;
    BrewMetaSync.stamps = undefined;
    Logger.info(TAG, 'meta memory index reset');
  }

  /**
   * 取某个 kind 的 `token → desc` 索引。**同步、无网络**：
   * 内存里有就用内存，否则从 Preference 读一次；两者都没有就返回空表（页面会走降级路径）。
   */
  public static descOf(kind: string): Record<string, string> {
    const index: BrewMetaIndex = BrewMetaSync.ensureIndex();
    return kind === BrewKind.CASK ? index.cask : index.formula;
  }

  /** 索引是否已就绪（用于日志与降级判断） */
  public static ready(): boolean {
    const index: BrewMetaIndex = BrewMetaSync.ensureIndex();
    return Object.keys(index.formula).length > 0 || Object.keys(index.cask).length > 0;
  }

  /** 进程启动后调一次：后台同步。任何异常都吞掉 —— 同步失败绝不能影响页面 */
  public static start(): void {
    if (!BREW_META_SYNC || BrewMetaSync.started) {
      return;
    }
    BrewMetaSync.started = true;
    // 冷启动原点：这是数据层在本次进程里的第一次动作（splash 的 preloadResources）。
    // 打它的唯一目的是让 `[load]` 时间线**自包含** —— 设备 hilog 环形缓冲只回收到 ~12s 前，
    // 抓日志时 `Ability onCreate` 经常已经被挤掉（实测 --from 90s 与 --from 600s 同一起点），
    // 没有它就只能靠 hilog 时间戳碰运气。
    BrewLoadLog.info('cold_start', 'origin', 0,
      '数据层冷启动原点（≈ Ability onCreate 后 ~300ms）；其余 [load] 行的 at= 减本行即得相对耗时');
    // 源子系统的自检入口。默认关（BREW_SOURCE_VERIFY=false），只打日志。
    // 放在这里是因为 `start()` 是数据层在进程里的第一个动作，早于任何页面读取 activeBaseUrl。
    BrewSourceDiagnostics.run();
    // 先把落盘的索引读进来：页面立刻可用，本次同步完成后整体替换
    const cached: BrewMetaIndex = BrewMetaSync.ensureIndex();
    const stamps: Record<string, string> = BrewMetaSync.ensureStamps();
    Logger.info(TAG, `meta sync: start, cached formula=${Object.keys(cached.formula).length} ` +
      `cask=${Object.keys(cached.cask).length}, ts=${cached.ts}, ` +
      `stamp formula=[${stamps[BrewKind.FORMULA] ?? ''}] cask=[${stamps[BrewKind.CASK] ?? ''}]`);
    BrewMetaSync.sync().catch((error: BusinessError) => {
      Logger.error(TAG, `meta sync: failed, code=${error?.code}, msg=${error?.message}`);
      // 整个 sync 抛出来（而非收敛成 MetaKindResult 的失败分支）时也要记健康 —— 
      // 否则「两个 kind 都因为同一个原因挂掉」这类情况在设置页上完全看不到
      BrewSourceStore.noteError(BrewSourceStore.sessionActive().id, 'meta',
        `${error?.code}, ${error?.message}`);
    });
  }

  private static ensureIndex(): BrewMetaIndex {
    if (BrewMetaSync.index === undefined) {
      // [perf] 这一段是主线程 `getSync` + `JSON.parse`（索引约 1MB）。实测只有 17ms ——
      // 它此前完全不在 `browse … built` 的计时区间内，所以历史日志里的 ms 一直是低估的。
      const t0: number = Date.now();
      const stored: BrewMetaIndex | null =
        BrewSourcePrefs.get<BrewMetaIndex>(BREW_META_INDEX_KEY);
      const readMs: number = Date.now() - t0;
      // 形状校验后再用：落盘的东西会跨版本存活（开发期改过结构、将来也可能改），
      // 一个少字段的旧值不能让 `Object.keys(undefined)` 把整个浏览页带崩。
      const usable: boolean = stored !== null && stored.formula !== undefined && stored.cask !== undefined;
      BrewMetaSync.index = usable ? stored as BrewMetaIndex : { ts: 0, formula: {}, cask: {} };
      if (BREW_PERF_TRACE) {
        Logger.info(TAG, `[perf] meta index pref read+parse ts=${t0} readMs=${readMs} ` +
          `formula=${Object.keys(BrewMetaSync.index.formula).length} ` +
          `cask=${Object.keys(BrewMetaSync.index.cask).length}`);
      }
      const formulaCount: number = Object.keys(BrewMetaSync.index.formula).length;
      const caskCount: number = Object.keys(BrewMetaSync.index.cask).length;
      const reason: string = stored === null ? 'missing' : (usable ? 'pref' : 'shape-invalid');
      BrewLoadLog.info('meta_index', reason, readMs,
        'formula=' + formulaCount + ' cask=' + caskCount + ' age=' +
        (usable ? Math.floor((Date.now() - BrewMetaSync.index.ts) / 1000) : -1) + 's');
      if (reason !== 'pref') {
        BrewLoadLog.warn('meta_index', reason, readMs,
          '索引不可用 → 浏览页**必然**走降级路径（逐条 hydrate，5~15s）。' +
          (reason === 'shape-invalid' ?
            '盘上有值但形状校验不过（缺 formula/cask 字段），已按空表处理' :
            '盘上没有索引：首次安装，或上次启动的 meta sync 未成功落盘'));
      }
    }
    return BrewMetaSync.index;
  }

  private static async sync(): Promise<void> {
    // 世代号在**操作入口**捕获：本进程的元数据同步只从 `start()` 走到这里，
    // `rememberStamp` 与 `persistIndex` 都由它（经 `syncKindWithBudget` → `applyKindResult`）触发。
    // 清空发生在这次同步开始之后的话，这次同步的**全部**写入都应作废。
    BrewMetaSync.epoch = BrewCacheEpoch.current();
    const startedAt: number = Date.now();
    const stamps: Record<string, string> = BrewMetaSync.ensureStamps();
    const cached: BrewMetaIndex = BrewMetaSync.ensureIndex();
    // **只有在盘上已经有该 kind 的表时才发条件请求。**
    // 否则“有基准但表是空的”（上一次落盘失败 / 索引被 parse 失败删掉）会拿到 304，
    // 而 304 路径不写表 → 那个 kind 就**永远填不上**。表为空时宁可贵一次，全量拉。
    const sourceId: string = BrewSourceStore.sessionActive().id;
    const dialect: string = BrewSourceStore.dialectOf(sourceId);
    const adapter: BrewSourceAdapter = adapterFor(dialect);
    const hasFormulaIndex: boolean = Object.keys(cached.formula).length > 0;
    // Harmonybrew 的 ETag 只有在索引与本地目录都存在时才能安全使用；否则 304 会让
    // 已丢失的 catalog.tsv 永远无法重建。上游仍严格保持只看原索引的旧条件。
    const hasCatalog: boolean = dialect !== BREW_DIALECT_HARMONYBREW || BrewCatalogFile.has(sourceId);
    const formulaStamp: string = hasFormulaIndex && hasCatalog ?
      (stamps[BrewKind.FORMULA] ?? '') : '';
    const caskStamp: string =
      Object.keys(cached.cask).length > 0 ? (stamps[BrewKind.CASK] ?? '') : '';
    // 两个 kind **串行开始**（并发下载两个大文件只会互相抢带宽）：
    // 等 formula 提前结束或预算用完，再开始 cask。
    //
    // ⚠ **“每个 kind 各自一结束就落盘”是本模块的核心不变量。**
    // 改动前是“两个都 await 完才 setValue 一次”，于是第一个 kind 一卡就把两个结果都扣在内存里 ——
    // 真机实测：`meta sync [formula]` 花了 **578s**、`[cask]` 再 221s，`total=798998ms`（13.3 分钟），
    // 期间 `brew_meta_index` **一个字都没落盘**；而任何一次冷启动都等不到 13 分钟，
    // 浏览页于是永久走降级路径（逐条 hydrate，5~15s）。详见 docs/brew-catalog-fullsync-spec.md §4.7。
    // 现在落盘发生在 `syncKindWithBudget` 的迟到回调里 —— 所以这里的 `await` **只控节奏、不等落盘**。
    await BrewMetaSync.syncKindWithBudget(BrewKind.FORMULA, formulaStamp, startedAt);
    if (!adapter.supportsCasks) {
      // 不支持的 kind 是源能力边界，不是同步失败；尤其不要让空结果进入 applyKindResult
      // 调 noteError，否则会把「部分可用」卡片与正常的连接探针记录成互相矛盾的状态。
      BrewLoadLog.info('meta_index_sync', 'skip-unsupported', Date.now() - startedAt,
        'kind=' + BrewKind.CASK + ' 本源不支持 cask，跳过（不是失败）');
    } else {
      await BrewMetaSync.syncKindWithBudget(BrewKind.CASK, caskStamp, startedAt);
    }
  }

  /**
   * 启动一个 kind 的同步，并给它一个**等待预算**。
   *
   * **预算只决定“等多久就先去处理下一个 kind”，不丢弃结果** —— 这就是「迟到落盘」：
   * 下载在后台继续跑，它真正结束时才落盘（见下面的 `work.then`）。
   *
   * 为什么不能是“超时就丢弃”：上游慢时（实测单文件 578s）硬预算会让索引**永远刷不到** ——
   * 那是比改动前更差的回归（旧代码靠一直等，13.3 分钟后确实成功了）。
   * 也不能“一直等”：那正是改动前的问题 —— 第二个 kind 被第一个扣住，且完全不可观测。
   *
   * 不主动取消底层请求（taskpool 没有取消语义），而且 `http.readTimeout` 用的是
   * `BREW_META_READ_TIMEOUT_MS`（10 分钟，**远大于这里的预算**）—— 这是“迟到落盘”能成立的
   * 前提：第一版把两者写成同一个值，结果下载在 90s 被中止，根本没有迟到的结果可落。
   */
  private static async syncKindWithBudget(kind: string, sinceStamp: string, startedAt: number): Promise<void> {
    const work: Promise<MetaKindResult> = BrewMetaSync.syncKind(kind, sinceStamp);
    // 迟到落盘：无论等不等到，只要它最终结束就一定落盘。每个 kind 只会调一次
    // `applyKindResult`（只在这里），所以不需要幂等守卫；两个 kind 的先后顺序也不影响结果 ——
    // `applyKindResult` 每次都先读当前内存副本，只替换自己那一个表。
    work.then((late: MetaKindResult) => {
      BrewMetaSync.applyKindResult(kind, late, startedAt);
      if (BREW_META_VERIFY && kind === BrewKind.FORMULA && late.table !== undefined) {
        BrewMetaSync.verify(late.table).catch(() => {
          // 自检失败不影响索引本身，已由 verify 内部打日志
        });
      }
    }, () => {
      // `syncKind` 内部已把异常收敛成 MetaKindResult，这里只是兜底，不让它变成未处理拒绝
    });
    let timer: number = -1;
    const expired: Promise<boolean> = new Promise<boolean>((resolve: (value: boolean) => void) => {
      timer = setTimeout(() => resolve(true), BREW_META_SYNC_BUDGET_MS);
    });
    const timedOut: boolean = await Promise.race([work.then(() => false, () => false), expired]);
    if (timer !== -1) {
      clearTimeout(timer);
    }
    if (timedOut) {
      BrewLoadLog.info('meta_index_sync', 'budget', Date.now() - startedAt,
        'kind=' + kind + ' 超过 ' + BREW_META_SYNC_BUDGET_MS + 'ms 预算，先去开始下一个 kind；' +
        '本次下载仍在后台继续，结束时照常落盘（迟到落盘）');
    }
  }

  /**
   * 落一个 kind 的结果。**每个 kind 只会被调用一次**（在 `syncKindWithBudget` 的迟到落盘回调里），
   * 这是“第二个 kind 再慢也不影响第一个”的落点，也是本次修复的核心。
   */
  private static applyKindResult(kind: string, result: MetaKindResult, startedAt: number): void {
    const current: BrewMetaIndex = BrewMetaSync.ensureIndex();
    const tKind: number = Date.now() - startedAt;
    // spec §9.5 的运行期写入点：三个分支各自代表「成功 / 成功（304）/ 失败」。
    // 取本会话冻结的 active 源 —— 索引与目录都是它的，不能拿注册表里可能已改的 activeId。
    const sourceId: string = BrewSourceStore.sessionActive().id;
    if (result.notModified) {
      // **304 不写索引**：表没变，而 `ts` 只是信息性字段（索引无 TTL）。
      // 每轮冷启动都重写 1MB 只为改一个 ts 是不必要的 —— 条件请求省下的流量又被写盘花回去。
      // 只落基准（几百字节）。
      BrewMetaSync.rememberStamp(kind, result.lastModified);
      BrewLoadLog.info('meta_index_sync', 'net-304', tKind,
        'kind=' + kind + ' 数据集未变（If-Modified-Since 命中 304，0 字节）→ 保留旧表，不重写盘 ' +
        result.detail);
      // 304 说明全量包端点**可达**（只是内容未变）→ 对「镜像能不能用」而言这是一次成功
      BrewSourceStore.noteMetaOk(sourceId, BrewMetaSync.indexSize(current));
      return;
    }
    if (result.table === undefined) {
      BrewLoadLog.warn('meta_index_sync', 'sync-failed', tKind,
        'kind=' + kind + ' ' + result.detail + ' → 保留上一份索引（没有旧表就一直是降级路径）');
      BrewSourceStore.noteError(sourceId, 'meta', result.detail);
      return;
    }
    // Harmonybrew 必须先成功写完整目录，再记住 ETag。若先记 stamp，目录写失败后下次会拿
    // 304 直接跳过重写，详情目录将永远缺失。目录写入与 brew_meta_index 共用同一世代号守卫。
    if (result.catalogJson !== undefined) {
      const catalogPairs: number = result.catalogPairs ?? 0;
      const catalogPersisted: boolean = BrewMetaSync.persistCatalog(sourceId, result.catalogJson, catalogPairs);
      if (!catalogPersisted) {
        BrewLoadLog.warn('meta_index_sync', 'sync-failed', tKind,
          'kind=' + kind + ' pairs=' + catalogPairs + ' ' + result.detail +
          ' → 目录未落盘，不更新 ETag；保留旧目录与旧索引');
        BrewSourceStore.noteError(sourceId, 'meta', 'catalog file write failed');
        return;
      }
    }
    BrewMetaSync.rememberStamp(kind, result.lastModified);
    const next: BrewMetaIndex = kind === BrewKind.CASK ?
      { ts: Date.now(), formula: current.formula, cask: result.table } :
      { ts: Date.now(), formula: result.table, cask: current.cask };
    const pairs: number = Object.keys(result.table).length;
    const persisted: boolean = BrewMetaSync.persistIndex(next);
    if (persisted) {
      BrewLoadLog.info('meta_index_sync', 'net-200', tKind,
        'kind=' + kind + ' pairs=' + pairs + ' ' + result.detail +
        ' → 已单独落盘（不等另一个 kind）');
    } else {
      // 落盘被世代号守卫丢弃：用户在本次同步开始之后清空了这个源的缓存。
      // **不能沿用 net-200 那句「已单独落盘」** —— 那是谎报（见 `persistIndex` 的注释）。
      // `BrewLoadLog` 的 reason 是固定词表、没有「被世代号丢弃」这一项，故用 `sync-failed`，
      // 用明细里的「已丢弃」与真正的同步失败（没有这个字样）区分。
      BrewLoadLog.warn('meta_index_sync', 'sync-failed', tKind,
        'kind=' + kind + ' pairs=' + pairs + ' ' + result.detail +
        ' → 已丢弃：清空缓存发生在本次同步开始之后（世代号不匹配）；索引未落盘、内存副本未更新，' +
        '本会话浏览页走降级路径');
    }
    // `tokens` 报「现在索引里到底有多少条」，不是「本次抓到了多少条」：
    // 落盘被丢弃时内存表没变，报抓到的条数会让人以为索引已经更新。
    let effective: BrewMetaIndex = next;
    if (!persisted) {
      effective = current;
    }
    BrewSourceStore.noteMetaOk(sourceId, BrewMetaSync.indexSize(effective));
  }

  /** 索引里的条目数（formula + cask），仅用于健康记录的日志与展示 */
  private static indexSize(index: BrewMetaIndex): number {
    return Object.keys(index.formula).length + Object.keys(index.cask).length;
  }

  /**
   * 落盘 + 同步内存副本。**唯一的写入口**，避免“有的路径忘了写盘 / 忘了更新内存”。
   *
   * 返回**是否真的落盘**：被世代号守卫丢弃时返回 `false`。
   *
   * 为什么要返回而不是就地打日志：调用方在「真落盘」与「被丢弃」两种情况下必须打**不同的判据行**。
   * 早先调用方无条件打「已单独落盘」，而守卫其实已经把它丢了 —— 真机复现 C1 修复时
   * 看到的就是「先 `dropped write key=brew_meta_index`，紧跟着一行『已单独落盘』」，
   * 读日志的人会直接得出「索引在盘上」的错误结论。
   */
  private static persistIndex(next: BrewMetaIndex): boolean {
    // 世代号在 `sync()` 入口捕获。**不在这里改写 epoch** ——
    // `epoch` 是 `rememberStamp` 与 `persistIndex` **共用的同一个 static**，
    // 而 `applyKindResult` 先调 `rememberStamp` 再调 `persistIndex`；
    // 一旦在 drop 分支里改写，`rememberStamp` 就会把「不匹配」这个事实消化掉，
    // 紧接着 `persistIndex` 比对通过 → 1MB 的索引照写不误（终审抓到的 Critical）。
    if (BrewMetaSync.epoch !== BrewCacheEpoch.current()) {
      Logger.info(TAG, '[BrewCache] epoch mismatch, dropped write key=brew_meta_index');
      return false;
    }
    BrewMetaSync.index = next;
    const t0: number = Date.now();
    BrewSourcePrefs.set<BrewMetaIndex>(BREW_META_INDEX_KEY, next);
    // 索引是全项目最贵的一份缓存（全量包 gzip 5.29MB，设备实测下载 21.7s，慢时到 578s）。
    // 写进内存缓存页不算数 —— 进程被回收就会丢，所以立刻显式刷盘。
    BrewSourcePrefs.persistNow();
    Logger.info(TAG, `meta index persisted, formula=${Object.keys(next.formula).length} ` +
      `cask=${Object.keys(next.cask).length}, pref write=${Date.now() - t0}ms`);
    return true;
  }

  /**
   * 写 Harmonybrew 归一化目录。世代号不匹配时不碰正文或偏移表。
   * 上游 catalogJson 为 undefined，不走此路径。
   */
  private static persistCatalog(sourceId: string, catalogJson: string, pairs: number): boolean {
    if (BrewMetaSync.epoch !== BrewCacheEpoch.current()) {
      Logger.info(TAG, '[BrewCache] epoch mismatch, dropped write key=brew_catalog_offsets');
      return false;
    }
    const offsets: Record<string, number[]> | null = BrewCatalogFile.write(sourceId, catalogJson);
    if (offsets === null) {
      return false;
    }
    const actualPairs: number = Object.keys(offsets).length;
    return actualPairs === pairs;
  }

  /** 全量包的 `Last-Modified` 基准，首次访问从 Preference 读一次 */
  private static ensureStamps(): Record<string, string> {
    if (BrewMetaSync.stamps === undefined) {
      const stored: Record<string, string> | null =
        BrewSourcePrefs.get<Record<string, string>>(BREW_META_STAMP_KEY);
      BrewMetaSync.stamps = stored ?? {};
    }
    return BrewMetaSync.stamps;
  }

  /**
   * 记住这次的 `Last-Modified`，下次条件请求用它。空串不覆盖（服务端没给就别把基准弄丢）
   *
   * 这里**不调 `persistNow()`**：`brew_meta_stamp` 只有两个键、几十字节，
   * 而它每次都会被 `persistIndex()` 的那次显式刷盘顺带带下去（两个写入口在同一次同步里成对发生）；
   * 就算真丢了也只是一次多余的探针（0 字节条件请求），代价与一次刷盘相当。
   */
  private static rememberStamp(kind: string, lastModified: string): void {
    if (lastModified.length === 0) {
      return;
    }
    if (BrewMetaSync.epoch !== BrewCacheEpoch.current()) {
      Logger.info(TAG, '[BrewCache] epoch mismatch, dropped write key=brew_meta_stamp');
      return;
    }
    const stamps: Record<string, string> = BrewMetaSync.ensureStamps();
    if (stamps[kind] === lastModified) {
      return;
    }
    stamps[kind] = lastModified;
    BrewSourcePrefs.set<Record<string, string>>(BREW_META_STAMP_KEY, stamps);
  }

  /** 同步一个 kind。transport 细节由 adapter 处理，三种结局仍在 MetaKindResult 中表达。 */
  private static async syncKind(kind: string, sinceStamp: string): Promise<MetaKindResult> {
    try {
      // 标识键按 kind 取：cask 的标识是 token（name 是显示名数组，不是标识）
      const idKey: string = kind === BrewKind.CASK ? '"token":' : '"name":';
      const sourceId: string = BrewSourceStore.sessionActive().id;
      const adapter: BrewSourceAdapter = adapterFor(BrewSourceStore.dialectOf(sourceId));
      const out: BrewCatalogResult = await adapter.fetchCatalog(BrewSourceStore.activeBaseUrl(),
        sinceStamp, kind, idKey);
      if (out.notModified) {
        const renewed: MetaKindResult = {
          notModified: true, lastModified: out.stamp, detail: out.detail,
        };
        return renewed;
      }
      // 判据用 `pairs` 而不是 `indexJson.length`：空表序列化出来是 `"{}"`（长度 2），
      // 用长度判会让“格式一变 → pairs=0”静默地把该 kind 原本好的索引覆成空表。
      if (!out.ok || out.pairs === 0) {
        const failed: MetaKindResult = {
          notModified: false, lastModified: out.stamp, detail: out.detail,
        };
        return failed;
      }
      const ok: MetaKindResult = {
        notModified: false, lastModified: out.stamp,
        table: JSON.parse(out.indexJson) as Record<string, string>, detail: out.detail,
        catalogJson: out.catalogJson, catalogPairs: out.catalogPairs,
      };
      return ok;
    } catch (error) {
      const err = error as BusinessError;
      Logger.error(TAG, `meta sync [${kind}]: failed, code=${err?.code}, msg=${err?.message}`);
      const crashed: MetaKindResult = {
        notModified: false, lastModified: '',
        detail: 'failed code=' + err?.code + ' msg=' + err?.message,
      };
      return crashed;
    }
  }

  /**
   * 可选自检（`BREW_META_VERIFY`）：索引里的 desc 必须与单条 API 逐字一致。
   *
   * 为什么值得留：扫描器是手写的（锚点 + 转义），一旦配对错位或 unescape 出错，
   * 页面会**看起来正常但分类是错的** —— 那种 bug 只能靠对账抓。
   */
  private static async verify(index: Record<string, string>): Promise<void> {
    const keys: string[] = Object.keys(index);
    const picked: string[] = [];
    const step: number = Math.max(1, Math.floor(keys.length / VERIFY_COUNT));
    for (let i = 0; i < keys.length && picked.length < VERIFY_COUNT; i += step) {
      picked.push(keys[i]);
    }
    const startedAt: number = Date.now();
    let mismatch: number = 0;
    let failed: number = 0;
    const samples: string[] = [];
    for (let start = 0; start < picked.length; start += VERIFY_CONCURRENCY) {
      const batch: string[] = picked.slice(start, start + VERIFY_CONCURRENCY);
      const online: string[] = await Promise.all(batch.map((token: string) => BrewMetaSync.fetchDesc(token)));
      for (let k = 0; k < batch.length; k++) {
        const token: string = batch[k];
        const remote: string = online[k];
        if (remote === '__FAILED__') {
          failed++;
          continue;
        }
        const local: string = index[token] ?? '';
        if (remote !== local) {
          mismatch++;
          if (samples.length < 5) {
            samples.push(`${token}: local="${local}" online="${remote}"`);
          }
        }
      }
    }
    Logger.info(TAG, `meta verify: total=${picked.length} mismatch=${mismatch} failed=${failed} ` +
      `${Date.now() - startedAt}ms samples=${samples.join(' | ')}`);
  }

  /** 单条现网 desc；失败返回哨兵值（对账时算 failed，不算 mismatch） */
  private static async fetchDesc(token: string): Promise<string> {
    try {
      const doc: MetaRawDoc = await BrewHttp.getJson<MetaRawDoc>(
        BrewSourceUrl.join(BrewSourceStore.activeBaseUrl(), `/formula/${token}.json`));
      return doc.desc ?? '';
    } catch (error) {
      return '__FAILED__';
    }
  }
}
