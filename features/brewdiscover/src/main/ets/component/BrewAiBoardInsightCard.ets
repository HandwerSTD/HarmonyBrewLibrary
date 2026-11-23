/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { CommonConstants, Logger } from '@ohos/common';
import {
  AiBoardInsightInput,
  AiInsightCard,
  AiSettingsStore,
  AiTasks,
} from '@ohos/brewcommon';

const TAG: string = '[ai]';

/**
 * 榜单/单包统计的 AI 解读行（AI Companion 二期 P1-1，spec
 * `docs/superpowers/specs/2026-11-23-ai-companion-phase2-spec.md` §4）。
 *
 * 形态 = **折叠行**：一枚「AI 解读」小徽章 + 一句话解读；点击整行展开要点列表、
 * HEAD/ghcr 补充行与来源行。规格红线：
 *   - **不改主数字**：本行只做解读，榜单行自身的 30d/365d 数字一概不动（§4）；
 *   - **数字回溯制**（§6）：要点里的数字由 `AiTasks.parseInsight` 在写入缓存前
 *     过 `AnalyticsNumberParser.filterTraceable`，回溯不到 grounding 的数字整条丢弃；
 *   - **失败静默**（§5 F2）：无 Key / 网络失败 / E4 时本行整体不渲染（连重试按钮
 *     也不给——榜单页是「逛」的场景，原生榜单永远可用），对齐一期 D1 的
 *     autoAttempt 静默策略；
 *   - **点击互不干扰**：ArkUI 手势不冒泡，行上的 onClick 不会触发整卡的
 *     「查看全部」/「进详情」跳转（`BrewDiscoverBoardCard` 头注的既有约定）。
 *
 * 数据来自 `AiTasks.boardInsight`：缓存键含 snapshotDate（同一天数字不变，TTL 1 天），
 * stale-while-revalidate 的回包走 onRefreshed 静默换新。
 */
@Component
export struct BrewAiBoardInsightCard {
  /** grounding 输入（数字全部来自目录统计，A 级 grounding，登记 `AI_GROUNDING_BI`）。 */
  @Prop @Require input: AiBoardInsightInput;
  /** 快照日期（来源行「数据截至」用；空串则不渲染来源行）。 */
  @Prop snapshotDate: string = '';
  /** 装配层给的自动开关（`AiSettingsStore.autoExplain()`；无 Key 时恒 false）。 */
  @Prop autoStart: boolean = false;

  @State private card: AiInsightCard | null = null;
  /** 只做重入闸：加载期间不渲染占位（列表场景不能抖动行高）。 */
  @State private loading: boolean = false;
  @State private expanded: boolean = false;

  aboutToAppear(): void {
    if (this.autoStart) {
      this.requestInsight(false);
    }
  }

  /** 拉取解读。force = 旁路缓存强制取数（预留，卡片本体不提供重试入口）。 */
  private requestInsight(force: boolean): void {
    if (this.loading) {
      return;
    }
    this.loading = true;
    AiTasks.boardInsight(this.input, (card: AiInsightCard) => {
      // stale-while-revalidate 的回包：静默换新
      this.applyCard(card);
    }, force)
      .then((card: AiInsightCard) => {
        this.applyCard(card);
      })
      .catch((error: Error) => {
        // 失败静默（F2）：不留错误态、不给按钮，AI 行消失、原生榜单照常
        Logger.warn(TAG, `board insight silent fail, scope=${this.input.scope}, msg=${error?.message}`);
      })
      .finally(() => {
        this.loading = false;
      });
  }

  private applyCard(card: AiInsightCard): void {
    if (card === null || !card.isValid()) {
      return;
    }
    this.getUIContext().animateTo({ duration: 300, curve: Curve.Friction }, () => {
      this.card = card;
    });
  }

  /** 占位资源（含 %d / %s）取成纯串再替换，与 `BrewSentinelService.publishAsync` 同款。 */
  private resStr(name: string): string {
    const host: Context | undefined = this.getUIContext().getHostContext();
    if (host === undefined) {
      return '';
    }
    return host.resourceManager.getStringByNameSync(name);
  }

  /** HEAD 补充行文案（HEAD 拉取单列，不混进 30d 主计数）。 */
  private headNote(): string {
    if (this.input.headInstalls <= 0) {
      return '';
    }
    return this.resStr('ai_board_head_note').replace('%d', `${this.input.headInstalls}`);
  }

  /** ghcr 补充行文案（口径与 install-on-request 不同，必须标注「口径不同」）。 */
  private ghcrNote(): string {
    if (this.input.ghcrDownloads <= 0) {
      return '';
    }
    return this.resStr('ai_board_ghcr_note').replace('%d', `${this.input.ghcrDownloads}`);
  }

  @Builder
  PointLine(text: string) {
    Text(text)
      .fontSize($r('sys.float.Body_S'))
      .fontColor($r('sys.color.font_primary'))
      .width(CommonConstants.FULL_PERCENT)
      .padding({ left: $r('sys.float.padding_level10') })
  }

  @Builder
  CollapsedRow() {
    Row({ space: $r('sys.float.padding_level2') }) {
      Text($r('app.string.ai_board_insight'))
        .fontSize($r('sys.float.Body_S'))
        .fontColor($r('sys.color.font_tertiary'))
        .padding({
          left: $r('sys.float.padding_level3'),
          right: $r('sys.float.padding_level3'),
          top: $r('sys.float.padding_level1'),
          bottom: $r('sys.float.padding_level1'),
        })
        .borderRadius($r('sys.float.corner_radius_level4'))
        .backgroundColor($r('sys.color.comp_background_tertiary'))
      Text(this.card === null ? '' : this.card.oneLiner)
        .fontSize($r('sys.float.Body_S'))
        .fontColor($r('sys.color.font_secondary'))
        .maxLines(1)
        .ellipsisMode(EllipsisMode.END)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_down'))
        .fontSize($r('sys.float.Title_S'))
        .fontColor([$r('sys.color.icon_tertiary')])
        .rotate({ angle: this.expanded ? 180 : 0 })
    }
    .width(CommonConstants.FULL_PERCENT)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  ExpandedBody() {
    Column({ space: $r('sys.float.padding_level2') }) {
      if (this.card !== null) {
        ForEach(this.card.points, (point: string) => {
          this.PointLine(point)
        }, (point: string, index: number) => `${index}_${point}`)
      }
      if (this.headNote().length > 0) {
        Text(this.headNote())
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_tertiary'))
          .width(CommonConstants.FULL_PERCENT)
      }
      if (this.ghcrNote().length > 0) {
        Text(this.ghcrNote())
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_tertiary'))
          .width(CommonConstants.FULL_PERCENT)
      }
      if (this.snapshotDate.length > 0) {
        Text(this.resStr('ai_sources_analytics').replace('%s', this.snapshotDate))
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_tertiary'))
          .width(CommonConstants.FULL_PERCENT)
      }
    }
    .width(CommonConstants.FULL_PERCENT)
    .alignItems(HorizontalAlign.Start)
    .padding({ top: $r('sys.float.padding_level2') })
  }

  build() {
    // card 未就绪 → 整行不渲染（失败静默 + 列表行高不抖动）
    if (this.card === null) {
      Column()
        .width(CommonConstants.FULL_PERCENT)
        .height(0)
    } else {
      Column() {
        this.CollapsedRow()
        if (this.expanded) {
          this.ExpandedBody()
        }
      }
      .width(CommonConstants.FULL_PERCENT)
      .alignItems(HorizontalAlign.Start)
      .padding({
        left: $r('sys.float.padding_level8'),
        right: $r('sys.float.padding_level8'),
        top: $r('sys.float.padding_level4'),
        bottom: $r('sys.float.padding_level4'),
      })
      .onClick(() => {
        // 行内点击只翻展开态（本 SDK 的 onClick 不冒泡，代码库无 stopPropagation 先例，
        // 整卡跳转事件挂在榜单卡/单包卡自己的 onClick 上，互不触发）。
        this.expanded = !this.expanded;
      })
    }
  }
}
