/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { Logger, PasteboardUtil } from '@ohos/common';
import {
  AiError,
  AiErrorKind,
  AiExplainCard,
  AiExplainInput,
  AiTasks,
  AiErrorDetail,
} from '@ohos/brewcommon';

/**
 * D1 · AI 讲解卡（spec §4）。
 *
 * 挂在详情页「元信息条之后、各分区之前」（spec §4 定稿口径）；触发分两种：
 * 自动生成（ai_settings_auto_explain 开、有 Key，autoStart 传入）与
 * 显式按钮（其余场景）。缓存命中秒开（G3）；stale 先渲染旧值再后台刷新（G10）。
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
  /**
   * 自动生成（spec §4）：true = 装配时替用户点一次按钮（ai_settings_auto_explain 开
   * 且有 Key，判据在装配层查 AiSettingsStore.autoExplain()——快照值无 Key 恒 false）。
   * 自动模式**失败静默**：不显示错误，入口按钮回到原位可手动重试（用户没主动要求，
   * 失败不该打扰）。手动点击的失败照常显示分级错误。
   */
  @Prop autoStart: boolean = false;
  /** 点「配置 AI Key」引导时由页面处理（跳 AI 设置页）。 */
  onConfigureKey: () => void = () => {
  };

  /** null = 未展开（只渲染入口按钮） */
  @State private card: AiExplainCard | null = null;
  @State private loading: boolean = false;
  @State private errorKind: AiErrorKind | null = null;
  /** E4/E5 的细节后缀（spec §8 排查记录：诊断信息直达 UI）。空串 = 无细节。 */
  @State private errorDetail: string = '';
  /** E4/E2/E3 重试入口的显隐由 errorKind 决定；这里只是触发重渲染的计数器 */
  @State private attempt: number = 0;
  /** 本次挂载是否以自动模式发起（失败静默的判据；手动重试后转普通模式）。 */
  @State private autoAttempt: boolean = false;

  aboutToAppear(): void {
    if (this.autoStart) {
      // 自动生成 = 替用户点一次按钮。失败静默由 autoAttempt 标记在 catch 分支兑现。
      this.autoAttempt = true;
      this.requestExplain();
    }
  }

  private startLoad(): void {
    if (this.loading) {
      return;
    }
    // 手动触发（含按钮重试）：错误正常展示
    this.autoAttempt = false;
    this.requestExplain();
  }

  private requestExplain(): void {
    if (this.loading) {
      return;
    }
    this.loading = true;
    this.errorKind = null;
    this.errorDetail = '';
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
        this.autoAttempt = false;
      })
      .catch((error: AiError) => {
        this.loading = false;
        if (this.autoAttempt) {
          // 自动模式失败静默：不置 errorKind，入口按钮保持原位（可手动重试）
          this.autoAttempt = false;
          Logger.info(TAG,
            `d1 auto start fail kind=${error instanceof AiError ? error.kind : 'e2'}`);
          return;
        }
        this.errorKind = error instanceof AiError ? error.kind : AiErrorKind.E2_NETWORK;
        this.errorDetail = error instanceof AiError ? AiErrorDetail.of(error) : '';
      });
  }

  private errorText(): ResourceStr {
    if (this.errorKind === AiErrorKind.E1_NO_KEY) {
      return $r('app.string.ai_error_e1');
    }
    if (this.errorKind === AiErrorKind.E4_BAD_FORMAT) {
      return AiErrorDetail.e4Text(this.errorDetail);
    }
    if (this.errorKind === AiErrorKind.E5_BLOCKED) {
      return AiErrorDetail.e5Text(this.errorDetail);
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
      // 渲染基调（spec §4）：像一段讲解，不是一张表——分区标题弱化成轻量引导词，
      // 分区从属靠字重/颜色不靠框；**空数组分区整体不渲染**（空字段不显示原则，
      // 不渲染任何「暂无」占位）。steps 保留编号与复制（G13）。
      if (this.card !== null) {
        Column({ space: 12 }) {
          if (this.card.summary.length > 0) {
            Text(this.card.summary)
              .fontSize($r('sys.float.Body_M'))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_primary'))
              .width('100%')
          }

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

  /** 分区标题：弱化的引导词（ tertiary 色 + 正常字重），不与正文争层级。 */
  @Builder
  SectionTitle(label: ResourceStr) {
    Text(label)
      .fontSize($r('sys.float.Body_S'))
      .fontWeight(FontWeight.Normal)
      .fontColor($r('sys.color.font_tertiary'))
      .width('100%')
  }

  /** 要点行：缩进无符号，靠留白与缩进表达从属（去掉「填表」的 · 前缀）。 */
  @Builder
  Bullet(text: string) {
    Text(text)
      .fontSize($r('sys.float.Body_M'))
      .fontColor($r('sys.color.font_primary'))
      .width('100%')
      .padding({ left: 10 })
  }
}

/** 自动生成的静默失败打点（与 AiTasks 同 tag 口径）。 */
const TAG: string = '[ai]';
