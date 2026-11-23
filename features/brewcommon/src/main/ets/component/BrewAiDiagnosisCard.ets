/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { Logger, PasteboardUtil } from '@ohos/common';
import { AiDiagnosisInput, AiInsightCard } from '../model/AiTypes';
import { AiSettingsStore } from '../service/AiSettingsStore';
import { AiTasks } from '../service/AiTasks';

const TAG: string = '[ai]';

/**
 * P1-4 · 数据源诊断 AI 解读卡（AI Companion 二期，spec §3/§4）。
 *
 * 挂在数据源设置页的**探测失败行**下方：原生探测结果（HTTP 码 / 原因码 / 耗时）
 * 永远自足可用，本卡只是解读增强 —— 所以：
 *   - **自动触发**：autoStart（=`AiSettingsStore.autoExplain()`）时 aboutToAppear
 *     直接请求，没有 D3 那样的入口按钮（诊断场景用户已经停在失败态，多点一步
 *     只是把同一个信息推开）；
 *   - **失败静默**（spec §5 F2）：无 Key / 断网 / E4 时整卡不渲染，保留原生 probe 结果；
 *   - **只读诊断**（G7）：`actionHint` 是操作描述文字，渲染成「复制」chip ——
 *     只有复制、没有任何执行入口；AiTasks.sourceDiagnosis 的 DIAGNOSIS_RULE
 *     已在 prompt 侧禁止模型输出命令行；
 *   - **脱敏在发送边界**（spec §6）：`AiTasks.sourceDiagnosis` 内部对
 *     `detail` 统一过 `aiMaskLocalPaths`，本卡拿到的输入是什么就传什么，
 *     不在本卡做二次处理（避免两处正则漂移）。
 */
@Component
export struct BrewAiDiagnosisCard {
  /** 探测结果 grounding 输入（B 级 detail 字段在任务层脱敏）。 */
  @Prop @Require input: AiDiagnosisInput;
  /** 装配层给的自动开关（无 Key 恒 false）。 */
  @Prop autoStart: boolean = false;

  @State private card: AiInsightCard | null = null;
  /** 只做重入闸；加载中不渲染占位（探测卡高度不抖）。 */
  @State private loading: boolean = false;

  aboutToAppear(): void {
    if (this.autoStart && this.input.baseUrl.length > 0) {
      this.requestDiagnosis();
    }
  }

  private requestDiagnosis(): void {
    if (this.loading) {
      return;
    }
    this.loading = true;
    AiTasks.sourceDiagnosis(this.input)
      .then((card: AiInsightCard) => {
        if (card.isValid()) {
          this.getUIContext().animateTo({ duration: 300, curve: Curve.Friction }, () => {
            this.card = card;
          });
        }
      })
      .catch((error: Error) => {
        // 失败静默（F2）：原生探测结果照常，AI 解读区不出现
        Logger.warn(TAG, `diagnosis silent fail, source=${this.input.sourceId}, msg=${error?.message}`);
      })
      .finally(() => {
        this.loading = false;
      });
  }

  build() {
    // 数据未到达 → 整卡不渲染（失败静默 + 不抖动探测卡的行高）
    if (this.card === null) {
      Column()
        .width('100%')
        .height(0)
    } else {
      Column({ space: 6 }) {
        Text($r('app.string.ai_diag_title'))
          .fontSize($r('sys.float.Body_S'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_tertiary'))
          .width('100%')
        Text($r('app.string.ai_diag_from_probe', this.input.httpCode, this.input.tookMs))
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_tertiary'))
          .width('100%')
        Text(this.card.oneLiner)
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('sys.color.font_primary'))
          .width('100%')
        ForEach(this.card.points, (point: string) => {
          Text(point)
            .fontSize($r('sys.float.Body_M'))
            .fontColor($r('sys.color.font_primary'))
            .width('100%')
            .padding({ left: 10 })
        }, (point: string, index: number) => `sdpt_${index}`)
        if (this.card.actionHint.length > 0) {
          Row() {
            Text(this.card.actionHint)
              .fontSize($r('sys.float.Body_S'))
              .fontColor($r('sys.color.font_primary'))
              .layoutWeight(1)
            Text($r('app.string.brew_action_copy'))
              .fontSize($r('sys.float.Body_S'))
              .fontColor($r('sys.color.font_emphasize'))
              .onClick(() => {
                // G7：只复制、不执行。闭包里 this.card 的非空收窄会失效，闭包内自行判空
                if (this.card !== null && this.card.actionHint.length > 0) {
                  PasteboardUtil.copyText(this.card.actionHint);
                }
              })
              .padding({ left: 8 })
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          .margin({ top: 2 })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(10)
      .borderRadius($r('sys.float.corner_radius_level6'))
      .backgroundColor($r('sys.color.comp_background_tertiary'))
      .margin({ top: 4 })
    }
  }
}
