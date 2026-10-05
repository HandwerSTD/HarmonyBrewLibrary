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
import { HdsNavDestination } from '@kit.UIDesignKit';
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
} from '@ohos/common';
import {
  BREW_CHIP_BAR_HEIGHT,
  BrewChip,
  BrewChipBar,
  BrewCli,
  BrewCommandRunner,
  BrewCommandStartResult,
  BrewCommandState,
  BrewCommandStatus,
  BrewLocalPackageRow,
  brewChipBarHorizontalInset,
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
 * 「更新全部」按钮高度。与「我的」页及其它二级页的操作按钮同高
 * （与 `BrewSourceSettingView.CapsuleButton` 取同一值）。
 */
const ACTION_BUTTON_HEIGHT: number = 32;

/**
 * 「我的 - 本机包」列表页。
 *
 * 三个入口共用一个页面（已安装 / 待更新 / 已更新），差别只有 `mode`：
 * 结构与交互完全相同，做成三个页面会让 chips、空态、加载态、返回处理各写三遍。
 *
 * chips 放在标题栏的 `bottomBuilder` 里（与 Casks 页一致），内容区靠
 * `brewTitleBarTotalHeight()` 手动让位 —— 标题栏是浮层，不会把内容顶下去。
 * 筛选 chips 在左段横向滚动，隐藏依赖 chip 常驻右端（页面右边缘）。
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

  /** 胶囊圆角：侧边栏（2in1）用固定圆角，其余用胶囊 —— 与数据源设置页的胶囊按钮同一规则 */
  private capsuleRadius(): Length {
    return AppStorage.get<boolean>(StorageKey.IS_SIDEBAR_LAYOUT) ?
      $r('sys.float.corner_radius_level4') : '50%';
  }

  /** 「更新全部」是否渲染。待更新页 + 当前筛选下确实有包 + 设备上 brew 可用 */
  private showUpgradeAll(): boolean {
    return this.packagesState.mode === PackageListMode.OUTDATED &&
      this.packagesState.filteredPackages.length > 0 && BrewCli.isEnabled();
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
   * 有底部操作行时由操作行承担底部内边距（导航条 + SPACE_12），列表只留一段呼吸；
   * 没有操作行（已安装 / 已更新两个模式）时保持现状的 `naviIndicatorHeight + SPACE_24`
   * —— 与「榜单查看全部」二级页、包详情页同一个口径，2in1 上导航条高度为 0，不预留就贴到窗口下沿。
   */
  private listBottomInset(): Length {
    if (this.showUpgradeAll()) {
      return CommonConstants.SPACE_16;
    }
    return this.globalInfoModel.naviIndicatorHeight + CommonConstants.SPACE_24;
  }

  @Builder
  ContentBuilder() {
    Column() {
      Scroll() {
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
      .layoutWeight(1)
      .width(CommonConstants.FULL_PERCENT)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })

      // 底部操作行。固定在页面底部而不是放在内容顶部：它的操作对象是整张列表，
      // 列表可能很长，放在顶部会随列表滚走。
      if (this.showUpgradeAll()) {
        Row() {
          Blank()
          Button(this.upgradeAllRunning() ? $r('app.string.brew_action_running') :
            $r('app.string.brew_action_upgrade_all'))
            .height(ACTION_BUTTON_HEIGHT)
            .fontSize($r('sys.float.Body_M'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .backgroundColor($r('sys.color.comp_background_tertiary'))
            .borderRadius(this.capsuleRadius())
            .padding({ left: $r('sys.float.padding_level6'), right: $r('sys.float.padding_level6') })
            .onClick(() => {
              this.onUpgradeAllClick();
            })
        }
        .width(CommonConstants.FULL_PERCENT)
        .alignItems(VerticalAlign.Center)
        .padding({
          left: this.contentInset(),
          right: this.contentInset(),
          bottom: this.globalInfoModel.naviIndicatorHeight + CommonConstants.SPACE_12,
        })
      }
    }
    .width(CommonConstants.FULL_PERCENT)
    .height(CommonConstants.FULL_PERCENT)
  }

  build() {
    HdsNavDestination() {
      if (this.packagesState.loadingModel.loadingStatus === LoadingStatus.SUCCESS) {
        this.ContentBuilder()
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
        bottomBuilder: {
          builder: () => {
            this.ChipBarBuilder();
          },
          height: BREW_CHIP_BAR_HEIGHT,
        },
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
