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

import { LoadingStatus, Logger, PageContext, PageEnum, StorageKey } from '@ohos/common';
import { BrewFormulaModel, BrewKind } from '@ohos/brewcommon';
import type { BrewCategoryCard, BrewCategoryParams, BrewDetailParams, BrewPackageItem } from '@ohos/brewcommon';
import { BrewFormulaCategoryState } from './BrewFormulaCategoryState';

const TAG: string = '[BrewFormulaCategoryVM]';

/**
 * 分类「查看全部」二级页 ViewModel。
 *
 * **无状态**：state 由页面自己 `new` 并通过参数传进来 —— 与详情页 / 榜单二级页同一个理由
 * （docs §10.4.1）：把「每页实例」的状态放进共享单例，叠第二个同类页面时会互相覆盖。
 *
 * 与 `BrewCaskHomeViewModel` 的差别只有一处：那边 load 完固定选第 0 个分类（页签根页面），
 * 这边要按路由参数选到「用户点进来的那个分类」，所以多一个 `initialCategoryKey`。
 */
export class BrewFormulaCategoryVM {
  private static instance: BrewFormulaCategoryVM;
  private formulaModel: BrewFormulaModel = BrewFormulaModel.getInstance();

  private constructor() {
  }

  public static getInstance(): BrewFormulaCategoryVM {
    if (!BrewFormulaCategoryVM.instance) {
      BrewFormulaCategoryVM.instance = new BrewFormulaCategoryVM();
    }
    return BrewFormulaCategoryVM.instance;
  }

  /**
   * 取全部分类卡（每张卡内含该分类的**完整**成员），并返回 chip 该选中的下标。
   *
   * **下标是返回值，不是 state 的属性** —— 选中态由页面自己的 `@State currentIndex` 持有。
   * 先走过一版「VM 把 `state.currentIndex` 改掉」：hilog 证明回调执行了（`switch category …`），
   * 但 chips 与内容一帧不变（实测：`ui click` 后 `ui layout`/`ui screenshot` 与点击前逐帧一致）；
   * 换成组件 @State 后同样的点击立即生效（截图已确认）。
   * 原因未定位（同样写法在 Casks 首页、「我的-本机包」真机上是好的），
   * 详见 `BrewFormulaCategoryState` 顶部注释。
   *
   * 不新增端点：分类与成员本来就是设备端用「目录 + 词表」现算的，首页刚算过一次，
   * 这里再取一次是命中目录缓存（与榜单二级页按 boardId 重取 discover 页同款做法）。
   *
   * 空数组按**失败**处理：本页只能从「卡片还有更多」进入，所以空数组不可能是「这个分类本来就空」，
   * 而是目录没拿到（无网）—— 给失败态 + 重试，比显示一张空列表有用。
   * 仓库层把异常吞成空数组（`getFormulaCategories`），所以这里不写 catch，只按长度判状态。
   */
  public load(params: BrewCategoryParams | undefined, state: BrewFormulaCategoryState): Promise<number> {
    state.initialCategoryKey = params?.categoryKey ?? '';
    state.loadingModel.loadingStatus = LoadingStatus.LOADING;
    return this.formulaModel.getFormulaCategories()
      .then((cards: BrewCategoryCard[]) => {
        state.cards = cards;
        const index: number = this.indexOfCategory(cards, state.initialCategoryKey);
        state.loadingModel.loadingStatus = cards.length > 0 ? LoadingStatus.SUCCESS : LoadingStatus.FAILED;
        Logger.info(TAG,
          `load ${cards.length} categories, selected=${this.categoryKeyAt(cards, index)} index=${index}`);
        return index;
      });
  }

  /**
   * 换分类后的收尾：回到顶部。
   *
   * 选中态本身由调用方（页面）写自己的 `@State` —— 本方法只做「与数据/UI 无关的那半件事」，
   * 因为停在上一个分类的滚动位置会很突兀（与 Casks 页同款处理）。
   */
  public scrollToTop(state: BrewFormulaCategoryState): void {
    state.scroller?.scrollTo({ xOffset: 0, yOffset: 0, animation: false });
  }

  public categoryKeyAt(cards: BrewCategoryCard[], index: number): string {
    return cards[index]?.categoryKey ?? '';
  }

  public jumpDetail(item: BrewPackageItem): void {
    const param: BrewDetailParams = {
      kind: BrewKind.FORMULA,
      title: item.subTitle,
      id: item.id,
      token: item.token,
      categoryKey: item.categoryKey,
    };
    // 与首页同一个页面栈：本页是从 Formulae 页签压进来的，详情页也应该压在同一栈上，
    // 否则返回时会把用户弹回页签根页（而不是这张分类列表）。
    const pageContext: PageContext | undefined = AppStorage.get<boolean>(StorageKey.IS_SIDEBAR_LAYOUT) ?
      AppStorage.get<PageContext>(StorageKey.BREW_FORMULA_PAGE_CONTEXT) :
      AppStorage.get<PageContext>(StorageKey.HOME_PAGE_CONTEXT);
    pageContext?.openPage({
      routerName: PageEnum.BREW_DETAIL_VIEW,
      param: param,
    }, true);
  }

  /** 按 categoryKey 找下标；找不到（key 变了/为空）就退回第 0 个，不把页面变成空态。 */
  private indexOfCategory(cards: BrewCategoryCard[], categoryKey: string): number {
    const index: number = cards.findIndex((card: BrewCategoryCard) => card.categoryKey === categoryKey);
    return index < 0 ? 0 : index;
  }
}
