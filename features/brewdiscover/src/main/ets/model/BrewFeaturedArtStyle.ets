/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { BrewKind, getCategorySymbolMap } from '@ohos/brewcommon';

/**
 * 单 App 大图卡（`BrewDiscoverFeaturedCard`）**整套配色**的唯一来源。
 *
 * ## 配色是「池子」，不是「一套」
 *
 * 这里维护的是 **7 套底色方案**（`BREW_FEATURED_SCHEME_COUNT`），每套是「上亮下暗的渐变
 * 两停点 + 它属于浅色还是深色」。卡片在 `aboutToAppear` 里**随机取一套**，所以同屏能同时
 * 看到多种方案 —— 这是需求方要求的对比方式。
 *
 * ⚠ **方案池是累积的**：需求方的操作一直是「删一套 + 加一套」（例：「移除深绿色…换成深蓝」
 * 「棕色换成紫色，再加个 #C4B3AB 作为浅色」），**不是替换那唯一一套**。
 * 加新方案时不要顺手删旧的 —— 只有需求方明确说「移除/换成」的那一套才删。
 * 本项目真踩过这个坑：曾把 6 套误当成「按榜分的冗余」一次删掉，只剩 2 套。
 *
 * 方案与**榜**无关（需求方明确：「不使用颜色配色区分大图卡类型」）。榜的身份只由卡上的
 * 来源徽章文字承担（`BrewBoardStyle.titleOf`）。所以本文件的函数**都不收 `boardKey`**。
 *
 * 与**包类型**色是两回事：symbol 仍按 formula / cask 换色与换字形（那是「包类型」的语义）。
 *
 * ## 前景色由方案的明暗决定，不是每套一份
 *
 * 7 套共用两套前景：浅色方案用深前景（`brew_featured_ink` / `_sym_l_*`），
 * 深色方案用浅前景（`brew_featured_ink_on_dark` / `_sym_d_*`）。
 * 所以新增方案时**只要它是浅色或深色之一，前景就自动适配**，不用另配一套。
 *
 * ## 三个必须知道的前提
 *
 * **1. 底色不与榜单卡 Hero 共用。** `BrewBoardStyle.colorStartOf/EndOf` 那套强渐变仍被
 * 榜单大卡的 Hero 与 Discover 顶部 Hero 使用（面积小、当色块看）。改这里不影响那两处。
 *
 * **2. 卡上的文字色必须是固定色，不能用 `sys.color.font_primary` 这类语义色。**
 * 语义色会**跟随系统深浅色模式翻转**，而本卡的底是固定色（不随主题变）。深色主题下
 * `font_primary` 会变成浅色，压在固定的浅色卡上直接读不出来。
 *
 * **3. 徽章必须实心反色，不能用半透明遮罩。** 原先用 `sys.color.mask_fourth`（半透明黑）
 * 压渐变 + 白字。实测：35% 黑遮罩叠在浅色卡上得到 `#A39D92`，白字只有 **2.69:1**，不过。
 *
 * ## 实测对比度（2026-09，7 套各自取最坏值）
 *
 * | 项 | 浅色方案 | 深色方案 |
 * |---|---|---|
 * | 主文字 | 8.45:1 | 8.78:1 |
 * | 次文字 | 5.32:1 | 5.47:1 |
 * | symbol formula | 4.69:1 | 3.47:1 |
 * | symbol cask | 5.23:1 | 4.32:1 |
 *
 * ⚠ **symbol 的算法与文字不同：按它实际覆盖的渐变区间取，不是按渐变两端。**
 * symbol 是 140vp 垂直居中于 224vp 视觉区，覆盖 `t ∈ [0.19, 0.81]` —— **不压两端**，
 * 所以它的真实对比比按端点算的略好（例：浅底 cask 按端点是 4.95:1，按实际区间是 5.23:1）。
 * 主文字/次文字则按整条渐变取最坏（它们铺得更开）。
 * formula 那一档**带 85% 透明度**（见下），数值已计入混合后的实际颜色。
 *
 * ⚠ **两端的最坏情况方向相反，加方案时必须分开看**：
 *   - 浅色方案：前景是深色 → 最坏在**底部**（最深那端）。顶部随便提亮都不影响对比度。
 *   - 深色方案：前景是浅色 → 最坏在**顶部**（最亮那端）。**顶部提亮会拉低对比度，有上限** ——
 *     试到 `#7E4572` 时次文字就掉到 4.39:1 不达标了，所以紫色停在 `#6B3A5E`。
 *   - 现在的最坏值就来自「浅·灰调」的底部 `#C4B3AB` 与「深·紫」的顶部 `#6B3A5E`。
 *     新方案的明度若比这两个更极端，会先撑不住。
 */

/**
 * 方案池的渐变起点（上，亮端）。**索引即方案 id，顺序与 `SCHEME_END` / `SCHEME_IS_DARK` 一致**。
 *
 * 必须写成 `$r()` 字面量：`$r()` 只接受编译期字面量，用 `SCHEME_KEYS` 之类的字符串数组
 * 在运行期拼名字是**拼不出来**的（本项目为此吃过 11 个假符号名的亏，见 §10.6）。
 */
const SCHEME_START: Resource[] = [
  $r('app.color.brew_featured_bg_warm_a'),   // 0 浅·暖黄
  $r('app.color.brew_featured_bg_blue_a'),   // 1 浅·浅蓝
  $r('app.color.brew_featured_bg_mint_a'),   // 2 浅·浅薄荷
  $r('app.color.brew_featured_bg_gray_a'),   // 3 浅·灰调
  $r('app.color.brew_featured_bg_purple_a'), // 4 深·紫
  $r('app.color.brew_featured_bg_navy_a'),   // 5 深·藏青
  $r('app.color.brew_featured_bg_indigo_a'), // 6 深·深蓝
];

/** 方案池的渐变终点（下，暗端）。需求方要求「顶部亮、底部用给定色」，所以给定色在这一端 */
const SCHEME_END: Resource[] = [
  $r('app.color.brew_featured_bg_warm_b'),
  $r('app.color.brew_featured_bg_blue_b'),
  $r('app.color.brew_featured_bg_mint_b'),
  $r('app.color.brew_featured_bg_gray_b'),
  $r('app.color.brew_featured_bg_purple_b'),
  $r('app.color.brew_featured_bg_navy_b'),
  $r('app.color.brew_featured_bg_indigo_b'),
];

/** 每套方案是浅色还是深色。**决定用哪一套前景**，与 `SCHEME_START` 索引一一对应 */
const SCHEME_IS_DARK: boolean[] = [false, false, false, false, true, true, true];

/** 方案池大小。卡片随机取方案的取值范围就是它 */
export const BREW_FEATURED_SCHEME_COUNT: number = SCHEME_START.length;

/** 取方案的渐变起点。越界回落第 0 套，避免脏数据导致渲染异常 */
export function brewFeaturedSchemeStart(index: number): Resource {
  return SCHEME_START[index] ?? SCHEME_START[0];
}

/** 取方案的渐变终点 */
export function brewFeaturedSchemeEnd(index: number): Resource {
  return SCHEME_END[index] ?? SCHEME_END[0];
}

/** 该方案是不是深色（决定前景用深墨还是浅墨） */
export function brewFeaturedSchemeIsDark(index: number): boolean {
  return SCHEME_IS_DARK[index] ?? false;
}

/**
 * 按**稳定 id** 选配色方案 —— 同一个包永远拿到同一套配色。
 *
 * 入参是 `BrewDiscoverEntry.id`（`BrewBrowseBuilder.tokenId` 的 FNV-1a 输出）。
 * 实测这个 id 在**两条数据路径下完全一致**（内置快照 JSON 里的 `id` 字段 == 由 token 实算的
 * `tokenId`），所以同一个包不会因为走目录路径还是快照路径而换色。
 *
 * ## 为什么直接用 `id % 7`，不叠更"混合"的写法
 *
 * 实测对比过三种（同一批真实 token）：
 *
 * | 写法 | 240 token 分布 | 48 个榜单 token 分布 |
 * |---|---|---|
 * | `id % 7`（**本实现**） | 43/37/32/32/32/28/36 | 9/8/4/5/7/6/9 |
 * | `(id >>> 3) % 7` | — | 4/8/5/7/7/7/10 |
 * | `(id * 2654435761) % 7` | — | 2/3/5/12/11/7/8 |
 *
 * `id` 本身就是 FNV-1a 的输出，**再叠一次乘法只会引入偏差，不会消除偏差**
 * （本项目此前也吃过哈希分布不均的坑：`h*31` 与 `djb2xor` 都凑不齐三种）。
 *
 * ## ⚠ 确定性的固有代价：同屏可能重复
 *
 * 内置快照的 5 张 featured 落在 5/4/0/6/6 —— **「深·深蓝」出现两次**。
 * 随机取的话平均能看到 4.3 种，确定性取则完全由 id 决定、不受控。
 * 要保证同屏不重复，只能改成「按屏内序号轮转」，但那会丢掉
 * **「同一个包永远同色」**这个性质 —— 这是本次改动的目的，所以不这么做。
 *
 * 负数与越界都归一到 `[0, COUNT)`，避免脏数据让渐变取到 undefined。
 */
export function brewFeaturedSchemeOf(id: number): number {
  const n: number = BREW_FEATURED_SCHEME_COUNT;
  return ((id % n) + n) % n;
}

/**
 * 图画的字形：取**该包所属分类**的图标（与分类卡同一张表 `getCategorySymbolMap`）。
 *
 * 需求方要求「换成该软件包真实的分类图标」—— 所以卡上画的东西与它所属分类一致，
 * 而不再是按包类型写死的 `code` / `pc`（那只能表达「命令行包 / 桌面应用」）。
 *
 * ⚠ `categoryKey` 由数据层保证非空（`BrewRepository.fillCategoryKeys` 在 hydration 前补，
 * 理由见那里）。拿不到分类时退回类型字形，见 `brewFeaturedKindSymbol`。
 *
 * 注意这与行首 48vp 小图标的 `scenes` 是**两套字形**：那处是「包」的通用符号，
 * 这处是「这个包是什么分类」。同屏两者会不一样，是有意的。
 */
export function brewFeaturedArtSymbol(kind: BrewKind, categoryKey: string): Resource {
  return getCategorySymbolMap(kind)[categoryKey] ?? brewFeaturedKindSymbol(kind);
}

/**
 * 分类未知时的兜底：退回**包类型**字形（formula `code` / cask `pc`）。
 *
 * 不用分类卡那套兜底（`square_grid_2x2`）：大图卡上 140vp 的图标是整张卡的主体，
 * 退成通用方格看不出这是什么；退回类型字形至少仍表达「命令行包 / 桌面应用」。
 * 实测榜单 48 条全部命中策展层，正常路径走不到这里。
 */
function brewFeaturedKindSymbol(kind: BrewKind): Resource {
  return kind === BrewKind.CASK ? $r('sys.symbol.pc') : $r('sys.symbol.code');
}

/**
 * 裸 symbol 的类型色。**浅色方案用深一档、深色方案用提亮档**。
 *
 * 浅色这一档按「浅·灰调」的底部 `#C4B3AB`（明度 72%，池子里最深的浅色底）取 ——
 * 更早的淡彩底用的 `#9E5900` / `#2A669C` 压上去只有 2.67 / 2.98:1，连 3:1 门槛都不过。
 * 池子里其它浅色方案都比它亮，所以对比度只会更好。
 *
 * ## formula 为什么是灰（2026-09，改了四版）
 *
 * 这一档的颜色来回改了四次，把死路都记下来，免得以后重走：
 *
 * | 版本 | 值 | 为什么不行 |
 * |---|---|---|
 * | 1 | `#653800`（深棕） | 需求方：「好丑」。彩度只有 0.396，而它压在的「浅·灰调」底色 |
 * |   |  | `#C4B3AB` 色相约 20° —— **色相太近，看着就是一团泥**。 |
 * | 2 | `#8A4A00`（艳棕） | 在橙色色相内提彩度到 0.541，但对比度掉到 3.39:1（退到 3:1 门槛）。 |
 * |   |  | 天花板很低：再提（`#9A5200` 起）就跌破 3:1；要在 4:1 以上拿高彩度， |
 * |   |  | 色相会被迫偏到 18°（红棕），丢掉 formula 的橙色身份。 |
 * | 3 | `#0041C4`（靛蓝） | 换色相后确实更好（彩度 0.77 / 对比 4.07:1 —— 蓝的感知亮度低， |
 * |   |  | 「鲜艳」与「高对比」不冲突，4:1 门槛赚回来了）。但需求方最终选择灰。 |
 * | 4 | `#4A4E54`（灰） | **当前**。 |
 *
 * **关于橙色的感知特性**（这是第 1、2 版失败的根本原因，不是彩度高低的问题）：
 * 反证是浅底 cask `#1B4568` 彩度只有 0.302（**比 `#653800` 更低**）却没人抱怨 ——
 * 因为深蓝读作「藏青」是干净的，深橙读作「棕」是脏的。所以不能拿
 * 「cask 彩度更低也没事」推断 formula 也没事。
 *
 * ## 灰这一档的约束
 *
 * 可用区间比想象中窄 —— 灰必须**足够深/足够浅**才能过 4:1，而且**要避开已占用的墨色**：
 *   - 浅底：`#4A4E54`（对比 4.14:1）。再浅一档 `#50545A` 就掉到 3.77:1 不达标。
 *     与主文字 `#1A1C1E` 差 2.04、与次文字 `#3A3E43` 差 1.29 —— 选它是因为在**达标的
 *     候选里**它与两个墨色分离最大。
 *   - 深底：`#B0B4B8`（对比 4.21:1）。与白字差 2.09、与 `#CCCCCC` 差 1.30。
 *   - 两个灰都**略带冷调**（不是纯中性 R=G=B）：底色 `#C4B3AB` 是暖灰，冷调灰分离度更好。
 *
 * ⚠ **需要留意的观感风险**：灰色在 UI 语汇里常表示「禁用/不可用」。这个图标是卡上最大的
 * 视觉元素，改灰后整张卡会明显安静下来 —— 若看着像置灰状态，应改回彩色而不是继续调灰。
 *
 * 与 cask 的区分：现在是「中性灰 vs 蓝」，靠**色相的有无**区分，比第 3 版
 * （两个蓝只差 13° 色相）更容易分辨。
 *
 * ## 透明度：底色用「近黑 / 近白」，alpha 只负责浓度
 *
 * 两个色值：浅底 `#A60A0C10`（底 `#0A0C10` @ 65%）、深底 `#80F5F7FA`（底 `#F5F7FA` @ 50%）。
 * 格式是 `#AARRGGBB`（旁证：已有的 `brew_featured_art_shadow = #40000000` = 25% 黑）。
 *
 * ### 关键认知：alpha 与「显示成什么色」是解耦的
 *
 * 显示色 = `alpha × 底色 + (1-alpha) × 背景`。所以**同一个显示色可以用无数组 (底色, alpha) 做出来** ——
 * 想同时要「更深」和「更透明」，只要把**底色推向极端**（浅底推向黑、深底推向白），再用 alpha 拉回目标。
 *
 * 这一点我一开始理解反了：以为「调深」和「加透明」互相冲突、只能二选一。实际上
 * **在底色固定时**它们才冲突（浅底上 alpha 越低越浅）；**换底色就解开了**。
 * 教训：alpha 不是"颜色的一部分"，它是"这个颜色有多浓"。
 *
 * ### 只有两条硬边界
 *
 * 1. **浅底：越深对比越高，没有上限**（深色压浅底）。下限是"再深就发死"的观感问题。
 * 2. **深底：越深对比越低，有硬上限**。深底 formula 的最坏值现在 **3.47:1**，
 *    alpha 再降就跌破 3:1 —— 因为深色方案的底色本身就深，前景越接近底色越读不出来。
 *
 * ### 实测（formula 按它实际覆盖的渐变区间 `t ∈ [0.19, 0.81]` 取最坏）
 *
 * | 底色 | alpha | 浅底显示 | 浅底最坏 | 深底显示 | 深底最坏 |
 * |---|---|---|---|---|---|
 * | `#4A4E54` / `#B0B4B8` | 85% | `#5E5F63` | 3.38:1 | `#A3A0A8` | 3.70:1 |
 * | `#0A0C10` / `#F5F7FA` | 65% / 50% | **`#4F4B4B`** | **4.69:1** | **`#A894A5`** | **3.47:1** |
 *
 * 改后**两边都更深、alpha 都更低**：浅底 #5E5F63 → #4F4B4B，深底 #A3A0A8 → #A894A5。
 *
 * 只有 formula 带透明度（需求方只提了灰色这一档），cask 仍是不透明。
 * 混合按 **sRGB 空间线性插值**估算（HarmonyOS 默认按 sRGB 混合），不是线性光空间。
 */
export function brewFeaturedSymbolColor(kind: BrewKind, isDark: boolean): Resource {
  if (kind === BrewKind.CASK) {
    return isDark ? $r('app.color.brew_featured_sym_d_cask') : $r('app.color.brew_featured_sym_l_cask');
  }
  return isDark ? $r('app.color.brew_featured_sym_d_formula') : $r('app.color.brew_featured_sym_l_formula');
}

/** 主文字墨色（描述大字 / 市场名） */
export function brewFeaturedInk(isDark: boolean): Resource {
  return isDark ? $r('app.color.brew_featured_ink_on_dark') : $r('app.color.brew_featured_ink');
}

/** 次文字墨色（安装量） */
export function brewFeaturedInkSecondary(isDark: boolean): Resource {
  return isDark ? $r('app.color.brew_featured_ink_on_dark_secondary') : $r('app.color.brew_featured_ink_secondary');
}

/** 徽章底：实心反色（浅底→深徽章，深底→浅徽章） */
export function brewFeaturedBadgeBg(isDark: boolean): Resource {
  return isDark ? $r('app.color.brew_featured_badge_bg_d') : $r('app.color.brew_featured_badge_bg_l');
}

/** 徽章文字：与徽章底反向（浅底上是白字，深底上是深字） */
export function brewFeaturedBadgeInk(isDark: boolean): Resource {
  return isDark ? $r('app.color.brew_featured_badge_ink_d') : $r('app.color.brew_featured_badge_ink_l');
}

/**
 * 行尾 `>` 圆钮的底色：两种方案都用白。
 * 浅色卡上它是一枚浅钮（自身对底最低只有 1.12:1 —— 压在「浅·暖黄」上时），
 * 靠钮内的深图标读（17.09:1）；深色卡上它是一枚高对比白钮。
 */
export const BREW_FEATURED_ARROW_BG: Resource = $r('app.color.brew_featured_arrow_bg');

/** 圆钮里的图标色：圆钮始终是白底，所以图标始终取深墨色（不随方案变） */
export const BREW_FEATURED_ARROW_INK: Resource = $r('app.color.brew_featured_ink');

/**
 * 图形投影：中性黑，负责「浮起来」的纵深感（需求方要求的「加上阴影」）。
 *
 * **渲染走 `SymbolGlyph.symbolShadow`，不是通用 `.shadow()`**（需求方指定）。入参同为
 * `ShadowOptions`，所以这个常量两边都能用；换接口时不用改值。
 *
 * ⚠ `symbolShadow` 的 SDK 声明里有一条 NOTE：它与 `fill` / `showType` /
 * **`renderingStrategy`**（声明里写作 "coloring strategy"）不兼容。本项目只设了 `fontColor`，
 * 没设 `renderingStrategy`，所以不冲突 —— 但以后若给该 symbol 加 `renderingStrategy`，
 * **阴影会静默失效**（不报错、只是没阴影），这条要跟着改。
 * API 版本：`@since 20`，项目 `compatibleSdkVersion = 6.1.0(23)`，可用。
 *
 * 深色方案上这层投影基本看不见 —— 没有为它单独做一套（浅色发光在深底上会显得发灰），
 * 深色卡上图画看着更「平」是有意的取舍。
 */
export const BREW_FEATURED_ART_SHADOW: ShadowOptions = {
  radius: 16,
  color: $r('app.color.brew_featured_art_shadow'),
  offsetX: 0,
  offsetY: 8,
};
