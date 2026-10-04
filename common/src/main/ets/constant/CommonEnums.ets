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

/**
 * Loading status enum.
 */
export enum LoadingStatus {
  IDLE = 'idle',
  OFF = 'off',
  LOADING = 'loading',
  /**
   * 正在建立本地数据（首次安装要先把包描述列表拉下来）。
   *
   * 与 `LOADING` 分开是因为两者的等待时长差两个数量级：`LOADING` 是百毫秒级的单次请求，
   * 只给转圈就够；`BUILDING` 是几十秒到几分钟的整表下载，必须给出说明与取消等待的预期。
   */
  BUILDING = 'building',
  SUCCESS = 'success',
  FAILED = 'failed',
  NO_NETWORK = 'no_network',
  EMPTY_DATA = 'empty_data',
  /**
   * 数据源确认没有这个包（详情页单条取数 404 / 410）。
   *
   * 与 `FAILED` 分开：`FAILED` 是取数失败，重试有意义；`NOT_FOUND` 是数据源给出的确定结论，
   * 重试只有在数据源自身的数据变了之后才有意义。两者的文案与日志也不同。
   */
  NOT_FOUND = 'not_found',
}

/**
 * GridRow column.
 */
export enum ColumnEnum {
  SM = 4,
  MD = 8,
  LG = 12,
  XL = 12,
}

/**
 * Module name.
 */

export enum ModuleNameEnum {
  COMPONENT_LIST = 'componentListView',
  COMPONENT_DETAIL = 'componentDetailView',
  CODE_PREVIEW = 'codePreview',
  ARTICLE_DETAIL = 'articleDetail',
}

/**
 * Web component scroll direction
 */
export enum ScrollDirectionEnum {
  UP = 'up',
  DOWN = 'down'
}

export enum ProductSeriesEnum {
  HPR = 'HPR', // foldable PC
  VDE = 'VDE',
  HAD = 'HAD',
}

export enum StorageKey {
  UI_CONTEXT = 'hmos_world_UIContext',
  COLOR_MODE = 'hmos_world_SystemColorMode',
  GLOBAL_INFO = 'hmos_world_GlobalInfoModel',
  BUNDLE_INFO = 'hmos_world_BundleInfoData',
  WEB_LOADING = 'hmos_world_WebIsLoading',
  IS_PLAYING = 'hmos_world_IsPlaying',
  CURRENT_TAB = 'hmos_world_CurrentTabIndex',
  BLUE_RENDER_GROUP = 'hmos_world_BlurRenderGroup',
  HOME_PAGE_CONTEXT = 'hmos_world_PageContext',
  MINE_PAGE_CONTEXT = 'hmos_world_MinePageContext',
  BREW_FORMULA_PAGE_CONTEXT = 'hmos_world_BrewFormulaPageContext',
  BREW_DISCOVER_PAGE_CONTEXT = 'hmos_world_BrewDiscoverPageContext',
  BREW_CASK_PAGE_CONTEXT = 'hmos_world_BrewCaskPageContext',
  /** 搜索页自己的页面栈。**不能与任何页签共用** —— 共用会让两个栈串起来（见 handover §3.3） */
  BREW_SEARCH_PAGE_CONTEXT = 'hmos_world_BrewSearchPageContext',
  ACCOUNT_USER_ID = 'hmos_world_account_user_id',
  IS_IMAGE_DEFAULT_SIZE = 'hmos_world_Image_Is_Default_Size',
  // IntentFramework:
  CONTEXT_ENTRY = 'hmos_world_Context_EntryAbility',
  IS_SIDEBAR_LAYOUT = 'hmos_world_isSideBarLayout',
  /** 设备执行通道（brew cli）是否可用。由 entry 的 UIAbility 注入，未注入时为 false */
  BREW_CLI_ENABLED = 'hmos_world_brewCliEnabled',
}