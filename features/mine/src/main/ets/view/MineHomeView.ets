/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
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
import { Logger, PageContext, PageEnum, StorageKey } from '@ohos/common';
import { HomeListParams } from '@ohos/commonbusiness';
import { PackageListMode } from '../model/MinePackagesModels';
import type { MinePackagesParams } from '../model/MinePackagesModels';

const TAG: string = '[MineHomeView]';

@Component({ freezeWhenInactive: true })
export struct MineHomeView {
  @StorageLink((StorageKey.MINE_PAGE_CONTEXT)) minePageContext: PageContext =
    AppStorage.get<PageContext>(StorageKey.MINE_PAGE_CONTEXT) ?? new PageContext();
  /**
   * 更新哨兵的待处理路由（卡片点击 / 通知「全部升级」，PcAbility 从 want 落进 AppStorage）。
   * 本组件是「我的」导航栈的宿主，pushPath 只能在这里做——太早（MineView 尚未 replacePage
   * 铺底）会被顶掉，太晚（别的组件的栈）页不对。消费后立即清键，避免下次冷启动重复跳。
   */
  @StorageProp(StorageKey.SENTINEL_PENDING_ROUTE) @Watch('consumeSentinelRoute') sentinelPendingRoute: string = '';
  scroller: Scroller = new Scroller();
  homeTabController: HdsTabsController = new HdsTabsController();

  aboutToAppear(): void {
    this.minePageContext.replacePage({
      routerName: PageEnum.MINE_VIEW,
      param: {
        scroller: this.scroller,
        homeTabController: this.homeTabController,
      } as HomeListParams,
    }, false);
    // 冷启动：PcAbility.onCreate 早于 UI 构建，watch 不会触发，铺底之后补一次消费
    this.consumeSentinelRoute();
  }

  /**
   * 待处理路由 → 直达升级队列（G2/G4）。
   *
   * 路由名固定是 MinePackagesView（卡片与通知按钮都带这个值）；路由参数复用既有
   * MinePackagesParams：mode=OUTDATED，因为通知说的是「待升级」。「导航栈未就绪」在
   * 本组件的语境下不存在——消费点都在本组件生命周期内，NavPathStack 由本组件持有。
   */
  private consumeSentinelRoute(): void {
    const route: string = this.sentinelPendingRoute;
    if (route.length === 0) {
      return;
    }
    AppStorage.setOrCreate<string>(StorageKey.SENTINEL_PENDING_ROUTE, '');
    if (route !== PageEnum.MINE_PACKAGES_VIEW) {
      Logger.warn(TAG, `unknown sentinel route: ${route}`);
      return;
    }
    this.minePageContext.openPage({
      routerName: PageEnum.MINE_PACKAGES_VIEW,
      param: { mode: PackageListMode.OUTDATED } as MinePackagesParams,
    }, true);
    Logger.info(TAG, 'sentinel route consumed: open packages (outdated)');
  }

  build() {
    HdsNavigation(this.minePageContext.navPathStack) {
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