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

import { BrewPackageItem } from './BrewModels';

/**
 * 包列表的 `LazyForEach` 数据源（分类二级页用）。
 *
 * 为什么需要它：去掉前 100 硬裁切后，一个分类可以装下上千行（实测 Formulae 的 system 分类
 * 有 5,447 行）。`Scroll + Column + ForEach` 会把这上千行**一次性**构建出来，首屏与内存都难看；
 * `List` + `LazyForEach` 只构建可视区附近的行。而 `LazyForEach` 只认 `IDataSource`。
 *
 * 换数据必须走 `setDataArray`：它替换数组**并通知**已注册的监听者重载 —— 直接改私有数组
 * 不会触发 `List` 刷新（「只 setDataArray 不通知」的写法只有在数据源整体被外层条件重建时
 * 才碰巧能用；这里的 `List` 一直在，必须通知）。
 */
export class BrewPackageItemSource implements IDataSource {
  private items: BrewPackageItem[] = [];
  private listeners: DataChangeListener[] = [];

  /** 换一份数据并通知 `List` 重载（切分类、重新加载都走它） */
  public setDataArray(dataArray: BrewPackageItem[]): void {
    this.items = dataArray;
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataReloaded();
    });
  }

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): BrewPackageItem {
    if (index >= 0 && index < this.items.length) {
      return this.items[index];
    }
    return new BrewPackageItem();
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos: number = this.listeners.indexOf(listener);
    if (pos >= 0) {
      this.listeners.splice(pos, 1);
    }
  }
}
