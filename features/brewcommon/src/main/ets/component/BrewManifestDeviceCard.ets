/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { CommonModifier } from '@kit.ArkUI';
import { CommonConstants } from '@ohos/common';
import { BREW_CATEGORY_PREVIEW_COUNT } from '../constant/BrewConstants';
import { BrewKind } from '../model/BrewModels';
import { BrewPackageIcon } from './BrewPackageIcon';
import { BrewIconSize } from '../constant/BrewIconStyle';
import { BrewInstalledLoader } from '../service/BrewInstalledLoader';
import type { BrewSyncPackageDoc } from '../model/BrewSyncModels';

/**
 * 设备清单卡（spec §4.2.1）：Formulae 分类卡同构复刻，语义从「分类」换成「设备」。
 *
 * 卡头自绘（BrewCategoryCardHeader 是 categoryKey→name/symbol 映射，装不下
 * 设备名这种动态文本）：设备 symbol（laptop / pc 按 deviceType 挑）+ 设备名 +
 * 包数 + 本机标记。卡内前 `BREW_CATEGORY_PREVIEW_COUNT` 条（与 Formulae 卡
 * 共用同一常量——截断与 hasMore 判据同源，不新设）；底部「查看全部」同款；
 * 整卡点击 = 查看全部、点行优先（手势不冒泡已验证）。
 *
 * 行右槽只表达「装没装本机」这一二值事实（「已在本机」灰字）；新装区的
 * 状态机 chip（待装/已入队/…）在 Sheet ③ 区，不在设备卡里。
 */
@Component
export struct BrewManifestDeviceCard {
  /** 投影到卡上的包（已按 token 字典序排好）。 */
  @Prop @Require packages: BrewSyncPackageDoc[];
  @Prop @Require deviceName: string;
  @Prop @Require itemCount: number;
  @Prop isSelf: boolean = false;
  /** 设备名旁的英文第二行（与 Formulae 卡头的中英双行排版对齐）。 */
  @Prop deviceKindText: string = '';
  handlePackageClick?: (pkg: BrewSyncPackageDoc) => void;
  handleViewAll?: () => void;

  /** 本机已装的 token 集合（「已在本机」判定；aboutToAppear 时取快照）。 */
  @State private installedTokens: Set<string> = new Set<string>();

  aboutToAppear(): void {
    const snap = BrewInstalledLoader.snapshot();
    if (snap !== null) {
      for (const one of snap.sets.installed) {
        this.installedTokens.add(one.name);
      }
    }
  }

  private previewItems(): BrewSyncPackageDoc[] {
    return this.packages.slice(0, BREW_CATEGORY_PREVIEW_COUNT);
  }

  @Builder
  HeaderBuilder() {
    Row() {
      Column() {
        SymbolGlyph($r('sys.symbol.pc'))
          .fontColor([$r('sys.color.icon_emphasize')])
          .fontSize($r('app.float.brew_card_header_icon_size'))
      }
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .width($r('app.float.brew_monogram_size'))
      .height($r('app.float.brew_monogram_size'))
      .borderRadius($r('sys.float.corner_radius_level5'))
      .backgroundColor($r('sys.color.comp_background_tertiary'))
      .margin({ right: $r('sys.float.padding_level8') })

      Column() {
        Row() {
          Text(this.deviceName)
            .fontSize($r('sys.float.Title_S'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .maxLines(1)
            .ellipsisMode(EllipsisMode.END)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.isSelf) {
            // 「本机」标记（spec §4.2.1）：清单就是本机读出来的，区别于组网远端设备。
            Text($r('app.string.sync_device_self'))
              .fontSize($r('sys.float.Body_S'))
              .fontColor($r('sys.color.interactive_active'))
              .padding({
                left: $r('sys.float.padding_level4'),
                right: $r('sys.float.padding_level4'),
                top: 1,
                bottom: 1,
              })
              .borderRadius($r('sys.float.corner_radius_level2'))
              .backgroundColor($r('sys.color.comp_background_tertiary'))
              .margin({ left: $r('sys.float.padding_level4') })
          }
        }
        .alignItems(VerticalAlign.Center)
        if (this.deviceKindText.length > 0) {
          Text(this.deviceKindText)
            .fontSize($r('sys.float.Body_S'))
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
            .ellipsisMode(EllipsisMode.END)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: $r('sys.float.padding_level2') })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text($r('app.string.brew_label_packages_count', this.itemCount))
        .fontSize($r('sys.float.Body_S'))
        .fontColor($r('sys.color.font_tertiary'))
        .margin({ left: $r('sys.float.padding_level6') })
    }
    .alignItems(VerticalAlign.Center)
    .width(CommonConstants.FULL_PERCENT)
    .height($r('app.float.brew_card_header_height'))
    .padding({
      left: $r('sys.float.padding_level6'),
      right: $r('sys.float.padding_level8'),
    })
  }

  @Builder
  ViewAllBuilder() {
    Row() {
      Text($r('app.string.brew_action_view_all'))
        .fontSize($r('sys.float.Body_M'))
        .fontColor($r('sys.color.font_secondary'))
      Blank()
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize($r('sys.float.Title_M'))
        .fontColor([$r('sys.color.icon_secondary')])
    }
    .width(CommonConstants.FULL_PERCENT)
    .alignItems(VerticalAlign.Center)
    .padding({
      left: $r('sys.float.padding_level8'),
      right: $r('sys.float.padding_level8'),
      top: $r('sys.float.padding_level4'),
      bottom: $r('sys.float.padding_level4'),
    })
    .onClick(() => {
      this.handleViewAll?.();
    })
  }

  /** 行（BrewPackageRow 同排版，右槽换「已在本机」）。 */
  @Builder
  PackageRow(pkg: BrewSyncPackageDoc) {
    Row() {
      Column() {
        BrewPackageIcon({ kind: this.kindOf(pkg), boxSize: BrewIconSize.ROW })
      }
      .margin({ right: $r('sys.float.padding_level4') })

      Column() {
        Text(pkg.token)
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .ellipsisMode(EllipsisMode.END)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.subTitleOf(pkg))
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(1)
          .ellipsisMode(EllipsisMode.END)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: $r('sys.float.padding_level2') })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Row() {
        if (this.installedTokens.has(pkg.token)) {
          Text($r('app.string.sync_pkg_installed_here'))
            .fontSize($r('sys.float.Body_S'))
            .fontColor($r('sys.color.font_tertiary'))
            .maxLines(1)
            .ellipsisMode(EllipsisMode.END)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontColor([$r('sys.color.icon_secondary')])
          .fontSize($r('sys.float.Title_M'))
          .margin({ left: $r('sys.float.padding_level4') })
      }
      .alignItems(VerticalAlign.Center)
      .padding({ right: $r('sys.float.padding_level4') })
    }
    .alignItems(VerticalAlign.Center)
    .height($r('app.float.brew_package_row_height'))
    .padding({ left: $r('sys.float.padding_level6'), right: $r('sys.float.padding_level4') })
    .onClick(() => {
      this.handlePackageClick?.(pkg);
    })
  }

  private kindOf(pkg: BrewSyncPackageDoc): BrewKind {
    return pkg.kind === BrewKind.CASK ? BrewKind.CASK : BrewKind.FORMULA;
  }

  /** 副标题：tap 非空显示 tap，否则 kind 描述（命令行工具/图形应用）。 */
  private subTitleOf(pkg: BrewSyncPackageDoc): ResourceStr {
    if (pkg.tap.length > 0) {
      return pkg.tap;
    }
    return this.kindOf(pkg) === BrewKind.CASK ?
      $r('app.string.sync_pkg_kind_cask') : $r('app.string.sync_pkg_kind_formula');
  }

  private cardModifier(): CommonModifier {
    const modifier: CommonModifier = new CommonModifier();
    modifier.clickEffect({ level: ClickEffectLevel.MIDDLE });
    return modifier;
  }

  build() {
    Column() {
      this.HeaderBuilder()

      Divider()
        .strokeWidth('1px')
        .color($r('sys.color.comp_background_tertiary'))
        .margin({ bottom: $r('sys.float.padding_level2') })

      ForEach(this.previewItems(), (pkg: BrewSyncPackageDoc) => {
        this.PackageRow(pkg)
      }, (pkg: BrewSyncPackageDoc, index: number) => `${pkg.identity()}#${index}`)

      if (this.packages.length > BREW_CATEGORY_PREVIEW_COUNT) {
        this.ViewAllBuilder()
      }
    }
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .borderRadius($r('sys.float.corner_radius_level8'))
    .clip(true)
    .width(CommonConstants.FULL_PERCENT)
    .padding({ bottom: $r('sys.float.padding_level2') })
    .attributeModifier(this.cardModifier())
    .onClick(() => {
      this.handleViewAll?.();
    })
  }
}
