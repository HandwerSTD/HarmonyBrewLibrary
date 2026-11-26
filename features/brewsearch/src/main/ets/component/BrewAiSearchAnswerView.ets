/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { CommonConstants } from '@ohos/common';
import { BrewKind, BrewPackageItem, BrewPackageRow } from '@ohos/brewcommon';
import type { AiSearchAnswer, AiSearchPick } from '@ohos/brewcommon';
import { AiCatalogIndex } from '../model/AiCatalogIndex';

/**
 * AI 问答混排答案（2026-11-26-ai-search-ask-spec §4.4）。
 *
 * 节奏：文本段（无底色）与行卡（有底色）交替 —— lead 总起段 → 每包
 * 「AI 介绍段 + BrewPackageRow」成对（组内 level2 / 组间 level8）→「目录中相关」
 * 尾行（无介绍段，标题承担身份）→ footer 徽章（AI 生成 · 已由本地目录校验）。
 *
 * - 顺序 = LLM 叙事序（首选在前），不经引擎重排（G4）；
 * - 行 = 标准 `BrewPackageRow(hideRank=true)`，独立卡底 list_card + level8 圆角
 *   （与普通搜索列表的「拼大卡」不同：AI 答案里行是叙事的锚点，独立成卡更像
 *   AppStore Today 的段落式排版）；
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

  @Builder
  LeadBuilder() {
    if (this.answer.lead.length > 0) {
      Text(this.answer.lead)
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('sys.color.font_primary'))
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .lineHeight(24)
        .width(CommonConstants.FULL_PERCENT)
        .padding({ left: $r('sys.float.padding_level6'), right: $r('sys.float.padding_level6') })
        .margin({ bottom: $r('sys.float.padding_level6') })
    }
  }

  @Builder
  IntroBuilder(intro: string) {
    if (intro.length > 0) {
      Text(intro)
        .fontSize($r('sys.float.Body_M'))
        .fontColor($r('sys.color.font_secondary'))
        .maxLines(4)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .lineHeight(21)
        .width(CommonConstants.FULL_PERCENT)
        .padding({ left: $r('sys.float.padding_level6'), right: $r('sys.float.padding_level6') })
    }
  }

  @Builder
  PackageRowBuilder(vm: BrewPackageRowVM) {
    BrewPackageRow({
      packageItem: vm.item,
      kind: vm.kind,
      hideRank: true,
      itemHeight: $r('app.float.brew_package_row_height'),
    })
      .width(CommonConstants.FULL_PERCENT)
      .backgroundColor($r('sys.color.comp_background_list_card'))
      .borderRadius($r('sys.float.corner_radius_level8'))
      .onClick(() => {
        this.handleRowClick?.(vm.token, vm.kind === BrewKind.CASK ? 'cask' : 'formula');
      })
  }

  @Builder
  PickGroupBuilder(pick: AiSearchPick) {
    Column({ space: $r('sys.float.padding_level2') }) {
      this.IntroBuilder(pick.intro)
      this.PackageRowBuilder(this.rowOf(pick))
    }
    .width(CommonConstants.FULL_PERCENT)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  RelatedBuilder() {
    if (this.answer.related.length > 0) {
      Column({ space: $r('sys.float.padding_level4') }) {
        Text($r('app.string.ai_search_related_header'))
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_tertiary'))
          .width(CommonConstants.FULL_PERCENT)
          .padding({ left: $r('sys.float.padding_level6'), right: $r('sys.float.padding_level6') })
        ForEach(this.answer.related, (pick: AiSearchPick) => {
          this.PackageRowBuilder(this.rowOf(pick))
        }, (pick: AiSearchPick) => `related_${pick.token}`)
      }
      .width(CommonConstants.FULL_PERCENT)
      .alignItems(HorizontalAlign.Start)
      .margin({ top: $r('sys.float.padding_level8') })
    }
  }

  @Builder
  FooterBuilder() {
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
    .margin({ top: $r('sys.float.padding_level6') })
  }

  build() {
    Column({ space: $r('sys.float.padding_level8') }) {
      this.LeadBuilder()
      ForEach(this.answer.picks, (pick: AiSearchPick) => {
        this.PickGroupBuilder(pick)
      }, (pick: AiSearchPick) => `pick_${pick.token}`)
      this.RelatedBuilder()
      this.FooterBuilder()
    }
    .width(CommonConstants.FULL_PERCENT)
    .alignItems(HorizontalAlign.Start)
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
