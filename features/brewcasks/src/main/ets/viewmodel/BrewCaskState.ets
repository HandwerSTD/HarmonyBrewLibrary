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
import { BrewCaskCardSource } from './BrewCaskCardSource';

/**
 * Casks 首页状态。
 *
 * 与 Formulae 首页同构（那边是 `BrewFormulaState`）：首页就是一屏**分类卡**，
 * 用 LazyForEach + sections 渲染，所以这里只存「卡片源 + 瀑布流分段」。
 *
 * 分类 chips **不在这里** —— 它们和「看某个分类的全部」一起搬到了分类二级页
 * （`BrewCaskCategoryView`，那边有自己的 `BrewCaskCategoryState`）。
 * 所以本页不再需要「当前选中的分类」这类字段。
 *
 * 注：本类不加 @Observed。@State 会观察所持对象的**一级属性**赋值
 * （「我的」页 MinePageState、分类二级页的 `BrewCaskCategoryState` 都是同样的写法
 * 并驱动了刷新，可作依据）。
 */
export class BrewCaskState extends BaseHomeState {
  public cardSource: BrewCaskCardSource = new BrewCaskCardSource();
  public sections: WaterFlowSections = new WaterFlowSections();

  public constructor() {
    super();
  }
}
