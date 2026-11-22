/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import type { BusinessError } from '@kit.BasicServicesKit';
import { LoadingModel, LoadingStatus, Logger, RequestErrorCode, Toast } from '@ohos/common';
import {
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
  BrewSourceStore,
  BREW_DIALECT_HARMONYBREW,
  TldrService,
} from '@ohos/brewcommon';
import type {
  BrewCaskDetail,
  BrewDetailParams,
  BrewFormulaDetail,
  BrewInfoPageData,
  BrewInstalledPackage,
  BrewPackageItem,
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
    this.loadTldr(param, state);
    // 先用已有快照（内存优先、其次盘上）同步算一次安装状态：快照命中时按钮首帧就是对的，
    // 不等详情请求，也不等 brew 命令。详情页自己的网络取数不受这条路径影响。
    this.refreshInstallState(state);
    this.loadInstallState(state);
    const task: Promise<BrewInfoPageData> = param.kind === BrewKind.CASK ?
      this.loadCask(param.id, param.token) : this.loadFormula(param.id, param.token);
    task.then((data: BrewInfoPageData) => {
      state.data = data;
      this.setStatus(state, LoadingStatus.SUCCESS);
      // tap 只在详情数据里有，所以安装状态与按钮可执行性要等数据落地后再算一次
      this.refreshInstallState(state);
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
   * - `TldrService.get()` 从不 reject（内部已把 404/断网/解析失败全收敛成 null），
   *   这里的 catch 只是兜住非预期异常 —— 无论哪条路，失败都保持 `hasTldr=false`，
   *   分区不渲染、零提示（G6）；
   * - 数据到达时就地赋值插入（spec §4.2），不预留高度 —— 与 siblings 的异步插入
   *   是同一条既有惯例，页面其余分区照常。
   */
  private loadTldr(param: BrewDetailParams, state: BrewDetailState): void {
    if (param.kind !== BrewKind.FORMULA || param.token.trim().length === 0) {
      return;
    }
    TldrService.getInstance().get(param.token).then((page: TldrPage | null) => {
      // 空示例页与无页同口径：只有真正可渲染的示例才值得占一个分区
      if (page !== null && page.examples.length > 0) {
        state.tldrPage = page;
        state.hasTldr = true;
        Logger.info(TAG, `tldr ready, kind=${param.kind} token=${param.token} locale=${page.locale}`);
      }
    }).catch((error: Error) => {
      Logger.warn(TAG, `tldr load failed. reason=${error.message}`);
    });
  }
}
