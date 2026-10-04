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

import { BrewKind } from '@ohos/brewcommon';
import type { BrewInstalledPackage } from '@ohos/brewcommon';
import { BrewInstalledLoader } from '@ohos/brewcommon';
import type { BrewInstalledSets } from '@ohos/brewcommon';
import { MinePackageSets, PackageListMode } from '../model/MinePackagesModels';

/**
 * 本机包集合的取数口径。**「我的」首页与它的子页面共用这一份** ——
 * 见 `MinePackageSets` 的注释：两处各算一次迟早会让「卡片预览」和「查看全部」的首项不一致。
 */
export class MinePackagesUtil {
  /**
   * 一次取齐三个集合。
   *
   * 数据来自设备上的 brew 命令（`brew info --json=v2 --installed`），
   * 由 `BrewInstalledLoader` 负责执行、解析与进程内缓存。
   *
   * 读取失败会抛异常，失败分类在 `error.message` 里；调用方转成页面的失败态。
   * 「我的」页的 `loadLocalPackages` 只记日志不改成错误态（本机包只是整页的一部分），
   * 二级页 `MinePackagesVM` 则把它当作整页失败。
   */
  public static async loadSets(): Promise<MinePackageSets> {
    const sets: MinePackageSets = new MinePackageSets();
    const loaded: BrewInstalledSets = await BrewInstalledLoader.loadSets();
    sets.installed = loaded.installed;
    sets.outdated = loaded.outdated;
    sets.updated = loaded.updated;
    return sets;
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
