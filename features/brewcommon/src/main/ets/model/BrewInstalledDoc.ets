/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

/**
 * `brew info --json=v2 --installed` 的输出形状。
 *
 * 字段名与设备上 Homebrew 源码的投影一一对应，改字段前先核对这个位置：
 * `Library/Homebrew/formula.rb` 的 `to_hash`（`installed` 数组在 `installed_kegs` 一段）。
 *
 * 只声明本层真正读的字段。上游的字段远不止这些，多声明一个就多一处会失效的假设。
 */

/** formula 的一个已安装版本（`installed_kegs` 的投影） */
export interface BrewInstalledKegDoc {
  version: string;
  /** 由 bottle 安装。顶层没有 `poured_from_bottle`，用它填 `pouredFromBottle` */
  built_as_bottle?: boolean;
  /** 安装时刻，Unix 秒 */
  time?: number;
  installed_on_request?: boolean;
}

/** formula 的版本集合 */
export interface BrewVersionsDoc {
  stable?: string;
}

/** formula 条目。只取本机包需要的字段 */
export interface BrewFormulaDoc {
  name: string;
  full_name?: string;
  versions?: BrewVersionsDoc;
  installed?: BrewInstalledKegDoc[];
  outdated?: boolean;
}

/** cask 条目。本机不支持 cask，声明它只为在解析时明确丢弃 */
export interface BrewCaskDoc {
  token: string;
}

/** 命令输出整体 */
export interface BrewInstalledDoc {
  formulae?: BrewFormulaDoc[];
  casks?: BrewCaskDoc[];
}
