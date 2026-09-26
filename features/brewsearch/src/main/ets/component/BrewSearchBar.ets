/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { CommonConstants } from '@ohos/common';
import { BREW_SEARCH_BAR_HEIGHT } from '../constant/BrewSearchConstants';

/**
 * 搜索页的输入框行（放大镜 + 输入框 + 「搜索」）。
 *
 * 放在**搜索页标题栏的 `bottomBuilder` 里、chips 行之上**：标题栏是浮层，输入框因此常驻顶部
 * 不随结果滚动，而且与 chips 同处一个已被验证可交互的浮层区域。
 *
 * ## 为什么它不是「侧边栏搜索框」改个位置
 *
 * 原先的形态是侧边栏里一个可展开的框 + `bindPopup` 的历史/发现浮层，真机上浮层会把焦点
 * 从输入框拿走（`focusable` 的浮层是焦点作用域，从作用域外 `requestFocus` 抢不回来），
 * 面板一拉起就打字没反应。需求方据此改成**页签形态**：输入框与历史/发现都在页面里，
 * 没有跨层焦点问题，也就不需要「回焦兜底」这类补丁。
 *
 * ## 状态归页面，本组件不自持关键字
 *
 * `keyword` 是 `@Prop`（单向），输入事件走 `onInput` 回调 —— 页面持有唯一的 `@State`
 * 并决定何时搜索。**不用 `@Link` + `@Watch`**：那样「点建议词填入」与「用户打字」会走同一条
 * 通路，页面就得靠「这个值是不是我自己刚设的」去区分两者（那是循环论证）。
 * 现在搜索是**显式触发**的（回车 / 点「搜索」），这条区分就是页面上的 `appliedKeyword`。
 */
@Component
export struct BrewSearchBar {
  /** 关键字（由页面持有；本组件只负责显示与上报输入） */
  @Prop @Require keyword: string;
  /**
   * 每次输入：**只上报内容**，页面据此更新显示；不触发搜索。
   *
   * 页面在没有真搜索时不会碰到引擎（搜索必须由回车 / 「搜索」按钮 / 建议项发起），
   * 所以这个回调不需要防抖，也不会因为输入快而把引擎抬起来跑一次全量匹配。
   */
  onInput: (value: string) => void = (_value: string) => {
  };
  /** 立即搜索：回车（`EnterKeyType.Search`）/ 点「搜索」 */
  onSearch: () => void = () => {
  };

  build() {
    Row() {
      SymbolGlyph($r('sys.symbol.magnifyingglass'))
        .fontSize($r('sys.float.Body_L'))
        .fontColor([$r('sys.color.icon_secondary')])
        .margin({ right: $r('sys.float.padding_level4') })
      TextInput({ text: this.keyword, placeholder: $r('app.string.brew_search_placeholder') })
        .placeholderFont({ size: $r('sys.float.Body_M') })
        .fontSize($r('sys.float.Body_M'))
        .fontColor($r('sys.color.font_primary'))
        .placeholderColor($r('sys.color.font_tertiary'))
        .backgroundColor(Color.Transparent)
        .padding(0)
        .layoutWeight(1)
        .enterKeyType(EnterKeyType.Search)
        .onChange((value: string) => {
          this.onInput(value);
        })
        .onSubmit(() => {
          this.onSearch();
        })
      // 「搜索」按钮只在有字时出现：空框上挂一个按下去没反应的按钮是死交互
      if (this.keyword.length > 0) {
        Divider()
          .vertical(true)
          .height($r('sys.float.padding_level8'))
          .color($r('sys.color.comp_divider'))
          .margin({ left: $r('sys.float.padding_level4'), right: $r('sys.float.padding_level4') })
        Text($r('app.string.brew_search_action'))
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('sys.color.font_emphasize'))
          .onClick(() => {
            this.onSearch();
          })
      }
    }
    .width(CommonConstants.FULL_PERCENT)
    .height(BREW_SEARCH_BAR_HEIGHT)
    .alignItems(VerticalAlign.Center)
    .padding({
      left: $r('sys.float.padding_level4'),
      right: $r('sys.float.padding_level4'),
    })
    .backgroundColor($r('sys.color.comp_background_tertiary'))
    .borderRadius($r('sys.float.corner_radius_level4'))
  }
}
