/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { common } from '@kit.AbilityKit';
import { Logger, PasteboardUtil } from '@ohos/common';
import {
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
 * **位置**：「提供的命令」分区正下方 —— 由页面按 `section.key` 装配（formula 独有，
 * cask 详情页整区不出现，G2）。数据异步到达时就地插入（spec §4.2）。
 *
 * **视觉**：扁平列表 —— 外层容器是分区卡（comp_background_list_card，与详情页其它分区
 * 一致），示例之间用 `Divider` 分隔，示例自身不再套独立卡片底色（避免「卡片套卡片」）。
 * 命令行保留一条 tertiary 灰条承载等宽文本，与「安装命令」卡片的命令行同款。
 *
 * **本组件从不渲染空态**：`hasTldr` 为假时页面根本不会装配它（G6：无数据静默隐藏，
 * 无数据不是错误态），因此 build 里假定 `page.examples` 非空 —— 由 VM 的装配条件保证。
 *
 * 结构（spec §4.1）：分区标题 → 说明段（可选）→ 扁平示例列表 → 署名行。
 * 行尾操作只有「复制」（v1.3.3 用户定调：执行按钮移除——命令的执行入口
 * 统一收敛在安装/升级主操作与执行 Sheet,示例命令不提供一键执行）。
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

      // 命名提示行（spec §4.1）：命中页名 ≠ 包名时教用户一句「提供的命令是什么」——
      // ripgrep 的页是 rg、python@3.12 的页是 python，候选链命中后这里把对应关系点破
      if (this.page.command.toLowerCase() !== this.token.toLowerCase()) {
        Text($r('app.string.brew_tldr_command_hint', this.token, this.page.command))
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
          .margin({ bottom: $r('sys.float.padding_level6') })
      }

      if (this.page.summary.length > 0) {
        Text(this.page.summary)
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
          .margin({ bottom: $r('sys.float.padding_level6') })
      }

      ForEach(this.page.examples, (example: TldrExample, index: number) => {
        Column() {
          if (index > 0) {
            Divider()
              .strokeWidth('1px')
              .color($r('sys.color.comp_background_tertiary'))
              .margin({ top: $r('sys.float.padding_level6'), bottom: $r('sys.float.padding_level6') })
          }
          BrewTldrExampleCard({ token: this.token, example: example })
        }
        .width('100%')
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
      .margin({ top: $r('sys.float.padding_level6') })
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
 * 一条示例（**扁平**：无自己的卡片底色与圆角，分隔由父级的 Divider 承担）：
 * 说明行 + 等宽命令灰条（占位符高亮）+ 行尾操作。
 *
 * 占位符高亮是**展示层唯一**的加工：`Span` 序列来自 `TldrParser.splitCodeSegments`，
 * 全部段拼接与 `code` 逐字一致 —— 所以「渲染的命令文本」就是原文，复制（G3）
 * 的就是同一段字符串。
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

      // 命令灰条：等宽字体 + 占位符高亮（spec §4.1）。复制走下面的专用按钮（G3），
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
    .alignItems(HorizontalAlign.Start)
    .width('100%')
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
}
