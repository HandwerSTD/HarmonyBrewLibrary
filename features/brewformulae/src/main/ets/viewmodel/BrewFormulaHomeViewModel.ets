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
import { BrewFormulaModel, BREW_TITLEBAR_BLUR_RAMP, brewBlurScrollEffect, brewLogRampForPage } from '@ohos/brewcommon';
import type {
  BrewCategoryCard,
  BrewCategoryParams,
  BrewDetailParams,
  BrewFormulaPageData,
  BrewPageData,
} from '@ohos/brewcommon';
import { BrewFormulaState } from './BrewFormulaState';

const TAG: string = '[BrewFormulaHomeVM]';

/**
 * Formulae 首页 ViewModel。
 *
 * 复用 commonbusiness 的 BaseHomeViewModel：拿到模糊标题栏（topNavigationData.hdsTitleBarStyle）、
 * 断点/配色变化处理、返回键处理；不重写这套逻辑，只做 brew 特有的事。
 *
 * 与组件页的唯一结构差异：**没有 banner 区块**。Homebrew 的 banner 接口没有可用素材
 * （mediaUrl 实测为空），与其渲染一块空白，不如把 banner 高度固定为 0。
 */
export class BrewFormulaHomeViewModel extends BaseHomeViewModel<BrewFormulaState> {
  private static instance: BrewFormulaHomeViewModel;
  private globalInfoModel: GlobalInfoModel = AppStorage.get(StorageKey.GLOBAL_INFO) ?? new GlobalInfoModel();
  private formulaModel: BrewFormulaModel = BrewFormulaModel.getInstance();
  /**
   * 顶部让位块所属的 section（对应视图里第一个空白 FlowItem，高度 = 状态栏 + 标题行）。
   *
   * 为何用「内容里的占位块」而不是容器 padding / contentStartOffset：见 BrewFormulaBaseView 与
   * brewcommon 的 BrewTitleBar.ets —— 容器 padding 会裁剪内容、contentStartOffset 会把滚动
   * 坐标系左移 C（静止时自报偏移量 −C），两者都会让标题栏模糊失效（实测）。
   * 组件页就是这么做的：banner 是瀑布流里的第一个 FlowItem。
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
    super(new BrewFormulaState());
    this.state.topNavigationData.title = $r('app.string.tab_formulae');
  }

  public static getInstance(): BrewFormulaHomeViewModel {
    if (!BrewFormulaHomeViewModel.instance) {
      BrewFormulaHomeViewModel.instance = new BrewFormulaHomeViewModel();
    }
    return BrewFormulaHomeViewModel.instance;
  }

  public sendEvent<T>(eventParam: BrewFormulaEventParam<T>): void | boolean {
    const eventType: BrewFormulaEventType | BaseHomeEventType = eventParam.type;
    if (eventType === BrewFormulaEventType.LOAD_FORMULA_PAGE) {
      return this.loadFormulaPage();
    } else if (eventType === BrewFormulaEventType.UPDATE_FLOW_SECTION) {
      return this.updateFlowSection();
    } else if (eventType === BrewFormulaEventType.JUMP_DETAIL) {
      return this.jumpDetail(eventParam.param as BrewDetailParams);
    } else if (eventType === BrewFormulaEventType.JUMP_CATEGORY) {
      return this.jumpCategory(eventParam.param as BrewCategoryParams);
    }
    return super.sendEvent(eventParam as BaseHomeEventParam<T>);
  }

  /**
   * 覆盖基类的 banner 高度计算：Formulae 首页没有 banner 区块，
   * 固定 0 可避免基类按手机 banner 高度做滚动位移与标题栏透明度计算。
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
    brewLogRampForPage('formulae');
  }

  protected loadFormulaPage(): void {
    const isDark: boolean = AppStorage.get(StorageKey.COLOR_MODE) === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    this.state.loadingModel.loadingStatus = LoadingStatus.LOADING;
    WindowUtil.updateStatusBarColor(isDark);
    this.formulaModel.getFormulaPage(this.state.currentPage, this.pageSize)
      .then((result: BrewPageData<BrewFormulaPageData>) => {
        const cards: BrewCategoryCard[] = result.data.cardData;
        this.state.cardSource.setDataArray(cards);
        this.updateFlowSection();
        this.state.loadingModel.hasNextPage =
          cards.length === this.pageSize && (result.totalSize > this.state.currentPage * this.pageSize);
        this.state.loadingModel.loadingStatus = LoadingStatus.SUCCESS;
        TAB_CONTENT_STATUSES[TabBarType.FORMULAE] = true;
        Logger.info(TAG, `loadFormulaPage success, ${cards.length} category cards`);
      })
      .catch((error: BusinessError) => {
        WindowUtil.updateStatusBarColor(isDark);
        TAB_CONTENT_STATUSES[TabBarType.FORMULAE] = isDark;
        if (error.code === RequestErrorCode.NETWORK_CONNECT_FAILED) {
          this.state.loadingModel.loadingStatus = LoadingStatus.NO_NETWORK;
        } else {
          this.state.loadingModel.loadingStatus = LoadingStatus.FAILED;
        }
        Logger.error(TAG, `loadFormulaPage failed. ${error.code} ${error.message}`);
      });
  }

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
    this.formulaPageContext()?.openPage({
      routerName: PageEnum.BREW_DETAIL_VIEW,
      param: param,
    }, true);
  }

  /** 分类卡的「查看全部」：与详情页同一个页面栈（返回时回卡片，而不是回页签首页） */
  protected jumpCategory(param: BrewCategoryParams): void {
    this.formulaPageContext()?.openPage({
      routerName: PageEnum.BREW_FORMULA_CATEGORY_VIEW,
      param: param,
    }, true);
  }

  private formulaPageContext(): PageContext | undefined {
    return AppStorage.get<boolean>(StorageKey.IS_SIDEBAR_LAYOUT) ?
      AppStorage.get<PageContext>(StorageKey.BREW_FORMULA_PAGE_CONTEXT) :
      AppStorage.get<PageContext>(StorageKey.HOME_PAGE_CONTEXT);
  }
}

export enum BrewFormulaEventType {
  LOAD_FORMULA_PAGE = 'loadFormulaPage',
  UPDATE_FLOW_SECTION = 'updateFlowSection',
  JUMP_DETAIL = 'jumpDetail',
  JUMP_CATEGORY = 'jumpCategory',
}

export interface BrewFormulaEventParam<T> {
  type: BrewFormulaEventType | BaseHomeEventType;
  param: T;
}
