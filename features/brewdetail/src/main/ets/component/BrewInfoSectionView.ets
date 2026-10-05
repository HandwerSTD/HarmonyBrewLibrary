/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { PasteboardUtil } from '@ohos/common';
import type { BrewInfoRow, BrewInfoSection } from '@ohos/brewcommon';

/**
 * 元信息条（§5.3 分区 3）：版本 / 许可 / 近 30 天安装量 / 分类内排名。
 *
 * 与 BrewInfoSectionView 的区别是这里**没有分区标题**、且是横向流式排布 ——
 * 这几个值都很短，竖排会把首屏撑得很空。
 */
@Component
export struct BrewDetailMetaBar {
  @Prop @Require rows: BrewInfoRow[];

  @Builder
  MetaItem(row: BrewInfoRow) {
    Row() {
      Text(row.label)
        .fontSize($r('sys.float.Body_S'))
        .fontColor($r('sys.color.font_tertiary'))
      Text(row.value)
        .fontSize($r('sys.float.Body_S'))
        .fontColor($r('sys.color.font_primary'))
        .margin({ left: $r('sys.float.padding_level2') })
    }
    .alignItems(VerticalAlign.Center)
    .padding({
      left: $r('sys.float.padding_level4'),
      right: $r('sys.float.padding_level4'),
      top: $r('sys.float.padding_level2'),
      bottom: $r('sys.float.padding_level2'),
    })
    .margin({
      right: $r('sys.float.padding_level4'),
      bottom: $r('sys.float.padding_level4'),
    })
    .borderRadius($r('sys.float.corner_radius_level4'))
    .backgroundColor($r('sys.color.comp_background_tertiary'))
  }

  build() {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(this.rows, (row: BrewInfoRow, index: number) => {
        this.MetaItem(row)
      }, (row: BrewInfoRow, index: number) => `meta_${index}`)
    }
    .width('100%')
  }
}

/**
 * 详情页的一个通用分区（§5.3 分区 4/5/6/7/11 共用）：标题 + 若干「标签 值」行。
 *
 * 做成数据驱动的（吃 `BrewInfoSection`）而不是每个分区写一段 UI：
 * 两种包的字段差异已经在 BrewDetailNormalizer 里摊平，
 * 再在 UI 层为每个分区写一遍会把这个差异重新引回来。
 */
@Component
export struct BrewInfoSectionView {
  @Prop @Require section: BrewInfoSection;

  build() {
    Column() {
      Text(this.section.title)
        .fontSize($r('sys.float.Title_S'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .margin({ bottom: $r('sys.float.padding_level6') })

      ForEach(this.section.rows, (row: BrewInfoRow, index: number) => {
        Row() {
          Text(row.label)
            .fontSize($r('sys.float.Body_M'))
            .fontColor($r('sys.color.font_secondary'))
            .constraintSize({ minWidth: $r('app.float.brew_detail_label_width') })
            .margin({ right: $r('sys.float.padding_level8') })
          Text(row.value)
            .fontSize($r('sys.float.Body_M'))
            .fontColor($r('sys.color.font_primary'))
            .layoutWeight(1)
        }
        .alignItems(VerticalAlign.Top)
        .width('100%')
        .padding({
          top: $r('sys.float.padding_level3'),
          bottom: $r('sys.float.padding_level3'),
        })
      }, (row: BrewInfoRow, index: number) => `${index}`)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding($r('sys.float.padding_level6'))
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .borderRadius($r('sys.float.corner_radius_level8'))
  }
}

/**
 * 安装命令 + 复制按钮（§5.3 分区 2）。
 *
 * 决策：只展示基础命令 `brew install <token>`，不做交互式安装选项面板 ——
 * 官方 API 的 `options` 字段实测恒为空，没有数据支撑选项面板（§5.1）。
 *
 * 主操作按钮（安装 / 升级 / 已安装）不在这里：它挪到了页面底部的悬浮操作栏
 * （`BrewDetailView.ActionBarBuilder()`），本卡片只负责命令文本与「复制」按钮。
 * 两件事分开的原因见 2026-10-05-brew-detail-action-bar-spec.md：主操作要一条
 * 通栏的渐变模糊背板，而卡片的标题行给不了。
 */
@Component
export struct BrewInstallCommandCard {
  @Prop @Require command: string;

  build() {
    Column() {
      Text($r('app.string.brew_label_install_command'))
        .fontSize($r('sys.float.Title_S'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .width('100%')
        .margin({ bottom: $r('sys.float.padding_level6') })

      Row() {
        Text(this.command)
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('sys.color.font_primary'))
          .layoutWeight(1)
        Button($r('app.string.brew_action_copy'))
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('sys.color.font_primary'))
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          .height($r('app.float.brew_detail_copy_button_height'))
          .margin({ left: $r('sys.float.padding_level8') })
          .onClick(() => {
            // PasteboardUtil 自带成功/失败 Toast
            PasteboardUtil.copyText(this.command);
          })
      }
      .alignItems(VerticalAlign.Center)
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
    .padding($r('sys.float.padding_level6'))
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .borderRadius($r('sys.float.corner_radius_level8'))
  }
}
