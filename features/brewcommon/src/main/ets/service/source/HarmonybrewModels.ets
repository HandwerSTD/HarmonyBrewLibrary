/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
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
