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

import { BrewKind, BrewLocalModel } from '@ohos/brewcommon';
import type { BrewInstalledPackage } from '@ohos/brewcommon';
import { MinePackageSets, PackageListMode } from '../model/MinePackagesModels';

/**
 * 本机包集合的取数口径。**「我的」首页与它的子页面共用这一份** ——
 * 见 `MinePackageSets` 的注释：两处各算一次迟早会让「卡片预览」和「查看全部」的首项不一致。
 */
export class MinePackagesUtil {
  /**
   * 一次取齐三个集合。三个请求并发发起，任一失败则整体失败（都来自同一个本地 mock，
   * 失败基本只会是资源读取问题，此时整块内容都不该显示）。
   */
  public static loadSets(): Promise<MinePackageSets> {
    const model: BrewLocalModel = BrewLocalModel.getInstance();
    return Promise.all([
      model.getInstalledFormulae(),
      model.getInstalledCasks(),
      model.getOutdated(),
    ]).then((result: BrewInstalledPackage[][]) => {
      const all: BrewInstalledPackage[] = result[0].concat(result[1]);
      const outdated: BrewInstalledPackage[] = result[2];
      const outdatedFullNames: Set<string> = new Set<string>();
      outdated.forEach((pkg: BrewInstalledPackage) => {
        outdatedFullNames.add(pkg.fullName);
      });

      const sets: MinePackageSets = new MinePackageSets();
      sets.installed = MinePackagesUtil.byName(all);
      sets.outdated = MinePackagesUtil.byName(outdated);
      sets.updated = all.filter((pkg: BrewInstalledPackage) => !outdatedFullNames.has(pkg.fullName));
      sets.updated.sort((a: BrewInstalledPackage, b: BrewInstalledPackage) => b.installedAt - a.installedAt);
      return sets;
    });
  }

  /** 按模式取对应的集合 */
  public static pick(sets: MinePackageSets, mode: PackageListMode): BrewInstalledPackage[] {
    if (mode === PackageListMode.OUTDATED) {
      return sets.outdated;
    }
    if (mode === PackageListMode.UPDATED) {
      return sets.updated;
    }
    return sets.installed;
  }

  /**
   * 按筛选 chips 过滤：0 全部 / 1 Formulae / 2 Casks。
   * 不用 `Array.filter` 的条件表达式做花活，直接比 kind 更好读。
   */
  public static filter(list: BrewInstalledPackage[], filterIndex: number): BrewInstalledPackage[] {
    if (filterIndex === 1) {
      return list.filter((pkg: BrewInstalledPackage) => pkg.kind === BrewKind.FORMULA);
    }
    if (filterIndex === 2) {
      return list.filter((pkg: BrewInstalledPackage) => pkg.kind === BrewKind.CASK);
    }
    return list;
  }

  private static byName(list: BrewInstalledPackage[]): BrewInstalledPackage[] {
    const copied: BrewInstalledPackage[] = list.slice();
    // 不用 localeCompare：ArkTS 对它的支持没有保证，普通比较足够且结果稳定
    copied.sort((a: BrewInstalledPackage, b: BrewInstalledPackage) => {
      if (a.name === b.name) {
        return 0;
      }
      return a.name < b.name ? -1 : 1;
    });
    return copied;
  }
}
