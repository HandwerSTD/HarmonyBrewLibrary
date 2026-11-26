/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { CommonConstants } from '@ohos/common';
import { BrewFormat } from '@ohos/brewcommon';
import type { BrewDiscoverAiEntry, BrewDiscoverBoard, BrewDiscoverEntry, BrewKind } from '@ohos/brewcommon';
import { AI_BOARD, BrewBoardStyle } from '../model/BrewBoardStyle';
import { BrewDiscoverHero } from './BrewDiscoverHero';
import { BrewDiscoverRow, BrewDiscoverRowDivider } from './BrewDiscoverRow';

/** 卡内预览条数。整张榜有 10 条，剩下的走「查看全部」 */
export const DISCOVER_PREVIEW_COUNT: number = 5;

/**
 * 一张榜单大卡。
 *
 * 结构 = 组件页两种卡的拼装（这是需求方指定的两个视觉锚点）：
 *   上半：`BrewDiscoverHero` —— 组件页 CodeLabCard（那张「安全选择图库」卡）的大图区，
 *         只是把图片换成代码画的渐变块；
 *   下半：榜内行 —— 组件页 ListCard（那张「按钮、图片、进度条等」卡）的行列表规格，
 *         连分隔线参数都照搬。
 *
 * 卡的外壳（primary 底 + level8 圆角 + clip）与 ListCard 一致，所以 Hero 的渐变块
 * 会被卡片的圆角裁掉上沿，和 CodeLabCard 的观感一致。
 *
 * **点击分工**：
 *   - 整张卡根节点 -> `handleViewAll`（进榜单二级页）。即除了榜内行与底部「查看全部」之外，
 *     点 Hero、点卡片空白处都算「看这张榜的全部」；
 *   - 榜内每一行 -> `handleEntryClick`（进包详情，`BrewDiscoverRow` 自己挂的 onClick）；
 *   - 底部「查看全部」行 -> 也是 `handleViewAll`。
 * ArkUI 的手势不冒泡（父子组件绑定同类手势时默认只响应最内层那个），
 * 所以点行不会又跳详情又跳榜单；若实测出现“双跳”，应改成在行上挡掉父节点的手势。
 *
 * **AI 榜特判（D4）**：`boardKey === 'ai'` 时行为三处不同 ——
 *   1. Hero 标题 = `heroTitle`（画像 headline，LLM 产出），空则回退 titleOf；
 *   2. 行**全显**（不截 5 条）、不渲染「查看全部」——AI 榜没有二级页；
 *   3. 根节点不可点、Hero 右上角换成「换一批」圆钮（handleRegenerate）。
 */
@Component
export struct BrewDiscoverBoardCard {
  @Prop @Require board: BrewDiscoverBoard;
  handleEntryClick?: (entry: BrewDiscoverEntry) => void;
  handleViewAll?: (board: BrewDiscoverBoard) => void;
  /** AI 榜专用：「换一批」（Hero 右上圆钮）。stat 榜不传 */
  handleRegenerate?: () => void;

  private isAiBoard(): boolean {
    return this.board.boardKey === AI_BOARD;
  }

  /** AI 榜全显，stat 榜截 5 条（+「查看全部」行） */
  private previewEntries(): BrewDiscoverEntry[] {
    if (this.isAiBoard()) {
      return this.board.entries;
    }
    return this.board.entries.slice(0, DISCOVER_PREVIEW_COUNT);
  }

  @Builder
  HeroBuilder() {
    Stack({ alignContent: Alignment.TopEnd }) {
      BrewDiscoverHero({
        kindLabel: this.isAiBoard() ?
          $r('app.string.brew_discover_ai_badge') : BrewBoardStyle.kindLabelOf(this.board.kind),
        title: this.isAiBoard() ?
          (this.board.heroTitle ?? '') : BrewBoardStyle.titleOf(this.board.boardKey),
        symbol: BrewBoardStyle.symbolOf(this.board.boardKey),
        colorStart: BrewBoardStyle.colorStartOf(this.board.boardKey),
        colorEnd: BrewBoardStyle.colorEndOf(this.board.boardKey),
      })
      // 换一批圆钮：AI 榜专属。压在渐变上，白底反色与大图卡的 chevron 圆钮同款语言
      if (this.isAiBoard()) {
        Row() {
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize($r('sys.float.Title_S'))
            .fontColor([$r('sys.color.font_on_primary')])
        }
        .justifyContent(FlexAlign.Center)
        .width($r('app.float.brew_discover_arrow_size'))
        .height($r('app.float.brew_discover_arrow_size'))
        .borderRadius(CommonConstants.FULL_PERCENT)
        .backgroundColor($r('sys.color.comp_emphasize_secondary'))
        .margin({
          top: $r('sys.float.padding_level8'),
          right: $r('sys.float.padding_level8'),
        })
        .clickEffect({ level: ClickEffectLevel.MIDDLE })
        .onClick(() => {
          this.handleRegenerate?.();
        })
      }
    }
  }

  /** 行的图标种类：AI 榜行自带 kind（候选池单一事实源），stat 榜用 board.kind */
  private rowKindOf(entry: BrewDiscoverEntry): BrewKind {
    if (this.isAiBoard()) {
      const aiEntry: BrewDiscoverAiEntry = entry as BrewDiscoverAiEntry;
      return BrewFormat.brewKindOf(aiEntry.kind);
    }
    return BrewFormat.brewKindOf(this.board.kind);
  }

  @Builder
  RowsBuilder() {
    Column() {
      ForEach(this.previewEntries(), (entry: BrewDiscoverEntry, index: number) => {
        BrewDiscoverRow({
          entry: entry,
          kind: this.rowKindOf(entry),
          handleItemClick: (clicked: BrewDiscoverEntry) => {
            this.handleEntryClick?.(clicked);
          },
        })
        // 最后一行不画分隔线，与 List 的 divider 行为一致
        if (index < this.previewEntries().length - 1) {
          BrewDiscoverRowDivider()
        }
      }, (entry: BrewDiscoverEntry) => `${this.board.id}_${entry.rank}`)
    }
    .width(CommonConstants.FULL_PERCENT)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  ViewAllBuilder() {
    Row() {
      Text($r('app.string.brew_action_view_all'))
        .fontSize($r('sys.float.Body_M'))
        .fontColor($r('sys.color.font_secondary'))
      Blank()
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize($r('sys.float.Title_M'))
        .fontColor([$r('sys.color.icon_secondary')])
    }
    .width(CommonConstants.FULL_PERCENT)
    .alignItems(VerticalAlign.Center)
    .padding({
      left: $r('sys.float.padding_level8'),
      right: $r('sys.float.padding_level8'),
      top: $r('sys.float.padding_level4'),
      bottom: $r('sys.float.padding_level4'),
    })
    .onClick(() => {
      this.handleViewAll?.(this.board);
    })
  }

  build() {
    Column() {
      this.HeroBuilder()
      this.RowsBuilder()
      // 预览装不下才给入口。新星榜常常不足 5 条，那时「查看全部」会指向一个没有增量的页面
      if (!this.isAiBoard() && this.board.entryCount > DISCOVER_PREVIEW_COUNT) {
        this.ViewAllBuilder()
      }
    }
    .width(CommonConstants.FULL_PERCENT)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('sys.color.comp_background_primary'))
    .borderRadius($r('sys.float.corner_radius_level8'))
    .clip(true)
    .clickEffect({ level: ClickEffectLevel.MIDDLE })
    .onClick(() => {
      // AI 榜没有二级页，根节点点击不导航（防误触跳到一个不存在的 boardId=0 页）
      if (this.isAiBoard()) {
        return;
      }
      this.handleViewAll?.(this.board);
    })
  }
}
