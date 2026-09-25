/*
 * Copyright (c) 2024 Huawei Device Co., Ltd.
 * Licensed under the Apache License,Version 2.0 (the "License");
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

// TabContent views is dark StatusBar or not.
// 索引与 TabBarType 一一对应：MINE / DISCOVER / FORMULAE / CASKS / BREW_SEARCH
/**
 * 每个页签的「状态栏是否按浅色内容绘制」，**按下标取**（下标 === `TabBarType` 值）。
 * 新增页签枚举值时必须同步在**末尾**追加一项，否则该页签取到 `undefined`（falsy），
 * 状态栏颜色会静默变成另一个页签的口径。
 */
export const TAB_CONTENT_STATUSES: boolean[] = [false, true, true, true, true];

export enum TabBarType {
  MINE = 0,
  /** 以下为 Homebrew 应用市场入口（Discover 联网探索） */
  DISCOVER = 1,
  FORMULAE = 2,
  CASKS = 3,
  /**
   * 搜索页签。**必须追加在末尾**：`TAB_CONTENT_STATUSES` 按下标取，
   * `HomeView.TabContentsBuilder()` 的 TabContent 顺序也按枚举值排（见 TabBarModel 的注释）。
   */
  BREW_SEARCH = 4,
}