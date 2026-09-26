/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { LoadingStatus, Logger, PageContext, PageEnum, StorageKey } from '@ohos/common';
import { adapterFor, BrewCaskModel, BrewKind, BrewSourceStore } from '@ohos/brewcommon';
import type { BrewCaskCategory, BrewCategoryParams, BrewDetailParams, BrewPackageItem } from '@ohos/brewcommon';
import { BrewCaskCategoryState } from './BrewCaskCategoryState';

const TAG: string = '[BrewCaskCategoryVM]';

/**
 * Casks 分类「查看全部」二级页 ViewModel。
 *
 * 与 `BrewFormulaCategoryVM` 一一对应（无状态、state 由页面自己 new 并通过参数传进来，
 * 理由见 docs §10.4.1：把「每页实例」的状态放进共享单例，叠第二个同类页面时会互相覆盖），
 * 差别只有数据来源：这边取 `BrewCaskModel.getCaskCategories()`（分类 -> 卡片 -> 条目三层）。
 */
export class BrewCaskCategoryVM {
  private static instance: BrewCaskCategoryVM;
  private caskModel: BrewCaskModel = BrewCaskModel.getInstance();

  private constructor() {
  }

  public static getInstance(): BrewCaskCategoryVM {
    if (!BrewCaskCategoryVM.instance) {
      BrewCaskCategoryVM.instance = new BrewCaskCategoryVM();
    }
    return BrewCaskCategoryVM.instance;
  }

  /**
   * 取全部分类（每个分类内含它的卡片与**完整**成员），并返回 chip 该选中的下标。
   *
   * **下标是返回值，不是 state 的属性** —— 选中态由页面自己的 `@State currentIndex` 持有
   * （理由与实测记录见 `BrewFormulaCategoryVM.load` 与 `BrewFormulaCategoryState` 顶部注释）。
   *
   * 不新增端点：分类与成员本来就是设备端用「目录 + 词表」现算的，首页刚算过一次，
   * 这里再取一次是命中目录缓存（与 Formulae 分类二级页同款做法）。
   *
   * 空数组的语义**按源能力分**：
   *   - 源**支持** cask（上游）时，本页只能从「卡片还有更多」进入，所以空数组不可能是
   *     「这个分类本来就空」，而是目录没拿到（无网）—— 给失败态 + 重试，比显示一张空列表有用。
   *   - 源**不支持** cask（Harmonybrew）时，空数组就是**正常结果**，判成 FAILED 会让用户看到
   *     「加载失败」，而实际上只是这个源没有 cask。这类「把空当成失败」的误报比空列表更坑。
   *
   * 仓库层把异常吞成空数组（`getCaskCategories`），所以这里不写 catch，只按能力与长度判状态。
   * 能力查询不能放到 `BrewSourceStore` 上（`BrewSourceAdapter` 已 import 它，反向会成环）。
   */
  public load(params: BrewCategoryParams | undefined, state: BrewCaskCategoryState): Promise<number> {
    state.initialCategoryKey = params?.categoryKey ?? '';
    state.loadingModel.loadingStatus = LoadingStatus.LOADING;
    return this.caskModel.getCaskCategories()
      .then((categories: BrewCaskCategory[]) => {
        state.categories = categories;
        const index: number = this.indexOfCategory(categories, state.initialCategoryKey);
        const sessionId: string = BrewSourceStore.sessionActive().id;
        const casksSupported: boolean = adapterFor(BrewSourceStore.dialectOf(sessionId)).supportsCasks;
        state.loadingModel.loadingStatus = (!casksSupported || categories.length > 0)
          ? LoadingStatus.SUCCESS : LoadingStatus.FAILED;
        Logger.info(TAG,
          `load ${categories.length} categories, selected=${this.categoryKeyAt(categories, index)} index=${index}`);
        return index;
      });
  }

  /**
   * 换分类后的收尾：回到顶部。
   *
   * 选中态本身由调用方（页面）写自己的 `@State` —— 本方法只做「与数据/UI 无关的那半件事」，
   * 因为停在上一个分类的滚动位置会很突兀（与首页同款处理）。
   */
  public scrollToTop(state: BrewCaskCategoryState): void {
    state.scroller?.scrollTo({ xOffset: 0, yOffset: 0, animation: false });
  }

  public categoryKeyAt(categories: BrewCaskCategory[], index: number): string {
    return categories[index]?.categoryKey ?? '';
  }

  public jumpDetail(item: BrewPackageItem): void {
    const param: BrewDetailParams = {
      kind: BrewKind.CASK,
      title: item.subTitle,
      id: item.id,
      token: item.token,
      categoryKey: item.categoryKey,
    };
    // 与首页同一个页面栈：本页是从 Casks 页签压进来的，详情页也应该压在同一栈上，
    // 否则返回时会把用户弹回页签根页（而不是这张分类列表）。
    const pageContext: PageContext | undefined = AppStorage.get<boolean>(StorageKey.IS_SIDEBAR_LAYOUT) ?
      AppStorage.get<PageContext>(StorageKey.BREW_CASK_PAGE_CONTEXT) :
      AppStorage.get<PageContext>(StorageKey.HOME_PAGE_CONTEXT);
    pageContext?.openPage({
      routerName: PageEnum.BREW_DETAIL_VIEW,
      param: param,
    }, true);
  }

  /** 按 categoryKey 找下标；找不到（key 变了/为空）就退回第 0 个，不把页面变成空态。 */
  private indexOfCategory(categories: BrewCaskCategory[], categoryKey: string): number {
    const index: number = categories.findIndex((one: BrewCaskCategory) => one.categoryKey === categoryKey);
    return index < 0 ? 0 : index;
  }
}
