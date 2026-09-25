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
 * 目录聚合输入的叶子类型。
 *
 * 放在独立模块里，避免适配器为了复用 BrewService 内部的 CatalogProbeResult
 * 而反向 import BrewService；BrewService 后续只负责把本类型映射成既有探针结果。
 */
export interface BrewCatalogInput {
  kind: string;
  win: string;
  url: string;
  text: string;
  lastModified: string;
}
