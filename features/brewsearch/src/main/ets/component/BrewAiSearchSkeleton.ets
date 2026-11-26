/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { CommonConstants } from '@ohos/common';

/**
 * AI 问答加载骨架（2026-11-26-ai-search-ask-spec §4.3）。
 *
 * 结构是答案的「影子」：lead 双条 + （intro 条 + 行骨架）×2 组，
 * 高度 ≈ 真实答案的首屏，等答案替换时不跳版。灰条范式沿用 D4 骨架卡
 * （font_secondary @0.18），行壳用 list_card 底与真实行同源。
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

  /** 一行占位：icon48 方块 + 双文字条 + 尾部热区位 */
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
      left: $r('sys.float.padding_level6'),
      right: $r('sys.float.padding_level8'),
    })
  }

  @Builder
  PickGroupSkeletonBuilder() {
    Column({ space: $r('sys.float.padding_level2') }) {
      Column({ space: $r('sys.float.padding_level2') }) {
        this.BarBuilder('55%', 14, 6)
        this.BarBuilder('38%', 14, 6)
      }
      .alignItems(HorizontalAlign.Start)
      .width(CommonConstants.FULL_PERCENT)
      .padding({ left: $r('sys.float.padding_level6'), right: $r('sys.float.padding_level6') })
      Column() {
        this.RowSkeletonBuilder()
      }
      .width(CommonConstants.FULL_PERCENT)
      .backgroundColor($r('sys.color.comp_background_list_card'))
      .borderRadius($r('sys.float.corner_radius_level8'))
    }
    .width(CommonConstants.FULL_PERCENT)
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column({ space: $r('sys.float.padding_level8') }) {
      // lead 双条（总起段影子）
      Column({ space: $r('sys.float.padding_level2') }) {
        this.BarBuilder('70%', 16, 8)
        this.BarBuilder('40%', 14, 7)
      }
      .alignItems(HorizontalAlign.Start)
      .width(CommonConstants.FULL_PERCENT)
      .padding({ left: $r('sys.float.padding_level6'), right: $r('sys.float.padding_level6') })

      this.PickGroupSkeletonBuilder()
      this.PickGroupSkeletonBuilder()
    }
    .width(CommonConstants.FULL_PERCENT)
    .alignItems(HorizontalAlign.Start)
    .opacity(this.pulse)
  }
}
