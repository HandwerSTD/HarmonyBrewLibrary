/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { BrewCategoryCard } from '@ohos/brewcommon';

export class BrewFormulaCardSource implements IDataSource {
  private cardList: BrewCategoryCard[] = [];
  private listeners: DataChangeListener[] = [];

  public setDataArray(dataArray: BrewCategoryCard[]): void {
    this.cardList = dataArray;
  }

  public totalCount(): number {
    return this.cardList.length;
  }

  public getData(index: number): BrewCategoryCard {
    if (index >= 0 && index < this.cardList.length) {
      return this.cardList[index];
    }
    return new BrewCategoryCard();
  }

  public registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  public unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos: number = this.listeners.indexOf(listener);
    if (pos >= 0) {
      this.listeners.splice(pos, 1);
    }
  }
}
