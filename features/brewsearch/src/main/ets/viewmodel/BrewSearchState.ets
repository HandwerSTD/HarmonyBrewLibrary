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

import type { BrewSearchResult } from '@ohos/brewcommon';

/**
 * 搜索页的**每页实例**状态。
 *
 * 为什么不能放单例 VM：搜索态关掉再进来是**新的页面实例**，共享一份状态会让新页面
 * 先渲染出上一次的结果（详情页正是这么踩的：handover §10.4.1）。
 * 所以 `result` 也在这里，而不是在 `BrewSearchVM` 里。
 */
export class BrewSearchState {
  /** 原始关键字（含大小写与空白；归一化交给引擎） */
  public keyword: string = '';
  /** chips 选中项，对应 `BrewSearchVM.chips()` 的下标 */
  public filterIndex: number = 0;
  /** 命中总数（截断前），用于「共 N 个结果」 */
  public total: number = 0;
  /** 元数据索引是否就绪（false → 顶部提示条） */
  public indexReady: boolean = true;
  /** 行是仅凭 desc 索引造出来的（目录缺失） */
  public rowsFromIndexOnly: boolean = false;
  /** 本页最近一次搜索结果。与 hits 等长同序的 items 也在这里面 */
  public result?: BrewSearchResult = undefined;
}
