/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { HdsNavigation, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { CommonConstants, PageContext, PageEnum, StorageKey } from '@ohos/common';
import { BrewSearchResultView } from './BrewSearchResultView';

/**
 * 搜索页签的内容壳，与 `BrewDiscoverHomeView` 同构：自己持有一个 PageContext 的
 * NavPathStack，进入时把搜索页压栈作为栈底。
 *
 * 形态说明（需求方真机测试后定的口径）：搜索是**侧边栏的一个普通页签**，
 * 不再是「侧边栏搜索框 + 历史/发现浮层」的覆盖层形态 —— 浮层会把焦点从输入框拿走，
 * 面板一拉起打字就没反应（`focusable` 的浮层是焦点作用域，抢不回来）。
 * 输入框因此搬进搜索页的标题栏（见 `BrewSearchBar`），历史/发现渲染在页内。
 *
 * `StorageKey` 必须是**本模块自己的** `BREW_SEARCH_PAGE_CONTEXT`：共用会让搜索的
 * 页面栈与某个页签串起来（从一个页签的二级页会影响到另一个）。
 *
 * ## 压栈为什么必须幂等
 *
 * `PageContext` 活在 `AppStorage` 里，**不受本组件销毁影响**（没人出栈时它就一直在），
 * 而 `HdsTabs` 的 `TabContent` 可能被销毁重建。于是「每次进来都压一个搜索页」会让栈里
 * 叠出 N 个，栈底返回键要先白白按 N 下。所以进入时按**栈契约**对齐：
 * 栈里恰好一个搜索页、且在栈底（见 `ensureResultPageAtBottom`）。
 */
@Component({ freezeWhenInactive: true })
export struct BrewSearchHomeView {
  @StorageLink(StorageKey.BREW_SEARCH_PAGE_CONTEXT) searchPageContext: PageContext =
    AppStorage.get<PageContext>(StorageKey.BREW_SEARCH_PAGE_CONTEXT) ?? new PageContext();

  aboutToAppear(): void {
    this.ensureResultPageAtBottom();
  }

  /**
   * 栈契约：进入搜索页签后，栈里**有且只有一个**搜索页，且它是栈底。
   *
   * 三种情形（`navPathStack` 在 `AppStorage` 里跨销毁存活，是栈的唯一真相）：
   *   1. `size === 0`（首次进来）→ 压栈。
   *   2. `size === 1`（页签切走又切回）→ **什么都不做**：栈里那个条目还在，
   *      `HdsNavigation` 会为它重建 destination，新的页面实例照样跑 `onReady`。
   *   3. `size > 1`（在详情页上切走页签，详情页留在栈里）→ 回栈底。
   *      不回的话再进来会直接看到那个陈旧的详情页。
   *
   * 为什么不做「无脑压栈 + 出栈时弹干净」：出栈的路（返回键 / 切页签 / 系统返回）分属两个模块，
   * 谁都可能漏；把不变式收在**唯一入口**这里，漏一条也不会堆栈。
   */
  private ensureResultPageAtBottom(): void {
    const size: number = this.searchPageContext.navPathStack.size();
    if (size === 0) {
      // 不传 param：关键字由搜索页自己持有（输入框在页内），没有跨层要带的东西
      this.searchPageContext.openPage({
        routerName: PageEnum.BREW_SEARCH_RESULT_VIEW,
      }, false);
      return;
    }
    if (size > 1) {
      // 无动画：此刻本组件的 HdsNavigation 还没建起来，动画没有承接者
      this.searchPageContext.popPageByIndex(0, false);
    }
  }

  build() {
    HdsNavigation(this.searchPageContext.navPathStack) {
      BrewSearchResultView()
    }
    .mode(NavigationMode.Stack)
    .hideBackButton(true)
    .hideTitleBar(true)
    .titleMode(HdsNavigationTitleMode.MINI)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .width(CommonConstants.FULL_PERCENT)
    .height(CommonConstants.FULL_PERCENT)
  }
}
