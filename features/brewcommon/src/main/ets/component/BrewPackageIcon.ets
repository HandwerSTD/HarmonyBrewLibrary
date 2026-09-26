/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { BrewKind } from '../model/BrewModels';
import {
  BREW_PACKAGE_ICON,
  BREW_PACKAGE_ICON_BORDER_WIDTH,
  BREW_PACKAGE_ICON_BOX_BACKGROUND,
  BREW_PACKAGE_ICON_RATIO,
  BrewIconSize,
  brewKindIconColor,
} from '../constant/BrewIconStyle';

/**
 * 包图标基底：中性实底圆角方块 + 类型色 symbol + 同色描边。
 *
 * 替代原先四个各写一份的「包名首字母方块」（_BrewMonogram_ / _BrewDiscoverRowIcon_ /
 * _BrewDiscoverFeaturedIcon_ / _BrewDetailHero_ 的内联 Text）。四个渲染点现在都走这一个组件，
 * 字形、比例、配色都从 `BrewIconStyle` 取 —— 美工换图标/换配色只改那里（见该文件注释）。
 *
 * 为什么用 symbol 而不是首字母：字母块原本是「Homebrew 没有图标素材」时的兜底做法，
 * 但它承载的信息只有包名的第一个字母，6000+ 个包里大量撞首字母（`c` 开头的有几百个），
 * 几乎等于没有信息。换成统一 symbol 后，方块的**颜色**成了唯一有意义的信号
 * （formula / cask），语义反而更干净。
 *
 * **必须是独立的 @Component，不能把 Column 内联进 `PrefixCustomBuilder` 的箭头里**：
 * `HdsListItemCard` 的前缀槽位是拿 builder 根节点的**测量宽度**给正文留位的 ——
 *   内联 Column      -> 量到的是里面 SymbolGlyph 的宽，正文从方块原点开始排，方块盖住标题
 *   独立 @Component  -> 量到方块边长，正文正确让位
 * 组件页的 `ComponentIcon` 也是独立 @Component，这里与它保持一致。
 *
 * **成员名必须避开 ArkUI 内置属性**：`CustomComponent` 上已经带了全套通用属性方法，
 * 声明同名的成员会报
 * `Property 'x' in type 'BrewPackageIcon' is not assignable to the same property in base type 'CustomComponent'`。
 * 本项目实测：叫 `size` 直接编译失败（撞 `size(value: SizeOptions)`）；因此几何参数统一加 `box` 前缀
 * （`boxSize` / `boxRadius` / `boxMarginStart` / `boxMarginEnd`）。
 */
@Component
export struct BrewPackageIcon {
  /** 包类型，决定符号颜色 */
  @Prop @Require kind: BrewKind;

  /** 方块边长（vp）。符号字号 = `boxSize * BREW_PACKAGE_ICON_RATIO`。档位见 `BrewIconSize` */
  boxSize: number = BrewIconSize.ROW;

  /** 方块圆角。列表行是 level5；详情页头部原用 level8 */
  boxRadius: Resource = $r('sys.float.corner_radius_level5');

  /** 方块左外边距。默认对齐列表前缀槽位（左 level6 / 右 level8） */
  boxMarginStart: Length = $r('sys.float.padding_level6');

  /** 方块右外边距。详情页头部原用 level12 */
  boxMarginEnd: Length = $r('sys.float.padding_level8');

  build() {
    Column() {
      SymbolGlyph(BREW_PACKAGE_ICON)
        .fontColor([brewKindIconColor(this.kind)])
        .fontSize(this.boxSize * BREW_PACKAGE_ICON_RATIO)
    }
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .width(this.boxSize)
    .height(this.boxSize)
    .borderRadius(this.boxRadius)
    .backgroundColor(BREW_PACKAGE_ICON_BOX_BACKGROUND)
    // 描边与符号同色（kind 色），成一个「描边 chips」的观感。
    // 圆角仍由上面的 `borderRadius` 统一管，这里只给宽与色。
    .border({
      width: BREW_PACKAGE_ICON_BORDER_WIDTH,
      color: brewKindIconColor(this.kind),
    })
    .margin({
      left: this.boxMarginStart,
      right: this.boxMarginEnd,
    })
  }
}
