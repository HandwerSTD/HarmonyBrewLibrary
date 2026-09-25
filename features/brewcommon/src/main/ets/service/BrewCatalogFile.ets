/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
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

import { fileIo } from '@kit.CoreFileKit';
import type { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger, StorageKey } from '@ohos/common';
import { BrewSourcePrefs } from './BrewSourcePrefs';
import { BrewSourceStore } from './BrewSourceStore';

const TAG: string = '[BrewCatalogFile]';

/** 每源独立 Preferences 里的偏移表键；不改动现有六条缓存键。 */
const CATALOG_OFFSETS_KEY: string = 'brew_catalog_offsets';

/**
 * Harmonybrew 归一化文档目录文件。
 *
 * 文件格式固定为 `token\t<doc JSON>\n`，偏移表记录每行在 UTF-8 文件中的字节区间。
 * Preferences 只保存约 50KB 偏移表；约 3.4MB 文档正文留在 filesDir，避免大对象频繁 flush。
 */
export class BrewCatalogFile {
  /**
   * 全量写目录并保存偏移表。成功返回偏移表；目录或 Preferences 不可用时返回 null。
   * 调用方必须在调用前执行世代号守卫，本类不自行决定缓存是否仍有效。
   */
  public static write(sourceId: string, catalogJson: string): Record<string, number[]> | null {
    const ctx: Context | undefined = BrewCatalogFile.context();
    if (ctx === undefined) {
      Logger.error(TAG, `write deferred, uicontext is undefined, id=${sourceId}`);
      return null;
    }
    let catalog: Record<string, Object> = {};
    try {
      catalog = JSON.parse(catalogJson) as Record<string, Object>;
    } catch (error) {
      const err = error as BusinessError;
      Logger.error(TAG, `catalog JSON.parse failed, id=${sourceId}, code=${err?.code}, msg=${err?.message}`);
      return null;
    }
    const path: string = BrewCatalogFile.pathOf(ctx.filesDir, sourceId);
    const temporaryPath: string = path + '.tmp';
    const directory: string = path.substring(0, path.length - '/catalog.tsv'.length);
    let file: fileIo.File | undefined = undefined;
    const offsets: Record<string, number[]> = {};
    const encoder: util.TextEncoder = util.TextEncoder.create('utf-8');
    let position: number = 0;
    let step: string = 'mkdir';
    try {
      // ⚠ `mkdirSync(dir, true)` 在**目录已存在时仍会抛 `13900015 File exists`** ——
      // SDK 的 throws 列表里明确列了这条，`recursion=true` 在本平台不保证幂等。
      // 这正是「首次写入成功、之后每次重写都失败」的成因：首次目录不存在 → 成功；
      // 之后目录已存在 → mkdir 抛错 → 整段失败（又因设计上「目录未落盘就不更新 ETag」，
      // 于是每次启动都重新下载 3.9MB 再失败一遍）。
      try {
        fileIo.mkdirSync(directory, true);
      } catch (mkdirError) {
        const mkdirErr = mkdirError as BusinessError;
        // 目录已存在是重写路径的**预期情况**，只有其它错误才失败。
        // 注意不能 `throw mkdirErr` 上抛：ArkTS 禁止 throw 任意类型
        // （`arkts-limited-throw`，只能抛 Error），所以这里就地记录并返回。
        if (mkdirErr?.code !== 13900015) {
          Logger.error(TAG, `file write failed at=mkdir, id=${sourceId}, ` +
            `code=${mkdirErr?.code}, msg=${mkdirErr?.message}`);
          return null;
        }
      }
      step = 'unlink-temp';
      if (fileIo.accessSync(temporaryPath)) {
        fileIo.unlinkSync(temporaryPath);
      }
      step = 'open';
      file = fileIo.openSync(temporaryPath, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE |
        fileIo.OpenMode.TRUNC);
      step = 'write';
      const tokens: string[] = Object.keys(catalog);
      tokens.forEach((token: string) => {
        const line: string = token + '\t' + JSON.stringify(catalog[token]) + '\n';
        const start: number = position;
        const expected: number = encoder.encodeInto(line).byteLength;
        const written: number = fileIo.writeSync(file?.fd ?? -1, line);
        if (written !== expected) {
          throw new Error(`short catalog write token=${token} written=${written} expected=${expected}`);
        }
        position += written;
        const end: number = position;
        offsets[token] = [start, end];
      });
      step = 'close';
      fileIo.closeSync(file);
      file = undefined;
    } catch (error) {
      if (file !== undefined) {
        fileIo.closeSync(file);
      }
      const err = error as BusinessError;
      // **必须带上 `at=${step}`**：整段共用一个 catch 会把 mkdir / unlink / open / write / close
      // 的失败压成同一句 `file write failed`，排查时只能靠猜 —— 本文件就因此误诊过一次
      // （把 `File exists` 归给了 `renameSync`，实际是 `mkdirSync`）。
      Logger.error(TAG, `file write failed at=${step}, id=${sourceId}, code=${err?.code}, msg=${err?.message}`);
      return null;
    }
    BrewSourcePrefs.set<Record<string, number[]>>(CATALOG_OFFSETS_KEY, offsets);
    if (BrewSourcePrefs.get<Record<string, number[]>>(CATALOG_OFFSETS_KEY) === null) {
      Logger.error(TAG, `offsets persist failed, id=${sourceId}`);
      return null;
    }
    BrewSourcePrefs.persistNow(sourceId);
    try {
      // 先持久化新偏移表，再替换正文。has() 以正文为准，临时文件尚存时判目录不完整，
      // 所以进程若在两步之间被杀，下次会强制全量重下；偏移表缺失时则可从完整正文重建。
      //
      // ⚠ **HarmonyOS 的 `fileIo.renameSync` 不会覆盖已存在的目标** —— 目标存在时抛
      // `13900015 File exists`（SDK 的 throws 列表里明确列了这一条），与 POSIX `rename(2)`
      // 的原子覆盖语义不同。所以重写路径必须**先删旧正文再改名**，否则表现为
      // 「首次写入成功、之后每次重写都失败」：上游目录一变就永远落不下去；又因为按设计
      // 「目录未落盘就不更新 ETag」，于是每次启动都重新下载 3.9MB 再失败一遍。
      // 安全性：偏移表已在上面持久化；正文在 `.tmp` + rename 过程中被视为不完整，
      // 进程若在删除与改名之间被杀，`has()` 判不完整，下次强制全量重下。偏移表本身是
      // 正文的派生索引，即使 Preferences 中的副本丢失，也可从正文重建。
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
      fileIo.renameSync(temporaryPath, path);
    } catch (error) {
      const err = error as BusinessError;
      Logger.error(TAG, `catalog rename failed, id=${sourceId}, code=${err?.code}, msg=${err?.message}`);
      return null;
    }
    Logger.info(TAG, `catalog written, id=${sourceId} pairs=${Object.keys(offsets).length} bytes=${position}`);
    return offsets;
  }

  /**
   * 按偏移读取 token 对应的归一化 doc JSON；目录、偏移或字节范围缺失时返回 null。
   *
   * 清空 Preferences 后 filesDir 正文仍可能保留，且发现页常在首次 meta 同步前先读详情：
   * 那时旧偏移表查不到 token 会返回 503，发现页就会把空 desc 缓存到本次会话。偏移表是
   * 正文的派生索引，因此缺表或缺 token 时只从正文重建一次，再继续按字节范围读取。
   */
  public static readRange(sourceId: string, token: string): string | null {
    const ctx: Context | undefined = BrewCatalogFile.context();
    if (ctx === undefined) {
      return null;
    }
    let offsets: Record<string, number[]> | null =
      BrewSourcePrefs.get<Record<string, number[]>>(CATALOG_OFFSETS_KEY);
    let range: number[] | undefined = offsets?.[token];
    if (range === undefined || range.length !== 2 || range[0] < 0 || range[1] <= range[0]) {
      const path: string = BrewCatalogFile.pathOf(ctx.filesDir, sourceId);
      offsets = BrewCatalogFile.rebuildOffsets(sourceId, path);
      if (offsets === null) {
        return null;
      }
      range = offsets[token];
      if (range === undefined || range.length !== 2 || range[0] < 0 || range[1] <= range[0]) {
        return null;
      }
    }
    const path: string = BrewCatalogFile.pathOf(ctx.filesDir, sourceId);
    let file: fileIo.File | undefined = undefined;
    try {
      file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      const buffer: ArrayBuffer = new ArrayBuffer(range[1] - range[0]);
      const read: number = fileIo.readSync(file.fd, buffer, { offset: range[0], length: buffer.byteLength });
      fileIo.closeSync(file);
      file = undefined;
      if (read !== buffer.byteLength) {
        Logger.warn(TAG, `short catalog read, id=${sourceId} token=${token} read=${read} expected=${buffer.byteLength}`);
        return null;
      }
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      const line: string = decoder.decodeToString(new Uint8Array(buffer), { stream: false });
      const separator: number = line.indexOf('\t');
      if (separator < 0) {
        return null;
      }
      const end: number = line.endsWith('\n') ? line.length - 1 : line.length;
      return line.substring(separator + 1, end);
    } catch (error) {
      if (file !== undefined) {
        fileIo.closeSync(file);
      }
      const err = error as BusinessError;
      Logger.error(TAG, `file read failed, id=${sourceId} token=${token}, code=${err?.code}, msg=${err?.message}`);
      return null;
    }
  }

  /** 删除该源的目录文件、源目录和偏移表。 */
  public static delete(sourceId: string): void {
    const ctx: Context | undefined = BrewCatalogFile.context();
    if (ctx !== undefined) {
      const path: string = BrewCatalogFile.pathOf(ctx.filesDir, sourceId);
      const directory: string = path.substring(0, path.length - '/catalog.tsv'.length);
      try {
        if (fileIo.accessSync(path)) {
          fileIo.unlinkSync(path);
        }
        if (fileIo.accessSync(directory)) {
          fileIo.rmdirSync(directory);
        }
      } catch (error) {
        const err = error as BusinessError;
        Logger.error(TAG, `file delete failed, id=${sourceId}, code=${err?.code}, msg=${err?.message}`);
      }
    }
    const store: preferences.Preferences | null = BrewSourcePrefs.openFor(sourceId);
    if (store !== null) {
      try {
        store.deleteSync(CATALOG_OFFSETS_KEY);
      } catch (error) {
        const err = error as BusinessError;
        Logger.error(TAG, `offsets delete failed, id=${sourceId}, code=${err?.code}, msg=${err?.message}`);
      }
    }
    if (sourceId !== BrewSourceStore.sessionActive().id) {
      BrewSourcePrefs.releaseFor(sourceId);
    }
    BrewSourcePrefs.persistNow(sourceId);
  }

  /**
   * 正文存在即可服务；临时文件残留仍视为不可用。
   *
   * 清空缓存后首次冷启时 Preferences 里的偏移表可能已经没了，但 filesDir 正文仍在；
   * 此时发现页早于 meta 同步加载，fetchDoc 不应因此 503。偏移表是从自描述 TSV 正文
   * 派生的索引，不是正文的并列必需条件；readRange 会在缺表时从正文重建一次。正文由
   * `.tmp` + rename 原子写出，所以有正文就足以保证内容完整，要么完整要么不存在。
   */
  public static has(sourceId: string): boolean {
    const ctx: Context | undefined = BrewCatalogFile.context();
    if (ctx === undefined) {
      return false;
    }
    const path: string = BrewCatalogFile.pathOf(ctx.filesDir, sourceId);
    try {
      if (!fileIo.accessSync(path) || fileIo.accessSync(path + '.tmp')) {
        return false;
      }
    } catch (error) {
      return false;
    }
    return true;
  }

  /** 偏移表是正文派生索引；完整正文缺表时按 UTF-8 字节行边界重建并持久化一次。 */
  private static rebuildOffsets(sourceId: string, path: string): Record<string, number[]> | null {
    const startedAt: number = Date.now();
    let file: fileIo.File | undefined = undefined;
    try {
      file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      const size: number = fileIo.statSync(file.fd).size;
      const buffer: ArrayBuffer = new ArrayBuffer(size);
      const read: number = fileIo.readSync(file.fd, buffer, { offset: 0, length: size });
      fileIo.closeSync(file);
      file = undefined;
      if (read !== size) {
        Logger.warn(TAG, `short catalog read while rebuilding offsets, id=${sourceId} ` +
          `read=${read} expected=${size}`);
        return null;
      }
      const bytes: Uint8Array = new Uint8Array(buffer);
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      const offsets: Record<string, number[]> = {};
      let lineStart: number = 0;
      let lines: number = 0;
      for (let i: number = 0; i < bytes.length; i++) {
        if (bytes[i] === 0x0A) {
          const tab: number = BrewCatalogFile.findTab(bytes, lineStart, i);
          if (tab > lineStart) {
            const keyBytes: Uint8Array = bytes.slice(lineStart, tab);
            const token: string = decoder.decodeToString(keyBytes, { stream: false });
            offsets[token] = [lineStart, i + 1];
            lines++;
          }
          lineStart = i + 1;
        }
      }
      BrewSourcePrefs.set<Record<string, number[]>>(CATALOG_OFFSETS_KEY, offsets);
      if (BrewSourcePrefs.get<Record<string, number[]>>(CATALOG_OFFSETS_KEY) === null) {
        Logger.error(TAG, `offsets rebuild persist failed, id=${sourceId}`);
        return null;
      }
      BrewSourcePrefs.persistNow(sourceId);
      Logger.info(TAG, `offsets rebuilt, id=${sourceId} lines=${lines} ms=${Date.now() - startedAt}`);
      return offsets;
    } catch (error) {
      if (file !== undefined) {
        fileIo.closeSync(file);
      }
      const err = error as BusinessError;
      Logger.error(TAG, `offsets rebuild failed, id=${sourceId}, code=${err?.code}, msg=${err?.message}`);
      return null;
    }
  }

  private static findTab(bytes: Uint8Array, start: number, end: number): number {
    for (let i: number = start; i < end; i++) {
      if (bytes[i] === 0x09) {
        return i;
      }
    }
    return -1;
  }

  private static pathOf(filesDir: string, sourceId: string): string {
    return filesDir + '/brew_src/' + sourceId + '/catalog.tsv';
  }

  private static context(): Context | undefined {
    const uiContext: UIContext | undefined = AppStorage.get<UIContext>(StorageKey.UI_CONTEXT);
    return uiContext === undefined ? undefined : uiContext.getHostContext();
  }
}
