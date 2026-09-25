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
  CommonConstants,
  GlobalInfoModel,
  LoadingFailedView,
  LoadingStatus,
  NoNetworkView,
  StatusBarColorType,
  StorageKey,
} from '@ohos/common';
import {
  BREW_CHIP_BAR_HEIGHT,
  BrewCategoryCardHeader,
  BrewKind,
  BrewPackageRow,
  brewPageContentLeft,
  brewPageContentRight,
  brewTitleBarStyle,
  brewTitleBarTotalHeight,
} from '@ohos/brewcommon';
import type { BrewCaskCard, BrewCaskCategory, BrewCategoryParams, BrewPackageItem } from '@ohos/brewcommon';
import { BrewCategoryChipBar } from '../component/BrewCategoryChipBar';
import { BrewCaskCategoryState } from '../viewmodel/BrewCaskCategoryState';
import { BrewCaskCategoryVM } from '../viewmodel/BrewCaskCategoryVM';

/**
 * Casks 分类「查看全部」二级页 —— 首页分类卡点「查看全部」/ 点卡片空白处进来。
 *
 * 与 Formulae 的 `BrewFormulaCategoryView` 一一对应（那是这页的孪生页）：
 *   标题栏（标题 + chips 行，chip 与标题共用同一块模糊材质）
 *     + Scroll(当前分类的卡，卡内是该分类的**全部**成员)
 * 本页正是改造前 Casks 首页的样子（chips 选分类 + 单分类卡片列表），
 * 现在它退到二级：首页只平铺分类卡，点进去才看某个分类的全部。
 *
 * 两处「这是二级页而不是页签根页」的差别：
 *   1. 进来时 chip 直接选中**用户点进来的那个分类**（路由参数 `categoryKey`），
 *      而不是像首页那样固定停在第一个；
 *   2. 不挂 `dynamicHideTitleBar` —— 那是页签根页「上滑收起标题行、只留 chips」的行为，
 *      本页随时可以返回，标题行一直留着更好认（详见 docs/hds-titlebar-blur.md 的嵌套注意项）。
 *
 * chip 栏直接复用 `BrewCategoryChipBar`（它本来就是「分类 -> chips」的映射，
 * 改造前挂在首页标题栏上），所以本页不需要再写一份 chips。
 */
@Component
export struct BrewCaskCategoryView {
  @StorageProp(StorageKey.GLOBAL_INFO) globalInfoModel: GlobalInfoModel =
    AppStorage.get(StorageKey.GLOBAL_INFO) ?? new GlobalInfoModel();
  @StorageProp(StorageKey.COLOR_MODE) systemColorMode: ConfigurationConstant.ColorMode =
    AppStorage.get(StorageKey.COLOR_MODE) ?? ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
  // 标题栏模糊共用 brewTitleBarStyle()（区间位置与长度只在 BrewTitleBar 里定义一次）
  @State titleBarStyle: TitleBarStyleOptions = brewTitleBarStyle('cask-category');
  /**
   * 返回键防重入。**必须是本组件的 @State**：放进共享 state 会跨页面复用、置位后不复位，
   * 表现为「第一次能返回、之后返回键全部失效」（详情页踩过，docs §10.4.1）。
   */
  @State backPressed: boolean = false;
  /** 每页实例一份 state（同 §10.4.1 的理由，不能挂在 VM 单例上） */
  @State categoryState: BrewCaskCategoryState = new BrewCaskCategoryState();
  /**
   * 当前选中的分类下标（chip 选中态 + 内容取哪个分类）。
   * **必须是组件自己的 @State**：理由与实测记录见 `BrewFormulaCategoryState` 顶部注释。
   */
  @State currentIndex: number = 0;
  viewModel: BrewCaskCategoryVM = BrewCaskCategoryVM.getInstance();
  private pathStack?: NavPathStack;

  private handleOnReady(ctx: NavDestinationContext): void {
    this.pathStack = ctx?.pathStack;
    const params: BrewCategoryParams = ctx?.pathInfo?.param as BrewCategoryParams;
    this.viewModel.load(params, this.categoryState).then((index: number) => {
      this.applyIndex(index);
    });
  }

  private reload(): void {
    this.viewModel.load({ categoryKey: this.categoryState.initialCategoryKey }, this.categoryState)
      .then((index: number) => {
        this.applyIndex(index);
      });
  }

  /**
   * 选中某个分类：**换数据源 + 写 currentIndex**（三处入口收敛到这里，避免各写一遍）。
   *
   * 数据源与选中态在同一个事件里连续写，ArkUI 只渲染一帧，所以不会出现
   * 「卡头已经换了、行还是上一个分类」的中间态。
   */
  private applyIndex(index: number): void {
    this.categoryState.itemSource.setDataArray(this.itemsOf(this.categoryState.categories[index]));
    // 选中态写回组件自己的 @State（VM 只算「该选哪个」）
    this.currentIndex = index;
  }

  /** 当前分类 */
  private currentCategory(): BrewCaskCategory | undefined {
    return this.categoryState.categories[this.currentIndex];
  }

  /**
   * 内容区的卡片：当前分类下的卡片。
   * 用数组而不是单张，是因为 Casks 的数据形状本来就是「分类 -> 卡片（列表）-> 条目」，
   * 哪天一个分类有多张卡，这里不用改（与改造前首页的 ForEach 结构一致）。
   */
  private currentCards(): BrewCaskCard[] {
    return this.currentCategory()?.caskCards ?? [];
  }

  /** 卡头取的那张卡（线上路径每个分类恒定一张） */
  private currentCard(): BrewCaskCard | undefined {
    return this.currentCards()[0];
  }

  /** 把该分类下所有卡片的条目拍平（`LazyForEach` 的数据源要一维数组） */
  private itemsOf(category: BrewCaskCategory | undefined): BrewPackageItem[] {
    let out: BrewPackageItem[] = [];
    (category?.caskCards ?? []).forEach((card: BrewCaskCard) => {
      out = out.concat(card.caskContents ?? []);
    });
    return out;
  }

  /** 点 chip 换分类：先回顶部，再换下标（下标是组件 @State，写入即刷新） */
  private selectCategory(index: number): void {
    if (index === this.currentIndex || index < 0 || index >= this.categoryState.categories.length) {
      return;
    }
    this.applyIndex(index);
    // 换完内容再回顶部：先回顶部会先滚一遍旧内容，白滚一趟
    this.viewModel.scrollToTop(this.categoryState);
  }

  /**
   * 分类 chips 挂在标题栏的 `bottomBuilder` 里（与样例页一致，chips 与标题共用同一块模糊材质），
   * 因此内容要让出「标题行 + chips 行」两段高度 —— 见下面的 `brewTitleBarTotalHeight()`。
   */
  @Builder
  ChipBarBuilder() {
    BrewCategoryChipBar({
      categories: this.categoryState.categories,
      currentIndex: this.currentIndex,
      handleCategoryClick: (index: number) => {
        this.selectCategory(index);
      },
    })
  }

  /**
   * 内容区：`List` + `LazyForEach`（虚拟滚动）。
   *
   * **为什么不能再用「首页那张卡 + previewLimit = 0」**（改动前的做法）：一个分类可以有上千个成员
   * （真机实测 Casks 的 systemtool 分类 2,877 行、Formulae 的 system 5,447 行），卡内 `ForEach`
   * 会把这上千行**一次性**构建出来。去掉 100 硬裁切之后这条路径才真正被走到 ——
   * 所以虚拟化是那次改动的配套，不是可选优化。
   *
   * 版式仍然是「一张卡」：让位与卡头各是一个 `ListItem`，成员行也是 `ListItem`，
   * 靠「同一底色 + 首项圆上角 / 末项圆下角」拼出卡的样子。让位按
   * `docs/hds-titlebar-blur.md` §2 的「`List`（无 banner）→ 首项空白 `ListItem`」；
   * 左右内缩同样写在**项**上（写容器 `padding` 会连带裁剪内容，到不了标题栏下面、模糊就白做了）。
   *
   * Casks 的数据是三层（分类 -> 卡片 -> 条目），但线上路径每个分类恒定**一张**卡
   * （`BrewBrowseBuilder.caskPage` 里 `category.caskCards = [card]`），所以卡头取第一张、
   * 成员是把该分类所有卡片的条目拍平 —— 真出现多卡也不会丢行。
   */
  /**
   * 内容区：`List` + `LazyForEach`（虚拟滚动）。
   *
   * **为什么不能再用「首页那张卡 + previewLimit = 0」**（改动前的做法）：一个分类可以有上千个成员
   * （真机实测 Casks 的 systemtool 分类 2,877 行），卡内 `ForEach` 会把这上千行**一次性**构建出来。
   * 去掉 100 硬裁切之后这条路径才真正被走到 —— 所以虚拟化是那次改动的配套，不是可选优化。
   *
   * 版式仍然是「一张卡」：让位与卡头各是一个 `ListItem`，成员行也是 `ListItem`，
   * 靠「同一底色 + 首项圆上角 / 末项圆下角」拼出卡的样子。
   *
   * **内缩的写法是真机试出来的，别再"简化"**：底色必须画在 `ListItem` 的**子节点**上，
   * `ListItem` 自己只负责 `padding` 内缩。两种更直觉的写法都实测失败：
   *   1. 底色 + `padding` 都写在 `ListItem` 上 → ArkUI 把背景铺满 border box（含 padding），
   *      内容缩了、白底仍贴到屏边；
   *   2. 底色 + `margin` 写在 `ListItem` 上 → margin 只把整项右移，内容溢出到右边框外。
   * 让位按 `docs/hds-titlebar-blur.md` §2 的「`List`（无 banner）→ 首项空白 `ListItem`」。
   */
  @Builder
  ContentBuilder() {
    List({ scroller: this.categoryState.scroller }) {
      // 顶部让位 = 标题行 + chips 行（与标题栏 `bottomBuilder.height` 同源）
      ListItem() {
        Row().height(brewTitleBarTotalHeight(this.globalInfoModel.statusBarHeight))
      }

      // 卡头（与首页分类卡共用同一个组件）
      ListItem() {
        Column() {
          BrewCategoryCardHeader({
            kind: BrewKind.CASK,
            categoryKey: this.currentCard()?.categoryKey ?? '',
            title: this.currentCard()?.title ?? '',
            itemCount: this.currentCard()?.itemCount ?? 0,
          })
          Divider()
            .strokeWidth('1px')
            .color($r('sys.color.comp_background_tertiary'))
            .margin({ bottom: $r('sys.float.padding_level2') })
        }
        .width(CommonConstants.FULL_PERCENT)
        .backgroundColor($r('sys.color.comp_background_list_card'))
        .borderRadius({
          topLeft: $r('sys.float.corner_radius_level8'),
          topRight: $r('sys.float.corner_radius_level8'),
        })
      }
      .padding({ left: this.contentLeft(), right: this.contentRight() })

      // 成员行：只有可视区附近的行会被构建
      LazyForEach(this.categoryState.itemSource, (item: BrewPackageItem, index: number) => {
        ListItem() {
          BrewPackageRow({ packageItem: item, kind: BrewKind.CASK })
            .onClick(() => {
              this.viewModel.jumpDetail(item);
            })
            .width(CommonConstants.FULL_PERCENT)
            .backgroundColor($r('sys.color.comp_background_list_card'))
            .borderRadius(index === this.categoryState.itemSource.totalCount() - 1 ? {
              bottomLeft: $r('sys.float.corner_radius_level8'),
              bottomRight: $r('sys.float.corner_radius_level8'),
            } : 0)
            // 与改动前的卡片收尾一致：最后一行之下留一点底色。
            // **`padding` 只能调一次** —— 它是整体覆盖，拆成两次会让前一次失效（`hds-titlebar-blur.md` §9.9）。
            .padding({
              bottom: index === this.categoryState.itemSource.totalCount() - 1 ?
                $r('sys.float.padding_level2') : 0,
            })
        }
        .padding({ left: this.contentLeft(), right: this.contentRight() })
      }, (item: BrewPackageItem) => item.id.toString())

      // 底部让位：导航条
      ListItem() {
        Row().height(this.globalInfoModel.naviIndicatorHeight)
      }
    }
    .width(CommonConstants.FULL_PERCENT)
    .height(CommonConstants.FULL_PERCENT)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
  }

  /** 左右边距与 Casks 首页 / Formulae 页共用同一份实现（brewcommon），几个页面的内容才对得齐 */
  private contentLeft(): Length {
    return brewPageContentLeft(this.globalInfoModel);
  }

  private contentRight(): Length {
    return brewPageContentRight(this.globalInfoModel);
  }

  build() {
    HdsNavDestination() {
      if (this.categoryState.loadingModel.loadingStatus === LoadingStatus.SUCCESS) {
        this.ContentBuilder()
      } else if (this.categoryState.loadingModel.loadingStatus === LoadingStatus.FAILED) {
        LoadingFailedView(this.globalInfoModel.widthBreakpoint, () => {
          this.reload();
        })
      } else if (this.categoryState.loadingModel.loadingStatus === LoadingStatus.NO_NETWORK) {
        NoNetworkView(this.globalInfoModel.widthBreakpoint, () => {
          this.reload();
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
        // 标题固定是「Casks」：分类身份由 chip 表达（卡头里还有一次分类名），
        // 与 Formulae 分类二级页「标题 = 页签名、分类交给 chips」同一口径。
        title: { mainTitle: $r('app.string.tab_casks') },
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
      if (this.backPressed) {
        return true;
      }
      this.backPressed = true;
      if (this.pathStack) {
        this.pathStack.pop();
        return true;
      }
      // 拿不到页面栈时不吞事件，交给系统默认出栈，而不是让返回键彻底失灵
      return false;
    })
  }
}

@Builder
export function BrewCaskCategoryBuilder() {
  BrewCaskCategoryView()
}
