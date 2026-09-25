/*
 * Copyright (c) 2025 Huawei Device Co., Ltd.
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
