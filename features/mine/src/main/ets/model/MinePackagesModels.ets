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

import type { BrewInstalledPackage } from '@ohos/brewcommon';

/**
 * 本机包列表页的三种模式，由路由参数决定。
 *
 * 三个入口（「我的」页的已安装行、待更新卡片、已更新卡片）**共用一个页面**：
 * 页面结构与交互完全相同，差别只有「取哪个集合」和「标题叫什么」。
 * 三个页面各自实现会让筛选 chips、空态、加载态、返回处理各写三遍。
 */
export enum PackageListMode {
  ALL = 'all',
  OUTDATED = 'outdated',
  UPDATED = 'updated',
}

export interface MinePackagesParams {
  mode: PackageListMode;
}

/**
 * 「我的」页用的三个本机包集合。
 *
 * **口径只在这里定义一次** ——「我的」首页的卡片预览与子页面的完整列表必须看到同一批包、
 * 同一个顺序，各算一次迟早会不一致（预览里是 A，点进「查看全部」看到的第一个却是 B）。
 */
export class MinePackageSets {
  /** 全部已安装，按名称排序 */
  public installed: BrewInstalledPackage[] = [];
  /** 有新版本可升级，按名称排序 */
  public outdated: BrewInstalledPackage[] = [];
  /**
   * 版本已是最新，按 installedAt 倒序（最近更新的排前面）。
   *
   * 为什么是「已安装 - 待更新」而不是「全部已安装按 installedAt 倒序」：
   * 后者与「已安装」是同一批包（60 个），两张卡片会列出完全相同的包，只是顺序不同 ——
   * 用户一眼就能看出重复。取补集后 8 + 52 = 60，不重不漏，两张卡片各自都有意义；
   * 排序仍然按 recency，保留「最近更新」的语义。
   */
  public updated: BrewInstalledPackage[] = [];
}
