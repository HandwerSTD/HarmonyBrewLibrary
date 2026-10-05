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
import { LoadingModel, LoadingStatus, Logger, Toast } from '@ohos/common';
import {
  BrewChipItem,
  BrewCommandGenerator,
  BrewCommandRequest,
  BrewCommandRunner,
  BrewCommandStartResult,
  BrewCommandState,
  BrewInstalledLoader,
} from '@ohos/brewcommon';
import type { BrewInstalledPackage, BrewInstalledSets } from '@ohos/brewcommon';
import { PackageListMode } from '../model/MinePackagesModels';
import { MinePackageSets } from '../model/MinePackagesModels';
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
  /**
   * 快照更新回调。存成字段而不是在 `subscribe` 里现造一个箭头函数：
   * `BrewInstalledLoader` 按函数对象去重，两处传的不是同一个对象时会退订不掉、回调叠加。
   */
  private snapshotListener: () => void = () => {
    this.applySnapshot();
  };

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

    // 快照优先（spec §6.4）：有快照就直接出列表，页面不闪加载态。
    // 冷启动进「待更新」页时盘上快照就能立刻显示数量，不需要等一次 brew 命令。
    const snapshot = BrewInstalledLoader.snapshot();
    if (snapshot !== null) {
      this.applySets(MinePackagesVM.toMineSets(snapshot.sets));
    } else {
      this.setStatus(LoadingStatus.LOADING);
    }

    // 随后仍然走一次 `loadSets`：新鲜窗口内它立刻返回快照不执行命令，超窗时它在后台刷新。
    MinePackagesUtil.loadSets()
      .then((sets) => {
        this.applySets(sets);
        Logger.info(TAG, `load success, mode=${mode} count=${this.state.packages.length}`);
      })
      .catch((error: BusinessError) => {
        // `loadSets` 只在「没有任何快照」时才会失败（有了快照它直接返回旧数据、不执行命令），
        // 所以走到这里就意味着从头到尾没读到过，按整页失败处理。
        // 本机包读不到一律走失败态：`error.message` 里是 `BrewInstalledFailure` 的分类
        // （找不到 brew / 执行能力不可用 / 超时 / 非零退出 / 输出解析失败 / 形状不符）。
        // 分类只进日志 —— 用户看到「读不到本机包」就够，不需要知道是超时还是输出形状变了。
        this.setStatus(LoadingStatus.FAILED);
        Logger.error(TAG, `load failed. reason=${error.message} code=${error.code}`);
      });
  }

  /**
   * 订阅已安装列表快照的更新（后台刷新成功、写命令结束后的刷新），按当前模式重新 `pick`。
   * 由页面在显示期间调用。
   */
  public subscribeSnapshot(): void {
    BrewInstalledLoader.subscribe(this.snapshotListener);
  }

  public unsubscribeSnapshot(): void {
    BrewInstalledLoader.unsubscribe(this.snapshotListener);
  }

  /** 本次「更新全部」要发出的参数，跟随筛选 chips（0 全部 / 1 Formulae / 2 Casks） */
  public upgradeAllArgs(): string {
    return BrewCommandGenerator.upgradeAllArgs(this.state.filterIndex);
  }

  /**
   * 命令状态实例。`BrewCommandRunner` 单例持有的那一个，页面用它渲染 Sheet，
   * 并靠它的一级属性变化触发按钮文案重渲染。
   */
  public getCommandState(): BrewCommandState {
    return BrewCommandRunner.getInstance().getState();
  }

  /**
   * 启动「更新全部」。返回 `STARTED` 时页面打开 Sheet；其余三类按 spec §5.4 弹对应提示。
   */
  public startUpgradeAll(): BrewCommandStartResult {
    const args: string = this.upgradeAllArgs();
    const result: BrewCommandStartResult = BrewCommandRunner.getInstance().start(
      new BrewCommandRequest($r('app.string.brew_action_upgrade_all'), `brew ${args}`, args));
    if (result === BrewCommandStartResult.BUSY) {
      Logger.info(TAG, `upgradeAll rejected, another command is running, args=${args}`);
      Toast.showToast($r('app.string.brew_cmd_busy'));
    } else if (result === BrewCommandStartResult.UNAVAILABLE) {
      Logger.warn(TAG, `upgradeAll rejected, brew is unavailable, args=${args}`);
      Toast.showToast($r('app.string.brew_cmd_unavailable'));
    } else if (result === BrewCommandStartResult.BAD_ARGS) {
      Logger.warn(TAG, `upgradeAll rejected, args is not valid, args=${args}`);
      Toast.showToast($r('app.string.brew_cmd_bad_name'));
    }
    return result;
  }

  /**
   * 快照里就地取一遍列表。快照路径不能等一次命令，所以自己转一次集合，
   * 取列表仍然走 `MinePackagesUtil.pick` —— 与命令路径同一个口径，不会出现两种排序。
   */
  private applySnapshot(): void {
    const snapshot = BrewInstalledLoader.snapshot();
    if (snapshot === null) {
      return;
    }
    this.applySets(MinePackagesVM.toMineSets(snapshot.sets));
  }

  /**
   * 三个集合落到状态上。
   *
   * 只写 `packages` / `filteredPackages` 两个一级属性：状态管理 V1 只观察第一层，
   * 写成 `state.packages[i].xxx` 页面不会跟着变。
   * `filteredPackages` 走 `filter()` 而不是直接用全集 —— 快照更新可能发生在用户切过 chips 之后。
   */
  private applySets(sets: MinePackageSets): void {
    const list: BrewInstalledPackage[] = MinePackagesUtil.pick(sets, this.state.mode);
    this.state.packages = list;
    this.state.filteredPackages = MinePackagesUtil.filter(list, this.state.filterIndex);
    this.setStatus(LoadingStatus.SUCCESS);
  }

  /** `BrewInstalledSets` -> `MinePackageSets`。与 `MinePackagesUtil.loadSets` 的转法一致 */
  private static toMineSets(loaded: BrewInstalledSets): MinePackageSets {
    const sets: MinePackageSets = new MinePackageSets();
    sets.installed = loaded.installed;
    sets.outdated = loaded.outdated;
    sets.updated = loaded.updated;
    return sets;
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
