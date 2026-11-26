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
    // IDataSource 契约：数据换了必须通知，LazyForEach 才会重取。历史上这里不通知
    // 也能用，是因为 loadDiscover 设完数据紧跟 loadingStatus 切 SUCCESS，loading→
    // content 的整页重建连带重建了 LazyForEach；D4 的运行时 phase 重建（骨架→实体、
    // 换一批）不碰 loadingStatus，不通知时数据源与已渲染节点脱节 —— 表现为 AI 区
    // 光有骨架不落地、原有六榜卡丢失。
    const current: DataChangeListener[] = this.listeners.slice();
    for (const one of current) {
      one.onDataReloaded();
    }
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
