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
