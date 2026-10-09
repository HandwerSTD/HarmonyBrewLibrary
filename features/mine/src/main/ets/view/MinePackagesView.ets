/*
 * Copyright (c) 2025 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { ConfigurationConstant } from '@kit.AbilityKit';
import { LengthMetrics } from '@kit.ArkUI';
import { BlurStrategy, DividerMode, HdsNavDestination, HdsTabs } from '@kit.UIDesignKit';
import type { TitleBarStyleOptions } from '@kit.UIDesignKit';
import {
  BreakpointType,
  CommonConstants,
  DelayedLoadingView,
  GlobalInfoModel,
  LoadingFailedView,
  LoadingStatus,
  NoNetworkView,
  PageEnum,
  StatusBarColorType,
  StorageKey,
  WIDTH_BREAKPOINTS,
} from '@ohos/common';
import {
  BREW_ACTION_BAR_HEIGHT,
  BREW_ACTION_BUTTON_BOTTOM_EXTRA,
  BREW_ACTION_BUTTON_HEIGHT,
  BREW_ACTION_BUTTON_MAX_WIDTH,
  BREW_ACTION_BUTTON_WIDTH,
  BREW_CHIP_BAR_HEIGHT,
  BrewChip,
  BrewChipBar,
  BrewCommandRunner,
  BrewCommandStartResult,
  BrewCommandState,
  BrewCommandStatus,
  BrewLocalPackageRow,
  brewActionBarHeight,
  brewActionBarMaskHeight,
  brewChipBarHorizontalInset,
  brewLogActionBar,
  brewTitleBarStyle,
  brewTitleBarTotalHeight,
} from '@ohos/brewcommon';
import type { BrewInstalledPackage } from '@ohos/brewcommon';
import { PackageListMode } from '../model/MinePackagesModels';
import type { MinePackagesParams } from '../model/MinePackagesModels';
import { MinePackagesUtil } from '../util/MinePackagesUtil';
import { MinePackagesState } from '../viewmodel/MinePackagesState';
import { MinePackagesVM } from '../viewmodel/MinePackagesVM';

/**
 * 「我的 - 本机包」列表页。
 *
 * 三个入口共用一个页面（已安装 / 待更新 / 已更新），差别只有 `mode`：
 * 结构与交互完全相同，做成三个页面会让 chips、空态、加载态、返回处理各写三遍。
 *
 * chips 放在标题栏的 `bottomBuilder` 里（与 Casks 页一致），内容区靠
 * `brewTitleBarTotalHeight()` 手动让位 —— 标题栏是浮层，不会把内容顶下去。
 * 筛选 chips 在左段横向滚动，隐藏依赖 chip 常驻右端（页面右边缘）。
 *
 * 待更新模式下的「更新全部」是一条悬浮操作栏（与包详情页同一套取值与同一个遮罩），
 * 由单页签 `HdsTabs` 的页签栏承载。
 */
@Component
export struct MinePackagesView {
  @StorageProp(StorageKey.GLOBAL_INFO) globalInfoModel: GlobalInfoModel =
    AppStorage.get(StorageKey.GLOBAL_INFO) ?? new GlobalInfoModel();
  @StorageProp(StorageKey.COLOR_MODE) systemColorMode: ConfigurationConstant.ColorMode =
    AppStorage.get(StorageKey.COLOR_MODE) ?? ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
  // 标题栏模糊共用 brewTitleBarStyle()（本页的 chips 行挂在标题栏 bottomBuilder 上）
  @State titleBarStyle: TitleBarStyleOptions = brewTitleBarStyle('mine-packages');
  /**
   * 返回键防重入。**必须是本组件的 @State，不能放进 viewmodel 的 state** ——
   * 放共享 state 里会跨页面复用、置位后不复位，表现为「第一次能返回、之后返回键都失效」
   * （详情页就是这么踩的，见 docs §10.4.1）。
   */
  @State backPressed: boolean = false;
  viewModel: MinePackagesVM = MinePackagesVM.getInstance();
  @State packagesState: MinePackagesState = this.viewModel.getState();
  /**
   * 与 `BrewCommandRunner` 单例里**同一个**命令状态实例（`BrewCommandState` 是 `@Observed`）。
   * 按钮文案靠它的一级属性变化重渲染。
   */
  @State commandState: BrewCommandState = this.viewModel.getCommandState();
  /** 页面栈。不是 @State —— 只用于出栈，不参与渲染。来源与详情页相同。 */
  private pathStack?: NavPathStack;
  /**
   * 内容滚动容器。操作栏把内容嵌进 `HdsTabs` 的 `TabContent` 之后，标题栏模糊不再能靠
   * HDS 自动识别滚动容器，必须显式把它交给 `bindToScrollable`（与详情页同一个原因）。
   */
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    // 快照更新 -> 重取列表。命令状态与执行 Sheet 由全局宿主负责，本页只订阅快照。
    this.viewModel.subscribeSnapshot();
  }

  aboutToDisappear(): void {
    this.viewModel.unsubscribeSnapshot();
  }

  private handleOnReady(ctx: NavDestinationContext): void {
    this.pathStack = ctx?.pathStack;
    const params: MinePackagesParams = ctx?.pathInfo?.param as MinePackagesParams;
    this.viewModel.load(params?.mode ?? PackageListMode.ALL);
  }

  /**
   * 行点击 -> 详情页。本页已经在详情页同一条 `NavPathStack` 上（二级页由「我的」页 pushPath 进来），
   * 继续压入详情页，返回时回到本页。路由参数与「我的」页的预览行同一个口径。
   */
  private openDetail(pkg: BrewInstalledPackage): void {
    this.pathStack?.pushPath({
      name: PageEnum.BREW_DETAIL_VIEW,
      param: MinePackagesUtil.detailParamsOf(pkg),
    }, true);
  }

  private titleOf(mode: PackageListMode): ResourceStr {
    if (mode === PackageListMode.OUTDATED) {
      return $r('app.string.mine_outdated');
    }
    if (mode === PackageListMode.UPDATED) {
      return $r('app.string.mine_updated');
    }
    return $r('app.string.mine_installed');
  }

  /** 内容左右边距。与 MineView 同值（本页是从「我的」页压进来的子页面，两边对齐）。 */
  private contentInset(): Length {
    return new BreakpointType<Length>({
      sm: $r('sys.float.padding_level8'),
      md: $r('sys.float.padding_level12'),
      lg: $r('sys.float.padding_level16'),
    }).getValue(this.globalInfoModel.widthBreakpoint);
  }

  /**
   * 「更新全部」是否渲染。待更新页 + 当前筛选下确实有包 + 设备上 brew 可用。
   *
   * 最后的可用性与刷新按钮同源（`packagesState.brewReady`）：两条入口都只在真的能跑
   * `brew upgrade` 时出现，不存在「栏渲染了但命令发不出去」。
   */
  private showUpgradeAll(): boolean {
    return this.packagesState.mode === PackageListMode.OUTDATED &&
      this.packagesState.filteredPackages.length > 0 && this.packagesState.brewReady;
  }

  /** 操作栏总高。有底部导航条时把它算进来，按钮才不会压在导航条上 */
  private actionBarHeight(): number {
    return brewActionBarHeight(this.globalInfoModel.naviIndicatorHeight);
  }

  /** 遮罩总高 = 栏高 + 遮罩渐变长度 */
  private actionBarMaskHeight(): number {
    return brewActionBarMaskHeight(this.globalInfoModel.naviIndicatorHeight);
  }

  /**
   * 操作栏的判据行：`mask − height` 必须等于 `gradient`，`height` 必须等于 56 + `navi`，
   * 且本页与详情页的取值逐字相同。同内容只打一次（断点变化会反复触发渲染）。
   */
  private logActionBar(): void {
    brewLogActionBar('mine-packages', this.globalInfoModel.naviIndicatorHeight,
      WIDTH_BREAKPOINTS[this.globalInfoModel.widthBreakpoint]);
  }

  /**
   * 本页的「更新全部」是不是正在执行。
   *
   * 判据是 `BrewCommandRunner.isRunningArgs()`：参数相同才算本页这条命令在跑，
   * 别的命令（例如详情页的安装）在跑时按钮仍显示「更新全部」，点下去弹「已有命令在执行」。
   * 先读一次 `status` 是为了让本方法在 build 里建立对 `commandState` 的观察 ——
   * 忙闲切换时 runner 只改自己的字段，不改被观察属性，按钮不会跟着重渲染。
   */
  private upgradeAllRunning(): boolean {
    const status: BrewCommandStatus = this.commandState.status;
    if (status !== BrewCommandStatus.RUNNING) {
      return false;
    }
    return BrewCommandRunner.getInstance().isRunningArgs(this.viewModel.upgradeAllArgs());
  }

  private onUpgradeAllClick(): void {
    // 「执行中…」时点击只重新打开 Sheet：命令状态在单例里，重新打开能看到完整输出，
    // 也不能因为重复点而把同一条命令再发一次。
    if (this.upgradeAllRunning()) {
      BrewCommandRunner.getInstance().openSheet();
      return;
    }
    // 隐藏开启时列表里看不到依赖包，而 `brew upgrade` 会把设备上全部过时的包（含这些依赖包）
    // 一起升级。先在确认框里说明一次，确认过就不再出现。
    if (this.viewModel.needsDependencyUpgradeNotice()) {
      this.confirmDependencyUpgrade();
      return;
    }
    this.startUpgradeAll();
  }

  private confirmDependencyUpgrade(): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.brew_action_upgrade_all'),
      message: $r('app.string.mine_dep_upgrade_notice'),
      primaryButton: {
        value: $r('app.string.brew_source_cancel'),
        action: () => {
        }
      },
      secondaryButton: {
        value: $r('app.string.mine_dep_upgrade_notice_continue'),
        action: () => {
          this.viewModel.acknowledgeDependencyUpgradeNotice();
          this.startUpgradeAll();
        }
      }
    });
  }

  private startUpgradeAll(): void {
    if (this.viewModel.startUpgradeAll() === BrewCommandStartResult.STARTED) {
      BrewCommandRunner.getInstance().openSheet();
    }
  }

  /**
   * 隐藏 chip 与筛选 chips 的间隔。取值与 `BrewChipBar` 内部的 chip 间距一致（sm 10 / md·lg 12），
   * 叠加在 chip 栏自己的右内边距之上。
   */
  private hideChipSpace(): Length {
    return new BreakpointType<Length>({
      sm: CommonConstants.SPACE_10,
      md: CommonConstants.SPACE_12,
      lg: CommonConstants.SPACE_12,
    }).getValue(this.globalInfoModel.widthBreakpoint);
  }

  @Builder
  ChipBarBuilder() {
    Row() {
      BrewChipBar({
        chips: this.viewModel.getChips(),
        currentIndex: this.packagesState.filterIndex,
        handleChipClick: (index: number) => {
          this.viewModel.setFilter(index);
        },
      })
        .layoutWeight(1)

      // 隐藏 chip 常驻右端。外面包一层 Row 是因为胶囊底色画在 `BrewChip` 内部 Text 自己的框上，
      // 直接给 chip 加内边距会把底色一起撑大。
      //
      // 右内缩与 chip 栏自己的左右内缩同源：标题栏 `bottomBuilder` 的底区是整宽的，
      // 不补这一档，chip 会贴到窗口右边缘（与筛选 chips 左侧的留白不对称）。
      Row() {
        BrewChip({
          label: $r('app.string.mine_hide_dependency'),
          selected: this.packagesState.hideDependencies,
          handleClick: () => {
            this.viewModel.setHideDependencies(!this.packagesState.hideDependencies);
          },
        })
      }
      .alignItems(VerticalAlign.Top)
      .padding({
        left: this.hideChipSpace(),
        right: brewChipBarHorizontalInset(this.globalInfoModel),
        top: $r('sys.float.padding_level8'),
      })
    }
    .width(CommonConstants.FULL_PERCENT)
    .height(BREW_CHIP_BAR_HEIGHT)
    // 与 chip 栏内部的内容贴顶对齐：栏内 chips 的下方还有 chip 栏自己的 padding_level5，
    // 这里不补底部内边距，两边的 chip 才会落在同一条水平线上。
    .alignItems(VerticalAlign.Top)
  }

  /**
   * 列表底部的让位高度。
   *
   * 固定为 `naviIndicatorHeight + SPACE_24` —— 与「榜单查看全部」二级页、包详情页同一个口径，
   * 2in1 上导航条高度为 0，不预留就贴到窗口下沿。悬浮操作栏占的那一段由
   * `Scroll.contentEndOffset` 补（它只在内容末尾加空白，不移动滚动坐标系原点）。
   */
  private listBottomInset(): Length {
    return this.globalInfoModel.naviIndicatorHeight + CommonConstants.SPACE_24;
  }

  /**
   * 底部主操作栏：`HdsTabs` 页签栏承载的内容 —— 白色渐变遮罩 + 本页唯一的主操作按钮。
   *
   * 与包详情页同一套取值（`BrewActionBar`）、同一个遮罩颜色，两个页面的栏长得一样。
   * 遮罩的高度与颜色由 HDS 画（见 `build()` 里的 `barBackgroundStyle`），本构建器只管按钮排布。
   */
  @Builder
  ActionBarBuilder() {
    Row() {
      Button(this.upgradeAllRunning() ? $r('app.string.brew_action_running') :
        $r('app.string.brew_action_upgrade_all'))
        .width(BREW_ACTION_BUTTON_WIDTH)
        .constraintSize({ maxWidth: BREW_ACTION_BUTTON_MAX_WIDTH })
        .height(BREW_ACTION_BUTTON_HEIGHT)
        .type(ButtonType.ROUNDED_RECTANGLE)
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(FontWeight.Medium)
        .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
        .fontColor($r('sys.color.font_on_primary'))
        .onClick(() => {
          this.onUpgradeAllClick();
        })
    }
    .width(CommonConstants.FULL_PERCENT)
    .height(CommonConstants.FULL_PERCENT)
    .justifyContent(FlexAlign.Center)
    // 判据日志挂在 onAppear 上：@Builder 里不允许裸语句，而这里是「操作栏渲染了」这一刻
    // （日志本身按内容去重，反复 appear 不会刷屏）
    .onAppear(() => {
      this.logActionBar();
    })
    // 左右内缩必须与内容区（`Scroll` 内层 Column 的 padding）同源：按钮宽 60% 才有意义，
    // 而 60% 是相对**去除内缩后**的内容区宽度。
    .padding({
      left: this.contentInset(),
      right: this.contentInset(),
      bottom: this.globalInfoModel.naviIndicatorHeight + BREW_ACTION_BUTTON_BOTTOM_EXTRA,
    })
  }

  @Builder
  ContentBuilder() {
    Scroll(this.scroller) {
      // 外层这层 Column 只负责**让位与内缩**（写成内容上的 margin / padding），
      // 里面的卡片保留自己的宽度、圆角与底色。与「我的」页 MineView 完全同款。
      Column() {
        if (this.packagesState.filteredPackages.length > 0) {
          Column() {
            ForEach(this.packagesState.filteredPackages, (pkg: BrewInstalledPackage) => {
              BrewLocalPackageRow({ installedPackage: pkg })
                .onClick(() => {
                  this.openDetail(pkg);
                })
            }, (pkg: BrewInstalledPackage) => pkg.fullName)
          }
          .width(CommonConstants.FULL_PERCENT)
          .backgroundColor($r('sys.color.comp_background_primary'))
          .borderRadius($r('sys.float.corner_radius_level8'))
          .clip(true)
        } else {
          Text($r('app.string.mine_packages_empty'))
            .fontSize($r('sys.float.Body_M'))
            .fontColor($r('sys.color.font_tertiary'))
            .width(CommonConstants.FULL_PERCENT)
            .textAlign(TextAlign.Center)
            .padding({ top: $r('sys.float.padding_level16') })
        }
      }
      .width(CommonConstants.FULL_PERCENT)
      // 顶部让位：状态栏 + 标题行 + chips 行。**写成内层内容的 margin**（原因与包详情页一致）：
      //   - 容器 `padding` 会把内容**裁剪**在 padding 区域之外 —— 内容永远滚不到标题栏下面，
      //     而标题栏模糊正是靠「内容透上来」才有效果，结果就是模糊“形同虚设”（实测确认）；
      //   - `contentStartOffset` 会把滚动坐标系整体左移 C（静止时自报偏移量 −C，本页是 −112），
      //     而 HDS 的 blurEffectiveStartOffset 只接受 [0, +∞)（负数按 0 处理），永远够不到原点
      //     → 内容已在标题栏下钻了 C 还没开始模糊 = 空行程；
      //   - `margin` 写在**内层内容**上是安全的（占位跟着内容一起滚走）。
      //     （之前“margin 必然底部溢出”的结论是把它写在 Scroll **容器**上得出的，两者不同。）
      .margin({
        top: brewTitleBarTotalHeight(this.globalInfoModel.statusBarHeight),
        bottom: this.listBottomInset(),
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
    // 底部为悬浮操作栏留出滚动空间。**只加 BREW_ACTION_BAR_HEIGHT**：内层 Column 的
    // margin.bottom 里已经有 naviIndicatorHeight，操作栏自己那一段导航条高度由栏高与按钮的
    // padding.bottom 覆盖，这里再加一次会多出一段空白。没有操作栏时是 0，与改动前一致。
    .contentEndOffset(this.showUpgradeAll() ? BREW_ACTION_BAR_HEIGHT : 0)
  }

  /**
   * 成功态的内容：有悬浮操作栏时用单页签 `HdsTabs` 把它承载起来（页签栏就是那条栏，
   * 背板即白色渐变遮罩），否则直接放内容 —— 与包详情页同一个结构。
   */
  @Builder
  SuccessBuilder() {
    if (this.showUpgradeAll()) {
      HdsTabs({ barPosition: BarPosition.End, index: 0 }) {
        TabContent() {
          this.ContentBuilder()
        }
        .tabBar(this.ActionBarBuilder())      // 页签栏内容 = 唯一的主操作按钮
      }
      .width(CommonConstants.FULL_PERCENT)
      .height(CommonConstants.FULL_PERCENT)
      // 只有一个页签：不存在切换，同时挡住左右滑动手势
      .scrollable(false)
      .vertical(false)
      // 页签栏叠在内容之上 —— 内容压到它下面，遮罩才盖得住
      .barOverlap(true)
      .barHeight(this.actionBarHeight())      // 56vp + naviIndicatorHeight
      // 默认的 FOLLOW_SCROLL 会在内容滚过页签栏时画一条分割线，与遮罩冲突
      .divider({ mode: DividerMode.NONE })
      // 关掉页签栏自带的 COMPONENT_THICK 模糊：只要那层白色渐变遮罩，不要模糊
      .barBackgroundBlurStyle(BlurStyle.NONE)
      .blurStrategy(BlurStrategy.DISABLE)
      // 遮罩：白色渐变，高度 = 栏高 + 渐变长度（HDS 画的那层，不吃触摸）
      .barBackgroundStyle({
        maskColor: $r('app.color.brew_action_bar_mask'),
        maskHeight: this.actionBarMaskHeight(),
      })
      // 页签栏上的点击会走一次 Tabs 的切换逻辑；单页签下这次切换没有任何可见效果
      .animationDuration(0)
    } else {
      this.ContentBuilder()
    }
  }

  build() {
    HdsNavDestination() {
      if (this.packagesState.loadingModel.loadingStatus === LoadingStatus.SUCCESS) {
        this.SuccessBuilder()
      } else if (this.packagesState.loadingModel.loadingStatus === LoadingStatus.LOADING) {
        // 读取本机包要拉起 brew（首次约 2–3 秒）。延迟出现：缓存命中时不会闪一下
        DelayedLoadingView({ breakpoint: this.globalInfoModel.widthBreakpoint })
      } else if (this.packagesState.loadingModel.loadingStatus === LoadingStatus.FAILED) {
        LoadingFailedView(this.globalInfoModel.widthBreakpoint, () => {
          this.viewModel.load(this.packagesState.mode);
        })
      } else if (this.packagesState.loadingModel.loadingStatus === LoadingStatus.NO_NETWORK) {
        NoNetworkView(this.globalInfoModel.widthBreakpoint, () => {
          this.viewModel.load(this.packagesState.mode);
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
        title: { mainTitle: this.titleOf(this.packagesState.mode) },
        // 刷新按钮与 brew 可用性同源：能力关闭或设备上找不到 brew 时不渲染那一步
        // （pc_normal 与「去安装 Harmonybrew」两种情形），刷新期间置灰。
        menu: this.packagesState.brewReady ? {
          value: [{
            content: {
              icon: $r('sys.symbol.arrow_clockwise'),
              label: $r('app.string.mine_refresh'),
              isEnabled: !this.packagesState.refreshing,
              action: () => {
                this.viewModel.refresh();
              },
            }
          }]
        } : undefined,
        bottomBuilder: {
          builder: () => {
            this.ChipBarBuilder();
          },
          height: BREW_CHIP_BAR_HEIGHT,
        },
      },
    })
    // 显式绑定滚动容器：内容嵌进单页签 `HdsTabs` 的 `TabContent` 之后，HDS 不再自动识别它，
    // 不写这一行标题栏的动态模糊会直接丢失（FAQ faqs-arkui-1095 场景二）。
    .bindToScrollable([this.scroller])
    .systemBarStyle({
      statusBarContentColor: this.systemColorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK ?
        StatusBarColorType.WHITE : StatusBarColorType.BLACK
    }, {
      statusBarContentColor: this.systemColorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK ?
        StatusBarColorType.WHITE : StatusBarColorType.BLACK
    })
    .onReady((ctx: NavDestinationContext) => this.handleOnReady(ctx))
    .onBackPressed(() => {
      // 已在处理中就吞掉重复按下，否则连点会把上一页（「我的」页）也一起弹掉。
      if (this.backPressed) {
        return true;
      }
      this.backPressed = true;
      if (this.pathStack) {
        this.pathStack.pop();
        return true;
      }
      // 拿不到页面栈时不吞事件，交给系统默认出栈，而不是让返回键彻底失效。
      return false;
    })
  }
}

@Builder
export function MinePackagesViewBuilder() {
  MinePackagesView()
}
