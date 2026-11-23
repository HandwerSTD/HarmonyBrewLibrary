/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger, StorageKey } from '@ohos/common';
import { objKeys } from '../util/objkeys';
import {
  RELEASE_INTEL_PAUSE_FOREVER_MS,
  RELEASE_INTEL_PREFS_KEY_IGNORED,
  RELEASE_INTEL_PREFS_KEY_PAUSED,
  RELEASE_INTEL_PREFS_STORE,
} from '../constant/ReleaseIntelConstants';

const TAG: string = '[release-intel]';

/**
 * 更新提醒策略的落盘（spec §3.2 / G6）。
 *
 * GSKV store `brew_release_intel`（与哨兵的 `brew_sentinel` 同模式、但物理分开——
 * 哨兵 store 由扩展进程读写，本 store 只在宿主进程出现，不进 CommonEnums.StorageKey
 * 的理由与 SentinelConstants 一致：AppStorage 键与跨进程 preferences 键物理分开）。
 *
 * - `ignored: {token: version}` —— 忽略「这一版」；出现**更新的版本**时不再抑制
 *   （按精确版本匹配，spec G6）；
 * - `paused: {token: untilTs}` —— 暂停提醒，0 = 无限期；恢复 = 删键；
 * - **pin 不落盘**：固定版本是设备上 brew 的状态（`brew pin`），本应用只生成命令，
 *   不代管状态（spec G6：策略影响 H 的通知计数，pin 只生成命令）。
 *
 * 写入后必须 `persistNow()`（GSKV `putSync` 只进内存缓存页——BrewService.flush 的同款硬规）。
 * ArkTS 无 delete：清键一律「重建整表再写回」。
 */
export class ReleaseIntelPrefs {
  private static store: preferences.Preferences | undefined = undefined;

  /** token 被忽略的版本（空串 = 没有忽略）。 */
  public static ignoredVersion(token: string): string {
    const map: Record<string, string> = ReleaseIntelPrefs.readStrMap(RELEASE_INTEL_PREFS_KEY_IGNORED);
    const value: string | undefined = map[token];
    return value === undefined ? '' : value;
  }

  /** 暂停截止时间（0 = 无限期；-1 = 未暂停）。 */
  public static pauseUntil(token: string): number {
    const map: Record<string, number> = ReleaseIntelPrefs.readNumMap(RELEASE_INTEL_PREFS_KEY_PAUSED);
    const value: number | undefined = map[token];
    return value === undefined ? -1 : value;
  }

  /**
   * 「这个 (token, offeredVersion) 是否应从哨兵的通知里压掉」。
   * 版本按**精确匹配**：忽略 8.5 不影响 8.6 的提醒（spec G2 的零误报精神同样适用）。
   */
  public static isSuppressed(token: string, offeredVersion: string): boolean {
    if (ReleaseIntelPrefs.ignoredVersion(token) === offeredVersion) {
      return true;
    }
    const until: number = ReleaseIntelPrefs.pauseUntil(token);
    if (until === RELEASE_INTEL_PAUSE_FOREVER_MS) {
      return true;
    }
    return until > 0 && Date.now() < until;
  }

  public static setIgnored(token: string, version: string): void {
    const map: Record<string, string> = ReleaseIntelPrefs.readStrMap(RELEASE_INTEL_PREFS_KEY_IGNORED);
    map[token] = version;
    ReleaseIntelPrefs.putJson(RELEASE_INTEL_PREFS_KEY_IGNORED, JSON.stringify(map),
      `ignore set token=${token} version=${version}`);
  }

  public static clearIgnored(token: string): void {
    const map: Record<string, string> = ReleaseIntelPrefs.readStrMap(RELEASE_INTEL_PREFS_KEY_IGNORED);
    if (map[token] === undefined) {
      return;
    }
    ReleaseIntelPrefs.putJson(RELEASE_INTEL_PREFS_KEY_IGNORED,
      JSON.stringify(ReleaseIntelPrefs.omitStr(map, token)), `ignore cleared token=${token}`);
  }

  /** 暂停。untilTs=0 表示无限期。 */
  public static setPaused(token: string, untilTs: number): void {
    const map: Record<string, number> = ReleaseIntelPrefs.readNumMap(RELEASE_INTEL_PREFS_KEY_PAUSED);
    map[token] = untilTs;
    ReleaseIntelPrefs.putJson(RELEASE_INTEL_PREFS_KEY_PAUSED, JSON.stringify(map),
      `pause set token=${token} until=${untilTs}`);
  }

  public static clearPaused(token: string): void {
    const map: Record<string, number> = ReleaseIntelPrefs.readNumMap(RELEASE_INTEL_PREFS_KEY_PAUSED);
    if (map[token] === undefined) {
      return;
    }
    ReleaseIntelPrefs.putJson(RELEASE_INTEL_PREFS_KEY_PAUSED,
      JSON.stringify(ReleaseIntelPrefs.omitNum(map, token)), `pause cleared token=${token}`);
  }

  // ------------------------------------------------------------ 内部

  /** 重建 string 表跳过 target（ArkTS 无 delete）。 */
  private static omitStr(map: Record<string, string>, target: string): Record<string, string> {
    const out: Record<string, string> = {};
    objKeys(map).forEach((key: string) => {
      if (key !== target) {
        out[key] = map[key];
      }
    });
    return out;
  }

  /** 重建 number 表跳过 target。 */
  private static omitNum(map: Record<string, number>, target: string): Record<string, number> {
    const out: Record<string, number> = {};
    objKeys(map).forEach((key: string) => {
      if (key !== target) {
        out[key] = map[key];
      }
    });
    return out;
  }

  private static readStrMap(key: string): Record<string, string> {
    const raw: string = ReleaseIntelPrefs.rawJson(key);
    if (raw.length === 0) {
      return {};
    }
    try {
      const parsed: Object = JSON.parse(raw) as Object;
      if (parsed === null || parsed === undefined || Array.isArray(parsed)) {
        return {};
      }
      return parsed as Record<string, string>;
    } catch (err) {
      Logger.warn(TAG, `prefs parse failed key=${key}`);
      return {};
    }
  }

  private static readNumMap(key: string): Record<string, number> {
    const raw: string = ReleaseIntelPrefs.rawJson(key);
    if (raw.length === 0) {
      return {};
    }
    try {
      const parsed: Object = JSON.parse(raw) as Object;
      if (parsed === null || parsed === undefined || Array.isArray(parsed)) {
        return {};
      }
      return parsed as Record<string, number>;
    } catch (err) {
      Logger.warn(TAG, `prefs parse failed key=${key}`);
      return {};
    }
  }

  private static rawJson(key: string): string {
    const store: preferences.Preferences | null = ReleaseIntelPrefs.open();
    if (store === null) {
      return '';
    }
    try {
      const raw: string = store.getSync(key, '') as string;
      return raw ?? '';
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.warn(TAG, `prefs read failed key=${key}, code=${e.code}`);
      return '';
    }
  }

  private static putJson(key: string, jsonText: string, detail: string): void {
    const store: preferences.Preferences | null = ReleaseIntelPrefs.open();
    if (store === null) {
      return;
    }
    try {
      store.putSync(key, jsonText);
      // GSKV 的 putSync 只进内存页：不显式刷盘，进程被回收就丢（BrewService 硬规 ①）
      ReleaseIntelPrefs.persistNow();
      Logger.info(TAG, `prefs saved key=${key} ${detail}`);
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.error(TAG, `prefs write failed key=${key}, code=${e.code}`);
    }
  }

  /** 显式落盘。失败不抛（下次写入还会再试）。 */
  public static persistNow(): void {
    if (ReleaseIntelPrefs.store !== undefined) {
      try {
        ReleaseIntelPrefs.store.flush();
      } catch (err) {
        const e: BusinessError = err as BusinessError;
        Logger.warn(TAG, `prefs flush failed, code=${e.code}`);
      }
    }
  }

  private static open(): preferences.Preferences | null {
    if (ReleaseIntelPrefs.store !== undefined) {
      return ReleaseIntelPrefs.store;
    }
    const uiContext: UIContext | undefined = AppStorage.get<UIContext>(StorageKey.UI_CONTEXT);
    if (uiContext === undefined) {
      return null;
    }
    const ctx: Context | undefined = uiContext.getHostContext();
    if (ctx === undefined) {
      return null;
    }
    try {
      const options: preferences.Options =
        { name: RELEASE_INTEL_PREFS_STORE, storageType: preferences.StorageType.GSKV };
      ReleaseIntelPrefs.store = preferences.getPreferencesSync(ctx, options);
      return ReleaseIntelPrefs.store;
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.error(TAG, `prefs store open failed, code=${e.code}, msg=${e.message}`);
      return null;
    }
  }
}
