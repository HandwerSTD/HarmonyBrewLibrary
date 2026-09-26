/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { BrewKind, BrewPackageItem } from '@ohos/brewcommon';

/**
 * 结果行。`BrewPackageRow` 需要 `kind`（它透传给 `BrewPackageIcon` 决定符号颜色），
 * 而 `BrewPackageItem` 里没有这个字段 —— 所以这里包一层。
 */
export class BrewSearchRow {
  public kind: BrewKind = BrewKind.FORMULA;
  public item: BrewPackageItem = new BrewPackageItem();

  constructor(kind: BrewKind, item: BrewPackageItem) {
    this.kind = kind;
    this.item = item;
  }
}

/**
 * 结果列表的 `LazyForEach` 数据源。形状与 `BrewPackageItemSource` 一致
 * （同为 `IDataSource`），差别只在元素类型多带了 `kind`。
 *
 * 换数据必须走 `setDataArray`：它替换数组**并通知**已注册的监听者重载 ——
 * 直接改私有数组不会触发 `List` 刷新。
 */
export class BrewSearchRowSource implements IDataSource {
  private rows: BrewSearchRow[] = [];
  private listeners: DataChangeListener[] = [];

  public setDataArray(rows: BrewSearchRow[]): void {
    this.rows = rows;
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataReloaded();
    });
  }

  totalCount(): number {
    return this.rows.length;
  }

  getData(index: number): BrewSearchRow {
    if (index >= 0 && index < this.rows.length) {
      return this.rows[index];
    }
    return new BrewSearchRow(BrewKind.FORMULA, new BrewPackageItem());
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
