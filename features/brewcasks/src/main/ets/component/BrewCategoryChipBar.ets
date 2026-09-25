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

import { BrewChipBar, BrewChipItem, CASK_CATEGORY_NAME } from '@ohos/brewcommon';
import type { BrewCaskCategory } from '@ohos/brewcommon';

/**
 * Casks 的分类 chip 栏。
 *
 * 只做一件事：把 `BrewCaskCategory[]` 映射成通用的 `BrewChipItem[]`，
 * 渲染与全部样式都在 `brewcommon` 的 `BrewChipBar` 里 ——
 * 「我的-本机包」子页面也要用同一套 chip，样式若各写一份必然漂移。
 *
 * 挂载点：分类二级页 `BrewCaskCategoryView` 的标题栏 `bottomBuilder`
 * （改造前是挂在 Casks 首页上的，首页改成分类卡瀑布流后搬到了二级页）。
 *
 * 分类名的取值优先级：本地化的 `CASK_CATEGORY_NAME` 优先，回落到数据里的 `categoryName`
 * （与 mock 的 categoryKey 一一对应，见 docs §10.3）。
 */
@Component
export struct BrewCategoryChipBar {
  @Prop @Require categories: BrewCaskCategory[];
  @Prop @Require currentIndex: number;
  handleCategoryClick?: (index: number) => void;

  private chips(): BrewChipItem[] {
    return this.categories.map((category: BrewCaskCategory) =>
      new BrewChipItem(category.id.toString(),
        CASK_CATEGORY_NAME[category.categoryKey] ?? category.categoryName));
  }

  build() {
    BrewChipBar({
      chips: this.chips(),
      currentIndex: this.currentIndex,
      handleChipClick: (index: number) => {
        this.handleCategoryClick?.(index);
      },
    })
  }
}
