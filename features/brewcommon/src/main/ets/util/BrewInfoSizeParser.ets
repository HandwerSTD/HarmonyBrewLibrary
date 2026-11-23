/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

/**
 * `brew info <name...>`（多包文本）输出解析器（纯函数层，Agent Skill 预演 sizes 补测专用）。
 *
 * 设备实测（brew 7.0.9_7，2026-11-23）——已安装的包每个版本一行：
 *   acl 2.4.0 (67 files, 548.2KB) [Linked]
 *   alsa-lib 1.2.16.1_1 (147 files, 1.9MB) [Linked]
 * 行首就是包名，映射天然自带；未安装的包没有这种行 → 无占用数据（诚实缺省）。
 * 多包一次命令（`brew info a b c`），Ruby 启动成本只付一次。
 *
 * 本文件保持**零 import**、字符串常量而非 enum、无模板字符串：
 * `hmosword-build/brew-skill/audit_skill_no_exec.mjs` 会把本文件原样拷成 `.mts`
 * 在 node 里跑（Node 类型剥离），任何破坏这一点的改动都会让检查脚本先失败。
 */

/** 一个已安装版本的当前占用 */
export class BrewInfoSize {
  public name: string = '';
  public version: string = '';
  /** 文件数 */
  public files: number = 0;
  /** brew 原文的体积串（如 `548.2KB` / `1.9MB`），直接转述 */
  public sizeText: string = '';
}

export class BrewInfoSizeResult {
  public sizes: BrewInfoSize[] = [];
}

export class BrewInfoSizeParser {
  /** 终端着色由 BrewCli 的 HOMEBREW_COLOR 环境位决定，进来先剥一遍 ANSI */
  private static readonly ANSI_RE: RegExp = /\x1b\[[0-9;]*[A-Za-z]/g;
  /**
   * 版本占用行：`acl 2.4.0 (67 files, 548.2KB) [Linked]`；
   * outdated 包是**箭头形态**（设备实测 git-lfs）：
   * `git-lfs 3.8.0_1 → 3.8.1 (82 files, 14.6MB) [Linked]`——已装版本与最新版都在行内，
   * 体积归属已装版本，version 捕获已装版本、箭头段跳过。`[Linked]` 等后缀不进捕获。
   * 大包的文件数带**千分位逗号**（`6,869 files` / `23,904 files`，设备实测 openssl@4 /
   * ohos-sdk-native），files 组收 `[\d,]+` 再去逗号取整。版本与 `(` 之间可能是多空格。
   * 只匹配这种行：未安装的包不产生它，天然表达「无数据」。
   */
  private static readonly SIZE_LINE_RE: RegExp =
    /^([A-Za-z0-9][A-Za-z0-9@+._/-]*)\s+(\S+)(?:\s+(?:→|->)\s+\S+)?\s+\(([\d,]+)\s+files?,\s+([^)]+)\)/;

  public static parse(stdout: string): BrewInfoSizeResult {
    const result: BrewInfoSizeResult = new BrewInfoSizeResult();
    const clean: string = stdout.replace(BrewInfoSizeParser.ANSI_RE, '');
    const lines: string[] = clean.split('\n');
    // 同名同版本的占用行去重（设备实测 python@3.15 的段落出现两次）
    const seen: Set<string> = new Set<string>();
    for (const line of lines) {
      const match: RegExpMatchArray | null = line.trim().match(BrewInfoSizeParser.SIZE_LINE_RE);
      if (match === null) {
        continue;
      }
      const files: number = parseInt(match[3].replace(/,/g, ''), 10);
      if (isNaN(files)) {
        continue;
      }
      const key: string = match[1] + '@' + match[2];
      if (seen.has(key)) {
        continue;
      }
      seen.add(key);
      const size: BrewInfoSize = new BrewInfoSize();
      size.name = match[1];
      size.version = match[2];
      size.files = files;
      size.sizeText = match[4].trim();
      result.sizes.push(size);
    }
    return result;
  }
}
