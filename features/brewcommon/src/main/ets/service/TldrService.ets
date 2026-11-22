/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { fileIo } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger, StorageKey } from '@ohos/common';
import {
  TLDR_CACHE_ROOT,
  TLDR_CHANNEL_GITHUB,
  TLDR_CHANNEL_JSDELIVR,
  TLDR_FAIL_HEAD_BYTES,
  TLDR_HTTP_TIMEOUT_MS,
  TLDR_LOCALE_EN,
  TLDR_LOCALE_ZH,
  TLDR_LOG_TAG,
  TLDR_META_SUFFIX,
  TLDR_NEG_SUFFIX,
  TLDR_NEG_TTL_MS,
  TLDR_PAGE_PATHS,
  TLDR_REFRESH_FAIL_LIMIT,
  TLDR_CHANNELS,
  TLDR_TTL_MS,
  TLDR_URL_GITHUB_BASE,
  TLDR_URL_JSDELIVR_BASE,
} from '../constant/TldrConstants';
import { TldrPage } from '../model/TldrPage';
import {
  TLDR_CHAIN_ALL_NOT_FOUND,
  TLDR_CHAIN_FAILED,
  TLDR_CHAIN_HIT,
  TLDR_ORIGIN_DISK,
  TLDR_ORIGIN_NETWORK,
  TLDR_OUTCOME_FAILED,
  TLDR_OUTCOME_HIT,
  TLDR_OUTCOME_NOT_FOUND,
  TldrCandidateOutcome,
  TldrChainResult,
  TldrParser,
} from '../util/TldrParser';
import { BrewHttp, BrewHttpResult } from './BrewHttp';

const TAG: string = TLDR_LOG_TAG;

/** meta 文件的形状（`<token>.meta.json`，spec §3.1） */
class TldrMeta {
  public fetchedAt: number = 0;
  public channel: string = '';
  public locale: string = '';
}

/** 负缓存标记文件的形状（`<候选名>.neg.json`，候选粒度） */
class TldrNegMeta {
  public fetchedAt: number = 0;
}

/** 一次渠道×路径尝试的参数 */
class TldrAttempt {
  public channel: string = '';
  public path: string = '';
  public locale: string = '';
  public url: string = '';
}

/** 一次单候选取数链的结果 */
enum TldrFetchOutcome {
  /** 拿到 markdown */
  HIT = 'hit',
  /** 全部尝试都是 404：确凿的「没有这一页」 */
  ALL_NOT_FOUND = 'all_not_found',
  /** 存在网络/非 404 失败：不能下「没有这一页」的结论 */
  FAILED = 'failed',
}

class TldrFetchResult {
  public outcome: TldrFetchOutcome = TldrFetchOutcome.FAILED;
  public markdown: string = '';
  public channel: string = '';
  public locale: string = '';
}

/** 落盘缓存的一次读取结果（键是候选页名） */
class TldrDiskEntry {
  public markdown: string = '';
  public fetchedAt: number = 0;
  public locale: string = '';
}

/**
 * tldr 用法示例的取数层：**候选名链**（spec §3.1 命名错位修复）——
 * `查询候选 = [token, 剥 @version 后缀, …executables]`，按序逐候选走
 * 内存 → 落盘（TTL 14 天 + stale-while-revalidate）→ 双渠道网络（jsDelivr → GitHub raw），
 * **命中即停**。两条硬规则（不许破）：
 *
 * 1. **单个候选的 404 不毒化整链**：负缓存保持候选粒度（`rg` 404 只写 `rg` 的负缓存），
 *    链上全部候选都 ALL_NOT_FOUND 才整链隐藏；24h 语义不变（G9）。
 *    网络失败（非 404）与 404 严格分开：链上出现一次网络失败立即终止（F1），不写任何负缓存
 *    —— 瞬时断网不能把候选毒化成 24h 的「无此页」。
 * 2. 解析器标题校验放宽为「标题 = 任一候选」（F6），防抓错页的防御不松（见 TldrParser）。
 *
 * **在途合并键 = 包名 token（链身份）**：候选链由 token 与 executables 派生，同一详情页
 * 的并发 get 必然派生同一条链，按 token 合并即可保证同链并发不重复取数；
 * 按首候选合并反而会让「token 与首候选不同」的链（ripgrep→rg）无法共享。
 *
 * 失败分级见 spec §5 —— **tldr 是增强层**：它的缺席不得产生任何错误可见性，
 * 所有失败在这里收敛成 `null`，UI 据此整区隐藏（G6）。
 *
 * ## 缓存目录与归属
 *
 * `filesDir/brew_live/tldr/<locale>/<命中页名>.md` + `<命中页名>.meta.json`（spec §3.1）；
 * 负缓存标记在根目录 `<候选名>.neg.json`（候选粒度）。目录由 `BrewCacheAdmin` 统一清理
 * （`clear()` 会连带删它），**不随 CacheEpoch（换源）清理** —— tldr 与浏览源无关，
 * 所以本类不读、不写世代号。
 *
 * ## 为什么写盘用「meta 是提交点」
 *
 * 先写 `.md` 再写 `.meta.json`，读取时两份**必须同时存在**才算命中 —— 进程在两步之间
 * 被杀，留下的无 meta 正文会被当作「没有缓存」直接重下，不会读到半份内容
 * （与 BrewCatalogFile 的 tmp+rename 同一目的，实现更薄）。
 */
export class TldrService {
  private static instance: TldrService | null = null;

  public static getInstance(): TldrService {
    if (TldrService.instance === null) {
      TldrService.instance = new TldrService();
    }
    return TldrService.instance;
  }

  /** utf-8 解码器。单例：TextDecoder.create 有构造成本，本类所有读盘共用一个 */
  private static decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });

  /** 内存正缓存：**候选页名**（小写）→ 页面。链查找按候选序扫 */
  private pageCache: Map<string, TldrPage> = new Map();
  /** 内存负缓存：**候选名**（小写）→ 写入时刻（G9 候选粒度） */
  private negCache: Map<string, number> = new Map();
  /** 在途请求合并：键 = 包名 token（链身份，见类注释） */
  private inflight: Map<string, Promise<TldrPage | null>> = new Map();
  /** F2：后台刷新连续失败计数（会话内；成功一次清零） */
  private refreshFailStreak: number = 0;

  private constructor() {
  }

  /**
   * 取一页 tldr。**任何失败都返回 null**（整链无页 / 网络 / 解析 / 非法 token），
   * 不抛错 —— 调用方（详情页 VM）拿到 null 就把分区藏掉，无需区分原因（G6）。
   *
   * `executables` 是详情页「提供的命令」清单（Normalizer 已有），参与候选链构建；
   * token 自身与剥 @version 后缀始终在链首。
   */
  public get(token: string, executables: string[]): Promise<TldrPage | null> {
    const normalized: string = token.trim().toLowerCase();
    if (normalized.length === 0) {
      Logger.info(TAG, `get token=${token} ok=false channel=none reason=bad_token`);
      return Promise.resolve(null);
    }
    const candidates: string[] = TldrParser.buildCandidates(normalized, executables);
    if (candidates.length === 0) {
      Logger.info(TAG, `get token=${normalized} ok=false channel=none reason=bad_candidates`);
      return Promise.resolve(null);
    }
    // 1. 链级内存缓存：按候选序扫，第一个命中的候选直接返回
    for (const candidate of candidates) {
      const memory: TldrPage | undefined = this.pageCache.get(candidate);
      if (memory !== undefined) {
        Logger.info(TAG, `get token=${normalized} locale=${memory.locale} ok=true channel=memory ` +
          `candidate=${candidate}`);
        return Promise.resolve(memory);
      }
    }
    // 2. 链级负缓存：全部候选都在 24h 负缓存内 → 整链无页（G9，候选粒度不毒化）
    let firstNegCandidate: string = '';
    let allNeg: boolean = true;
    for (const candidate of candidates) {
      if (this.negFreshAt(candidate) !== null) {
        if (firstNegCandidate.length === 0) {
          firstNegCandidate = candidate;
        }
      } else {
        allNeg = false;
        break;
      }
    }
    if (allNeg) {
      Logger.info(TAG, `neg-cache hit token=${firstNegCandidate} chain=${candidates.join(',')}`);
      return Promise.resolve(null);
    }
    // 3. 在途请求合并（键 = token，链身份）
    const pending: Promise<TldrPage | null> | undefined = this.inflight.get(normalized);
    if (pending !== undefined) {
      return pending;
    }
    // 在途合并：loadChain 自身吞掉全部失败（从不 reject），这里只是确保注册项一定被摘除
    const task: Promise<TldrPage | null> = this.loadChain(normalized, candidates).then(
      (page: TldrPage | null) => {
        this.inflight.delete(normalized);
        return page;
      },
      (error: Error) => {
        this.inflight.delete(normalized);
        return null;
      });
    this.inflight.set(normalized, task);
    return task;
  }

  /**
   * 给 BrewCacheAdmin 的维护入口：清空全部内存副本。
   * 盘上目录由调用方删除（`BrewCacheAdmin.clearTldr`）。
   */
  public resetMemory(): void {
    this.pageCache.clear();
    this.negCache.clear();
    this.inflight.clear();
    this.refreshFailStreak = 0;
  }

  // ---------------------------------------------------------------- 候选链

  private async loadChain(token: string, candidates: string[]): Promise<TldrPage | null> {
    // 落盘 stale 命中的候选：链命中即停后据此发起 SWR（G8）
    let staleCandidate: string = '';
    const result: TldrChainResult = await TldrParser.resolveChain(candidates,
      (candidate: string): Promise<TldrCandidateOutcome> => {
        return this.resolveCandidate(candidate, candidates, (stale: string) => {
          staleCandidate = stale;
        });
      });
    if (result.status === TLDR_CHAIN_HIT && result.page !== null) {
      if (result.hitOrigin === TLDR_ORIGIN_NETWORK) {
        // 网络命中才落盘（存原始 markdown，不是解析产物）；盘上命中的内容本来就是盘上的
        this.writeDisk(result.candidate, result.hitMarkdown, result.page.locale, result.hitChannel);
      }
      this.pageCache.set(result.candidate, result.page);
      this.refreshFailStreak = 0;
      Logger.info(TAG, `get token=${token} locale=${result.page.locale} ok=true ` +
        `channel=${result.hitOrigin === TLDR_ORIGIN_DISK ? TLDR_ORIGIN_DISK : result.hitChannel} ` +
        `candidate=${result.candidate}`);
      if (staleCandidate.length > 0) {
        // SWR（G8）：旧值已经返回，刷新在后台完成
        this.refreshInBackground(token, candidates);
      }
      return result.page;
    }
    if (result.status === TLDR_CHAIN_FAILED) {
      // F1：无缓存 + 全渠道网络失败 → 分区隐藏，UI 零提示；不写任何负缓存
      Logger.info(TAG, `fetch fail token=${token} candidates=${candidates.join(',')}`);
      return null;
    }
    if (result.parseFailHead.length > 0) {
      // F3 / F6：链上拿到的内容对不上任一候选。不写缓存，让下次访问重取
      Logger.info(TAG, `parse fail token=${token} head=${result.parseFailHead}`);
    }
    // 整链 all_not_found：每个候选的负缓存已由 resolveCandidate 逐个写入
    Logger.info(TAG, `chain-miss token=${token} candidates=${candidates.join(',')}`);
    return null;
  }

  /**
   * 单候选的一次取数结论（供 `TldrParser.resolveChain` 回调）。
   *
   * 顺序：候选负缓存（跳过）→ 落盘（解析校验通过即命中；stale 走 SWR）→
   * 网络（双渠道 × 回落路径；全 404 写**该候选**的负缓存）。
   */
  private async resolveCandidate(candidate: string, candidates: string[],
    staleSink: (candidate: string) => void): Promise<TldrCandidateOutcome> {
    // 1. 候选粒度负缓存（G9）：24h 内不再请求这一个候选
    const negAt: number | null = this.negFreshAt(candidate);
    if (negAt !== null) {
      Logger.info(TAG, `neg-cache hit token=${candidate} age=${Date.now() - negAt}ms`);
      return TldrService.outcome(TLDR_OUTCOME_NOT_FOUND);
    }
    // 2. 落盘缓存（键 = 候选页名）
    const disk: TldrDiskEntry | null = this.readDisk(candidate);
    if (disk !== null) {
      const parsed: TldrPage | null = TldrParser.parse(disk.markdown, candidates, disk.locale);
      if (parsed !== null) {
        if (Date.now() - disk.fetchedAt >= TLDR_TTL_MS) {
          // stale：链在这一候选停下（返回旧值），SWR 由 loadChain 统一发起（G8）
          staleSink(candidate);
          Logger.info(TAG, `refresh stale token=${candidate}`);
        }
        return TldrService.outcome(TLDR_OUTCOME_HIT, disk.markdown, disk.locale, TLDR_ORIGIN_DISK);
      }
      // 盘上内容解析失败（F3 / F6）：删掉这份被污染的缓存，本候选继续走网络
      Logger.info(TAG, `parse fail token=${candidate} channel=disk head=${TldrService.headOf(disk.markdown)}`);
      this.deleteCached(candidate, disk.locale);
    }
    // 3. 网络抓取（双渠道 × 回落路径，per candidate）
    const fetched: TldrFetchResult = await this.fetchChain(candidate);
    if (fetched.outcome === TldrFetchOutcome.HIT) {
      return TldrService.outcome(TLDR_OUTCOME_HIT, fetched.markdown, fetched.locale,
        TLDR_ORIGIN_NETWORK, fetched.channel);
    }
    if (fetched.outcome === TldrFetchOutcome.ALL_NOT_FOUND) {
      // F4：确凿的「没有这一页」→ **该候选**的负缓存 24h（G9，不毒化整链）
      const now: number = Date.now();
      this.negCache.set(candidate, now);
      this.writeNegDisk(candidate, now);
      Logger.info(TAG, `neg-cache put token=${candidate} ttl=24h`);
      return TldrService.outcome(TLDR_OUTCOME_NOT_FOUND);
    }
    // 网络失败：交给链决策（resolveChain 立即终止整链，不写负缓存）
    return TldrService.outcome(TLDR_OUTCOME_FAILED);
  }

  /**
   * stale-while-revalidate 的后台半程（G8）。
   *
   * 只走网络（盘上的旧值就是正在展示的内容）；失败静默（F2：继续显示旧值，UI 无感知），
   * 连续失败 3 次后本次会话不再刷新。成功后就地替换内存与盘上副本。
   */
  private refreshInBackground(token: string, candidates: string[]): void {
    if (this.refreshFailStreak >= TLDR_REFRESH_FAIL_LIMIT) {
      Logger.info(TAG, `refresh skipped token=${token} streak=${this.refreshFailStreak}`);
      return;
    }
    TldrParser.resolveChain(candidates, (candidate: string): Promise<TldrCandidateOutcome> => {
      return this.refreshCandidate(candidate);
    }).then((result: TldrChainResult) => {
      if (result.status === TLDR_CHAIN_HIT && result.page !== null) {
        if (result.hitOrigin === TLDR_ORIGIN_NETWORK) {
          this.writeDisk(result.candidate, result.hitMarkdown, result.page.locale, result.hitChannel);
        }
        this.pageCache.set(result.candidate, result.page);
        this.refreshFailStreak = 0;
        Logger.info(TAG, `refresh ok token=${token} locale=${result.page.locale} ` +
          `channel=${result.hitChannel} candidate=${result.candidate}`);
        return;
      }
      if (result.status === TLDR_CHAIN_FAILED) {
        this.refreshFailStreak++;
        Logger.info(TAG, `refresh fail token=${token} count=${this.refreshFailStreak}`);
        return;
      }
      // 整链确认无页（上游撤了页面）：保留旧缓存继续展示，不计入失败连击
      Logger.info(TAG, `refresh miss token=${token} keep cache candidates=${candidates.join(',')}`);
    }).catch((error: Error) => {
      this.refreshFailStreak++;
      Logger.warn(TAG, `refresh fail token=${token} count=${this.refreshFailStreak} msg=${error.message}`);
    });
  }

  /** 刷新路径的单候选结论：只走网络，不读盘、不写负缓存（负缓存只描述「首次查询无页」） */
  private async refreshCandidate(candidate: string): Promise<TldrCandidateOutcome> {
    const fetched: TldrFetchResult = await this.fetchChain(candidate);
    if (fetched.outcome === TldrFetchOutcome.HIT) {
      return TldrService.outcome(TLDR_OUTCOME_HIT, fetched.markdown, fetched.locale,
        TLDR_ORIGIN_NETWORK, fetched.channel);
    }
    if (fetched.outcome === TldrFetchOutcome.ALL_NOT_FOUND) {
      return TldrService.outcome(TLDR_OUTCOME_NOT_FOUND);
    }
    return TldrService.outcome(TLDR_OUTCOME_FAILED);
  }

  // ---------------------------------------------------------------- 单候选取数链

  /**
   * 双渠道 × 回落路径的顺序抓取（单候选）。
   *
   * 渠道优先、路径次之（TldrConstants.TLDR_CHANNELS 的注释）：jsDelivr 健康时一条路径
   * 命中就结束；整渠道不可达时才切下一渠道，切换时打 G7 的 fallback 行。
   *
   * 404 与网络失败分开记账：**只有全部尝试都是 404** 才是确凿的「没有这一页」；
   * 混入过网络失败时按 F1 处理 —— 瞬时断网不能把一个候选毒化成 24h 的「无此页」。
   */
  private async fetchChain(normalized: string): Promise<TldrFetchResult> {
    const result: TldrFetchResult = new TldrFetchResult();
    let saw404: boolean = false;
    let sawError: boolean = false;
    let previousChannel: string = '';
    const attempts: TldrAttempt[] = TldrService.buildAttempts(normalized);
    for (let index: number = 0; index < attempts.length; index++) {
      const attempt: TldrAttempt = attempts[index];
      if (previousChannel.length > 0 && previousChannel !== attempt.channel && (saw404 || sawError)) {
        // G7：渠道回落可观测
        Logger.info(TAG, `channel fallback ${previousChannel}→${attempt.channel}`);
      }
      previousChannel = attempt.channel;
      try {
        const resp: BrewHttpResult = await BrewHttp.request(attempt.url, http.RequestMethod.GET,
          {}, TLDR_HTTP_TIMEOUT_MS);
        if (resp.code === 200 && resp.text.length > 0) {
          result.outcome = TldrFetchOutcome.HIT;
          result.markdown = resp.text;
          result.channel = attempt.channel;
          result.locale = attempt.locale;
          return result;
        }
        if (resp.code === 404) {
          saw404 = true;
        } else {
          sawError = true;
          Logger.info(TAG, `attempt fail token=${normalized} channel=${attempt.channel} ` +
            `path=${attempt.path} status=${resp.code}`);
        }
      } catch (error) {
        sawError = true;
        const err = error as BusinessError;
        Logger.info(TAG, `attempt fail token=${normalized} channel=${attempt.channel} ` +
          `path=${attempt.path} msg=${err?.message}`);
      }
    }
    result.outcome = sawError ? TldrFetchOutcome.FAILED : TldrFetchOutcome.ALL_NOT_FOUND;
    return result;
  }

  // ---------------------------------------------------------------- 落盘

  private filesDir(): string {
    const uiContext: UIContext | undefined = AppStorage.get<UIContext>(StorageKey.UI_CONTEXT);
    if (uiContext === undefined) {
      return '';
    }
    const host: Context | undefined = uiContext.getHostContext();
    if (host === undefined) {
      return '';
    }
    return host.filesDir;
  }

  private rootDir(): string {
    return this.filesDir() + '/' + TLDR_CACHE_ROOT;
  }

  /** 候选是否在 24h 负缓存内；是则返回写入时刻（内存优先，其次落盘标记并回填内存） */
  private negFreshAt(candidate: string): number | null {
    const memory: number | undefined = this.negCache.get(candidate);
    if (memory !== undefined) {
      return Date.now() - memory < TLDR_NEG_TTL_MS ? memory : null;
    }
    const diskAt: number | null = this.readNegDisk(candidate);
    if (diskAt !== null && Date.now() - diskAt < TLDR_NEG_TTL_MS) {
      this.negCache.set(candidate, diskAt);
      return diskAt;
    }
    return null;
  }

  private readDisk(candidate: string): TldrDiskEntry | null {
    const root: string = this.rootDir();
    if (root.length === 0) {
      return null;
    }
    const locales: string[] = [TLDR_LOCALE_ZH, TLDR_LOCALE_EN];
    for (const locale of locales) {
      const markdown: string | null = TldrService.readFile(root + '/' + locale + '/' + candidate + '.md');
      if (markdown === null) {
        continue;
      }
      const metaRaw: string | null = TldrService.readFile(
        root + '/' + locale + '/' + candidate + TLDR_META_SUFFIX);
      if (metaRaw === null) {
        continue;
      }
      let meta: TldrMeta | null = null;
      try {
        meta = JSON.parse(metaRaw) as TldrMeta;
      } catch (error) {
        // meta 损坏按「这一语言没有缓存」处理
        continue;
      }
      if (meta === null || !(meta.fetchedAt > 0)) {
        continue;
      }
      const entry: TldrDiskEntry = new TldrDiskEntry();
      entry.markdown = markdown;
      entry.fetchedAt = meta.fetchedAt;
      entry.locale = meta.locale.length > 0 ? meta.locale : locale;
      return entry;
    }
    return null;
  }

  /** 写盘（键 = 命中的候选页名，内容 = 原始 markdown）。先正文后 meta：meta 是提交点（见类注释） */
  private writeDisk(candidate: string, markdown: string, locale: string, channel: string): void {
    const root: string = this.rootDir();
    if (root.length === 0) {
      return;
    }
    const dir: string = root + '/' + locale;
    if (!TldrService.ensureDir(dir)) {
      return;
    }
    const meta: TldrMeta = new TldrMeta();
    meta.fetchedAt = Date.now();
    meta.channel = channel;
    meta.locale = locale;
    const wroteBody: boolean = TldrService.writeFile(dir + '/' + candidate + '.md', markdown);
    const wroteMeta: boolean = TldrService.writeFile(dir + '/' + candidate + TLDR_META_SUFFIX,
      JSON.stringify(meta));
    if (!wroteBody || !wroteMeta) {
      Logger.warn(TAG, `disk write incomplete candidate=${candidate} body=${wroteBody} meta=${wroteMeta}`);
    }
  }

  private readNegDisk(candidate: string): number | null {
    const root: string = this.rootDir();
    if (root.length === 0) {
      return null;
    }
    const raw: string | null = TldrService.readFile(root + '/' + candidate + TLDR_NEG_SUFFIX);
    if (raw === null) {
      return null;
    }
    try {
      const meta: TldrNegMeta = JSON.parse(raw) as TldrNegMeta;
      return meta.fetchedAt > 0 ? meta.fetchedAt : null;
    } catch (error) {
      return null;
    }
  }

  private writeNegDisk(candidate: string, at: number): void {
    const root: string = this.rootDir();
    if (root.length === 0) {
      return;
    }
    if (!TldrService.ensureDir(root)) {
      return;
    }
    const meta: TldrNegMeta = new TldrNegMeta();
    meta.fetchedAt = at;
    TldrService.writeFile(root + '/' + candidate + TLDR_NEG_SUFFIX, JSON.stringify(meta));
  }

  /** 删除某候选的正缓存（语言目录下 md + meta）。负缓存标记保留 */
  private deleteCached(candidate: string, locale: string): void {
    const dir: string = this.rootDir() + '/' + locale;
    TldrService.unlinkQuietly(dir + '/' + candidate + '.md');
    TldrService.unlinkQuietly(dir + '/' + candidate + TLDR_META_SUFFIX);
  }

  // ---------------------------------------------------------------- 文件原子

  private static ensureDir(dir: string): boolean {
    try {
      fileIo.mkdirSync(dir, true);
      return true;
    } catch (error) {
      const err = error as BusinessError;
      // 目录已存在是重写路径的预期情况（SDK 不保证 recursion 幂等，见 BrewCatalogFile）
      if (err?.code === 13900015) {
        return true;
      }
      Logger.warn(TAG, `mkdir failed dir=${dir} code=${err?.code}`);
      return false;
    }
  }

  private static readFile(path: string): string | null {
    try {
      if (!fileIo.accessSync(path)) {
        return null;
      }
      const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      let text: string | null = null;
      try {
        const stat = fileIo.statSync(file.fd);
        const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
        const read: number = fileIo.readSync(file.fd, buffer, { offset: 0, length: stat.size });
        if (read === stat.size) {
          text = TldrService.decoder.decodeToString(new Uint8Array(buffer));
        }
      } finally {
        fileIo.closeSync(file);
      }
      return text;
    } catch (error) {
      return null;
    }
  }

  private static writeFile(path: string, text: string): boolean {
    let file: fileIo.File | undefined = undefined;
    try {
      file = fileIo.openSync(path,
        fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, text);
      return true;
    } catch (error) {
      return false;
    } finally {
      if (file !== undefined) {
        try {
          fileIo.closeSync(file);
        } catch (closeError) {
          // 关闭失败不影响写入结果判定
        }
      }
    }
  }

  private static unlinkQuietly(path: string): void {
    try {
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    } catch (error) {
      // 清理失败不阻塞主流程
    }
  }

  /** F3 / F6 时日志带走的原文头部（spec §5：报告原文前 200 字节），压成单行 */
  private static headOf(text: string): string {
    const head: string = text.substring(0, TLDR_FAIL_HEAD_BYTES);
    return head.replace(/[\r\n]+/g, ' ');
  }

  /** 渠道 × 回落路径的完整尝试表（单候选）。顺序约定见 TLDR_CHANNELS 注释 */
  private static buildAttempts(normalized: string): TldrAttempt[] {
    const attempts: TldrAttempt[] = [];
    for (const channel of TLDR_CHANNELS) {
      for (const path of TLDR_PAGE_PATHS) {
        const isGithub: boolean = channel === TLDR_CHANNEL_GITHUB;
        const attempt: TldrAttempt = new TldrAttempt();
        attempt.channel = isGithub ? TLDR_CHANNEL_GITHUB : TLDR_CHANNEL_JSDELIVR;
        attempt.path = path;
        attempt.locale = path.startsWith('pages.zh') ? TLDR_LOCALE_ZH : TLDR_LOCALE_EN;
        attempt.url = (isGithub ? TLDR_URL_GITHUB_BASE : TLDR_URL_JSDELIVR_BASE) +
          '/' + path + '/' + normalized + '.md';
        attempts.push(attempt);
      }
    }
    return attempts;
  }

  private static outcome(kind: string, markdown: string = '', locale: string = '',
    origin: string = '', channel: string = ''): TldrCandidateOutcome {
    const outcome: TldrCandidateOutcome = new TldrCandidateOutcome();
    outcome.kind = kind;
    outcome.markdown = markdown;
    outcome.locale = locale;
    outcome.origin = origin;
    outcome.channel = channel;
    return outcome;
  }
}
