/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

/**
 * `brew config` 输出解析器（纯函数层，Agent Skill 的 brew 状态自检专用）。
 *
 * 只抽四个稳定键：HOMEBREW_VERSION / HOMEBREW_PREFIX / HOMEBREW_CELLAR / Core tap HEAD。
 * API 模式下 Core tap 行可能整段缺席，按缺省空串处理，不影响 ok 判定。
 * 本文件保持**零 import**、字符串常量而非 enum、无模板字符串：
 * `hmosword-build/brew-skill/audit_skill_no_exec.mjs` 会把本文件原样拷成 `.mts`
 * 在 node 里跑（Node 类型剥离），任何破坏这一点的改动都会让检查脚本先失败。
 */

/** 一次 `brew config` 输出的解析结果 */
export class BrewConfigResult {
  /** 至少抽到了 HOMEBREW_VERSION 行 */
  public ok: boolean = false;
  public version: string = '';
  public prefix: string = '';
  public cellar: string = '';
  /** API 模式下可能为空串 */
  public coreTapHead: string = '';
  /** 抽不到版本行时的摘要，只进回包 errMsg */
  public failureMessage: string = '';
}

export class BrewConfigParser {
  /** 终端着色由 BrewCli 的 HOMEBREW_COLOR 环境位决定，进来先剥一遍 ANSI */
  private static readonly ANSI_RE: RegExp = /\x1b\[[0-9;]*[A-Za-z]/g;

  private static readonly KEY_VERSION: string = 'HOMEBREW_VERSION';
  private static readonly KEY_PREFIX: string = 'HOMEBREW_PREFIX';
  private static readonly KEY_CELLAR: string = 'HOMEBREW_CELLAR';
  private static readonly KEY_CORE_TAP: string = 'Core tap HEAD';

  public static parse(stdout: string): BrewConfigResult {
    const result: BrewConfigResult = new BrewConfigResult();
    const clean: string = stdout.replace(BrewConfigParser.ANSI_RE, '');
    const lines: string[] = clean.split('\n');
    for (const line of lines) {
      const text: string = line.trim();
      if (result.version.length === 0) {
        result.version = BrewConfigParser.valueOf(text, BrewConfigParser.KEY_VERSION);
      }
      if (result.prefix.length === 0) {
        result.prefix = BrewConfigParser.valueOf(text, BrewConfigParser.KEY_PREFIX);
      }
      if (result.cellar.length === 0) {
        result.cellar = BrewConfigParser.valueOf(text, BrewConfigParser.KEY_CELLAR);
      }
      if (result.coreTapHead.length === 0) {
        result.coreTapHead = BrewConfigParser.valueOf(text, BrewConfigParser.KEY_CORE_TAP);
      }
    }
    result.ok = result.version.length > 0;
    if (!result.ok) {
      result.failureMessage = 'no HOMEBREW_VERSION line in output';
    }
    return result;
  }

  /** `HOMEBREW_VERSION: 4.4.1` -> `4.4.1`。键不匹配返回空串 */
  private static valueOf(line: string, key: string): string {
    if (line.indexOf(key) !== 0) {
      return '';
    }
    const rest: string = line.substring(key.length).trim();
    if (rest.indexOf(':') === 0) {
      return rest.substring(1).trim();
    }
    return rest;
  }
}
