/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { ConfigurationConstant } from '@kit.AbilityKit';
import { LengthMetrics } from '@kit.ArkUI';
import { HdsNavDestination } from '@kit.UIDesignKit';
import type { TitleBarStyleOptions } from '@kit.UIDesignKit';
import {
  CommonConstants,
  GlobalInfoModel,
  PageEnum,
  StatePlaceholderKind,
  StatePlaceholderView,
  StatusBarColorType,
  StorageKey,
} from '@ohos/common';
import {
  BrewInstalledLoader,
  BrewKind,
  BrewManifestDeviceParams,
  BrewManifestSyncService,
  BrewPackageIcon,
  brewPageContentLeft,
  brewPageContentRight,
  brewTitleBarStyle,
  brewTitleBarTotalHeight,
} from '@ohos/brewcommon';
import type { BrewDetailParams, BrewSyncPackageDoc } from '@ohos/brewcommon';

/**
 * W′ 设备清单二级页（spec §4.2.2）：设备卡「查看全部」进来，展示那台设备的完整主动安装清单。
 *
 * 版式照搬 BrewFormulaCategoryView（List + 让位首项 + 首末圆角拼卡 + 底部让位导航条）；
 * 无 chip bar。与分类页的差别：
 *   1. 数据在 service state 内存里（路由参数 {deviceId}），零等待——没有 loading/失败态分派；
 *   2. 行右槽不是热度，而是「已在本机」（与设备卡同一口径：只表达装没装本机这一二值事实）；
 *   3. 行点击进包详情（id=0 本机包派生口径），pc_normal 也可进——浏览不受 G9 闸。
 *
 * 清单是 KB 级集合（几十到几百条），`ForEach` 一次性构建可接受，不需要 LazyForEach 虚拟化
 * （分类页上虚拟滚动是因为单分类可达数千行，这里的量级差一个数量级以上）。
 */
@Component
export struct BrewManifestDevicePage {
  @StorageProp(StorageKey.GLOBAL_INFO) globalInfoModel: GlobalInfoModel =
    AppStorage.get(StorageKey.GLOBAL_INFO) ?? new GlobalInfoModel();
  @StorageProp(StorageKey.COLOR_MODE) systemColorMode: ConfigurationConstant.ColorMode =
    AppStorage.get(StorageKey.COLOR_MODE) ?? ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
  // 标题栏模糊共用 brewTitleBarStyle()（区间位置与长度只在 BrewTitleBar 里定义一次）
  @State titleBarStyle: TitleBarStyleOptions = brewTitleBarStyle('manifest-device');
  /** 返回键防重入。必须是本组件的 @State（跨页复用不复位的坑，docs §10.4.1）。 */
  @State backPressed: boolean = false;
  /** 本页展示的设备（deviceId 路由参数 → service state 内存取，零等待） */
  @State packages: BrewSyncPackageDoc[] = [];
  @State deviceName: string = '';
  /** 设备不存在（state 里没有这个 deviceId）→ 空态占位 */
  @State deviceFound: boolean = true;
  /** 「已在本机」判定集合：进入页面时取一次快照 */
  private installedTokens: Set<string> = new Set<string>();
  private pathStack?: NavPathStack;

  aboutToAppear(): void {
    const snapshot = BrewInstalledLoader.snapshot();
    if (snapshot) {
      this.installedTokens = new Set<string>(snapshot.sets.installed.map((item) => item.name));
    }
  }

  private handleOnReady(ctx: NavDestinationContext): void {
    this.pathStack = ctx?.pathStack;
    const params = ctx?.pathInfo?.param as BrewManifestDeviceParams;
    const deviceId = params?.deviceId ?? '';
    const entry = BrewManifestSyncService.getInstance().getState().devices
      .find((item) => item.deviceId === deviceId);
    if (entry) {
      this.deviceName = entry.deviceName;
      this.packages = entry.packages;
      this.deviceFound = true;
    } else {
      this.deviceFound = false;
    }
  }

  /** 行点击进包详情（与 MinePackagesUtil.detailParamsOf 同口径：id=0 本机包派生） */
  private jumpDetail(pkg: BrewSyncPackageDoc): void {
    const params: BrewDetailParams = {
      kind: pkg.kind === 'cask' ? BrewKind.CASK : BrewKind.FORMULA,
      title: pkg.token,
      id: 0,
      token: pkg.token,
      categoryKey: '',
    };
    this.pathStack?.pushPath({ name: PageEnum.BREW_DETAIL_VIEW, param: params });
  }

  /** 副文本：tap 非空给 tap，否则给类型描述（与设备卡同一口径） */
  private subTitleOf(pkg: BrewSyncPackageDoc): ResourceStr {
    if (pkg.tap.length > 0) {
      return pkg.tap;
    }
    return pkg.kind === 'cask' ? $r('app.string.sync_pkg_kind_cask') : $r('app.string.sync_pkg_kind_formula');
  }

  private contentLeft(): Length {
    return brewPageContentLeft(this.globalInfoModel);
  }

  private contentRight(): Length {
    return brewPageContentRight(this.globalInfoModel);
  }

  /** 成员行：与 BrewManifestDeviceCard 的行同排版，右槽「已在本机」（spec §4.2.2） */
  @Builder
  PackageRow(pkg: BrewSyncPackageDoc, isLast: boolean) {
    Row() {
      BrewPackageIcon({ kind: pkg.kind === 'cask' ? BrewKind.CASK : BrewKind.FORMULA })
      Column() {
        Text(pkg.token)
          .fontSize($r('sys.float.Body_M'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.subTitleOf(pkg))
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_secondary'))
          .margin({ top: $r('sys.float.padding_level2') })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (this.installedTokens.has(pkg.token)) {
        Text($r('app.string.sync_pkg_installed_here'))
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_tertiary'))
      }
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize($r('sys.float.Title_S'))
        .fontColor([$r('sys.color.icon_fourth')])
    }
    .width(CommonConstants.FULL_PERCENT)
    .height($r('app.float.brew_package_row_height'))
    .padding({
      left: $r('sys.float.padding_level6'),
      right: $r('sys.float.padding_level4'),
    })
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .borderRadius(isLast ? {
      bottomLeft: $r('sys.float.corner_radius_level8'),
      bottomRight: $r('sys.float.corner_radius_level8'),
    } : 0)
    .onClick(() => {
      this.jumpDetail(pkg);
    })
  }

  @Builder
  ContentBuilder() {
    List() {
      // 顶部让位 = 标题行（无 banner 的 List 按标题栏总高让位，docs/hds-titlebar-blur.md §2）
      ListItem() {
        Row().height(brewTitleBarTotalHeight(this.globalInfoModel.statusBarHeight))
      }

      // 卡头：设备名 + 包数（自绘，BrewCategoryCardHeader 是分类映射装不下设备名）
      ListItem() {
        Column() {
          Row() {
            SymbolGlyph($r('sys.symbol.pc'))
              .fontSize($r('sys.float.Title_M'))
              .fontColor([$r('sys.color.icon_emphasize')])
              .padding($r('sys.float.padding_level4'))
              .backgroundColor($r('sys.color.comp_background_tertiary'))
              .borderRadius($r('sys.float.corner_radius_level5'))
              .margin({ right: $r('sys.float.padding_level8') })
            Column() {
              Text(this.deviceName)
                .fontSize($r('sys.float.Title_S'))
                .fontWeight(FontWeight.Medium)
                .fontColor($r('sys.color.font_primary'))
              Text($r('app.string.brew_label_packages_count', this.packages.length))
                .fontSize($r('sys.float.Body_S'))
                .fontColor($r('sys.color.font_secondary'))
                .margin({ top: $r('sys.float.padding_level2') })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .width(CommonConstants.FULL_PERCENT)
          .padding({
            left: $r('sys.float.padding_level6'),
            right: $r('sys.float.padding_level8'),
          })
          Divider()
            .strokeWidth('1px')
            .color($r('sys.color.comp_background_tertiary'))
            .margin({ bottom: $r('sys.float.padding_level2') })
        }
        .width(CommonConstants.FULL_PERCENT)
        .backgroundColor($r('sys.color.comp_background_list_card'))
        .borderRadius({
          topLeft: $r('sys.float.corner_radius_level8'),
          topRight: $r('sys.float.corner_radius_level8'),
        })
      }
      .padding({ left: this.contentLeft(), right: this.contentRight() })

      // 全量成员行
      ForEach(this.packages, (pkg: BrewSyncPackageDoc, index: number) => {
        ListItem() {
          this.PackageRow(pkg, index === this.packages.length - 1)
        }
        .padding({ left: this.contentLeft(), right: this.contentRight() })
      }, (pkg: BrewSyncPackageDoc, index: number) => `${pkg.kind}/${pkg.tap}/${pkg.token}#${index}`)

      // 底部让位：导航条
      ListItem() {
        Row().height(this.globalInfoModel.naviIndicatorHeight)
      }
    }
    .width(CommonConstants.FULL_PERCENT)
    .height(CommonConstants.FULL_PERCENT)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
  }

  build() {
    HdsNavDestination() {
      if (this.deviceFound && this.packages.length > 0) {
        this.ContentBuilder()
      } else if (!this.deviceFound) {
        StatePlaceholderView({
          kind: StatePlaceholderKind.EMPTY,
          message: $r('app.string.state_no_data'),
        })
      } else {
        StatePlaceholderView({
          kind: StatePlaceholderKind.EMPTY,
          message: $r('app.string.sync_empty_no_pending'),
        })
      }
    }
    .hideBackButton(false)
    .backgroundColor($r('sys.color.background_secondary'))
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .titleBar({
      padding: {
        start: LengthMetrics.vp(CommonConstants.SPACE_16),
        end: LengthMetrics.vp(CommonConstants.SPACE_16),
      },
      avoidLayoutSafeArea: true,
      style: this.titleBarStyle,
      content: {
        title: { mainTitle: $r('app.string.sync_device_page_title', this.deviceName) },
      },
    })
    .systemBarStyle({
      statusBarContentColor: this.systemColorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK ?
        StatusBarColorType.WHITE : StatusBarColorType.BLACK
    }, {
      statusBarContentColor: this.systemColorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK ?
        StatusBarColorType.WHITE : StatusBarColorType.BLACK
    })
    .onReady((ctx: NavDestinationContext) => this.handleOnReady(ctx))
    .onBackPressed(() => {
      if (this.backPressed) {
        return true;
      }
      this.backPressed = true;
      if (this.pathStack) {
        this.pathStack.pop();
        return true;
      }
      return false;
    })
  }
}

@Builder
export function BrewManifestDevicePageBuilder() {
  BrewManifestDevicePage()
}
