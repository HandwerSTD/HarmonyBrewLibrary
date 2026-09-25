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

import { LoadingModel } from '@ohos/common';
import type { BrewCaskCategory } from '@ohos/brewcommon';
import { BrewPackageItemSource } from '@ohos/brewcommon';

/**
 * Casks 分类「查看全部」二级页状态。**每个页面实例各自 new 一份**（写在 view 的 @State 上）。
 *
 * 与 Formulae 的 `BrewFormulaCategoryState` 一一对应，只有「分类」的类型不同：
 * 那边分类本身就是卡（`BrewCategoryCard[]`），这边多一层，分类是 `BrewCaskCategory[]`，
 * 每个分类里再挂它的卡片（`caskCards`）。所以 chip 栏与内容都从这里取：
 * chip 用分类数组，内容用「当前分类的卡片」。
 *
 * **「当前选中哪个分类」不在这里** —— 它是页面自己的 `@State currentIndex`：
 * 能驱动 UI 的选中态放组件 @State，数据放 state 对象，两者不混
 * （理由与实测记录见 `BrewFormulaCategoryState` 顶部注释）。
 */
@Observed
export class BrewCaskCategoryState {
  public loadingModel: LoadingModel = new LoadingModel();
  /** 全部分类（含各自卡片与**完整**成员）。chip 栏与内容都从这里按 `currentIndex` 取。 */
  public categories: BrewCaskCategory[] = [];
  /**
   * 路由带进来的分类 key。切 chip 不改它：重试时要回到「用户点进来的那个分类」，
   * 而不是回到最后一次点开的那个。
   */
  public initialCategoryKey: string = '';
  /** 本页自己的滚动器（切分类要回到顶部，需要一个能 scrollTo 的对象） */
  public scroller: Scroller = new Scroller();
  /**
   * 成员行的 `LazyForEach` 数据源。放进 state（与首页的 `BrewFormulaState.cardSource`
   * 同一位置、同一理由）：每页实例一份，切分类时由 view 换数据。
   */
  public itemSource: BrewPackageItemSource = new BrewPackageItemSource();
}
