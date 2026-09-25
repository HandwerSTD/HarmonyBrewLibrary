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
import type { BrewCategoryCard } from '@ohos/brewcommon';
import { BrewPackageItemSource } from '@ohos/brewcommon';

/**
 * 分类「查看全部」二级页状态。**每个页面实例各自 new 一份**（写在 view 的 @State 上）。
 *
 * 形状照 `BrewCaskState`（Casks 一级页）而不是照 Formulae 首页：本页是「chips 选一个分类 -> 看该分类的卡」，
 * 所以需要「全部分类卡 + 滚动位置」，而不是首页那套 WaterFlow section / 卡片源。
 *
 * **「当前选中哪个分类」不在这里** —— 它是页面自己的 `@State currentIndex`。
 *
 * 实测（2in1，`devecocli ui click` + `ui layout`/`ui screenshot` 逐帧对照）：
 * 先把选中项放在这个 `@Observed` 类的属性上、由 VM 在 chip 回调里赋值，结果是 hilog 打出了
 * `switch category -> devtools index=1`（**回调确实执行了、写入也发生了**），但 chips 选中态与内容
 * **一帧都不变**；改成组件自己的 `@State currentIndex` 后，同样的点击立即生效（截图已确认）。
 * 即问题不在点击、而在「那次写入没有驱动这一页重渲染」。
 *
 * **但具体原因没定位到，不要把它当成「@Observed 不能用」**：同样的写法（VM 写 state 的一级属性）
 * 在本仓库其它页是真机验证过可用的 —— Casks 首页（`BrewCaskState.currentCards`）、
 * 「我的-本机包」（`MinePackagesState.filteredPackages`）点 chip 都会换卡/筛选。
 * 本页采用的写法是「**能驱动 UI 的选中态放组件 @State，数据放 state 对象**」，
 * 这个写法本身经过验证（样例页 `PracticesView` 同款）。
 *
 * 另：用 `devecocli ui click` 做这类判定时，先确认窗口在前台 —— 坐标是屏幕坐标，
 * 窗口不在前台时点击会被别的窗口吃掉（什么都不会发生），此时 `ui layout` 会返回 `[0,0,0,0]`。
 * 本人就在「本机包 chips」上因此误判过一次。
 */
@Observed
export class BrewFormulaCategoryState {
  public loadingModel: LoadingModel = new LoadingModel();
  /** 全部分类卡（含各自**完整**成员）。chip 栏与内容都从这里按 `currentIndex` 取。 */
  public cards: BrewCategoryCard[] = [];
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
