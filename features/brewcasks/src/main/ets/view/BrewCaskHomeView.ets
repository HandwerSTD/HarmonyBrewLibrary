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

import { HdsNavigation, HdsNavigationTitleMode, HdsTabsController } from '@kit.UIDesignKit';
import { PageContext, PageEnum, StorageKey } from '@ohos/common';
import { BaseHomeEventType, HomeListParams, InitializeParam } from '@ohos/commonbusiness';
import { BrewCaskHomeViewModel } from '../viewmodel/BrewCaskHomeViewModel';
import { BrewCaskBaseView } from './BrewCaskBaseView';

/**
 * Casks 入口的外层壳，与 BrewFormulaHomeView / ComponentHomeView 同构：
 * 自己持有一个 PageContext 的 NavPathStack，进入时先把列表页压栈。
 */
@Component({ freezeWhenInactive: true })
export struct BrewCaskHomeView {
  @StorageLink(StorageKey.BREW_CASK_PAGE_CONTEXT) caskPageContext: PageContext =
    AppStorage.get<PageContext>(StorageKey.BREW_CASK_PAGE_CONTEXT) ?? new PageContext();
  scroller: Scroller = new Scroller();
  homeTabController: HdsTabsController = new HdsTabsController();
  viewModel: BrewCaskHomeViewModel = BrewCaskHomeViewModel.getInstance();

  aboutToAppear(): void {
    this.viewModel.sendEvent<InitializeParam>({
      type: BaseHomeEventType.INITIALIZE,
      param: {
        homeTabController: this.homeTabController,
        scroller: this.scroller,
      },
    });
    this.caskPageContext.openPage({
      routerName: PageEnum.BREW_CASK_LIST_VIEW,
      param: {
        scroller: this.scroller,
        homeTabController: this.homeTabController,
      } as HomeListParams,
    }, false);
  }

  build() {
    HdsNavigation(this.caskPageContext.navPathStack) {
      BrewCaskBaseView()
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
