/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { CommonConstants } from '@ohos/common';
import { BrewKind, BrewPackageItem, BrewPackageRow } from '@ohos/brewcommon';
import type { AiSearchAnswer, AiSearchPick } from '@ohos/brewcommon';
import { AiCatalogIndex } from '../model/AiCatalogIndex';

/**
 * AI 问答混排答案（2026-11-26-ai-search-ask-spec §4.4，m01422 修订）。
 *
 * **一篇长文，内嵌若干包 Item**：全部内容收进同一张大卡（list_card 底 /
 * level8 圆角 / clip），文字统一正文字体（Body_M），行透明嵌在文流里
 * （不再独立成卡）—— 读起来是「lead → 介绍段 → 行 → 介绍段 → 行 → 目录中
 * 相关 → 行… → footer」的连续文章，而不是「行旁边放提示文本」。
 *
 * - 顺序 = LLM 叙事序（首选在前），不经引擎重排（G4）；
 * - 行 = 标准 `BrewPackageRow(hideRank=true)`，透明底融入大卡；
 *   related 行间加 1px 分隔线（连续行区才需要，pick 行之间隔着文字段）；
 * - kind 只信 `AiCatalogIndex`（G5 单一事实源）；行点击走页面统一的 openDetail。
 */
@Component
export struct BrewAiSearchAnswerView {
  @Prop @Require answer: AiSearchAnswer;
  /** 行点击 → 详情页（页面统一入口，与普通搜索行同链路） */
  handleRowClick?: (token: string, kind: string) => void;

  /** pick/related → 行视图模型（desc 用目录原文；AI intro 只放在介绍段，不塞进行里） */
  private rowOf(pick: AiSearchPick): BrewPackageRowVM {
    const vm: BrewPackageRowVM = new BrewPackageRowVM();
    vm.kind = AiCatalogIndex.kindOf(pick.token) === 'cask' ? BrewKind.CASK : BrewKind.FORMULA;
    vm.token = pick.token;
    vm.desc = AiCatalogIndex.descOf(pick.token);
    vm.item.token = pick.token;
    vm.item.subTitle = pick.token;
    vm.item.title = vm.desc;
    vm.item.installs30d = AiCatalogIndex.vol30dOf(pick.token);
    return vm;
  }

  /** 段落文字的统一样式：正文 Body_M + 21 行高；水平缩进 level4（比行窄一档，段落感） */
  @Builder
  ParagraphBuilder(text: string, color: Resource, maxLines: number) {
    Text(text)
      .fontSize($r('sys.float.Body_M'))
      .fontColor(color)
      .maxLines(maxLines)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .lineHeight(21)
      .width(CommonConstants.FULL_PERCENT)
      .padding({
        left: $r('sys.float.padding_level4'),
        right: $r('sys.float.padding_level4'),
      })
  }

  @Builder
  LeadBuilder() {
    if (this.answer.lead.length > 0) {
      // 总起段：字体与正文一致（m01422），只靠颜色深浅区分主次
      Column() {
        this.ParagraphBuilder(this.answer.lead, $r('sys.color.font_primary'), 3)
      }
      .margin({ bottom: $r('sys.float.padding_level4') })
      .width(CommonConstants.FULL_PERCENT)
    }
  }

  @Builder
  IntroBuilder(intro: string) {
    if (intro.length > 0) {
      // 介绍段与它引领的行紧挨（level2），行与下一段落隔 level4
      Column() {
        this.ParagraphBuilder(intro, $r('sys.color.font_secondary'), 4)
      }
      .margin({ top: $r('sys.float.padding_level4'), bottom: $r('sys.float.padding_level2') })
      .width(CommonConstants.FULL_PERCENT)
    }
  }

  /** 行嵌在文流里：透明底（大卡提供底色），间距交给前后段落的 margin 编排 */
  @Builder
  PackageRowBuilder(vm: BrewPackageRowVM) {
    BrewPackageRow({
      packageItem: vm.item,
      kind: vm.kind,
      hideRank: true,
      itemHeight: $r('app.float.brew_package_row_height'),
    })
      .width(CommonConstants.FULL_PERCENT)
      .onClick(() => {
        this.handleRowClick?.(vm.token, vm.kind === BrewKind.CASK ? 'cask' : 'formula');
      })
  }

  /** related 连续行区内的 1px 分隔线（左缩进对齐文字块，右贴卡边距） */
  @Builder
  RelatedDividerBuilder() {
    Row()
      .height(1)
      .width(CommonConstants.FULL_PERCENT)
      .backgroundColor($r('sys.color.comp_background_tertiary'))
      .margin({ left: $r('sys.float.padding_level4'), right: $r('sys.float.padding_level4') })
  }

  @Builder
  RelatedBuilder() {
    if (this.answer.related.length > 0) {
      Column() {
        Text($r('app.string.ai_search_related_header'))
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('sys.color.font_tertiary'))
          .width(CommonConstants.FULL_PERCENT)
          .padding({
            left: $r('sys.float.padding_level4'),
            right: $r('sys.float.padding_level4'),
          })
          .margin({ bottom: $r('sys.float.padding_level2') })
        ForEach(this.answer.related, (pick: AiSearchPick, index: number) => {
          if (index > 0) {
            this.RelatedDividerBuilder()
          }
          this.PackageRowBuilder(this.rowOf(pick))
        }, (pick: AiSearchPick) => `related_${pick.token}`)
      }
      .width(CommonConstants.FULL_PERCENT)
      .alignItems(HorizontalAlign.Start)
      .margin({ top: $r('sys.float.padding_level4') })
    }
  }

  /**
   * 目录外披露（m01462）：AI 提到但本机源里查不到的名字，纯文本列在答案尾部。
   * 不可点击、无详情路由、无任何安装入口——它存在的意义就是让「lead 说 5 个、
   * 实际匹配 3 个」对上账，并明示这些名字**不在**本机目录里（反 slopsquatting：
   * 用户从这里拿不到任何可安装的入口）。
   */
  @Builder
  MissedBuilder() {
    if (this.answer.missed.length > 0) {
      Column({ space: $r('sys.float.padding_level1') }) {
        Text($r('app.string.ai_search_missed_header'))
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_tertiary'))
          .width(CommonConstants.FULL_PERCENT)
          .padding({
            left: $r('sys.float.padding_level4'),
            right: $r('sys.float.padding_level4'),
          })
        Text(this.answer.missed.join('、'))
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_tertiary'))
          .width(CommonConstants.FULL_PERCENT)
          .padding({
            left: $r('sys.float.padding_level4'),
            right: $r('sys.float.padding_level4'),
          })
      }
      .width(CommonConstants.FULL_PERCENT)
      .alignItems(HorizontalAlign.Start)
      .margin({ top: $r('sys.float.padding_level4') })
    }
  }

  @Builder
  FooterBuilder() {
    // 上方一条发丝线把「AI 生成」落款与正文隔开，落款居中小字
    Row()
      .height(1)
      .width(CommonConstants.FULL_PERCENT)
      .backgroundColor($r('sys.color.comp_background_tertiary'))
      .margin({
        left: $r('sys.float.padding_level4'),
        right: $r('sys.float.padding_level4'),
        top: $r('sys.float.padding_level6'),
      })
    Row({ space: $r('sys.float.padding_level2') }) {
      SymbolGlyph($r('sys.symbol.lightbulb'))
        .fontSize($r('sys.float.Body_S'))
        .fontColor([$r('sys.color.icon_tertiary')])
      Text($r('app.string.ai_search_footer'))
        .fontSize($r('sys.float.Body_S'))
        .fontColor($r('sys.color.font_tertiary'))
    }
    .justifyContent(FlexAlign.Center)
    .width(CommonConstants.FULL_PERCENT)
    .margin({ top: $r('sys.float.padding_level4') })
  }

  build() {
    // 一张大卡承载全文：space=0，垂直节奏由各段 margin 手工编排（段落紧行、组间隔开）
    Column() {
      this.LeadBuilder()
      ForEach(this.answer.picks, (pick: AiSearchPick) => {
        this.IntroBuilder(pick.intro)
        this.PackageRowBuilder(this.rowOf(pick))
      }, (pick: AiSearchPick) => `pick_${pick.token}`)
      this.RelatedBuilder()
      this.MissedBuilder()
      this.FooterBuilder()
    }
    .width(CommonConstants.FULL_PERCENT)
    .alignItems(HorizontalAlign.Start)
    .padding($r('sys.float.padding_level6'))
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .borderRadius($r('sys.float.corner_radius_level8'))
    .clip(true)
  }
}

/**
 * 行视图模型：`BrewPackageRow` 的 props 是 `BrewPackageItem`（值导出 class）+
 * `BrewKind`；token/desc/installs30d 从目录索引取（G5 单一事实源）。
 * 注意 `BrewPackageItem` 的命名包袱：`subTitle` 是 primaryText（token 槽位）、
 * `title` 是 secondaryText（desc 槽位）。
 */
export class BrewPackageRowVM {
  public kind: BrewKind = BrewKind.FORMULA;
  public token: string = '';
  public desc: string = '';
  public item: BrewPackageItem = new BrewPackageItem();
}
