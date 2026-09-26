/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { BaseHomeState } from '@ohos/commonbusiness';
import { BrewDiscoverCardSource } from './BrewDiscoverCardSource';

/**
 * Discover 页状态。
 *
 * 与 BrewFormulaState 同构，都继承 BaseHomeState —— 模糊标题栏、section、滚动位置、
 * 返回键、断点/配色变化这些都在基类里，这里只加榜单卡片源与快照日期。
 */
export class BrewDiscoverState extends BaseHomeState {
  public cardSource: BrewDiscoverCardSource = new BrewDiscoverCardSource();
  public sections: WaterFlowSections = new WaterFlowSections();
  /**
   * 数据窗口结束日，如 `'2026-09-17'`。
   *
   * **必须是 state 上的一层属性**：`@State` 只观察一层，包进嵌套对象就不会触发页面更新。
   * 页面上「数据窗口 xxx」这行用它。
   */
  public snapshotDate: string = '';

  public constructor() {
    super();
  }
}
