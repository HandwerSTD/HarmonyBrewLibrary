/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { HdsNavDestination, HideMode } from '@kit.UIDesignKit';
import { GlobalInfoModel, StorageKey } from '@ohos/common';
import { BaseHomeEventType } from '@ohos/commonbusiness';
import type { BrewCaskState } from '../viewmodel/BrewCaskState';
import { BrewCaskHomeViewModel } from '../viewmodel/BrewCaskHomeViewModel';
import { BrewCaskBaseView } from './BrewCaskBaseView';

@Component({ freezeWhenInactive: true })
struct BrewCaskListView {
  @StorageProp(StorageKey.GLOBAL_INFO) globalInfoModel: GlobalInfoModel =
    AppStorage.get(StorageKey.GLOBAL_INFO) ?? new GlobalInfoModel();
  viewModel: BrewCaskHomeViewModel = BrewCaskHomeViewModel.getInstance();
  @State caskState: BrewCaskState = this.viewModel.getState();

  build() {
    HdsNavDestination() {
      BrewCaskBaseView()
    }
    .hideBackButton(true)
    .bindToScrollable([this.caskState.scroller])
    .dynamicHideTitleBar(this.globalInfoModel.needDynamicHideBar ? {
      hideTitleArea: true,
      mode: HideMode.SCROLL_UP,
    } : {})
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .titleBar({
      padding: this.caskState.topNavigationData.hdsTitleBarPadding,
      avoidLayoutSafeArea: true,
      style: this.caskState.topNavigationData.hdsTitleBarStyle,
      content: {
        title: { mainTitle: this.caskState.topNavigationData.title },
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
export function BrewCaskListBuilder() {
  BrewCaskListView()
}
