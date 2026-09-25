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

import { TabBarType } from '@ohos/commonbusiness';

export interface TabBarData {
  id: TabBarType;
  title: ResourceStr;
  icon: Resource;
  /** 侧边栏是否展示。`true` = 只藏入口，`TabContent` 与 `TabBarType` 枚举值仍保留 */
  hidden?: boolean;
}

/**
 * 页签入口表。
 * 侧边栏（products/pc 的 CustomSideBar）按本数组顺序渲染，HdsTabs 按 `TabBarType` 的值取内容，
 * 因此这里的顺序决定侧边栏顺序，与枚举值无关。
 */
const ALL_TABS: TabBarData[] = [
  {
    id: TabBarType.DISCOVER,
    icon: $r('sys.symbol.discover_fill'),
    title: $r('app.string.tab_discover'),
  },
  {
    id: TabBarType.FORMULAE,
    icon: $r('sys.symbol.wrench_and_screwdriver_fill'),
    title: $r('app.string.tab_formulae'),
  },
  {
    id: TabBarType.CASKS,
    icon: $r('sys.symbol.scenes'),
    title: $r('app.string.tab_casks'),
  },
  {
    id: TabBarType.BREW_SEARCH,
    icon: $r('sys.symbol.magnifyingglass'),
    title: $r('app.string.tab_search'),
  },
  {
    id: TabBarType.MINE,
    icon: $r('sys.symbol.person_crop_circle_fill_1'),
    title: $r('app.string.tab_mine'),
  },
];

/**
 * 侧边栏 / 任何新页面渲染用的列表：滤掉 `hidden` 的入口。
 *
 * 注意**不能再拿 TabBarType 当它的下标**（`TABS_LIST[tabType]`）—— 过滤后下标与枚举值不再一一对应；
 * 需要按枚举取项的地方请用 `ALL_TABS_LIST` + `find`。
 */
export const TABS_LIST: TabBarData[] = ALL_TABS.filter((item: TabBarData) => !item.hidden);

/** 完整的入口表（含 hidden 的），供底部页签样式等按枚举取值的地方使用 */
export const ALL_TABS_LIST: TabBarData[] = ALL_TABS;

/** 冷启动默认页（同时也是所有外部拉起 App 的落点） */
export const DEFAULT_TAB: TabBarType = TabBarType.DISCOVER;
