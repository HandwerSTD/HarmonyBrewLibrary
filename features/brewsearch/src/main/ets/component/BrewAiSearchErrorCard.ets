/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { CommonConstants } from '@ohos/common';

/**
 * AI 问答错误卡（2026-11-26-ai-search-ask-spec §4.5）。
 *
 * E4（格式不符）/ E5（内容拒绝）时停在结果区：诊断细节直达 UI（沿用 D2
 * 排查记录），给两个出口——重试（重发 ask）/ 用本地搜索（描边次按钮，
 * 语义上明确「放弃 AI、走普通搜索」而不是「AI 挂了」）。
 *
 * 主按钮紫渐变与 pill on 态同源（D4 'ai' 身份）；E1/E2/E3 不走此卡
 * （AiFindVM 已自动降级本地搜索 + 通知条，G6）。
 */
@Component
export struct BrewAiSearchErrorCard {
  /** 诊断细节（errorDetail；空串时隐藏该行） */
  @Prop errorDetail: string = '';
  /** 重试：重发 AI 提问（回到 loading 骨架） */
  handleRetry?: () => void;
  /** 用本地搜索：放弃 AI，走普通搜索链路 */
  handleUseLocal?: () => void;

  @Builder
  RetryButtonBuilder() {
    Row({ space: $r('sys.float.padding_level2') }) {
      SymbolGlyph($r('sys.symbol.arrow_clockwise'))
        .fontSize($r('sys.float.Body_M'))
        .fontColor([$r('sys.color.font_on_primary')])
      Text($r('app.string.ai_search_retry'))
        .fontSize($r('sys.float.Body_M'))
        .fontColor($r('sys.color.font_on_primary'))
        .fontWeight(FontWeight.Medium)
    }
    .justifyContent(FlexAlign.Center)
    .padding({
      left: $r('sys.float.padding_level10'),
      right: $r('sys.float.padding_level10'),
      top: $r('sys.float.padding_level4'),
      bottom: $r('sys.float.padding_level4'),
    })
    .borderRadius(CommonConstants.FULL_PERCENT)
    .linearGradient({
      angle: 90,
      colors: [
        [$r('app.color.brew_ai_pill_start'), 0.0],
        [$r('app.color.brew_ai_pill_end'), 1.0],
      ],
    })
    .clickEffect({ level: ClickEffectLevel.MIDDLE })
    .onClick(() => {
      this.handleRetry?.();
    })
  }

  @Builder
  UseLocalButtonBuilder() {
    Text($r('app.string.ai_search_use_local'))
      .fontSize($r('sys.float.Body_M'))
      .fontColor($r('sys.color.font_secondary'))
      .padding({
        left: $r('sys.float.padding_level10'),
        right: $r('sys.float.padding_level10'),
        top: $r('sys.float.padding_level4'),
        bottom: $r('sys.float.padding_level4'),
      })
      .borderRadius(CommonConstants.FULL_PERCENT)
      .backgroundColor($r('sys.color.comp_background_primary'))
      .clickEffect({ level: ClickEffectLevel.MIDDLE })
      .onClick(() => {
        this.handleUseLocal?.();
      })
  }

  build() {
    Column({ space: $r('sys.float.padding_level6') }) {
      Row({ space: $r('sys.float.padding_level2') }) {
        SymbolGlyph($r('sys.symbol.lightbulb'))
          .fontSize($r('sys.float.Title_S'))
          .fontColor([$r('sys.color.icon_secondary')])
        Text($r('app.string.ai_search_failed'))
          .fontSize($r('sys.float.Title_S'))
          .fontColor($r('sys.color.font_primary'))
          .fontWeight(FontWeight.Medium)
      }
      if (this.errorDetail.length > 0) {
        Text(this.errorDetail)
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_tertiary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width(CommonConstants.FULL_PERCENT)
      }
      Row({ space: $r('sys.float.padding_level6') }) {
        this.RetryButtonBuilder()
        this.UseLocalButtonBuilder()
      }
      .justifyContent(FlexAlign.Center)
    }
    .width(CommonConstants.FULL_PERCENT)
    .alignItems(HorizontalAlign.Center)
    .padding({
      left: $r('sys.float.padding_level8'),
      right: $r('sys.float.padding_level8'),
      top: $r('sys.float.padding_level8'),
      bottom: $r('sys.float.padding_level10'),
    })
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .borderRadius($r('sys.float.corner_radius_level8'))
  }
}
