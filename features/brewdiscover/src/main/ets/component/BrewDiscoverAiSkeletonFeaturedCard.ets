/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { CommonConstants } from '@ohos/common';

/**
 * AI 发现流（D4）首载骨架 · 大图卡形。
 *
 * **几何与 `BrewDiscoverFeaturedCard` 逐项对齐**（400vp 高 / level8 圆角 / clip /
 * 底部内容块 176vp：徽章行 + 描述大字两行 + icon48 行 + 40vp 圆钮）—— AI 区换骨架
 * 时卡片尺寸一丝不动，feed 不会跳（spec §4.2 的核心要求）。分层也照抄真卡：
 * Stack(BottomStart){ 背景层(整卡灰底 + 上部居中圆形) + 内容层(右上徽章 + 底部块) }。
 *
 * 占位条：底 comp_background_tertiary，条用 font_secondary 低透明度（深浅色模式
 * 都成立）。整卡 1.2s 呼吸脉冲（iterations -1 往返）—— 卡住不动会像「加载完成但
 * 内容是灰的」，脉冲是在告诉用户「这里正在生成」。
 */
@Component
export struct BrewDiscoverAiSkeletonFeaturedCard {
  /** 呼吸脉冲的目标透明度；aboutToAppear 里用无限往返动画驱动 */
  @State private pulse: number = 1;

  aboutToAppear(): void {
    // UIContext.animateTo 是项目惯例（全局 animateTo 已标 deprecated）
    this.getUIContext().animateTo({
      duration: 1200,
      curve: Curve.EaseInOut,
      iterations: -1,
      playMode: PlayMode.Alternate,
    }, () => {
      this.pulse = 0.55;
    });
  }

  /** 一根灰占位条。宽支持百分比（Length），不同槽位条宽不同，骨架才像「有内容」 */
  @Builder
  BarBuilder(widthValue: Length, heightValue: number, radiusValue: number) {
    Row()
      .width(widthValue)
      .height(heightValue)
      .borderRadius(radiusValue)
      .backgroundColor($r('sys.color.font_secondary'))
      .opacity(0.18)
  }

  /** 背景层：整卡灰底 + 上部视觉区居中的圆形占位（呼应真卡 140vp 裸 symbol） */
  @Builder
  ArtSkeletonBuilder() {
    Stack() {
      Column()
        .width(CommonConstants.FULL_PERCENT)
        .height(CommonConstants.FULL_PERCENT)
        .backgroundColor($r('sys.color.comp_background_tertiary'))
      Stack() {
        Column()
          .width(140)
          .height(140)
          .borderRadius(CommonConstants.FULL_PERCENT)
          .backgroundColor($r('sys.color.font_secondary'))
          .opacity(0.12)
      }
      .width(CommonConstants.FULL_PERCENT)
      .height(CommonConstants.FULL_PERCENT)
      .alignContent(Alignment.Top)
      .padding({ top: $r('app.float.brew_featured_art_symbol_top') })
    }
    .width(CommonConstants.FULL_PERCENT)
    .height(CommonConstants.FULL_PERCENT)
  }

  /** 底部内容块骨架：徽章行 + 大字两行 + 行条（icon48 + 双行条 + 40vp 圆钮） */
  @Builder
  CaptionSkeletonBuilder() {
    Column({ space: $r('sys.float.padding_level2') }) {
      this.BarBuilder(120, 12, 6)
      this.BarBuilder('90%', 20, 6)
      this.BarBuilder('64%', 20, 6)

      // 行条：左 icon 方块 + 两根文字条 + 右圆钮，行高与真卡 HdsListItemCard 行同量级
      Row({ space: $r('sys.float.padding_level3') }) {
        Row()
          .width(48)
          .height(48)
          .borderRadius($r('sys.float.corner_radius_level5'))
          .backgroundColor($r('sys.color.font_secondary'))
          .opacity(0.18)
        Column({ space: $r('sys.float.padding_level1') }) {
          this.BarBuilder(96, 14, 7)
          this.BarBuilder(72, 12, 6)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Blank()
        Row()
          .width($r('app.float.brew_discover_arrow_size'))
          .height($r('app.float.brew_discover_arrow_size'))
          .borderRadius(CommonConstants.FULL_PERCENT)
          .backgroundColor($r('sys.color.font_secondary'))
          .opacity(0.18)
      }
      .width(CommonConstants.FULL_PERCENT)
      .alignItems(VerticalAlign.Center)
      .padding({
        left: $r('sys.float.padding_level4'),
        right: $r('sys.float.padding_level4'),
      })
    }
    .width(CommonConstants.FULL_PERCENT)
    .height($r('app.float.brew_discover_featured_content_height'))
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.End)
    .padding({ left: $r('sys.float.padding_level6'), right: $r('sys.float.padding_level6') })
  }

  build() {
    Stack({ alignContent: Alignment.BottomStart }) {
      // ① 背景层：灰底 + 图画占位
      this.ArtSkeletonBuilder()

      // ② 内容层：上部只留右上徽章占位（真卡增速徽章的位置），下部是内容块骨架
      Column() {
        Row() {
          Blank()
          Row()
            .width(56)
            .height(20)
            .borderRadius(CommonConstants.FULL_PERCENT)
            .backgroundColor($r('sys.color.font_secondary'))
            .opacity(0.18)
        }
        .width(CommonConstants.FULL_PERCENT)
        .layoutWeight(1)
        .alignItems(VerticalAlign.Top)
        .padding({
          left: $r('sys.float.padding_level6'),
          right: $r('sys.float.padding_level6'),
          top: $r('sys.float.padding_level4'),
        })

        this.CaptionSkeletonBuilder()
      }
      .width(CommonConstants.FULL_PERCENT)
      .height(CommonConstants.FULL_PERCENT)
      .alignItems(HorizontalAlign.Start)
    }
    .width(CommonConstants.FULL_PERCENT)
    .height($r('app.float.brew_discover_featured_height'))
    .borderRadius($r('sys.float.corner_radius_level8'))
    .clip(true)
    .opacity(this.pulse)
  }
}
