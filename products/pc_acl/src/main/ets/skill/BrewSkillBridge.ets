/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { Logger } from '@ohos/common';
import { ShellUtils } from '@ohos/pcnative';
import type { ShellResult } from '@ohos/pcnative';
import {
  BrewCli,
  BrewCommandGenerator,
  BrewDryRunParser,
  BrewInstalledLoader,
  BrewKindText,
  BrewSearchModel,
  BrewTable,
  SKILL_BREW_TIMEOUT_MS,
  SKILL_SEARCH_LIMIT,
} from '@ohos/brewcommon';
import type { BrewDryRunResult } from '@ohos/brewcommon';
import type { BrewInstalledPackage } from '@ohos/brewcommon';
import type { BrewSearchResult } from '@ohos/brewcommon';

const TAG: string = '[skill]';

/** searchPackages 回包里的一行（SKILL.md data.rows[].） */
export class SkillSearchRow {
  public name: string = '';
  public kind: string = '';
  public desc: string = '';
}

/** queryPackage 回包（SKILL.md data）。installed 状态来自盘上快照——冻结口径，asOf 是快照时刻 */
export class SkillQueryResult {
  public token: string = '';
  public kind: string = '';
  public desc: string = '';
  public inCatalog: boolean = false;
  public installed: boolean = false;
  public version: string = '';
  public latestVersion: string = '';
  public outdated: boolean = false;
  /** 盘上快照的读取时刻（epoch ms）；0 = 没有快照（从未打开过本机包管理） */
  public asOf: number = 0;
}

/** 预演清单里的一条（SKILL.md data.wouldInstall[].） */
export class SkillPreviewItem {
  public name: string = '';
  public version: string = '';
  public kind: string = '';
}

/** previewInstall / requestInstall 共用的回包（SKILL.md data） */
export class SkillPreviewResult {
  public ok: boolean = false;
  public items: SkillPreviewItem[] = [];
  public declaredCount: number = 0;
  public notFound: boolean = false;
  public failureMessage: string = '';
  /** 实际下发的命令行（`brew install --dry-run ...`），进回包供小艺转述，可溯源 */
  public cmdline: string = '';
  public exitCode: number = 0;
}

/**
 * Skill 脚本的唯一业务出口（headless，spec 2026-11-22-agent-skill-spec.md §3.4）。
 *
 * 裁决记录（2026-11-22，需求方裁定）：**本层零 UI 触点**——不 import UI 符号、不写
 * AppStorage/preferences、不拉起应用、不碰 `BrewCommandRunner` / `BrewCommandSheet`。
 * 「人类点头」落在应用详情页既有的安装按钮上；`audit_skill_no_exec.mjs` 把这些禁令锁死。
 *
 * 唯一允许的命令是 `brew install --dry-run`（只读预演）。命令行经 `BrewCli.commandLine`
 * 与执行通道同一份环境前缀拼装，但**不走** `BrewCommandRunner`（那是写命令的执行层，
 * 带 Sheet 状态机，Skill 场景既不需要也不允许）。
 */
export class BrewSkillBridge {
  /**
   * 关键词找包。同步内存检索（BrewSearchModel 全程不发请求），冷启动时先补目录。
   * 返回条数受 SKILL_SEARCH_LIMIT 限制；总数信息由调用方按 rows.length 转述。
   */
  public static async searchPackages(keyword: string): Promise<SkillSearchRow[]> {
    const started: number = Date.now();
    await BrewSkillBridge.ensureCatalog();
    const result: BrewSearchResult = await BrewSearchModel.getInstance().search(keyword);
    const rows: SkillSearchRow[] = [];
    const hits = result.hits;
    const cap: number = hits.length < SKILL_SEARCH_LIMIT ? hits.length : SKILL_SEARCH_LIMIT;
    for (let i = 0; i < cap; i++) {
      const row: SkillSearchRow = new SkillSearchRow();
      row.name = hits[i].token;
      row.kind = hits[i].kind;
      row.desc = hits[i].desc;
      rows.push(row);
    }
    Logger.info(TAG, 'search total=' + result.total + ' rows=' + rows.length +
      ' ms=' + (Date.now() - started));
    return rows;
  }

  /**
   * 包的状态与详情。目录侧给 kind 与描述；安装状态只读**盘上快照**（冻结口径），
   * 冷启动可读，不执行任何刷新命令。快照缺失时 installed=false、asOf=0，由小艺如实转述。
   */
  public static async queryPackage(token: string): Promise<SkillQueryResult> {
    const started: number = Date.now();
    const result: SkillQueryResult = new SkillQueryResult();
    result.token = token;
    await BrewSkillBridge.ensureCatalog();
    if (BrewSkillBridge.hasToken(BrewKindText.FORMULA, token)) {
      result.kind = BrewKindText.FORMULA;
      result.inCatalog = true;
      result.desc = BrewTable.descOf(BrewKindText.FORMULA, token);
    } else if (BrewSkillBridge.hasToken(BrewKindText.CASK, token)) {
      result.kind = BrewKindText.CASK;
      result.inCatalog = true;
      result.desc = BrewTable.descOf(BrewKindText.CASK, token);
    }
    const snapshot = BrewInstalledLoader.snapshot();
    if (snapshot !== null) {
      result.asOf = snapshot.readAt;
      const pkg: BrewInstalledPackage | null = BrewInstalledLoader.installedOf(token);
      if (pkg !== null) {
        result.installed = true;
        result.version = pkg.version;
        result.latestVersion = pkg.latestVersion;
        result.outdated = pkg.outdated;
        if (result.kind.length === 0) {
          result.kind = pkg.kind;
        }
      }
    }
    Logger.info(TAG, 'query token=' + token + ' inCatalog=' + result.inCatalog +
      ' installed=' + result.installed + ' outdated=' + result.outdated +
      ' ms=' + (Date.now() - started));
    return result;
  }

  /**
   * 预演：装下去会发生什么。**只读，不动盘**——`brew install --dry-run` 一条命令，
   * 清单解析与 J（装机预演）共用 BrewDryRunParser。
   *
   * G7 快路径：目录就绪且无此 token 时不跑命令直接回 notFound——目录是冻结口径，
   * 编造的包名到不了 brew，slopsquatting 面在 Skill 边界上就收口。
   */
  public static async previewInstall(token: string): Promise<SkillPreviewResult> {
    const started: number = Date.now();
    const result: SkillPreviewResult = new SkillPreviewResult();
    const catalogReady: boolean = await BrewSkillBridge.ensureCatalog();
    let kindFound: string = '';
    if (catalogReady) {
      if (BrewSkillBridge.hasToken(BrewKindText.FORMULA, token)) {
        kindFound = BrewKindText.FORMULA;
      } else if (BrewSkillBridge.hasToken(BrewKindText.CASK, token)) {
        kindFound = BrewKindText.CASK;
      } else {
        result.notFound = true;
        result.failureMessage = 'token not in catalog';
        Logger.info(TAG, 'preview token=' + token + ' notFound=catalog-fast-path');
        return result;
      }
    }
    if (!BrewCli.isReady()) {
      result.failureMessage = 'brew is unavailable';
      Logger.warn(TAG, 'preview rejected, brew is not ready, token=' + token);
      return result;
    }
    // 与安装同一份拼装（installArgs）+ --dry-run 尾缀；tap 信息目录侧没有，
    // 官方 tap 之外的 qualified name 本来就进不了目录快路径，此处按裸 token 拼，brew 自己裁决。
    const kind: string = kindFound.length > 0 ? kindFound : BrewKindText.FORMULA;
    const dryRunArgs: string = BrewCommandGenerator.installArgs(kind, token, '') + ' --dry-run';
    result.cmdline = 'brew ' + dryRunArgs;
    const shellResult: ShellResult =
      await ShellUtils.run(BrewCli.commandLine(dryRunArgs), SKILL_BREW_TIMEOUT_MS);
    result.exitCode = shellResult.exitCode;
    const parsed: BrewDryRunResult =
      BrewDryRunParser.parse(shellResult.stdout + '\n' + shellResult.stderr);
    if (shellResult.ok && parsed.ok) {
      result.ok = true;
      result.declaredCount = parsed.declaredCount;
      for (const item of parsed.wouldInstall) {
        const one: SkillPreviewItem = new SkillPreviewItem();
        one.name = item.name;
        one.version = item.version;
        one.kind = item.kind;
        result.items.push(one);
      }
      Logger.info(TAG, 'preview token=' + token + ' ok items=' + result.items.length +
        ' declared=' + result.declaredCount + ' ms=' + (Date.now() - started));
    } else {
      result.notFound = parsed.notFound;
      result.failureMessage = parsed.failureMessage.length > 0
        ? parsed.failureMessage
        : BrewSkillBridge.tailOf(shellResult.stderr, 200);
      Logger.warn(TAG, 'preview token=' + token + ' failed exit=' + shellResult.exitCode +
        ' notFound=' + result.notFound + ' reason=' + result.failureMessage);
    }
    return result;
  }

  /** 目录是否就绪。未就绪先补一次目录（网络），仍不就绪返回 false，由调用方降级（G11） */
  private static async ensureCatalog(): Promise<boolean> {
    if (BrewSkillBridge.catalogReady()) {
      return true;
    }
    try {
      await BrewTable.refresh();
    } catch (err) {
      const error = err as Error;
      Logger.warn(TAG, 'catalog refresh failed, reason=' + error.message);
    }
    return BrewSkillBridge.catalogReady();
  }

  /** 描述片就绪或任一类别浏览集非空都算可检索（与 BrewSearchModel 的口径一致） */
  private static catalogReady(): boolean {
    return BrewTable.descReady() ||
      BrewTable.rows(BrewKindText.FORMULA).length > 0 ||
      BrewTable.rows(BrewKindText.CASK).length > 0;
  }

  private static hasToken(kind: string, token: string): boolean {
    const rows = BrewTable.rows(kind);
    for (const row of rows) {
      if (row.token === token) {
        return true;
      }
    }
    return false;
  }

  /** 错误摘要只留尾部，避免把整段 stderr 塞进回包 */
  private static tailOf(text: string, max: number): string {
    if (text.length <= max) {
      return text.trim();
    }
    return text.substring(text.length - max).trim();
  }
}
