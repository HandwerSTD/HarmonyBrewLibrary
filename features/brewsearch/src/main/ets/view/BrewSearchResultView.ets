/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { ConfigurationConstant } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { LengthMetrics } from '@kit.ArkUI';
import { HdsNavDestination } from '@kit.UIDesignKit';
import type { TitleBarStyleOptions } from '@kit.UIDesignKit';
import {
  BreakpointType,
  CommonConstants,
  GlobalInfoModel,
  Logger,
  PageContext,
  PageEnum,
  StorageKey,
  StatusBarColorType,
} from '@ohos/common';
import {
  BREW_CHIP_BAR_HEIGHT,
  BrewChipBar,
  BrewKind,
  BrewPackageRow,
  brewTitleBarStyle,
  brewTitleBarTotalHeight,
} from '@ohos/brewcommon';
import type { BrewDetailParams } from '@ohos/brewcommon';
// BrewPackageItem 是值导出（AI 答案行要 new 它）。
import { BrewPackageItem, AiSettingsStore } from '@ohos/brewcommon';
import { BrewSearchRow, BrewSearchRowSource } from '../model/BrewSearchRowSource';
import { BrewAiSearchExamples } from '../component/BrewAiSearchExamples';
import { BrewAiSearchAnswerView } from '../component/BrewAiSearchAnswerView';
import { BrewAiSearchSkeleton } from '../component/BrewAiSearchSkeleton';
import { BrewAiSearchErrorCard } from '../component/BrewAiSearchErrorCard';
import { AiAskState, AiFindVM } from '../viewmodel/AiFindVM';
import { BrewSearchState } from '../viewmodel/BrewSearchState';
import { BrewSearchVM } from '../viewmodel/BrewSearchVM';
import { BrewSearchSuggestions } from '../component/BrewSearchSuggestions';
import { BrewSearchBar } from '../component/BrewSearchBar';
import {
  BREW_SEARCH_BAR_ROW_HEIGHT,
  BREW_SEARCH_CHIP_ROW_GAP,
  BREW_SEARCH_SPACE_LEVEL8,
  BREW_SEARCH_SPACE_LEVEL12,
  BREW_SEARCH_SPACE_LEVEL16,
} from '../constant/BrewSearchConstants';

const TAG: string = '[BrewSearch]';

/**
 * 搜索页（搜索页签的栈底页）。
 *
 * 结构 = 模糊标题栏（**输入框行 + chips 行都挂在 `bottomBuilder` 上**）+ 滚动根占满窗口、
 * 让位写成首末两个占位 `ListItem` 的 `List`（见 `ResultListBuilder`）；未提交态与无命中两种状态
 * 换成同样占满窗口的 `Scroll`（见 `NoRowsScrollBuilder`）。
 *
 * 本页特有的点：
 *   1. **每页实例状态**：`state` 与 `keyword` 都在本页（不从单例 VM / AppStorage 取）。
 *      共享状态会让页面先渲染出上一次的结果（详情页正是这么踩的：handover §10.4.1）。
 *   2. **输入框在标题栏里**（`BrewSearchBar`）：它是本页唯一的搜索入口，而且**显式触发**
 *      （回车 / 点「搜索」/ 点历史与发现项）。输入框里的词还没被执行时下方显示历史与发现，
 *      执行后才换成结果列表 —— 两者的区别就是 `appliedKeyword`。
 *   3. **历史是真的**：每次真正执行搜索（`apply`）就把词交给 `BrewSearchVM` 落盘，
 *      与输入框的变化无关（打字打一半的 `nod` 不进历史）。
 *   4. **返回键**：栈顶有详情页就弹它；否则有字就清空回到历史/发现；否则**不吞**，
 *      交回 `PcMainPage`（与其它页签一致）。
 *
 * ## AI 问答模式（2026-11-26-ai-search-ask-spec §3/§4）
 *
 * 搜索框内的 AI pill 切换 `aiEnabled`（`AiSettingsStore` 持久化，重启保持）。on 态提交走
 * `applyAi`（LLM 问答，`AiAskState.kind` 分流混排答案/骨架/错误卡/降级通知条）；off 态
 * 提交走 `apply`（本地搜索链路零改动，G8）。降级矩阵：E1/E2/E3 自动本地 + 通知条；
 * E4/E5 错误卡（重试/用本地搜索）。AI 模式下 chips 行隐藏（titleBar `bottomBuilder`
 * 高度与 `topInset()` 同步收缩——三处同源常量由 `chipsRowVisible()` 统一判定）。
 */
@Component({ freezeWhenInactive: true })
export struct BrewSearchResultView {
  @StorageProp(StorageKey.GLOBAL_INFO) globalInfoModel: GlobalInfoModel =
    AppStorage.get(StorageKey.GLOBAL_INFO) ?? new GlobalInfoModel();
  @StorageProp(StorageKey.COLOR_MODE) systemColorMode: ConfigurationConstant.ColorMode =
    AppStorage.get(StorageKey.COLOR_MODE) ?? ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
  /**
   * 关键字。**本页是唯一写者**（输入框通过 `onInput` 上报、建议词直接填入）——
   * 不再走 AppStorage：原先侧边栏搜索框与结果页分居两层，才需要共享一个键，
   * 而那个共享也是「框里显示旧词、回车把旧词发回去」这类缺陷的温床。
   */
  @State keyword: string = '';
  /**
   * **已生效**的关键字 = 上一次真正执行搜索时输入框里的值。
   *
   * 搜索是显式触发的（回车 / 点「搜索」/ 点历史与发现项），所以「框里有字」不等于「有结果」：
   * `keyword` 是输入框的内容，`appliedKeyword` 是「内容区现在显示的是谁的结果」。
   * 两者（trim 后）不一致 = 还没搜 —— 内容区显示历史/发现，而不是上一次的旧结果
   * （旧行为是防抖自动搜，打字到一半内容区就换一批结果，用户还没确认关键字就一直在跑全量匹配）。
   */
  @State appliedKeyword: string = '';
  @State titleBarStyle: TitleBarStyleOptions = brewTitleBarStyle('search');
  @State state: BrewSearchState = new BrewSearchState();
  @State rowSource: BrewSearchRowSource = new BrewSearchRowSource();
  /**
   * AI 问答模式开关（spec §3）。**初值来自持久化**（AiSettingsStore.aiSearch，重启保持，G2），
   * 切换由 pill 上报 → `toggleAi()` 落盘 + 处理态迁移。`@State` 是为了 pill/hint 即时换肤。
   */
  @State aiEnabled: boolean = AiSettingsStore.aiSearch();
  /** AI 问答的状态机（spec §4.6：loading → answer/empty/error/fallback）。 */
  @State aiAsk: AiAskState = new AiAskState();
  /** E1/E2/E3 降级时页面是否显示通知条（可点击关闭；spec §4.5） */
  @State aiFallbackNoticeVisible: boolean = false;
  /**
   * 防重入旗：只护「弹出栈顶详情页」那一支（连点不能把上一页也弹掉）。
   * 栈底那两支不设旗（清空关键字与交回上层都不需要防重入）。**必须是本组件的 @State**
   * （放共享 state 会置位后不复位，handover §10.4.1）。
   */
  @State backPressed: boolean = false;
  private viewModel: BrewSearchVM = BrewSearchVM.getInstance();
  private aiFinder: AiFindVM = AiFindVM.getInstance();
  /**
   * 本页的页面栈，一律走**搜索壳自己持有的** `PageContext`（`@ohos/common`）。
   *
   * 不用 `NavDestinationContext.pathStack`（`handleOnReady` 的第二个入参）：真机实测那个对象上
   * `size` 不是函数（见 `apply` 的注释），而本页需要的三种操作（回栈底 / 压详情页 / 弹栈顶）
   * 在 `PageContext` 里都是**已被证明可用**的路径（`BaseHomeViewModel.ets:142` 就在跑同一个
   * `PageContext.navPathStack.size()`）；它还每个方法都包了 try/catch + 日志，API 不可用时降级而不是崩页面。
   * 两个对象指向的是同一个 `NavPathStack`（搜索壳把它直接传给了 `HdsNavigation`），不是两个栈。
   */
  @StorageLink(StorageKey.BREW_SEARCH_PAGE_CONTEXT) searchPageContext: PageContext =
    AppStorage.get<PageContext>(StorageKey.BREW_SEARCH_PAGE_CONTEXT) ?? new PageContext();

  handleOnReady(): void {
    this.apply(this.keyword);
  }

  /**
   * 输入框每次输入：**只更新输入框内容，不搜索**。
   *
   * 搜索改为显式触发（需求方口径：回车 / 点「搜索」才搜），所以这里没有防抖定时器，
   * 也不该有 —— 没有「挂起的超时」就少一个「旧结果后到把新结果盖掉」的来源。
   */
  onInput(value: string): void {
    this.keyword = value;
  }

  /** 回车 / 点「搜索」：执行一次搜索，并把输入框里的值记为「已生效」 */
  searchNow(): void {
    this.appliedKeyword = this.keyword;
    if (this.aiEnabled) {
      this.applyAi(this.keyword);
    } else {
      this.apply(this.keyword);
    }
  }

  /**
   * 点历史/发现里的词：填进输入框并**立刻**搜（等同于用户按了回车）。
   *
   * 两个入口都只做「赋值 + 走 `searchNow`」：关键字只有本页一个写者，
   * 不需要「值是不是我自己刚设的」那类判断。AI 模式下示例 chips 也走这里（= 填入即问）。
   */
  pickWord(word: string): void {
    this.keyword = word;
    this.searchNow();
  }

  /** AI pill 切换：落盘 + 态迁移（spec §4.6 状态机图）。 */
  toggleAi(): void {
    const next: boolean = !this.aiEnabled;
    this.aiEnabled = next;
    AiSettingsStore.saveAiSearch(next);
    Logger.info(TAG, `ai search toggled enabled=${next}`);
    if (next) {
      // on：hint/图标已由 @Prop 换肤；若内容区正显示普通结果且词已生效，不自动改写
      // —— 用户下一次提交才走 AI（保持「显式触发」纪律）。AI 状态机复位到 idle。
      this.aiAsk = new AiAskState();
      this.aiFallbackNoticeVisible = false;
    } else {
      // off：AI 状态清场；若内容区是 AI 答案（词已生效），重跑本地搜索拿回普通结果。
      this.aiAsk = new AiAskState();
      this.aiFallbackNoticeVisible = false;
      if (this.appliedKeyword.trim().length > 0 && this.keyword.trim() === this.appliedKeyword.trim()) {
        this.apply(this.appliedKeyword);
      }
    }
  }

  /**
   * AI 问答提交（spec §3）：栈底化 + 历史照记（历史是「我用过的词」，问 AI 也算），
   * 然后走 `AiFindVM.ask`。结果回来按 kind 分流渲染；E1/E2/E3 的 fallback 态**不在这里**
   * 调 `apply` —— 本地结果由 fallback 分支渲染时再算（用户看到的还是「问了一次 AI」）。
   */
  private applyAi(keyword: string): void {
    this.searchPageContext.popPageByIndex(0, false);
    this.viewModel.recordSearch(keyword);
    this.state.keyword = keyword;
    this.aiFallbackNoticeVisible = false;
    this.aiFinder.ask(keyword, this.aiAsk)
      .then((outcome) => {
        // 陈旧守卫：undefined = 结果被丢弃（新提交已接管），什么都不做
        if (outcome === undefined) {
          return;
        }
        if (outcome.kind === 'fallback') {
          // E1/E2/E3 → 通知条 + 本地搜索结果（G6：不引导配 Key）
          this.aiFallbackNoticeVisible = true;
          this.runLocalSearch(this.keyword);
        }
        // 'answer' / 'error' / 'empty' 状态已写进 this.aiAsk，渲染分支直接消费
      })
      .catch((error: BusinessError) => {
        Logger.error(TAG, `ai ask failed, code=${error?.code}, msg=${error?.message}`);
      });
  }

  /** fallback 态的本地搜索：只算结果不写历史（applyAi 已记过）。 */
  private runLocalSearch(keyword: string): void {
    this.viewModel.search(keyword, this.state)
      .then((rows: BrewSearchRow[] | undefined) => {
        if (rows !== undefined) {
          this.rowSource.setDataArray(rows);
        }
      })
      .catch((error: BusinessError) => {
        Logger.error(TAG, `local search failed, code=${error?.code}, msg=${error?.message}`);
      });
  }

  /**
   * 栈顶是否叠着详情页（决定返回键是「弹详情页」还是「清空关键字 / 交回上层」）。
   *
   * 单独抽成方法、并且包 try/catch：栈深是**唯一一处还依赖 `size()` 的判断**，而 `size()` 在
   * 真机上已被证明可能不可用（原崩溃点见 `apply` 的注释）。拿不到栈深就按「栈底」处理。
   */
  private hasDetailOnTop(): boolean {
    try {
      return this.searchPageContext.navPathStack.size() > 1;
    } catch (error) {
      // 真机实测：NavDestinationContext 给的栈对象上 size 不是函数（undefined is not callable）。
      // 这里再兜一层：拿不到栈深就按「栈底」处理（退出搜索态），绝不因此崩页面。
      Logger.error(TAG, `stack size unavailable, treat as bottom: ${error?.message}`);
      return false;
    }
  }

  /**
   * 用新关键字重算。**新关键字不 push 新页面**：先把栈回到栈底
   * （可能正叠着详情页）再换数据 —— 否则连输会堆一叠结果页。
   */
  private apply(keyword: string): void {
    // 回栈底**无条件调用**，不先问栈深：栈里只有结果页一个条目时 `popToIndex(0)` 本身就是
    // 空操作，所以这里不需要 `size()` 守卫。这个守卫原来是崩溃点 —— 在 `NavDestinationContext`
    // 给的栈对象上调 `size()` 报 `undefined is not callable`（见 `hasDetailOnTop` 的兜底）。
    // 走 `PageContext.popPageByIndex`：它与 `BaseHomeViewModel.ets:142` 里那个能用的 `size()` 是同一个对象。
    this.searchPageContext.popPageByIndex(0, false);
    // 历史在**这里**写：`apply` 就是「真正执行了一次搜索」，空关键字会被 `recordSearch` 拦掉
    // （所以返回键的清空与 `handleOnReady` 的空关键字都不会污染历史）。
    // 不等结果回来就记：历史是「我用过的词」，0 结果也算用过。
    this.viewModel.recordSearch(keyword);
    this.state.keyword = keyword;
    this.viewModel.search(keyword, this.state)
      .then((rows: BrewSearchRow[] | undefined) => {
        if (rows !== undefined) {
          this.rowSource.setDataArray(rows);
        }
      })
      .catch((error: BusinessError) => {
        Logger.error(TAG, `search failed, code=${error?.code}, msg=${error?.message}`);
      });
  }

  /**
   * 本页内容的左右内缩（vp 数值）。
   *
   * 返回**数字**而不是资源型 `Length`：标题栏的 `padding` 只吃 `LengthMetrics`，
   * 而标题「搜索」必须与下面的输入框/chips/分区标题同一条竖线（否则看着就是“没对齐”）。
   * 两边共用这一个方法 → 同一条竖线是结构上保证的，不是两处数字碰巧相等。
   */
  private contentInset(): number {
    return new BreakpointType<number>({
      sm: BREW_SEARCH_SPACE_LEVEL8,
      md: BREW_SEARCH_SPACE_LEVEL12,
      lg: BREW_SEARCH_SPACE_LEVEL16,
    }).getValue(this.globalInfoModel.widthBreakpoint);
  }

  /**
   * AI 模式下 chips 行是否可见（spec §4.1：AI 答案没有 kind 过滤语境，chips 整行隐藏）。
   *
   * **三处同源**（titleBar `bottomBuilder.height` / `TitleBarBottomBuilder` / `topInset()`）
   * 都由这个判定给出：差一档就会出现「chips 盖住内容」或「内容上方多一条空白」。
   */
  private chipsRowVisible(): boolean {
    return !this.aiEnabled;
  }

  /** titleBar bottomBuilder 的高度（chips 行可见与否两档，与 topInset 同源）。 */
  private bottomBuilderHeight(): number {
    const chips: number = this.chipsRowVisible() ? BREW_CHIP_BAR_HEIGHT : 0;
    return chips + BREW_SEARCH_BAR_ROW_HEIGHT + BREW_SEARCH_CHIP_ROW_GAP;
  }

  /**
   * 顶部让位的高度：标题行 + **输入框行** + （chips 行 + **chips 下方留白**，AI 模式隐藏）。
   *
   * 输入框与 chips 都挂在标题栏的 `bottomBuilder` 上（它是浮层，不会把内容顶下去），
   * 所以这里的值必须与 `bottomBuilder.height` 同源 —— 差一档就会出现
   * 「输入框盖住 chips」或「内容上方多一条空白」。模糊区间不受影响：
   * `brewBlurScrollEffect` 用的是固定的 `BREW_TITLEBAR_BLUR_RAMP`（start=0），与标题栏高度无关。
   */
  private topInset(): number {
    const chips: number = this.chipsRowVisible() ? BREW_CHIP_BAR_HEIGHT + BREW_SEARCH_CHIP_ROW_GAP : 0;
    return brewTitleBarTotalHeight(this.globalInfoModel.statusBarHeight) +
      BREW_SEARCH_BAR_ROW_HEIGHT + chips;
  }

  /** 底部让位的高度：导航条 + `SPACE_24`（与「我的-本机包」、包详情页同口径） */
  private bottomInset(): number {
    return this.globalInfoModel.naviIndicatorHeight + CommonConstants.SPACE_24;
  }

  /**
   * 内容区是否显示「历史/发现」：**输入框里的词还没被执行过**。
   *
   * 两种情形：① 从没搜过（`appliedKeyword` 为空）；② 打完上一次搜索后又改了字（两者不一致）。
   * 比较用 `trim()`：多敲一个空格不该让内容区从结果跳回发现。
   */
  private showingSuggestions(): boolean {
    const typed: string = this.keyword.trim();
    const applied: string = this.appliedKeyword.trim();
    return applied.length === 0 || typed !== applied;
  }

  /** AI 问答内容是否正在前台（提交后词已生效且 AI 态非 idle）。 */
  private showingAiContent(): boolean {
    return this.aiEnabled && !this.showingSuggestions() && this.aiAsk.kind !== 'idle';
  }

  private openDetail(row: BrewSearchRow): void {
    const item: BrewPackageItem = row.item;
    this.searchPageContext.openPage({
      routerName: PageEnum.BREW_DETAIL_VIEW,
      param: {
        kind: row.kind,
        title: item.subTitle,
        id: item.id,
        token: item.token,
        categoryKey: item.categoryKey,
      } as BrewDetailParams,
    }, true);
  }

  /**
   * AI 答案行 → 详情页（spec §4.4：与普通搜索行同一链路）。kind 由目录索引判定
   * （AnswerView 的 rowOf 已折算成 BrewKind，这里回传字符串保持 openDetail 的 param 口径）。
   */
  private openAiAnswerDetail(token: string, kind: string): void {
    const kindValue: BrewKind = kind === 'cask' ? BrewKind.CASK : BrewKind.FORMULA;
    this.searchPageContext.openPage({
      routerName: PageEnum.BREW_DETAIL_VIEW,
      param: {
        kind: kindValue,
        title: token,
        id: 0,
        token: token,
        categoryKey: '',
      } as BrewDetailParams,
    }, true);
  }

  /**
   * 输入框行（标题栏 `bottomBuilder` 的第一行）。
   *
   * **内缩写在包一层的 `Row` 的 `padding` 上**，不是写在 `BrewSearchBar` 上：
   * 那个 Row 的 `backgroundColor` 就是可见的圆角框，往它自己身上加 padding 只会把框撑满整宽
   * （“搜索框贴边”就是这个原因）；而“`width('100%')` + `margin`”也不行 —— margin 不算在 100% 里，
   * 元素会溢出而不是内缩。父级 `padding` 是唯一正确的一处（子级 100% 按父级**内容盒**解析，
   * 与页内 `NoRowsScrollBuilder` 的写法一致）。
   *
   * 只包住输入框行、**不包 chips**：`BrewChipBar` 自带 `barPadding()`，再套一层就是双份内缩。
   */
  @Builder
  SearchBarBuilder() {
    Row() {
      BrewSearchBar({
        keyword: this.keyword,
        aiEnabled: this.aiEnabled,
        onInput: (value: string) => {
          this.onInput(value);
        },
        onSearch: () => {
          this.searchNow();
        },
        onToggleAi: () => {
          this.toggleAi();
        },
      })
    }
    .width(CommonConstants.FULL_PERCENT)
    .padding({ left: this.contentInset(), right: this.contentInset() })
  }

  /**
   * 标题栏底部区：输入框行 + chips 行，上下各一档留白。
   *
   * **必须抽成 `@Builder` 方法**，不能把 `Column() { ... }.width(...)` 直接写在 `builder:` 的箭头函数里：
   * 那样 eTS 解析器会在容器组件块之后的换行链式调用（`.width`）上报 `Rollup Error: Unexpected token`，
   * 连带报出一堆无关的 ArkTS 错（对象字面量无类型、`this` 不在函数内……）。
   *
   * 上下两档留白必须与 `bottomBuilder.height` / `topInset()` 的数学一致（见常量注释）：
   * 这里量到多少、那里就得算多少 —— 不一致要么让内容钻到标题栏底下，要么在下方多一条空白。
   *
   * AI 模式：chips 行不渲染（`chipsRowVisible()` 三处同源判定之一）。
   */
  @Builder
  TitleBarBottomBuilder() {
    Column() {
      this.SearchBarBuilder();
      if (this.chipsRowVisible()) {
        this.ChipBarBuilder();
      }
    }
    .width(CommonConstants.FULL_PERCENT)
    .padding({
      top: BREW_SEARCH_SPACE_LEVEL8,
      bottom: BREW_SEARCH_CHIP_ROW_GAP,
    })
  }

  @Builder
  ChipBarBuilder() {
    BrewChipBar({
      chips: this.viewModel.chips(),
      currentIndex: this.state.filterIndex,
      handleChipClick: (index: number) => {
        this.state.filterIndex = index;
        this.rowSource.setDataArray(this.viewModel.rowsOf(this.state));
      },
    })
  }

  /** 索引未就绪的提示条（不是失败态：仍按包名搜出了结果） */
  @Builder
  IndexPendingBuilder() {
    Text($r('app.string.brew_search_index_pending'))
      .fontSize($r('sys.float.Body_S'))
      .fontColor($r('sys.color.font_tertiary'))
      .width(CommonConstants.FULL_PERCENT)
      .padding({ bottom: $r('sys.float.padding_level4') })
  }

  /**
   * E1/E2/E3 降级通知条（spec §4.5）：可点击关闭；文案按 fallbackNoKey 分流。
   */
  @Builder
  AiFallbackNoticeBuilder() {
    if (this.aiFallbackNoticeVisible) {
      Row({ space: $r('sys.float.padding_level2') }) {
        SymbolGlyph($r('sys.symbol.lightbulb'))
          .fontSize($r('sys.float.Body_S'))
          .fontColor([$r('sys.color.icon_secondary')])
        Text(this.aiAsk.fallbackNoKey ? $r('app.string.ai_search_fallback_no_key')
          : $r('app.string.ai_search_fallback_notice'))
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text('×')
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_tertiary'))
          .onClick(() => {
            this.aiFallbackNoticeVisible = false;
          })
      }
      .width(CommonConstants.FULL_PERCENT)
      .height(36)
      .alignItems(VerticalAlign.Center)
      .padding({
        left: $r('sys.float.padding_level6'),
        right: $r('sys.float.padding_level6'),
      })
      .backgroundColor($r('sys.color.comp_background_tertiary'))
      .borderRadius($r('sys.float.corner_radius_level4'))
      .margin({ bottom: $r('sys.float.padding_level4') })
    }
  }

  /**
   * AI 问答内容区（spec §4.3/4.4/4.5）：按 `AiAskState.kind` 分流。
   *
   * 与 `ResultListBuilder` 同一理由：`Scroll` 是滚动根、占满整个窗口，让位写成内层
   * `Column` 的 `margin`，内缩写在**内层内容**上（容器 padding 会把内容裁掉、模糊失效）。
   */
  @Builder
  AiContentBuilder() {
    Scroll() {
      Column() {
        this.AiFallbackNoticeBuilder();
        if (this.aiAsk.kind === 'loading') {
          BrewAiSearchSkeleton()
        } else if (this.aiAsk.kind === 'answer' && this.aiAsk.answer !== null) {
          BrewAiSearchAnswerView({
            answer: this.aiAsk.answer,
            handleRowClick: (token: string, kind: string) => {
              this.openAiAnswerDetail(token, kind);
            },
          })
        } else if (this.aiAsk.kind === 'error') {
          BrewAiSearchErrorCard({
            errorDetail: this.aiAsk.errorDetail,
            handleRetry: () => {
              this.applyAi(this.keyword);
            },
            handleUseLocal: () => {
              this.aiFallbackNoticeVisible = true;
              this.runLocalSearch(this.appliedKeyword);
            },
          })
        } else if (this.aiAsk.kind === 'empty') {
          Text($r('app.string.ai_search_empty'))
            .fontSize($r('sys.float.Body_M'))
            .fontColor($r('sys.color.font_tertiary'))
            .width(CommonConstants.FULL_PERCENT)
            .textAlign(TextAlign.Center)
            .padding({ top: $r('sys.float.padding_level16') })
        } else if (this.aiAsk.kind === 'fallback') {
          // fallback：通知条（已渲染）+ 本地结果行（复用 ResultListBuilder 的行形态，
          // 但这里直接给 List 也行——本地结果是全量列表，走 List 的 LazyForEach 性能更好）
          this.FallbackRowsBuilder()
        }
      }
      .width(CommonConstants.FULL_PERCENT)
      .margin({ top: this.topInset(), bottom: this.bottomInset() })
      .padding({ left: this.contentInset(), right: this.contentInset() })
    }
    .width(CommonConstants.FULL_PERCENT)
    .height(CommonConstants.FULL_PERCENT)
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
  }

  /** fallback 态的本地结果行（嵌在 AI 内容区的 Scroll 里）。 */
  @Builder
  FallbackRowsBuilder() {
    Column() {
      if (this.state.total === 0) {
        Text($r('app.string.brew_search_no_result'))
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('sys.color.font_tertiary'))
          .width(CommonConstants.FULL_PERCENT)
          .textAlign(TextAlign.Center)
          .padding({ top: $r('sys.float.padding_level16') })
      } else {
        ForEach(this.rowSource.all(), (row: BrewSearchRow, index: number) => {
          BrewPackageRow({
            packageItem: row.item,
            kind: row.kind,
            hideRank: true,
            itemHeight: $r('app.float.brew_search_row_height'),
          })
            .onClick(() => {
              this.openDetail(row);
            })
            .width(CommonConstants.FULL_PERCENT)
            .backgroundColor($r('sys.color.comp_background_list_card'))
            .borderRadius($r('sys.float.corner_radius_level8'))
            .margin({ bottom: $r('sys.float.padding_level2') })
        }, (row: BrewSearchRow) => `${row.kind}_${row.item.token}`)
      }
    }
    .width(CommonConstants.FULL_PERCENT)
  }

  /**
   * 有命中时的内容区：`List` 就是**整页的滚动根**（`.height(FULL_PERCENT)`）。
   *
   * **绝对不能**再写成「一个 `height(100%)` + `margin.top(T)` 的容器 + 里面的 `List`」：
   * 百分比高度是按父容器的**内容盒**解析、且不算节点自己的 `margin`，那个容器实际占据
   * `[T, T + H]`，而父容器在 `H` 就结束了 —— 底部 `T`（这里是 112vp）被推到窗口外，
   * 列表最后约 `T / 行高` 行**永远滚不到底**。更糟的是，让位由外层容器承担时 `List` 的视口
   * 整体落在标题栏下方，任何内容都钻不到标题栏底下，而标题栏模糊**正是靠内容透上来**才有效果
   * ——区间配得再对也只是一块装饰背板（`docs/hds-titlebar-blur.md` §5 坑 3「模糊形同虚设」）。
   *
   * 所以让位一律写成**内容里的占位项**（`hds-titlebar-blur.md` §2）：
   * 顶部 = 首项空白 `ListItem`，底部 = 末项空白 `ListItem`；`List` 自己不加 `padding`
   * （滚动容器上的 `padding` 参与裁剪，同样会把内容挡在标题栏之外）。
   * 左右内缩写在**项**上，同理。
   */
  @Builder
  ResultListBuilder() {
    List() {
      // 顶部让位 = 标题行 + chips 行
      ListItem() {
        Row().height(this.topInset())
      }

      // 索引未就绪的提示条。做成独立 `ListItem`，跟着内容一起滚走，不占视口
      if (!this.state.indexReady) {
        ListItem() {
          this.IndexPendingBuilder();
        }
        .padding({ left: this.contentInset(), right: this.contentInset() })
      }

      // 「共 N 个结果」（不是卡片的一部分，所以不画底色，与改动前一致）
      ListItem() {
        Text($r('app.string.brew_search_result_count', this.state.total))
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_tertiary'))
          .width(CommonConstants.FULL_PERCENT)
          .padding({ bottom: $r('sys.float.padding_level4') })
      }
      .padding({ left: this.contentInset(), right: this.contentInset() })

      // 结果行：只有可视区附近的行会被构建
      LazyForEach(this.rowSource, (row: BrewSearchRow, index: number) => {
        ListItem() {
          BrewPackageRow({
            packageItem: row.item,
            kind: row.kind,
            // 搜索结果没有「分类内名次」语境；不隐藏的话每行都会是 "0 / 0"
            hideRank: true,
            itemHeight: $r('app.float.brew_search_row_height'),
          })
            // 点击必须用 `.onClick()` 挂在组件调用上 —— 这是本项目 6 处 BrewPackageRow 调用点的
            // 统一写法（Formulae 分类页/分类卡、Casks 分类页/分类卡、详情页「同分类其他包」、本处）。
            // 曾经写成 `handleItemClick: () => …` 参数：`BrewPackageRow` 虽然声明了该成员，
            // 却从未把它转发给 `HdsListItemCard` 的 `onClick`，于是回调被**静默丢弃**、
            // 行根本点不动（无编译错误、无运行时报错）。详见 `BrewPackageRow` 里删除该参数时的注释。
            .onClick(() => {
              this.openDetail(row);
            })
            .width(CommonConstants.FULL_PERCENT)
            // 底色画在 `ListItem` 的**子节点**上，`ListItem` 自己只负责内缩。两种更直觉的写法都
            // 实测失败（`BrewFormulaCategoryView` 的注释）：底色写 `ListItem` 上会铺满 border box
            // （含 padding），白底仍贴到屏边；写 `margin` 只把整项右移、内容溢出到边框外。
            // 首项圆上角 / 末项圆下角拼出「一张卡」；只有一行时四个角都是圆的。
            .backgroundColor($r('sys.color.comp_background_primary'))
            .borderRadius({
              topLeft: index === 0 ? $r('sys.float.corner_radius_level8') : 0,
              topRight: index === 0 ? $r('sys.float.corner_radius_level8') : 0,
              bottomLeft: index === this.rowSource.totalCount() - 1 ?
                $r('sys.float.corner_radius_level8') : 0,
              bottomRight: index === this.rowSource.totalCount() - 1 ?
                $r('sys.float.corner_radius_level8') : 0,
            })
        }
        .padding({ left: this.contentInset(), right: this.contentInset() })
      }, (row: BrewSearchRow) => `${row.kind}_${row.item.token}`)

      // 底部让位：导航条 + 余量。有了它，最后一行才不会贴在窗口下沿（也就说“滚得到底”）
      ListItem() {
        Row().height(this.bottomInset())
      }
    }
    .width(CommonConstants.FULL_PERCENT)
    .height(CommonConstants.FULL_PERCENT)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
  }

  /**
   * 「没有结果行可滚」的两种状态共用这一份 `Scroll`：空关键字（历史 / 发现）与无命中。
   *
   * 与列表态同一个理由（见 `ResultListBuilder`）：`Scroll` 是滚动根、占满整个窗口，
   * 让位写成**内层 `Column` 的 `margin`**，内缩也写在**内层内容**上 —— 容器 `padding`
   * 会把内容裁剪掉（内容到不了标题栏下面，模糊失效），容器 `margin` 会把整块推出窗口。
   * 顺带把「窗口很矮时历史/发现被裁掉」也治了：内容一超高就能滚。
   * 这一份与「我的-本机包」`MinePackagesView` 的写法同款。
   *
   * AI 模式（spec §4.2）：贴片退役后，示例区挂在历史/发现**之前**；AI off 时示例区
   * 不渲染，本 builder 与改前逐字节一致（G8）。
   */
  @Builder
  NoRowsScrollBuilder() {
    Scroll() {
      Column() {
        if (!this.state.indexReady && !this.showingSuggestions()) {
          this.IndexPendingBuilder();
        }
        if (this.showingSuggestions()) {
          if (this.aiEnabled) {
            BrewAiSearchExamples({
              onPickExample: (query: string) => {
                this.pickWord(query);
              },
            })
              .margin({ bottom: $r('sys.float.padding_level8') })
          }
          BrewSearchSuggestions({
            pickWord: (word: string) => {
              // 关键字只有本页一个写者：直接填入并立刻搜（AI 模式=填入即问）
              this.pickWord(word);
            },
          })
        } else {
          Text($r('app.string.brew_search_no_result'))
            .fontSize($r('sys.float.Body_M'))
            .fontColor($r('sys.color.font_tertiary'))
            .width(CommonConstants.FULL_PERCENT)
            .textAlign(TextAlign.Center)
            .padding({ top: $r('sys.float.padding_level16') })
        }
      }
      .width(CommonConstants.FULL_PERCENT)
      .margin({ top: this.topInset(), bottom: this.bottomInset() })
      .padding({ left: this.contentInset(), right: this.contentInset() })
    }
    .width(CommonConstants.FULL_PERCENT)
    .height(CommonConstants.FULL_PERCENT)
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
  }

  @Builder
  ContentBuilder() {
    if (this.showingAiContent()) {
      this.AiContentBuilder();
    } else if (this.showingSuggestions() || this.state.total === 0) {
      this.NoRowsScrollBuilder();
    } else {
      this.ResultListBuilder();
    }
  }

  build() {
    HdsNavDestination() {
      this.ContentBuilder()
    }
    // 栈底页：没有上一页可回，与同类栈底页 `BrewDiscoverListView` 一致地藏掉返回按钮
    .hideBackButton(true)
    .backgroundColor($r('sys.color.background_secondary'))
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .titleBar({
      // 与内容同一条竖线（实测：标题原本用 SPACE_16=16vp，而内容在 lg 档是 24vp，
      // 差 8vp 看着就是“标题没对齐”—— 需求方一眼就看出来了）
      padding: {
        start: LengthMetrics.vp(this.contentInset()),
        end: LengthMetrics.vp(this.contentInset()),
      },
      avoidLayoutSafeArea: true,
      style: this.titleBarStyle,
      content: {
        title: {
          // 标题是静态的：关键字改由下面的输入框自己显示（重复显示一遍没有意义）
          mainTitle: $r('app.string.brew_search_title'),
        },
        bottomBuilder: {
          builder: () => {
            this.TitleBarBottomBuilder();
          },
          // 输入框行 +（chips 行 + chips 下方留白）：AI 模式 chips 行隐藏（与 topInset 同源）
          height: this.bottomBuilderHeight(),
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
    .onReady(() => this.handleOnReady())
    .onBackPressed(() => {
      if (this.hasDetailOnTop()) {
        // 弹出的是**栈顶的详情页**，本页仍然活着 —— 所以旗子只能护这一支。
        // 若像别的页那样在入口就置位，`backPressed` 会一直粘住（本页不是被弹走的那个），
        // 之后再在栈底按返回会被它直接吞掉：返回键“只生效一次，然后永远没反应”，
        // 不报错、无日志。
        if (this.backPressed) {
          return true;
        }
        this.backPressed = true;
        this.searchPageContext.popPage();
        return true;
      }
      // 栈底（本页就是搜索页签的首页）：
      //   有字 → 清空回到「历史/发现」并吞掉（搜索页最自然的「退一步」）；
      //   没字 → **不吞**，return false 交回 `PcMainPage`（与其它页签一致：再按一次退出应用）。
      // 这里**不能**再像搜索态时期那样无条件吞掉：那时「返回」的语义是「退出搜索」，
      // 现在搜索是一个普通页签，吞掉会让返回键在本页变成死键。
      if (this.keyword.length > 0 || this.appliedKeyword.length > 0) {
        // 清空输入框 + 撤掉「已生效」的关键字：内容区回到历史/发现（`apply('')` 空关键字不写历史）；
        // AI 状态机一并复位（answer/骨架/错误卡不残留）
        this.keyword = '';
        this.appliedKeyword = '';
        this.aiAsk = new AiAskState();
        this.aiFallbackNoticeVisible = false;
        this.apply('');
        return true;
      }
      return false;
    })
  }
}

@Builder
export function BrewSearchResultBuilder() {
  BrewSearchResultView()
}
