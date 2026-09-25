/*
 * Copyright (c) 2024 Huawei Device Co., Ltd.
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

import { ConfigurationConstant } from '@kit.AbilityKit';
import { SymbolGlyphModifier, TabsModifier } from '@kit.ArkUI';
import { HdsTabs, DividerMode, HdsTabsController, hdsMaterial, HdsTabsModifier } from '@kit.UIDesignKit';
import {
  BreakpointType,
  CommonConstants,
  GlobalInfoModel,
  HdsUtil,
  Logger,
  StorageKey,
  WindowUtil,
  DynamicInstallManager,
} from '@ohos/common';
import { TAB_CONTENT_STATUSES, TabBarType } from '@ohos/commonbusiness';
import { MineHomeView } from '@ohos/mine';
import { BrewFormulaHomeView } from '@ohos/brewformulae';
import { BrewDiscoverHomeView } from '@ohos/brewdiscover';
import { BrewCaskHomeView } from '@ohos/brewcasks';
import { BrewSearchHomeView } from '@ohos/brewsearch';
import { ALL_TABS_LIST, DEFAULT_TAB, TabBarData } from '../model/TabBarModel';

const TAG: string = '[HomeView]';

@Component
export struct HomeView {
  @StorageProp(StorageKey.GLOBAL_INFO) @Watch('updateTabsModifier') globalInfoModel: GlobalInfoModel =
    AppStorage.get(StorageKey.GLOBAL_INFO) ?? new GlobalInfoModel();
  @StorageProp(StorageKey.COLOR_MODE) @Watch('handleColorModeChange') systemColorMode: ConfigurationConstant.ColorMode =
    AppStorage.get(StorageKey.COLOR_MODE) ?? ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
  @Prop showTabBar: boolean = false;
  @Prop isShown: boolean = false;
  @Link currentIndex: number;
  @State tabsModifier: TabsModifier | HdsTabsModifier =
    (HdsUtil.isSupportNewMaterialApi() ? new HdsTabsModifier() : new TabsModifier());
  private tabController: HdsTabsController = new HdsTabsController();
  private mineScroller: Scroller = new Scroller();
  private discoverScroller: Scroller = new Scroller();
  private formulaScroller: Scroller = new Scroller();
  private caskScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    DynamicInstallManager.subscribeDownloadProgress();
    AppStorage.setOrCreate(StorageKey.CURRENT_TAB, DEFAULT_TAB);
    this.updateTabsModifier();
    this.tabController.bindScroller(TabBarType.MINE, this.mineScroller);
    this.tabController.bindScroller(TabBarType.DISCOVER, this.discoverScroller);
    this.tabController.bindScroller(TabBarType.FORMULAE, this.formulaScroller);
    this.tabController.bindScroller(TabBarType.CASKS, this.caskScroller);
  }

  aboutToDisappear(): void {
    DynamicInstallManager.unsubscribeDownloadProgress();
  }

  updateTabsModifier() {
    if (HdsUtil.isSupportNewMaterialApi() && !AppStorage.get<boolean>(StorageKey.IS_SIDEBAR_LAYOUT)) {
      (this.tabsModifier as HdsTabsModifier)
        .vertical(false)
        .barPosition(BarPosition.End)
        .barHeight(this.showTabBar ? CommonConstants.TAB_BAR_HEIGHT : 0)
        .barFloatingStyle({
          adaptToHandedness: true,
          barBottomMargin: this.globalInfoModel.naviIndicatorHeight > 0 ? this.globalInfoModel.naviIndicatorHeight :
            $r('sys.float.padding_level8'),
          systemMaterialEffect: {
            materialType: hdsMaterial.MaterialType.IMMERSIVE,
            materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE,
          },
        })
    }
  }

  onPageShow(): void {
    this.isShown = true;
    this.handleColorModeChange();
    CommonConstants.PROMISE_WAIT(500).then(() => {
      AppStorage.setOrCreate(StorageKey.BLUE_RENDER_GROUP, false);
    });
  }

  changeTabStatus(index: number) {
    AppStorage.setOrCreate(StorageKey.CURRENT_TAB, index);
    const selectedIndex = index;
    const isSystemDark: boolean = (this.systemColorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    if (selectedIndex === TabBarType.MINE || this.globalInfoModel.widthBreakpoint === WidthBreakpoint.WIDTH_LG ||
      this.globalInfoModel.widthBreakpoint === WidthBreakpoint.WIDTH_XL ||
      AppStorage.get<boolean>(StorageKey.IS_SIDEBAR_LAYOUT)) {
      WindowUtil.updateStatusBarColor(isSystemDark);
    } else {
      WindowUtil.updateStatusBarColor(isSystemDark || TAB_CONTENT_STATUSES[selectedIndex]);
    }
    this.currentIndex = index;
  }

  handleColorModeChange() {
    if (this.isShown) {
      this.changeTabStatus(this.currentIndex);
    }
  }

  bottomTabBarStyle(tabType: TabBarType): BottomTabBarStyle {
    // 按枚举在完整入口表里查，**不能**写成 `TABS_LIST[tabType]`：
    // TABS_LIST 已滤掉隐藏入口，下标与 TabBarType 不再一一对应，会把每个页签显示成别人的名字与图标。
    const tabItem: TabBarData = ALL_TABS_LIST.find((item: TabBarData) => item.id === tabType) ?? ALL_TABS_LIST[0];
    const normalGlyphModifier = new SymbolGlyphModifier(tabItem.icon)
      .renderingStrategy(HdsUtil.isSupportNewMaterialApi() ? SymbolRenderingStrategy.SINGLE :
        SymbolRenderingStrategy.MULTIPLE_OPACITY);
    if (HdsUtil.isSupportNewMaterialApi()) {
      normalGlyphModifier.fontColor(HdsUtil.isSupportNewMaterialApi() ? [$r('sys.color.icon_primary')] : [])
    }
    return BottomTabBarStyle.of({
      normal: normalGlyphModifier,
      selected: new SymbolGlyphModifier(tabItem.icon)
        .renderingStrategy(HdsUtil.isSupportNewMaterialApi() ? SymbolRenderingStrategy.SINGLE :
          SymbolRenderingStrategy.MULTIPLE_OPACITY)
    }, tabItem.title)
      .labelStyle(HdsUtil.isSupportNewMaterialApi() ? { unselectedColor: $r('sys.color.font_primary') } : undefined)
      .padding({
        bottom: (this.globalInfoModel.widthBreakpoint === WidthBreakpoint.WIDTH_LG ||
          HdsUtil.isSupportNewMaterialApi()) ? 0 : this.globalInfoModel.naviIndicatorHeight
      })
  }

  @Builder
  TabContentsBuilder() {
    TabContent() {
      MineHomeView({ scroller: this.mineScroller, homeTabController: this.tabController })
    }
    .tabBar(this.showTabBar ? this.bottomTabBarStyle(TabBarType.MINE) : new SubTabBarStyle(''))

    TabContent() {
      BrewDiscoverHomeView({ scroller: this.discoverScroller, homeTabController: this.tabController })
    }
    .tabBar(this.showTabBar ? this.bottomTabBarStyle(TabBarType.DISCOVER) : new SubTabBarStyle(''))

    TabContent() {
      BrewFormulaHomeView({ scroller: this.formulaScroller, homeTabController: this.tabController })
    }
    .tabBar(this.showTabBar ? this.bottomTabBarStyle(TabBarType.FORMULAE) : new SubTabBarStyle(''))

    TabContent() {
      BrewCaskHomeView({ scroller: this.caskScroller, homeTabController: this.tabController })
    }
    .tabBar(this.showTabBar ? this.bottomTabBarStyle(TabBarType.CASKS) : new SubTabBarStyle(''))

    // 搜索页签。**必须排在最后**：HdsTabs 按 `TabBarType` 的**值**取内容（= TabContent 的下标），
    // `BREW_SEARCH = 4` 而上面四个 TabContent 依次是 0..3。侧边栏的顺序另由 `ALL_TABS_LIST` 决定，
    // 两者互不影响（搜索在侧边栏里排在「我的」之上，在这里却必须在末尾）。
    TabContent() {
      BrewSearchHomeView()
    }
    .tabBar(this.showTabBar ? this.bottomTabBarStyle(TabBarType.BREW_SEARCH) : new SubTabBarStyle(''))
  }

  build() {
    HdsTabs({ controller: this.tabController as HdsTabsController, index: this.currentIndex }) {
      this.TabContentsBuilder()
    }
    .backgroundColor($r('sys.color.background_secondary'))
    .vertical((this.globalInfoModel.widthBreakpoint === WidthBreakpoint.WIDTH_LG ||
      this.globalInfoModel.widthBreakpoint === WidthBreakpoint.WIDTH_XL) &&
      !AppStorage.get<boolean>(StorageKey.IS_SIDEBAR_LAYOUT))
    .barPosition((this.globalInfoModel.widthBreakpoint === WidthBreakpoint.WIDTH_LG ||
      this.globalInfoModel.widthBreakpoint === WidthBreakpoint.WIDTH_XL) &&
      !AppStorage.get<boolean>(StorageKey.IS_SIDEBAR_LAYOUT) ? BarPosition.Start :
      BarPosition.End)
    .divider({
      mode: !AppStorage.get<boolean>(StorageKey.IS_SIDEBAR_LAYOUT) ? DividerMode.FOLLOW_SCROLL : DividerMode.NONE,
    })
    .barHeight(this.showTabBar ? new BreakpointType<Length>({
      sm: CommonConstants.TAB_BAR_HEIGHT + this.globalInfoModel.naviIndicatorHeight,
      md: CommonConstants.TAB_BAR_HEIGHT + this.globalInfoModel.naviIndicatorHeight,
      lg: '100%',
    }).getValue(this.globalInfoModel.widthBreakpoint) : 0)
    .barOverlap(true)
    .scrollable(false)
    .animationDuration(0)
    .attributeModifier(HdsUtil.isSupportNewMaterialApi() ? this.tabsModifier as HdsTabsModifier : undefined)
    .onAttach(() => {
      this.tabController?.preloadItems([TabBarType.DISCOVER, TabBarType.MINE])
        .catch((error: Error) => {
          Logger.error(TAG, `onAttach failed. cause: ${error.message}`);
        });
    })
    .onChange((index: number) => {
      this.changeTabStatus(index);
    })
  }
}