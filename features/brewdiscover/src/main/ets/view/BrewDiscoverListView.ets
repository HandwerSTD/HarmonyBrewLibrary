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

import { HdsNavDestination, HideMode } from '@kit.UIDesignKit';
import { GlobalInfoModel, StorageKey } from '@ohos/common';
import { BaseHomeEventType } from '@ohos/commonbusiness';
import type { BrewDiscoverState } from '../viewmodel/BrewDiscoverState';
import { BrewDiscoverHomeViewModel } from '../viewmodel/BrewDiscoverVM';
import { BrewDiscoverBaseView } from './BrewDiscoverBaseView';

/**
 * Discover 页签的首个目的地，与 BrewFormulaListView 同构。
 *
 * 标题栏相关的四件事都在这里，而不是在内容视图里：
 *   - 模糊材质（hdsTitleBarStyle 由 BaseHomeViewModel 按断点/配色算好）
 *   - 随滚动动态隐藏（dynamicHideTitleBar + bindToScrollable）
 *   - 顶部安全区忽略（ignoreLayoutSafeArea(TOP)）—— 所以内容视图必须自己用 padding 让位
 *   - 返回键交给基类的 ON_BACK_PRESS 处理
 */
@Component({ freezeWhenInactive: true })
struct BrewDiscoverListView {
  @StorageProp(StorageKey.GLOBAL_INFO) globalInfoModel: GlobalInfoModel =
    AppStorage.get(StorageKey.GLOBAL_INFO) ?? new GlobalInfoModel();
  viewModel: BrewDiscoverHomeViewModel = BrewDiscoverHomeViewModel.getInstance();
  @State discoverState: BrewDiscoverState = this.viewModel.getState();

  build() {
    HdsNavDestination() {
      BrewDiscoverBaseView()
    }
    .hideBackButton(true)
    .bindToScrollable([this.discoverState.scroller])
    .dynamicHideTitleBar(this.globalInfoModel.needDynamicHideBar ? {
      hideTitleArea: true,
      mode: HideMode.SCROLL_UP,
    } : {})
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .titleBar({
      padding: this.discoverState.topNavigationData.hdsTitleBarPadding,
      avoidLayoutSafeArea: true,
      style: this.discoverState.topNavigationData.hdsTitleBarStyle,
      content: {
        title: { mainTitle: this.discoverState.topNavigationData.title },
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
export function BrewDiscoverListBuilder() {
  BrewDiscoverListView()
}
