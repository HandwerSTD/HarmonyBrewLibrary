/*
 * Copyright (c) 2025 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/**
 * 数据源图标：中性实底圆角方块 + `scenes` 符号。
 *
 * 与 `brewcommon` 的 `BrewPackageIcon` 同构（那边是带 kind 描边的包类型图标），
 * 差别只在配色：源不分 formula/cask，所以方块与符号都用中性色。
 *
 * ## 为什么必须是独立的 @Component，不能把 Row 内联进 `PrefixCustomBuilder` 的箭头里
 *
 * `HdsListItemCard` 的前缀槽位是拿 builder 根节点的**测量宽度**给正文留位的，
 * 而**只有独立组件才会把自身 margin 算进这个宽度**：
 *
 *   裸 Row（含 @Builder 展开） -> 槽位量到 Row 的 `boxSize`，margin 不计入；
 *                                margin 只把方块往外推，方块溢出槽位、正文压在方块上
 *   独立 @Component           -> 槽位量到 margin box，正文正确让位
 *
 * 本项目实测（486vp 宽的卡片，1.9 units/vp）：
 *   裸 Row + `margin.right`  -> 槽位 `[1149..1225]` = 40vp，方块 `[1164..1240]`（溢出 8vp），
 *                               正文起点 `1225` —— 压在方块右半部分上
 *   独立 @Component（本文件）-> 槽位宽度 = 8 + 40 + 16 = 64vp，正文起点 = 方块右沿 + 16vp
 *
 * `BrewPackageIcon` 的注释里记的是同一条结论（它那边裸 Column 的后果是"方块盖住标题"）。
 * 换句话说：**边距必须写在图标组件内部，且图标必须是组件** —— 两个条件缺一不可。
 *
 * ## 成员名
 *
 * 沿用 `BrewPackageIcon` 的 `box` 前缀。`CustomComponent` 自带全套通用属性方法，
 * 声明同名成员会报 `Property 'x' ... is not assignable to the same property in base type`，
 * 所以几何参数一律加 `box` 前缀（那边实测叫 `size` 直接编译失败）。
 */
@Component
export struct BrewSourceIcon {
  /** 方块边长（vp）。与列表行的包图标同档（40vp） */
  boxSize: number = 40;

  /**
   * 方块左外边距。默认 `padding_level4`（8vp）—— 与卡片分割线、状态区、操作区的左右内缩
   * 同值，保证图标左沿与分割线左端对齐。
   *
   * 不用 `BrewPackageIcon` 默认的 `padding_level6`（12vp）：那是给没有分割线的列表行用的，
   * 这边有分割线可对齐。
   */
  boxMarginStart: Length = $r('sys.float.padding_level4');

  /**
   * 方块右外边距，即「图标 ↔ 正文」的间距。
   *
   * 默认 `padding_level8`（16vp），与 `BrewPackageIcon.boxMarginEnd` 同值 ——
   * `BrewPackageRow` / `BrewLocalPackageRow` / `BrewDiscoverRow` / `BrewDiscoverFeaturedCard`
   * 四个列表行实测都是 16vp。
   *
   * 这个间距**只能由图标自己给**：前缀槽位内部不提供任何间距，缺了它就是图标贴字。
   */
  boxMarginEnd: Length = $r('sys.float.padding_level8');

  build() {
    Row() {
      SymbolGlyph($r('sys.symbol.scenes'))
        .fontSize($r('sys.float.Title_M'))
        .fontColor([$r('sys.color.icon_secondary')])
    }
    .width(this.boxSize)
    .height(this.boxSize)
    .alignItems(VerticalAlign.Center)
    .justifyContent(FlexAlign.Center)
    .borderRadius($r('sys.float.corner_radius_level8'))
    .backgroundColor($r('sys.color.comp_background_tertiary'))
    // 边距写在组件内部而不是调用点的 `cardPrefixMargin`：见文件头注释
    .margin({
      left: this.boxMarginStart,
      right: this.boxMarginEnd,
    })
  }
}
