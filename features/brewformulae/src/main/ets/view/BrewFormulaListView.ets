/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { HdsNavDestination, HideMode } from '@kit.UIDesignKit';
import { GlobalInfoModel, StorageKey } from '@ohos/common';
import { BaseHomeEventType } from '@ohos/commonbusiness';
import type { BrewFormulaState } from '../viewmodel/BrewFormulaState';
import { BrewFormulaHomeViewModel } from '../viewmodel/BrewFormulaHomeViewModel';
import { BrewFormulaBaseView } from './BrewFormulaBaseView';

@Component({ freezeWhenInactive: true })
struct BrewFormulaListView {
  @StorageProp(StorageKey.GLOBAL_INFO) globalInfoModel: GlobalInfoModel =
    AppStorage.get(StorageKey.GLOBAL_INFO) ?? new GlobalInfoModel();
  viewModel: BrewFormulaHomeViewModel = BrewFormulaHomeViewModel.getInstance();
  @State formulaState: BrewFormulaState = this.viewModel.getState();

  build() {
    HdsNavDestination() {
      BrewFormulaBaseView()
    }
    .hideBackButton(true)
    .bindToScrollable([this.formulaState.scroller])
    .dynamicHideTitleBar(this.globalInfoModel.needDynamicHideBar ? {
      hideTitleArea: true,
      mode: HideMode.SCROLL_UP,
    } : {})
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .titleBar({
      padding: this.formulaState.topNavigationData.hdsTitleBarPadding,
      avoidLayoutSafeArea: true,
      style: this.formulaState.topNavigationData.hdsTitleBarStyle,
      content: {
        title: { mainTitle: this.formulaState.topNavigationData.title },
      },
    })
    .onBackPressed(() => {
      return !!this.viewModel.sendEvent<null>({ type: BaseHomeEventType.ON_BACK_PRESS, param: null });
    })
    .onReady((ctx) => {
      this.viewModel.sendEvent({
        type: BaseHomeEventType.INIT_PATH_STACK,
        param: ctx.pathStack,
      });
    })
    .width('100%')
    .height('100%')
  }
}

@Builder
export function BrewFormulaListBuilder() {
  BrewFormulaListView()
}
