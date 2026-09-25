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
 * Harmonybrew payload 中 formula 的原始形状。
 *
 * 这是解包器的输入 DTO，不是应用对外模型：Task 4 的 HarmonybrewMap 才负责把它归一化。
 * *_args 按 fork 实际生成的调用参数声明为 Object[]，避免把 Ruby DSL 的数组/对象两种形态
 * 错写成一种固定数组类型。
 */
export interface HarmonybrewFormula {
  desc?: string;
  homepage?: string;
  license?: string;
  stable_version?: string;
  head_url_args?: Object[];
  bottle_checksum?: string;
  bottle_rebuild?: number;
  keg_only_args?: Object[];
  /**
   * `deprecate!` / `disable!` 的**哈希**参数（不是调用参数数组，与其它 `*_args` 不同）。
   * 实测形状：`{":date":"2024-07-07",":because":":unmaintained",":replacement_formula":"x"}`。
   * 键带前导冒号（Ruby symbol 的字面形式）。
   */
  deprecate_args?: Record<string, string>;
  disable_args?: Record<string, string>;
  versioned_formulae?: string[];
  aliases?: string[];
  executables?: string[];
  caveats?: string;
  stable_dependencies?: Object[];
  stable_uses_from_macos?: Object[];
  conflicts?: Object[];
  service_run_args?: Object[];
}
