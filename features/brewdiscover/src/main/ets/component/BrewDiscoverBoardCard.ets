/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { CommonConstants } from '@ohos/common';
import { BrewFormat, AiBoardInsightEntry, AiBoardInsightInput } from '@ohos/brewcommon';
import type { BrewDiscoverBoard, BrewDiscoverEntry } from '@ohos/brewcommon';
import { BrewBoardStyle } from '../model/BrewBoardStyle';
import { BrewAiBoardInsightCard } from './BrewAiBoardInsightCard';
import { BrewDiscoverHero } from './BrewDiscoverHero';
import { BrewDiscoverRow, BrewDiscoverRowDivider } from './BrewDiscoverRow';

/** 卡内预览条数。整张榜有 10 条，剩下的走「查看全部」 */
export const DISCOVER_PREVIEW_COUNT: number = 5;

/** AI 解读 grounding 里带的条目上限（AI 二期 spec §3 P1-1：截前 10 条）。 */
const AI_INSIGHT_ENTRY_LIMIT: number = 10;

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
 */
@Component
export struct BrewDiscoverBoardCard {
  @Prop @Require board: BrewDiscoverBoard;
  /** 目录快照日期（AI 解读来源行「数据截至」用，BaseView 从 discoverState 透传）。 */
  @Prop snapshotDate: string = '';
  /** AI 解读自动开关（`AiSettingsStore.autoExplain()`，BaseView 透传）。 */
  @Prop autoStart: boolean = false;
  handleEntryClick?: (entry: BrewDiscoverEntry) => void;
  handleViewAll?: (board: BrewDiscoverBoard) => void;

  private previewEntries(): BrewDiscoverEntry[] {
    return this.board.entries.slice(0, DISCOVER_PREVIEW_COUNT);
  }

  /**
   * AI 解读的 grounding 输入（A 级：数字全部来自榜条目，AI 只准原样引用）。
   * 截前 10 条与「整张榜」口径一致（榜单页条目即 10 条）；HEAD/ghcr 在榜单
   * 上下文不可得，保持 -1（UI 不渲染那两行）。
   */
  private insightInput(): AiBoardInsightInput {
    const input: AiBoardInsightInput = new AiBoardInsightInput();
    input.scope = 'board';
    input.boardKey = this.board.boardKey;
    input.kind = this.board.kind;
    input.snapshotDate = this.snapshotDate;
    const entries: AiBoardInsightEntry[] = [];
    const top: BrewDiscoverEntry[] = this.board.entries.slice(0, AI_INSIGHT_ENTRY_LIMIT);
    for (let i: number = 0; i < top.length; i++) {
      const one: BrewDiscoverEntry = top[i];
      const mapped: AiBoardInsightEntry = new AiBoardInsightEntry();
      mapped.token = one.token;
      mapped.rank = one.rank;
      mapped.installs30d = one.installs30d;
      mapped.installs365d = one.installs365d;
      mapped.priorMonthly = one.priorMonthly;
      mapped.velocity = one.velocity;
      entries.push(mapped);
    }
    input.entries = entries;
    return input;
  }

  @Builder
  HeroBuilder() {
    BrewDiscoverHero({
      kindLabel: BrewBoardStyle.kindLabelOf(this.board.kind),
      title: BrewBoardStyle.titleOf(this.board.boardKey),
      symbol: BrewBoardStyle.symbolOf(this.board.boardKey),
      colorStart: BrewBoardStyle.colorStartOf(this.board.boardKey),
      colorEnd: BrewBoardStyle.colorEndOf(this.board.boardKey),
    })
  }

  @Builder
  RowsBuilder() {
    Column() {
      ForEach(this.previewEntries(), (entry: BrewDiscoverEntry, index: number) => {
        BrewDiscoverRow({
          entry: entry,
          kind: BrewFormat.brewKindOf(this.board.kind),
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
      // AI 解读行（P1-1）：数据到达前整行不渲染（失败静默），不占位不抖行高
      BrewAiBoardInsightCard({ input: this.insightInput(), snapshotDate: this.snapshotDate, autoStart: this.autoStart })
      // 预览装不下才给入口。新星榜常常不足 5 条，那时「查看全部」会指向一个没有增量的页面
      if (this.board.entryCount > DISCOVER_PREVIEW_COUNT) {
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
      this.handleViewAll?.(this.board);
    })
  }
}
