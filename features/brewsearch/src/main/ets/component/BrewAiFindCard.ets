/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { CommonConstants } from '@ohos/common';
import { AiErrorDetail, AiErrorKind } from '@ohos/brewcommon';
import { AiFindVM, AiFindState } from '../viewmodel/AiFindVM';
import { AiFindRowSource, AiFindRow } from '../model/AiFindRowSource';

/**
 * 「AI 帮我找工具」卡（spec §5，G5 / G6）。
 *
 * 挂在搜索首页（未提交态）的顶部：一个输入框 + 三个示例 chips +
 * 结果列表（token + why + 点击进详情）。AI 模式与词表模式的结果渲染同一份结构。
 *
 * ## 降级（G6）
 *
 * 未配 Key：**不发注定失败的请求**，输入直接走词表模式并显示提示条；
 * AI 模式请求失败（E1/E2/E3）也自动落词表（在 AiFindVM 里分流）。
 *
 * ## G5 防幻觉
 *
 * 结果列表只渲染 `AiTasks.findTools` 过滤后的候选——目录外的名字在任务层已被丢弃，
 * 本组件拿不到也渲染不出目录外的名字。
 */
@Component
export struct BrewAiFindCard {
  /** 点结果行：由页面处理（打开详情页）。 */
  openDetail: (token: string, kind: string) => void = (_token: string, _kind: string) => {
  };

  @State state: AiFindState = new AiFindState();
  @State intent: string = '';
  @State rowSource: AiFindRowSource = new AiFindRowSource();
  private aiFinder: AiFindVM = AiFindVM.getInstance();

  /** 未配 Key 时直接走词表；已配置走 AI（失败自动落词表，在 VM 里分流）。 */
  private submit(): void {
    const text: string = this.intent.trim();
    if (text.length === 0) {
      return;
    }
    if (!this.aiFinder.isConfigured()) {
      this.rowSource.setDataArray(this.aiFinder.findOffline(text, this.state));
      return;
    }
    this.aiFinder.find(text, this.state)
      .then((rows: AiFindRow[] | undefined) => {
        if (rows !== undefined) {
          this.rowSource.setDataArray(rows);
          if (rows.length === 0 && this.state.mode === 'ai') {
            this.state.mode = 'empty';
          }
        }
      });
  }

  private errorText(): ResourceStr {
    if (this.state.errorKind === AiErrorKind.E4_BAD_FORMAT) {
      return AiErrorDetail.e4Text(this.state.errorDetail);
    }
    if (this.state.errorKind === AiErrorKind.E5_BLOCKED) {
      return AiErrorDetail.e5Text(this.state.errorDetail);
    }
    return $r('app.string.ai_error_e2');
  }

  build() {
    Column({ space: 8 }) {
      // ---------- 标题行 ----------
      Text($r('app.string.ai_d2_entry'))
        .fontSize($r('sys.float.Title_S'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .width('100%')

      // ---------- 词表模式提示条（G6）----------
      if (this.state.fallbackNotice) {
        Text($r('app.string.ai_d2_fallback_notice'))
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_tertiary'))
          .width('100%')
          .padding({
            left: 8,
            right: 8,
            top: 4,
            bottom: 4,
          })
          .borderRadius($r('sys.float.corner_radius_level4'))
          .backgroundColor($r('sys.color.comp_background_tertiary'))
      }

      // ---------- 输入行 ----------
      Row() {
        TextInput({ text: this.intent, placeholder: $r('app.string.ai_d2_hint') })
          .height(36)
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('sys.color.font_primary'))
          .placeholderColor($r('sys.color.font_tertiary'))
          .backgroundColor(Color.Transparent)
          .padding(0)
          .layoutWeight(1)
          .enterKeyType(EnterKeyType.Search)
          .onChange((value: string) => {
            this.intent = value;
          })
          .onSubmit(() => {
            this.submit();
          })
        if (this.intent.trim().length > 0) {
          Text($r('app.string.ai_d2_search'))
            .fontSize($r('sys.float.Body_M'))
            .fontColor($r('sys.color.font_emphasize'))
            .onClick(() => {
              this.submit();
            })
            .padding({ left: 8 })
        }
      }
      .width('100%')
      .height(40)
      .alignItems(VerticalAlign.Center)
      .padding({ left: 8, right: 8 })
      .backgroundColor($r('sys.color.comp_background_tertiary'))
      .borderRadius($r('sys.float.corner_radius_level4'))

      // ---------- 示例 chips ----------
      Row({ space: 8 }) {
        this.ExampleChip('我想批量压缩图片')
        this.ExampleChip('录屏')
        this.ExampleChip('查看端口占用')
      }
      .width('100%')

      // ---------- 状态区 ----------
      if (this.state.mode === 'loading') {
        Row() {
          LoadingProgress()
            .width(16)
            .height(16)
          Text($r('app.string.ai_d1_loading'))
            .fontSize($r('sys.float.Body_S'))
            .fontColor($r('sys.color.font_secondary'))
            .margin({ left: 6 })
        }
        .width('100%')
      } else if (this.state.mode === 'error') {
        Text(this.errorText())
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.warning'))
          .width('100%')
      } else if (this.state.mode === 'empty' ||
        (this.rowSource.totalCount() === 0 && this.state.mode !== 'idle')) {
        // 空态（G5：目录外的名字零展示，过滤后为空就是空态）
        Column({ space: 4 }) {
          Text($r('app.string.ai_d2_empty'))
            .fontSize($r('sys.float.Body_M'))
            .fontColor($r('sys.color.font_secondary'))
            .width('100%')
            .textAlign(TextAlign.Center)
          Text($r('app.string.ai_d2_empty_hint'))
            .fontSize($r('sys.float.Body_S'))
            .fontColor($r('sys.color.font_tertiary'))
            .width('100%')
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .padding({ top: 8, bottom: 8 })
      } else if (this.rowSource.totalCount() > 0) {
        // ---------- 结果列表 ----------
        List() {
          ForEach(this.rowSource.all(), (row: AiFindRow, index: number) => {
            ListItem() {
              Column({ space: 2 }) {
                Row() {
                  Text(row.item.token)
                    .fontSize($r('sys.float.Body_M'))
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('sys.color.font_primary'))
                    .layoutWeight(1)
                  Text($r('app.string.brew_search_action'))
                    .fontSize($r('sys.float.Body_S'))
                    .fontColor($r('sys.color.font_emphasize'))
                }
                .width('100%')
                Text(row.why)
                  .fontSize($r('sys.float.Body_S'))
                  .fontColor($r('sys.color.font_secondary'))
                  .width('100%')
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .padding(8)
              .backgroundColor($r('sys.color.comp_background_primary'))
              .borderRadius(index === 0 ? $r('sys.float.corner_radius_level8') :
                $r('sys.float.corner_radius_level4'))
              .onClick(() => {
                this.openDetail(row.item.token, row.kind);
              })
            }
          }, (row: AiFindRow) => `${row.kind}_${row.item.token}`)
        }
        .width('100%')
        .height(Math.min(this.rowSource.totalCount() * 64 + 8, 320))
        .scrollBar(BarState.Off)

        // 角标：AI 提名 · 本地排序（提示这不是官方分类）
        Text($r('app.string.ai_d2_badge'))
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_tertiary'))
          .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .borderRadius($r('sys.float.corner_radius_level8'))
  }

  @Builder
  ExampleChip(text: string) {
    Text(text)
      .fontSize($r('sys.float.Body_S'))
      .fontColor($r('sys.color.font_secondary'))
      .padding({
        left: 8,
        right: 8,
        top: 4,
        bottom: 4,
      })
      .borderRadius($r('sys.float.corner_radius_level4'))
      .backgroundColor($r('sys.color.comp_background_tertiary'))
      .onClick(() => {
        this.intent = text;
        this.submit();
      })
  }
}
