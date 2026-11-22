/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { Logger } from '@ohos/common';
import { ShellUtils } from '@ohos/pcnative';
import type { ShellResult } from '@ohos/pcnative';
import {
  BrewCaskModel,
  BrewCli,
  BrewCommandGenerator,
  BrewConfigParser,
  BrewDocAbsentError,
  BrewDryRunParser,
  BrewFormulaModel,
  BrewInstalledLoader,
  BrewKindText,
  BrewSearchModel,
  BrewTable,
  BrewUsesParser,
  SKILL_BREW_QUICK_TIMEOUT_MS,
  SKILL_BREW_TIMEOUT_MS,
  SKILL_CAVEATS_MAX_CHARS,
  SKILL_LIST_LIMIT,
  SKILL_SEARCH_LIMIT,
  SKILL_TRENDING_LIMIT,
  SKILL_USAGE_LIMIT,
  TldrService,
} from '@ohos/brewcommon';
import type { BrewCaskDetail } from '@ohos/brewcommon';
import type { BrewConfigResult } from '@ohos/brewcommon';
import type { BrewDryRunResult } from '@ohos/brewcommon';
import type { BrewFormulaDetail } from '@ohos/brewcommon';
import type { BrewInstalledPackage } from '@ohos/brewcommon';
import type { BrewInstalledSets } from '@ohos/brewcommon';
import type { BrewSearchResult } from '@ohos/brewcommon';
import type { BrewUsesResult } from '@ohos/brewcommon';
import type { CatalogEntry } from '@ohos/brewcommon';
import type { CatalogKindMeta } from '@ohos/brewcommon';
import type { TldrPage } from '@ohos/brewcommon';

const TAG: string = '[skill]';

// ------------------------------------------------------------ 回包模型

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

/** 预演清单里的一条。fromVersion 只在升级预演有值（旧版本），安装预演恒为空串 */
export class SkillPreviewItem {
  public name: string = '';
  public version: string = '';
  public kind: string = '';
  public fromVersion: string = '';
}

/** previewInstall / requestInstall / previewUpgrade / previewUpgradeAll 共用的回包（SKILL.md data） */
export class SkillPreviewResult {
  public ok: boolean = false;
  public items: SkillPreviewItem[] = [];
  public declaredCount: number = 0;
  public notFound: boolean = false;
  /** 命令成功退出但没有可执行的升级（已是最新）。仅升级预演会出现 */
  public nothingToDo: boolean = false;
  /** 快照口径下这个包还没装（仅 previewUpgrade 会给出，不跑命令） */
  public notInstalled: boolean = false;
  public failureMessage: string = '';
  /** 实际下发的命令行（`brew ... --dry-run`），进回包供小艺转述，可溯源 */
  public cmdline: string = '';
  public exitCode: number = 0;
}

/** listInstalled / listOutdated 回包里的一行（盘上快照口径） */
export class SkillInstalledRow {
  public name: string = '';
  public kind: string = '';
  public version: string = '';
  public latestVersion: string = '';
  public outdated: boolean = false;
  public installedAsDependency: boolean = false;
}

/** listInstalled 回包（SKILL.md data） */
export class SkillListResult {
  public hasSnapshot: boolean = false;
  public asOf: number = 0;
  public total: number = 0;
  public formulaCount: number = 0;
  public caskCount: number = 0;
  public outdatedCount: number = 0;
  public rows: SkillInstalledRow[] = [];
  public failureMessage: string = '';
}

/** listOutdated 回包（SKILL.md data） */
export class SkillOutdatedResult {
  public hasSnapshot: boolean = false;
  public asOf: number = 0;
  public total: number = 0;
  public rows: SkillInstalledRow[] = [];
  public failureMessage: string = '';
}

/** packageDetail 回包（SKILL.md data）。详情来自现网单条，安装状态来自盘上快照 */
export class SkillDetailResult {
  public token: string = '';
  public kind: string = '';
  public desc: string = '';
  public version: string = '';
  public homepage: string = '';
  public license: string = '';
  public categoryKey: string = '';
  public installs30d: number = 0;
  public dependencies: string[] = [];
  /** 安装后的注意事项摘要（超长截断） */
  public caveats: string = '';
  public deprecated: boolean = false;
  public deprecationReason: string = '';
  public disabled: boolean = false;
  public disableReason: string = '';
  public installed: boolean = false;
  public installedVersion: string = '';
  public outdated: boolean = false;
  public asOf: number = 0;
  public notFound: boolean = false;
  public failureMessage: string = '';
}

/** packageUsage 回包里的一条示例（tldr 页的 `- 说明` + 命令原文） */
export class SkillUsageRow {
  public desc: string = '';
  public code: string = '';
  public hasPlaceholder: boolean = false;
}

/** packageUsage 回包。tldr 是增强层：found=false 不算错误 */
export class SkillUsageResult {
  public token: string = '';
  public found: boolean = false;
  public locale: string = '';
  public summary: string = '';
  public examples: SkillUsageRow[] = [];
}

/** listTrending 回包里的一条 */
export class SkillTrendingRow {
  public rank: number = 0;
  public token: string = '';
  public desc: string = '';
  public installs30d: number = 0;
  public installs365d: number = 0;
  /** 仅 trending 榜有意义，其余榜为 0 */
  public score: number = 0;
}

/** listTrending 回包（SKILL.md data） */
export class SkillTrendingResult {
  public board: string = '';
  public kind: string = '';
  public state: string = '';
  public windowStart: string = '';
  public windowEnd: string = '';
  public rows: SkillTrendingRow[] = [];
}

/** listCategories 回包里的一条 */
export class SkillCategoryRow {
  public categoryKey: string = '';
  public name: string = '';
  public itemCount: number = 0;
}

/** listCategories 回包（SKILL.md data） */
export class SkillCategoriesResult {
  public state: string = '';
  public formula: SkillCategoryRow[] = [];
  public cask: SkillCategoryRow[] = [];
}

/** checkBrew 回包（SKILL.md data）。自检回包永远成功，事实由字段承载 */
export class SkillBrewStatus {
  public ready: boolean = false;
  public enabled: boolean = false;
  public shellAvailable: boolean = false;
  public brewPath: string = '';
  public prefix: string = '';
  public version: string = '';
  public configOk: boolean = false;
  public failureMessage: string = '';
}

/** previewUninstall 回包（SKILL.md data）。只读推导（快照 + brew uses），绝不执行卸载命令 */
export class SkillUninstallResult {
  public token: string = '';
  public kind: string = '';
  /** 'not_installed' | 'needs_confirmation' */
  public status: string = '';
  public version: string = '';
  /** 展示用的计划命令行，只转述不执行 */
  public plannedCommand: string = '';
  /** 依赖它的已安装包名（formula 才查） */
  public dependents: string[] = [];
  public usesOk: boolean = false;
  public asOf: number = 0;
  public notFound: boolean = false;
  public failureMessage: string = '';
}

// ------------------------------------------------------------ 业务出口

/**
 * Skill 脚本的唯一业务出口（headless，spec 2026-11-22-agent-skill-spec.md §3.4 +
 * 2026-11-23 v2 能力面扩充）。
 *
 * 裁决记录（2026-11-22，需求方裁定）：**本层零 UI 触点**——不 import UI 符号、不写
 * AppStorage/preferences、不拉起应用、不碰 `BrewCommandRunner` / `BrewCommandSheet`。
 * 「人类点头」落在应用详情页既有的安装按钮上；`audit_skill_no_exec.mjs` 把这些禁令锁死。
 *
 * v2 裁决记录（2026-11-23，需求方裁定「能暴露的都暴露」）：只读能力全部放开；
 * 写操作**只许以 dry-run 预演**进入本层。命令执行收口在两个私有helper上：
 *   - `runDryRun`：唯一允许的命令尾巴是 `--dry-run`；
 *   - `runRead`：只读白名单（uses --installed / config / info），任何写命令进不来。
 * 审计脚本以「ShellUtils.run 调用点数量 === 2」锁死这条不变量。
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
    // 与安装同一份拼装（installArgs）；tap 信息目录侧没有，官方 tap 之外的 qualified name
    // 本来就进不了目录快路径，此处按裸 token 拼，brew 自己裁决。
    const kind: string = kindFound.length > 0 ? kindFound : BrewKindText.FORMULA;
    const args: string = BrewCommandGenerator.installArgs(kind, token, '');
    result.cmdline = 'brew ' + args + ' --dry-run';
    const shellResult: ShellResult = await BrewSkillBridge.runDryRun(args);
    result.exitCode = shellResult.exitCode;
    const parsed: BrewDryRunResult =
      BrewDryRunParser.parse(shellResult.stdout + '\n' + shellResult.stderr);
    if (shellResult.ok && parsed.ok) {
      result.ok = true;
      result.declaredCount = parsed.declaredCount;
      BrewSkillBridge.fillPreviewItems(result, parsed);
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

  /**
   * 已装清单。数据是**盘上快照**（冻结口径）；快照缺失时读一次命令补齐
   * （`brew info --json=v2 --installed`，BrewInstalledLoader 内部自带并发合并与快照写入）。
   * filter 支持 all / formula / cask / outdated / updated；query 按包名子串过滤。
   */
  public static async listInstalled(filter: string, query: string,
    limit: number): Promise<SkillListResult> {
    const started: number = Date.now();
    const result: SkillListResult = new SkillListResult();
    const sets: BrewInstalledSets | null = await BrewSkillBridge.installedSets();
    if (sets === null) {
      result.failureMessage = 'brew is unavailable';
      Logger.warn(TAG, 'listInstalled rejected, brew is not ready');
      return result;
    }
    result.hasSnapshot = true;
    const snapshot = BrewInstalledLoader.snapshot();
    result.asOf = snapshot !== null ? snapshot.readAt : 0;
    result.total = sets.installed.length;
    result.outdatedCount = sets.outdated.length;
    for (const pkg of sets.installed) {
      if (pkg.kind === BrewKindText.FORMULA) {
        result.formulaCount++;
      } else if (pkg.kind === BrewKindText.CASK) {
        result.caskCount++;
      }
    }
    const normalized: string = query.trim().toLowerCase();
    const cap: number = BrewSkillBridge.capOf(limit, SKILL_LIST_LIMIT, 50);
    for (const pkg of sets.installed) {
      if (result.rows.length >= cap) {
        break;
      }
      if (!BrewSkillBridge.matchesFilter(filter, pkg)) {
        continue;
      }
      if (normalized.length > 0 && pkg.name.toLowerCase().indexOf(normalized) < 0) {
        continue;
      }
      result.rows.push(BrewSkillBridge.rowOf(pkg));
    }
    Logger.info(TAG, 'listInstalled filter=' + filter + ' query=' + normalized +
      ' total=' + result.total + ' rows=' + result.rows.length + ' ms=' + (Date.now() - started));
    return result;
  }

  /** 待更新清单。同一份盘上快照的 outdated 集合，冻结口径 */
  public static async listOutdated(): Promise<SkillOutdatedResult> {
    const started: number = Date.now();
    const result: SkillOutdatedResult = new SkillOutdatedResult();
    const sets: BrewInstalledSets | null = await BrewSkillBridge.installedSets();
    if (sets === null) {
      result.failureMessage = 'brew is unavailable';
      Logger.warn(TAG, 'listOutdated rejected, brew is not ready');
      return result;
    }
    result.hasSnapshot = true;
    const snapshot = BrewInstalledLoader.snapshot();
    result.asOf = snapshot !== null ? snapshot.readAt : 0;
    result.total = sets.outdated.length;
    for (const pkg of sets.outdated) {
      result.rows.push(BrewSkillBridge.rowOf(pkg));
    }
    Logger.info(TAG, 'listOutdated total=' + result.total + ' ms=' + (Date.now() - started));
    return result;
  }

  /**
   * 预演：升级一个包会发生什么。**只读**——`brew upgrade --dry-run`。
   * 快照口径下没装的包不跑命令（notInstalled），已是最新时回 nothingToDo。
   */
  public static async previewUpgrade(token: string): Promise<SkillPreviewResult> {
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
        Logger.info(TAG, 'upgrade token=' + token + ' notFound=catalog-fast-path');
        return result;
      }
    }
    const pkg: BrewInstalledPackage | null = BrewInstalledLoader.installedOf(token);
    if (pkg !== null && kindFound.length === 0) {
      kindFound = pkg.kind;
    }
    const snapshot = BrewInstalledLoader.snapshot();
    if (snapshot !== null && pkg === null) {
      // 冻结口径：快照里没有它就不跑必然失败的命令；kind 都定不下来的编造名字同样挡住
      result.notInstalled = true;
      if (kindFound.length === 0 && catalogReady === false) {
        result.notFound = true;
        result.notInstalled = false;
      }
      Logger.info(TAG, 'upgrade token=' + token + ' notInstalled=snapshot-fast-path');
      return result;
    }
    if (!BrewCli.isReady()) {
      result.failureMessage = 'brew is unavailable';
      Logger.warn(TAG, 'upgrade rejected, brew is not ready, token=' + token);
      return result;
    }
    const kind: string = kindFound.length > 0 ? kindFound : BrewKindText.FORMULA;
    const args: string = BrewCommandGenerator.upgradeArgs(kind, token, '');
    result.cmdline = 'brew ' + args + ' --dry-run';
    const shellResult: ShellResult = await BrewSkillBridge.runDryRun(args);
    result.exitCode = shellResult.exitCode;
    const parsed: BrewDryRunResult =
      BrewDryRunParser.parse(shellResult.stdout + '\n' + shellResult.stderr);
    if (shellResult.ok && parsed.ok) {
      result.ok = true;
      result.declaredCount = parsed.declaredCount;
      BrewSkillBridge.fillPreviewItems(result, parsed);
      Logger.info(TAG, 'upgrade token=' + token + ' ok items=' + result.items.length +
        ' ms=' + (Date.now() - started));
    } else if (shellResult.ok && parsed.failureMessage === 'no Would install line in output') {
      // 命令成功退出但没有 Would 行 = 无可升级（已是最新）
      result.ok = true;
      result.nothingToDo = true;
      Logger.info(TAG, 'upgrade token=' + token + ' nothingToDo ms=' + (Date.now() - started));
    } else {
      result.notFound = parsed.notFound;
      result.failureMessage = parsed.failureMessage.length > 0
        ? parsed.failureMessage
        : BrewSkillBridge.tailOf(shellResult.stderr, 200);
      Logger.warn(TAG, 'upgrade token=' + token + ' failed exit=' + shellResult.exitCode +
        ' reason=' + result.failureMessage);
    }
    return result;
  }

  /**
   * 预演：批量升级会发生什么。**只读**——`brew upgrade [--formula|--cask] --dry-run`。
   * scope：all / formula / cask。
   */
  public static async previewUpgradeAll(scope: string): Promise<SkillPreviewResult> {
    const started: number = Date.now();
    const result: SkillPreviewResult = new SkillPreviewResult();
    if (!BrewCli.isReady()) {
      result.failureMessage = 'brew is unavailable';
      Logger.warn(TAG, 'upgradeAll rejected, brew is not ready');
      return result;
    }
    const index: number = scope === 'formula' ? 1 : (scope === 'cask' ? 2 : 0);
    const args: string = BrewCommandGenerator.upgradeAllArgs(index);
    result.cmdline = 'brew ' + args + ' --dry-run';
    const shellResult: ShellResult = await BrewSkillBridge.runDryRun(args);
    result.exitCode = shellResult.exitCode;
    const parsed: BrewDryRunResult =
      BrewDryRunParser.parse(shellResult.stdout + '\n' + shellResult.stderr);
    if (shellResult.ok && parsed.ok) {
      result.ok = true;
      result.declaredCount = parsed.declaredCount;
      BrewSkillBridge.fillPreviewItems(result, parsed);
      Logger.info(TAG, 'upgradeAll scope=' + scope + ' ok items=' + result.items.length +
        ' ms=' + (Date.now() - started));
    } else if (shellResult.ok && parsed.failureMessage === 'no Would install line in output') {
      result.ok = true;
      result.nothingToDo = true;
      Logger.info(TAG, 'upgradeAll scope=' + scope + ' nothingToDo ms=' + (Date.now() - started));
    } else {
      result.failureMessage = parsed.failureMessage.length > 0
        ? parsed.failureMessage
        : BrewSkillBridge.tailOf(shellResult.stderr, 200);
      Logger.warn(TAG, 'upgradeAll scope=' + scope + ' failed exit=' + shellResult.exitCode +
        ' reason=' + result.failureMessage);
    }
    return result;
  }

  /**
   * 卸载影响评估。**只读推导，绝不执行卸载命令**：
   *   - 安装事实来自盘上快照（冻结口径）；没装 → not_installed，不跑任何命令；
   *   - 反向依赖来自只读命令 `brew uses --installed <token>`（仅 formula）；
   *   - plannedCommand 是展示用的计划命令行，只转述不执行。
   */
  public static async previewUninstall(token: string): Promise<SkillUninstallResult> {
    const started: number = Date.now();
    const result: SkillUninstallResult = new SkillUninstallResult();
    result.token = token;
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
        Logger.info(TAG, 'uninstall token=' + token + ' notFound=catalog-fast-path');
        return result;
      }
    }
    const pkg: BrewInstalledPackage | null = BrewInstalledLoader.installedOf(token);
    const snapshot = BrewInstalledLoader.snapshot();
    result.asOf = snapshot !== null ? snapshot.readAt : 0;
    if (pkg === null) {
      result.status = 'not_installed';
      Logger.info(TAG, 'uninstall token=' + token + ' not_installed ms=' + (Date.now() - started));
      return result;
    }
    result.status = 'needs_confirmation';
    result.version = pkg.version;
    if (kindFound.length === 0) {
      kindFound = pkg.kind;
    }
    result.kind = kindFound;
    result.plannedCommand = BrewCommandGenerator.uninstallCommand(kindFound, token, '');
    if (kindFound === BrewKindText.FORMULA) {
      try {
        const shellResult: ShellResult =
          await BrewSkillBridge.runRead('uses --installed ' + token);
        const parsed: BrewUsesResult =
          BrewUsesParser.parse(shellResult.stdout + '\n' + shellResult.stderr);
        result.usesOk = shellResult.ok && parsed.ok;
        for (const name of parsed.names) {
          result.dependents.push(name);
        }
        if (!result.usesOk) {
          result.failureMessage = parsed.failureMessage.length > 0
            ? parsed.failureMessage
            : BrewSkillBridge.tailOf(shellResult.stderr, 200);
        }
      } catch (err) {
        const error = err as Error;
        result.usesOk = false;
        result.failureMessage = error.message;
        Logger.warn(TAG, 'uninstall uses failed, token=' + token + ' reason=' + error.message);
      }
    }
    Logger.info(TAG, 'uninstall token=' + token + ' dependents=' + result.dependents.length +
      ' ms=' + (Date.now() - started));
    return result;
  }

  /**
   * 包详情。现网单条（BrewRepository 的归一详情，带 1 小时缓存与失败回落）+
   * 盘上快照的安装状态。kind 判定顺序：目录 → 快照 → 按 formula 试、缺席换 cask 再试一次。
   */
  public static async packageDetail(token: string): Promise<SkillDetailResult> {
    const started: number = Date.now();
    const result: SkillDetailResult = new SkillDetailResult();
    result.token = token;
    const catalogReady: boolean = await BrewSkillBridge.ensureCatalog();
    let kind: string = '';
    let kindResolved: boolean = false;
    if (BrewSkillBridge.hasToken(BrewKindText.FORMULA, token)) {
      kind = BrewKindText.FORMULA;
      kindResolved = true;
    } else if (BrewSkillBridge.hasToken(BrewKindText.CASK, token)) {
      kind = BrewKindText.CASK;
      kindResolved = true;
    } else {
      const pkg: BrewInstalledPackage | null = BrewInstalledLoader.installedOf(token);
      if (pkg !== null) {
        kind = pkg.kind;
        kindResolved = true;
      }
    }
    if (!kindResolved && catalogReady) {
      result.notFound = true;
      result.failureMessage = 'token not in catalog';
      Logger.info(TAG, 'detail token=' + token + ' notFound=catalog-fast-path');
      return result;
    }
    if (kind.length === 0) {
      kind = BrewKindText.FORMULA;
    }
    try {
      const detail: SkillDetailResult = await BrewSkillBridge.detailOf(kind, token);
      Logger.info(TAG, 'detail token=' + token + ' kind=' + kind +
        ' ms=' + (Date.now() - started));
      return detail;
    } catch (err) {
      if (err instanceof BrewDocAbsentError) {
        if (!kindResolved) {
          // kind 是兜底猜的：换一边再试一次，仍缺席才按 notFound 收口
          const other: string = kind === BrewKindText.CASK ? BrewKindText.FORMULA : BrewKindText.CASK;
          try {
            const detail: SkillDetailResult = await BrewSkillBridge.detailOf(other, token);
            Logger.info(TAG, 'detail token=' + token + ' kind=' + other +
              ' ms=' + (Date.now() - started));
            return detail;
          } catch (inner) {
            if (inner instanceof BrewDocAbsentError) {
              result.notFound = true;
              result.failureMessage = 'doc absent upstream';
              return result;
            }
            throw inner;
          }
        }
        result.notFound = true;
        result.failureMessage = 'doc absent upstream';
        Logger.info(TAG, 'detail token=' + token + ' absent upstream');
        return result;
      }
      const error = err as Error;
      result.failureMessage = error.message.length > 0 ? error.message : 'detail fetch failed';
      Logger.warn(TAG, 'detail token=' + token + ' failed, reason=' + result.failureMessage);
      return result;
    }
  }

  /** 用法示例（tldr）。增强层：任何失败都收敛成 found=false，不产生错误 */
  public static async packageUsage(token: string): Promise<SkillUsageResult> {
    const started: number = Date.now();
    const result: SkillUsageResult = new SkillUsageResult();
    result.token = token;
    const noExecutables: string[] = [];
    const page: TldrPage | null = await TldrService.getInstance().get(token, noExecutables);
    if (page === null) {
      Logger.info(TAG, 'usage token=' + token + ' miss ms=' + (Date.now() - started));
      return result;
    }
    result.found = true;
    result.locale = page.locale;
    result.summary = BrewSkillBridge.clamp(page.summary, SKILL_CAVEATS_MAX_CHARS);
    const cap: number = page.examples.length < SKILL_USAGE_LIMIT
      ? page.examples.length
      : SKILL_USAGE_LIMIT;
    for (let i = 0; i < cap; i++) {
      const row: SkillUsageRow = new SkillUsageRow();
      row.desc = page.examples[i].desc;
      row.code = page.examples[i].code;
      row.hasPlaceholder = page.examples[i].hasPlaceholder;
      result.examples.push(row);
    }
    Logger.info(TAG, 'usage token=' + token + ' found examples=' + result.examples.length +
      ' ms=' + (Date.now() - started));
    return result;
  }

  /** 热门榜单（Discover 的三张榜之一）。同步读表，零请求 */
  public static async listTrending(board: string, kind: string,
    limit: number): Promise<SkillTrendingResult> {
    const started: number = Date.now();
    const result: SkillTrendingResult = new SkillTrendingResult();
    result.board = board;
    result.kind = kind;
    result.state = BrewTable.state();
    const meta: CatalogKindMeta | undefined = BrewTable.metaOf(kind);
    if (meta !== undefined) {
      result.windowStart = meta.windowStart;
      result.windowEnd = meta.windowEnd;
    }
    const cap: number = BrewSkillBridge.capOf(limit, SKILL_TRENDING_LIMIT, 50);
    const rows: CatalogEntry[] = BrewTable.boardRows(kind, board);
    const slice: number = rows.length < cap ? rows.length : cap;
    for (let i = 0; i < slice; i++) {
      const row: SkillTrendingRow = new SkillTrendingRow();
      row.rank = i + 1;
      row.token = rows[i].token;
      row.desc = BrewTable.descOf(kind, rows[i].token);
      row.installs30d = rows[i].vol30d;
      row.installs365d = rows[i].vol365d;
      row.score = rows[i].score;
      result.rows.push(row);
    }
    Logger.info(TAG, 'listTrending board=' + board + ' kind=' + kind + ' rows=' + result.rows.length +
      ' state=' + result.state + ' ms=' + (Date.now() - started));
    return result;
  }

  /** 分类清单（Formulae 与 Casks 的两级分类）。同步读表，零请求 */
  public static async listCategories(): Promise<SkillCategoriesResult> {
    const started: number = Date.now();
    const result: SkillCategoriesResult = new SkillCategoriesResult();
    result.state = BrewTable.state();
    for (const card of BrewTable.formulaBrowse()) {
      const row: SkillCategoryRow = new SkillCategoryRow();
      row.categoryKey = card.categoryKey;
      row.name = card.title;
      row.itemCount = card.itemCount;
      result.formula.push(row);
    }
    for (const category of BrewTable.caskBrowse()) {
      const row: SkillCategoryRow = new SkillCategoryRow();
      row.categoryKey = category.categoryKey;
      row.name = category.categoryName;
      // 构页时每个分类恰好一张卡，卡的 itemCount 就是该分类的总条数
      row.itemCount = category.caskCards.length > 0 ? category.caskCards[0].itemCount : 0;
      result.cask.push(row);
    }
    Logger.info(TAG, 'listCategories formula=' + result.formula.length +
      ' cask=' + result.cask.length + ' state=' + result.state +
      ' ms=' + (Date.now() - started));
    return result;
  }

  /** brew 状态自检：能力开关、shell 通道、可执行文件、`brew config` 的版本与前缀。 */
  public static async checkBrew(): Promise<SkillBrewStatus> {
    const started: number = Date.now();
    const result: SkillBrewStatus = new SkillBrewStatus();
    result.enabled = BrewCli.isEnabled();
    result.shellAvailable = ShellUtils.available();
    if (!result.enabled || !result.shellAvailable) {
      result.failureMessage = 'brew is unavailable';
      Logger.warn(TAG, 'checkBrew not ready, enabled=' + result.enabled +
        ' shell=' + result.shellAvailable);
      return result;
    }
    result.brewPath = BrewCli.brewPath();
    result.prefix = BrewCli.prefix();
    result.ready = BrewCli.isReady();
    if (!result.ready) {
      result.failureMessage = 'brew executable not found';
      return result;
    }
    try {
      const shellResult: ShellResult = await BrewSkillBridge.runRead('config');
      const parsed: BrewConfigResult =
        BrewConfigParser.parse(shellResult.stdout + '\n' + shellResult.stderr);
      result.version = parsed.version;
      result.configOk = shellResult.ok && parsed.ok;
      if (!result.configOk) {
        result.failureMessage = parsed.failureMessage.length > 0
          ? parsed.failureMessage
          : BrewSkillBridge.tailOf(shellResult.stderr, 200);
      }
    } catch (err) {
      const error = err as Error;
      result.configOk = false;
      result.failureMessage = error.message;
    }
    Logger.info(TAG, 'checkBrew ready=' + result.ready + ' version=' + result.version +
      ' configOk=' + result.configOk + ' ms=' + (Date.now() - started));
    return result;
  }

  // ------------------------------------------------------------ 私有：命令执行收口

  /**
   * 写命令的预演执行：唯一允许的命令尾巴是 `--dry-run`（G6 不变量，audit 锁死）。
   * 工作目录用 brew 的 prefix（与执行通道同一份口径，见 BrewCli.workingDirectory）。
   */
  private static async runDryRun(args: string): Promise<ShellResult> {
    return await ShellUtils.run(BrewCli.commandLine(args + ' --dry-run'),
      SKILL_BREW_TIMEOUT_MS, BrewCli.workingDirectory());
  }

  /**
   * 只读命令白名单执行（卸载预演的反向依赖查询 / brew 状态自检）。
   * 只许 uses --installed / config / info 这类读命令，任何写命令进不来。
   */
  private static async runRead(args: string): Promise<ShellResult> {
    const permitted: boolean = args === 'config' || args.startsWith('uses --installed ') ||
      args.startsWith('info ');
    if (!permitted) {
      Logger.warn(TAG, 'read command rejected: ' + args);
      throw new Error('read command not allowed: ' + args);
    }
    return await ShellUtils.run(BrewCli.commandLine(args),
      SKILL_BREW_QUICK_TIMEOUT_MS, BrewCli.workingDirectory());
  }

  // ------------------------------------------------------------ 私有：共用

  /**
   * 盘上快照的三个集合。快照缺失时读一次命令补齐（BrewInstalledLoader 内部自带
   * 并发合并与「写命令期间不写快照」的保护）。能力关闭或读取失败返回 null。
   */
  private static async installedSets(): Promise<BrewInstalledSets | null> {
    if (!BrewCli.isEnabled()) {
      return null;
    }
    const snapshot = BrewInstalledLoader.snapshot();
    if (snapshot !== null) {
      return snapshot.sets;
    }
    try {
      return await BrewInstalledLoader.loadSets(false);
    } catch (err) {
      const error = err as Error;
      Logger.warn(TAG, 'installed load failed, reason=' + error.message);
      return null;
    }
  }

  /** kind 判定（目录 → 快照）后的单条取数。失败抛错，BrewDocAbsentError 表示上游确认没这个包 */
  private static async detailOf(kind: string, token: string): Promise<SkillDetailResult> {
    if (kind === BrewKindText.CASK) {
      const detail: BrewCaskDetail = await BrewCaskModel.getInstance().getCaskDetail(0, token);
      return BrewSkillBridge.detailFromCask(token, detail);
    }
    const detail: BrewFormulaDetail =
      await BrewFormulaModel.getInstance().getFormulaDetail(0, token);
    return BrewSkillBridge.detailFromFormula(token, detail);
  }

  private static detailFromFormula(token: string, detail: BrewFormulaDetail): SkillDetailResult {
    const result: SkillDetailResult = new SkillDetailResult();
    result.token = token;
    result.kind = BrewKindText.FORMULA;
    result.desc = detail.desc;
    result.version = detail.stableVersion;
    result.homepage = detail.homepage;
    result.license = detail.license;
    result.categoryKey = detail.categoryKey;
    result.installs30d = detail.installs30d;
    for (const dep of detail.dependencies) {
      result.dependencies.push(dep.name);
    }
    result.caveats = BrewSkillBridge.clamp(detail.caveats, SKILL_CAVEATS_MAX_CHARS);
    result.deprecated = detail.deprecated;
    result.deprecationReason = detail.deprecationReason;
    result.disabled = detail.disabled;
    result.disableReason = detail.disableReason;
    BrewSkillBridge.mergeInstalled(result, token);
    return result;
  }

  private static detailFromCask(token: string, detail: BrewCaskDetail): SkillDetailResult {
    const result: SkillDetailResult = new SkillDetailResult();
    result.token = token;
    result.kind = BrewKindText.CASK;
    result.desc = detail.desc;
    result.version = detail.version;
    result.homepage = detail.homepage;
    result.categoryKey = detail.categoryKey;
    result.installs30d = detail.installs30d;
    if (detail.dependsOn !== undefined) {
      if (detail.dependsOn.formula !== undefined) {
        for (const dep of detail.dependsOn.formula) {
          result.dependencies.push(dep.name);
        }
      }
      if (detail.dependsOn.cask !== undefined) {
        for (const dep of detail.dependsOn.cask) {
          result.dependencies.push(dep.name);
        }
      }
    }
    result.caveats = BrewSkillBridge.clamp(detail.caveats, SKILL_CAVEATS_MAX_CHARS);
    result.deprecated = detail.deprecated;
    result.deprecationReason = detail.deprecationReason;
    result.disabled = detail.disabled;
    result.disableReason = detail.disableReason;
    BrewSkillBridge.mergeInstalled(result, token);
    return result;
  }

  /** 把盘上快照的安装状态合并进详情回包（冻结口径，asOf 是快照时刻） */
  private static mergeInstalled(result: SkillDetailResult, token: string): void {
    const snapshot = BrewInstalledLoader.snapshot();
    if (snapshot === null) {
      return;
    }
    result.asOf = snapshot.readAt;
    const pkg: BrewInstalledPackage | null = BrewInstalledLoader.installedOf(token);
    if (pkg !== null) {
      result.installed = true;
      result.installedVersion = pkg.version;
      result.outdated = pkg.outdated;
    }
  }

  private static fillPreviewItems(result: SkillPreviewResult, parsed: BrewDryRunResult): void {
    for (const item of parsed.wouldInstall) {
      const one: SkillPreviewItem = new SkillPreviewItem();
      one.name = item.name;
      one.version = item.version;
      // 升级预演的通用名词行（package/packages）不带 kind：目录 → 盘上快照逐条补齐
      one.kind = item.kind.length > 0 ? item.kind : BrewSkillBridge.kindGuessOf(item.name);
      one.fromVersion = item.fromVersion;
      result.items.push(one);
    }
  }

  /** 预演条目的 kind 兜底：目录 → 盘上快照 → 空串 */
  private static kindGuessOf(token: string): string {
    if (BrewSkillBridge.hasToken(BrewKindText.FORMULA, token)) {
      return BrewKindText.FORMULA;
    }
    if (BrewSkillBridge.hasToken(BrewKindText.CASK, token)) {
      return BrewKindText.CASK;
    }
    const pkg: BrewInstalledPackage | null = BrewInstalledLoader.installedOf(token);
    return pkg !== null ? pkg.kind : '';
  }

  private static rowOf(pkg: BrewInstalledPackage): SkillInstalledRow {
    const row: SkillInstalledRow = new SkillInstalledRow();
    row.name = pkg.name;
    row.kind = pkg.kind;
    row.version = pkg.version;
    row.latestVersion = pkg.latestVersion;
    row.outdated = pkg.outdated;
    row.installedAsDependency = pkg.installedAsDependency;
    return row;
  }

  /** filter：all / formula / cask / outdated / updated（脚本侧已校验，这里兜底放行 all） */
  private static matchesFilter(filter: string, pkg: BrewInstalledPackage): boolean {
    if (filter === 'formula') {
      return pkg.kind === BrewKindText.FORMULA;
    }
    if (filter === 'cask') {
      return pkg.kind === BrewKindText.CASK;
    }
    if (filter === 'outdated') {
      return pkg.outdated;
    }
    if (filter === 'updated') {
      return !pkg.outdated;
    }
    return true;
  }

  private static capOf(limit: number, fallback: number, max: number): number {
    if (limit <= 0) {
      return fallback;
    }
    if (limit > max) {
      return max;
    }
    return limit;
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

  /** 长文本摘要：超长截断加省略号 */
  private static clamp(text: string, max: number): string {
    const trimmed: string = text.trim();
    if (trimmed.length <= max) {
      return trimmed;
    }
    return trimmed.substring(0, max).trim() + '……';
  }
}
