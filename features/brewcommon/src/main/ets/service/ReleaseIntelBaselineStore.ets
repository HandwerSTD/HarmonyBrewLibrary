/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger, StorageKey } from '@ohos/common';
import {
  RELEASE_INTEL_BASELINE_CAP,
  RELEASE_INTEL_BASELINE_SEGMENT,
} from '../constant/ReleaseIntelConstants';

const TAG: string = '[release-intel]';

/** 基线条目的盘上形态：{ts, dataJson}。 */
class BaselineEnvelope {
  public ts: number = 0;
  public dataJson: string = '';
}

/**
 * diff 基线库（spec §3.1 / F5）。
 *
 * 背景：`BrewService` 的单条缓存是**覆盖式**的——详情页每次抓取都会用新 JSON 冲掉旧值。
 * 「已装版本的配方」只有在它还是最新版本的那一刻被看见，所以必须在两个时机顺手快照：
 *   1. 详情页取数**前**（VM.load 预捕获）：store 缓存若还留着已装版本的 raw JSON，
 *      赶在它被新抓取覆盖之前拷进基线库；
 *   2. 详情页加载成功且「已装 = 最新」时：抓到的 raw 就是已装配方，存一份（幂等）。
 *
 * 布局：`filesDir/<RELEASE_INTEL_BASELINE_SEGMENT>/<token>/<version>.json`；
 * 每个 token 只保留一份（已装版本的那份），全局 LRU cap 40 条（~200KB 封顶）。
 * 在 `brew_live/ai` 之下：随 `BrewCacheAdmin.clear` 一并清空（换源=口径失效）。
 */
export class ReleaseIntelBaselineStore {
  /** 保存基线（幂等：同 token+version 已存在则只更新时间戳之外什么都不做）。 */
  public static save(token: string, version: string, dataJson: string): void {
    if (token.length === 0 || version.length === 0 || dataJson.length === 0) {
      return;
    }
    const dir: string = ReleaseIntelBaselineStore.tokenDir(token);
    const path: string = ReleaseIntelBaselineStore.pathOf(token, version);
    if (path.length === 0) {
      return;
    }
    try {
      if (fileIo.accessSync(path)) {
        return; // 幂等：同一版本已快照过
      }
    } catch (error) {
      // accessSync 抛错按不存在处理，继续尝试写
    }
    const envelope: BaselineEnvelope = new BaselineEnvelope();
    envelope.ts = Date.now();
    envelope.dataJson = dataJson;
    let file: fileIo.File | undefined = undefined;
    const tempPath: string = path + '.tmp';
    try {
      fileIo.mkdirSync(dir, true);
      if (fileIo.accessSync(tempPath)) {
        fileIo.unlinkSync(tempPath);
      }
      file = fileIo.openSync(tempPath, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE |
        fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, JSON.stringify(envelope));
      fileIo.closeSync(file);
      file = undefined;
      fileIo.renameSync(tempPath, path);
      Logger.info(TAG, `baseline saved token=${token} version=${version} bytes=${dataJson.length}`);
      ReleaseIntelBaselineStore.prune(token);
    } catch (error) {
      if (file !== undefined) {
        try {
          fileIo.closeSync(file);
        } catch (closeErr) {
          Logger.warn(TAG, `baseline close failed, code=${(closeErr as BusinessError)?.code}`);
        }
      }
      const err: BusinessError = error as BusinessError;
      Logger.warn(TAG, `baseline save failed, token=${token}, code=${err?.code}, msg=${err?.message}`);
    }
  }

  /** 读基线 raw JSON（无 → 空串，调用方落 F5「未保留旧版本对照数据」）。 */
  public static read(token: string, version: string): string {
    const path: string = ReleaseIntelBaselineStore.pathOf(token, version);
    if (path.length === 0) {
      return '';
    }
    let file: fileIo.File | undefined = undefined;
    try {
      if (!fileIo.accessSync(path)) {
        return '';
      }
      file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      const size: number = fileIo.statSync(file.fd).size;
      const buffer: ArrayBuffer = new ArrayBuffer(size);
      const read: number = fileIo.readSync(file.fd, buffer, { offset: 0, length: size });
      fileIo.closeSync(file);
      file = undefined;
      if (read !== size) {
        return '';
      }
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      const text: string = decoder.decodeToString(new Uint8Array(buffer), { stream: false });
      const parsed: Object = JSON.parse(text) as Object;
      const rec: Record<string, Object> = parsed as Record<string, Object>;
      const data: Object | undefined = rec['dataJson'];
      return typeof data === 'string' ? data as string : '';
    } catch (error) {
      if (file !== undefined) {
        try {
          fileIo.closeSync(file);
        } catch (closeErr) {
          Logger.warn(TAG, `baseline read close failed, code=${(closeErr as BusinessError)?.code}`);
        }
      }
      const err: BusinessError = error as BusinessError;
      Logger.warn(TAG, `baseline read failed, token=${token}, code=${err?.code}`);
      return '';
    }
  }

  // ------------------------------------------------------------ 内部

  /** LRU 淘汰：token 目录数超 cap 时删最旧的（ts 最小的 envelope）。 */
  private static prune(keepToken: string): void {
    const root: string = ReleaseIntelBaselineStore.rootDir();
    if (root.length === 0) {
      return;
    }
    let names: string[] = [];
    try {
      names = fileIo.listFileSync(root);
    } catch (error) {
      return;
    }
    if (names.length <= RELEASE_INTEL_BASELINE_CAP) {
      return;
    }
    // 收集 (token, ts) 后按 ts 升序删，直到数量回到 cap 内
    const stamps: BaselineStamp[] = [];
    names.forEach((name: string) => {
      const tokenDir: string = root + '/' + name;
      try {
        const files: string[] = fileIo.listFileSync(tokenDir);
        for (let i: number = 0; i < files.length; i++) {
          const one: string = files[i];
          if (!one.endsWith('.json')) {
            continue;
          }
          const ts: number = ReleaseIntelBaselineStore.readTs(tokenDir + '/' + one);
          const stamp: BaselineStamp = new BaselineStamp();
          stamp.dir = tokenDir;
          stamp.ts = ts;
          stamps.push(stamp);
          break; // 每个 token 只有一份
        }
      } catch (error) {
        // 目录读不出来就不管它
      }
    });
    stamps.sort((a: BaselineStamp, b: BaselineStamp): number => a.ts - b.ts);
    let excess: number = stamps.length - RELEASE_INTEL_BASELINE_CAP;
    for (let i: number = 0; i < stamps.length && excess > 0; i++) {
      if (stamps[i].dir.endsWith('/' + keepToken)) {
        continue; // 刚保存的不删
      }
      try {
        fileIo.rmdirSync(stamps[i].dir);
        excess--;
      } catch (error) {
        break;
      }
    }
  }

  private static readTs(path: string): number {
    try {
      if (!fileIo.accessSync(path)) {
        return 0;
      }
      const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      const size: number = fileIo.statSync(file.fd).size;
      const buffer: ArrayBuffer = new ArrayBuffer(Math.min(size, 256));
      const read: number = fileIo.readSync(file.fd, buffer, { offset: 0, length: buffer.byteLength });
      fileIo.closeSync(file);
      if (read <= 0) {
        return 0;
      }
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      const head: string = decoder.decodeToString(new Uint8Array(buffer), { stream: false });
      const parsed: Object = JSON.parse(head + (head.trimEnd().endsWith('}') ? '' : '')) as Object;
      const rec: Record<string, Object> = parsed as Record<string, Object>;
      const ts: Object | undefined = rec['ts'];
      return typeof ts === 'number' ? ts as number : 0;
    } catch (error) {
      return 0;
    }
  }

  private static rootDir(): string {
    const ctx: Context | undefined = ReleaseIntelBaselineStore.context();
    return ctx === undefined ? '' : ctx.filesDir + '/' + RELEASE_INTEL_BASELINE_SEGMENT;
  }

  private static tokenDir(token: string): string {
    const root: string = ReleaseIntelBaselineStore.rootDir();
    return root.length === 0 ? '' : root + '/' + ReleaseIntelBaselineStore.sanitize(token);
  }

  private static pathOf(token: string, version: string): string {
    const dir: string = ReleaseIntelBaselineStore.tokenDir(token);
    if (dir.length === 0) {
      return '';
    }
    return dir + '/' + ReleaseIntelBaselineStore.sanitize(version) + '.json';
  }

  /** 路径段归一（与 AiCache.sanitize 同口径）：非 [a-z0-9] 折 `-`，截 64，空 → empty。 */
  private static sanitize(segment: string): string {
    let out: string = '';
    for (let i: number = 0; i < segment.length; i++) {
      const ch: string = segment.charAt(i).toLowerCase();
      const isAlnum: boolean = (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9');
      out += isAlnum ? ch : '-';
    }
    return out.length === 0 ? 'empty' : out.substring(0, 64);
  }

  private static context(): Context | undefined {
    const uiContext: UIContext | undefined = AppStorage.get<UIContext>(StorageKey.UI_CONTEXT);
    return uiContext === undefined ? undefined : uiContext.getHostContext();
  }
}

/** LRU 淘汰用的内部结构（ArkTS 禁匿名对象字面量）。 */
class BaselineStamp {
  public dir: string = '';
  public ts: number = 0;
}
