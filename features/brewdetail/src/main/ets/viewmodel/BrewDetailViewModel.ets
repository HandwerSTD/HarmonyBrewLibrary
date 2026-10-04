/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import type { BusinessError } from '@kit.BasicServicesKit';
import { LoadingModel, LoadingStatus, Logger, RequestErrorCode } from '@ohos/common';
import { BrewCaskModel, BrewDetailNormalizer, BrewDocAbsentError, BrewFormulaModel, BrewKind } from '@ohos/brewcommon';
import type {
  BrewCaskDetail,
  BrewDetailParams,
  BrewFormulaDetail,
  BrewInfoPageData,
  BrewPackageItem,
} from '@ohos/brewcommon';
import { BrewDetailState } from './BrewDetailState';

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
    const task: Promise<BrewInfoPageData> = param.kind === BrewKind.CASK ?
      this.loadCask(param.id, param.token) : this.loadFormula(param.id, param.token);
    task.then((data: BrewInfoPageData) => {
      state.data = data;
      this.setStatus(state, LoadingStatus.SUCCESS);
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
}
