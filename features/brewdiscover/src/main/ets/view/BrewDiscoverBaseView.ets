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
import { BrewDiscoverBoard as BrewDiscoverBoardClass, BrewDiscoverFeatured, BrewKind } from '@ohos/brewcommon';
import type {
  BrewDetailParams,
  BrewDiscoverBoard,
  BrewDiscoverBoardParams,
  BrewDiscoverEntry,
} from '@ohos/brewcommon';
import { BrewDiscoverBoardCard } from '../component/BrewDiscoverBoardCard';
import { BrewDiscoverFeaturedCard } from '../component/BrewDiscoverFeaturedCard';
import { BrewDiscoverFeedItem, BrewDiscoverFeedType } from '../model/BrewDiscoverFeedItem';
import type { BrewDiscoverState } from '../viewmodel/BrewDiscoverState';
import { BrewDiscoverEventType, BrewDiscoverHomeViewModel } from '../viewmodel/BrewDiscoverVM';

/**
 * Discover 首页内容区。
 *
 * 结构与 Formulae / Casks 首页**同构**（这正是需求：前三个页签复用组件页首页的 UX）：
 *   BaseHomeView(加载/失败/无网) + WaterFlow(单 section) + LazyForEach(榜单大卡)
 * 同样没有 banner FlowItem —— Homebrew 无横幅素材，对应 ViewModel 里 banner 高度固定为 0。
 *
 * 差别只在卡的内容：这里一张卡 = 一张榜（趋势/历史/新星 × Formulae/Casks，共 6 张）。
 */
@Component({ freezeWhenInactive: true })
export struct BrewDiscoverBaseView {
  @StorageProp(StorageKey.GLOBAL_INFO) @Watch('handleBreakPointChange') globalInfoModel: GlobalInfoModel =
    AppStorage.get(StorageKey.GLOBAL_INFO) ?? new GlobalInfoModel();
  @StorageProp(StorageKey.COLOR_MODE) @Watch('handleColorModeChange') systemColorMode: ConfigurationConstant.ColorMode =
    AppStorage.get(StorageKey.COLOR_MODE) ?? ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
  viewModel: BrewDiscoverHomeViewModel = BrewDiscoverHomeViewModel.getInstance();
  @State discoverState: BrewDiscoverState = this.viewModel.getState();

  aboutToAppear(): void {
    this.viewModel.sendEvent({ type: BrewDiscoverEventType.LOAD_DISCOVER, param: null });
    this.viewModel.sendEvent<OffsetParam>({
      type: BaseHomeEventType.HANDLE_BREAKPOINT_CHANGE,
      param: { yOffset: 0, tabIndex: TabBarType.DISCOVER },
    });
  }

  handleBreakPointChange(): void {
    this.viewModel.sendEvent({ type: BrewDiscoverEventType.UPDATE_FLOW_SECTION, param: null });
    this.viewModel.sendEvent<OffsetParam>({
      type: BaseHomeEventType.HANDLE_BREAKPOINT_CHANGE,
      param: {
        yOffset: (this.discoverState.scroller?.currentOffset()?.yOffset || 0),
        tabIndex: TabBarType.DISCOVER,
      },
    });
  }

  handleColorModeChange(): void {
    this.viewModel.sendEvent<OffsetParam>({
      type: BaseHomeEventType.HANDLE_COLOR_CHANGE,
      param: {
        yOffset: (this.discoverState.scroller?.currentOffset()?.yOffset || 0),
        tabIndex: TabBarType.DISCOVER,
      },
    });
  }

  /**
   * 点榜内的包 -> 详情页。
   *
   * `categoryKey` 取自榜单条目自身（生成器写入），详情页据此查「同分类其他包」；
   * 不要留空，否则从 Discover 点进去的详情页会缺这一段推荐。
   */
  jumpDetail(entry: BrewDiscoverEntry, board: BrewDiscoverBoard): void {
    if (!entry.id) {
      return;
    }
    const param: BrewDetailParams = {
      kind: BrewKind.FORMULA,
      title: entry.token,
      id: entry.id,
      token: entry.token,
      categoryKey: entry.categoryKey,
    };
    param.kind = board.kind === 'cask' ? BrewKind.CASK : BrewKind.FORMULA;
    this.viewModel.sendEvent<BrewDetailParams>({
      type: BrewDiscoverEventType.JUMP_DETAIL,
      param: param,
    });
  }

  /** 单 App 大图卡 -> 详情页。`kind` 与 `categoryKey` 都由生成器写进条目里 */
  jumpFeatured(item: BrewDiscoverFeatured): void {
    if (!item.id) {
      return;
    }
    const param: BrewDetailParams = {
      kind: BrewKind.FORMULA,
      title: item.token,
      id: item.id,
      token: item.token,
      categoryKey: item.categoryKey,
    };
    param.kind = item.kind === 'cask' ? BrewKind.CASK : BrewKind.FORMULA;
    this.viewModel.sendEvent<BrewDetailParams>({
      type: BrewDiscoverEventType.JUMP_DETAIL,
      param: param,
    });
  }

  jumpBoard(board: BrewDiscoverBoard): void {
    const param: BrewDiscoverBoardParams = { boardId: board.id };
    this.viewModel.sendEvent<BrewDiscoverBoardParams>({
      type: BrewDiscoverEventType.JUMP_BOARD,
      param: param,
    });
  }

  @Builder
  ContentViewBuilder() {
    WaterFlow({ scroller: this.discoverState.scroller, sections: this.discoverState.sections }) {
      // 顶部让位：内容里的**空白 FlowItem 占位块**（高度 = 状态栏 + 标题行），与组件页把 banner
      // 当作第一个 FlowItem 撑出顶部空间是同一个做法。
      //
      // 为什么不能用容器 padding / contentStartOffset（两者都会让模糊失效，实测）：
      //   - 容器 padding 会把内容**裁剪**在 padding 区域之外 —— 内容永远滚不到标题栏下面，
      //     标题栏模糊就“形同虚设”；
      //   - contentStartOffset 会把**滚动坐标系整体左移 C**（静止时 scroller 自报偏移量变成 −C，
      //     本机实测 −56），而 HDS 的 blurEffectiveStartOffset 只接受 [0, +∞)（负数按 0 处理），
      //     永远够不到那个原点 → 内容已在标题栏下钻了 C 还没开始模糊 = 空行程。
      // 占位块属于内容：既不被裁剪，也不移动坐标系原点。详见 BrewTitleBar.ets。
      FlowItem() {
        Column()
          .width('100%')
          .height(this.globalInfoModel.statusBarHeight + CommonConstants.NAVIGATION_HEIGHT)
      }
      .width('100%')

      LazyForEach(this.discoverState.cardSource, (feed: BrewDiscoverFeedItem) => {
        FlowItem() {
          if (feed.feedType === BrewDiscoverFeedType.FEATURED) {
            // 单 App 大图卡：一张卡 = 一个包
            BrewDiscoverFeaturedCard({
              item: feed.featured ?? new BrewDiscoverFeatured(),
              handleItemClick: (clicked: BrewDiscoverFeatured) => {
                this.jumpFeatured(clicked);
              },
            })
          } else {
            BrewDiscoverBoardCard({
              board: feed.board ?? new BrewDiscoverBoardClass(),
              handleEntryClick: (entry: BrewDiscoverEntry) => {
                this.jumpDetail(entry, feed.board ?? new BrewDiscoverBoardClass());
              },
              handleViewAll: (board: BrewDiscoverBoard) => {
                this.jumpBoard(board);
              },
            })
          }
        }
        .width(CommonConstants.FULL_PERCENT)
      }, (feed: BrewDiscoverFeedItem) => feed.key())

      // 底部让位：同样是内容里的空白块
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
    // 固定 Spring：基线里那个 `hasEdgeEffect` 是给手机 banner 回弹算的，本页没有 banner，
    // 它恒为 false。与 Formulae / 我的 页保持一致，直接常开。
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    // 顶部/底部让位都写成内容里的空白 FlowItem（见上面），容器上不写任何 padding ——
    // 容器 padding 会裁剪内容；左右内缩由 section 的 margin 提供（与组件页一致）。
    //
    // **左右内缩不在这里**：它由 section 的 margin 提供（见 ViewModel.updateFlowSection），
    // 与组件页的做法一致（ComponentBaseView 的 WaterFlow 上一个 .padding() 都没有）。
    // 两边各写一份必然变成双份内缩，§9.9/§9.10 已经因此吃过两次亏。
    .width(CommonConstants.FULL_PERCENT)
    .height(CommonConstants.FULL_PERCENT)
    .cachedCount(4)
    .onDidScroll(() => {
      this.viewModel.sendEvent<OffsetParam>({
        type: BaseHomeEventType.HANDLE_SCROLL_OFFSET,
        param: {
          yOffset: this.discoverState.scroller?.currentOffset()?.yOffset ?? 0,
          tabIndex: TabBarType.DISCOVER,
        },
      });
    })
  }

  build() {
    BaseHomeView({
      loadingModel: this.discoverState.loadingModel,
      contentView: () => {
        this.ContentViewBuilder();
      },
      reloadData: () => {
        this.viewModel.sendEvent({ type: BrewDiscoverEventType.LOAD_DISCOVER, param: null });
      },
    })
  }
}
