/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { PasteboardUtil } from '@ohos/common';
import {
  AiError,
  AiErrorKind,
  AiExplainCard,
  AiExplainInput,
  AiTasks,
} from '@ohos/brewcommon';

/**
 * D1 · AI 讲解卡（spec §4）。
 *
 * 挂在详情页「描述分区之后、用法示例之前」；**显式触发**（点「AI 讲解」按钮才请求，
 * 不自动消耗）。缓存命中直接渲染（G3）；stale 先渲染旧值再后台刷新（G10）。
 *
 * ## 失败态（spec §4 / §8）
 *
 * - E1（未配置 Key）：按钮位变「配置 AI Key」引导；
 * - E2/E3（网络/超时）：卡内重试按钮；
 * - E4（格式不符）：错误态 + 重试（G11，不渲染半成品）；
 * - E5（内容安全拒绝）：「该包内容无法生成讲解」；
 * - 任何失败不阻塞详情页其它分区（本组件收起即无痕）。
 *
 * ## G13 红线
 *
 * 卡片内的「上手三步」**只有文本与复制按钮，永不渲染任何执行入口**。
 */
@Component
export struct BrewAiExplainCard {
  /** 详情页归一化数据的 grounding 输入（token / kind / desc / caveats / dependencies）。 */
  @Prop @Require input: AiExplainInput;
  /** 点「配置 AI Key」引导时由页面处理（跳 AI 设置页）。 */
  onConfigureKey: () => void = () => {
  };

  /** null = 未展开（只渲染入口按钮） */
  @State private card: AiExplainCard | null = null;
  @State private loading: boolean = false;
  @State private errorKind: AiErrorKind | null = null;
  /** E4/E2/E3 重试入口的显隐由 errorKind 决定；这里只是触发重渲染的计数器 */
  @State private attempt: number = 0;

  private startLoad(): void {
    if (this.loading) {
      return;
    }
    this.loading = true;
    this.errorKind = null;
    this.attempt++;
    AiTasks.explain(this.input, (refreshed: AiExplainCard) => {
      // stale-while-revalidate 的后台刷新回调：新内容无感替换（G10）
      if (refreshed !== null) {
        this.card = refreshed;
      }
    })
      .then((card: AiExplainCard) => {
        this.card = card;
        this.loading = false;
      })
      .catch((error: AiError) => {
        this.loading = false;
        this.errorKind = error instanceof AiError ? error.kind : AiErrorKind.E2_NETWORK;
      });
  }

  private errorText(): ResourceStr {
    if (this.errorKind === AiErrorKind.E1_NO_KEY) {
      return $r('app.string.ai_error_e1');
    }
    if (this.errorKind === AiErrorKind.E4_BAD_FORMAT) {
      return $r('app.string.ai_error_e4');
    }
    if (this.errorKind === AiErrorKind.E5_BLOCKED) {
      return $r('app.string.ai_error_e5');
    }
    return $r('app.string.ai_error_e2');
  }

  build() {
    Column() {
      // ---------- 入口 / 失败引导行 ----------
      if (this.card === null) {
        Row() {
          if (this.loading) {
            LoadingProgress()
              .width(20)
              .height(20)
            Text($r('app.string.ai_d1_loading'))
              .fontSize($r('sys.float.Body_M'))
              .fontColor($r('sys.color.font_secondary'))
              .margin({ left: $r('sys.float.padding_level2') })
          } else {
            Button(this.errorKind === null ? $r('app.string.ai_d1_button') :
              $r('app.string.ai_d1_retry'))
              .fontSize($r('sys.float.Body_M'))
              .fontColor($r('sys.color.font_primary'))
              .backgroundColor($r('sys.color.comp_background_tertiary'))
              .height(32)
              .onClick(() => {
                this.startLoad();
              })
            if (this.errorKind !== null) {
              Text(this.errorText())
                .fontSize($r('sys.float.Body_S'))
                .fontColor($r('sys.color.font_secondary'))
                .margin({ left: $r('sys.float.padding_level4') })
                .layoutWeight(1)
            }
          }
          // E1 的引导按钮：把用户带到 AI 设置页（spec §4 失败行）
          if (this.errorKind === AiErrorKind.E1_NO_KEY && !this.loading) {
            Button($r('app.string.ai_error_e1_action'))
              .fontSize($r('sys.float.Body_M'))
              .height(32)
              .margin({ left: $r('sys.float.padding_level2') })
              .onClick(() => {
                this.onConfigureKey();
              })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }

      // ---------- 讲解卡正文 ----------
      if (this.card !== null) {
        Column({ space: 8 }) {
          Text(this.card.summary)
            .fontSize($r('sys.float.Body_M'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .width('100%')

          if (this.card.scenarios.length > 0) {
            this.SectionTitle($r('app.string.ai_d1_section_scenarios'))
            ForEach(this.card.scenarios, (item: string) => {
              this.Bullet(item)
            }, (item: string, index: number) => `scn_${index}`)
          }

          if (this.card.caveats.length > 0) {
            this.SectionTitle($r('app.string.ai_d1_section_caveats'))
            ForEach(this.card.caveats, (item: string) => {
              this.Bullet(item)
            }, (item: string, index: number) => `cav_${index}`)
          }

          if (this.card.steps.length > 0) {
            this.SectionTitle($r('app.string.ai_d1_section_steps'))
            ForEach(this.card.steps, (item: string, index: number) => {
              // 每步一行 + 复制按钮。**没有执行按钮**（G13：AI 生成的命令只有复制）
              Row() {
                Text(`${index + 1}. ${item}`)
                  .fontSize($r('sys.float.Body_M'))
                  .fontColor($r('sys.color.font_primary'))
                  .layoutWeight(1)
                Text($r('app.string.brew_action_copy'))
                  .fontSize($r('sys.float.Body_S'))
                  .fontColor($r('sys.color.font_emphasize'))
                  .onClick(() => {
                    PasteboardUtil.copyText(item);
                  })
                  .padding({ left: 8, right: 4 })
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
            }, (item: string, index: number) => `stp_${index}`)
          }

          // 底部角标行：AI 生成声明 + 重新生成
          Row() {
            Text($r('app.string.ai_d1_badge'))
              .fontSize($r('sys.float.Body_S'))
              .fontColor($r('sys.color.font_tertiary'))
              .layoutWeight(1)
            Text($r('app.string.ai_d1_regen'))
              .fontSize($r('sys.float.Body_S'))
              .fontColor($r('sys.color.font_emphasize'))
              .onClick(() => {
                if (!this.loading) {
                  this.card = null;
                  this.startLoad();
                }
              })
              .padding({ left: 8 })
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .margin({ top: 4 })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(12)
        .backgroundColor($r('sys.color.comp_background_list_card'))
        .borderRadius($r('sys.float.corner_radius_level8'))
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  SectionTitle(label: ResourceStr) {
    Text(label)
      .fontSize($r('sys.float.Body_S'))
      .fontWeight(FontWeight.Medium)
      .fontColor($r('sys.color.font_secondary'))
      .width('100%')
      .margin({ top: 4 })
  }

  @Builder
  Bullet(text: string) {
    Row() {
      Text('·')
        .fontSize($r('sys.float.Body_M'))
        .fontColor($r('sys.color.font_tertiary'))
        .margin({ right: 6 })
      Text(text)
        .fontSize($r('sys.float.Body_M'))
        .fontColor($r('sys.color.font_primary'))
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }
}
