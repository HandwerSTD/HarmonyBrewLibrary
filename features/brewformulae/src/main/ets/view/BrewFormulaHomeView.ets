/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { HdsNavigation, HdsNavigationTitleMode, HdsTabsController } from '@kit.UIDesignKit';
import { PageContext, PageEnum, StorageKey } from '@ohos/common';
import { BaseHomeEventType, HomeListParams, InitializeParam } from '@ohos/commonbusiness';
import { BrewFormulaHomeViewModel } from '../viewmodel/BrewFormulaHomeViewModel';
import { BrewFormulaBaseView } from './BrewFormulaBaseView';

/**
 * Formulae 入口的外层壳，与 ComponentHomeView 同构：
 * 自己持有一个 PageContext 的 NavPathStack，进入时先把列表页压栈。
 */
@Component({ freezeWhenInactive: true })
export struct BrewFormulaHomeView {
  @StorageLink(StorageKey.BREW_FORMULA_PAGE_CONTEXT) brewPageContext: PageContext =
    AppStorage.get<PageContext>(StorageKey.BREW_FORMULA_PAGE_CONTEXT) ?? new PageContext();
  scroller: Scroller = new Scroller();
  homeTabController: HdsTabsController = new HdsTabsController();
  viewModel: BrewFormulaHomeViewModel = BrewFormulaHomeViewModel.getInstance();

  aboutToAppear(): void {
    this.viewModel.sendEvent<InitializeParam>({
      type: BaseHomeEventType.INITIALIZE,
      param: {
        homeTabController: this.homeTabController,
        scroller: this.scroller,
      },
    });
    this.brewPageContext.openPage({
      routerName: PageEnum.BREW_FORMULA_LIST_VIEW,
      param: {
        scroller: this.scroller,
        homeTabController: this.homeTabController,
      } as HomeListParams,
    }, false);
  }

  build() {
    HdsNavigation(this.brewPageContext.navPathStack) {
      BrewFormulaBaseView()
    }
    .mode(NavigationMode.Stack)
    .hideBackButton(true)
    .hideTitleBar(true)
    .titleMode(HdsNavigationTitleMode.MINI)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .width('100%')
    .height('100%')
  }
}
