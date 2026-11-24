/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import type { BusinessError } from '@kit.BasicServicesKit';
import {
  LoadingModel,
  LoadingStatus,
  Logger,
  RequestErrorCode,
  StorageKey,
  Toast,
} from '@ohos/common';
import {
  AiSettingsStore,
  BrewCaskModel,
  BrewCli,
  BrewCommandGenerator,
  BrewCommandRequest,
  BrewCommandRunner,
  BrewCommandStartResult,
  BrewCommandState,
  BrewDetailNormalizer,
  BrewDocAbsentError,
  BrewFormulaModel,
  BrewInstalledLoader,
  BrewKind,
  BrewService,
  BrewSourceStore,
  BREW_DIALECT_HARMONYBREW,
  ReleaseIntelBaselineStore,
  ReleaseIntelPrefs,
  ReleaseIntelService,
  ReleaseIntelSnapshot,
  releaseIntelSnapshotFork,
  SemverJudge,
  TldrService,
} from '@ohos/brewcommon';
import type {
  BrewCaskDetail,
  BrewDetailParams,
  BrewFormulaDetail,
  BrewInfoPageData,
  BrewInstalledPackage,
  BrewPackageItem,
  ReleaseIntelArchiveEntry,
  ReleaseIntelCard,
  TldrPage,
} from '@ohos/brewcommon';
import { BrewDetailState, BrewInstallState } from './BrewDetailState';

const TAG: string = '[BrewDetailVM]';

/** 详情页「同分类其他包」最多展示几个 */
const SIBLING_LIMIT: number = 6;

/**
 * 详情页 ViewModel。formula / cask 共用。
 *
 * 与页签页不同，这里不需要复用 BaseHomeViewModel —— 详情页没有 banner、
 * 没有断点相关的内容重排，也没有 tabIndex 参与的状态栏逻辑。
 * 只需要：加载详情 + 加载同类包。
 *
 * **本类不持有 state**，state 由页面实例自己创建并传进来。原因是详情页可以叠在详情页上
 * （点「同分类其他包」会 push 一个新详情页）：如果 state 挂在共享对象上，
 * 新页面的加载结果会覆盖栈中旧页面的数据，从新页面返回时旧页面渲染的是同一份数据，
 * 表现就是「返回看起来没反应」。state 归页面实例所有即可天然隔离。
 *
 * 同类问题：返回键的防重入标志同理不能放共享 state —— 「本页是否已处理过返回」
 * 是每页实例的状态。见 BrewDetailView 里 @State backPressed 的注释。
 */
export class BrewDetailViewModel {
  private formulaModel: BrewFormulaModel = BrewFormulaModel.getInstance();
  private caskModel: BrewCaskModel = BrewCaskModel.getInstance();

  /** 单例即可：本类无状态，只是两个 model 的入口 */
  private static instance: BrewDetailViewModel;

  private constructor() {
  }

  public static getInstance(): BrewDetailViewModel {
    if (!BrewDetailViewModel.instance) {
      BrewDetailViewModel.instance = new BrewDetailViewModel();
    }
    return BrewDetailViewModel.instance;
  }

  /**
   * 进入详情页时调用。两个请求相互独立：
   * 详情失败 -> 整页失败态；同类包失败 -> 只是不显示推荐位（见 loadSiblings）。
   *
   * 失败分三种：数据源确认没这个包 -> `NOT_FOUND`（重试只在数据源自身变化后有救）；
   * 网络不通 -> `NO_NETWORK`；其余 -> `FAILED`。取数层在抛出前已经试过回退到历史详情。
   */
  public load(param: BrewDetailParams, state: BrewDetailState): void {
    this.setStatus(state, LoadingStatus.LOADING);
    this.loadSiblings(param, state);
    // 先用已有快照（内存优先、其次盘上）同步算一次安装状态：快照命中时按钮首帧就是对的，
    // 不等详情请求，也不等 brew 命令。详情页自己的网络取数不受这条路径影响。
    this.refreshInstallState(state);
    this.loadInstallState(state);
    // Y 基线预捕获（release intel spec §3.1）：store 的单条缓存是覆盖式的，
    // 详情请求一落地就会把「已装版本」的 raw 冲掉——必须抢在发起请求**之前**
    // 把旧 raw 抢救进基线库（版本相符才落盘，内部判；幂等）。
    this.captureBaselineFromStoreIfInstalled(param);
    const task: Promise<BrewInfoPageData> = param.kind === BrewKind.CASK ?
      this.loadCask(param.id, param.token) : this.loadFormula(param.id, param.token);
    task.then((data: BrewInfoPageData) => {
      state.data = data;
      this.setStatus(state, LoadingStatus.SUCCESS);
      // tap 只在详情数据里有，所以安装状态与按钮可执行性要等数据落地后再算一次
      this.refreshInstallState(state);
      // tldr 候选链需要「提供的命令」清单（executables 只在详情数据里有，
      // spec 2026-11-22 §3.1）—— 详情成功后再发起。详情失败时整页本就是错误态，
      // tldr 分区不可见，不需要取数。
      this.loadTldr(param, state);
      // Y：抓取落地后「已装==最新」时顺手把新 raw 快照进基线库（幂等），
      // 再装配更新情报卡（独立异步、失败静默——tldr 同款惯例，spec §4 / G8）。
      this.captureBaselineFromStoreIfInstalled(param);
      this.loadReleaseIntel(param, state);
      this.loadReleaseArchive(param, state);
      Logger.info(TAG, `load success, kind=${param.kind} token=${param.token}`);
    }).catch((error: Error) => {
      if (error instanceof BrewDocAbsentError) {
        // 数据源给出的确定结论，用 info 级别（不计入异常）
        this.setStatus(state, LoadingStatus.NOT_FOUND);
        Logger.info(TAG, `load absent, kind=${param.kind} token=${param.token} status=${error.status}`);
        return;
      }
      const err: BusinessError = error as BusinessError;
      this.setStatus(state, err.code === RequestErrorCode.NETWORK_CONNECT_FAILED ?
        LoadingStatus.NO_NETWORK : LoadingStatus.FAILED);
      Logger.error(TAG, `load failed. ${err.code} ${err.message}`);
    });
  }

  /**
   * 改加载状态。**整体替换 `loadingModel`，不写 `loadingModel.loadingStatus`** ——
   * 页面用 `@State detailState` 持有本状态类，状态管理 V1 只能观察到**第一层属性**的变化
   * （官方文档：`@State` 仅观察状态变量第一层属性的变化，不递归观察嵌套属性）。
   * 写二级属性时日志里有状态、页面一帧不变：真机实测「未找到」与失败态内容区永远空白、
   * 连重试按钮都出不来（`state.data = data` 是一级赋值，所以成功路径一直是好的，掩盖了它）。
   */
  private setStatus(state: BrewDetailState, status: LoadingStatus): void {
    state.loadingModel = new LoadingModel(status);
  }

  /**
   * 把本机安装状态与按钮可执行性按当前快照重算一遍。
   *
   * 三个时机都走这里：进页面（快照命中时首帧就对）、详情数据落地（`tap` 只在详情里有）、
   * 快照更新（后台刷新成功、写命令结束后的刷新，页面订阅后调用）。
   *
   * 匹配口径是 `BrewInstalledPackage.name === params.token`（本机包的 `name` 是不带 tap 前缀的包名，
   * 与路由参数里的 token 同一口径；`fullName` 带 tap 前缀，不参与匹配）。
   * `OUTDATED` 直接取快照里的 `outdated` 字段，不在这里做版本比较。
   */
  public refreshInstallState(state: BrewDetailState): void {
    state.installState = BrewDetailViewModel.installStateOf(state.params.token);
    const token: string = state.params.token;
    const tap: string = state.data.tap;
    // 能装到本机上的只有 Harmonybrew 方言的包：设备上跑的是 Harmonybrew，上游源下发的是 macOS 的
    // formula / cask 清单，照它的数据执行 install 只会失败。
    const dialect: string = BrewSourceStore.sessionActive().dialect;
    const commandable: boolean = dialect === BREW_DIALECT_HARMONYBREW;
    // `tap` 只在非空时才校验：Harmonybrew 方言刻意不设 tap（设了命令会变成
    // `brew install harmonybrew/core/wget`），空串是「无需前缀」，不是非法值。
    const safe: boolean = commandable && BrewCommandGenerator.isSafeName(token) &&
      (tap.length === 0 || BrewCommandGenerator.isSafeName(tap));
    if (safe) {
      state.commandHiddenWarned = false;
    } else if (!state.commandHiddenWarned) {
      state.commandHiddenWarned = true;
      Logger.warn(TAG, `action button hidden. token=${token} tap=${tap} dialect=${dialect}`);
    }
    // 能力开关关（pc_normal）时整块按钮不渲染
    state.commandReady = safe && BrewCli.isEnabled();
  }

  /** 读一次本机包快照让安装状态落到最新。新鲜窗口内立刻返回、不执行命令 */
  private loadInstallState(state: BrewDetailState): void {
    BrewInstalledLoader.loadSets()
      .then(() => {
        this.refreshInstallState(state);
      })
      .catch((error: Error) => {
        // 只在「本进程一次都没读到过」时才会失败。此时保留 UNKNOWN（按钮仍显示「安装」），
        // 页面本身的内容与加载态由详情请求决定，不跟着本机包的失败变。
        Logger.warn(TAG, `load install state failed. reason=${error.message}`);
      });
  }

  /** 本次点击要发出的参数：已安装且有新版本走 `upgrade`，其余走 `install` */
  public actionArgs(state: BrewDetailState): string {
    const token: string = state.params.token;
    const tap: string = state.data.tap;
    const kind: string = state.params.kind;
    return state.installState === BrewInstallState.OUTDATED ?
      BrewCommandGenerator.upgradeArgs(kind, token, tap) : BrewCommandGenerator.installArgs(kind, token, tap);
  }

  /**
   * 启动本包的安装 / 升级命令。返回 `STARTED` 时页面打开 Sheet；
   * 其余三类按 spec §5.4 弹对应提示。
   */
  public startInstallOrUpgrade(state: BrewDetailState): BrewCommandStartResult {
    const args: string = this.actionArgs(state);
    const isUpgrade: boolean = state.installState === BrewInstallState.OUTDATED;
    const token: string = state.params.token;
    const title: ResourceStr = isUpgrade ?
      $r('app.string.brew_cmd_title_upgrade', token) : $r('app.string.brew_cmd_title_install', token);
    const result: BrewCommandStartResult = BrewCommandRunner.getInstance().start(
      new BrewCommandRequest(title, `brew ${args}`, args));
    if (result === BrewCommandStartResult.BUSY) {
      Logger.info(TAG, `start rejected, another command is running, args=${args}`);
      Toast.showToast($r('app.string.brew_cmd_busy'));
    } else if (result === BrewCommandStartResult.UNAVAILABLE) {
      Logger.warn(TAG, `start rejected, brew is unavailable, args=${args}`);
      Toast.showToast($r('app.string.brew_cmd_unavailable'));
    } else if (result === BrewCommandStartResult.BAD_ARGS) {
      Logger.warn(TAG, `start rejected, args is not valid, args=${args}`);
      Toast.showToast($r('app.string.brew_cmd_bad_name'));
    }
    return result;
  }

  /**
   * 命令状态实例。`BrewCommandRunner` 单例持有的那一个，页面用它渲染 Sheet，
   * 并靠它的一级属性变化触发按钮文案重渲染。
   */
  public getCommandState(): BrewCommandState {
    return BrewCommandRunner.getInstance().getState();
  }

  /** 快照里查不到这个包 / 快照本身还没有时分开两种状态 */
  private static installStateOf(token: string): BrewInstallState {
    if (BrewInstalledLoader.snapshot() === null) {
      return BrewInstallState.UNKNOWN;
    }
    const installed: BrewInstalledPackage | null = BrewInstalledLoader.installedOf(token);
    if (installed === null) {
      return BrewInstallState.NOT_INSTALLED;
    }
    return installed.outdated ? BrewInstallState.OUTDATED : BrewInstallState.INSTALLED;
  }

  /**
   * `token` 必须一并传下去：现网单条请求只能按 token 发（`/api/formula/<token>.json`），
   * 官方 API 里没有我们本地的 id；id 只当路由参数与缓存键。
   */
  private loadFormula(id: number, token: string): Promise<BrewInfoPageData> {
    return this.formulaModel.getFormulaDetail(id, token)
      .then((detail: BrewFormulaDetail) => BrewDetailNormalizer.fromFormula(detail));
  }

  private loadCask(id: number, token: string): Promise<BrewInfoPageData> {
    return this.caskModel.getCaskDetail(id, token)
      .then((detail: BrewCaskDetail) => BrewDetailNormalizer.fromCask(detail));
  }

  /**
   * 同分类其他包。失败只记日志 —— 推荐位是附加信息，
   * 不应该因为它失败把详情页变成错误态（repository 侧已经把错误吞成空数组）。
   */
  private loadSiblings(param: BrewDetailParams, state: BrewDetailState): void {
    // 路由参数没带分类时按目录描述补算（本机包入口就是这种情况）：没有描述返回空串，
    // 「同分类其他包」保持为空。见 BrewRepository.categoryKeyOf。
    const categoryKey: string = param.categoryKey.length > 0 ? param.categoryKey :
      (param.kind === BrewKind.CASK ? this.caskModel.categoryKeyOf(param.token) :
        this.formulaModel.categoryKeyOf(param.token));
    const task: Promise<BrewPackageItem[]> = param.kind === BrewKind.CASK ?
      this.caskModel.getSameCategoryPackages(categoryKey, param.token, SIBLING_LIMIT) :
      this.formulaModel.getSameCategoryPackages(categoryKey, param.token, SIBLING_LIMIT);
    task.then((items: BrewPackageItem[]) => {
      state.siblings = items;
    }).catch(() => {
      state.siblings = [];
    });
  }

  /**
   * tldr 用法示例（spec 2026-11-22）。与 siblings 同一套「独立请求 + 失败静默」惯例：
   *
   * - 只对 formula 取（G2：tldr 只覆盖命令行工具，cask 详情页整区不出现，连请求都不发）；
   * - 候选名链 = [token, 剥 @version 后缀, …executables]（服务层构建，命中即停），
   *   ripgrep→rg、python@3.12→python、gnupg→gpg 这类命名错位由链修复；
   * - `TldrService.get()` 从不 reject（内部已把整链无页/断网/解析失败全收敛成 null），
   *   这里的 catch 只是兜住非预期异常 —— 无论哪条路，失败都保持 `hasTldr=false`，
   *   分区不渲染、零提示（G6）；
   * - 数据到达时就地赋值插入（spec §4.2），并带 300ms 淡入转场（G15）——
   *   缓存命中与临时拉取走**同一条**落地路径，视觉一致性优先。
   */
  private loadTldr(param: BrewDetailParams, state: BrewDetailState): void {
    if (param.kind !== BrewKind.FORMULA || param.token.trim().length === 0) {
      return;
    }
    TldrService.getInstance().get(param.token, state.data.executables).then((page: TldrPage | null) => {
      // 空示例页与无页同口径：只有真正可渲染的示例才值得占一个分区
      if (page !== null && page.examples.length > 0) {
        BrewDetailViewModel.applyTldrWithTransition(state, page);
        Logger.info(TAG, `tldr ready, kind=${param.kind} token=${param.token} locale=${page.locale} ` +
          `candidate=${page.command}`);
      }
    }).catch((error: Error) => {
      Logger.warn(TAG, `tldr load failed. reason=${error.message}`);
    });
  }

  /**
   * tldr 数据落 state，带插入转场（G15）。
   *
   * `animateTo` 包住赋值：分区插入与下方内容的重排一起按 300ms 走
   * （视图侧另有 `TransitionEffect` 控制新分区自己的淡入+上移，见 BrewDetailView）。
   * UIContext 从 AppStorage 取（与 TldrService 同款取法）—— **拿不到时直接赋值不动画**：
   * 转场是展示层锦上添花，任何环境下都不能因为它崩或卡住数据（G6 的兜底口径）。
   */
  private static applyTldrWithTransition(state: BrewDetailState, page: TldrPage): void {
    const apply: () => void = () => {
      state.tldrPage = page;
      state.hasTldr = true;
    };
    const uiContext: UIContext | undefined = AppStorage.get<UIContext>(StorageKey.UI_CONTEXT);
    if (uiContext === undefined) {
      apply();
      return;
    }
    uiContext.animateTo({ duration: 300, curve: Curve.Friction }, apply);
  }

  // ------------------------------------------------------------ Y · 更新情报中心

  /**
   * Y 基线的捕获入口（release intel spec §3.1）：store 缓存里的 raw 若恰好是「已装版本」，
   * 就把它落进基线库（幂等）。两个时机共用：详情请求**前**（预捕获，防覆盖）与
   * 成功落地**后**（已装==最新时新抓到的 raw 就是已装配方）。
   * 内部判「raw 版本 == 已装版本」——OUTDATED 包刚抓到的新版本不会误存成基线。
   */
  private captureBaselineFromStoreIfInstalled(param: BrewDetailParams): void {
    if (!BrewCli.isEnabled() || param.kind === BrewKind.CASK || param.token.trim().length === 0) {
      return;
    }
    const installed: BrewInstalledPackage | null = BrewInstalledLoader.installedOf(param.token);
    if (installed === null || installed.version.length === 0) {
      return;
    }
    ReleaseIntelService.captureBaselineFromStore('formula', param.token, installed.version,
      BrewService.cachedRawDocJson('formula', param.token));
  }

  /**
   * Y 更新情报卡（release intel spec §3.1 / §4 / G8）。与 tldr 同一条惯例：
   * 独立异步、失败静默、数据到达带 300ms 淡入。
   *
   * 出现条件（三道闸，任一不满足整卡不出现、不发请求）：
   * - pc_normal / CLI 关（G10）；
   * - 仅 formula（cask v1 不渲染情报卡，spec §10）；
   * - 本机已装且 OUTDATED（H 负责发现更新，Y 只理解「这一组更新」）。
   *
   * **两阶段装配（v1.3.8 用户定调）**：先落占位卡（「版本号 + spinner」，情报获取
   * 期间就上屏），assemble 只做结构化区 + notes 原文（atom 是唯一网络步）——
   * 快照落地后正文**保持原文**；AI 段随后后台补跑（`runIntelAi`），期间只有
   * 操作行的 AI 入口转 [spinner] AI 解析中，AI **完成才把 card 落进快照**、
   * 正文由卡片 @Watch 切到 AI 视图。AI 生成期间整卡不再是 spinner。
   *
   * baseline 缺失 → F5（diff 区降级）；上游通道失败 → 对应缺口码；
   * AI 失败 / 无 Key → 结构化区照常渲染（G5）。`force` 旁路两级缓存
   * （快照缓存 + AI 缓存）；`manualAi` 绕开自动解析开关（用户显式触发）。
   */
  public loadReleaseIntel(param: BrewDetailParams, state: BrewDetailState, force: boolean = false,
    manualAi: boolean = false): void {
    const inputs: IntelAssembleInputs | null = this.intelInputsOf(param, state);
    if (inputs === null) {
      return;
    }
    // 占位快照（loading=true）：立即上卡,版本行已知,正文区只有 spinner
    // （仅首次装配用——卡上还没有任何可展示的内容;「重新生成」不走这里,见下）
    const loading: ReleaseIntelSnapshot = new ReleaseIntelSnapshot();
    loading.token = param.token;
    loading.kind = 'formula';
    loading.fromVersion = inputs.fromVersion;
    loading.toVersion = inputs.latestVersion;
    loading.verdict = SemverJudge.judge(inputs.fromVersion, inputs.latestVersion).kind;
    loading.fetchedAt = Date.now();
    loading.loading = true;
    state.releaseIntel = loading;
    BrewDetailViewModel.applyIntelWithTransition(state);
    ReleaseIntelService.assemble(inputs.rawDoc, inputs.oldRawJson, param.token, 'formula',
      inputs.fromVersion, force)
      .then((snapshot: ReleaseIntelSnapshot) => {
        // 版本无增量（快照同步偏差：brew 说 outdated 但源还没更新）→ 收掉占位卡
        if (snapshot.toVersion.length === 0 || snapshot.toVersion === snapshot.fromVersion) {
          Logger.info(TAG, `release intel skip: no version delta, token=${param.token}`);
          state.hasReleaseIntel = false;
          return;
        }
        state.releaseIntel = snapshot;
        // 策略与 pin（G6）：忽略状态影响顶部弱化条；pin 只生成命令文本，执行=复制
        state.releaseIntelIgnored =
          ReleaseIntelPrefs.ignoredVersion(param.token) === snapshot.toVersion;
        state.releaseIntelPinCommand = BrewCommandGenerator.pinCommand(param.token, state.data.tap);
        BrewDetailViewModel.applyIntelWithTransition(state);
        Logger.info(TAG, `release intel ready token=${param.token} ` +
          `${snapshot.fromVersion} -> ${snapshot.toVersion} gap=${snapshot.gapCode} ` +
          `card=${snapshot.card !== null}`);
        // AI 段后台补跑（自动闸/Key 闸在 runIntelAi 里判;card 已有则秒回）
        this.runIntelAi(state, snapshot, force, manualAi);
      })
      .catch((error: Error) => {
        // assemble 内部不抛（缺口都收敛进 gapCode）；这里的 catch 只兜非预期异常。
        // 占位卡收掉,别让 spinner 永转
        state.hasReleaseIntel = false;
        Logger.warn(TAG, `release intel load failed. reason=${error.message}`);
      });
  }

  /**
   * 装配输入推导（loadReleaseIntel / regenerateReleaseIntel 共用）：三道出现闸
   * （CLI 开 / formula / OUTDATED）+ 已装与最新版本 + store raw + 基线 raw。
   * 任一不满足返回 null（整卡不出现、不发请求）。
   */
  private intelInputsOf(param: BrewDetailParams, state: BrewDetailState): IntelAssembleInputs | null {
    if (!BrewCli.isEnabled() || param.kind === BrewKind.CASK || param.token.trim().length === 0) {
      return null;
    }
    if (state.installState !== BrewInstallState.OUTDATED) {
      return null;
    }
    const installed: BrewInstalledPackage | null = BrewInstalledLoader.installedOf(param.token);
    if (installed === null || installed.version.length === 0 ||
      installed.latestVersion.length === 0) {
      return null;
    }
    // store 里的 raw 是「刚刚抓到的最新版」；基线库里有已装版本的旧 raw（load 开头已预捕获）
    const rawJson: string = BrewService.cachedRawDocJson('formula', param.token);
    if (rawJson.length === 0) {
      return null;
    }
    let rawDoc: Object = new Object();
    try {
      rawDoc = JSON.parse(rawJson) as Object;
    } catch (error) {
      Logger.warn(TAG, `release intel raw parse failed, token=${param.token}`);
      return null;
    }
    const out: IntelAssembleInputs = new IntelAssembleInputs();
    out.rawDoc = rawDoc;
    out.oldRawJson = ReleaseIntelBaselineStore.read(param.token, installed.version);
    out.fromVersion = installed.version;
    out.latestVersion = installed.latestVersion;
    return out;
  }

  /**
   * AI 摘要段（v1.3.8 两阶段装配的第二段）：输入全部来自已落卡的快照
   * （notesFull/diff 就是当初要喂 AI 的那份数据），**不重跑 atom/结构化装配**。
   * 开跑前落 aiPending=true 的快照副本（操作行转 [spinner] AI 解析中）——
   * **已在 pending 态的快照不重复落**（「重新生成」路径先落 pending 再带着它进来）；
   * 完成/失败各落一次新副本——@Prop 靠新对象引用触发更新，原地改字段 UI 不刷新。
   *
   * 闸：card 已有 / 已失败 / 无 notes（缺口态）→ 不跑；自动流过「自动解析更新日志」
   * 开关；无 Key 静默跳过（G5，不落 aiFailed——无 Key 不是失败态）。
   * `manual=true`（手动按钮/重新生成）绕开自动开关。
   */
  private runIntelAi(state: BrewDetailState, base: ReleaseIntelSnapshot, force: boolean,
    manual: boolean): Promise<void> {
    if (base.loading || base.card !== null || base.aiFailed || base.notesFull.length === 0) {
      return Promise.resolve();
    }
    if (!manual && !AiSettingsStore.autoReleaseIntel()) {
      return Promise.resolve();
    }
    if (!AiSettingsStore.hasApiKey()) {
      return Promise.resolve();
    }
    let pending: ReleaseIntelSnapshot = base;
    if (!base.aiPending) {
      pending = releaseIntelSnapshotFork(base);
      pending.aiPending = true;
      state.releaseIntel = pending;
    }
    return ReleaseIntelService.runAi(pending.token, pending.fromVersion, pending.toVersion,
      pending.notesFull, pending.diff, force)
      .then((card: ReleaseIntelCard) => {
        const done: ReleaseIntelSnapshot = releaseIntelSnapshotFork(pending);
        done.card = card;
        done.aiPending = false;
        state.releaseIntel = done;
        BrewDetailViewModel.applyIntelWithTransition(state);
        Logger.info(TAG, `release intel ai ready token=${done.token} to=${done.toVersion}`);
      })
      .catch((error: Error) => {
        const done: ReleaseIntelSnapshot = releaseIntelSnapshotFork(pending);
        done.aiFailed = true;
        done.aiPending = false;
        state.releaseIntel = done;
        BrewDetailViewModel.applyIntelWithTransition(state);
        Logger.warn(TAG, `release intel ai failed, token=${done.token}, reason=${error.message}`);
      });
  }

  /**
   * 手动「AI 解析」（v1.3.3 用户定调；v1.3.8 改用当前快照补跑）：自动解析开关
   * 关闭时,操作行末尾仍有显式按钮——直接用**当前已落卡快照**的数据只跑 AI 段
   * （不重跑 atom/结构化装配,也不再有「atom 这次失败把整卡打回缺口态」的回归面）。
   * 完成前卡片正文保持原文,完成后由卡片的 @Watch 把正文切到 AI 视图。
   * Promise 交给按钮做 spinner/禁用。
   */
  public requestReleaseIntelAi(state: BrewDetailState): Promise<void> {
    return this.runIntelAi(state, state.releaseIntel, false, true);
  }

  /** 情报卡数据落 state，带插入转场（对齐 tldr 的 300ms 淡入，spec §4.2 同款） */
  private static applyIntelWithTransition(state: BrewDetailState): void {
    const apply: () => void = () => {
      state.hasReleaseIntel = true;
    };
    const uiContext: UIContext | undefined = AppStorage.get<UIContext>(StorageKey.UI_CONTEXT);
    if (uiContext === undefined) {
      apply();
      return;
    }
    uiContext.animateTo({ duration: 300, curve: Curve.Friction }, apply);
  }

  /**
   * 「重新生成」（G8；v1.3.8b 用户定调重写）：旁路两级缓存强制重装配 + 强制重跑 AI。
   * **不落占位卡**——当前卡的原文**始终保持展示**，先把现有快照 fork 成
   * card=null + aiPending（正文回原文、操作行 AI 入口转 [spinner] AI 解析中），
   * assemble 与 AI 全程后台跑；新装配有 notes 就带着 pending 态继续跑 AI（不闪
   * 「按钮出现又变 spinner」的中间态），AI 完成才落 card、@Watch 切 AI 视图。
   * 新装配没拿到 notes（缺口态）则直接落新快照——缺口是数据事实，如实展示。
   */
  public regenerateReleaseIntel(param: BrewDetailParams, state: BrewDetailState): void {
    const inputs: IntelAssembleInputs | null = this.intelInputsOf(param, state);
    if (inputs === null) {
      return;
    }
    const current: ReleaseIntelSnapshot = state.releaseIntel;
    if (!current.loading) {
      const pending: ReleaseIntelSnapshot = releaseIntelSnapshotFork(current);
      pending.card = null;
      pending.aiFailed = false;
      pending.aiPending = true;
      state.releaseIntel = pending;
    }
    ReleaseIntelService.assemble(inputs.rawDoc, inputs.oldRawJson, param.token, 'formula',
      inputs.fromVersion, true)
      .then((snapshot: ReleaseIntelSnapshot) => {
        if (snapshot.toVersion.length === 0 || snapshot.toVersion === snapshot.fromVersion) {
          Logger.info(TAG, `release intel regen skip: no version delta, token=${param.token}`);
          state.hasReleaseIntel = false;
          return;
        }
        state.releaseIntelIgnored =
          ReleaseIntelPrefs.ignoredVersion(param.token) === snapshot.toVersion;
        state.releaseIntelPinCommand = BrewCommandGenerator.pinCommand(param.token, state.data.tap);
        if (snapshot.notesFull.length === 0) {
          // 缺口态（如 atom 这次失败）：AI 无从跑,如实落卡收尾
          state.releaseIntel = snapshot;
          BrewDetailViewModel.applyIntelWithTransition(state);
          Logger.info(TAG, `release intel regen gap=${snapshot.gapCode}, token=${param.token}`);
          return;
        }
        // 有 notes：保持 pending 态无缝续跑 AI（force 旁路 AI 缓存）
        const pending: ReleaseIntelSnapshot = releaseIntelSnapshotFork(snapshot);
        pending.aiPending = true;
        state.releaseIntel = pending;
        this.runIntelAi(state, pending, true, true);
      })
      .catch((error: Error) => {
        state.hasReleaseIntel = false;
        Logger.warn(TAG, `release intel regenerate failed. reason=${error.message}`);
      });
  }

  /**
   * 版本档案区（spec §3.3 / §4：caveats 与 siblings 之间）。readArchive 是同步盘读，
   * 这里同步调用、try/catch 兜底静默（档案是增益记录，读失败只影响档案区展示）；
   * 只展示当前 token 的条目，按时间倒序（appendArchive 已保证）。
   * CLI 关 / pc_normal（G10）/ token 空都不加载。
   */
  public loadReleaseArchive(param: BrewDetailParams, state: BrewDetailState): void {
    if (!BrewCli.isEnabled() || param.token.trim().length === 0) {
      return;
    }
    try {
      const entries: ReleaseIntelArchiveEntry[] = ReleaseIntelService.readArchive();
      const mine: ReleaseIntelArchiveEntry[] = [];
      for (const entry of entries) {
        if (entry.token === param.token) {
          mine.push(entry);
        }
      }
      state.releaseArchive = mine;
    } catch (error) {
      Logger.warn(TAG, `release archive load failed. reason=${(error as Error).message}`);
    }
  }
}

/** 情报卡装配输入（intelInputsOf 的产物，loadReleaseIntel / regenerateReleaseIntel 共用）。 */
class IntelAssembleInputs {
  /** 最新版 raw doc（store 缓存解析产物） */
  public rawDoc: Object = new Object();
  /** 已装版本的基线 raw JSON（空串 = 基线缺失，F5） */
  public oldRawJson: string = '';
  /** 已装版本（from） */
  public fromVersion: string = '';
  /** 最新版本（to；占位快照的版本行用） */
  public latestVersion: string = '';
}
