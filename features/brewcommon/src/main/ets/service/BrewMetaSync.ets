/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

/**
 * 描述片构建器：把 `formula.json` / `cask.json`（或 Harmonybrew 的单文件目录）抽成
 * `token → desc`，交给 `BrewTable` 写进包表。
 *
 * 为什么整份下载（`docs/brew-catalog-fullsync-spec.md`）：
 * 官方 API **没有分类字段**，分类是自建词表看 `desc` 算的；而 `desc` 在单条端点里，
 * 于是「能分类的包数」被压成了几十个。全量包一次就能拿到所有 `desc`：
 * 实测 gzip 5.29 MB（解压 32,364,877 B）/ 2.05 MB，2 个请求，
 * 比逐条拉（13,779 次请求、约 22 MB）省两个数量级。有了它，浏览集才能是**全量包**。
 *
 * 几条刻意的取舍：
 * 1. **下载必须在 `@Concurrent` 函数内部**：taskpool 跨线程序列化上限 16MB，
 *    32MB 文本根本传不进去；只有抽出来的索引（约 1MB）可以回传。
 * 2. **用流式扫描而不是 `JSON.parse`**：整份解析会建一棵几万条记录的对象树，
 *    而扫描只认 `"name"` / `"desc"` 两个字段、就地丢弃文本，内存是常数级；
 *    主线程大 JSON 解析也是官方点名的卡顿反模式。
 * 3. **不落盘索引**：索引进了包表的 `desc` 一半（`brew_table`），本模块只负责产出它。
 *    Harmonybrew 的归一化目录仍然要落本地文件（`BrewCatalogFile`），因为详情页在
 *    那个方言下是**读本地文件**而不是发请求。
 */
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '@ohos/common';
import { BrewHttp } from './BrewHttp';
import { BrewLoadLog } from '../util/BrewLoadLog';
import { BrewSourceDiagnostics } from './BrewSourceDiagnostics';
import { BrewCatalogFile } from './BrewCatalogFile';
import { BrewKind } from '../model/BrewModels';
import { BrewSourceStore } from './BrewSourceStore';
import { BrewSourceUrl } from './BrewSourceUrl';
import { BREW_DIALECT_HARMONYBREW } from '../constant/BrewSourceConstants';
import { adapterFor } from './source/BrewSourceAdapter';
import type { BrewCatalogResult, BrewSourceAdapter } from './source/BrewSourceAdapter';
import {
  BREW_META_VERIFY,
  BREW_META_SYNC_BUDGET_MS,
} from '../constant/BrewConstants';

const TAG: string = '[BrewMetaSync]';

/** 抽样对账条数 / 并发（并发与浏览页原先的批量 hydrate 一致） */
const VERIFY_COUNT: number = 200;
const VERIFY_CONCURRENCY: number = 6;

/** 原始文档的最小投影（对账用） */
interface MetaRawDoc {
  name?: string;
  desc?: string;
}

/** 一个 kind 的描述片结果。`BrewMetaSync` 产出，`BrewTable` 消费并写盘 */
export interface DescShardOutcome {
  kind: string;
  ok: boolean;
  notModified: boolean;
  stamp: string;
  /** `token → desc`。失败与 304 都是空表（调用方据此保留旧表） */
  table: Record<string, string>;
  detail: string;
}

/**
 * 描述片的取数。
 *
 * `stamps` 是包表记下的条件请求基准（按 kind）。
 * `onApplied` 每个 kind **真正结束时**回调一次 —— 包括超过等待预算之后才结束的那次
 * （「迟到写入」）。所以调用方**不能**靠这个 Promise 的 resolve 时机判断描述片是否已就绪，
 * 要等回调。
 *
 * ## 为什么等待预算不等于超时
 *
 * 预算只决定「等多久就先去处理下一个 kind」，**不丢弃结果**：下载在后台继续跑，
 * 它真正结束时仍会回调。若把预算当超时用，上游慢时（实测单文件 578s）描述片**永远刷不到**；
 * 而一开始就 `await` 完再处理第二个 kind，则正是原设计里 13.3 分钟的成因 ——
 * 第一个 kind 一卡就把第二个的结果一起扣在内存里，期间一个字都没写下去。
 *
 * ## 为什么两个 kind 串行开始
 *
 * 并发下载两个大文件只会互相抢带宽（formula 解压 32MB、cask 约 12MB）。
 */
export class BrewMetaSync {
  /**
   * 启动描述片取数，按支持的 kind 逐个开始。
   *
   * @param stamps 包表记下的条件请求基准（`[kind] -> Last-Modified`）
   * @param hasDesc 包表里该 kind 的描述是否已非空（决定要不要发条件请求）
   * @param onApplied 每个 kind 结束时回调（可能晚于本 Promise 的 resolve）
   * @returns 在最后一个 kind 的等待预算用尽后 resolve（不是等下载结束）
   */
  public static async fetchDescShards(stamps: Record<string, string>, hasDesc: Record<string, boolean>,
    onApplied: (outcome: DescShardOutcome) => void): Promise<void> {
    const startedAt: number = Date.now();
    const sourceId: string = BrewSourceStore.sessionActive().id;
    const adapter: BrewSourceAdapter = adapterFor(BrewSourceStore.dialectOf(sourceId));
    // 取会话冻结的 active 源：描述片是它的，不能拿注册表里可能已改的 activeId
    Logger.info(TAG, `desc shard start, hasDesc formula=${hasDesc[BrewKind.FORMULA] === true} ` +
      `cask=${hasDesc[BrewKind.CASK] === true}, stamp formula=[${stamps[BrewKind.FORMULA] ?? ''}] ` +
      `cask=[${stamps[BrewKind.CASK] ?? ''}]`);
    // Harmonybrew 的 ETag 只有在本地目录也在时才能安全使用；否则 304 会让
    // 已丢失的 catalog 文件永远无法重建。上游仍严格保持「只有盘上已有该 kind 的表才发条件请求」。
    const hasCatalog: boolean = BrewSourceStore.dialectOf(sourceId) !== BREW_DIALECT_HARMONYBREW ||
      BrewCatalogFile.has(sourceId);
    await BrewMetaSync.startKind(BrewKind.FORMULA, stamps, hasDesc, hasCatalog, onApplied, startedAt);
    if (!adapter.supportsCasks) {
      // 不支持的 kind 是源能力边界，不是取数失败；尤其不要进 `onApplied` 的失败分支，
      // 否则设置页会出现与连接探针互相矛盾的状态
      BrewLoadLog.info('table_desc', 'skip-unsupported', Date.now() - startedAt,
        'kind=' + BrewKind.CASK + ' 本源不支持 cask，跳过（不是失败）');
      return;
    }
    await BrewMetaSync.startKind(BrewKind.CASK, stamps, hasDesc, hasCatalog, onApplied, startedAt);
  }

  /**
   * 启动一个 kind，给它一个**等待预算**。
   *
   * 预算只决定「等多久就先去处理下一个 kind」，不丢弃结果 —— 下载在后台继续跑，
   * 真正结束时通过 `onApplied` 回调写入（迟到写入）。
   *
   * 不主动取消底层请求（taskpool 没有取消语义），而且 `http.readTimeout` 用的是
   * `BREW_META_READ_TIMEOUT_MS`（10 分钟，**远大于这里的预算**）—— 这是「迟到写入」能成立的
   * 前提：第一版把两者写成同一个值，结果下载在 90s 被中止，根本没有迟到的结果可写。
   */
  private static async startKind(kind: string, stamps: Record<string, string>, hasDesc: Record<string, boolean>,
    hasCatalog: boolean, onApplied: (outcome: DescShardOutcome) => void,
    startedAt: number): Promise<void> {
    // **只有在盘上已经有该 kind 的描述时才发条件请求。**
    // 否则「有基准但表是空的」（上一次写盘失败 / 索引被 parse 失败删掉）会拿到 304，
    // 而 304 路径不写表 → 那个 kind 就**永远填不上**。表为空时宁可贵一次，全量拉。
    const stamp: string = hasDesc[kind] === true && hasCatalog ? (stamps[kind] ?? '') : '';
    // 这一行是「描述片这一轮发不发请求」的判据：`stamp=[]` 就意味着这一次是全量拉。
    // 不带条件请求常常不是 bug，而是「表被清过」或「上游不支持」，两种原因在这里就分得开
    BrewLoadLog.debug('table_desc', stamp.length > 0 ? 'conditional' : 'full', Date.now() - startedAt,
      `kind=${kind} stamp=[${stamp}] hasDesc=${hasDesc[kind] === true} hasCatalog=${hasCatalog} ` +
      `budget=${BREW_META_SYNC_BUDGET_MS}ms`);
    const work: Promise<DescShardOutcome> = BrewMetaSync.syncKind(kind, stamp);
    // 迟到写入：无论等不等到，只要它最终结束就一定回调。每个 kind 只会调一次，
    // 所以不需要幂等守卫；两个 kind 的先后顺序也不影响结果。
    work.then((outcome: DescShardOutcome) => {
      onApplied(outcome);
      if (BREW_META_VERIFY && kind === BrewKind.FORMULA && outcome.ok && !outcome.notModified) {
        BrewMetaSync.verify(outcome.table).catch(() => {
          // 自检失败不影响描述片本身，已由 verify 内部打日志
        });
      }
    }, () => {
      // `syncKind` 内部已把异常收敛成 DescShardOutcome，这里只是兜底，不让它变成未处理拒绝
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
      BrewLoadLog.info('table_desc', 'budget', Date.now() - startedAt,
        `kind=${kind} 超过 ` + BREW_META_SYNC_BUDGET_MS + `ms 预算，先去开始下一个 kind；` +
        '本次下载仍在后台继续，结束时照常写入（迟到写入）');
    } else {
      BrewLoadLog.debug('table_desc', 'within-budget', Date.now() - startedAt,
        `kind=${kind} 在预算内结束（${Date.now() - startedAt}ms / ${BREW_META_SYNC_BUDGET_MS}ms）`);
    }
  }

  /** 同步一个 kind。transport 细节由 adapter 处理，三种结局仍在 DescShardOutcome 中表达 */
  private static async syncKind(kind: string, sinceStamp: string): Promise<DescShardOutcome> {
    const t0: number = Date.now();
    try {
      // 标识键按 kind 取：cask 的标识是 token（显示名是数组，不是标识）
      const idKey: string = kind === BrewKind.CASK ? '"token":' : '"name":';
      const sourceId: string = BrewSourceStore.sessionActive().id;
      const adapter: BrewSourceAdapter = adapterFor(BrewSourceStore.dialectOf(sourceId));
      Logger.debug(TAG, `[desc] ${kind} → fetch idKey=${idKey} since=[${sinceStamp}]`);
      const out: BrewCatalogResult = await adapter.fetchCatalog(BrewSourceStore.activeBaseUrl(),
        sinceStamp, kind, idKey);
      if (out.notModified) {
        Logger.info(TAG, `[desc] ${kind} 304, 0 字节, ${Date.now() - t0}ms`);
        return { kind: kind, ok: true, notModified: true, stamp: out.stamp,
          table: {}, detail: out.detail };
      }
      // 判据用 `pairs` 而不是 `indexJson.length`：空表序列化出来是 `"{}"`（长度 2），
      // 用长度判会让「格式一变 → pairs=0」静默地把该 kind 原本好的描述覆成空表。
      if (!out.ok || out.pairs === 0) {
        Logger.error(TAG, `[desc] ${kind} failed after ${Date.now() - t0}ms, ok=${out.ok} ` +
          `pairs=${out.pairs} ${out.detail}`);
        return { kind: kind, ok: false, notModified: false, stamp: out.stamp,
          table: {}, detail: out.detail };
      }
      // Harmonybrew 必须先成功写本地目录，再让调用方记住 ETag。若先记 stamp，目录写失败后
      // 下次会拿 304 直接跳过重写，详情目录将永远缺失。
      if (out.catalogJson !== undefined) {
        const persisted: boolean = BrewCatalogFile.write(sourceId, out.catalogJson) !== null;
        if (!persisted) {
          return { kind: kind, ok: false, notModified: false, stamp: '',
            table: {}, detail: out.detail + ' → 目录文件写失败' };
        }
      }
      Logger.info(TAG, `[desc] ${kind} ok pairs=${out.pairs} bytes=${out.indexJson.length} ` +
        `${Date.now() - t0}ms catalogFile=${out.catalogJson !== undefined} | ${out.detail}`);
      return { kind: kind, ok: true, notModified: false, stamp: out.stamp,
        table: JSON.parse(out.indexJson) as Record<string, string>, detail: out.detail };
    } catch (error) {
      const err = error as BusinessError;
      Logger.error(TAG, `desc shard [${kind}]: failed, code=${err?.code}, msg=${err?.message}`);
      return { kind: kind, ok: false, notModified: false, stamp: '', table: {},
        detail: 'failed code=' + err?.code + ' msg=' + err?.message };
    }
  }

  /**
   * 可选自检（`BREW_META_VERIFY`）：描述必须与单条 API 逐字一致。
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

  /** 源子系统的自检入口。默认关（`BREW_SOURCE_VERIFY=false`），只打日志 */
  public static runDiagnostics(): void {
    BrewSourceDiagnostics.run();
  }
}