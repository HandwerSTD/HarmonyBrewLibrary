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

import { BrewFormat, BrewKind } from '@ohos/brewcommon';
import type { BrewDetailParams, BrewInstalledPackage } from '@ohos/brewcommon';
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
   * 本机包 -> 详情页路由参数。两个点击入口（「我的」页的卡片预览与「本机包」二级页）共用，
   * 避免 token 的口径各写一遍。
   *
   * `id` 传 0：本机数据里没有目录 id，详情取数层会用 `tokenId(token)` 派生（与目录条目派生出的
   * id 是同一个函数）。`categoryKey` 留空：由详情取数层按目录描述补算。
   */
  public static detailParamsOf(pkg: BrewInstalledPackage): BrewDetailParams {
    return {
      kind: BrewFormat.brewKindOf(pkg.kind),
      title: pkg.name,
      id: 0,
      token: pkg.name,
      categoryKey: '',
    };
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

  /**
   * 按隐藏 chip 过滤：去掉作为依赖安装的包。
   *
   * 谓词只看 `installedAsDependency`（解析自 brew 输出里最新 keg 的 `installed_on_request`）：
   * 不按包名判定，也不为三个集合各写一份 —— 三个集合的补集关系因此不会因过滤而改变。
   */
  public static visible(list: BrewInstalledPackage[], hideDependencies: boolean): BrewInstalledPackage[] {
    if (!hideDependencies) {
      return list;
    }
    return list.filter((pkg: BrewInstalledPackage) => !pkg.installedAsDependency);
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
