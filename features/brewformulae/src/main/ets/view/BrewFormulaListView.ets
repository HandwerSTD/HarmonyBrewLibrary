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
