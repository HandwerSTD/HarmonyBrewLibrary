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
import { TldrParser } from '../util/TldrParser';
import { BrewHttp, BrewHttpResult } from './BrewHttp';

const TAG: string = TLDR_LOG_TAG;

/** meta 文件的形状（`<token>.meta.json`，spec §3.1） */
class TldrMeta {
  public fetchedAt: number = 0;
  public channel: string = '';
  public locale: string = '';
}

/** 负缓存标记文件的形状（`<token>.neg.json`） */
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

/** 一次取数链的结果 */
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

/** 落盘缓存的一次读取结果 */
class TldrDiskEntry {
  public markdown: string = '';
  public fetchedAt: number = 0;
  public locale: string = '';
}

/**
 * tldr 用法示例的取数层：内存缓存 → 落盘缓存（TTL 14 天 + stale-while-revalidate）→
 * 双渠道网络抓取（jsDelivr → GitHub raw）→ 24h 404 负缓存。
 *
 * 流水线口径见 spec §3.1；失败分级见 spec §5 —— **tldr 是增强层**：它的缺席不得产生
 * 任何错误可见性，所有失败在这里收敛成 `null`，UI 据此整区隐藏（G6）。
 *
 * ## 缓存目录与归属
 *
 * `filesDir/brew_live/tldr/<locale>/<token>.md` + `<token>.meta.json`（spec §3.1）；
 * 负缓存标记在根目录 `<token>.neg.json`。目录由 `BrewCacheAdmin` 统一清理
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

  /** 内存正缓存：token（小写）→ 页面 */
  private pageCache: Map<string, TldrPage> = new Map();
  /** 内存负缓存：token（小写）→ 写入时刻 */
  private negCache: Map<string, number> = new Map();
  /** 在途请求合并：同一 token 的并发 get 共享同一个 Promise */
  private inflight: Map<string, Promise<TldrPage | null>> = new Map();
  /** F2：后台刷新连续失败计数（会话内；成功一次清零） */
  private refreshFailStreak: number = 0;

  private constructor() {
  }

  /**
   * 取一页 tldr。**任何失败都返回 null**（404 / 网络 / 解析 / 非法 token），
   * 不抛错 —— 调用方（详情页 VM）拿到 null 就把分区藏掉，无需区分原因（G6）。
   */
  public get(token: string): Promise<TldrPage | null> {
    const normalized: string = token.trim().toLowerCase();
    if (normalized.length === 0 || !TldrService.isCacheableToken(normalized)) {
      Logger.info(TAG, `get token=${token} ok=false channel=none reason=bad_token`);
      return Promise.resolve(null);
    }
    // 1. 内存正缓存
    const memory: TldrPage | undefined = this.pageCache.get(normalized);
    if (memory !== undefined) {
      Logger.info(TAG, `get token=${normalized} locale=${memory.locale} ok=true channel=memory`);
      return Promise.resolve(memory);
    }
    // 2. 内存负缓存（24h 内不再重复请求，G9）
    const negAt: number | undefined = this.negCache.get(normalized);
    if (negAt !== undefined) {
      if (Date.now() - negAt < TLDR_NEG_TTL_MS) {
        Logger.info(TAG, `neg-cache hit token=${normalized} age=${Date.now() - negAt}ms`);
        return Promise.resolve(null);
      }
      this.negCache.delete(normalized);
    }
    // 3. 在途请求合并
    const pending: Promise<TldrPage | null> | undefined = this.inflight.get(normalized);
    if (pending !== undefined) {
      return pending;
    }
    // 在途合并：load() 自身吞掉全部失败（从不 reject），这里只是确保注册项一定被摘除
    const task: Promise<TldrPage | null> = this.load(normalized).then(
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

  // ---------------------------------------------------------------- 主流程

  private load(normalized: string): Promise<TldrPage | null> {
    // 4. 落盘缓存。命中且未过期 → 直接用；已过期 → 先返回旧值 + 后台刷新（G8）
    const disk: TldrDiskEntry | null = this.readDisk(normalized);
    if (disk !== null) {
      const parsed: TldrPage | null = TldrParser.parse(disk.markdown, normalized, disk.locale);
      if (parsed !== null) {
        this.pageCache.set(normalized, parsed);
        const fresh: boolean = Date.now() - disk.fetchedAt < TLDR_TTL_MS;
        if (fresh) {
          Logger.info(TAG, `get token=${normalized} locale=${parsed.locale} ok=true channel=disk`);
          return Promise.resolve(parsed);
        }
        // stale-while-revalidate：旧值立刻返回，刷新在后台完成（G8）
        Logger.info(TAG, `get token=${normalized} locale=${parsed.locale} ok=true channel=disk stale=true`);
        this.refreshInBackground(normalized);
        return Promise.resolve(parsed);
      }
      // 盘上内容解析失败（F3 / F6）：删掉这份被污染的缓存，走网络重取
      Logger.info(TAG, `parse fail token=${normalized} channel=disk head=${TldrService.headOf(disk.markdown)}`);
      this.deleteCached(normalized, disk.locale);
    }
    // 5. 落盘负缓存（跨进程存续，G9）
    const negDisk: number | null = this.readNegDisk(normalized);
    if (negDisk !== null && Date.now() - negDisk < TLDR_NEG_TTL_MS) {
      this.negCache.set(normalized, negDisk);
      Logger.info(TAG, `neg-cache hit token=${normalized} age=${Date.now() - negDisk}ms source=disk`);
      return Promise.resolve(null);
    }
    // 6. 网络抓取（双渠道 × 回落路径）
    return this.fetchChain(normalized).then((result: TldrFetchResult) => {
      if (result.outcome === TldrFetchOutcome.HIT) {
        const parsed: TldrPage | null = TldrParser.parse(result.markdown, normalized, result.locale);
        if (parsed === null) {
          // F3 / F6：内容不是可用的 tldr 页。不写任何缓存，让下次访问重取
          Logger.info(TAG, `parse fail token=${normalized} channel=${result.channel} ` +
            `head=${TldrService.headOf(result.markdown)}`);
          return null;
        }
        this.writeDisk(normalized, result.markdown, result.channel, parsed.locale);
        this.pageCache.set(normalized, parsed);
        this.refreshFailStreak = 0;
        Logger.info(TAG, `get token=${normalized} locale=${parsed.locale} ok=true channel=${result.channel}`);
        return parsed;
      }
      if (result.outcome === TldrFetchOutcome.ALL_NOT_FOUND) {
        // F4：确凿的「没有这一页」→ 负缓存 24h（G9）
        const now: number = Date.now();
        this.negCache.set(normalized, now);
        this.writeNegDisk(normalized, now);
        Logger.info(TAG, `neg-cache put token=${normalized} ttl=24h`);
        return null;
      }
      // F1：无缓存 + 全渠道网络失败 → 分区隐藏，UI 零提示
      Logger.info(TAG, `fetch fail token=${normalized}`);
      return null;
    }).catch((error: Error) => {
      // 取数链内部已经吞掉单次失败，走到这里属于非预期异常：按 F1 处理
      Logger.warn(TAG, `fetch unexpected token=${normalized} msg=${error.message}`);
      return null;
    });
  }

  /**
   * stale-while-revalidate 的后台半程。
   *
   * 失败静默（F2：继续显示旧值，UI 无感知），连续失败 3 次后本次会话不再刷新。
   * 成功后就地替换内存与盘上副本 —— 正在展示的页面下次进入（或内存命中）拿到新值。
   */
  private refreshInBackground(normalized: string): void {
    if (this.refreshFailStreak >= TLDR_REFRESH_FAIL_LIMIT) {
      Logger.info(TAG, `refresh skipped token=${normalized} streak=${this.refreshFailStreak}`);
      return;
    }
    Logger.info(TAG, `refresh stale token=${normalized}`);
    this.fetchChain(normalized).then((result: TldrFetchResult) => {
      if (result.outcome !== TldrFetchOutcome.HIT) {
        this.refreshFailStreak++;
        Logger.info(TAG, `refresh fail token=${normalized} count=${this.refreshFailStreak}`);
        return;
      }
      const parsed: TldrPage | null = TldrParser.parse(result.markdown, normalized, result.locale);
      if (parsed === null) {
        // 刷新拿到的是坏内容：不动旧缓存（旧值继续可用），按一次失败计
        Logger.info(TAG, `parse fail token=${normalized} channel=${result.channel} ` +
          `head=${TldrService.headOf(result.markdown)}`);
        this.refreshFailStreak++;
        return;
      }
      this.writeDisk(normalized, result.markdown, result.channel, parsed.locale);
      this.pageCache.set(normalized, parsed);
      this.refreshFailStreak = 0;
      Logger.info(TAG, `refresh ok token=${normalized} locale=${parsed.locale} channel=${result.channel}`);
    }).catch((error: Error) => {
      this.refreshFailStreak++;
      Logger.warn(TAG, `refresh fail token=${normalized} count=${this.refreshFailStreak} msg=${error.message}`);
    });
  }

  // ---------------------------------------------------------------- 取数链

  /**
   * 双渠道 × 回落路径的顺序抓取。
   *
   * 渠道优先、路径次之（TldrConstants.TLDR_CHANNELS 的注释）：jsDelivr 健康时一条路径
   * 命中就结束；整渠道不可达时才切下一渠道，切换时打 G7 的 fallback 行。
   *
   * 404 与网络失败分开记账：**只有全部尝试都是 404** 才是确凿的「没有这一页」
   * （走 G9 负缓存）；混入过网络失败时按 F1 处理 —— 瞬时断网不能把一个 token
   * 毒化成 24h 的「无此页」。
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

  private readDisk(normalized: string): TldrDiskEntry | null {
    const root: string = this.rootDir();
    if (root.length === 0) {
      return null;
    }
    const locales: string[] = [TLDR_LOCALE_ZH, TLDR_LOCALE_EN];
    for (const locale of locales) {
      const markdown: string | null = TldrService.readFile(root + '/' + locale + '/' + normalized + '.md');
      if (markdown === null) {
        continue;
      }
      const metaRaw: string | null = TldrService.readFile(
        root + '/' + locale + '/' + normalized + TLDR_META_SUFFIX);
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

  private writeDisk(normalized: string, markdown: string, channel: string, locale: string): void {
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
    // 先正文后 meta：meta 是提交点（见类注释）
    const wroteBody: boolean = TldrService.writeFile(dir + '/' + normalized + '.md', markdown);
    const wroteMeta: boolean = TldrService.writeFile(dir + '/' + normalized + TLDR_META_SUFFIX,
      JSON.stringify(meta));
    if (!wroteBody || !wroteMeta) {
      Logger.warn(TAG, `disk write incomplete token=${normalized} body=${wroteBody} meta=${wroteMeta}`);
    }
  }

  private readNegDisk(normalized: string): number | null {
    const root: string = this.rootDir();
    if (root.length === 0) {
      return null;
    }
    const raw: string | null = TldrService.readFile(root + '/' + normalized + TLDR_NEG_SUFFIX);
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

  private writeNegDisk(normalized: string, at: number): void {
    const root: string = this.rootDir();
    if (root.length === 0) {
      return;
    }
    if (!TldrService.ensureDir(root)) {
      return;
    }
    const meta: TldrNegMeta = new TldrNegMeta();
    meta.fetchedAt = at;
    TldrService.writeFile(root + '/' + normalized + TLDR_NEG_SUFFIX, JSON.stringify(meta));
  }

  /** 删除某 token 的正缓存（语言目录下 md + meta）。负缓存标记保留 */
  private deleteCached(normalized: string, locale: string): void {
    const dir: string = this.rootDir() + '/' + locale;
    TldrService.unlinkQuietly(dir + '/' + normalized + '.md');
    TldrService.unlinkQuietly(dir + '/' + normalized + TLDR_META_SUFFIX);
  }

  // ---------------------------------------------------------------- 文件原子

  /**
   * token 能否安全地当文件名。tldr 页名是小写字母数字与 `-_.@+`；
   * 路由参数里的 token 不可信，路径穿越（`..`、分隔符）在这里被挡死。
   * 不通过的 token 仍可走内存与网络，只是不落盘。
   */
  private static isCacheableToken(token: string): boolean {
    if (token.length === 0 || token.length > 100 || token.indexOf('..') >= 0 ||
      token.indexOf('/') >= 0 || token.indexOf('\\') >= 0) {
      return false;
    }
    return /^[a-z0-9@._+-]+$/.test(token);
  }

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

  /** 渠道 × 回落路径的完整尝试表。顺序约定见 TLDR_CHANNELS 注释 */
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
}
