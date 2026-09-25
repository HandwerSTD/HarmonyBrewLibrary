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

/**
 * `MockRequest` 的 trigger：值即 `rawfile/mockdata/<trigger>.json` 的文件名。
 *
 * 挂顶点（`request()` 的调用点）与被删除的条目要一起看：**删掉枚举成员之前先确认
 * `grep "TriggerEnums.<成员>"` 为空**，否则会把一次「请求静默失败」留在代码里。
 */
export enum TriggerEnums {
  // Homebrew marketplace - remote
  BREW_DISCOVER_PAGE = 'brew-discover-page',

  // Homebrew marketplace - local machine state (currently Mock)
  BREW_LOCAL_FORMULAE = 'brew-local-formulae',
  BREW_LOCAL_CASKS = 'brew-local-casks',
  BREW_LOCAL_OUTDATED = 'brew-local-outdated',
}
