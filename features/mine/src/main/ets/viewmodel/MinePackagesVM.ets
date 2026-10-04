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
import { LoadingModel, LoadingStatus, Logger } from '@ohos/common';
import { BrewChipItem } from '@ohos/brewcommon';
import type { BrewInstalledPackage } from '@ohos/brewcommon';
import { PackageListMode } from '../model/MinePackagesModels';
import { MinePackagesUtil } from '../util/MinePackagesUtil';
import { MinePackagesState } from './MinePackagesState';

const TAG: string = '[MinePackagesVM]';

/** 筛选 chips 的下标，与 MinePackagesUtil.filter() 的约定一致 */
const FILTER_ALL: number = 0;
const FILTER_FORMULA: number = 1;
const FILTER_CASK: number = 2;

/**
 * 本机包列表页 ViewModel。
 *
 * 单例是安全的：这个页面只会被 push 一次、不会叠在自己上面
 * （与详情页不同 —— 详情页能从「同分类其他包」再 push 一个详情页，
 * 那里共享 state 会导致返回后内容串页，见 docs §10.4.1）。
 */
export class MinePackagesVM {
  private static instance: MinePackagesVM;
  private state: MinePackagesState = new MinePackagesState();

  private constructor() {
  }

  public static getInstance(): MinePackagesVM {
    if (!MinePackagesVM.instance) {
      MinePackagesVM.instance = new MinePackagesVM();
    }
    return MinePackagesVM.instance;
  }

  public getState(): MinePackagesState {
    return this.state;
  }

  public getChips(): BrewChipItem[] {
    return [
      new BrewChipItem('all', $r('app.string.mine_filter_all')),
      new BrewChipItem('formula', $r('app.string.mine_filter_formulae')),
      new BrewChipItem('cask', $r('app.string.mine_filter_casks')),
    ];
  }

  /** 进入页面时调用。mode 由路由参数决定，三个入口共用这一个页面。 */
  public load(mode: PackageListMode): void {
    this.state.mode = mode;
    this.state.filterIndex = FILTER_ALL;
    this.state.packages = [];
    this.state.filteredPackages = [];
    this.setStatus(LoadingStatus.LOADING);

    MinePackagesUtil.loadSets()
      .then((sets) => {
        const list: BrewInstalledPackage[] = MinePackagesUtil.pick(sets, mode);
        this.state.packages = list;
        this.state.filteredPackages = list;
        this.setStatus(LoadingStatus.SUCCESS);
        Logger.info(TAG, `load success, mode=${mode} count=${list.length}`);
      })
      .catch((error: BusinessError) => {
        // 本机包读不到一律走失败态：`error.message` 里是 `BrewInstalledFailure` 的分类
        // （找不到 brew / 执行能力不可用 / 超时 / 非零退出 / 输出解析失败 / 形状不符）。
        // 分类只进日志 —— 用户看到「读不到本机包」就够，不需要知道是超时还是输出形状变了。
        this.setStatus(LoadingStatus.FAILED);
        Logger.error(TAG, `load failed. reason=${error.message} code=${error.code}`);
      });
  }

  /**
   * 改加载状态。**整体替换 `loadingModel`**：页面用 `@State packagesState` 持有本状态类，
   * 状态管理 V1 只能观察到第一层属性的变化（不递归观察嵌套属性）。
   * 写 `state.loadingModel.loadingStatus` 时日志里有状态、页面不变 —— 失败态会一直停在转圈，
   * 因为失败路径不再有一级属性赋值跟着它一起触发重渲染。
   */
  private setStatus(status: LoadingStatus): void {
    this.state.loadingModel = new LoadingModel(status);
  }

  /** 切换筛选 chips */
  public setFilter(index: number): void {
    if (index < FILTER_ALL || index > FILTER_CASK || index === this.state.filterIndex) {
      return;
    }
    this.state.filterIndex = index;
    this.state.filteredPackages = MinePackagesUtil.filter(this.state.packages, index);
  }
}
