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

import type { BusinessError } from '@kit.BasicServicesKit';
import { LoadingStatus, Logger, RequestErrorCode } from '@ohos/common';
import { BrewCaskModel, BrewDetailNormalizer, BrewFormulaModel, BrewKind } from '@ohos/brewcommon';
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
   */
  public load(param: BrewDetailParams, state: BrewDetailState): void {
    state.loadingModel.loadingStatus = LoadingStatus.LOADING;
    this.loadSiblings(param, state);
    const task: Promise<BrewInfoPageData> = param.kind === BrewKind.CASK ?
      this.loadCask(param.id, param.token) : this.loadFormula(param.id, param.token);
    task.then((data: BrewInfoPageData) => {
      state.data = data;
      state.loadingModel.loadingStatus = LoadingStatus.SUCCESS;
      Logger.info(TAG, `load success, kind=${param.kind} token=${param.token}`);
    }).catch((error: BusinessError) => {
      if (error.code === RequestErrorCode.NETWORK_CONNECT_FAILED) {
        state.loadingModel.loadingStatus = LoadingStatus.NO_NETWORK;
      } else {
        state.loadingModel.loadingStatus = LoadingStatus.FAILED;
      }
      Logger.error(TAG, `load failed. ${error.code} ${error.message}`);
    });
  }

  /**
   * `token` 必须一并传下去：内置快照能按 id 找到骨架，但**现网单条请求只能按 token 发**
   * （`/api/formula/<token>.json`），官方 API 里没有我们本地的 id。
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
    const task: Promise<BrewPackageItem[]> = param.kind === BrewKind.CASK ?
      this.caskModel.getSameCategoryPackages(param.categoryKey, param.token, SIBLING_LIMIT) :
      this.formulaModel.getSameCategoryPackages(param.categoryKey, param.token, SIBLING_LIMIT);
    task.then((items: BrewPackageItem[]) => {
      state.siblings = items;
    }).catch(() => {
      state.siblings = [];
    });
  }
}
