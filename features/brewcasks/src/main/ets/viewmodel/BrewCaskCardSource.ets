/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { BrewCaskCard } from '@ohos/brewcommon';

/** 与 Formulae 的 `BrewFormulaCardSource` 同构，只是元素类型换成 Casks 的分类卡 */
export class BrewCaskCardSource implements IDataSource {
  private cardList: BrewCaskCard[] = [];
  private listeners: DataChangeListener[] = [];

  public setDataArray(dataArray: BrewCaskCard[]): void {
    this.cardList = dataArray;
  }

  public totalCount(): number {
    return this.cardList.length;
  }

  public getData(index: number): BrewCaskCard {
    if (index >= 0 && index < this.cardList.length) {
      return this.cardList[index];
    }
    return new BrewCaskCard();
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
