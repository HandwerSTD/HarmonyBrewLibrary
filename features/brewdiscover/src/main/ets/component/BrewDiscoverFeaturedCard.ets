/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { TextModifier } from '@kit.ArkUI';
import {
  HdsListItemCard,
  PrefixCustomBuilder,
  SuffixCustomBuilder,
} from '@kit.UIDesignKit';
import { CommonConstants } from '@ohos/common';
import { BrewFormat, BrewIconSize, BrewPackageIcon, AiBoardInsightEntry, AiBoardInsightInput } from '@ohos/brewcommon';
import type { BrewDiscoverFeatured, BrewKind } from '@ohos/brewcommon';
import { BrewBoardStyle } from '../model/BrewBoardStyle';
import { BrewAiBoardInsightCard } from './BrewAiBoardInsightCard';
import {
  BREW_FEATURED_ARROW_BG,
  BREW_FEATURED_ARROW_INK,
  BREW_FEATURED_ART_SHADOW,
  brewFeaturedBadgeBg,
  brewFeaturedBadgeInk,
  brewFeaturedArtSymbol,
  brewFeaturedInk,
  brewFeaturedInkSecondary,
  brewFeaturedSchemeEnd,
  brewFeaturedSchemeIsDark,
  brewFeaturedSchemeOf,
  brewFeaturedSchemeStart,
  brewFeaturedSymbolColor,
} from '../model/BrewFeaturedArtStyle';

/**
 * 「单 App 大图卡」—— 一张卡就是一个包。
 *
 * 结构逐项对齐组件页 `CodeLabCard`（「图库选择器 - PhotoPicker - 安全选择图库」那张）。
 * 先把那张卡解剖一遍：
 *
 * ```
 * Stack(TopStart)
 * ├─ TagTipLabel                左上角 NEW 标签
 * └─ Stack(Bottom)
 *    ├─ ImageComponent(Cover)   铺满整卡的图
 *    └─ Column(height=144vp, justify=End)      <- 底部内容块
 *       ├─ Text(title)      Body_S / font_on_secondary / Regular
 *       ├─ Text(subTitle)   Title_M / font_on_primary / Medium
 *       └─ ComponentItemList(suffixType=ICON, itemHeight=72vp)
 *            每行 = [ComponentIcon 48vp] + 文字 + [CircleArrow 40vp 白圆底 >]
 * ```
 *
 * 本卡的对应关系：
 *
 * | CodeLabCard | 这里 |
 * |---|---|
 * | `ImageComponent` 铺满 | 代码画的渐变铺满（Homebrew 没有图标/截图素材） |
 * | `TagTipLabel`（左上） | 来源徽章「今日热门 · 第 1 名」 |
 * | —（右上无元素） | 增速徽章「↑22.0×」 |
 * | `title` 小字 | **包名**（token，`brew install` 用的那个标识） |
 * | `subTitle` 粗体大字 | **英文原文描述**（2 行截断） |
 * | `ComponentItemList` 那一行 | 48vp 包图标（symbol，见 `BrewPackageIcon`）+ **市场名** + **下载量** + `>` 圆钮 |
 *
 * 一个包的三个字符串各有其位（需求方指定）：市场名 `Vorssaint` 在行首、
 * 包名 `vorssaint` 在小字行、描述 `Menu bar toolkit with…` 是大字。
 *
 * `CircleArrow` 在组件页里是 `componentlibrary` 的私有 struct，跨模块拿不到，
 * 所以在这里按同款规格重新实现（`chevron_right` / 40vp / `aspectRatio(1)` / 白圆底），不发挥。
 */
@Component
export struct BrewDiscoverFeaturedCard {
  @Prop @Require item: BrewDiscoverFeatured;
  /** 目录快照日期（AI 解读来源行用，BaseView 透传）。 */
  @Prop snapshotDate: string = '';
  /** AI 解读自动开关（`AiSettingsStore.autoExplain()`，BaseView 透传）。 */
  @Prop autoStart: boolean = false;
  handleItemClick?: (item: BrewDiscoverFeatured) => void;

  /**
   * AI 解读的 grounding 输入：单包聚焦卡恒 1 条（scope='featured'，缓存键用
   * token+snapshotDate）。HEAD/ghcr 在单包卡上下文不可得，保持 -1（不渲染那两行）。
   */
  private featuredInsightInput(): AiBoardInsightInput {
    const input: AiBoardInsightInput = new AiBoardInsightInput();
    input.scope = 'featured';
    input.boardKey = this.item.boardKey;
    input.kind = this.item.kind;
    input.snapshotDate = this.snapshotDate;
    const entry: AiBoardInsightEntry = new AiBoardInsightEntry();
    entry.token = this.item.token;
    entry.rank = this.item.rank;
    entry.installs30d = this.item.installs30d;
    entry.installs365d = this.item.installs365d;
    entry.priorMonthly = this.item.priorMonthly;
    entry.velocity = this.item.velocity;
    input.entries = [entry];
    return input;
  }

  /**
   * 配色方案：**按 `item.id` 确定性选取**（同一个包永远同一套配色）。
   *
   * 刻意用「计算属性」而不是 `@State` + `aboutToAppear`：
   *   - 不需要生命周期钩子，值只依赖 `item`，随 `@Prop` 变化自动重算；
   *   - **修掉一个隐患**：`aboutToAppear` 只在组件创建时跑一次，若列表回收后复用组件
   *     并把 `item` 换成另一个包，旧写法的 scheme 不会更新，会出现「卡换了颜色没换」。
   *
   * 曾经的临时实现是 `Math.random()`（用于同屏对比选型），已按需求方要求替换。
   */
  private scheme(): number {
    return brewFeaturedSchemeOf(this.item.id);
  }

  /** 当前方案是深色还是浅色（决定前景用深墨还是浅墨） */
  private isDark(): boolean {
    return brewFeaturedSchemeIsDark(this.scheme());
  }

  /** 包类型：图画按类型换字形与配色（formula `code` / cask `pc`） */
  private artKind(): BrewKind {
    return BrewFormat.brewKindOf(this.item.kind);
  }

  /** 压在底色上的小徽章。**实心反色**：浅底配深徽章 + 白字，深底配浅徽章 + 深字 */
  @Builder
  BadgeBuilder(text: ResourceStr) {
    Text(text)
      .fontSize($r('sys.float.Body_S'))
      .fontColor(brewFeaturedBadgeInk(this.isDark()))
      .fontWeight(FontWeight.Regular)
      .maxLines(1)
      .ellipsisMode(EllipsisMode.END)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .padding({
        left: $r('sys.float.padding_level3'),
        right: $r('sys.float.padding_level3'),
        top: $r('sys.float.padding_level1'),
        bottom: $r('sys.float.padding_level1'),
      })
      .borderRadius($r('sys.float.corner_radius_level4'))
      .backgroundColor(brewFeaturedBadgeBg(this.isDark()))
  }

  /** 行首 48vp 图标（基底组件）。`kind` 由快照生成器写进条目（`BrewDiscoverFeatured.kind`） */
  @Builder
  PackageIconBuilder() {
    BrewPackageIcon({ kind: BrewFormat.brewKindOf(this.item.kind), boxSize: BrewIconSize.DISCOVER })
  }

  /**
   * 行尾 `>` 圆钮 —— 与组件页 `CircleArrow` 同规格。
   *
   * **外面那层 `Row` + `padding({right: level4})` 不能省**：组件页的 `CircleArrowBuilder`
   * 就是 `Row { CircleArrow() }.padding({right: level4})`，右内缩由它和 `cardSuffixMargin`
   * 一起给出。我最初只抄了里面的 `Button`，加上又去掉了底部块那一层 padding（左侧有图标
   * 自带的 `margin left level6` 顶着、右侧没有任何东西补位），结果按钮直接贴到卡片右缘。
   */
  @Builder
  ArrowBuilder() {
    Row() {
      Button() {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontColor([BREW_FEATURED_ARROW_INK])
          .fontSize($r('sys.float.Title_M'))
      }
      .backgroundColor(BREW_FEATURED_ARROW_BG)
      .width($r('app.float.brew_discover_arrow_size'))
      .aspectRatio(1)
    }
    .padding({ right: $r('sys.float.padding_level4') })
  }

  /**
   * 底部内容块 —— 对照组件页 `CodeLabCard` 的那个 Column：
   *   `.height(codelab_card_content_height 144vp)` + `justifyContent(FlexAlign.End)`，
   *   **块本身没有左右内缩、也没有底部留白**，内缩由子元素各自的 margin 提供。
   *
   * 之前我在这一层又加了 `padding({left/right: level6, bottom: level4})`，两个后果：
   *   1. item 行的图标变成 `level6(块) + level6(图标自身 margin)` = 12vp，
   *      比上面描述文字的 6vp 多缩一截 —— 两者本该左对齐（组件页里文字和图标都是 level6）；
   *   2. 底部多出 4vp，item 行没有贴着卡片下沿（组件页是贴着的）。
   * 所以这里只留 `bottom` 的一点点也不加，与组件页一致。
   */
  @Builder
  CaptionBuilder() {
    Column({ space: $r('sys.float.padding_level1') }) {
      // 第一行 = 来源徽章（「今日热门 · 第 1 名」）。
      // 位置就是原来的包名小字行 —— 需求方明确：来源徽章放这里，左上角不挂东西，包名不显示。
      // 规格与组件页 CodeLabCard 的 `title` 槽位一致：Body_S / font_on_secondary / Regular
      Text($r('app.string.brew_discover_featured_rank',
        BrewBoardStyle.titleOf(this.item.boardKey), this.item.rank))
        .fontSize($r('sys.float.Body_S'))
        .fontColor(brewFeaturedInkSecondary(this.isDark()))
        .fontWeight(FontWeight.Regular)
        .maxLines(1)
        .ellipsisMode(EllipsisMode.END)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding({
          left: $r('sys.float.padding_level6'),
          right: $r('sys.float.padding_level6'),
        })

      // 描述大字。**字重整体降过一档**（需求方：大图卡字重调低）：
      // 这里原为 Bold，与上面两个徽章一起降（Bold→Medium、Medium→Regular）。
      Text(this.item.desc)
        .fontSize($r('sys.float.Title_M'))
        .fontColor(brewFeaturedInk(this.isDark()))
        .fontWeight(FontWeight.Medium)
        .maxLines(2)
        .ellipsisMode(EllipsisMode.END)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width(CommonConstants.FULL_PERCENT)
        .padding({
          left: $r('sys.float.padding_level6'),
          right: $r('sys.float.padding_level6'),
        })

      HdsListItemCard({
        prefixItem: new PrefixCustomBuilder(() => {
          this.PackageIconBuilder();
        }),
        textItem: {
          // primary = 市场名（1 行截断）
          primaryText: {
            text: this.item.name,
            modifier: new TextModifier()
              .maxLines(1)
              .ellipsisMode(EllipsisMode.END)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .fontColor(brewFeaturedInk(this.isDark())),
          },
          // secondary 不只放数字，带提示词；文案走资源占位符，不硬编码
          secondaryText: {
            text: $r('app.string.brew_discover_installs_label',
              BrewFormat.compactCount(this.item.installs30d)),
            modifier: new TextModifier()
              .maxLines(1)
              .ellipsisMode(EllipsisMode.END)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .fontColor(brewFeaturedInkSecondary(this.isDark())),
          },
        },
        suffixItem: new SuffixCustomBuilder(() => {
          this.ArrowBuilder();
        }),
        cardHeight: $r('app.float.brew_discover_featured_row_height'),
        cardPrefixMargin: $r('sys.float.padding_level0'),
        cardSuffixMargin: $r('sys.float.padding_level2'),
        cardBorderRadius: 0,
        cardBackgroundColor: $r('sys.color.ohos_id_color_background_transparent'),
      })
    }
    .alignItems(HorizontalAlign.Start)
    .width(CommonConstants.FULL_PERCENT)
    .height($r('app.float.brew_discover_featured_content_height'))
    .justifyContent(FlexAlign.End)
  }

  // ---------------------------------------------------------------- 上半「图画」

  /**
   * 上半的图画：**裸 symbol，不带任何承载面**（需求方指定：symbol 不要加背景颜色）。
   *
   * 能去掉承载面的前提是底色已经换成「同色相内小幅明暗」的安静渐变 —— 原先那种
   * 「亮→深」的强渐变，中段只有 1.84–2.27:1，symbol 无论深浅都读不出来，所以才需要底板。
   * 换底色后 symbol 直接压在渐变上：浅底最坏 4.90 / 4.95:1、深底最坏 4.38 / 4.04:1
   * （7 套方案各自的最坏值见 `BrewFeaturedArtStyle`）。
   *
   * 字形取**该包所属分类**的图标，所以同一张卡上「画的什么」与分类卡一致；
   * 拿不到分类时退回包类型字形。见 `brewFeaturedArtSymbol`。
   *
   * 尺寸 140vp 照上部视觉区（400 - 176 = 224vp）取，垂直居中：top = (224 - 140) / 2 = 42。
   * **卡片高度或内容块高度一变，这两个数要一起重算。**
   */
  @Builder
  ArtBuilder() {
    SymbolGlyph(brewFeaturedArtSymbol(this.artKind(), this.item.categoryKey))
      .fontColor([brewFeaturedSymbolColor(this.artKind(), this.isDark())])
      .fontSize($r('app.float.brew_featured_art_symbol_size'))
      // 用 `symbolShadow` 而不是通用 `.shadow()`（需求方指定）：这是 `SymbolGlyph` 专有的阴影接口，
      // 字形内部的层叠结构能正确投下阴影。入参同为 `ShadowOptions`，所以常量直接复用。
      // ⚠ SDK 声明里的 NOTE：该接口与 `fill` / `showType` / `renderingStrategy`（文档中的
      //   "coloring strategy"）不兼容。这里只设了 `fontColor`，没设 `renderingStrategy`，不冲突；
      //   以后若给这个 symbol 加 `renderingStrategy`，阴影会静默失效。
      .symbolShadow(BREW_FEATURED_ART_SHADOW)
  }

  /**
   * 背景层：**底色 + 图画画成一个整体**，铺满整卡、垫在内容层下面。
   *
   * 需求方指定的 Stack 结构：背景与内容分两层，图画可以自由摆放而不受内容流影响。
   *
   * 底色**不再用 `BrewBoardStyle` 那套强渐变**（那套仍归榜单卡 Hero 与顶部 Hero 用），
   * 改用本卡自己的**配色池**（`BrewFeaturedArtStyle` 的 7 套），每次挂载随机取一套。
   * **不分榜**：所有大图卡共用同一个池子，色值与理由见 `BrewFeaturedArtStyle`。
   */
  @Builder
  ArtBackgroundBuilder() {
    Stack() {
      // 底色铺满整卡，替代 CodeLabCard 的 ImageComponent。
      // 明度差只有 4.5~5.1%：既保留一点层次，又让裸 symbol 压在哪一段都读得出来。
      // **不分榜** —— 三个榜的大图卡共用同一套底，榜的身份由卡上文字承担
      Column()
        .width(CommonConstants.FULL_PERCENT)
        .height(CommonConstants.FULL_PERCENT)
        .linearGradient({
          angle: 180,
          colors: [
            [brewFeaturedSchemeStart(this.scheme()), 0.0],
            [brewFeaturedSchemeEnd(this.scheme()), 1.0],
          ],
        })

      // 图画：居中于上部视觉区
      Stack() {
        this.ArtBuilder()
      }
      .width(CommonConstants.FULL_PERCENT)
      .height(CommonConstants.FULL_PERCENT)
      .alignContent(Alignment.Top)
      .padding({ top: $r('app.float.brew_featured_art_symbol_top') })
    }
    .width(CommonConstants.FULL_PERCENT)
    .height(CommonConstants.FULL_PERCENT)
  }

  build() {
    // AI 二期 P1-1：原 Stack（图画卡）保持定高整体不动，AI 解读行挂在它下方；
    // 卡片外壳（圆角/裁切/点击）上移到外层 Column。解读行自带白底（comp_background_primary
    // 在外层 Column 上），与上方渐变形成上下两段——这正是 spec §4 的「底部折叠行」形态。
    Column() {
      Stack({ alignContent: Alignment.BottomStart }) {
        // ① 背景层：渐变 + 图画，作为一个整体
        this.ArtBackgroundBuilder()

        // ② 内容层：徽章 + 底部内容块，整体叠在背景之上。
        //    高度占满整卡，靠 `layoutWeight(1)` 让徽章那行吃掉图画区（400 - 176 = 224vp）
        Column() {
          // 上部只留右上角的增速徽章：来源徽章（「今日热门 · 第 1 名」）与包名小字行
          // 都已按要求撤掉
          Row() {
            Blank()
            this.BadgeBuilder($r('app.string.brew_discover_velocity_badge',
              this.item.velocity > 0 ? this.item.velocity.toFixed(1) : '—'))
          }
          .width(CommonConstants.FULL_PERCENT)
          .layoutWeight(1)
          .alignItems(VerticalAlign.Top)
          .padding({
            left: $r('sys.float.padding_level6'),
            right: $r('sys.float.padding_level6'),
            top: $r('sys.float.padding_level4'),
          })

          this.CaptionBuilder()
        }
        .width(CommonConstants.FULL_PERCENT)
        .height(CommonConstants.FULL_PERCENT)
        .alignItems(HorizontalAlign.Start)
      }
      .width(CommonConstants.FULL_PERCENT)
      .height($r('app.float.brew_discover_featured_height'))

      // AI 解读行：数据到达前整行不渲染；行内点击不触发整卡进详情（手势不冒泡）
      BrewAiBoardInsightCard({ input: this.featuredInsightInput(), snapshotDate: this.snapshotDate, autoStart: this.autoStart })
    }
    .width(CommonConstants.FULL_PERCENT)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('sys.color.comp_background_primary'))
    .borderRadius($r('sys.float.corner_radius_level8'))
    .clip(true)
    .clickEffect({ level: ClickEffectLevel.MIDDLE })
    .onClick(() => {
      this.handleItemClick?.(this.item);
    })
  }
}
