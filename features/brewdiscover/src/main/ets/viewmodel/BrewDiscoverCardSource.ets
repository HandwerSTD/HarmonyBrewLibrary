/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { BrewDiscoverBoard } from '@ohos/brewcommon';
import { BrewDiscoverFeedItem } from '../model/BrewDiscoverFeedItem';

/**
 * Discover 瀑布流的数据源。与 BrewFormulaCardSource 同构（WaterFlow 只认 IDataSource），
 * 只是它装的不是单一类型：单 App 大图卡与榜卡混在一条瀑布里，靠 `BrewDiscoverFeedItem.feedType` 分支。
 */
export class BrewDiscoverCardSource implements IDataSource {
  private feedList: BrewDiscoverFeedItem[] = [];
  private listeners: DataChangeListener[] = [];

  public setDataArray(dataArray: BrewDiscoverFeedItem[]): void {
    this.feedList = dataArray;
  }

  public totalCount(): number {
    return this.feedList.length;
  }

  public getData(index: number): BrewDiscoverFeedItem {
    if (index >= 0 && index < this.feedList.length) {
      return this.feedList[index];
    }
    // 只有榜单卡才有"空榜"这个兜底形态；单 App 卡没有可空的字段
    return BrewDiscoverFeedItem.ofBoard(new BrewDiscoverBoard());
  }

  public registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  public unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos: number = this.listeners.indexOf(listener);
    if (pos >= 0) {
      this.listeners.splice(pos, 1);
    }
  }
}
