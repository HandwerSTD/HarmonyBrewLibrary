/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { CommonConstants } from '@ohos/common';
import { DISCOVER_PREVIEW_COUNT } from './BrewDiscoverBoardCard';

/**
 * AI 发现流（D4）首载/换一批骨架 · 榜卡形。
 *
 * **几何与 `BrewDiscoverBoardCard` 逐项对齐**：Hero 112vp（brew_discover_hero_height）
 * + 预览行 ×DISCOVER_PREVIEW_COUNT（行高、icon48、右按钮位同 `BrewDiscoverRow`），
 * 外壳同款 primary 底 / level8 圆角 / clip —— 换骨架时卡高丝丝不动（spec §4.2）。
 *
 * Hero 用**真的 'ai' 渐变**（降一点存在感）而不是纯灰：榜卡的 Hero 就是它的身份，
 * 纯灰会像「一张加载失败的榜」，而这里用户等的是 AI 在生成 —— 保留 AI 的视觉锚点。
 * 行区是灰占位（font_secondary 低透明度），整卡 1.2s 呼吸脉冲与骨架大图卡同频。
 */
@Component
export struct BrewDiscoverAiSkeletonBoardCard {
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

  /** Hero 骨架：真渐变打底 + 左下两根标题占位条（kindLabel + title 的位置） */
  @Builder
  HeroSkeletonBuilder() {
    Stack({ alignContent: Alignment.BottomStart }) {
      Column()
        .width(CommonConstants.FULL_PERCENT)
        .height(CommonConstants.FULL_PERCENT)
        .linearGradient({
          angle: 180,
          colors: [
            [$r('app.color.brew_board_color_ai_start'), 0.0],
            [$r('app.color.brew_board_color_ai_end'), 1.0],
          ],
        })
        .opacity(0.55)
      Column({ space: $r('sys.float.padding_level1') }) {
        this.BarBuilder(64, 12, 6)
        this.BarBuilder('46%', 18, 6)
      }
      .alignItems(HorizontalAlign.Start)
      .padding({ left: $r('sys.float.padding_level6'), bottom: $r('sys.float.padding_level6') })
    }
    .width(CommonConstants.FULL_PERCENT)
    .height($r('app.float.brew_discover_hero_height'))
  }

  /** 一行占位：icon48 方块 + 双文字条 + 右按钮位 */
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
      Row()
        .width(48)
        .height(24)
        .borderRadius(CommonConstants.FULL_PERCENT)
        .backgroundColor($r('sys.color.font_secondary'))
        .opacity(0.18)
    }
    .width(CommonConstants.FULL_PERCENT)
    .alignItems(VerticalAlign.Center)
    .height($r('app.float.brew_package_row_height'))
    .padding({
      left: $r('sys.float.padding_level6'),
      right: $r('sys.float.padding_level8'),
    })
  }

  build() {
    Column() {
      this.HeroSkeletonBuilder()
      Column() {
        ForEach([0, 1, 2, 3, 4], (rowIndex: number) => {
          this.RowSkeletonBuilder()
          if (rowIndex < DISCOVER_PREVIEW_COUNT - 1) {
            // 行间细分隔线，颜色与真卡 divider 同源（压灰一档保证可见）
            Row()
              .width(CommonConstants.FULL_PERCENT)
              .height(1)
              .backgroundColor($r('sys.color.comp_background_tertiary'))
          }
        }, (rowIndex: number) => `ai_board_skel_row_${rowIndex}`)
      }
      .width(CommonConstants.FULL_PERCENT)
      .alignItems(HorizontalAlign.Start)
      .padding({ top: $r('sys.float.padding_level2'), bottom: $r('sys.float.padding_level4') })
    }
    .width(CommonConstants.FULL_PERCENT)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('sys.color.comp_background_primary'))
    .borderRadius($r('sys.float.corner_radius_level8'))
    .clip(true)
    .opacity(this.pulse)
  }
}
