/*
 * Copyright (c) 2024 Huawei Device Co., Ltd.
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

export enum PageEnum {
  MAIN_PAGE = 'MainPage',
  /**
   * 组件详情路由名。组件页模块（`features/componentlibrary`）已移除，本项与
   * `ComponentDetailParams` 一起保留：`commonbusiness` 的 banner 卡与 `BaseHomeViewModel.jumpBannerDetail`
   * 是公共组件库的一部分，将来注册同名路由即可直接复用。
   */
  COMPONENT_DETAIL_VIEW = 'ComponentDetailView',
  MINE_VIEW = 'MineView',
  MINE_SETTING_VIEW = 'MineSettingsView',
  /** AI 设置页（spec：AI Companion 底座，「我的 - 设置」与详情页 E1 引导共用） */
  MINE_AI_SETTINGS_VIEW = 'MineAiSettingsView',
  MINE_PACKAGES_VIEW = 'MinePackagesView',
  BREW_SOURCE_SETTING_VIEW = 'BrewSourceSettingView',
  BREW_SOURCE_EDIT_VIEW = 'BrewSourceEditView',
  // Homebrew 应用市场
  BREW_FORMULA_LIST_VIEW = 'BrewFormulaListView',
  BREW_CASK_LIST_VIEW = 'BrewCaskListView',
  /** 分类卡的「查看全部」完整列表（成员数超过卡片预览条数时才可达） */
  BREW_FORMULA_CATEGORY_VIEW = 'BrewFormulaCategoryView',
  /** 同上，Casks 侧（chips 选分类 + 该分类的全部成员） */
  BREW_CASK_CATEGORY_VIEW = 'BrewCaskCategoryView',
  // 详情页 formula / cask 共用同一个路由，包类型由路由参数里的 kind 区分
  // （原 BREW_FORMULA_DETAIL_VIEW / BREW_CASK_DETAIL_VIEW 两个常量已合并为此项）
  BREW_DETAIL_VIEW = 'BrewDetailView',
  /** Discover 单张榜的完整列表（卡片的「查看全部」） */
  BREW_DISCOVER_LIST_VIEW = 'BrewDiscoverListView',
  BREW_DISCOVER_BOARD_VIEW = 'BrewDiscoverBoardView',
  /** 搜索结果页（侧边栏搜索框触达，不属于任何页签） */
  BREW_SEARCH_RESULT_VIEW = 'BrewSearchResultView',
}