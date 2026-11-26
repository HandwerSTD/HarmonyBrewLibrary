/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger, StorageKey } from '@ohos/common';
import { objKeys } from '../util/objkeys';

const TAG: string = '[update-follow]';

/**
 * GSKV store 名。与哨兵的 `brew_sentinel`、情报的 `brew_release_intel` 同模式、物理分开：
 * 本 store 只在宿主进程出现（关注切换只发生在「待更新」列表页与详情页），
 * 不入 CommonEnums.StorageKey 的理由与 SentinelConstants 一致 —— AppStorage 键与
 * 跨进程 preferences 键物理分开。
 */
const UPDATE_FOLLOW_PREFS_STORE: string = 'brew_update_follow';

/** 唯一的数据键：`{token: 关注时刻(epoch ms)}`。时刻只用于排查，判定一律按键存在与否 */
const UPDATE_FOLLOW_PREFS_KEY_FOLLOWED: string = 'followed_map';

/**
 * AppStorage 版本号键（F 线）：每次关注表写入 +1。
 *
 * 为什么要有它：关注表是普通 preferences，UI 组件观察不到它的变化；行内星标与
 * 「待更新」列表的置顶排序都依赖「关注表刚被写过」这个事实。写入方 bump 这个
 * 版本号，观察方（BrewLocalPackageRow / MinePackagesView）用 `@StorageProp` 挂上它，
 * 版本一变就重渲染/重排 —— 不需要为「关注变了」再发明一套回调协议。
 */
export const UPDATE_FOLLOW_VERSION_KEY: string = 'updateFollowVersion';

/**
 * 「关注更新」的落盘（F 线）。
 *
 * 关注是**按包名（token）**的布尔开关：关注后
 *   - 「待更新」列表里该包排最前面（优先提醒，MinePackagesUtil.prioritizeFollowed）；
 *   - 桌面更新卡片（2*4 / 4*4）只展示关注中的待更新包（BrewSentinelService 派生时过滤）。
 *
 * 跨进程说明：卡片数据在宿主进程派生（扩展进程只读镜像），所以本 store 只需要
 * 宿主进程可达 —— 与 ReleaseIntelPrefs 同款，走 AppStorage 的 UI_CONTEXT 打开。
 * 哨兵服务 import 本类不违反触达点审计（AppStorage 用法在本文件内，服务文件自身零 AppStorage）。
 *
 * 写入后必须 `persistNow()`（GSKV `putSync` 只进内存缓存页——ReleaseIntelPrefs 同款硬规）。
 * ArkTS 无 delete：取消关注一律「重建整表再写回」。
 */
export class UpdateFollowPrefs {
  private static store: preferences.Preferences | undefined = undefined;

  /** 该包是否处于关注中。 */
  public static isFollowed(token: string): boolean {
    const map: Record<string, number> = UpdateFollowPrefs.readMap();
    return map[token] !== undefined;
  }

  /** 当前关注中的包数。0 = 用户没有关注任何包（卡片的「关注空态」判据）。 */
  public static followedCount(): number {
    return objKeys(UpdateFollowPrefs.readMap()).length;
  }

  /** 关注。重复关注幂等：覆写时刻，不叠加条目。 */
  public static setFollowed(token: string): void {
    const map: Record<string, number> = UpdateFollowPrefs.readMap();
    map[token] = Date.now();
    UpdateFollowPrefs.putJson(JSON.stringify(map), `follow set token=${token}`);
    UpdateFollowPrefs.bumpVersion();
  }

  /** 取消关注。本来就没关注时不动存储（避免一次无意义的 flush）。 */
  public static clearFollowed(token: string): void {
    const map: Record<string, number> = UpdateFollowPrefs.readMap();
    if (map[token] === undefined) {
      return;
    }
    UpdateFollowPrefs.putJson(JSON.stringify(UpdateFollowPrefs.omit(map, token)),
      `follow cleared token=${token}`);
    UpdateFollowPrefs.bumpVersion();
  }

  /** 版本号 +1（见 UPDATE_FOLLOW_VERSION_KEY 的注释：观察方靠它感知关注表变化）。 */
  private static bumpVersion(): void {
    const current: number | undefined = AppStorage.get<number>(UPDATE_FOLLOW_VERSION_KEY);
    AppStorage.setOrCreate(UPDATE_FOLLOW_VERSION_KEY, (current === undefined ? 0 : current) + 1);
  }

  // ------------------------------------------------------------ 内部

  /** 重建 number 表跳过 target（ArkTS 无 delete）。 */
  private static omit(map: Record<string, number>, target: string): Record<string, number> {
    const out: Record<string, number> = {};
    objKeys(map).forEach((key: string) => {
      if (key !== target) {
        out[key] = map[key];
      }
    });
    return out;
  }

  private static readMap(): Record<string, number> {
    const raw: string = UpdateFollowPrefs.rawJson();
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
      Logger.warn(TAG, 'prefs parse failed');
      return {};
    }
  }

  private static rawJson(): string {
    const store: preferences.Preferences | null = UpdateFollowPrefs.open();
    if (store === null) {
      return '';
    }
    try {
      const raw: preferences.ValueType = store.getSync(UPDATE_FOLLOW_PREFS_KEY_FOLLOWED, '');
      return typeof raw === 'string' ? raw : '';
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.warn(TAG, `prefs read failed, code=${e.code}`);
      return '';
    }
  }

  private static putJson(jsonText: string, detail: string): void {
    const store: preferences.Preferences | null = UpdateFollowPrefs.open();
    if (store === null) {
      return;
    }
    try {
      store.putSync(UPDATE_FOLLOW_PREFS_KEY_FOLLOWED, jsonText);
      // GSKV 的 putSync 只进内存页：不显式刷盘，进程被回收就丢（ReleaseIntelPrefs 同款硬规）
      UpdateFollowPrefs.persistNow();
      Logger.info(TAG, `prefs saved ${detail}`);
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.error(TAG, `prefs write failed, code=${e.code}`);
    }
  }

  /** 显式落盘。失败不抛（下次写入还会再试）。 */
  public static persistNow(): void {
    if (UpdateFollowPrefs.store !== undefined) {
      try {
        UpdateFollowPrefs.store.flush();
      } catch (err) {
        const e: BusinessError = err as BusinessError;
        Logger.warn(TAG, `prefs flush failed, code=${e.code}`);
      }
    }
  }

  private static open(): preferences.Preferences | null {
    if (UpdateFollowPrefs.store !== undefined) {
      return UpdateFollowPrefs.store;
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
        { name: UPDATE_FOLLOW_PREFS_STORE, storageType: preferences.StorageType.GSKV };
      UpdateFollowPrefs.store = preferences.getPreferencesSync(ctx, options);
      return UpdateFollowPrefs.store;
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.error(TAG, `prefs store open failed, code=${e.code}, msg=${e.message}`);
      return null;
    }
  }
}
