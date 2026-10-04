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
import { BrewCaskModel, BREW_TITLEBAR_BLUR_RAMP, brewBlurScrollEffect,
  brewLogRampForPage, BrewTable } from '@ohos/brewcommon';
import type {
  BrewCaskCard,
  BrewCaskCategory,
  BrewCaskPageData,
  BrewCategoryParams,
  BrewDetailParams,
  BrewPageData,
} from '@ohos/brewcommon';
import { BrewCaskState } from './BrewCaskState';

const TAG: string = '[BrewCaskHomeVM]';

/**
 * Casks 首页 ViewModel。
 *
 * 与 BrewFormulaHomeViewModel 一样复用 commonbusiness 的 BaseHomeViewModel
 * （模糊标题栏、断点/配色处理、返回键），两页的差异只剩数据形状：
 * Casks 的 mock 是「分类 -> 卡片 -> 条目」三层，比 Formulae 多一层，所以
 * 加载后要先把卡片从分类里摊平再交给瀑布流（卡片上已带 categoryKey，见 BrewBrowseBuilder.caskPage）。
 *
 * 分类 chips 不在这里 —— 它跟着「看某个分类的全部」一起搬到了分类二级页
 * `BrewCaskCategoryView`（由 `jumpCategory` 打开），首页因此只剩「分类卡瀑布流」一件事，
 * 与 Formulae 首页的职责完全对齐。
 */
export class BrewCaskHomeViewModel extends BaseHomeViewModel<BrewCaskState> {
  private static instance: BrewCaskHomeViewModel;
  private globalInfoModel: GlobalInfoModel = AppStorage.get(StorageKey.GLOBAL_INFO) ?? new GlobalInfoModel();
  private caskModel: BrewCaskModel = BrewCaskModel.getInstance();
  /**
   * 顶部让位块所属的 section（对应视图里第一个空白 FlowItem，高度 = 状态栏 + 标题行）。
   *
   * 为何用「内容里的占位块」而不是容器 padding / contentStartOffset：见 BrewCaskBaseView 与
   * brewcommon 的 BrewTitleBar.ets —— 容器 padding 会裁剪内容、contentStartOffset 会把滚动
   * 坐标系左移 C（静止时自报偏移量 −C），两者都会让标题栏模糊失效（实测）。
   * 与 Formulae 首页同一份做法。
   */
  private spacerSection: SectionOptions = {
    itemsCount: 1,
    crossCount: 1,
  };
  /** 底部留白块所属的 section（对应视图里最后一个空白 FlowItem） */
  private footerSection: SectionOptions = {
    itemsCount: 1,
    crossCount: 1,
  };
  private categorySection: SectionOptions = {
    itemsCount: 0,
    crossCount: new BreakpointType({
      sm: 1,
      md: 2,
      lg: 3,
    }).getValue(this.globalInfoModel.widthBreakpoint),
    margin: $r('sys.float.padding_level8'),
  };

  private constructor() {
    super(new BrewCaskState());
    this.state.topNavigationData.title = $r('app.string.tab_casks');
  }

  public static getInstance(): BrewCaskHomeViewModel {
    if (!BrewCaskHomeViewModel.instance) {
      BrewCaskHomeViewModel.instance = new BrewCaskHomeViewModel();
    }
    return BrewCaskHomeViewModel.instance;
  }

  public sendEvent<T>(eventParam: BrewCaskEventParam<T>): void | boolean {
    const eventType: BrewCaskEventType | BaseHomeEventType = eventParam.type;
    if (eventType === BrewCaskEventType.LOAD_CASK_PAGE) {
      return this.loadCaskPage();
    } else if (eventType === BrewCaskEventType.UPDATE_FLOW_SECTION) {
      return this.updateFlowSection();
    } else if (eventType === BrewCaskEventType.JUMP_DETAIL) {
      return this.jumpDetail(eventParam.param as BrewDetailParams);
    } else if (eventType === BrewCaskEventType.JUMP_CATEGORY) {
      return this.jumpCategory(eventParam.param as BrewCategoryParams);
    }
    return super.sendEvent(eventParam as BaseHomeEventParam<T>);
  }

  /**
   * 覆盖基类的 banner 高度计算：Casks 首页同样没有 banner 区块。
   * 注意：本方法会被基类构造函数调用，此时基类的 this.state 已赋值，因此只允许访问 state。
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
   * 本页内容在静止时就贴在标题栏下沿（用**内容里的占位块**让位，所以静止时 scroller 自报的
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
    brewLogRampForPage('casks');
  }

  private tableObserver: () => void = () => {
    Logger.debug(TAG, `[load] 包表已落地（${BrewTable.statsLine()}），重出 Casks 页`);
    this.loadCaskPage();
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
    this.loadCaskPage();
    BrewTable.refresh(true).then(() => {
      this.loadCaskPage();
    });
  }

  /**
   * 每次进页面都推一次取数（非强制）：内部按两片各自的新鲜窗口判定要不要真发请求，
   * 两片都在窗口内时**一个字节都不发**。
   */
  public refreshTable(): void {
    BrewTable.refresh().then(() => {
      this.loadCaskPage();
    });
  }

  protected loadCaskPage(): void {
    const t0: number = Date.now();
    const isDark: boolean = AppStorage.get(StorageKey.COLOR_MODE) === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    WindowUtil.updateStatusBarColor(isDark);
    // 状态按包表两片分别判定（与 Formulae 首页同一口径）
    const tableState: string = BrewTable.state();
    Logger.debug(TAG, `[load] Casks 页构建开始 tableState=${tableState} page=${this.state.currentPage}`);
    this.caskModel.getCaskPage(this.state.currentPage, this.pageSize)
      .then((result: BrewPageData<BrewCaskPageData>) => {
        const categories: BrewCaskCategory[] = result.data.caskCategories ?? [];
        const cards: BrewCaskCard[] = BrewCaskHomeViewModel.flattenCards(categories);
        this.state.cardSource.setDataArray(cards);
        this.updateFlowSection();
        // Casks 一次返回全部分类，页签内不需要「加载更多」
        this.state.loadingModel.hasNextPage = false;
        if (tableState !== 'ready') {
          this.state.loadingModel.loadingStatus = tableState === 'building' ?
            LoadingStatus.BUILDING : LoadingStatus.EMPTY_DATA;
          TAB_CONTENT_STATUSES[TabBarType.CASKS] = false;
          Logger.info(TAG, `cask page waiting, table state=${tableState}`);
          return;
        }
        this.state.loadingModel.loadingStatus = LoadingStatus.SUCCESS;
        TAB_CONTENT_STATUSES[TabBarType.CASKS] = true;
        Logger.info(TAG, `loadCaskPage success, ${categories.length} categories, ${cards.length} cards ` +
          `in ${Date.now() - t0}ms | ${BrewTable.statsLine()}`);
      })
      .catch((error: BusinessError) => {
        WindowUtil.updateStatusBarColor(isDark);
        TAB_CONTENT_STATUSES[TabBarType.CASKS] = isDark;
        if (error.code === RequestErrorCode.NETWORK_CONNECT_FAILED) {
          this.state.loadingModel.loadingStatus = LoadingStatus.NO_NETWORK;
        } else {
          this.state.loadingModel.loadingStatus = LoadingStatus.FAILED;
        }
        Logger.error(TAG, `loadCaskPage failed. ${error.code} ${error.message}`);
      });
  }

  /**
   * 把「分类 -> 卡片」两层摊平成卡片列表（首页按分类平铺渲染）。
   *
   * 卡片上已经带了 categoryKey（`BrewBrowseBuilder.caskPage` 从所属分类复制），
   * 所以摊平后卡片自己就知道该显示哪个分类名与图标，不需要再回查分类。
   */
  private static flattenCards(categories: BrewCaskCategory[]): BrewCaskCard[] {
    const cards: BrewCaskCard[] = [];
    categories.forEach((category: BrewCaskCategory) => {
      (category.caskCards ?? []).forEach((card: BrewCaskCard) => cards.push(card));
    });
    return cards;
  }

  /** 与 BrewFormulaHomeViewModel.updateFlowSection 同款：列数/边距随断点变，三个 section 与视图里的子组件一一对应 */
  protected updateFlowSection(): void {
    const globalInfoModel: GlobalInfoModel =
      AppStorage.get<GlobalInfoModel>(StorageKey.GLOBAL_INFO) ?? new GlobalInfoModel();
    this.categorySection.itemsCount = this.state.cardSource.totalCount();
    this.categorySection.crossCount = new BreakpointType({
      sm: 1,
      md: 2,
      lg: 3,
    }).getValue(globalInfoModel.widthBreakpoint);
    const leftMargin: Length =
      new BreakpointType<Length>({
        sm: $r('sys.float.padding_level8'),
        md: $r('sys.float.padding_level12'),
        lg: (HdsUtil.isSupportNewMaterialApi() || AppStorage.get<boolean>(StorageKey.IS_SIDEBAR_LAYOUT)) ?
          CommonConstants.SPACE_32 :
          CommonConstants.SPACE_32 + CommonConstants.TAB_BAR_WIDTH,
      }).getValue(globalInfoModel.widthBreakpoint);
    const rightMargin: Length = new BreakpointType<Length>({
      sm: $r('sys.float.padding_level8'),
      md: $r('sys.float.padding_level12'),
      lg: $r('sys.float.padding_level16'),
    }).getValue(globalInfoModel.widthBreakpoint);
    const columnMargin: Length = new BreakpointType<Length>({
      sm: $r('sys.float.padding_level8'),
      md: $r('sys.float.padding_level10'),
      lg: $r('sys.float.padding_level12'),
    }).getValue(globalInfoModel.widthBreakpoint);
    this.categorySection.margin = {
      left: leftMargin,
      right: rightMargin,
      top: columnMargin,
      bottom: columnMargin,
    };
    // 三个 section 对应视图里的 [顶部空白块, 分类卡, 底部空白块]，顺序必须与子组件顺序一致
    this.state.sections.splice(0, this.state.sections.length(),
      [this.spacerSection, this.categorySection, this.footerSection]);
    Logger.debug(TAG, `updateFlowSection: ${this.categorySection.itemsCount} cards`);
  }

  protected jumpDetail(param: BrewDetailParams): void {
    this.caskPageContext()?.openPage({
      routerName: PageEnum.BREW_DETAIL_VIEW,
      param: param,
    }, true);
  }

  /** 分类卡的「查看全部」：与详情页同一个页面栈（返回时回卡片，而不是回页签首页） */
  protected jumpCategory(param: BrewCategoryParams): void {
    this.caskPageContext()?.openPage({
      routerName: PageEnum.BREW_CASK_CATEGORY_VIEW,
      param: param,
    }, true);
  }

  private caskPageContext(): PageContext | undefined {
    return AppStorage.get<boolean>(StorageKey.IS_SIDEBAR_LAYOUT) ?
      AppStorage.get<PageContext>(StorageKey.BREW_CASK_PAGE_CONTEXT) :
      AppStorage.get<PageContext>(StorageKey.HOME_PAGE_CONTEXT);
  }
}

export enum BrewCaskEventType {
  LOAD_CASK_PAGE = 'loadCaskPage',
  UPDATE_FLOW_SECTION = 'updateFlowSection',
  JUMP_DETAIL = 'jumpDetail',
  JUMP_CATEGORY = 'jumpCategory',
}

export interface BrewCaskEventParam<T> {
  type: BrewCaskEventType | BaseHomeEventType;
  param: T;
}
