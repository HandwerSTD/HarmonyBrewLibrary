/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { Logger, PreferenceManager } from '@ohos/common';
import { BREW_SEARCH_HISTORY_KEY } from '../constant/BrewSearchConstants';

const TAG: string = '[BrewSearch]';

/**
 * 搜索历史的落盘（Preference）。**全项目只有这里读写 `BREW_SEARCH_HISTORY_KEY`** ——
 * 历史是搜索模块自己的数据，入口收在模块内，别处（含 UI）只能经 `BrewSearchVM` 拿。
 *
 * 为什么走 `PreferenceManager` 而不是自己开一份 RDB：历史是一串短字符串（上限
 * `BREW_SEARCH_HISTORY_LIMIT` 条），与目录/索引/现网缓存同一套机制，
 * `getValue/setValue` 已经把 JSON 序列化、flush 与「UIContext 还没就绪」的重试兜住了。
 *
 * 为什么读的时候还要逐项筛：盘上的数据可能来自旧版本或被外部改过，
 * 到这里必须收敛成「非空字符串数组」，否则坏数据会一路走到 chips 的渲染里。
 */
export class BrewSearchHistoryStore {
  /**
   * 读历史。读不到 / 数据坏了都返回空数组。
   *
   * **绝不抛错**：历史丢了只是少了一屏建议，不该让搜索页变成错误态。
   */
  public static load(): string[] {
    const stored: string[] | null =
      PreferenceManager.getInstance().getValue<string[]>(BREW_SEARCH_HISTORY_KEY);
    if (stored === null || !Array.isArray(stored)) {
      Logger.info(TAG, 'search history: none on device');
      return [];
    }
    const out: string[] = [];
    stored.forEach((word: string) => {
      if (typeof word === 'string' && word.trim().length > 0) {
        out.push(word);
      }
    });
    Logger.info(TAG, `search history loaded, ${out.length} words`);
    return out;
  }

  /** 写历史。整份覆盖：调用方（`BrewSearchVM.recordSearch`）传进来的就是新的全量 */
  public static save(words: string[]): void {
    PreferenceManager.getInstance().setValue<string[]>(BREW_SEARCH_HISTORY_KEY, words);
  }

  /**
   * 清空历史：**删 key 而不是写空数组**。
   *
   * 读回来两者都是空，但删 key 才是「设备上真的没有这份数据」——
   * 垃圾桶按钮的语义就是这个（用户看不到任何残留，也不占盘）。
   */
  public static clear(): void {
    PreferenceManager.getInstance().deleteValue(BREW_SEARCH_HISTORY_KEY);
    Logger.info(TAG, 'search history cleared (persisted)');
  }
}
