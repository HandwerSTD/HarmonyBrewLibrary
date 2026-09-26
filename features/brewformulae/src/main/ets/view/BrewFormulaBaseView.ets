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
import { BrewKind, brewPageContentLeft, brewPageContentRight } from '@ohos/brewcommon';
import type { BrewCategoryCard, BrewCategoryParams, BrewDetailParams, BrewPackageItem } from '@ohos/brewcommon';
import { BrewCategoryCardView } from '../component/BrewCategoryCardView';
import type { BrewFormulaState } from '../viewmodel/BrewFormulaState';
import { BrewFormulaEventType, BrewFormulaHomeViewModel } from '../viewmodel/BrewFormulaHomeViewModel';

/**
 * Formulae 首页内容区。
 *
 * 结构与组件页 ComponentBaseView 一一对应，只是把卡片换成了分类大卡：
 *   BaseHomeView(加载/失败/无网) + WaterFlow(单 section) + LazyForEach(分类卡)
 * 没有 banner FlowItem —— Homebrew 无横幅素材，对应 ViewModel 里 banner 高度固定为 0。
 */
@Component({ freezeWhenInactive: true })
export struct BrewFormulaBaseView {
  @StorageProp(StorageKey.GLOBAL_INFO) @Watch('handleBreakPointChange') globalInfoModel: GlobalInfoModel =
    AppStorage.get(StorageKey.GLOBAL_INFO) ?? new GlobalInfoModel();
  @StorageProp(StorageKey.COLOR_MODE) @Watch('handleColorModeChange') systemColorMode: ConfigurationConstant.ColorMode =
    AppStorage.get(StorageKey.COLOR_MODE) ?? ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
  viewModel: BrewFormulaHomeViewModel = BrewFormulaHomeViewModel.getInstance();
  @State formulaState: BrewFormulaState = this.viewModel.getState();

  aboutToAppear(): void {
    this.viewModel.sendEvent({ type: BrewFormulaEventType.LOAD_FORMULA_PAGE, param: null });
    this.viewModel.sendEvent<OffsetParam>({
      type: BaseHomeEventType.HANDLE_BREAKPOINT_CHANGE,
      param: { yOffset: 0, tabIndex: TabBarType.FORMULAE },
    });
  }

  handleBreakPointChange(): void {
    this.viewModel.sendEvent({ type: BrewFormulaEventType.UPDATE_FLOW_SECTION, param: null });
    this.viewModel.sendEvent<OffsetParam>({
      type: BaseHomeEventType.HANDLE_BREAKPOINT_CHANGE,
      param: {
        yOffset: (this.formulaState.scroller?.currentOffset()?.yOffset || 0),
        tabIndex: TabBarType.FORMULAE,
      },
    });
  }

  handleColorModeChange(): void {
    this.viewModel.sendEvent<OffsetParam>({
      type: BaseHomeEventType.HANDLE_COLOR_CHANGE,
      param: {
        yOffset: (this.formulaState.scroller?.currentOffset()?.yOffset || 0),
        tabIndex: TabBarType.FORMULAE,
      },
    });
  }

  jumpDetail(item: BrewPackageItem): void {
    const param: BrewDetailParams = {
      kind: BrewKind.FORMULA,
      title: item.subTitle,
      id: item.id,
      token: item.token,
      categoryKey: item.categoryKey,
    };
    this.viewModel.sendEvent<BrewDetailParams>({
      type: BrewFormulaEventType.JUMP_DETAIL,
      param: param,
    });
  }

  /** 分类卡「查看全部」：进该分类的完整列表（只传 categoryKey，成员由二级页自己取） */
  jumpCategory(card: BrewCategoryCard): void {
    const param: BrewCategoryParams = { categoryKey: card.categoryKey };
    this.viewModel.sendEvent<BrewCategoryParams>({
      type: BrewFormulaEventType.JUMP_CATEGORY,
      param: param,
    });
  }

  @Builder
  ContentViewBuilder() {
    WaterFlow({ scroller: this.formulaState.scroller, sections: this.formulaState.sections }) {
      // 顶部让位：一个**空白的 FlowItem 占位块**（高度 = 状态栏 + 标题行），与组件页把 banner
      // 当成第一个 FlowItem 撑出顶部空间是同一个做法（本页没有 banner 素材，所以用空白块）。
      //
      // 为什么必须是「内容里的占位块」，而不是滚动容器上的 padding / contentStartOffset：
      //   - **容器 padding 会把内容裁剪在 padding 区域之外** —— 内容永远滚不到标题栏下面，
      //     而标题栏模糊正是靠「内容透上来」才看得出效果，结果就是模糊“形同虚设”（实测确认）；
      //   - **contentStartOffset 会把滚动坐标系整体左移 C**（静止时 scroller 自报的偏移量变成 −C，
      //     本机实测 −56），而 HDS 的 blurEffectiveStartOffset 只接受 [0, +∞)（负数按 0 处理），
      //     它永远够不到那个原点 → 内容已经在标题栏下钻了 C 还没开始模糊 = 用户看到的「空行程」；
      //   - **占位块属于内容**：不裁剪，也不移动滚动坐标系原点，静止时自报偏移量是 0，
      //     HDS 的区间 [0, ramp] 才真正从「内容贴在标题栏下沿」那一刻开始渐变。
      // 详见 brewcommon 的 BrewTitleBar.ets 顶部注释。
      FlowItem() {
        Column()
          .width('100%')
          .height(this.globalInfoModel.statusBarHeight + CommonConstants.NAVIGATION_HEIGHT)
      }
      .width('100%')

      LazyForEach(this.formulaState.cardSource, (item: BrewCategoryCard) => {
        FlowItem() {
          BrewCategoryCardView({
            cardData: item,
            handlePackageClick: (clicked: BrewPackageItem) => {
              this.jumpDetail(clicked);
            },
            handleViewAll: (card: BrewCategoryCard) => {
              this.jumpCategory(card);
            },
          })
        }
        .width('100%')
      }, (item: BrewCategoryCard) => item.id.toString())

      // 底部让位：同样是内容里的空白块（详情/二级页用内层 margin，这里没有「内层容器」可加）
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
    // 固定 Spring：基线里那个 `hasEdgeEffect` 是给手机 banner 回弹算的 ——
    // 它只在 calculateBannerHeight() 被调用时更新，而那个方法在侧边栏布局下直接 return，
    // 加上我也没有接 ON_SCROLL_FRAME_BEGIN 这个事件，所以它恒为 false。
    // 本页没有 banner 需要回弹，直接常开，与「我的」页 MineView 一致。
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    // 底部让位同样写成内容里的空白块（见本页 VM 的 footerSection）——
    // 容器上的 padding 会裁剪内容，而 contentEndOffset 又会把内容区原点整体前移。
    // 左右内缩仍由 section 的 margin 提供（与组件页一致，容器上一个 padding 都不写）。
    .width('100%')
    .height('100%')
    .cachedCount(4)
    .onDidScroll(() => {
      this.viewModel.sendEvent<OffsetParam>({
        type: BaseHomeEventType.HANDLE_SCROLL_OFFSET,
        param: {
          yOffset: this.formulaState.scroller?.currentOffset()?.yOffset ?? 0,
          tabIndex: TabBarType.FORMULAE,
        },
      });
    })
  }

  build() {
    BaseHomeView({
      loadingModel: this.formulaState.loadingModel,
      contentView: () => {
        this.ContentViewBuilder();
      },
      reloadData: () => {
        this.viewModel.sendEvent({ type: BrewFormulaEventType.LOAD_FORMULA_PAGE, param: null });
      },
    })
  }
}
