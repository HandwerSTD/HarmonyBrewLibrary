/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { Logger } from '@ohos/common';
import { AiInsightCard, AiLifecycleInput, AiTasks } from '@ohos/brewcommon';
import type { BrewLifecycleNotice } from '@ohos/brewcommon';

const TAG: string = '[ai]';

/**
 * 生命周期警示条（§5.3 分区 9）。
 *
 * Homebrew 是三态：正常 / deprecated（可用但警告）/ disabled（不可安装）。
 * 这个区分来自数据本身（`deprecated` 与 `disabled` 是两个独立字段，且各有自己的
 * 日期与原因字段），不是我们自己推的，所以提示条要如实区分两种措辞。
 *
 * 组件本身不判断是否显示 —— 该由调用方用 `if (lifecycle)` 控制，避免组件内部再存一份状态。
 *
 * 图标的取舍：本可以配一个警告类图标，但实测有效的 38 个 `sys.symbol.*` 里没有合适的一个
 * （`exclamationmark_triangle_fill` 之类均未验证，见 docs §10.3）。
 * 与其赌一个名字，先用「警示底色 + 文字」表达 —— 信息本身已经完整。
 *
 * AI 二期 P1-3 增补（spec `2026-11-23-ai-companion-phase2-spec.md` §4）：
 *   - **替代包 chip**：上游指定了替代包（`deprecationReplacementFormula/Cask`）时，
 *     原来的纯文本行升级为可点击 chip（白底反色），点击跳替代包详情（G5：替代包名
 *     只来自结构化字段，零编造）；未传 `onOpenReplacement` 回调时退回纯文本。
 *   - **AI 弃用解读段**：banner 下沿追加「弃用解读」一段（白字同族），grounding=
 *     弃用/禁用排期结构化字段（A 级，登记 `AI_GROUNDING_LC`）。数据到达才渲染，
 *     失败/无 Key 静默（F1/F2）——原生警示条永远可用。
 */
@Component
export struct BrewLifecycleBanner {
  @Prop @Require notice: BrewLifecycleNotice;
  /** AI 弃用解读的 grounding 输入；token 为空 = 详情页侧判定不启用（如 cask）。 */
  @Prop aiInput: AiLifecycleInput = new AiLifecycleInput();
  /** 装配层给的自动开关（`AiSettingsStore.autoExplain()`；无 Key 恒 false）。 */
  @Prop autoStart: boolean = false;
  /** 替代包 chip 点击（跳详情）。未传 = 不渲染 chip，保持纯文本。 */
  onOpenReplacement?: (token: string) => void;

  @State private aiCard: AiInsightCard | null = null;
  /** 只做重入闸；加载中不渲染占位（警示条高度不抖）。 */
  @State private aiLoading: boolean = false;

  aboutToAppear(): void {
    if (this.autoStart && this.aiInput.token.length > 0) {
      this.requestAi(false);
    }
  }

  /** 拉取弃用解读。force = 旁路缓存强制取数（预留）。 */
  private requestAi(force: boolean): void {
    if (this.aiLoading) {
      return;
    }
    this.aiLoading = true;
    AiTasks.lifecycleExplain(this.aiInput, (card: AiInsightCard) => {
      this.applyCard(card);
    }, force)
      .then((card: AiInsightCard) => {
        this.applyCard(card);
      })
      .catch((error: Error) => {
        // 失败静默（F2）：原生警示条照常，AI 段不出现
        Logger.warn(TAG, `lifecycle ai silent fail, token=${this.aiInput.token}, msg=${error?.message}`);
      })
      .finally(() => {
        this.aiLoading = false;
      });
  }

  private applyCard(card: AiInsightCard): void {
    if (card === null || !card.isValid()) {
      return;
    }
    this.getUIContext().animateTo({ duration: 300, curve: Curve.Friction }, () => {
      this.aiCard = card;
    });
  }

  /** 替代包 chip（白底反色；字色用警示底上的主字色）。 */
  @Builder
  ReplacementChip() {
    Text($r('app.string.ai_lifecycle_replacement', this.notice.replacement))
      .fontSize($r('sys.float.Body_S'))
      .fontColor($r('sys.color.font_primary'))
      .maxLines(1)
      .ellipsisMode(EllipsisMode.END)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .padding({
        left: $r('sys.float.padding_level4'),
        right: $r('sys.float.padding_level4'),
        top: $r('sys.float.padding_level1'),
        bottom: $r('sys.float.padding_level1'),
      })
      .margin({ top: $r('sys.float.padding_level2') })
      .borderRadius($r('sys.float.corner_radius_level4'))
      .backgroundColor($r('sys.color.font_on_primary'))
      .onClick(() => {
        // 本 SDK 的 onClick 不冒泡（代码库无 stopPropagation 先例），chip 点击不会
        // 误触详情页其他事件，直接跳替代包。
        const token: string = this.notice.replacement;
        if (token.length > 0) {
          this.onOpenReplacement?.(token);
        }
      })
  }

  @Builder
  AiPointLine(text: string) {
    Text(text)
      .fontSize($r('sys.float.Body_S'))
      .fontColor($r('sys.color.font_on_primary'))
      .opacity(0.92)
      .width('100%')
  }

  build() {
    Column() {
      Text(this.notice.label)
        .fontSize($r('sys.float.Title_S'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_on_primary'))
      Text(this.notice.hint)
        .fontSize($r('sys.float.Body_M'))
        .fontColor($r('sys.color.font_on_primary'))
        .margin({ top: $r('sys.float.padding_level2') })
      if (this.notice.reason) {
        Text(this.notice.reason)
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_on_primary'))
          .margin({ top: $r('sys.float.padding_level2') })
      }
      if (this.notice.replacement) {
        // 替代包：给了回调 = 可跳详情的 chip；否则保持原纯文本行
        if (this.onOpenReplacement !== undefined) {
          this.ReplacementChip()
        } else {
          Text(this.notice.replacement)
            .fontSize($r('sys.float.Body_S'))
            .fontColor($r('sys.color.font_on_primary'))
            .margin({ top: $r('sys.float.padding_level2') })
        }
      }
      // AI 弃用解读段（P1-3）：数据到达才渲染；无 Key/失败静默（F1/F2）
      if (this.aiCard !== null) {
        Column({ space: $r('sys.float.padding_level1') }) {
          Text($r('app.string.ai_lifecycle_title'))
            .fontSize($r('sys.float.Body_S'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_on_primary'))
            .width('100%')
          Text(this.aiCard.oneLiner)
            .fontSize($r('sys.float.Body_S'))
            .fontColor($r('sys.color.font_on_primary'))
            .opacity(0.92)
            .width('100%')
          ForEach(this.aiCard.points, (point: string) => {
            this.AiPointLine(point)
          }, (point: string, index: number) => `lcpt_${index}`)
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .margin({ top: $r('sys.float.padding_level4') })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding($r('sys.float.padding_level6'))
    .borderRadius($r('sys.float.corner_radius_level8'))
    .backgroundColor($r('sys.color.ohos_id_color_alert'))
  }
}
