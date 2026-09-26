/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { CommonConstants } from '@ohos/common';
import { BrewSearchVM } from '../viewmodel/BrewSearchVM';
import { BREW_SEARCH_CHIP_SPACE } from '../constant/BrewSearchConstants';

/**
 * 「搜索历史 + 搜索发现」，渲染在搜索页的**未提交态**（输入框里的词还没被执行）。
 *
 * 两块都是真数据（本轮变更）：历史由 VM 从 Preference 读（用户真搜过的词），
 * 发现是设备端目录里的真实热门包；两者都可能为空（首次安装 / 断网 / 刚清空历史），
 * 所以两块各自带一行空态文案。**不再有写死的词组**。
 *
 * 两个标题行**各写各的 `@Builder，不参数化**：标题右侧的动作图标与回调都不同
 * （历史是清空+折叠，发现是换一批）。ArkUI 的 @Builder 传数组/闭包参数是能编译的，
 * 但本项目已经因为「组件/回调的传递方式」踩过坑（handover §9.8），
 * 两条各三行的标题行不值得为省那几行引入那个风险。
 */
@Component
export struct BrewSearchSuggestions {
  /** 点历史 chip 或发现项：把词交给页面（页面填进输入框并立即搜） */
  pickWord: (word: string) => void = (_word: string) => {
  };
  // 历史与发现在单例 VM 里（会话级）：浮层与结果页必须看到同一份，
  // 否则会出现「在浮层里清空历史、结果页还显示旧的」
  @State history: string[] = [];
  @State discoveries: string[] = [];
  @State historyCollapsed: boolean = false;
  private viewModel: BrewSearchVM = BrewSearchVM.getInstance();

  aboutToAppear(): void {
    this.syncFromViewModel();
  }

  /** 改动 VM 之后必须把值取回自己的 @State，否则不重渲染（VM 是普通单例，不是 @State） */
  private syncFromViewModel(): void {
    this.history = this.viewModel.history();
    this.discoveries = this.viewModel.discoveries();
  }

  /** 分区标题字号：`Subtitle_L`。比列表项标题（`Body_L`）大一档、比页面标题（`Title_S`）小一档 */
  private titleSize(): Resource {
    return $r('sys.float.Subtitle_L');
  }

  /** 可点行的高度（历史 chip 与发现项共用） */
  private rowHeight(): Resource {
    return $r('app.float.brew_search_suggestion_height');
  }

  /** 分区标题行的高度。**不复用 `rowHeight()`**：那是可点行的高度（48），拿它当标题高会让标题上下各空出一大截 */
  private headerHeight(): Resource {
    return $r('app.float.brew_search_section_header_height');
  }

  /** 标题行：左边标题、右边动作图标。标题行本身不接收任何参数（见结构体注释） */
  @Builder
  HistoryHeaderBuilder() {
    Row() {
      Text($r('app.string.brew_search_history'))
        .fontSize(this.titleSize())
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
      Blank()
      // 没有历史时不摆图标：垃圾桶/折叠箭头按下去都没有作用，是死交互
      // （与 `BrewSearchBar` 只在有字时才显示「搜索」同一个口径）
      if (this.history.length > 0) {
        SymbolGlyph($r('sys.symbol.trash'))
          .fontSize($r('sys.float.Title_M'))
          .fontColor([$r('sys.color.icon_secondary')])
          .margin({ left: $r('sys.float.padding_level4') })
          .onClick(() => {
            this.viewModel.clearHistory();
            this.syncFromViewModel();
          })
        SymbolGlyph(this.historyCollapsed ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_up'))
          .fontSize($r('sys.float.Title_M'))
          .fontColor([$r('sys.color.icon_secondary')])
          .margin({ left: $r('sys.float.padding_level4') })
          .onClick(() => {
            this.historyCollapsed = !this.historyCollapsed;
          })
      }
    }
    .width(CommonConstants.FULL_PERCENT)
    .height(this.headerHeight())
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  DiscoveryHeaderBuilder() {
    Row() {
      Text($r('app.string.brew_search_discovery'))
        .fontSize(this.titleSize())
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
      Blank()
      // 池子为空（目录还没到）时不给「换一批」：换也还是空，按下去没反应就是死交互
      if (this.discoveries.length > 0) {
        SymbolGlyph($r('sys.symbol.arrow_clockwise'))
          .fontSize($r('sys.float.Title_M'))
          .fontColor([$r('sys.color.icon_secondary')])
          .margin({ left: $r('sys.float.padding_level4') })
          .onClick(() => {
            // 「换一批」：在真实热门池内轮换
            this.viewModel.rotateDiscovery();
            this.syncFromViewModel();
          })
      }
    }
    .width(CommonConstants.FULL_PERCENT)
    .height(this.headerHeight())
    .alignItems(VerticalAlign.Center)
    // 与上一区（历史 chips）拉开距离：两个分区贴在一起会看不出是两块内容。
    // 历史 chips 自身已有 `BREW_SEARCH_CHIP_SPACE` 的下边距，这里再给一档
    .margin({ top: $r('sys.float.padding_level16') })
  }

  @Builder
  HistoryChipsBuilder() {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(this.history, (word: string) => {
        Text(word)
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('sys.color.font_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          .borderRadius($r('sys.float.corner_radius_level4'))
          .padding({
            left: $r('sys.float.padding_level8'),
            right: $r('sys.float.padding_level8'),
            top: $r('sys.float.padding_level4'),
            bottom: $r('sys.float.padding_level4'),
          })
          .margin({ right: BREW_SEARCH_CHIP_SPACE, bottom: BREW_SEARCH_CHIP_SPACE })
          .onClick(() => {
            this.pickWord(word);
          })
      }, (word: string) => word)
    }
    .width(CommonConstants.FULL_PERCENT)
  }

  @Builder
  DiscoveryItemBuilder(word: string) {
    Row() {
      SymbolGlyph($r('sys.symbol.magnifyingglass'))
        .fontSize($r('sys.float.Body_M'))
        .fontColor([$r('sys.color.icon_secondary')])
        .margin({ right: $r('sys.float.padding_level6') })
      Text(word)
        .fontSize($r('sys.float.Body_M'))
        .fontColor($r('sys.color.font_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Blank()
    }
    .width('50%')
    .height(this.rowHeight())
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.pickWord(word);
    })
  }

  build() {
    Column() {
      this.HistoryHeaderBuilder();
      if (this.historyCollapsed || this.history.length === 0) {
        Text($r('app.string.brew_search_empty_history'))
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('sys.color.font_tertiary'))
          .width(CommonConstants.FULL_PERCENT)
          .padding({ bottom: $r('sys.float.padding_level4') })
      } else {
        this.HistoryChipsBuilder();
      }
      this.DiscoveryHeaderBuilder();
      if (this.discoveries.length === 0) {
        // 目录还没到（首次安装 / 断网且盘上没目录）：显示空态，**不回落写死的词** ——
        // 那些词在 Homebrew 里一个都不存在，点下去必然是空结果，比空着更糟。
        Text($r('app.string.brew_search_empty_discovery'))
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('sys.color.font_tertiary'))
          .width(CommonConstants.FULL_PERCENT)
          .padding({ bottom: $r('sys.float.padding_level4') })
      } else {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.discoveries, (word: string) => {
            this.DiscoveryItemBuilder(word);
          }, (word: string) => word)
        }
        .width(CommonConstants.FULL_PERCENT)
      }
    }
    .width(CommonConstants.FULL_PERCENT)
    .alignItems(HorizontalAlign.Start)
  }
}
