/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

/**
 * `brew uses --installed <token>` 输出解析器（纯函数层，Agent Skill 卸载预演专用）。
 *
 * 正常输出是「依赖它的已安装包名」每行一个；空输出 + 退出 0 = 没有别的已安装包依赖它，
 * 是合法结局而不是失败。本文件保持**零 import**、字符串常量而非 enum、无模板字符串：
 * `hmosword-build/brew-skill/audit_skill_no_exec.mjs` 会把本文件原样拷成 `.mts`
 * 在 node 里跑（Node 类型剥离），任何破坏这一点的改动都会让检查脚本先失败。
 */

/** 依赖者包名的字符形状（与 BrewCommandGenerator.isSafeName 同一口径，含 tap 前缀的 `/`） */
export const BREW_USES_NAME_RE: RegExp = /^[A-Za-z0-9][A-Za-z0-9@+._/-]*$/;

/** 一次 `brew uses` 输出的解析结果 */
export class BrewUsesResult {
  /** 依赖它的已安装包名。可能为空 = 没有别的包依赖它（合法） */
  public names: string[] = [];
  /** 输出解析正常（没有 Error 行）。与 names 是否为空无关 */
  public ok: boolean = false;
  /** Error 行原文，只进回包摘要与日志 */
  public failureMessage: string = '';
}

export class BrewUsesParser {
  /** 终端着色由 BrewCli 的 HOMEBREW_COLOR 环境位决定，进来先剥一遍 ANSI */
  private static readonly ANSI_RE: RegExp = /\x1b\[[0-9;]*[A-Za-z]/g;
  private static readonly ERROR_RE: RegExp = /Error:\s*(.*)/i;

  public static parse(stdout: string): BrewUsesResult {
    const result: BrewUsesResult = new BrewUsesResult();
    const clean: string = stdout.replace(BrewUsesParser.ANSI_RE, '');
    const lines: string[] = clean.split('\n');
    for (const line of lines) {
      const text: string = line.trim();
      if (text.length === 0) {
        continue;
      }
      const errorMatch: RegExpMatchArray | null = text.match(BrewUsesParser.ERROR_RE);
      if (errorMatch !== null) {
        if (result.failureMessage.length === 0) {
          result.failureMessage = errorMatch[1].trim();
        }
        continue;
      }
      // brew 的提示行（==> / Warning）不是依赖者名字
      if (text.indexOf('==> ') === 0 || text.indexOf('Warning') === 0) {
        continue;
      }
      const head: string = text.split(/\s+/)[0];
      if (head.match(BREW_USES_NAME_RE) !== null) {
        result.names.push(head);
      }
    }
    result.ok = result.failureMessage.length === 0;
    return result;
  }
}
