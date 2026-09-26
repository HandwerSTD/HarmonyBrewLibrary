/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { ConfigurationConstant } from '@kit.AbilityKit';
import { LengthMetrics } from '@kit.ArkUI';
import { HdsNavDestination } from '@kit.UIDesignKit';
import type { TitleBarStyleOptions } from '@kit.UIDesignKit';
import {
  BreakpointType,
  CommonConstants,
  GlobalInfoModel,
  LoadingFailedView,
  LoadingStatus,
  NoNetworkView,
  StatusBarColorType,
  StorageKey,
} from '@ohos/common';
import { BrewFormat, brewTitleBarStyle } from '@ohos/brewcommon';
import type { BrewDiscoverBoardParams, BrewDiscoverEntry } from '@ohos/brewcommon';
import { BrewBoardStyle } from '../model/BrewBoardStyle';
import { BrewDiscoverRow, BrewDiscoverRowDivider } from '../component/BrewDiscoverRow';
import { BrewDiscoverBoardState } from '../viewmodel/BrewDiscoverBoardState';
import { BrewDiscoverBoardVM } from '../viewmodel/BrewDiscoverBoardVM';

/**
 * 榜单「查看全部」二级页。
 *
 * 结构照搬「我的 - 本机包」的 MinePackagesView（那里已经有模糊标题栏 + 手动顶部让位 +
 * 返回键防重入的正确写法）：
 *   HdsNavDestination(标题栏) + Scroll(整张榜的全部条目)
 *
 * 两处与它不同：
 *   1. 没有 chips（榜单只有一个口径，不需要筛选）；
 *   2. 标题栏标题由榜单数据决定，所以要在 onReady 拿到 boardId、加载完才知道 ——
 *      加载期间先用空标题，回来后再显示（不会闪，因为同一帧内就会更新）。
 */
@Component
export struct BrewDiscoverBoardView {
  @StorageProp(StorageKey.GLOBAL_INFO) globalInfoModel: GlobalInfoModel =
    AppStorage.get(StorageKey.GLOBAL_INFO) ?? new GlobalInfoModel();
  @StorageProp(StorageKey.COLOR_MODE) systemColorMode: ConfigurationConstant.ColorMode =
    AppStorage.get(StorageKey.COLOR_MODE) ?? ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
  // 标题栏模糊共用 brewTitleBarStyle()（区间位置与长度只在 BrewTitleBar 里定义一次）
  @State titleBarStyle: TitleBarStyleOptions = brewTitleBarStyle('discover-board');
  /**
   * 返回键防重入。**必须是本组件的 @State**：放进共享 state 会跨页面复用、置位后不复位，
   * 表现为「第一次能返回、之后返回键全部失效」（详情页踩过，docs §10.4.1）。
   */
  @State backPressed: boolean = false;
  /**
   * 每页实例一份 state。**不能放在 VM 里当单例字段** —— 同 §10.4.1 的理由。
   */
  @State boardState: BrewDiscoverBoardState = new BrewDiscoverBoardState();
  viewModel: BrewDiscoverBoardVM = BrewDiscoverBoardVM.getInstance();
  private pathStack?: NavPathStack;


  private handleOnReady(ctx: NavDestinationContext): void {
    this.pathStack = ctx?.pathStack;
    const params: BrewDiscoverBoardParams = ctx?.pathInfo?.param as BrewDiscoverBoardParams;
    this.viewModel.load(params?.boardId ?? 0, this.boardState);
  }

  private contentInset(): Length {
    return new BreakpointType<Length>({
      sm: $r('sys.float.padding_level8'),
      md: $r('sys.float.padding_level12'),
      lg: $r('sys.float.padding_level16'),
    }).getValue(this.globalInfoModel.widthBreakpoint);
  }

  /** 数据来源说明。榜单是算法产物，用户有权知道它是怎么来的、覆盖什么时间 */
  @Builder
  ProvenanceBuilder() {
    Text($r('app.string.brew_discover_snapshot', this.boardState.snapshotDate))
      .fontSize($r('sys.float.Body_S'))
      .fontColor($r('sys.color.font_tertiary'))
      .width(CommonConstants.FULL_PERCENT)
      .padding({
        left: $r('sys.float.padding_level8'),
        right: $r('sys.float.padding_level8'),
        bottom: $r('sys.float.padding_level4'),
      })
  }

  @Builder
  ContentBuilder() {
    Scroll() {
      Column() {
        if (this.boardState.board) {
          this.ProvenanceBuilder()
          Column() {
            ForEach(this.boardState.board.entries, (entry: BrewDiscoverEntry, index: number) => {
              BrewDiscoverRow({
                entry: entry,
                kind: BrewFormat.brewKindOf(this.boardState.board?.kind ?? 'formula'),
                handleItemClick: (clicked: BrewDiscoverEntry) => {
                  this.viewModel.jumpDetail(clicked, this.boardState.board?.kind ?? 'formula');
                },
              })
              if (index < (this.boardState.board?.entries.length ?? 0) - 1) {
                BrewDiscoverRowDivider()
              }
            }, (entry: BrewDiscoverEntry) => `${this.boardState.boardId}_${entry.rank}`)
          }
          .width(CommonConstants.FULL_PERCENT)
          .backgroundColor($r('sys.color.comp_background_primary'))
          .borderRadius($r('sys.float.corner_radius_level8'))
          .clip(true)
        }
      }
      .width(CommonConstants.FULL_PERCENT)
      // 顶部/底部让位写成**内层内容的 margin**（与「我的」页 MineView、包详情页完全同款）：
      // margin 属于内容 —— 不裁剪内容，也不移动滚动坐标系原点（静止时 scroller 自报偏移量 = 0），
      // HDS 的模糊区间 [0, ramp] 才能真正从「内容贴在标题栏下沿」那一刻开始渐变。
      //
      // **本页没有 chips 行，所以不能用 `brewTitleBarTotalHeight()`** —— 那个函数把
      // `BREW_CHIP_BAR_HEIGHT`（又一条 56vp）也算进去了，多让一整行，表现为「顶部一片空白」。
      // 与详情页同一个口径：两处都是「标题栏里只有标题」的页面。
      //
      // 底部用 `naviIndicatorHeight + SPACE_24`（同详情页）：2in1 上 naviIndicatorHeight 是 0，
      // 只写它等于没有底部留白，最后一行会直接贴到窗口下沿。
      //
      // 两种旧写法都不行（均实测）：容器 `padding` 会裁剪内容（内容永远滚不到标题栏下面，模糊形同虚设）；
      // `contentStartOffset` 会把滚动坐标系左移 C（静止时自报偏移量 −C），而 HDS 的
      // `blurEffectiveStartOffset` 只接受 [0, +∞)（负数按 0 处理），永远够不到原点 → 空行程。
      // 详见 brewcommon 的 BrewTitleBar.ets。
      .margin({
        top: this.globalInfoModel.statusBarHeight + CommonConstants.NAVIGATION_HEIGHT,
        bottom: this.globalInfoModel.naviIndicatorHeight + CommonConstants.SPACE_24,
      })
      .padding({
        left: this.contentInset(),
        right: this.contentInset(),
      })
    }
    .width(CommonConstants.FULL_PERCENT)
    .height(CommonConstants.FULL_PERCENT)
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
  }

  build() {
    HdsNavDestination() {
      if (this.boardState.loadingModel.loadingStatus === LoadingStatus.SUCCESS) {
        this.ContentBuilder()
      } else if (this.boardState.loadingModel.loadingStatus === LoadingStatus.FAILED) {
        LoadingFailedView(this.globalInfoModel.widthBreakpoint, () => {
          this.viewModel.load(this.boardState.boardId, this.boardState);
        })
      } else if (this.boardState.loadingModel.loadingStatus === LoadingStatus.NO_NETWORK) {
        NoNetworkView(this.globalInfoModel.widthBreakpoint, () => {
          this.viewModel.load(this.boardState.boardId, this.boardState);
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
        title: { mainTitle: BrewBoardStyle.titleOf(this.boardState.board?.boardKey ?? '') },
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
      // 拿不到页面栈时不吞事件，交给系统默认出栈，而不是让返回键彻底失效
      return false;
    })
  }
}

@Builder
export function BrewDiscoverBoardBuilder() {
  BrewDiscoverBoardView()
}
