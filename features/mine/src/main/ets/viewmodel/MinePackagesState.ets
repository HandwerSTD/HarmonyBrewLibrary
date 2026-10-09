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

import { LoadingModel } from '@ohos/common';
import type { BrewInstalledPackage } from '@ohos/brewcommon';
import { PackageListMode } from '../model/MinePackagesModels';

/**
 * 本机包列表页状态。
 *
 * `packages` 与 `filteredPackages` 都作为独立字段存储，而不是渲染时对 `packages` 现算 ——
 * 与 `BrewCaskCategoryState.categories` 同样的做法。筛选结果直接赋值给一个一级属性，
 * 刷新时机确定，不依赖「build 里读到的中间值会不会被观察到」。
 */
@Observed
export class MinePackagesState {
  public loadingModel: LoadingModel = new LoadingModel();
  public mode: PackageListMode = PackageListMode.ALL;
  /** 该模式下的全集（未筛选） */
  public packages: BrewInstalledPackage[] = [];
  /** 当前筛选后的列表 */
  public filteredPackages: BrewInstalledPackage[] = [];
  /** 筛选 chips 选中项：0 全部 / 1 Formulae / 2 Casks */
  public filterIndex: number = 0;
  /**
   * 是否隐藏作为依赖安装的包。进入页面时从 `MinePackagePrefs` 读入，点标题栏的 chip 时写回。
   * 三个列表页共用同一个键，所以三个页面的这个字段总是同一个值。
   */
  public hideDependencies: boolean = false;
  /**
   * 设备上有没有可用的 brew（能力开关打开、执行通道可用、至少一个候选路径可执行）。
   *
   * 顶部刷新按钮的显隐依据：设备上找不到 brew 时这个页面只能看到失败态与重试按钮，
   * 刷新按钮在那种环境里什么都刷不出来。进页取数时顺带算一次（那一次探测与取数自己
   * 走的是同一个 `brewPath()` 缓存），不在渲染路径里现算。
   */
  public brewReady: boolean = false;
  /**
   * 顶部刷新按钮是否正在刷新。
   *
   * 与 `loadingModel` 分开：刷新时列表里已经有数据了，把它换成加载态是多余的一次闪屏。
   * 刷新期间按钮置灰，重复点不会发出第二条命令。
   */
  public refreshing: boolean = false;
}
