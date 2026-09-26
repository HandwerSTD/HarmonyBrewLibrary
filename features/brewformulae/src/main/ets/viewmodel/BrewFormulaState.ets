/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { BaseHomeState } from '@ohos/commonbusiness';
import { BrewFormulaCardSource } from './BrewFormulaCardSource';

export class BrewFormulaState extends BaseHomeState {
  public cardSource: BrewFormulaCardSource = new BrewFormulaCardSource();
  public sections: WaterFlowSections = new WaterFlowSections();

  public constructor() {
    super();
  }
}
