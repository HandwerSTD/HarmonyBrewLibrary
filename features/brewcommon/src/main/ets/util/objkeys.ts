/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
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
 * `Object.keys` 的包装。
 *
 * 官方文档明确：ArkTS 下 `Object.keys` 不能直接作用于 `Object` 类型，
 * 需要把该调用单独抽离到 `.ts` 文件再 import。`preferences.getAllSync()` 返回的正是 `Object`，
 * 所以 `BrewSourcePrefs.keys()` / `stats()` 必须走这里。
 */
export function objKeys(obj: Object): string[] {
  return Object.keys(obj);
}
