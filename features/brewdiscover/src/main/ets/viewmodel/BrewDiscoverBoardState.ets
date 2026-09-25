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
