/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { ConfigurationConstant } from '@kit.AbilityKit';
import { LengthMetrics } from '@kit.ArkUI';
import { BlurStrategy, DividerMode, HdsNavDestination, HdsTabs } from '@kit.UIDesignKit';
import type { TitleBarStyleOptions } from '@kit.UIDesignKit';
import {
  BreakpointType,
  CommonConstants,
  GlobalInfoModel,
  LoadingFailedView,
  LoadingStatus,
  Logger,
  NoNetworkView,
  PageEnum,
  ResourceUtil,
  StatePlaceholderKind,
  StatePlaceholderView,
  StatusBarColorType,
  StorageKey,
  WIDTH_BREAKPOINTS,
} from '@ohos/common';
import {
  BREW_ACTION_BUTTON_MAX_WIDTH,
  BREW_ACTION_BUTTON_WIDTH,
  BREW_ACTION_BUTTON_BOTTOM_EXTRA,
  BREW_ACTION_BUTTON_HEIGHT,
  BREW_ACTION_BAR_HEIGHT,
  BREW_SECTION_KEY_EXECUTABLES,
  BrewCommandRunner,
  BrewCommandStartResult,
  BrewCommandState,
  BrewCommandStatus,
  BrewInstalledLoader,
  BrewKind,
  BrewPackageRow,
  brewActionBarHeight,
  brewActionBarMaskHeight,
  brewContentTopInset,
  brewLogActionBar,
  brewTitleBarStyle,
} from '@ohos/brewcommon';
import type { BrewDetailParams, BrewInfoRow, BrewInfoSection, BrewPackageItem } from '@ohos/brewcommon';
import { AiExplainInput, AiSettingsStore } from '@ohos/brewcommon';
import { BrewAiExplainCard } from '../component/BrewAiExplainCard';
import { BrewDetailHero } from '../component/BrewDetailHero';
import { BrewDetailMetaBar, BrewInfoSectionView, BrewInstallCommandCard } from '../component/BrewInfoSectionView';
import { BrewLifecycleBanner } from '../component/BrewLifecycleBanner';
import { BrewTldrSectionView } from '../component/BrewTldrSectionView';
import { BrewDetailState, BrewInstallState } from '../viewmodel/BrewDetailState';
import { BrewDetailViewModel } from '../viewmodel/BrewDetailViewModel';

/**
 * 包详情页（formula 与 cask 共用，靠路由参数里的 `kind` 分流）。
 *
 * 分区顺序与实现清单见 docs/brew-api-design.md §5.3。
 * 两种包的字段差异全部在 `BrewDetailNormalizer` 里摊平成 `BrewInfoSection[]`，
 * 因此这里只有一处 `kind` 分支（决定点击同类包时回传的 kind），渲染代码是同一份。
 *
 * 底部操作栏的取值（栏高 / 遮罩渐变长度 / 按钮尺寸）与「我的 - 待更新」页共用
 * `@ohos/brewcommon` 的 `BrewActionBar` —— 两个页面的栏长得一样只由那一处保证。
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

  /**
   * 页面滚动容器。显式持有并在 `HdsNavDestination` 上 `bindToScrollable([this.scroller])`：
   * 嵌了 `HdsTabs` 之后内容不在目的地容器正中间那一层，不绑定标题栏的动态模糊会丢
   * （官方 FAQ `faqs-arkui-1095` 场景二就是这个现象）。只有一页，不需要切页时重新绑定。
   */
  private scroller: Scroller = new Scroller();

  private viewModel: BrewDetailViewModel = BrewDetailViewModel.getInstance();
  /**
   * 与 `BrewCommandRunner` 单例里**同一个**命令状态实例（`BrewCommandState` 是 `@Observed`）。
   * 按钮文案靠它的一级属性变化重渲染。
   */
  @State commandState: BrewCommandState = this.viewModel.getCommandState();
  /** 快照更新回调。详情页的 state 是页面实例自己的，所以回调也存在这里而不是 VM 里 */
  private snapshotListener: () => void = () => {
    this.viewModel.refreshInstallState(this.detailState);
  };

  /**
   * 快照订阅放在页面里而不是 VM 里：`BrewDetailState` 是每个页面实例自己的
   * （详情页可以叠在详情页上），VM 是单例，订阅回调必须知道是哪一页的 state。
   */
  aboutToAppear(): void {
    BrewInstalledLoader.subscribe(this.snapshotListener);
  }

  aboutToDisappear(): void {
    BrewInstalledLoader.unsubscribe(this.snapshotListener);
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

  /**
   * D1 讲解卡的 grounding 输入（spec §4：只用既有详情数据）。
   * dependencies 从归一化分区里取「依赖」行的原文平铺，避免二次遍历 detail 结构。
   */
  private aiExplainInput(): AiExplainInput {
    const input: AiExplainInput = new AiExplainInput();
    input.token = this.detailState.data.name;
    input.kind = this.kind === BrewKind.CASK ? 'cask' : 'formula';
    input.desc = this.detailState.data.desc;
    input.caveats = this.detailState.data.caveats;
    this.detailState.data.sections.forEach((section: BrewInfoSection) => {
      if (section.rows.length === 0) {
        return;
      }
      const firstLabel: ResourceStr = section.rows[0].label;
      // 依赖分区的行首标签是「依赖」；用资源比对太绕，退而求其次：取依赖分区的全部行值拼平。
      // 判定用 section 的第一行 label === 依赖行（资源引用相等只在同资源时成立）。
      if (firstLabel === $r('app.string.brew_label_dependencies')) {
        section.rows.forEach((row: BrewInfoRow) => {
          input.dependencies.push(this.resourceText(row.value));
        });
      }
    });
    return input;
  }

  /** ResourceStr → 文本（动态字符串直接用；资源走 ResourceUtil）。 */
  private resourceText(value: ResourceStr): string {
    if (typeof value === 'string') {
      return value as string;
    }
    try {
      const ctx: Context | undefined =
        this.getUIContext().getHostContext() as Context;
      return ResourceUtil.getResourceString(ctx, value as Resource);
    } catch (error) {
      return '';
    }
  }

  /** E1 引导：跳「我的 - 设置 - AI 设置」（页面栈从详情页回退到「我的」再 push 不现实，
   * 直接 push 到 AI 设置路由——它注册在 mine 模块的 routerMap，全局可达）。 */
  private openAiSettings(): void {
    this.detailState.pathStack?.pushPath({ name: PageEnum.MINE_AI_SETTINGS_VIEW });
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
      BrewCommandRunner.getInstance().openSheet();
      return;
    }
    if (this.viewModel.startInstallOrUpgrade(this.detailState) === BrewCommandStartResult.STARTED) {
      BrewCommandRunner.getInstance().openSheet();
    }
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
   * 操作栏的判据行：`mask − height` 必须等于 `gradient`，`height` 必须等于 56 + `navi` ——
   * 对不上说明两个高度用了不同的来源。同内容只打一次（断点变化会反复触发渲染）。
   */
  private logActionBar(): void {
    brewLogActionBar('detail', this.globalInfoModel.naviIndicatorHeight,
      WIDTH_BREAKPOINTS[this.globalInfoModel.widthBreakpoint]);
  }

  /**
   * 底部主操作栏：`HdsTabs` 页签栏承载的内容 —— 白色渐变遮罩 + 本页唯一的主操作按钮。
   *
   * 遮罩的高度、颜色、渐变全部由 HDS 画（见 `build()` 里的 `barBackgroundStyle`），
   * 所以这个构建器只管按钮的排布：栏高与按钮中线同源，且左右内缩与内容区一致。
   * 页签栏上方的渐变区由系统绘制、不吃触摸，那里的滚动手势仍归内容区。
   */
  @Builder
  ActionBarBuilder() {
    Row() {
      Button(this.installActionLabel())
        .width(BREW_ACTION_BUTTON_WIDTH)
        .constraintSize({ maxWidth: BREW_ACTION_BUTTON_MAX_WIDTH })
        .height(BREW_ACTION_BUTTON_HEIGHT)
        .type(ButtonType.ROUNDED_RECTANGLE)
        // 圆角不指定，用系统默认（本机实测渲染出来约 6vp）
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(FontWeight.Medium)
        // 「已安装」表达的是状态，沿用它在卡片里那套次要配色；可点的两个状态用强调色
        .backgroundColor(this.installActionEnabled() ? $r('sys.color.ohos_id_color_emphasize') :
          $r('sys.color.comp_background_tertiary'))
        .fontColor(this.installActionEnabled() ? $r('sys.color.font_on_primary') :
          $r('sys.color.font_tertiary'))
        .enabled(this.installActionEnabled())
        .onClick(() => {
          this.onInstallActionClick();
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    // 判据日志挂在 onAppear 上：@Builder 里不允许裸语句，而这里是「操作栏渲染了」这一刻
    // （日志本身按内容去重，反复 appear 不会刷屏）
    .onAppear(() => {
      this.logActionBar();
    })
    // 左右内缩必须与内容区（`Scroll` 内层 Column 的 padding）同源：按钮宽 60% 才有意义，
    // 而 60% 是相对**去除内缩后**的内容区宽度。
    .padding({
      left: this.contentLeft(),
      right: this.contentLeft(),
      // 底边多留 BREW_ACTION_BUTTON_BOTTOM_EXTRA：把按钮往上抬，离窗口下沿远一点
      bottom: this.globalInfoModel.naviIndicatorHeight + BREW_ACTION_BUTTON_BOTTOM_EXTRA,
    })
  }

  @Builder
  ContentBuilder() {
    Scroll(this.scroller) {
      Column({ space: $r('sys.float.padding_level8') }) {
        // 1 Hero
        BrewDetailHero({ data: this.detailState.data, kind: this.kind })

        // 9 生命周期警示（deprecated / disabled）—— 位置靠前，因为它影响"要不要装"
        if (this.detailState.data.hasLifecycle) {
          BrewLifecycleBanner({ notice: this.detailState.data.lifecycle })
        }

        // 2 安装命令 + 复制（主操作按钮不在这里，见 ActionBarBuilder）
        BrewInstallCommandCard({ command: this.detailState.data.installCommand })

        // 3 元信息
        BrewDetailMetaBar({ rows: this.detailState.data.meta })

        // AI 讲解卡（spec §4：元信息条之后、各分区之前——命令卡是刚性的，
        // 讲解是增强的）。autoStart = 自动生成开关开且有 Key（快照判据，
        // 无 Key 恒 false：不自动请求也不显示引导）；失败静默在卡内处理。
        BrewAiExplainCard({
          input: this.aiExplainInput(),
          autoStart: AiSettingsStore.autoExplain(),
          onConfigureKey: () => {
            this.openAiSettings();
          },
        })

        // 4/5/6/7/11 各分区（数据驱动；空分区不会出现在数组里）

        // 4/5/6/7/11 各分区（数据驱动；空分区不会出现在数组里）。
        // tldr「用法示例」装在「提供的命令」正下游：该分区 formula 独有（cask 路径不创建，
        // G2 在数据层成立），用 section.key 识别而不是魔法下标 —— 分区集合是
        // 「空分区不创建」的，下标会随包数据漂移，key 不会。
        ForEach(this.detailState.data.sections, (section: BrewInfoSection) => {
          // tldr 与宿主分区之间保持与页面其它卡片相同的间距节奏（外层 Column 的
          // space 只作用于本 wrapper 之外，wrapper 内部要自己给；space 是构造参数）
          Column({ space: $r('sys.float.padding_level8') }) {
            BrewInfoSectionView({ section: section })
            if (section.key === BREW_SECTION_KEY_EXECUTABLES && this.kind === BrewKind.FORMULA &&
              this.detailState.hasTldr) {
              // 插入转场（G15）：淡入 + 轻微上移，消掉「数据到达瞬间闪现」的突兀感。
              // 移除侧走同一效果的默认（对称），不单独配消失动画。
              BrewTldrSectionView({ token: this.detailState.params.token, page: this.detailState.tldrPage })
                .transition(TransitionEffect.OPACITY.animation({ duration: 300, curve: Curve.Friction })
                  .combine(TransitionEffect.translate({ y: 12 })))
            }
          }
          .width('100%')
        }, (section: BrewInfoSection, index: number) => `section_${index}`)

        // 8 安装提示（caveats）—— 位置与顺序不变
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
    // 底部为操作栏留出滚动空间。**只加 BREW_ACTION_BAR_HEIGHT**：内层 Column 的 margin.bottom
    // 里已经有 naviIndicatorHeight，操作栏自己那一段导航条高度由它的栏高与按钮的
    // padding.bottom 覆盖，这里再加一次会多出一段空白。没有操作栏时是 0，与改动前一致。
    //
    // 底部可以用 contentEndOffset（顶部不行，见内层 margin 的注释）：它只在内容末尾加空白，
    // 不移动滚动坐标系原点，静止时 scroller 自报的偏移量仍是 0。
    .contentEndOffset(this.detailState.commandReady ? BREW_ACTION_BAR_HEIGHT : 0)
  }

  build() {
    HdsNavDestination() {
      if (this.detailState.loadingModel.loadingStatus === LoadingStatus.SUCCESS) {
        // 底部主操作栏由一个只有一页的 `HdsTabs` 承载：页签栏就是这条栏，
        // 它的背板（白色渐变遮罩）由 HDS 画。`commandReady` 为假时整条栏不渲染，
        // 页面与改动前一致。
        if (this.detailState.commandReady) {
          HdsTabs({ barPosition: BarPosition.End, index: 0 }) {
            TabContent() {
              this.ContentBuilder()
            }
            .tabBar(this.ActionBarBuilder())      // 页签栏内容 = 唯一的主操作按钮
          }
          .width('100%')
          .height('100%')
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
    // 显式绑定滚动容器：内容嵌在 HdsTabs 的 TabContent 里之后，HDS 不再自动识别它，
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
