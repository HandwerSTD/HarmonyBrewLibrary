/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { CommonConstants } from '@ohos/common';

/**
 * AI 问答加载骨架（2026-11-26-ai-search-ask-spec §4.3，m01422 修订）。
 *
 * 结构是答案的「影子」：与 `BrewAiSearchAnswerView` 一样收进**同一张大卡**
 * （list_card 底 / level8 圆角 / clip），行骨架透明嵌入文流 —— 答案替换骨架
 * 时整卡不跳版。灰条范式沿用 D4 骨架卡（font_secondary @0.18）。
 *
 * 动画：1.2s 无限往返呼吸（pulse 0.55），走 `getUIContext().animateTo`
 * （全局 animateTo 已标 deprecated，项目内统一走 UIContext）。
 */
@Component
export struct BrewAiSearchSkeleton {
  /** 呼吸脉冲的目标透明度；aboutToAppear 里用无限往返动画驱动 */
  @State private pulse: number = 1;

  aboutToAppear(): void {
    this.getUIContext().animateTo({
      duration: 1200,
      curve: Curve.EaseInOut,
      iterations: -1,
      playMode: PlayMode.Alternate,
    }, () => {
      this.pulse = 0.55;
    });
  }

  /** 一根灰占位条 */
  @Builder
  BarBuilder(widthValue: Length, heightValue: number, radiusValue: number) {
    Row()
      .width(widthValue)
      .height(heightValue)
      .borderRadius(radiusValue)
      .backgroundColor($r('sys.color.font_secondary'))
      .opacity(0.18)
  }

  /** 一行占位：icon48 方块 + 双文字条 + 尾部热区位（透明底，融入大卡） */
  @Builder
  RowSkeletonBuilder() {
    Row({ space: $r('sys.float.padding_level3') }) {
      Row()
        .width(48)
        .height(48)
        .borderRadius($r('sys.float.corner_radius_level5'))
        .backgroundColor($r('sys.color.font_secondary'))
        .opacity(0.18)
      Column({ space: $r('sys.float.padding_level1') }) {
        this.BarBuilder(96, 14, 7)
        this.BarBuilder(140, 12, 6)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Blank()
      this.BarBuilder(48, 24, 12)
    }
    .width(CommonConstants.FULL_PERCENT)
    .alignItems(VerticalAlign.Center)
    .height($r('app.float.brew_package_row_height'))
    .padding({
      left: $r('sys.float.padding_level4'),
      right: $r('sys.float.padding_level8'),
    })
  }

  /** 一组「介绍段 + 行」的影子（intro 双条与行紧挨 level2，组间 level4） */
  @Builder
  PickGroupSkeletonBuilder() {
    Column() {
      Column({ space: $r('sys.float.padding_level2') }) {
        this.BarBuilder('55%', 14, 6)
        this.BarBuilder('38%', 14, 6)
      }
      .alignItems(HorizontalAlign.Start)
      .width(CommonConstants.FULL_PERCENT)
      .padding({ left: $r('sys.float.padding_level4'), right: $r('sys.float.padding_level4') })
      .margin({ top: $r('sys.float.padding_level4'), bottom: $r('sys.float.padding_level2') })
      this.RowSkeletonBuilder()
    }
    .width(CommonConstants.FULL_PERCENT)
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    // 一张大卡承载全文影子：与 AnswerView 同款外壳（padding level6 / list_card / level8 圆角 / clip）
    Column() {
      // lead 双条（总起段影子，正文行高）
      Column({ space: $r('sys.float.padding_level2') }) {
        this.BarBuilder('70%', 14, 7)
        this.BarBuilder('40%', 14, 7)
      }
      .alignItems(HorizontalAlign.Start)
      .width(CommonConstants.FULL_PERCENT)
      .padding({ left: $r('sys.float.padding_level4'), right: $r('sys.float.padding_level4') })
      .margin({ bottom: $r('sys.float.padding_level4') })

      this.PickGroupSkeletonBuilder()
      this.PickGroupSkeletonBuilder()
    }
    .width(CommonConstants.FULL_PERCENT)
    .alignItems(HorizontalAlign.Start)
    .padding($r('sys.float.padding_level6'))
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .borderRadius($r('sys.float.corner_radius_level8'))
    .clip(true)
    .opacity(this.pulse)
  }
}
