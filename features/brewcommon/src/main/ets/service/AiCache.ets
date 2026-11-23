/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger, StorageKey } from '@ohos/common';
import { AI_CACHE_ROOT_SEGMENT } from '../constant/AiConstants';

const TAG: string = '[ai]';

/**
 * 一条缓存记录的 meta（spec §3.3）：promptVersion / fetchedAt / model。
 * 正文（content）与 meta 同文件：`{meta:{...}, data:<task-specific JSON object>}`。
 */
export class AiCacheEnvelope {
  public promptVersion: number = 0;
  public fetchedAt: number = 0;
  public model: string = '';
  /** data 的 JSON 文本（任务侧自己再 parse 成强类型）。 */
  public dataJson: string = '';
}

/** 读缓存的三种结论（G9 / G10 的判据日志直接用）。 */
export enum AiCacheReadResult {
  HIT = 'hit',
  /** 过期但旧值可用（stale-while-revalidate 的「先旧值」）。 */
  STALE = 'stale',
  MISS = 'miss',
}

/** 读缓存的结构化返回：命中方式 + 正文（stale 也有正文）。 */
export class AiCacheRead {
  public result: AiCacheReadResult = AiCacheReadResult.MISS;
  /** miss 原因（G9 判据要区分 reason=promptVersion / reason=missing）。 */
  public missReason: string = '';
  public envelope: AiCacheEnvelope | null = null;
}

/**
 * AI 缓存的盘上读写（spec §3.3）。
 *
 * - **目录**：`filesDir/brew_live/ai/<feature>/<providerModelKey>/<cacheKey>.json`；
 *   providerModelKey 归一化（小写、非 [a-z0-9] 折成 `-`），防路径注入；
 * - **登记**：已进 `BrewCacheAdmin.clearAll()` 的清理范围（与 CacheEpoch 无关）；
 * - **TTL / promptVersion**：由调用方给（D1 7 天 / D2 1 天；版本号不匹配即按 miss
 *   reason=promptVersion 处理，旧文件顺手删掉）；
 * - **写原子性**：`.tmp` + unlink 旧文件 + rename（`renameSync` 不覆盖已存在目标，
 *   平台行为见 BrewCatalogFile 的注释）。
 */
export class AiCache {
  /**
   * 读缓存。文件缺失 / 数据损坏 → MISS(reason=missing/corrupt)；
   * promptVersion 不符 → MISS(reason=promptVersion) 并删除旧文件（G9）；
   * 未过期 → HIT；已过期 → STALE（旧值仍返回，调用方决定是否后台刷新）。
   */
  public static read(feature: string, providerModelKey: string, cacheKey: string,
    promptVersion: number, ttlMs: number): AiCacheRead {
    const path: string = AiCache.pathOf(feature, providerModelKey, cacheKey);
    let read: AiCacheRead = new AiCacheRead();
    if (!AiCache.fileExists(path)) {
      read.result = AiCacheReadResult.MISS;
      read.missReason = 'missing';
      return read;
    }
    let envelope: AiCacheEnvelope | null = AiCache.parseFile(path);
    if (envelope === null) {
      read.result = AiCacheReadResult.MISS;
      read.missReason = 'corrupt';
      return read;
    }
    if (envelope.promptVersion !== promptVersion) {
      // 版本不符的旧文件没有留存价值：删掉，别占 CacheAdmin 清理之外的空间
      AiCache.deleteFile(feature, providerModelKey, cacheKey);
      read.result = AiCacheReadResult.MISS;
      read.missReason = 'promptVersion';
      return read;
    }
    const age: number = Date.now() - envelope.fetchedAt;
    if (age < 0 || age >= ttlMs) {
      read.result = AiCacheReadResult.STALE;
    } else {
      read.result = AiCacheReadResult.HIT;
    }
    read.envelope = envelope;
    return read;
  }

  /** 写缓存。写失败只记日志（缓存缺席 = 下次 miss，不影响功能正确性）。 */
  public static write(feature: string, providerModelKey: string, cacheKey: string,
    promptVersion: number, model: string, dataJson: string): void {
    const path: string = AiCache.pathOf(feature, providerModelKey, cacheKey);
    const dir: string = path.substring(0, path.lastIndexOf('/'));
    const envelope: AiCacheEnvelope = new AiCacheEnvelope();
    envelope.promptVersion = promptVersion;
    envelope.fetchedAt = Date.now();
    envelope.model = model;
    envelope.dataJson = dataJson;
    // ArkTS 禁无类型对象字面量：先落一个带类型标注的空 Record 再逐键填（与 BrewCatalogFile 同款）
    const meta: Record<string, Object> = {};
    meta['promptVersion'] = envelope.promptVersion;
    meta['fetchedAt'] = envelope.fetchedAt;
    meta['model'] = envelope.model;
    const body: Record<string, Object> = {};
    body['meta'] = meta;
    body['data'] = envelope.dataJson;
    const bodyText: string = JSON.stringify(body);
    let file: fileIo.File | undefined = undefined;
    const tempPath: string = path + '.tmp';
    try {
      try {
        fileIo.mkdirSync(dir, true);
      } catch (mkdirError) {
        const mkdirErr: BusinessError = mkdirError as BusinessError;
        // 13900015 File exists = 目录已在（重写路径的预期情况），见 BrewCatalogFile 的注释
        if (mkdirErr?.code !== 13900015) {
          throw mkdirError as Error;
        }
      }
      if (fileIo.accessSync(tempPath)) {
        fileIo.unlinkSync(tempPath);
      }
      file = fileIo.openSync(tempPath, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE |
        fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, bodyText);
      fileIo.closeSync(file);
      file = undefined;
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
      fileIo.renameSync(tempPath, path);
      Logger.info(TAG, `cache write feature=${feature} key=${cacheKey} bytes=${bodyText.length}`);
    } catch (error) {
      if (file !== undefined) {
        try {
          fileIo.closeSync(file);
        } catch (closeErr) {
          Logger.warn(TAG, `cache write close failed, code=${(closeErr as BusinessError)?.code}`);
        }
      }
      const err: BusinessError = error as BusinessError;
      Logger.error(TAG, `cache write failed, feature=${feature}, code=${err?.code}, msg=${err?.message}`);
    }
  }

  /** 删除一条缓存（promptVersion 升级时清旧版本用）。 */
  public static deleteFile(feature: string, providerModelKey: string, cacheKey: string): void {
    try {
      const path: string = AiCache.pathOf(feature, providerModelKey, cacheKey);
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      Logger.warn(TAG, `cache delete failed, feature=${feature}, code=${err?.code}`);
    }
  }

  /** CacheAdmin 清理入口：整个 `brew_live/ai` 目录连根删。 */
  public static clearAll(): void {
    const ctx: Context | undefined = AiCache.context();
    if (ctx === undefined) {
      return;
    }
    const root: string = ctx.filesDir + '/' + AI_CACHE_ROOT_SEGMENT;
    try {
      if (fileIo.accessSync(root)) {
        fileIo.rmdirSync(root);
        Logger.info(TAG, `cache cleared root=${root}`);
      }
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      Logger.error(TAG, `cache clear failed, code=${err?.code}, msg=${err?.message}`);
    }
  }

  /** 缓存路径。cacheKey 只允许 [a-zA-Z0-9-]（调用方传入前归一化，这里再守一道）。 */
  private static pathOf(feature: string, providerModelKey: string, cacheKey: string): string {
    const ctx: Context | undefined = AiCache.context();
    const safeFeature: string = AiCache.sanitize(feature);
    const safeProvider: string = AiCache.sanitize(providerModelKey);
    const safeKey: string = AiCache.sanitize(cacheKey);
    return (ctx === undefined ? '' : ctx.filesDir) + '/' + AI_CACHE_ROOT_SEGMENT +
      '/' + safeFeature + '/' + safeProvider + '/' + safeKey + '.json';
  }

  /** 路径段归一化：非字母数字折成 `-`，压掉分隔符（防注入，对齐 tokenId 的确定性思路）。 */
  private static sanitize(segment: string): string {
    let out: string = '';
    for (let i: number = 0; i < segment.length; i++) {
      const ch: string = segment.charAt(i).toLowerCase();
      const isAlnum: boolean = (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9');
      out += isAlnum ? ch : '-';
    }
    return out.length === 0 ? 'empty' : out.substring(0, 64);
  }

  private static fileExists(path: string): boolean {
    if (path.length === 0) {
      return false;
    }
    try {
      return fileIo.accessSync(path);
    } catch (error) {
      return false;
    }
  }

  private static parseFile(path: string): AiCacheEnvelope | null {
    let file: fileIo.File | undefined = undefined;
    try {
      file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      const size: number = fileIo.statSync(file.fd).size;
      const buffer: ArrayBuffer = new ArrayBuffer(size);
      const read: number = fileIo.readSync(file.fd, buffer, { offset: 0, length: size });
      fileIo.closeSync(file);
      file = undefined;
      if (read !== size) {
        return null;
      }
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      const text: string = decoder.decodeToString(new Uint8Array(buffer), { stream: false });
      const parsed: Object = JSON.parse(text) as Object;
      const obj: Record<string, Object> = parsed as Record<string, Object>;
      const metaObj: Object | undefined = obj['meta'];
      const meta: Record<string, Object> = (metaObj === undefined || metaObj === null ?
        {} : metaObj) as Record<string, Object>;
      const out: AiCacheEnvelope = new AiCacheEnvelope();
      out.promptVersion = typeof meta['promptVersion'] === 'number' ? meta['promptVersion'] as number : 0;
      out.fetchedAt = typeof meta['fetchedAt'] === 'number' ? meta['fetchedAt'] as number : 0;
      out.model = typeof meta['model'] === 'string' ? meta['model'] as string : '';
      out.dataJson = typeof obj['data'] === 'string' ? obj['data'] as string : '';
      if (out.promptVersion === 0 || out.fetchedAt === 0 || out.dataJson.length === 0) {
        return null;
      }
      return out;
    } catch (error) {
      if (file !== undefined) {
        try {
          fileIo.closeSync(file);
        } catch (closeErr) {
          Logger.warn(TAG, `cache read close failed, code=${(closeErr as BusinessError)?.code}`);
        }
      }
      const err: BusinessError = error as BusinessError;
      Logger.warn(TAG, `cache parse failed, code=${err?.code}, msg=${err?.message}`);
      return null;
    }
  }

  private static context(): Context | undefined {
    const uiContext: UIContext | undefined = AppStorage.get<UIContext>(StorageKey.UI_CONTEXT);
    return uiContext === undefined ? undefined : uiContext.getHostContext();
  }
}
