/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { ConfigurationConstant } from '@kit.AbilityKit';
import type { BusinessError } from '@kit.BasicServicesKit';
import {
  BreakpointType,
  CommonConstants,
  GlobalInfoModel,
  HdsUtil,
  LoadingStatus,
  Logger,
  PageContext,
  PageEnum,
  RequestErrorCode,
  StorageKey,
  WindowUtil,
} from '@ohos/common';
import {
  BaseHomeEventParam,
  BaseHomeEventType,
  BaseHomeViewModel,
  TabBarType,
  TAB_CONTENT_STATUSES,
} from '@ohos/commonbusiness';
import type { TitleBarStyleOptions } from '@kit.UIDesignKit';
import { BrewDiscoverBoard, BrewDiscoverModel, BREW_TITLEBAR_BLUR_RAMP, brewBlurScrollEffect,
  brewLogRampForPage, BrewTable } from '@ohos/brewcommon';
import { BrewDiscoverFeedItem, BrewDiscoverFeedType } from '../model/BrewDiscoverFeedItem';
import type {
  BrewDetailParams,
  BrewDiscoverBoardParams,
  BrewDiscoverFeatured,
  BrewDiscoverPageData,
} from '@ohos/brewcommon';
import { BrewDiscoverState } from './BrewDiscoverState';

const TAG: string = '[BrewDiscoverVM]';

/**
 * 多栏瀑布流的断点配置 —— **与组件页 `ComponentListViewModel.updateFlowSection()`
 * 逐项同源**，这是「和组件页视效对齐」的关键。
 *
 * 踩过的坑：最初把 md 写成 1 列（想着"卡片更大就少放一列"），而这台 PC 恰好跑在 **md** 档
 * —— 于是 Discover 是单栏、组件页是双栏，一眼就不像同一个东西。
 * 实测算过账（1vp≈3.7px）：内缩 45px = 12vp = `level12`、列间距 23px = 6vp = `level6`，
 * 与组件页 md 档的 margin(`level12`) / columnsGap(`level6`) 完全吻合，确认就是 md 档。
 *
 * 所以这里不再自己拍列数，直接照抄组件页：sm 1 栏 / md 2 栏 / lg 3 栏。
 */
const CARD_CROSS_COUNT: BreakpointType<number> = new BreakpointType<number>({
  sm: 1,
  md: 2,
  lg: 3,
});

/** 左右内缩。组件页同样用三档 BreakpointType，这里保持同值同档 */
const CONTENT_LEFT: BreakpointType<Length> = new BreakpointType<Length>({
  sm: $r('sys.float.padding_level8'),
  md: $r('sys.float.padding_level12'),
  lg: (HdsUtil.isSupportNewMaterialApi() || AppStorage.get<boolean>(StorageKey.IS_SIDEBAR_LAYOUT)) ?
    CommonConstants.SPACE_32 : CommonConstants.SPACE_32 + CommonConstants.TAB_BAR_WIDTH,
});

const CONTENT_RIGHT: BreakpointType<Length> = new BreakpointType<Length>({
  sm: $r('sys.float.padding_level8'),
  md: $r('sys.float.padding_level12'),
  lg: $r('sys.float.padding_level16'),
});

/** 分区间距（section 的上下外边距），与组件页同值 */
const CONTENT_TOP: BreakpointType<Length> = new BreakpointType<Length>({
  sm: $r('sys.float.padding_level8'),
  md: $r('sys.float.padding_level10'),
  lg: $r('sys.float.padding_level12'),
});

/**
 * Discover 首页 ViewModel。
 *
 * 复用 commonbusiness 的 BaseHomeViewModel —— 模糊标题栏（topNavigationData.hdsTitleBarStyle）、
 * 断点/配色变化、返回键、页面栈都从基类拿，与 Formulae / Casks 完全同构。
 *
 * 与另外两个页签的两个差异：
 *   1. 榜单数据是**一份整体**（6 张榜），不分页，所以没有 currentPage/hasNextPage 逻辑；
 *   2. `categoryKey` 这类概念不属于榜单，跳详情时按条目自带的 categoryKey 传。
 */
export class BrewDiscoverHomeViewModel extends BaseHomeViewModel<BrewDiscoverState> {
  private static instance: BrewDiscoverHomeViewModel;
  private globalInfoModel: GlobalInfoModel = AppStorage.get(StorageKey.GLOBAL_INFO) ?? new GlobalInfoModel();
  private discoverModel: BrewDiscoverModel = BrewDiscoverModel.getInstance();
  /**
   * 单 section。**左右内缩由 section 的 margin 提供，视图层不再写 padding.left/right**
   * （两个来源必然重复，见 §9.9 / §9.10）。
   *
   * 这也是组件页的做法：`ComponentBaseView` 的 `WaterFlow` 上一个 `.padding()` 都没有，
   * 内缩全部来自 `componentColumnSection.margin`。照它办才能保证两边几何一致。
   */
  /**
   * 顶部让位块所属的 section（对应视图里第一个空白 FlowItem，高度 = 状态栏 + 标题行）。
   *
   * 为何用「内容里的占位块」而不是容器 padding / contentStartOffset：见 BrewDiscoverBaseView 与
   * brewcommon 的 BrewTitleBar.ets —— 容器 padding 会裁剪内容、contentStartOffset 会把滚动
   * 坐标系左移 C（静止时自报偏移量 −C），两者都会让标题栏模糊失效（实测）。
   */
  private spacerSection: SectionOptions = {
    itemsCount: 1,
    crossCount: 1,
    margin: 0,
  };
  /** 底部留白块所属的 section（对应视图里最后一个空白 FlowItem） */
  private footerSection: SectionOptions = {
    itemsCount: 1,
    crossCount: 1,
    margin: 0,
  };
  /** 承载**整条瀑布流**（大图卡 + 榜卡混排）的那一个 section。
   *  原名 `boardSection` —— 混排后它不再只装榜卡，名字会误导，故更名。 */
  private feedSection: SectionOptions = {
    itemsCount: 0,
    crossCount: 1,
    margin: 0,
  };

  private constructor() {
    super(new BrewDiscoverState());
    this.state.topNavigationData.title = $r('app.string.brew_tab_discover');
  }

  public static getInstance(): BrewDiscoverHomeViewModel {
    if (!BrewDiscoverHomeViewModel.instance) {
      BrewDiscoverHomeViewModel.instance = new BrewDiscoverHomeViewModel();
    }
    return BrewDiscoverHomeViewModel.instance;
  }

  public sendEvent<T>(eventParam: BrewDiscoverEventParam<T>): void | boolean {
    const eventType: BrewDiscoverEventType | BaseHomeEventType = eventParam.type;
    if (eventType === BrewDiscoverEventType.LOAD_DISCOVER) {
      return this.loadDiscover();
    }
    if (eventType === BrewDiscoverEventType.UPDATE_FLOW_SECTION) {
      return this.updateFlowSection();
    }
    if (eventType === BrewDiscoverEventType.JUMP_DETAIL) {
      return this.jumpDetail(eventParam.param as BrewDetailParams);
    }
    if (eventType === BrewDiscoverEventType.JUMP_BOARD) {
      return this.jumpBoard(eventParam.param as BrewDiscoverBoardParams);
    }
    return super.sendEvent(eventParam as BaseHomeEventParam<T>);
  }

  /**
   * 覆盖基类的 banner 高度计算：Discover 没有 banner 区块（Homebrew 无横幅素材），
   * 固定 0 可避免基类按手机 banner 高度做滚动位移与标题栏透明度计算。
   * 注意本方法会被基类构造函数调用，此时只允许访问 state。
   */
  protected changeBannerHeight(): void {
    this.state.bannerState.bannerHeight = 0;
    this.state.bannerHeight = 0;
  }

  /**
   * 覆写基类的标题栏样式。
   *
   * 基类那套 `blurEffectiveStartOffset/EndOffset` 是给**有 banner 的页**（组件/样例/实践）算的：
   * 它们顶部是一张占满状态栏的大图，要等大图收上去才该开始模糊。本页 `bannerHeight` 被上面的
   * `changeBannerHeight()` 置 0，套那组值会算出**反向区间**（起点 > 终点）→ 标题栏永不模糊，
   * 而且编译过、无异常、无日志。
   *
   * 本页内容在静止时就贴在标题栏下沿（用**滚动容器 padding** 让位，所以静止时 scroller 自报的
   * 偏移量是 0），模糊从滚动第一像素起连续增长 —— 具体区间与自检都在 `BrewTitleBar` 里，
   * 所有 brew 页共用同一份，不在各页各写一遍。
   *
   * 注意：本方法会被基类构造函数调用（此时 `this.state` 已赋值），所以只允许访问 state 与 AppStorage。
   */
  protected setTitleBarStyle(): void {
    super.setTitleBarStyle();   // 基类：标题行间距 hdsTitleBarPadding + 标题颜色 + 材质选择
    const style: TitleBarStyleOptions | undefined = this.state.topNavigationData.hdsTitleBarStyle;
    if (style === undefined) {
      return;
    }
    // **只替换模糊区间，不整份替换**：整份替换会连带丢掉基类的 `hdsTitleBarPadding`
    // （列表页 `Brew*ListView` 读它给标题行留左右间距，与参考页 `ComponentListView` 同款），
    // 表现为标题行左右位移 —— 这是"改模糊改出别的毛病"最隐蔽的一种。
    // 材质类型也保持基类选的 IMMERSIVE_GRADIENT_BLUR（与参考页 组件 一致），只补上区间。
    // 区间恒为 [0, 104]（不要减 contentStartOffset，理由见 BrewTitleBar 顶部注释）。
    style.scrollEffectOpts = brewBlurScrollEffect(style.scrollEffectOpts, BREW_TITLEBAR_BLUR_RAMP);
    brewLogRampForPage('discover');
  }

  protected loadDiscover(): void {
    const t0: number = Date.now();
    const isDark: boolean =
      AppStorage.get(StorageKey.COLOR_MODE) === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    WindowUtil.updateStatusBarColor(isDark);
    // 状态按包表两片分别判定（与两个浏览页同一口径）
    const tableState: string = BrewTable.state();
    Logger.debug(TAG, `[load] Discover 页构建开始 tableState=${tableState}`);
    this.discoverModel.getDiscoverPage()
      .then((result: BrewDiscoverPageData) => {
        // **空榜不上屏**：骨架恒为 6 张榜（boardId 1..6 稳定，二级页照旧按 id 路由），
        // 但安装量片未到时六张榜都没有成员。过滤后 feed 为空 → 走 BUILDING / EMPTY_DATA，
        // 而不是摆出 6 张只有标题的空榜卡。
        const boards: BrewDiscoverBoard[] = (result.boards ?? [])
          .filter((b: BrewDiscoverBoard) => b.entries.length > 0);
        const featured: BrewDiscoverFeatured[] = result.featured ?? [];
        // 两类卡混排：每张大图卡排在**它所属那张榜**的前面（规则与理由见 mix 的注释）。
        // 旧写法是「featured 一段 + boards 一段」的两段拼接 —— 大图卡全挤在首屏，
        // 与榜卡完全分离（需求方要求改成混排）。
        const feed: BrewDiscoverFeedItem[] = BrewDiscoverFeedItem.mix(featured, boards);
        this.state.cardSource.setDataArray(feed);
        this.state.snapshotDate = result.snapshotDate ?? '';
        this.updateFlowSection();
        this.state.loadingModel.hasNextPage = false;
        if (tableState !== 'ready') {
          this.state.loadingModel.loadingStatus = tableState === 'building' ?
            LoadingStatus.BUILDING : LoadingStatus.EMPTY_DATA;
          TAB_CONTENT_STATUSES[TabBarType.DISCOVER] = false;
          Logger.info(TAG, `discover waiting, table state=${tableState}`);
          return;
        }
        this.state.loadingModel.loadingStatus = LoadingStatus.SUCCESS;
        TAB_CONTENT_STATUSES[TabBarType.DISCOVER] = true;
        // 打出组装后的类型顺序（F=大图卡 B=榜卡）：混排规则唯一可核对的地方，
        // 期望 `F F B B F B F B B F B`。只打类型不打 token —— 一眼能看出归属是否正确。
        let order: string = '';
        feed.forEach((one: BrewDiscoverFeedItem) => {
          order += one.feedType === BrewDiscoverFeedType.FEATURED ? 'F ' : 'B ';
        });
        Logger.info(TAG,
          `loadDiscover success, ${featured.length} featured + ${boards.length} boards, ` +
          `order [${order.trim()}], snapshot ${result.snapshotDate} in ${Date.now() - t0}ms | ` +
          `${BrewTable.statsLine()}`);
      })
      .catch((error: BusinessError) => {
        WindowUtil.updateStatusBarColor(isDark);
        TAB_CONTENT_STATUSES[TabBarType.DISCOVER] = isDark;
        if (error.code === RequestErrorCode.NETWORK_CONNECT_FAILED) {
          this.state.loadingModel.loadingStatus = LoadingStatus.NO_NETWORK;
        } else {
          this.state.loadingModel.loadingStatus = LoadingStatus.FAILED;
        }
        Logger.error(TAG, `loadDiscover failed: ${error.code} ${error.message}`);
      });
  }

  /**
   * 订阅包表落地。**必须由页面成对订阅与退订**（见 `BrewDiscoverBaseView`）。
   *
   * 本类是单例，所以订阅者必须是**同一个函数引用**，否则退订删不掉。
   */
  private tableObserver: () => void = () => {
    Logger.debug(TAG, `[load] 包表已落地（${BrewTable.statsLine()}），重出 Discover 页`);
    this.loadDiscover();
  };

  public subscribeTable(): void {
    Logger.debug(TAG, '[subscribe] 注册包表观察者（成对：aboutToAppear / aboutToDisappear）');
    BrewTable.addObserver(this.tableObserver);
  }

  public unsubscribeTable(): void {
    BrewTable.removeObserver(this.tableObserver);
  }

  /** 重试按钮：强制重取两片（跳过新鲜窗口判定） */
  public retryLoad(): void {
    this.loadDiscover();
    BrewTable.refresh(true).then(() => {
      this.loadDiscover();
    });
  }

  /**
   * 每次进页面都推一次取数（非强制）：内部按两片各自的新鲜窗口判定要不要真发请求，
   * 两片都在窗口内时**一个字节都不发**。
   */
  public refreshTable(): void {
    BrewTable.refresh().then(() => {
      this.loadDiscover();
    });
  }

  /**
   * 多栏瀑布流的几何全部在这里定：列数 + section 内缩。
   * 列/行间距是 WaterFlow 自身的属性（在视图里），与组件页同值。
   */
  protected updateFlowSection(): void {
    // WidthBreakpoint 是 ArkUI SDK 的全局类型（与 SectionOptions / WaterFlowSections 同类），
    // 不从 @ohos/common 导入 —— 它不在那里导出。
    const breakpoint: WidthBreakpoint = this.globalInfoModel.widthBreakpoint;
    this.feedSection.itemsCount = this.state.cardSource.totalCount();
    this.feedSection.crossCount = CARD_CROSS_COUNT.getValue(breakpoint);
    this.feedSection.margin = {
      left: CONTENT_LEFT.getValue(breakpoint),
      right: CONTENT_RIGHT.getValue(breakpoint),
      top: CONTENT_TOP.getValue(breakpoint),
      bottom: $r('sys.float.padding_level6'),
    };
    // 三个 section 对应视图里的 [顶部空白块, 瀑布流内容, 底部空白块]，顺序必须与子组件顺序一致
    this.state.sections.splice(0, this.state.sections.length(),
      [this.spacerSection, this.feedSection, this.footerSection]);
    Logger.debug(TAG,
      `updateFlowSection: ${this.feedSection.itemsCount} feed items, crossCount ${this.feedSection.crossCount}`);
  }

  private currentPageContext(): PageContext | undefined {
    return AppStorage.get<boolean>(StorageKey.IS_SIDEBAR_LAYOUT) ?
      AppStorage.get<PageContext>(StorageKey.BREW_DISCOVER_PAGE_CONTEXT) :
      AppStorage.get<PageContext>(StorageKey.HOME_PAGE_CONTEXT);
  }

  protected jumpDetail(param: BrewDetailParams): void {
    this.currentPageContext()?.openPage({
      routerName: PageEnum.BREW_DETAIL_VIEW,
      param: param,
    }, true);
  }

  protected jumpBoard(param: BrewDiscoverBoardParams): void {
    this.currentPageContext()?.openPage({
      routerName: PageEnum.BREW_DISCOVER_BOARD_VIEW,
      param: param,
    }, true);
  }
}

export enum BrewDiscoverEventType {
  LOAD_DISCOVER = 'loadDiscover',
  UPDATE_FLOW_SECTION = 'updateFlowSection',
  JUMP_DETAIL = 'jumpDetail',
  JUMP_BOARD = 'jumpBoard',
}

export interface BrewDiscoverEventParam<T> {
  type: BrewDiscoverEventType | BaseHomeEventType;
  param: T;
}
