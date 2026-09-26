/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { CommonConstants } from '@ohos/common';

/**
 * 榜单卡片的「大图」区 —— 代码画的视觉块，**不用任何图片文件**。
 *
 * 照搬组件页 CodeLabCard 的结构（`docs/brew-marketplace-content-plan.md` 里那张
 * 「图库选择器 / PhotoPicker / 安全选择图库」卡）：
 *   Stack(Bottom) { 铺满的视觉层 ; 底部压字（小字 kind + 粗体 title） }
 *
 * 唯一替换掉的东西是那层 `ImageComponent`：
 *   - 卡片标记色渐变（本模块 color.json 的 start/end 两个值）
 *   - 右上角一个低透明度的大号 symbol 当水印，给纯色块一点纹理
 * 原因：Homebrew 既没有包图标也没有横幅素材（API 无 icon 字段、appcasks 实测 404），
 * 与其渲染一块空图，不如用代码画一块。文字压的渐变末端都取得足够深，白字对比度有保证。
 */
@Component
export struct BrewDiscoverHero {
  @Prop @Require kindLabel: ResourceStr;
  @Prop @Require title: ResourceStr;
  @Prop @Require symbol: Resource;
  @Prop @Require colorStart: Resource;
  @Prop @Require colorEnd: Resource;

  /** 底部压字：规格与 CodeLabCard 的 (title, subTitle) 一致 */
  @Builder
  CaptionBuilder() {
    Column({ space: $r('sys.float.padding_level2') }) {
      Text(this.kindLabel)
        .fontSize($r('sys.float.Body_S'))
        .fontColor($r('sys.color.font_on_secondary'))
        .fontWeight(FontWeight.Medium)
        .maxLines(1)
        .ellipsisMode(EllipsisMode.END)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.title)
        .fontSize($r('sys.float.Title_M'))
        .fontColor($r('sys.color.font_on_primary'))
        .fontWeight(FontWeight.Bold)
        .maxLines(1)
        .ellipsisMode(EllipsisMode.END)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .alignItems(HorizontalAlign.Start)
    .width(CommonConstants.FULL_PERCENT)
    .padding({
      left: $r('sys.float.padding_level6'),
      right: $r('sys.float.padding_level6'),
      bottom: $r('sys.float.padding_level6'),
    })
  }

  build() {
    // 外层 Stack 对齐到右上角放水印；内层 Stack 底部对齐放文字 —— 一层 Stack 只能有一个对齐方式
    Stack({ alignContent: Alignment.TopEnd }) {
      Stack({ alignContent: Alignment.BottomStart }) {
        Column()
          .width(CommonConstants.FULL_PERCENT)
          .height(CommonConstants.FULL_PERCENT)
          .linearGradient({
            angle: 180,
            colors: [[this.colorStart, 0.0], [this.colorEnd, 1.0]],
          })
        this.CaptionBuilder()
      }
      .width(CommonConstants.FULL_PERCENT)
      .height(CommonConstants.FULL_PERCENT)

      SymbolGlyph(this.symbol)
        .fontSize($r('app.float.brew_discover_hero_symbol_size'))
        .fontColor([$r('sys.color.font_on_primary')])
        .opacity(0.16)
        .margin({
          top: $r('sys.float.padding_level4'),
          right: $r('sys.float.padding_level6'),
        })
    }
    .width(CommonConstants.FULL_PERCENT)
    .height($r('app.float.brew_discover_hero_height'))
    .clip(true)
  }
}
