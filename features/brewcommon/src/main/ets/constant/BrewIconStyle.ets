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

import { BrewKind } from '../model/BrewModels';

/**
 * 包图标（基底 `BrewPackageIcon`）的**唯一样式来源** —— 美工后期替换只动这个文件。
 *
 * 为什么必须收成一处：这个方块在**四个**地方渲染（列表行 / Discover 行 / Discover 大图卡 /
 * 详情页头部），原先各自实现一套（`BrewMonogram` / `BrewDiscoverRowIcon` /
 * `BrewDiscoverFeaturedIcon` / `BrewDetailHero` 内联 Text），字形与配色分散在四个文件里。
 * 美工换一次图标要改四处、必然漂移 —— 本项目已经在 chips 与边距上吃过两次
 * （见 `BrewBoardStyle` 的注释）。现在：
 *
 *   换图标字形/比例 -> `BREW_PACKAGE_ICON` / `BREW_PACKAGE_ICON_RATIO`
 *   换类型配色      -> `brewKindIconColor()` + `resources/base/element/color.json`
 *   换底色/描边     -> `BREW_PACKAGE_ICON_BOX_BACKGROUND` / `BREW_PACKAGE_ICON_BORDER_WIDTH`
 *
 * 注意存的是 `$r()` 结果而不是符号名字符串：`$r()` 只接受编译期字面量，且**只有写成
 * 字面量时编译器才会校验资源是否存在**。写成普通字符串不校验 —— 本项目曾因此把 11 个
 * 根本不存在的符号名当成"已验证"（见 docs/brew-api-design.md §10.6）。
 */

/**
 * 包图标字形。全工程「包图标」的 `sys.symbol.*` 字面量只在这里出现一次。
 *
 * 名字是 **`scenes`（复数）**：符号表里没有 `scene`。已核对 SDK
 * `openharmony/ets/build-tools/ets-loader/sysResource.js`（该表内 `scenes: 125832865`）。
 */
export const BREW_PACKAGE_ICON: Resource = $r('sys.symbol.scenes');

/** 符号边长 / 方块边长。改这一个数就同时改四个地方的「图标占方块的比例」 */
export const BREW_PACKAGE_ICON_RATIO: number = 0.5;

/**
 * 方块**实底**色。
 *
 * 为什么不用 `sys.color.comp_background_tertiary`：那是 HDS 的**组件材质色**，
 * 带 alpha（本项目在 `commonbusiness/color.json` 里就有一个同色系的 `blur_bg = #CCF1F3F5`，
 * 即这抹浅灰带 80% alpha）。带 alpha 的底压在 Discover 榜卡渐变上时，
 * 底下的榜色会透出来，方块看着不是实底。这里取去掉 alpha 的同一抹灰。
 *
 * 明/暗两套值分别在 `base/element/color.json` 与 `dark/element/color.json`。
 * 注意 `dark/` 只覆盖这一个名字，其余颜色沿用 base。
 */
export const BREW_PACKAGE_ICON_BOX_BACKGROUND: Resource = $r('app.color.brew_icon_box_background');

/** 方块描边宽度（vp）。颜色与符号同色，都取 kind 色（`brewKindIconColor`）。
 *
 * ArkUI 的 border 画在组件**自身边界内**（border-box），所以描边宽度不影响方块外尺寸、
 * 也不推移行内正文 —— `HdsListItemCard` 前缀槽位量到的仍是 `boxSize`。
 * 1.5vp 时内部可见区为 `boxSize - 3`（40vp 方块 → 37vp），20vp 的 symbol 居中放得下。
 *
 * 非整数 vp 的取舍：1.5vp 在部分屏幕密度下会落在半像素上，抗锯齿后四个圆角可能
 * 看着比直边浅。真机上若描边发虚，回到整数（`1` 或 `2`）即可。 */
export const BREW_PACKAGE_ICON_BORDER_WIDTH: number = 1.5;

/**
 * 方块边长档位（vp）。基底组件按 `BREW_PACKAGE_ICON_RATIO` 推出符号字号。
 *
 * 这里用数值而不是 `$r('app.float.*')`：比例要能被算出来（符号 = 边长的一半），
 * 而 `Resource` 在运行期取不到值。四个调用点的边长只此一处定义。
 */
export class BrewIconSize {
  /** 列表行 / 本机包行（原 `app.float.brew_monogram_size`，40vp） */
  public static readonly ROW: number = 40;
  /** Discover 行 / Discover 大图卡（原 `app.float.brew_discover_row_icon_size`，48vp） */
  public static readonly DISCOVER: number = 48;
  /** 详情页头部（原 `app.float.brew_detail_monogram_size`，64vp） */
  public static readonly DETAIL: number = 64;
}

/**
 * 类型色：formula / cask，**色值由需求方指定**（formula `#E8971C` 橙 / cask `#5B9BD5` 蓝）。
 *
 * 不再与 Discover 的榜色调色板共用：榜色是「榜」的语义（`brewdiscover/.../color.json`），
 * 类型色是「包类型」的语义，两者本就不该是同一套值 —— 早先借用榜色的绿/红只是权宜，
 * 而且会让“看到某个颜色分不清是榜还是类型”。
 *
 * 一个已知的撞色：cask 的蓝 `#5B9BD5` 与 All-time 榜的蓝（起 `#8CC6F0` / 末 `#157DB1`）
 * 住在同一色相区间，在 All-time 榜二级页上会同屏出现（行内方块是类型色蓝、卡头是榜色蓝）。
 * **需求方明确表示这个撞色不要紧**，所以不再改。
 *
 * 注：行尾「查看」按钮已于 2026-09 改成固定用 `sys.color.font_emphasize`，
 * 所以这个撞色现在只剩“行内类型色 vs 卡头榜色”一处。
 *
 * 没有暗色覆盖：两个值都是中间调，在浅色 `#F1F3F5` 与暗色 `#2E3033` 底上都能读。
 *
 * **底色不再承载类型**：方块统一用中性实底（`BREW_PACKAGE_ICON_BOX_BACKGROUND`），
 * 颜色只由符号与描边表达。
 * 原先把「所属榜」的饱和色刷在方块上（`BrewDiscoverRowIcon`），但榜是**页面级**的
 * （`BrewDiscoverBoardView` 一页一个榜，所有行同色），而行级的 formula/cask 才是真正
 * 需要行内区分的信息。两者挤在同一个方块上会互相污染：用户看到红无法判断这是
 * "Trending 榜"还是"这是个 cask"，且红图标压在饱和绿底上对比度很差。
 */
export function brewKindIconColor(kind: BrewKind): Resource {
  return kind === BrewKind.CASK ? $r('app.color.brew_kind_cask') : $r('app.color.brew_kind_formula');
}
