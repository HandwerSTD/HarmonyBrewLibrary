/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { LoadingModel } from '@ohos/common';
import type { BrewDiscoverBoard } from '@ohos/brewcommon';

/**
 * 榜单二级页状态。**每个页面实例各自 new 一份**（见下面的构造注释与 view 里的用法）。
 *
 * 不复用 BrewDiscoverState：那个是首页的（WaterFlow sections / 卡片源 / 滚动位置），
 * 二级页是普通列表，两者没有共享字段，硬合并只会让两边都多出一堆用不到的字段。
 */
@Observed
export class BrewDiscoverBoardState {
  public loadingModel: LoadingModel = new LoadingModel();
  public boardId: number = 0;
  public board?: BrewDiscoverBoard = undefined;
  public snapshotDate: string = '';
}
