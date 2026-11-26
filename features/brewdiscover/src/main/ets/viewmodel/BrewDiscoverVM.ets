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
import {
  AI_D4_FEATURED_COUNT,
  AI_D4_INSTALLED_CAP,
  AI_D4_MIN_INSTALLED,
  AI_D4_POOL_CASK,
  AI_D4_POOL_FORMULA,
  AI_D4_RECENT_DAYS,
  AiCandidate,
  AiError,
  AiErrorKind,
  AiInstalledBrief,
  AiSettingsStore,
  AiTasks,
  BrewBrowseBuilder,
  BrewCacheEpoch,
  BrewDiscoverAiEntry,
  BrewDiscoverBoard,
  BrewDiscoverFeatured,
  BrewDiscoverModel,
  BrewInstalledLoader,
  BrewTable,
  BrewTaxonomy,
  BREW_TITLEBAR_BLUR_RAMP,
  brewBlurScrollEffect,
  brewLogRampForPage,
} from '@ohos/brewcommon';
import { AiDiscoverInput, AiDiscoverResult } from '@ohos/brewcommon';
import type {
  AiDiscoverPick,
  BrewDetailParams,
  BrewDiscoverBoardParams,
  BrewDiscoverEntry,
  BrewDiscoverPageData,
  BrewInstalledPackage,
  BrewInstalledSnapshot,
  CatalogEntry,
} from '@ohos/brewcommon';
import { AI_BOARD } from '../model/BrewBoardStyle';
import { BrewDiscoverFeedItem, BrewDiscoverFeedType } from '../model/BrewDiscoverFeedItem';
import { BrewDiscoverAiPhase, BrewDiscoverState } from './BrewDiscoverState';

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
  /** 最近一次 stat 榜原料（loadDiscover 写入，rebuildFeed 消费） */
  private lastFeatured: BrewDiscoverFeatured[] = [];
  private lastBoards: BrewDiscoverBoard[] = [];
  /** 最近一次 D4 候选池快照（buildAiInput 写入，applyAiResult 补全 entry 字段时消费） */
  private lastAiCandidates: AiCandidate[] = [];
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
    if (eventType === BrewDiscoverEventType.LOAD_AI) {
      return this.loadAiSection();
    }
    if (eventType === BrewDiscoverEventType.AI_RETRY) {
      return this.retryAi();
    }
    if (eventType === BrewDiscoverEventType.AI_REGENERATE) {
      return this.regenerateAi();
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
        // 记下原料、交给 rebuildFeed 摆：feed 从此只有一个拼装点 —— stat 混排（mix）与
        // AI 区前缀（D4，见 loadAiSection）在这里合流。AI phase 变化只重建 feed 数组，
        // 不重新走 getDiscoverPage，两条链路解耦。
        this.lastFeatured = featured;
        this.lastBoards = boards;
        this.state.snapshotDate = result.snapshotDate ?? '';
        this.rebuildFeed();
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
        // 打出组装后的类型顺序（F=大图卡 B=榜卡，a/A=AI 大图/AI 榜，s/S=骨架，X=失败）：
        // 混排规则唯一可核对的地方，stat 区期望 `F F B B F B F B B F B`，
        // AI 区前缀由 phase 决定（加载中 `s s s S`、就绪 `a a a A`、失败 `X`）。
        // 只打类型不打 token —— 一眼能看出归属是否正确。
        Logger.info(TAG,
          `loadDiscover success, ${featured.length} featured + ${boards.length} boards, ` +
          `order [${this.feedOrderLine()}], aiPhase=${this.state.aiPhase}, ` +
          `snapshot ${result.snapshotDate} in ${Date.now() - t0}ms | ` +
          `${BrewTable.statsLine()}`);
        // 目录两片都齐了，AI 区的闸门才有得谈（loadAiSection 内部自带
        // phase 重入/装机数/Key/目录 ready 判定，非 ready 时不会走到这里）
        this.loadAiSection();
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

  // ------------------------------------------------------------- AI 发现流（D4）
  // spec docs/superpowers/specs/2026-11-26-ai-discover-feed-spec.md。
  // 画像 + 推荐一次 LLM 调用生成（AiTasks.discover），VM 只做装配：闸门 → 候选池 →
  // phase 状态机 → feed 前缀。AI 是增强层：任何闸门不过都是**静默不出现**（G6），
  // 失败时占位卡 + 重试，主 stat 流不受影响。

  /** D4 prompt 的 locale。演示环境固定中文；接系统语言时只改这一处（spec §3.1） */
  private static readonly AI_LOCALE: string = 'zh';

  /**
   * AI 区装配入口（自动路径只认 HIDDEN：LOADING/REFRESHING 在途不重入；READY 已有内容；
   * FAILED 等用户点重试。tableObserver 落地 → loadDiscover → 这里，所以目录迟到会自动补跑）。
   *
   * 前置闸门（任一不过 = HIDDEN 静默，G6：不引导配 Key、不占位、不打 error）：
   *   1. 本机安装快照缺失（pc_normal 无 CLI / 首启未取）或装机数 < AI_D4_MIN_INSTALLED ——
   *      画像无从谈起；
   *   2. 无 API Key（E1）；
   *   3. 包表未 ready —— 候选池不完整会推荐出错的包（G5 的池子先于 G5 的校验）。
   */
  protected loadAiSection(): void {
    if (this.state.aiPhase !== BrewDiscoverAiPhase.HIDDEN) {
      return;
    }
    const snap: BrewInstalledSnapshot | null = BrewInstalledLoader.snapshot();
    if (snap === null || snap.sets.installed.length < AI_D4_MIN_INSTALLED) {
      Logger.debug(TAG, 'd4 hidden: installed snapshot missing or below minimum');
      return;
    }
    if (!AiSettingsStore.hasApiKey()) {
      Logger.debug(TAG, 'd4 hidden: no api key (G6 silent)');
      return;
    }
    if (BrewTable.state() !== 'ready') {
      Logger.debug(TAG, 'd4 hidden: catalog not ready yet');
      return;
    }
    const input: AiDiscoverInput = this.buildAiInput(snap, false);
    this.state.aiPhase = BrewDiscoverAiPhase.LOADING;
    this.rebuildFeed();
    Logger.info(TAG,
      `d4 loading: installed=${input.installed.length} candidates=${input.candidates.length}`);
    AiTasks.discover(input, false)
      .then((result: AiDiscoverResult) => {
        this.applyAiResult(result);
      })
      .catch((error: Error) => {
        this.applyAiError(error);
      });
  }

  /** 「换一批」（AI_REGENERATE）：force 旁路缓存读、exclude 当前 picks，照常写回同一 cacheKey */
  protected regenerateAi(): void {
    // 没有可换的（还在加载 / 已失败 / 已隐藏）就不响应 —— 按钮在 READY 之外本就不可见
    if (this.state.aiPhase !== BrewDiscoverAiPhase.READY) {
      return;
    }
    const snap: BrewInstalledSnapshot | null = BrewInstalledLoader.snapshot();
    if (snap === null) {
      return;
    }
    const input: AiDiscoverInput = this.buildAiInput(snap, true);
    this.state.aiRound++;
    this.state.aiPhase = BrewDiscoverAiPhase.REFRESHING;
    this.rebuildFeed();
    Logger.info(TAG,
      `d4 regenerate round=${this.state.aiRound} exclude=${input.exclude.length}`);
    AiTasks.discover(input, true)
      .then((result: AiDiscoverResult) => {
        this.applyAiResult(result);
      })
      .catch((error: Error) => {
        this.applyAiError(error);
      });
  }

  /** 失败占位卡上的「重试」（AI_RETRY）：回 HIDDEN 重走闸门。E2-E5 失败不写缓存，
   *  所以这里没有 force —— MISS 会真重打一次 LLM，不存在「重试秒回同一份失败」 */
  protected retryAi(): void {
    if (this.state.aiPhase !== BrewDiscoverAiPhase.FAILED) {
      return;
    }
    this.state.aiPhase = BrewDiscoverAiPhase.HIDDEN;
    this.loadAiSection();
  }

  /**
   * 组装 AiDiscoverInput。installed 按装时间降序（最近的权重最高），截 AI_D4_INSTALLED_CAP；
   * 候选池 formula top200 + cask top130（vol30d 降序）且**先剔掉已安装**（prompt 里
   * 不该出现已装包；模型如果仍推已装包，读侧 parseDiscover 还有第二道）。
   */
  private buildAiInput(snap: BrewInstalledSnapshot, force: boolean): AiDiscoverInput {
    const installed: BrewInstalledPackage[] = [...snap.sets.installed];
    installed.sort((a: BrewInstalledPackage, b: BrewInstalledPackage) => b.installedAt - a.installedAt);
    const capped: BrewInstalledPackage[] = installed.slice(0, AI_D4_INSTALLED_CAP);
    const recentLine: number = Date.now() - AI_D4_RECENT_DAYS * 24 * 60 * 60 * 1000;
    const briefs: AiInstalledBrief[] = [];
    capped.forEach((p: BrewInstalledPackage) => {
      const brief: AiInstalledBrief = new AiInstalledBrief();
      brief.token = p.name;
      brief.kind = p.kind;
      brief.recent = p.installedAt >= recentLine;
      briefs.push(brief);
    });
    const installedSet: Set<string> = new Set<string>();
    briefs.forEach((brief: AiInstalledBrief) => {
      installedSet.add(brief.token.toLowerCase());
    });
    const candidates: AiCandidate[] = [];
    this.collectCandidates('formula', AI_D4_POOL_FORMULA, installedSet, candidates);
    this.collectCandidates('cask', AI_D4_POOL_CASK, installedSet, candidates);
    this.lastAiCandidates = candidates;

    const input: AiDiscoverInput = new AiDiscoverInput();
    input.locale = BrewDiscoverHomeViewModel.AI_LOCALE;
    input.installed = briefs;
    input.candidates = candidates;
    input.epoch = BrewCacheEpoch.current();
    input.exclude = force ? this.currentPickTokens() : [];
    return input;
  }

  private collectCandidates(kind: string, cap: number, installedSet: Set<string>, out: AiCandidate[]): void {
    const rows: CatalogEntry[] = BrewTable.rows(kind).slice(0, cap);
    rows.forEach((row: CatalogEntry) => {
      if (installedSet.has(row.token.toLowerCase())) {
        return;
      }
      const candidate: AiCandidate = new AiCandidate();
      candidate.token = row.token;
      candidate.kind = kind;
      candidate.categoryKey = BrewTaxonomy.categoryOf(kind, row.token, BrewTable.descOf(kind, row.token));
      candidate.vol30d = row.vol30d;
      candidate.velocity = row.velocity;
      out.push(candidate);
    });
  }

  /** 换一批时的 exclude：当前 AI 榜上的 token（已安装 + 池内仍是事实，别的都别信） */
  private currentPickTokens(): string[] {
    const board: BrewDiscoverBoard | null = this.state.aiBoard;
    if (board === null) {
      return [];
    }
    return board.entries.map((entry: BrewDiscoverEntry) => entry.token);
  }

  /**
   * LLM 结果 → 渲染模型。字段可信度分三档：
   *   池内事实（kind / categoryKey / installs30d / velocity / desc） > pick 事实（token / why）
   *   > 占位（name = token，cask 显示名要发网络请求，不在这条链路里引）。
   * 解析侧（parseDiscover）已保证每个 pick 都在池内，这里查不到的按防御直接跳过。
   */
  private applyAiResult(result: AiDiscoverResult): void {
    const byToken: Map<string, AiCandidate> = new Map<string, AiCandidate>();
    this.lastAiCandidates.forEach((c: AiCandidate) => {
      byToken.set(c.token.toLowerCase(), c);
    });
    const entries: BrewDiscoverAiEntry[] = [];
    result.picks.forEach((pick: AiDiscoverPick) => {
      const candidate: AiCandidate | undefined = byToken.get(pick.token.toLowerCase());
      if (candidate === undefined) {
        return;
      }
      const entry: BrewDiscoverAiEntry = new BrewDiscoverAiEntry();
      entry.rank = entries.length + 1;
      entry.id = BrewBrowseBuilder.tokenId(candidate.token);
      entry.token = candidate.token;
      entry.name = candidate.token;
      entry.desc = pick.why;
      entry.categoryKey = candidate.categoryKey;
      entry.installs30d = candidate.vol30d;
      entry.velocity = candidate.velocity;
      entry.kind = candidate.kind;
      entries.push(entry);
    });
    // 大图卡取前 AI_D4_FEATURED_COUNT 张；desc 换成目录简介（大字位要的是"这是什么工具"，
    // 推荐理由留在榜行的副文案位）。id 用池内 token 的稳定 id —— 详情路由与 stat 卡同键。
    const featured: BrewDiscoverFeatured[] = [];
    const featuredCount: number = Math.min(entries.length, AI_D4_FEATURED_COUNT);
    for (let i: number = 0; i < featuredCount; i++) {
      const entry: BrewDiscoverAiEntry = entries[i];
      const card: BrewDiscoverFeatured = new BrewDiscoverFeatured();
      card.rank = i + 1;
      card.id = entry.id;
      card.token = entry.token;
      card.name = entry.name;
      card.desc = BrewTable.descOf(entry.kind, entry.token);
      card.categoryKey = entry.categoryKey;
      card.installs30d = entry.installs30d;
      card.velocity = entry.velocity;
      card.kind = entry.kind;
      card.boardKey = AI_BOARD;
      featured.push(card);
    }
    // AI 虚拟榜：id=0 兜底"根不可点"（'ai' 特判本就吞掉 ViewAll，双保险），
    // heroTitle = 画像 headline，boardKey='ai' 触发 BoardCard 特判（全显 / 换一批）。
    const board: BrewDiscoverBoard = new BrewDiscoverBoard();
    board.id = 0;
    board.kind = '';
    board.boardKey = AI_BOARD;
    board.sequence = 0;
    board.entryCount = entries.length;
    board.entries = entries;
    board.heroTitle = result.profile.headline;
    this.state.aiFeatured = featured;
    this.state.aiBoard = board;
    this.state.aiErrorText = '';
    this.state.aiPhase = BrewDiscoverAiPhase.READY;
    this.rebuildFeed();
    Logger.info(TAG,
      `d4 ready: ${featured.length} featured + ${entries.length} rows, ` +
      `headline=${result.profile.headline}, tags=[${result.profile.tags.join(',')}]`);
  }

  private applyAiError(error: Error): void {
    let kind: AiErrorKind = AiErrorKind.E2_NETWORK;
    if (error instanceof AiError) {
      kind = error.kind;
    }
    // E1 = 配置态变化（生成过程中用户删了 Key）→ 回 HIDDEN 静默，与「无 Key 不出 AI 区」同口径
    if (kind === AiErrorKind.E1_NO_KEY) {
      this.state.aiPhase = BrewDiscoverAiPhase.HIDDEN;
      this.rebuildFeed();
      Logger.info(TAG, 'd4 hidden after failure: no api key');
      return;
    }
    this.state.aiPhase = BrewDiscoverAiPhase.FAILED;
    this.state.aiErrorText = error.message;
    this.rebuildFeed();
    Logger.error(TAG, `d4 failed: kind=${kind} ${error.message}`);
  }

  /**
   * 唯一的 feed 拼装点（loadDiscover 与 D4 phase 变化都走这里）：AI 区前缀 + stat 混排。
   * stat 序列逐位不动的规则在 `BrewDiscoverFeedItem.mix` 内部，这里只做前缀拼接。
   */
  private rebuildFeed(): void {
    const aiFeed: BrewDiscoverFeedItem[] = this.buildAiFeedItems();
    const statFeed: BrewDiscoverFeedItem[] =
      BrewDiscoverFeedItem.mix(this.lastFeatured, this.lastBoards);
    this.state.cardSource.setDataArray(aiFeed.concat(statFeed));
    this.updateFlowSection();
  }

  private buildAiFeedItems(): BrewDiscoverFeedItem[] {
    const phase: BrewDiscoverAiPhase = this.state.aiPhase;
    if (phase === BrewDiscoverAiPhase.LOADING) {
      // 首载骨架：3 大图卡形 + 1 榜卡形，占住 AI 区版位防跳动（spec §4.2）
      return BrewDiscoverFeedItem.aiSkeletonFeed(AI_D4_FEATURED_COUNT);
    }
    if (phase === BrewDiscoverAiPhase.REFRESHING) {
      // 换一批：旧大图卡先留着（别闪成骨架），只把榜卡位换回骨架
      const items: BrewDiscoverFeedItem[] = [];
      this.state.aiFeatured.forEach((item: BrewDiscoverFeatured) => {
        items.push(BrewDiscoverFeedItem.ofAiFeatured(item));
      });
      return items.concat(BrewDiscoverFeedItem.aiSkeletonFeed(0));
    }
    if (phase === BrewDiscoverAiPhase.READY) {
      const items: BrewDiscoverFeedItem[] = [];
      this.state.aiFeatured.forEach((item: BrewDiscoverFeatured) => {
        items.push(BrewDiscoverFeedItem.ofAiFeatured(item));
      });
      const board: BrewDiscoverBoard | null = this.state.aiBoard;
      if (board !== null) {
        items.push(BrewDiscoverFeedItem.ofAiBoard(board));
      }
      return items;
    }
    if (phase === BrewDiscoverAiPhase.FAILED) {
      return [BrewDiscoverFeedItem.ofAiFailed()];
    }
    // HIDDEN：AI 区整段不出现，feed = 纯 stat 序列（老行为）
    return [];
  }

  /** feed 的类型序列一行（F/B/a/A/s/S/X），读屏上真实内容，供 loadDiscover 的 order 日志 */
  private feedOrderLine(): string {
    const total: number = this.state.cardSource.totalCount();
    let order: string = '';
    for (let i: number = 0; i < total; i++) {
      const one: BrewDiscoverFeedItem = this.state.cardSource.getData(i);
      const type: number = one.feedType;
      if (type === BrewDiscoverFeedType.FEATURED) {
        order += 'F ';
      } else if (type === BrewDiscoverFeedType.AI_FEATURED) {
        order += 'a ';
      } else if (type === BrewDiscoverFeedType.AI_BOARD) {
        order += 'A ';
      } else if (type === BrewDiscoverFeedType.AI_SKELETON_FEATURED) {
        order += 's ';
      } else if (type === BrewDiscoverFeedType.AI_SKELETON_BOARD) {
        order += 'S ';
      } else if (type === BrewDiscoverFeedType.AI_FAILED) {
        order += 'X ';
      } else {
        order += 'B ';
      }
    }
    return order.trim();
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
  /** AI 发现流（D4）：目录 ready 后的自动装配入口（幂等，见 loadAiSection 的闸门） */
  LOAD_AI = 'loadAiSection',
  /** AI 失败占位卡上的「重试」（回 HIDDEN 重走闸门，不 force） */
  AI_RETRY = 'aiRetry',
  /** AI 榜卡 Hero 右上的「换一批」（force + exclude 当前 picks） */
  AI_REGENERATE = 'aiRegenerate',
}

export interface BrewDiscoverEventParam<T> {
  type: BrewDiscoverEventType | BaseHomeEventType;
  param: T;
}
