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
import { MinePackageSets, PackageListMode } from '../model/MinePackagesModels';

/**
 * 本机包集合的取数口径。**「我的」首页与它的子页面共用这一份** ——
 * 见 `MinePackageSets` 的注释：两处各算一次迟早会让「卡片预览」和「查看全部」的首项不一致。
 */
export class MinePackagesUtil {
  /**
   * 一次取齐三个集合。**当前恒为空集**（2026-10 起）。
   *
   * 为什么是空集：HarmonyOS 上没有 brew，也没有可执行的本机包管理接口（不像 macOS 能跑
   * `brew list` / `brew outdated`），而原读的那三份内置 mock（`brew-local-*.json`）已随
   * 整条 mock 链路删除。所以本机包数据**只能**来自将来真机上可用的能力（e.g. 命令行 +
   * 权限，或 Harmonybrew 侧的安装记录）。
   *
   * 所以这里是**空态保壳**而不是删代码：「我的」页的三个区块、「本机包」二级页、筛选 chips
   * 全部保留，显示 0 个包 / 空列表。签名不变 → 将来接上真实数据源时只需改这一个方法，
   * `pick` / `filter` / `byName` 与全部 UI 都不用动。
   */
  public static loadSets(): Promise<MinePackageSets> {
    return Promise.resolve(new MinePackageSets());
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
