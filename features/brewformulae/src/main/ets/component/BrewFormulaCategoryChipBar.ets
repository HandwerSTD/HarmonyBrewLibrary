/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { BrewChipBar, BrewChipItem, FORMULA_CATEGORY_NAME } from '@ohos/brewcommon';
import type { BrewCategoryCard } from '@ohos/brewcommon';

/**
 * Formulae 的分类 chip 栏。
 *
 * 与 Casks 的 `BrewCategoryChipBar` 同构：只做一件事 —— 把分类映射成通用的 `BrewChipItem[]`，
 * 渲染与全部样式都在 brewcommon 的 `BrewChipBar` 里。
 *
 * 数据形态不同带来的一处差异：Casks 的分类是 `BrewCaskCategory[]`（categoryName 字段自带的），
 * Formulae 首页没有那么一层 —— 分类就是 8 张 `BrewCategoryCard`，所以 chip 的 label 一律
 * 按 categoryKey 查本地化的 `FORMULA_CATEGORY_NAME`，回落到卡片自己的英文名 `title`
 * （与分类卡表头取中文名是同一份映射，不会出现「chip 与卡头叫法不一致」）。
 */
@Component
export struct BrewFormulaCategoryChipBar {
  @Prop @Require cards: BrewCategoryCard[];
  @Prop @Require currentIndex: number;
  handleCategoryClick?: (index: number) => void;

  private chips(): BrewChipItem[] {
    return this.cards.map((card: BrewCategoryCard) =>
      new BrewChipItem(card.id.toString(), FORMULA_CATEGORY_NAME[card.categoryKey] ?? card.title));
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
