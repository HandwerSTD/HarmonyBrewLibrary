/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

/**
 * `brew install --dry-run` 输出解析器（纯函数层，Agent Skill 预演共用）。
 *
 * 设备实测样本（docs/knowledge/2026-11-21-brew-tap-trust.md）：
 *   `brew install --dry-run wget` → `==> Would install 1 formula: wget 1.25.0_2`
 *
 * 本文件保持**零 import**、字符串常量而非 enum、无模板字符串：
 * `hmosword-build/brew-skill/audit_skill_no_exec.mjs` 会把本文件原样拷成 `.mts`
 * 在 node 里跑（Node 类型剥离），任何破坏这一点的改动都会让检查脚本先失败。
 * 与 J（装机预演）落地时共用同一解析器与同一组用例，格式漂移两处同源。
 */

/** 解析出的包类别。字符串常量（node 剥离约束），取值 'formula' | 'cask' */
export const BREW_DRYRUN_KIND_FORMULA: string = 'formula';
export const BREW_DRYRUN_KIND_CASK: string = 'cask';

/** Would install 清单里的一条（`name version`；version 可能缺省） */
export class BrewDryRunItem {
  public name: string = '';
  public version: string = '';
  public kind: string = '';
}

/** 一次 dry-run 输出的解析结果 */
export class BrewDryRunResult {
  /** 清单解析成功（不代表安装成功——dry-run 本身不动盘） */
  public ok: boolean = false;
  public wouldInstall: BrewDryRunItem[] = [];
  /** brew 自己报的数量（可能多于实际条目，如清单换行时），只作展示，不作判据 */
  public declaredCount: number = 0;
  /** brew 明确说没有这个包（NOT_FOUND 分支的判据，G7） */
  public notFound: boolean = false;
  /** 失败摘要：Error 行原文或「没有 Would install 行」，只进回包 errMsg */
  public failureMessage: string = '';
}

export class BrewDryRunParser {
  /** 终端着色由 BrewCli 的 HOMEBREW_COLOR 环境位决定，进来先剥一遍 ANSI */
  private static readonly ANSI_RE: RegExp = /\x1b\[[0-9;]*[A-Za-z]/g;
  /** 设备实测行：`==> Would install 1 formula: wget 1.25.0_2`。单数/复数、formula/cask 都收 */
  private static readonly WOULD_INSTALL_RE: RegExp =
    /Would install\s+(\d+)\s+(formulae|formulas|formula|casks|cask)\s*:?\s*(.*)/i;
  private static readonly ERROR_RE: RegExp = /Error:\s*(.*)/i;
  private static readonly NOT_FOUND_RE: RegExp =
    /(No available formula|No available cask|No formulae found|No similarly named|was not found|nonexistent)/i;

  public static parse(stdout: string): BrewDryRunResult {
    const result: BrewDryRunResult = new BrewDryRunResult();
    const clean: string = stdout.replace(BrewDryRunParser.ANSI_RE, '');
    const lines: string[] = clean.split('\n');
    for (const line of lines) {
      const installMatch: RegExpMatchArray | null = line.match(BrewDryRunParser.WOULD_INSTALL_RE);
      if (installMatch !== null) {
        const count: number = parseInt(installMatch[1], 10);
        if (!isNaN(count)) {
          result.declaredCount = result.declaredCount + count;
        }
        const kindWord: string = installMatch[2].toLowerCase();
        const kind: string =
          kindWord.indexOf('cask') >= 0 ? BREW_DRYRUN_KIND_CASK : BREW_DRYRUN_KIND_FORMULA;
        const list: string = installMatch[3].trim();
        if (list.length > 0) {
          const parts: string[] = list.split(',');
          for (const part of parts) {
            const item: BrewDryRunItem = BrewDryRunParser.itemOf(part, kind);
            if (item.name.length > 0) {
              result.wouldInstall.push(item);
            }
          }
        }
        continue;
      }
      const errorMatch: RegExpMatchArray | null = line.match(BrewDryRunParser.ERROR_RE);
      if (errorMatch !== null && result.failureMessage.length === 0) {
        result.failureMessage = errorMatch[1].trim();
        if (line.match(BrewDryRunParser.NOT_FOUND_RE) !== null) {
          result.notFound = true;
        }
      }
    }
    if (result.wouldInstall.length > 0) {
      result.ok = true;
      result.notFound = false;
    } else if (result.failureMessage.length === 0) {
      result.failureMessage = 'no Would install line in output';
    }
    return result;
  }

  /** `wget 1.25.0_2` -> item；只认前两段（名字 / 版本），其余忽略 */
  private static itemOf(part: string, kind: string): BrewDryRunItem {
    const item: BrewDryRunItem = new BrewDryRunItem();
    const fields: string[] = part.trim().split(/\s+/);
    if (fields.length > 0 && fields[0].length > 0) {
      item.name = fields[0];
      item.kind = kind;
      if (fields.length > 1) {
        item.version = fields[1];
      }
    }
    return item;
  }
}
