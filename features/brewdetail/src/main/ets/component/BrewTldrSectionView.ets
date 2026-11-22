/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { common } from '@kit.AbilityKit';
import { Logger, PasteboardUtil, Toast } from '@ohos/common';
import {
  BrewCli,
  BrewCommandRequest,
  BrewCommandRunner,
  BrewCommandStartResult,
  TldrParser,
  TLDR_REPO_URL,
} from '@ohos/brewcommon';
import type { TldrCodeSegment, TldrExample, TldrPage } from '@ohos/brewcommon';

const TAG: string = '[BrewTldr]';

/** 「已复制」回显的停留时长。短命令复制是瞬间动作，2.5s 足够看清又不会常驻 */
const COPIED_RESET_MS: number = 2500;

/**
 * 详情页的「用法示例」分区（tldr，spec 2026-11-22）。
 *
 * **本组件从不渲染空态**：`hasTldr` 为假时页面根本不会装配它（G6：无数据静默隐藏，
 * 无数据不是错误态）；cask 详情页连 tldr 请求都不发，分区也不会出现（G2）。
 * 因此 build 里假定 `page.examples` 非空 —— 这个前提由 VM 的装配条件保证。
 *
 * 结构（spec §4.1）：分区标题 → 说明段（可选）→ 示例卡片列表 → 署名行。
 * 「执行」把示例原文送进既有的执行 Sheet（BrewCommandRunner 单例承载，
 * 流式输出 / 中断 / 退出码全部复用），不做任何改写或参数猜测。
 */
@Component
export struct BrewTldrSectionView {
  @Prop @Require token: string;
  @Prop @Require page: TldrPage;

  build() {
    Column() {
      Text($r('app.string.brew_tldr_section_title'))
        .fontSize($r('sys.float.Title_S'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .width('100%')
        .margin({ bottom: $r('sys.float.padding_level6') })

      if (this.page.summary.length > 0) {
        Text(this.page.summary)
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
          .margin({ bottom: $r('sys.float.padding_level6') })
      }

      ForEach(this.page.examples, (example: TldrExample, index: number) => {
        BrewTldrExampleCard({ token: this.token, example: example })
      }, (example: TldrExample, index: number) => `tldr_example_${index}`)

      // 署名行（G11）：固定文案，点击打开 tldr-pages 仓库。tldr 内容 CC BY 4.0，署名是分发条件
      Row() {
        Text($r('app.string.brew_tldr_attribution'))
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_tertiary'))
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize($r('sys.float.Body_S'))
          .fontColor([$r('sys.color.icon_fourth')])
          .margin({ left: $r('sys.float.padding_level1') })
      }
      .width('100%')
      .justifyContent(FlexAlign.Start)
      .alignItems(VerticalAlign.Center)
      .margin({ top: $r('sys.float.padding_level4') })
      .onClick(() => {
        this.openRepo();
      })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding($r('sys.float.padding_level6'))
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .borderRadius($r('sys.float.corner_radius_level8'))
  }

  /** 署名行跳转。openLink 在 UIAbilityContext 上；宿主拿不到时记日志静默结束 */
  private openRepo(): void {
    const host: Context | undefined = this.getUIContext().getHostContext();
    if (host === undefined) {
      Logger.warn(TAG, 'openRepo skipped, host context unavailable');
      return;
    }
    const ability: common.UIAbilityContext = host as common.UIAbilityContext;
    ability.openLink(TLDR_REPO_URL).catch((error: Error) => {
      Logger.warn(TAG, `openRepo failed, msg=${error.message}`);
    });
  }
}

/**
 * 一张示例卡：说明行 + 等宽命令块（占位符高亮）+ 行尾操作。
 *
 * 占位符高亮是**展示层唯一**的加工：`Span` 序列来自 `TldrParser.splitCodeSegments`，
 * 全部段拼接与 `code` 逐字一致 —— 所以「渲染的命令文本」就是原文，复制（G3）与
 * 执行送进 Sheet 的都是同一段字符串。
 */
@Component
struct BrewTldrExampleCard {
  @Prop @Require token: string;
  @Prop @Require example: TldrExample;
  @State copied: boolean = false;
  private copyResetTimer: number = 0;

  aboutToDisappear(): void {
    if (this.copyResetTimer !== 0) {
      clearTimeout(this.copyResetTimer);
      this.copyResetTimer = 0;
    }
  }

  build() {
    Column() {
      Text(this.example.desc)
        .fontSize($r('sys.float.Body_M'))
        .fontColor($r('sys.color.font_primary'))
        .width('100%')
        .margin({ bottom: $r('sys.float.padding_level4') })

      // 命令块：等宽字体 + 占位符高亮（spec §4.1）。复制走下面的专用按钮（G3），
      // 不依赖文本选择（`Text.selectable` 在本 SDK 档位不可用，编译已实测）
      Column() {
        Text() {
          ForEach(TldrParser.splitCodeSegments(this.example.code),
            (segment: TldrCodeSegment, index: number) => {
              Span(segment.text)
                .fontFamily('monospace')
                .fontColor(segment.placeholder ? $r('sys.color.warning') : $r('sys.color.font_primary'))
            }, (segment: TldrCodeSegment, index: number) => `tldr_seg_${index}`)
        }
        .fontSize($r('sys.float.Body_M'))
        .width('100%')

        Row() {
          Blank().layoutWeight(1)
          Button(this.copied ? $r('app.string.brew_tldr_copied') : $r('app.string.brew_tldr_copy'))
            .fontSize($r('sys.float.Body_M'))
            .fontColor($r('sys.color.font_primary'))
            .backgroundColor($r('sys.color.comp_background_secondary'))
            .height($r('app.float.brew_detail_copy_button_height'))
            .margin({ right: $r('sys.float.padding_level2') })
            .onClick(() => {
              this.copyCommand();
            })
          if (this.canRun()) {
            Button($r('app.string.brew_tldr_run'))
              .fontSize($r('sys.float.Body_M'))
              .fontColor($r('sys.color.font_on_primary'))
              .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
              .height($r('app.float.brew_detail_copy_button_height'))
              .onClick(() => {
                this.runExample();
              })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ top: $r('sys.float.padding_level2') })
      }
      .width('100%')
      .padding({
        left: $r('sys.float.padding_level8'),
        right: $r('sys.float.padding_level4'),
        top: $r('sys.float.padding_level4'),
        bottom: $r('sys.float.padding_level4'),
      })
      .borderRadius($r('sys.float.corner_radius_level6'))
      .backgroundColor($r('sys.color.comp_background_tertiary'))
    }
    .width('100%')
    .padding($r('sys.float.padding_level4'))
    .borderRadius($r('sys.float.corner_radius_level6'))
    .backgroundColor($r('sys.color.comp_background_secondary'))
    .margin({ bottom: $r('sys.float.padding_level4') })
  }

  /** 「执行」的显示条件（G4 + G10）：无占位符，且本版本开了执行通道 */
  private canRun(): boolean {
    return !this.example.hasPlaceholder && BrewCli.isEnabled();
  }

  /** 复制命令原文。内容与渲染文本逐字一致（G3）——两者同源于 `example.code` */
  private copyCommand(): void {
    // PasteboardUtil 自带成功/失败 Toast；按钮文案再回显一次「已复制」
    PasteboardUtil.copyText(this.example.code);
    this.copied = true;
    if (this.copyResetTimer !== 0) {
      clearTimeout(this.copyResetTimer);
    }
    this.copyResetTimer = setTimeout(() => {
      this.copyResetTimer = 0;
      this.copied = false;
    }, COPIED_RESET_MS);
  }

  /**
   * 一键执行：示例原文直接进既有执行 Sheet。
   *
   * `rawCommand` 模式下 runner 用 `TldrParser.isExecutable` 复核一次（G4 的通道侧兜底），
   * 提示沿用 brew 命令的同款文案（busy / unavailable / bad name 的用户语义完全相同）。
   * 本条示例正在执行时点击只重新打开 Sheet —— 与详情页安装按钮同一行为。
   */
  private runExample(): void {
    const runner: BrewCommandRunner = BrewCommandRunner.getInstance();
    if (runner.isRunningArgs(this.example.code)) {
      runner.openSheet();
      return;
    }
    const request: BrewCommandRequest = new BrewCommandRequest(
      $r('app.string.brew_cmd_title_tldr', this.token), this.example.code, this.example.code);
    request.rawCommand = this.example.code;
    const result: BrewCommandStartResult = runner.start(request);
    if (result === BrewCommandStartResult.STARTED) {
      runner.openSheet();
      return;
    }
    if (result === BrewCommandStartResult.BUSY) {
      Toast.showToast($r('app.string.brew_cmd_busy'));
    } else if (result === BrewCommandStartResult.UNAVAILABLE) {
      Toast.showToast($r('app.string.brew_cmd_unavailable'));
    } else {
      Toast.showToast($r('app.string.brew_cmd_bad_name'));
    }
  }
}
