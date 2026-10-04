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
  CustomImmersiveStyle,
  GlobalInfoModel,
  LoadingFailedView,
  LoadingStatus,
  MaterialUtil,
  NoNetworkView,
  PageEnum,
  StatePlaceholderKind,
  StatePlaceholderView,
  StatusBarColorType,
  StorageKey,
  Toast,
} from '@ohos/common';
import {
  BrewCommandRunner,
  BrewCommandSheet,
  BrewCommandStartResult,
  BrewCommandState,
  BrewCommandStatus,
  BrewInstalledLoader,
  BrewKind,
  BrewPackageRow,
  brewCommandStatusText,
  brewContentTopInset,
  brewTitleBarStyle,
} from '@ohos/brewcommon';
import type { BrewDetailParams, BrewInfoRow, BrewInfoSection, BrewPackageItem } from '@ohos/brewcommon';
import { BrewDetailHero } from '../component/BrewDetailHero';
import { BrewDetailMetaBar, BrewInfoSectionView, BrewInstallCommandCard } from '../component/BrewInfoSectionView';
import { BrewLifecycleBanner } from '../component/BrewLifecycleBanner';
import { BrewDetailState, BrewInstallState } from '../viewmodel/BrewDetailState';
import { BrewDetailViewModel } from '../viewmodel/BrewDetailViewModel';

/**
 * 包详情页（formula 与 cask 共用，靠路由参数里的 `kind` 分流）。
 *
 * 分区顺序与实现清单见 docs/brew-api-design.md §5.3。
 * 两种包的字段差异全部在 `BrewDetailNormalizer` 里摊平成 `BrewInfoSection[]`，
 * 因此这里只有一处 `kind` 分支（决定点击同类包时回传的 kind），渲染代码是同一份。
 */
@Component({ freezeWhenInactive: true })
export struct BrewDetailView {
  @StorageProp(StorageKey.GLOBAL_INFO) globalInfoModel: GlobalInfoModel =
    AppStorage.get(StorageKey.GLOBAL_INFO) ?? new GlobalInfoModel();
  @StorageProp(StorageKey.COLOR_MODE) systemColorMode: ConfigurationConstant.ColorMode =
    AppStorage.get(StorageKey.COLOR_MODE) ?? ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
  /**
   * 本页实例自己的展示状态。**不能从单例 VM 取** —— 详情页可以叠在详情页上
   * （点「同分类其他包」会 push 一个新详情页），共享一份 state 会让新页面的数据
   * 覆盖栈中旧页面，从新页面返回时旧页面渲染的是同一份数据、看起来像「返回没反应」。
   *
   * 直接在字段初始化里 new，不引用 this 的其他成员，避免依赖 ArkUI 的成员初始化顺序。
   */
  @State detailState: BrewDetailState = new BrewDetailState();
  @State title: ResourceStr = '';
  @State kind: BrewKind = BrewKind.FORMULA;
  // 标题栏模糊共用 brewTitleBarStyle()（详情页没有 chips 行）
  @State titleBarStyle: TitleBarStyleOptions = brewTitleBarStyle('detail');
  /**
   * 返回键防重入。**必须是组件自己的 @State，不能放进 BrewDetailState** ——
   * 后者挂在单例 viewmodel 上，会跨页面复用：一旦置位就再不复位，
   * 表现为「第一次能返回，之后每次进详情页返回键都失效」。
   * 每个 pushPath 都会新建一个 NavDestination（即一个新的本结构体实例），
   * 所以放在这里天然是每页独立的。
   */
  @State backPressed: boolean = false;

  private viewModel: BrewDetailViewModel = BrewDetailViewModel.getInstance();
  /** 执行 Sheet 是否展示。命令状态在 `BrewCommandRunner` 单例里，关掉 Sheet 不影响命令执行 */
  @State commandSheetShown: boolean = false;
  /**
   * 与 `BrewCommandRunner` 单例里**同一个**命令状态实例（`BrewCommandState` 是 `@Observed`）。
   * 按钮文案靠它的一级属性变化重渲染；Sheet 用 `@ObjectLink` 接它，输出逐行追加时只更新受影响的行。
   */
  @State commandState: BrewCommandState = this.viewModel.getCommandState();
  /** 命令状态回调。存成字段，保证 `subscribe` / `unsubscribe` 拿到的是同一个函数对象 */
  private commandListener: () => void = () => {
    this.onCommandStateChanged();
  };
  /** 快照更新回调。详情页的 state 是页面实例自己的，所以回调也存在这里而不是 VM 里 */
  private snapshotListener: () => void = () => {
    this.viewModel.refreshInstallState(this.detailState);
  };
  /**
   * 上一次看到的命令状态。用来分辨「刚刚结束」与「进页面时看到的是上次那条命令的结局」，
   * 后者不该再弹一次结束提示。
   */
  private lastCommandStatus: BrewCommandStatus = BrewCommandStatus.IDLE;

  /**
   * 快照订阅放在页面里而不是 VM 里：`BrewDetailState` 是每个页面实例自己的
   * （详情页可以叠在详情页上），VM 是单例，订阅回调必须知道是哪一页的 state。
   */
  aboutToAppear(): void {
    BrewInstalledLoader.subscribe(this.snapshotListener);
    BrewCommandRunner.getInstance().subscribe(this.commandListener);
  }

  aboutToDisappear(): void {
    BrewInstalledLoader.unsubscribe(this.snapshotListener);
    BrewCommandRunner.getInstance().unsubscribe(this.commandListener);
  }

  handleOnReady(ctx: NavDestinationContext): void {
    const params: BrewDetailParams = ctx?.pathInfo?.param as BrewDetailParams;
    if (!params) {
      return;
    }
    this.kind = params.kind;
    this.detailState.params = params;
    this.detailState.pathStack = ctx?.pathStack;
    // 先用列表页已知的信息填标题，避免详情返回前标题栏是空的
    this.title = params.title || params.token;
    this.viewModel.load(params, this.detailState);
  }

  /** 点击同类包：以当前页的 kind 为准，不依赖同类包自身的字段 */
  openSibling(item: BrewPackageItem): void {
    const params: BrewDetailParams = {
      kind: this.kind,
      title: item.subTitle,
      id: item.id,
      token: item.token,
      categoryKey: item.categoryKey,
    };
    this.detailState.pathStack?.pushPath({ name: PageEnum.BREW_DETAIL_VIEW, param: params }, true);
  }

  /** 失败/无网/未找到时的重试。必须重新发请求 —— 只重置标志位的话按钮点了没反应。
   * 条件是「有 token 或有 id」：本机包入口的 id 是 0，只判 id 会让重试按钮失效。 */
  private retry(): void {
    const params: BrewDetailParams = this.detailState.params;
    if (params.id > 0 || params.token.length > 0) {
      this.viewModel.load(params, this.detailState);
    }
  }

  private contentLeft(): Length {
    return new BreakpointType<Length>({
      sm: $r('sys.float.padding_level8'),
      md: $r('sys.float.padding_level12'),
      lg: $r('sys.float.padding_level16'),
    }).getValue(this.globalInfoModel.widthBreakpoint);
  }

  /**
   * 本包的安装 / 升级命令是不是正在执行。
   *
   * 判据是 `BrewCommandRunner.isRunningArgs()`：参数相同才算本页这条命令在跑，
   * 别的命令（例如「更新全部」）在跑时按钮仍显示「安装」/「升级」，点下去弹「已有命令在执行」。
   * 先读一次 `status` 是为了让本方法在 build 里建立对 `commandState` 的观察 ——
   * 忙闲切换时 runner 只改自己的字段，不改被观察属性，按钮不会跟着重渲染。
   */
  private installRunning(): boolean {
    const status: BrewCommandStatus = this.commandState.status;
    if (status !== BrewCommandStatus.RUNNING) {
      return false;
    }
    return BrewCommandRunner.getInstance().isRunningArgs(this.viewModel.actionArgs(this.detailState));
  }

  /**
   * 按钮文案（spec §3.2）：未安装或快照未知 -> 安装；已安装且有新版本 -> 升级；
   * 已安装且最新 -> 已安装（不可点）。本命令在跑时统一显示「执行中…」。
   */
  private installActionLabel(): ResourceStr {
    if (this.installRunning()) {
      return $r('app.string.brew_action_running');
    }
    if (this.detailState.installState === BrewInstallState.OUTDATED) {
      return $r('app.string.brew_action_upgrade');
    }
    if (this.detailState.installState === BrewInstallState.INSTALLED) {
      return $r('app.string.brew_state_installed');
    }
    return $r('app.string.brew_action_install');
  }

  /** 「已安装且版本已是最新」时按钮不可点 */
  private installActionEnabled(): boolean {
    return this.detailState.installState !== BrewInstallState.INSTALLED;
  }

  private onInstallActionClick(): void {
    // 「执行中…」时点击只重新打开 Sheet：命令状态在单例里，重新打开能看到完整输出，
    // 也不能因为重复点而把同一条命令再发一次。
    if (this.installRunning()) {
      this.commandSheetShown = true;
      return;
    }
    if (this.viewModel.startInstallOrUpgrade(this.detailState) === BrewCommandStartResult.STARTED) {
      this.commandSheetShown = true;
    }
  }

  /** 命令结束时补一条提示。Sheet 关着才弹 —— Sheet 里已经有状态行了 */
  private onCommandStateChanged(): void {
    const status: BrewCommandStatus = this.commandState.status;
    if (status === this.lastCommandStatus) {
      return;
    }
    this.lastCommandStatus = status;
    if (status !== BrewCommandStatus.DONE && status !== BrewCommandStatus.INTERRUPTED &&
      status !== BrewCommandStatus.TIMEOUT && status !== BrewCommandStatus.FAILED) {
      return;
    }
    if (this.commandSheetShown) {
      return;
    }
    // 本页压在「我的」页上时两页同时存活，结束提示只让先调用的那一页弹（避免弹两次）
    if (!BrewCommandRunner.getInstance().claimEndNotice()) {
      return;
    }
    Toast.showToast(brewCommandStatusText(this.commandState));
  }

  @Builder
  CommandSheetBuilder() {
    BrewCommandSheet({
      state: this.commandState,
      onInterrupt: () => {
        this.viewModel.interruptCommand();
      },
      onForceKill: () => {
        this.viewModel.forceKillCommand();
      },
      onClose: () => {
        this.commandSheetShown = false;
      },
    })
  }

  @Builder
  ContentBuilder() {
    Scroll() {
      Column({ space: $r('sys.float.padding_level8') }) {
        // 1 Hero
        BrewDetailHero({ data: this.detailState.data, kind: this.kind })

        // 9 生命周期警示（deprecated / disabled）—— 位置靠前，因为它影响"要不要装"
        if (this.detailState.data.hasLifecycle) {
          BrewLifecycleBanner({ notice: this.detailState.data.lifecycle })
        }

        // 2 安装命令 + 执行按钮 + 复制
        BrewInstallCommandCard({
          command: this.detailState.data.installCommand,
          showAction: this.detailState.commandReady,
          actionLabel: this.installActionLabel(),
          actionEnabled: this.installActionEnabled(),
          onAction: () => {
            this.onInstallActionClick();
          },
        })

        // 3 元信息
        BrewDetailMetaBar({ rows: this.detailState.data.meta })

        // 4/5/6/7/11 各分区（数据驱动；空分区不会出现在数组里）
        ForEach(this.detailState.data.sections, (section: BrewInfoSection) => {
          BrewInfoSectionView({ section: section })
        }, (section: BrewInfoSection, index: number) => `section_${index}`)

        // 8 安装提示（caveats）
        if (this.detailState.data.caveats) {
          Text(this.detailState.data.caveats)
            .fontSize($r('sys.float.Body_M'))
            .fontColor($r('sys.color.font_secondary'))
            .width('100%')
            .padding($r('sys.float.padding_level6'))
            .backgroundColor($r('sys.color.comp_background_list_card'))
            .borderRadius($r('sys.float.corner_radius_level8'))
        }

        // 10 同分类其他包
        if (this.detailState.siblings.length > 0) {
          Column() {
            Text($r('app.string.brew_section_same_category'))
              .fontSize($r('sys.float.Title_S'))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_primary'))
              .width('100%')
              .padding({
                left: $r('sys.float.padding_level6'),
                top: $r('sys.float.padding_level6'),
                bottom: $r('sys.float.padding_level2'),
              })
            ForEach(this.detailState.siblings, (item: BrewPackageItem) => {
              BrewPackageRow({ packageItem: item, kind: this.kind })
                .onClick(() => {
                  this.openSibling(item);
                })
            }, (item: BrewPackageItem) => item.id.toString())
          }
          .width('100%')
          .backgroundColor($r('sys.color.comp_background_list_card'))
          .borderRadius($r('sys.float.corner_radius_level8'))
          .clip(true)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      // 顶部/底部让位写成**内层内容的 margin**（与「我的」页 MineView 完全同款）：
      // margin 属于内容，会随内容一起滚走，**既不裁剪内容也不移动滚动坐标系原点** ——
      // 静止时 scroller 自报的偏移量是 0，HDS 的模糊区间 [0, ramp] 才能真正从
      // 「内容贴在标题栏下沿」那一刻开始渐变。
      //
      // 两种都不行（均实测）：
      //   - 容器 `padding`：把内容裁剪在 padding 区域之外 → 内容永远滚不到标题栏下面，模糊形同虚设；
      //   - `contentStartOffset`：把滚动坐标系整体左移 C（静止时自报偏移量 −C，实测 −56），
      //     而 HDS 的 blurEffectiveStartOffset 只接受 [0, +∞)（负数按 0 处理），永远够不到原点
      //     → 内容已在标题栏下钻了 C 还没开始模糊 = 空行程。
      // 详见 brewcommon 的 BrewTitleBar.ets。
      .margin({
        top: brewContentTopInset(this.globalInfoModel.statusBarHeight, false),
        bottom: this.globalInfoModel.naviIndicatorHeight + CommonConstants.SPACE_24,
      })
      .padding({
        left: this.contentLeft(),
        right: this.contentLeft(),
      })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
  }

  build() {
    HdsNavDestination() {
      if (this.detailState.loadingModel.loadingStatus === LoadingStatus.SUCCESS) {
        this.ContentBuilder()
      } else if (this.detailState.loadingModel.loadingStatus === LoadingStatus.FAILED) {
        LoadingFailedView(this.globalInfoModel.widthBreakpoint, () => {
          this.retry();
        })
      } else if (this.detailState.loadingModel.loadingStatus === LoadingStatus.NO_NETWORK) {
        NoNetworkView(this.globalInfoModel.widthBreakpoint, () => {
          this.retry();
        })
      } else if (this.detailState.loadingModel.loadingStatus === LoadingStatus.NOT_FOUND) {
        // 数据源确认没有这个包（自定义 tap 安装的本机包就是这种情况）。
        // 重试只重新取单条：源的数据变了之后重试才会成功
        StatePlaceholderView({
          kind: StatePlaceholderKind.EMPTY,
          message: $r('app.string.brew_detail_absent', this.detailState.params.token),
          actionLabel: $r('app.string.state_retry'),
          onAction: () => {
            this.retry();
          },
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
        title: { mainTitle: this.title },
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
    // 执行 Sheet。选项写法与 MineView 的登录 Sheet 一致（材质 + 宽窄屏的尺寸口径）。
    // Sheet 可随时关闭：命令状态在 `BrewCommandRunner` 单例里，关掉不影响命令执行。
    .bindSheet(this.commandSheetShown, this.CommandSheetBuilder(),
      MaterialUtil.getMaterialOptions<SheetOptions>({
        originOption: {
          showClose: false,
          preferType: (this.globalInfoModel.widthBreakpoint === WidthBreakpoint.WIDTH_SM &&
            !AppStorage.get<boolean>(StorageKey.IS_SIDEBAR_LAYOUT)) ? SheetType.BOTTOM : SheetType.CENTER,
          height: this.globalInfoModel.widthBreakpoint === WidthBreakpoint.WIDTH_XL ?
            ((this.globalInfoModel.deviceHeight - this.globalInfoModel.decorHeight) *
              CommonConstants.SHEET_HEIGHT_RATIO_XL) : SheetSize.LARGE,
          width: this.globalInfoModel.widthBreakpoint === WidthBreakpoint.WIDTH_XL ? CommonConstants.SHEET_WIDTH_XL :
            undefined,
          onWillDisappear: () => {
            this.commandSheetShown = false;
          },
        },
        param: {
          style: CustomImmersiveStyle.ULTRA_THICK,
          backgroundColor: Color.Transparent,
        },
      }) as SheetOptions
    )
    .onBackPressed(() => {
      // 已在处理中就吞掉重复按下 —— 否则连点会把上一页（列表页）也一起弹掉。
      if (this.backPressed) {
        return true;
      }
      this.backPressed = true;
      const pathStack: NavPathStack | undefined = this.detailState.pathStack;
      if (pathStack) {
        pathStack.pop();
        return true;
      }
      // 拿不到页面栈时不吞事件，交给系统默认出栈：
      // 宁可退化成系统默认行为，也不要「返回键彻底失效」。
      return false;
    })
  }
}

@Builder
export function BrewDetailBuilder() {
  BrewDetailView()
}
