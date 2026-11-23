/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

/**
 * `brew install --dry-run` / `brew upgrade --dry-run` 输出解析器 v3（纯函数层，Agent Skill 预演共用）。
 *
 * 设备实测（brew 7.0.9_7，2026-11-23，`brew install --dry-run wget` exit 0）：
 *   ==> Would install 1 formula:
 *   wget 1.25.0_2
 *   ==> Would upgrade 1 dependency for wget:
 *   node
 * 即**表头与清单分行**是当前常态，且 install 预演附带「连带依赖升级」段
 * （`Would upgrade N dependency(s) for <parent>:`，条目同样分行，只有名字）。
 * 表头前还有整段 tap-trust 警告块（裸行如 `harmony/ohos`），收集态之外一律无视。
 * 历史内联形态（`==> Would install 1 formula: wget 1.25.0_2`、
 * `==> Would upgrade 1 outdated package: wget 1.25.0_2 -> 1.26.0`）同样收。
 *
 * 不存在的包：`Error: No formulae found for X.`（exit 1）→ NOT_FOUND 判据（G7）。
 *
 * 本文件保持**零 import**、字符串常量而非 enum、无模板字符串：
 * `hmosword-build/brew-skill/audit_skill_no_exec.mjs` 会把本文件原样拷成 `.mts`
 * 在 node 里跑（Node 类型剥离），任何破坏这一点的改动都会让检查脚本先失败。
 * 与 J（装机预演）落地时共用同一解析器与同一组用例，格式漂移两处同源。
 */

/** 解析出的包类别。字符串常量（node 剥离约束），取值 'formula' | 'cask' | ''（未知/混合，由调用方按目录补齐） */
export const BREW_DRYRUN_KIND_FORMULA: string = 'formula';
export const BREW_DRYRUN_KIND_CASK: string = 'cask';

/** 收集态：install 清单条目用 itemOf，upgrade 清单条目用 itemOfUpgrade（兼容 `旧 -> 新`） */
const COLLECT_INSTALL: string = 'install';
const COLLECT_UPGRADE: string = 'upgrade';

/** Would install / Would upgrade 清单里的一条（`name version`；version 可能缺省） */
export class BrewDryRunItem {
  public name: string = '';
  public version: string = '';
  public kind: string = '';
  /** 升级预演的旧版本（`name 旧版本 -> 新版本` 形态）。安装预演与依赖升级条目恒为空串 */
  public fromVersion: string = '';
}

/** 一次 dry-run 输出的解析结果 */
export class BrewDryRunResult {
  /** 清单解析成功（不代表安装/升级会成功——dry-run 本身不动盘） */
  public ok: boolean = false;
  public wouldInstall: BrewDryRunItem[] = [];
  /** brew 自己报的数量（install 段与连带升级段累加；可能多于实际条目），只作展示，不作判据 */
  public declaredCount: number = 0;
  /** brew 明确说没有这个包（NOT_FOUND 分支的判据，G7） */
  public notFound: boolean = false;
  /** 失败摘要：Error 行原文或「没有 Would 行」，只进回包 errMsg */
  public failureMessage: string = '';
}

export class BrewDryRunParser {
  /** 终端着色由 BrewCli 的 HOMEBREW_COLOR 环境位决定，进来先剥一遍 ANSI */
  private static readonly ANSI_RE: RegExp = /\x1b\[[0-9;]*[A-Za-z]/g;
  /** install 表头：`==> Would install 1 formula: wget 1.25.0_2`（内联）或 `==> Would install 1 formula:`（分行） */
  private static readonly WOULD_INSTALL_RE: RegExp =
    /Would install\s+(\d+)\s+(formulae|formulas|formula|casks|cask)\s*:?\s*(.*)/i;
  /** 升级表头：`==> Would upgrade 2 outdated packages: wget 1.25.0_2 -> 1.26.0`（内联/分行都收） */
  private static readonly WOULD_UPGRADE_RE: RegExp =
    /Would upgrade\s+(\d+)\s+(outdated\s+)?(formulae|formulas|formula|casks|cask|packages|package)\s*:?\s*(.*)/i;
  /** 连带依赖升级段（brew 7 设备实测）：`==> Would upgrade 1 dependency for <parent>:`，kind 未知留空。
   *  注意 `dependenc(?:y|ies)`：`dependencies?` 的 `?` 只作用于 s，配不上单数 dependency */
  private static readonly WOULD_UPGRADE_DEP_RE: RegExp =
    /Would upgrade\s+(\d+)\s+dependenc(?:y|ies)\s+for\s+\S+\s*:?\s*(.*)/i;
  private static readonly ERROR_RE: RegExp = /Error:\s*(.*)/i;
  private static readonly NOT_FOUND_RE: RegExp =
    /(No available formula|No available cask|No formulae found|No similarly named|was not found|nonexistent)/i;

  public static parse(stdout: string): BrewDryRunResult {
    const result: BrewDryRunResult = new BrewDryRunResult();
    const clean: string = stdout.replace(BrewDryRunParser.ANSI_RE, '');
    const lines: string[] = clean.split('\n');
    // 收集态：表头命中后开启，遇到空行 / 新表头（==>）/ Warning / Error 收束。
    // 收集态里每行是一个条目（可带版本、可带 -> 旧版本），不再是普通文本。
    let collectState: string = '';
    let collectKind: string = '';
    for (const line of lines) {
      if (collectState.length > 0) {
        const text: string = line.trim();
        if (text.length === 0 || text.startsWith('==>') ||
          text.startsWith('Warning') || text.startsWith('Error')) {
          collectState = '';
        } else {
          const item: BrewDryRunItem = collectState === COLLECT_INSTALL
            ? BrewDryRunParser.itemOf(text, collectKind)
            : BrewDryRunParser.itemOfUpgrade(text, collectKind);
          if (item.name.length > 0) {
            result.wouldInstall.push(item);
          }
          continue;
        }
      }
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
          BrewDryRunParser.pushInline(result, list, kind, false);
        }
        collectState = COLLECT_INSTALL;
        collectKind = kind;
        continue;
      }
      const depMatch: RegExpMatchArray | null = line.match(BrewDryRunParser.WOULD_UPGRADE_DEP_RE);
      if (depMatch !== null) {
        const count: number = parseInt(depMatch[1], 10);
        if (!isNaN(count)) {
          result.declaredCount = result.declaredCount + count;
        }
        const list: string = depMatch[2].trim();
        if (list.length > 0) {
          BrewDryRunParser.pushInline(result, list, '', true);
        }
        collectState = COLLECT_UPGRADE;
        collectKind = '';
        continue;
      }
      const upgradeMatch: RegExpMatchArray | null = line.match(BrewDryRunParser.WOULD_UPGRADE_RE);
      if (upgradeMatch !== null) {
        const count: number = parseInt(upgradeMatch[1], 10);
        if (!isNaN(count)) {
          result.declaredCount = result.declaredCount + count;
        }
        const kindWord: string = upgradeMatch[3].toLowerCase();
        const kind: string = kindWord.indexOf('cask') >= 0 ? BREW_DRYRUN_KIND_CASK :
          (kindWord.indexOf('formula') >= 0 ? BREW_DRYRUN_KIND_FORMULA : '');
        const list: string = upgradeMatch[4].trim();
        if (list.length > 0) {
          BrewDryRunParser.pushInline(result, list, kind, true);
        }
        collectState = COLLECT_UPGRADE;
        collectKind = kind;
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

  /** 表头内联清单（`aom 3.9.1, dav1d 1.5.0`）。upgrade 形态走 itemOfUpgrade（兼容 `旧 -> 新`） */
  private static pushInline(result: BrewDryRunResult, list: string, kind: string,
    upgradeStyle: boolean): void {
    const parts: string[] = list.split(',');
    for (const part of parts) {
      const item: BrewDryRunItem = upgradeStyle
        ? BrewDryRunParser.itemOfUpgrade(part, kind)
        : BrewDryRunParser.itemOf(part, kind);
      if (item.name.length > 0) {
        result.wouldInstall.push(item);
      }
    }
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

  /** `wget 1.25.0_2 -> 1.26.0` -> item（带旧版本）；没有 `->` 时退化为「名字 + 版本」 */
  private static itemOfUpgrade(part: string, kind: string): BrewDryRunItem {
    const item: BrewDryRunItem = new BrewDryRunItem();
    const fields: string[] = part.trim().split(/\s+/);
    if (fields.length === 0 || fields[0].length === 0) {
      return item;
    }
    item.name = fields[0];
    item.kind = kind;
    let arrowAt: number = -1;
    for (let index: number = 1; index < fields.length; index++) {
      if (fields[index] === '->') {
        arrowAt = index;
        break;
      }
    }
    if (arrowAt > 1) {
      item.fromVersion = fields[arrowAt - 1];
      if (fields.length > arrowAt + 1) {
        item.version = fields[arrowAt + 1];
      }
    } else if (fields.length > 1) {
      item.version = fields[1];
    }
    return item;
  }
}
