/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { PasteboardUtil } from '@ohos/common';
import { AiError, AiErrorKind, AiFailureCard, AiFailureInput } from '../model/AiTypes';
import { AiSettingsStore } from '../service/AiSettingsStore';
import { AiTasks } from '../service/AiTasks';
import { AiErrorDetail } from '../util/AiErrorDetail';

/**
 * D3 · AI 报错解读卡（spec §6，挂在执行 Sheet 失败终态下方）。
 *
 * 输入来自 `BrewCommandState`（命令原文 + 行缓冲里按 stderr/stdout 分开的尾部）。
 * **未配 Key / 断网时按钮整个不出现**（G8，由 `d3ButtonVisible()` 判定——
 * 调用方在 render 前问一次，Key 存在性有进程内缓存，不产生 IO）。
 *
 * ## G13 红线（本组件最硬的约束）
 *
 * 「下一步」条目**只有复制按钮，没有任何执行入口**。AI 建议的命令文本可以复制，
 * 但永不渲染能把它送进 BrewCommandRunner 的控件——可执行入口只有 tldr 示例
 * （人工审校）与既有命令卡。
 */
@Component
export struct BrewAiFailureCard {
  /** 命令状态（sheet 侧传入，取命令原文与输出尾部）。 */
  @Prop command: string = '';
  @Prop stderrTail: string = '';
  @Prop stdoutTail: string = '';
  @Prop failureKind: string = '';
  @Prop token: string = '';

  @State private card: AiFailureCard | null = null;
  @State private loading: boolean = false;
  @State private errorKind: AiErrorKind | null = null;
  /** E4/E5 的细节后缀（spec §8 排查记录：诊断信息直达 UI）。空串 = 无细节。 */
  @State private errorDetail: string = '';
  @State private expanded: boolean = false;

  /** D3 按钮/卡片是否可见（G8：未配 Key 或断网时不出现；断网判定交给请求失败，
   * 这里只拦「没 Key」——没 Key 点击也是徒劳）。 */
  public static buttonVisible(): boolean {
    return AiSettingsStore.hasApiKey();
  }

  private startExplain(): void {
    if (this.loading) {
      return;
    }
    this.loading = true;
    this.errorKind = null;
    this.errorDetail = '';
    const input: AiFailureInput = new AiFailureInput();
    input.command = this.command;
    input.stderrTail = this.stderrTail;
    input.stdoutTail = this.stdoutTail;
    input.failureKind = this.failureKind;
    input.token = this.token;
    AiTasks.explainFailure(input)
      .then((card: AiFailureCard) => {
        this.card = card;
        this.loading = false;
        this.expanded = true;
      })
      .catch((error: AiError) => {
        this.loading = false;
        this.errorKind = error instanceof AiError ? error.kind : AiErrorKind.E2_NETWORK;
        this.errorDetail = error instanceof AiError ? AiErrorDetail.of(error) : '';
      });
  }

  private errorText(): ResourceStr {
    if (this.errorKind === AiErrorKind.E4_BAD_FORMAT) {
      return AiErrorDetail.e4Text(this.errorDetail);
    }
    if (this.errorKind === AiErrorKind.E5_BLOCKED) {
      return AiErrorDetail.e5Text(this.errorDetail);
    }
    return $r('app.string.ai_error_e2');
  }

  build() {
    Column({ space: 8 }) {
      // ---------- 入口按钮（失败终态下方的「AI 解读失败原因」） ----------
      if (!this.expanded && this.card === null) {
        Row() {
          if (this.loading) {
            LoadingProgress()
              .width(16)
              .height(16)
              .color(TERM_DIM)
            Text($r('app.string.ai_d3_loading'))
              .fontSize($r('sys.float.Body_S'))
              .fontColor(TERM_DIM)
              .margin({ left: 6 })
          } else {
            Text($r('app.string.ai_d3_button'))
              .fontSize($r('sys.float.Body_S'))
              .fontColor(TERM_DIM)
              .onClick(() => {
                this.startExplain();
              })
            if (this.errorKind !== null) {
              Text(this.errorText())
                .fontSize($r('sys.float.Body_S'))
                .fontColor(TERM_DIM)
                .margin({ left: 12 })
                .layoutWeight(1)
            }
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }

      // ---------- 三段卡 ----------
      if (this.expanded && this.card !== null) {
        Column({ space: 8 }) {
          this.Section($r('app.string.ai_d3_section_what'), [this.card.what], false)
          this.Section($r('app.string.ai_d3_section_causes'), this.card.causes, false)
          this.Section($r('app.string.ai_d3_section_next'), this.card.nextSteps, true)
          Row() {
            Text($r('app.string.ai_d3_badge'))
              .fontSize($r('sys.float.Body_S'))
              .fontColor(TERM_DIM)
              .layoutWeight(1)
            Text($r('app.string.brew_action_close'))
              .fontSize($r('sys.float.Body_S'))
              .fontColor(TERM_DIM)
              .onClick(() => {
                this.expanded = false;
              })
              .padding({ left: 8 })
          }
          .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(10)
        .borderRadius($r('sys.float.corner_radius_level6'))
        .backgroundColor(TERM_PANEL)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 一段：标题 + 条目。`copyable` 为真时条目带「复制」——**并且只有复制**（G13）。
   */
  @Builder
  Section(title: ResourceStr, items: string[], copyable: boolean) {
    Column({ space: 4 }) {
      Text(title)
        .fontSize($r('sys.float.Body_S'))
        .fontWeight(FontWeight.Medium)
        .fontColor(TERM_TEXT)
        .width('100%')
      ForEach(items, (item: string, index: number) => {
        Row() {
          Text(copyable ? `${index + 1}. ${item}` : `· ${item}`)
            .fontSize($r('sys.float.Body_S'))
            .fontColor(TERM_TEXT)
            .layoutWeight(1)
          if (copyable) {
            Text($r('app.string.brew_action_copy'))
              .fontSize($r('sys.float.Body_S'))
              .fontColor(TERM_DIM)
              .onClick(() => {
                PasteboardUtil.copyText(item);
              })
              .padding({ left: 8 })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }, (item: string, index: number) => `d3_${index}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

/** 终端观感的暗色（与 BrewCommandSheet 的黑底一致，卡内用深灰面板）。 */
const TERM_TEXT: ResourceColor = '#E6E6E6';
const TERM_DIM: ResourceColor = '#9AA0A6';
const TERM_PANEL: ResourceColor = '#1E2022';
