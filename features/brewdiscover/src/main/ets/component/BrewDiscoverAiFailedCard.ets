/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { CommonConstants } from '@ohos/common';
import { AI_BOARD, BrewBoardStyle } from '../model/BrewBoardStyle';
import { BrewDiscoverHero } from './BrewDiscoverHero';

/**
 * AI 发现流（D4）失败占位卡（E2 网络 / E3 超时 / E4 格式 / E5 被拒）。
 *
 * E1（无 Key）不走到这里 —— 它是 hidden：AI 区整段不出现（G6，不引导配 Key）。
 *
 * 结构 = 榜卡的前半：'ai' 渐变 Hero（复用 `BrewDiscoverHero`，标题 brew_discover_ai_failed）
 * + 一小段正文（AI 生成失败的具体原因，行数压住，演示时可看、用户可忽略）+ 重试按钮
 * （brew_discover_ai_retry，'ai' 渐变终点色 pill，白字 5.70:1）。
 * 点击重试 -> VM.retryAi()：回 HIDDEN 重走闸门（失败不写缓存，MISS 会真重打）。
 */
@Component
export struct BrewDiscoverAiFailedCard {
  /** 失败原因（AiError.message，已 sanitize）。空串就不渲染这一行 */
  errorText: string = '';
  handleRetry?: () => void;

  @Builder
  RetryButtonBuilder() {
    Row({ space: $r('sys.float.padding_level2') }) {
      SymbolGlyph($r('sys.symbol.arrow_clockwise'))
        .fontSize($r('sys.float.Body_M'))
        .fontColor([$r('sys.color.font_on_primary')])
      Text($r('app.string.brew_discover_ai_retry'))
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
    .backgroundColor($r('app.color.brew_board_color_ai_end'))
    .clickEffect({ level: ClickEffectLevel.MIDDLE })
    .onClick(() => {
      this.handleRetry?.();
    })
  }

  build() {
    Column() {
      BrewDiscoverHero({
        kindLabel: $r('app.string.brew_discover_ai_badge'),
        title: $r('app.string.brew_discover_ai_failed'),
        symbol: BrewBoardStyle.symbolOf(AI_BOARD),
        colorStart: BrewBoardStyle.colorStartOf(AI_BOARD),
        colorEnd: BrewBoardStyle.colorEndOf(AI_BOARD),
      })
      Column({ space: $r('sys.float.padding_level6') }) {
        // 具体失败原因：小字、两行截断。演示场景能看出 E 几；正式场景用户直接点重试
        if (this.errorText.length > 0) {
          Text(this.errorText)
            .fontSize($r('sys.float.Body_S'))
            .fontColor($r('sys.color.font_tertiary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width(CommonConstants.FULL_PERCENT)
        }
        this.RetryButtonBuilder()
      }
      .width(CommonConstants.FULL_PERCENT)
      .alignItems(HorizontalAlign.Center)
      .padding({
        left: $r('sys.float.padding_level8'),
        right: $r('sys.float.padding_level8'),
        top: $r('sys.float.padding_level8'),
        bottom: $r('sys.float.padding_level10'),
      })
    }
    .width(CommonConstants.FULL_PERCENT)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('sys.color.comp_background_primary'))
    .borderRadius($r('sys.float.corner_radius_level8'))
    .clip(true)
  }
}
