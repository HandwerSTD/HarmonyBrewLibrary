/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { ConfigurationConstant } from '@kit.AbilityKit';
import { BreakpointType, CommonConstants, GlobalInfoModel, StorageKey } from '@ohos/common';
import {
  BaseHomeEventType,
  BaseHomeView,
  OffsetParam,
  TabBarType,
} from '@ohos/commonbusiness';
import { BrewKind } from '@ohos/brewcommon';
import type { BrewCaskCard, BrewCategoryParams, BrewDetailParams, BrewPackageItem } from '@ohos/brewcommon';
import { BrewCaskCardView } from '../component/BrewCaskCardView';

import type { BrewCaskState } from '../viewmodel/BrewCaskState';
import { BrewCaskEventType, BrewCaskHomeViewModel } from '../viewmodel/BrewCaskHomeViewModel';

/**
 * Casks 首页内容区。
 *
 * 与 Formulae 首页（`BrewFormulaBaseView`）一一对应：
 *   BaseHomeView(加载/失败/无网) + WaterFlow(sections) + LazyForEach(分类卡)
 * 卡片也是同一张形态（分类大卡，卡内预览 5 条 + 「查看全部」），差别只有数据形状：
 * Casks 的卡是从「分类 -> 卡片」摊平来的（`BrewCaskHomeViewModel.flattenCards`）。
 *
 * 分类 chips 不在这里 —— 点卡片（或卡上的「查看全部」）进 `BrewCaskCategoryView`，
 * 那边才是「chips 选分类 + 看该分类全部成员」的形态（与 Formulae 的分类二级页对称）。
 */
@Component({ freezeWhenInactive: true })
export struct BrewCaskBaseView {
  @StorageProp(StorageKey.GLOBAL_INFO) @Watch('handleBreakPointChange') globalInfoModel: GlobalInfoModel =
    AppStorage.get(StorageKey.GLOBAL_INFO) ?? new GlobalInfoModel();
  @StorageProp(StorageKey.COLOR_MODE) @Watch('handleColorModeChange') systemColorMode: ConfigurationConstant.ColorMode =
    AppStorage.get(StorageKey.COLOR_MODE) ?? ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
  viewModel: BrewCaskHomeViewModel = BrewCaskHomeViewModel.getInstance();
  @State caskState: BrewCaskState = this.viewModel.getState();

  aboutToAppear(): void {
    this.viewModel.sendEvent({ type: BrewCaskEventType.LOAD_CASK_PAGE, param: null });
    this.viewModel.sendEvent<OffsetParam>({
      type: BaseHomeEventType.HANDLE_BREAKPOINT_CHANGE,
      param: { yOffset: 0, tabIndex: TabBarType.CASKS },
    });
  }

  handleBreakPointChange(): void {
    this.viewModel.sendEvent({ type: BrewCaskEventType.UPDATE_FLOW_SECTION, param: null });
    this.viewModel.sendEvent<OffsetParam>({
      type: BaseHomeEventType.HANDLE_BREAKPOINT_CHANGE,
      param: {
        yOffset: (this.caskState.scroller?.currentOffset()?.yOffset || 0),
        tabIndex: TabBarType.CASKS,
      },
    });
  }

  handleColorModeChange(): void {
    this.viewModel.sendEvent<OffsetParam>({
      type: BaseHomeEventType.HANDLE_COLOR_CHANGE,
      param: {
        yOffset: (this.caskState.scroller?.currentOffset()?.yOffset || 0),
        tabIndex: TabBarType.CASKS,
      },
    });
  }

  jumpDetail(item: BrewPackageItem): void {
    const param: BrewDetailParams = {
      kind: BrewKind.CASK,
      title: item.subTitle,
      id: item.id,
      token: item.token,
      categoryKey: item.categoryKey,
    };
    this.viewModel.sendEvent<BrewDetailParams>({
      type: BrewCaskEventType.JUMP_DETAIL,
      param: param,
    });
  }

  /** 分类卡「查看全部」：进该分类的完整列表（只传 categoryKey，成员由二级页自己取） */
  jumpCategory(card: BrewCaskCard): void {
    const param: BrewCategoryParams = { categoryKey: card.categoryKey };
    this.viewModel.sendEvent<BrewCategoryParams>({
      type: BrewCaskEventType.JUMP_CATEGORY,
      param: param,
    });
  }

  @Builder
  ContentViewBuilder() {
    WaterFlow({ scroller: this.caskState.scroller, sections: this.caskState.sections }) {
      // 顶部让位：一个**空白的 FlowItem 占位块**（高度 = 状态栏 + 标题行）。
      // 为什么必须是「内容里的占位块」而不是容器 padding / contentStartOffset：
      // 容器 padding 会把内容裁剪在 padding 区域之外（内容永远滚不到标题栏下面，
      // 标题栏模糊形同虚设）；contentStartOffset 会把滚动坐标系整体左移 C
      // （静止时 scroller 自报偏移量变成 −C），HDS 的 blurEffectiveStartOffset 够不到那个原点
      // → 用户看到「空行程」。占位块属于内容：不裁剪、不移动原点。详见 brewcommon 的 BrewTitleBar.ets。
      FlowItem() {
        Column()
          .width('100%')
          .height(this.globalInfoModel.statusBarHeight + CommonConstants.NAVIGATION_HEIGHT)
      }
      .width('100%')

      LazyForEach(this.caskState.cardSource, (item: BrewCaskCard) => {
        FlowItem() {
          BrewCaskCardView({
            cardData: item,
            handlePackageClick: (clicked: BrewPackageItem) => {
              this.jumpDetail(clicked);
            },
            handleViewAll: (card: BrewCaskCard) => {
              this.jumpCategory(card);
            },
          })
        }
        .width('100%')
      }, (item: BrewCaskCard) => item.id.toString())

      // 底部让位：同样是内容里的空白块（本页没有「内层容器」可加 margin）
      FlowItem() {
        Column()
          .width('100%')
          .height(this.globalInfoModel.naviIndicatorHeight)
      }
      .width('100%')
    }
    .columnsGap(new BreakpointType({
      sm: $r('sys.float.padding_level6'),
      md: $r('sys.float.padding_level6'),
      lg: $r('sys.float.padding_level8'),
      xl: $r('sys.float.padding_level8'),
    }).getValue(this.globalInfoModel.widthBreakpoint))
    .rowsGap(new BreakpointType({
      sm: $r('sys.float.padding_level8'),
      md: $r('sys.float.padding_level6'),
      lg: $r('sys.float.padding_level8'),
      xl: $r('sys.float.padding_level12'),
    }).getValue(this.globalInfoModel.widthBreakpoint))
    // 固定 Spring：本页没有 banner 需要回弹（与 Formulae 首页、「我的」页一致）
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    // 左右内缩由 section 的 margin 提供（与 Formulae 首页一致，容器上一个 padding 都不写）
    .width('100%')
    .height('100%')
    .cachedCount(4)
    .onDidScroll(() => {
      this.viewModel.sendEvent<OffsetParam>({
        type: BaseHomeEventType.HANDLE_SCROLL_OFFSET,
        param: {
          yOffset: this.caskState.scroller?.currentOffset()?.yOffset ?? 0,
          tabIndex: TabBarType.CASKS,
        },
      });
    })
  }

  build() {
    BaseHomeView({
      loadingModel: this.caskState.loadingModel,
      contentView: () => {
        this.ContentViewBuilder();
      },
      reloadData: () => {
        this.viewModel.sendEvent({ type: BrewCaskEventType.LOAD_CASK_PAGE, param: null });
      },
    })
  }
}
