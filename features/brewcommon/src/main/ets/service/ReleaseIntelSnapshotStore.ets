/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger, StorageKey } from '@ohos/common';
import {
  RELEASE_INTEL_SNAPSHOT_CAP,
  RELEASE_INTEL_SNAPSHOT_SEGMENT,
} from '../constant/ReleaseIntelConstants';

const TAG: string = '[release-intel]';

/** 快照缓存条目的盘上形态：{ts, pv, dataJson}（pv=AI promptVersion,换提示词即失效）。 */
class SnapshotEnvelope {
  public ts: number = 0;
  public pv: number = 0;
  public dataJson: string = '';
}

/** 读快照缓存的结构化返回：正文 + 落盘时刻（TTL 由调用方判，这里不藏判断）。 */
export class SnapshotCacheRead {
  public dataJson: string = '';
  public ts: number = 0;
}

/** LRU 淘汰用的内部结构（ArkTS 禁匿名对象字面量）。 */
class SnapshotStamp {
  public path: string = '';
  public ts: number = 0;
}

/**
 * 整卡快照缓存（v1.3.4,spec §14）：assemble 产物按 (token, toVersion) 落盘。
 *
 * 与 AI 缓存（AiCache）的分工：AI 缓存只存 AI 摘要卡且带 promptVersion 语义；
 * 这里存的是**整张快照**（verdict/diff/notesFull/notesPreview/card/缺口码）,
 * 命中时 assemble 直接返回,连 atom 网络步都省掉。同 token+to **覆盖写**（release
 * 说明可被作者编辑,重装配覆盖旧值;时间戳随写随新）。F1(net) 瞬态失败不进缓存
 * （调用方判 gapCode）；基线库是「已装版本」一份的幂等快照,这里是「目标版本」
 * 可多份的覆盖缓存——两个库不可混用。
 *
 * 布局：`filesDir/<RELEASE_INTEL_SNAPSHOT_SEGMENT>/<token>/<toVersion>.json`；
 * 在 `brew_live/ai` 之下,随 `BrewCacheAdmin.clear` 一并清空（换源=口径失效）。
 */
export class ReleaseIntelSnapshotStore {
  /** 覆盖写一条快照缓存（写失败只记日志——缓存缺席=下次 miss,不影响正确性）。 */
  public static save(token: string, toVersion: string, dataJson: string, promptVersion: number): void {
    if (token.length === 0 || toVersion.length === 0 || dataJson.length === 0 || promptVersion <= 0) {
      return;
    }
    const dir: string = ReleaseIntelSnapshotStore.tokenDir(token);
    const path: string = ReleaseIntelSnapshotStore.pathOf(token, toVersion);
    if (path.length === 0) {
      return;
    }
    const envelope: SnapshotEnvelope = new SnapshotEnvelope();
    envelope.ts = Date.now();
    envelope.pv = promptVersion;
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
      // 覆盖写：rename 不覆盖已存在目标,先 unlink 旧文件（与 AiCache.write 同款）
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
      fileIo.renameSync(tempPath, path);
      ReleaseIntelSnapshotStore.prune(path);
    } catch (error) {
      if (file !== undefined) {
        try {
          fileIo.closeSync(file);
        } catch (closeErr) {
          Logger.warn(TAG, `snapshot cache close failed, code=${(closeErr as BusinessError)?.code}`);
        }
      }
      const err: BusinessError = error as BusinessError;
      Logger.warn(TAG, `snapshot cache save failed, token=${token}, code=${err?.code}, msg=${err?.message}`);
    }
  }

  /**
   * 读快照缓存（**不判 TTL**——过期判断留给调用方, stale 时返回 null 由装配层重算,
   * 旧文件留待下次 save 覆盖）。promptVersion 不符 → null（提示词升级,旧卡视为无效,
   * 与 AiCache 同语义）。无/损坏 → null。
   */
  public static read(token: string, toVersion: string, promptVersion: number): SnapshotCacheRead | null {
    const path: string = ReleaseIntelSnapshotStore.pathOf(token, toVersion);
    if (path.length === 0 || promptVersion <= 0) {
      return null;
    }
    let file: fileIo.File | undefined = undefined;
    try {
      if (!fileIo.accessSync(path)) {
        return null;
      }
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
      const rec: Record<string, Object> = parsed as Record<string, Object>;
      const out: SnapshotCacheRead = new SnapshotCacheRead();
      const ts: Object | undefined = rec['ts'];
      out.ts = typeof ts === 'number' ? ts as number : 0;
      const data: Object | undefined = rec['dataJson'];
      out.dataJson = typeof data === 'string' ? data as string : '';
      if (out.ts === 0 || out.dataJson.length === 0) {
        return null;
      }
      const pv: Object | undefined = rec['pv'];
      const envelopeVersion: number = typeof pv === 'number' ? pv as number : 0;
      if (envelopeVersion !== promptVersion) {
        // 提示词升级后的旧卡不返回（文件留给下次 save 覆盖,或被 LRU 淘汰）
        return null;
      }
      return out;
    } catch (error) {
      if (file !== undefined) {
        try {
          fileIo.closeSync(file);
        } catch (closeErr) {
          Logger.warn(TAG, `snapshot cache read close failed, code=${(closeErr as BusinessError)?.code}`);
        }
      }
      return null;
    }
  }

  // ------------------------------------------------------------ 内部

  /** LRU 淘汰：快照文件总数超 cap 时删 ts 最旧的文件（刚写入的不删）。 */
  private static prune(keepPath: string): void {
    const root: string = ReleaseIntelSnapshotStore.rootDir();
    if (root.length === 0) {
      return;
    }
    let tokenDirs: string[] = [];
    try {
      tokenDirs = fileIo.listFileSync(root);
    } catch (error) {
      return;
    }
    const stamps: SnapshotStamp[] = [];
    tokenDirs.forEach((name: string) => {
      const tokenDir: string = root + '/' + name;
      try {
        const files: string[] = fileIo.listFileSync(tokenDir);
        for (let i: number = 0; i < files.length; i++) {
          const one: string = files[i];
          if (!one.endsWith('.json')) {
            continue;
          }
          const filePath: string = tokenDir + '/' + one;
          const stamp: SnapshotStamp = new SnapshotStamp();
          stamp.path = filePath;
          stamp.ts = ReleaseIntelSnapshotStore.readTs(filePath);
          stamps.push(stamp);
        }
      } catch (error) {
        // 目录读不出来就不管它
      }
    });
    if (stamps.length <= RELEASE_INTEL_SNAPSHOT_CAP) {
      return;
    }
    stamps.sort((a: SnapshotStamp, b: SnapshotStamp): number => a.ts - b.ts);
    let excess: number = stamps.length - RELEASE_INTEL_SNAPSHOT_CAP;
    for (let i: number = 0; i < stamps.length && excess > 0; i++) {
      if (stamps[i].path === keepPath) {
        continue;
      }
      try {
        fileIo.unlinkSync(stamps[i].path);
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
      const parsed: Object = JSON.parse(head) as Object;
      const rec: Record<string, Object> = parsed as Record<string, Object>;
      const ts: Object | undefined = rec['ts'];
      return typeof ts === 'number' ? ts as number : 0;
    } catch (error) {
      return 0;
    }
  }

  private static rootDir(): string {
    const ctx: Context | undefined = ReleaseIntelSnapshotStore.context();
    return ctx === undefined ? '' : ctx.filesDir + '/' + RELEASE_INTEL_SNAPSHOT_SEGMENT;
  }

  private static tokenDir(token: string): string {
    const root: string = ReleaseIntelSnapshotStore.rootDir();
    return root.length === 0 ? '' : root + '/' + ReleaseIntelSnapshotStore.sanitize(token);
  }

  private static pathOf(token: string, toVersion: string): string {
    const dir: string = ReleaseIntelSnapshotStore.tokenDir(token);
    if (dir.length === 0) {
      return '';
    }
    return dir + '/' + ReleaseIntelSnapshotStore.sanitize(toVersion) + '.json';
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
