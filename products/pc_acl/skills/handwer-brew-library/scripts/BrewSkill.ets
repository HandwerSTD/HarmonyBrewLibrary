/**
 * Harmonybrew Agent Skill 入口脚本（薄适配层，spec 2026-11-22-agent-skill-spec.md §3.2 +
 * 2026-11-23 v2 能力面扩充）。
 *
 * 官方机制（API 26.0.0+，@ohos.app.ability.scriptManager）：系统智能体（小艺 Work）依据
 * SKILL.md 完成意图匹配后，经 exec-cli 调用本文件里与 functionName 同名的 public async
 * 方法；本方法解析 argv、调用应用内既有业务、按契约构造 ExecuteResult 并回包。
 *
 * 本文件只做三件事：按 SKILL.md 的 args 约定取参、调 BrewSkillBridge（应用内只读业务与
 * dry-run 预演）、按契约回包。**业务逻辑一律不进脚本**；import 白名单
 * （audit_skill_no_exec.mjs 校验）：scriptManager / BusinessError / BrewSkillBridge。
 *
 * 契约常量在这里是本地副本——skills/ 目录不引跨模块包（探针 Q3 未决），与
 * features/brewcommon 的 SkillConstants.ets 逐字一致，check_skill_contract.mjs 核对。
 */

import { scriptManager } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { BrewSkillBridge } from '../../../src/main/ets/skill/BrewSkillBridge';
import type {
  SkillBrewStatus,
  SkillCategoriesResult,
  SkillCategoryRow,
  SkillDetailResult,
  SkillInstalledRow,
  SkillListResult,
  SkillOutdatedResult,
  SkillPreviewItem,
  SkillPreviewResult,
  SkillQueryResult,
  SkillSearchRow,
  SkillTrendingResult,
  SkillTrendingRow,
  SkillUninstallResult,
  SkillUsageResult,
  SkillUsageRow,
} from '../../../src/main/ets/skill/BrewSkillBridge';

const SKILL_FN_SEARCH: string = 'searchPackages';
const SKILL_FN_QUERY: string = 'queryPackage';
const SKILL_FN_PREVIEW: string = 'previewInstall';
const SKILL_FN_REQUEST: string = 'requestInstall';
const SKILL_FN_LIST_INSTALLED: string = 'listInstalled';
const SKILL_FN_LIST_OUTDATED: string = 'listOutdated';
const SKILL_FN_DETAIL: string = 'packageDetail';
const SKILL_FN_USAGE: string = 'packageUsage';
const SKILL_FN_TRENDING: string = 'listTrending';
const SKILL_FN_CATEGORIES: string = 'listCategories';
const SKILL_FN_CHECK: string = 'checkBrew';
const SKILL_FN_PREVIEW_UPGRADE: string = 'previewUpgrade';
const SKILL_FN_PREVIEW_UPGRADE_ALL: string = 'previewUpgradeAll';
const SKILL_FN_PREVIEW_UNINSTALL: string = 'previewUninstall';

const SKILL_ERR_INVALID_PARAMS: string = 'ERR_INVALID_PARAMS';
const SKILL_ERR_NOT_FOUND: string = 'ERR_NOT_FOUND';
const SKILL_ERR_INTERNAL: string = 'ERR_INTERNAL';

const SUGGEST_ASK_QUERY: string = '你想找什么类型的工具？';
const SUGGEST_ASK_TOKEN: string = '你想查哪个包？';
const SUGGEST_NOT_FOUND_PREFIX: string = '软件包目录里没有「';
const SUGGEST_NOT_FOUND_SUFFIX: string = '」，要不要说说你想做什么，我帮你找找？';
const SUGGEST_PREVIEW_OK: string =
  '清单在上面。想在 Harmonybrew 里装的话，打开这个包的详情页点安装就行。';
const SUGGEST_CONFIRM: string =
  '预演完成，请在 Harmonybrew 里打开这个包的详情页，点安装才算数。';
const SUGGEST_RETRY: string = '这次没成，稍后再试试。';
const SUGGEST_CATALOG: string = '先打开一次 Harmonybrew，让软件包目录就绪。';
const SUGGEST_ASK_FILTER: string =
  'filter 取值是 all / formula / cask / outdated / updated，你想看哪一类？';
const SUGGEST_ASK_BOARD: string =
  'board 取值是 trending / alltime / fresh，kind 取值是 formula / cask。';
const SUGGEST_ASK_SCOPE: string = 'scope 取值是 all / formula / cask，默认全部。';
const SUGGEST_BREW_MISSING: string =
  '设备上还没有可用的 brew。先在 Harmonybrew 里完成 brew 探测，再让我来。';
const SUGGEST_NOT_INSTALLED_UPGRADE: string =
  '这个包还没有安装记录。想装的话告诉我，我先给你预演安装。';
const SUGGEST_UPGRADE_PREVIEW_OK: string =
  '预演清单在上面。升级请在 Harmonybrew 里打开这个包的详情页操作。';
const SUGGEST_UPGRADE_ALL_PREVIEW_OK: string =
  '预演清单在上面。升级请在 Harmonybrew 的「我的 - 待更新」页操作。';
const SUGGEST_NOTHING_TO_UPGRADE: string = '它已经是最新版本，没有可升级的。';
const SUGGEST_NOTHING_TO_UPGRADE_ALL: string = '没有待升级的包，一切已是最新。';
const SUGGEST_UNINSTALL_CONFIRM: string =
  '卸载请打开 Harmonybrew 的「我的 - 本机包」，对这个包亲手操作卸载才算数。';
const SUGGEST_NOT_INSTALLED_UNINSTALL: string = '这个包没有安装记录，无需卸载。';
const SUGGEST_UPGRADE_HINT: string = '这个包有新版本。想升级的话告诉我，我先给你预演一下。';
const SUGGEST_USAGE_MISS: string = 'tldr 示例库里没有这个命令的页面（增强层，缺失属正常）。';

/** listInstalled 的 filter 取值 */
const LIST_FILTERS: string[] = ['all', 'formula', 'cask', 'outdated', 'updated'];
/** listTrending 的 board 取值 */
const TRENDING_BOARDS: string[] = ['trending', 'alltime', 'fresh'];
/** kind 取值 */
const KIND_VALUES: string[] = ['formula', 'cask'];
/** previewUpgradeAll 的 scope 取值 */
const SCOPE_VALUES: string[] = ['all', 'formula', 'cask'];

/** SKILL.md args Schema 的对象形态（exec-cli --args 传 JSON 对象时的形状） */
interface SkillArgs {
  query?: string;
  token?: string;
  filter?: string;
  scope?: string;
  board?: string;
  kind?: string;
  limit?: number;
}

/** token 只允许目录名出现过的字符形状；更严的「存在性」校验在 Bridge（G7） */
const TOKEN_RE: RegExp = /^[A-Za-z0-9][A-Za-z0-9._+-]{0,99}$/;

export default class BrewSkill {
  /** 按名称找包：SKILL.md 场景1。小艺的 LLM 负责从自然语言抽词，这里只做目录检索 */
  public async searchPackages(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    console.info('[skill] fn=' + SKILL_FN_SEARCH + ' begin');
    if (!BrewSkill.argvShapeOk(argv)) {
      await this.replyMalformed(info);
      return;
    }
    const keyword: string = BrewSkill.argOf(argv, 'query', 0);
    if (keyword.length === 0) {
      await this.replyInvalid(info, 'keyword is empty', SUGGEST_ASK_QUERY);
      return;
    }
    try {
      const rows: SkillSearchRow[] = await BrewSkillBridge.searchPackages(keyword);
      const data: Record<string, Object> = {
        'query': keyword,
        'matchedCount': rows.length,
        'rows': BrewSkill.rowsPayload(rows),
      };
      await this.reply(info, 0, BrewSkill.successPayload(data));
    } catch (err) {
      await this.replyInternal(info, err, SUGGEST_CATALOG);
    }
  }

  /** 包的状态与详情：SKILL.md 场景2。目录事实 + 盘上快照，不执行任何命令 */
  public async queryPackage(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    console.info('[skill] fn=' + SKILL_FN_QUERY + ' begin');
    if (!BrewSkill.argvShapeOk(argv)) {
      await this.replyMalformed(info);
      return;
    }
    const token: string = BrewSkill.argOf(argv, 'token', 0);
    if (!BrewSkill.isSafeToken(token)) {
      await this.replyInvalid(info, 'token is empty or invalid', SUGGEST_ASK_TOKEN);
      return;
    }
    try {
      const q: SkillQueryResult = await BrewSkillBridge.queryPackage(token);
      if (!q.inCatalog && !q.installed) {
        await this.replyNotFound(info, token);
        return;
      }
      const data: Record<string, Object> = {
        'token': q.token,
        'kind': q.kind,
        'desc': q.desc,
        'installed': q.installed,
        'version': q.version,
        'latestVersion': q.latestVersion,
        'outdated': q.outdated,
        'asOf': q.asOf,
      };
      await this.reply(info, 0, BrewSkill.successPayload(data));
    } catch (err) {
      await this.replyInternal(info, err, SUGGEST_RETRY);
    }
  }

  /** 预演安装：SKILL.md 场景3。`brew install --dry-run`，只读 */
  public async previewInstall(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    console.info('[skill] fn=' + SKILL_FN_PREVIEW + ' begin');
    await this.previewAndReply(info, argv, false);
  }

  /** AI 发起安装：SKILL.md 场景4。与预演同一实现，只换回包语义与指路文案（G5） */
  public async requestInstall(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    console.info('[skill] fn=' + SKILL_FN_REQUEST + ' begin');
    await this.previewAndReply(info, argv, true);
  }

  /** 已装清单：SKILL.md 场景5。盘上快照（冻结口径），快照缺失时读一次命令补齐 */
  public async listInstalled(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    console.info('[skill] fn=' + SKILL_FN_LIST_INSTALLED + ' begin');
    if (!BrewSkill.optionalArgsOk(argv)) {
      await this.replyMalformed(info);
      return;
    }
    const filter: string = BrewSkill.argOf(argv, 'filter', 0);
    const query: string = BrewSkill.argOf(argv, 'query', 1);
    const limit: number = BrewSkill.limitOf(argv);
    const effectiveFilter: string = filter.length > 0 ? filter : 'all';
    if (!BrewSkill.inSet(effectiveFilter, LIST_FILTERS)) {
      await this.replyInvalid(info, 'filter must be all/formula/cask/outdated/updated',
        SUGGEST_ASK_FILTER);
      return;
    }
    try {
      const r: SkillListResult = await BrewSkillBridge.listInstalled(effectiveFilter, query, limit);
      if (r.failureMessage.length > 0) {
        await this.replyInternal(info, new Error(r.failureMessage), SUGGEST_BREW_MISSING);
        return;
      }
      const data: Record<string, Object> = {
        'filter': effectiveFilter,
        'query': query,
        'hasSnapshot': r.hasSnapshot,
        'asOf': r.asOf,
        'total': r.total,
        'formulaCount': r.formulaCount,
        'caskCount': r.caskCount,
        'outdatedCount': r.outdatedCount,
        'rows': BrewSkill.installedRows(r.rows),
      };
      await this.reply(info, 0, BrewSkill.successPayload(data));
    } catch (err) {
      await this.replyInternal(info, err, SUGGEST_RETRY);
    }
  }

  /** 待更新清单：SKILL.md 场景6。同一份盘上快照的 outdated 集合 */
  public async listOutdated(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    console.info('[skill] fn=' + SKILL_FN_LIST_OUTDATED + ' begin');
    if (!BrewSkill.optionalArgsOk(argv)) {
      await this.replyMalformed(info);
      return;
    }
    try {
      const r: SkillOutdatedResult = await BrewSkillBridge.listOutdated();
      if (r.failureMessage.length > 0) {
        await this.replyInternal(info, new Error(r.failureMessage), SUGGEST_BREW_MISSING);
        return;
      }
      const data: Record<string, Object> = {
        'hasSnapshot': r.hasSnapshot,
        'asOf': r.asOf,
        'total': r.total,
        'rows': BrewSkill.installedRows(r.rows),
      };
      await this.reply(info, 0, BrewSkill.successPayload(data));
    } catch (err) {
      await this.replyInternal(info, err, SUGGEST_RETRY);
    }
  }

  /** 预演升级单包：SKILL.md 场景7。`brew upgrade --dry-run`，只读 */
  public async previewUpgrade(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    console.info('[skill] fn=' + SKILL_FN_PREVIEW_UPGRADE + ' begin');
    if (!BrewSkill.argvShapeOk(argv)) {
      await this.replyMalformed(info);
      return;
    }
    const token: string = BrewSkill.argOf(argv, 'token', 0);
    if (!BrewSkill.isSafeToken(token)) {
      await this.replyInvalid(info, 'token is empty or invalid', SUGGEST_ASK_TOKEN);
      return;
    }
    try {
      const r: SkillPreviewResult = await BrewSkillBridge.previewUpgrade(token);
      if (r.notFound) {
        await this.replyNotFound(info, token);
        return;
      }
      if (r.notInstalled) {
        const data: Record<string, Object> = {
          'token': token,
          'status': 'not_installed',
        };
        await this.reply(info, 0, BrewSkill.successPayload(data, SUGGEST_NOT_INSTALLED_UPGRADE));
        return;
      }
      if (!r.ok) {
        await this.replyInternal(info, new Error(r.failureMessage), SUGGEST_RETRY);
        return;
      }
      if (r.nothingToDo) {
        const data: Record<string, Object> = {
          'token': token,
          'status': 'nothing_to_upgrade',
          'cmdline': r.cmdline,
        };
        await this.reply(info, 0, BrewSkill.successPayload(data, SUGGEST_NOTHING_TO_UPGRADE));
        return;
      }
      const data: Record<string, Object> = {
        'token': token,
        'status': 'preview',
        'cmdline': r.cmdline,
        'declaredCount': r.declaredCount,
        'wouldUpgrade': BrewSkill.upgradePayload(r.items),
      };
      await this.reply(info, 0, BrewSkill.successPayload(data, SUGGEST_UPGRADE_PREVIEW_OK));
    } catch (err) {
      await this.replyInternal(info, err, SUGGEST_RETRY);
    }
  }

  /** 预演批量升级：SKILL.md 场景8。`brew upgrade [--formula|--cask] --dry-run`，只读 */
  public async previewUpgradeAll(info: scriptManager.ArkTSScriptInfo,
    ...argv: string[]): Promise<void> {
    console.info('[skill] fn=' + SKILL_FN_PREVIEW_UPGRADE_ALL + ' begin');
    if (!BrewSkill.optionalArgsOk(argv)) {
      await this.replyMalformed(info);
      return;
    }
    const scope: string = BrewSkill.argOf(argv, 'scope', 0);
    const effectiveScope: string = scope.length > 0 ? scope : 'all';
    if (!BrewSkill.inSet(effectiveScope, SCOPE_VALUES)) {
      await this.replyInvalid(info, 'scope must be all/formula/cask', SUGGEST_ASK_SCOPE);
      return;
    }
    try {
      const r: SkillPreviewResult = await BrewSkillBridge.previewUpgradeAll(effectiveScope);
      if (!r.ok) {
        await this.replyInternal(info, new Error(r.failureMessage), SUGGEST_RETRY);
        return;
      }
      if (r.nothingToDo) {
        const data: Record<string, Object> = {
          'scope': effectiveScope,
          'status': 'nothing_to_upgrade',
          'cmdline': r.cmdline,
        };
        await this.reply(info, 0, BrewSkill.successPayload(data, SUGGEST_NOTHING_TO_UPGRADE_ALL));
        return;
      }
      const data: Record<string, Object> = {
        'scope': effectiveScope,
        'status': 'preview',
        'cmdline': r.cmdline,
        'declaredCount': r.declaredCount,
        'wouldUpgrade': BrewSkill.upgradePayload(r.items),
      };
      await this.reply(info, 0, BrewSkill.successPayload(data, SUGGEST_UPGRADE_ALL_PREVIEW_OK));
    } catch (err) {
      await this.replyInternal(info, err, SUGGEST_RETRY);
    }
  }

  /** 卸载影响评估：SKILL.md 场景9。只读推导（快照 + brew uses），绝不执行卸载 */
  public async previewUninstall(info: scriptManager.ArkTSScriptInfo,
    ...argv: string[]): Promise<void> {
    console.info('[skill] fn=' + SKILL_FN_PREVIEW_UNINSTALL + ' begin');
    if (!BrewSkill.argvShapeOk(argv)) {
      await this.replyMalformed(info);
      return;
    }
    const token: string = BrewSkill.argOf(argv, 'token', 0);
    if (!BrewSkill.isSafeToken(token)) {
      await this.replyInvalid(info, 'token is empty or invalid', SUGGEST_ASK_TOKEN);
      return;
    }
    try {
      const r: SkillUninstallResult = await BrewSkillBridge.previewUninstall(token);
      if (r.notFound) {
        await this.replyNotFound(info, token);
        return;
      }
      if (r.status === 'not_installed') {
        const data: Record<string, Object> = {
          'token': token,
          'status': 'not_installed',
        };
        await this.reply(info, 0, BrewSkill.successPayload(data, SUGGEST_NOT_INSTALLED_UNINSTALL));
        return;
      }
      let suggestion: string = SUGGEST_UNINSTALL_CONFIRM;
      if (r.dependents.length > 0) {
        suggestion = '注意：' + r.dependents.length + ' 个已安装包依赖它，卸载会破坏它们的依赖关系。' +
          SUGGEST_UNINSTALL_CONFIRM;
      }
      const data: Record<string, Object> = {
        'token': token,
        'status': 'needs_confirmation',
        'kind': r.kind,
        'version': r.version,
        'plannedCommand': r.plannedCommand,
        'dependents': r.dependents,
        'usesOk': r.usesOk,
        'asOf': r.asOf,
      };
      await this.reply(info, 0, BrewSkill.successPayload(data, suggestion));
    } catch (err) {
      await this.replyInternal(info, err, SUGGEST_RETRY);
    }
  }

  /** 包详情：SKILL.md 场景10。现网单条 + 盘上快照合并 */
  public async packageDetail(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    console.info('[skill] fn=' + SKILL_FN_DETAIL + ' begin');
    if (!BrewSkill.argvShapeOk(argv)) {
      await this.replyMalformed(info);
      return;
    }
    const token: string = BrewSkill.argOf(argv, 'token', 0);
    if (!BrewSkill.isSafeToken(token)) {
      await this.replyInvalid(info, 'token is empty or invalid', SUGGEST_ASK_TOKEN);
      return;
    }
    try {
      const r: SkillDetailResult = await BrewSkillBridge.packageDetail(token);
      if (r.notFound) {
        await this.replyNotFound(info, token);
        return;
      }
      if (r.failureMessage.length > 0) {
        await this.replyInternal(info, new Error(r.failureMessage), SUGGEST_RETRY);
        return;
      }
      const data: Record<string, Object> = {
        'token': r.token,
        'kind': r.kind,
        'desc': r.desc,
        'version': r.version,
        'homepage': r.homepage,
        'license': r.license,
        'categoryKey': r.categoryKey,
        'installs30d': r.installs30d,
        'dependencies': r.dependencies,
        'caveats': r.caveats,
        'deprecated': r.deprecated,
        'deprecationReason': r.deprecationReason,
        'disabled': r.disabled,
        'disableReason': r.disableReason,
        'installed': r.installed,
        'installedVersion': r.installedVersion,
        'outdated': r.outdated,
        'asOf': r.asOf,
      };
      const suggestion: string = r.outdated ? SUGGEST_UPGRADE_HINT : '';
      await this.reply(info, 0, BrewSkill.successPayload(data, suggestion));
    } catch (err) {
      await this.replyInternal(info, err, SUGGEST_RETRY);
    }
  }

  /** 用法示例：SKILL.md 场景11。tldr 增强层，缺失不算错误 */
  public async packageUsage(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    console.info('[skill] fn=' + SKILL_FN_USAGE + ' begin');
    if (!BrewSkill.argvShapeOk(argv)) {
      await this.replyMalformed(info);
      return;
    }
    const token: string = BrewSkill.argOf(argv, 'token', 0);
    if (!BrewSkill.isSafeToken(token)) {
      await this.replyInvalid(info, 'token is empty or invalid', SUGGEST_ASK_TOKEN);
      return;
    }
    try {
      const r: SkillUsageResult = await BrewSkillBridge.packageUsage(token);
      if (!r.found) {
        const missData: Record<string, Object> = {
          'token': token,
          'found': false,
        };
        await this.reply(info, 0, BrewSkill.successPayload(missData, SUGGEST_USAGE_MISS));
        return;
      }
      const data: Record<string, Object> = {
        'token': r.token,
        'found': true,
        'locale': r.locale,
        'summary': r.summary,
        'examples': BrewSkill.usageRows(r.examples),
      };
      await this.reply(info, 0, BrewSkill.successPayload(data));
    } catch (err) {
      await this.replyInternal(info, err, SUGGEST_RETRY);
    }
  }

  /** 热门榜单：SKILL.md 场景12。同步读表，零请求 */
  public async listTrending(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    console.info('[skill] fn=' + SKILL_FN_TRENDING + ' begin');
    if (!BrewSkill.optionalArgsOk(argv)) {
      await this.replyMalformed(info);
      return;
    }
    const board: string = BrewSkill.argOf(argv, 'board', 0);
    const kind: string = BrewSkill.argOf(argv, 'kind', 1);
    const limit: number = BrewSkill.limitOf(argv);
    const effectiveBoard: string = board.length > 0 ? board : 'trending';
    const effectiveKind: string = kind.length > 0 ? kind : 'formula';
    if (!BrewSkill.inSet(effectiveBoard, TRENDING_BOARDS) ||
      !BrewSkill.inSet(effectiveKind, KIND_VALUES)) {
      await this.replyInvalid(info, 'board must be trending/alltime/fresh; kind must be formula/cask',
        SUGGEST_ASK_BOARD);
      return;
    }
    try {
      const r: SkillTrendingResult = await BrewSkillBridge.listTrending(effectiveBoard,
        effectiveKind, limit);
      const data: Record<string, Object> = {
        'board': r.board,
        'kind': r.kind,
        'state': r.state,
        'windowStart': r.windowStart,
        'windowEnd': r.windowEnd,
        'rows': BrewSkill.trendingRows(r.rows),
      };
      const suggestion: string = r.rows.length === 0 ? SUGGEST_CATALOG : '';
      await this.reply(info, 0, BrewSkill.successPayload(data, suggestion));
    } catch (err) {
      await this.replyInternal(info, err, SUGGEST_RETRY);
    }
  }

  /** 分类清单：SKILL.md 场景13。同步读表，零请求 */
  public async listCategories(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    console.info('[skill] fn=' + SKILL_FN_CATEGORIES + ' begin');
    if (!BrewSkill.optionalArgsOk(argv)) {
      await this.replyMalformed(info);
      return;
    }
    try {
      const r: SkillCategoriesResult = await BrewSkillBridge.listCategories();
      const data: Record<string, Object> = {
        'state': r.state,
        'formula': BrewSkill.categoryRows(r.formula),
        'cask': BrewSkill.categoryRows(r.cask),
      };
      const suggestion: string =
        r.formula.length === 0 && r.cask.length === 0 ? SUGGEST_CATALOG : '';
      await this.reply(info, 0, BrewSkill.successPayload(data, suggestion));
    } catch (err) {
      await this.replyInternal(info, err, SUGGEST_RETRY);
    }
  }

  /** brew 状态自检：SKILL.md 场景14。事实由字段承载，回包永远成功 */
  public async checkBrew(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    console.info('[skill] fn=' + SKILL_FN_CHECK + ' begin');
    if (!BrewSkill.optionalArgsOk(argv)) {
      await this.replyMalformed(info);
      return;
    }
    try {
      const r: SkillBrewStatus = await BrewSkillBridge.checkBrew();
      const data: Record<string, Object> = {
        'ready': r.ready,
        'enabled': r.enabled,
        'shellAvailable': r.shellAvailable,
        'brewPath': r.brewPath,
        'prefix': r.prefix,
        'version': r.version,
        'configOk': r.configOk,
        'failureMessage': r.failureMessage,
      };
      let suggestion: string = '';
      if (!r.ready) {
        suggestion = SUGGEST_BREW_MISSING;
      } else if (!r.configOk) {
        suggestion = SUGGEST_RETRY;
      }
      await this.reply(info, 0, BrewSkill.successPayload(data, suggestion));
    } catch (err) {
      await this.replyInternal(info, err, SUGGEST_RETRY);
    }
  }

  // ------------------------------------------------------------ 私有：安装预演共用链

  private async previewAndReply(info: scriptManager.ArkTSScriptInfo,
    argv: string[], isRequest: boolean): Promise<void> {
    if (!BrewSkill.argvShapeOk(argv)) {
      await this.replyMalformed(info);
      return;
    }
    const token: string = BrewSkill.argOf(argv, 'token', 0);
    if (!BrewSkill.isSafeToken(token)) {
      await this.replyInvalid(info, 'token is empty or invalid', SUGGEST_ASK_TOKEN);
      return;
    }
    try {
      const preview: SkillPreviewResult = await BrewSkillBridge.previewInstall(token);
      if (preview.notFound) {
        await this.replyNotFound(info, token);
        return;
      }
      if (!preview.ok) {
        await this.replyInternal(info, new Error(preview.failureMessage), SUGGEST_RETRY);
        return;
      }
      const data: Record<string, Object> = {
        'token': token,
        'status': isRequest ? 'needs_confirmation' : 'preview',
        'cmdline': preview.cmdline,
        'declaredCount': preview.declaredCount,
        'wouldInstall': BrewSkill.previewPayload(preview.items),
      };
      const suggestion: string = isRequest ? SUGGEST_CONFIRM : SUGGEST_PREVIEW_OK;
      await this.reply(info, 0, BrewSkill.successPayload(data, suggestion));
    } catch (err) {
      await this.replyInternal(info, err, SUGGEST_RETRY);
    }
  }

  // ------------------------------------------------------------ 私有：回包与取参

  /** 成功回包。外层 status 恒为 success/failed（官方契约）；needs_confirmation 等业务
   * 语义放 data.status，不破坏 SKILL.md 顶层 oneOf */
  private static successPayload(data: Record<string, Object>,
    suggestion: string = ''): Record<string, Object> {
    const payload: Record<string, Object> = {
      'type': 'result',
      'status': 'success',
      'data': data,
    };
    if (suggestion.length > 0) {
      payload['suggestion'] = suggestion;
    }
    return payload;
  }

  private static failedPayload(errCode: string, errMsg: string,
    suggestion: string, data: Record<string, Object>): Record<string, Object> {
    const payload: Record<string, Object> = {
      'type': 'result',
      'status': 'failed',
      'errCode': errCode,
      'errMsg': errMsg,
      'suggestion': suggestion,
      'data': data,
    };
    return payload;
  }

  private static rowsPayload(rows: SkillSearchRow[]): Array<Record<string, Object>> {
    const list: Array<Record<string, Object>> = [];
    for (const row of rows) {
      const one: Record<string, Object> = {
        'name': row.name,
        'kind': row.kind,
        'desc': row.desc,
      };
      list.push(one);
    }
    return list;
  }

  private static previewPayload(items: SkillPreviewItem[]): Array<Record<string, Object>> {
    const list: Array<Record<string, Object>> = [];
    for (const item of items) {
      const one: Record<string, Object> = {
        'name': item.name,
        'version': item.version,
        'kind': item.kind,
      };
      list.push(one);
    }
    return list;
  }

  private static upgradePayload(items: SkillPreviewItem[]): Array<Record<string, Object>> {
    const list: Array<Record<string, Object>> = [];
    for (const item of items) {
      const one: Record<string, Object> = {
        'name': item.name,
        'fromVersion': item.fromVersion,
        'version': item.version,
        'kind': item.kind,
      };
      list.push(one);
    }
    return list;
  }

  private static installedRows(rows: SkillInstalledRow[]): Array<Record<string, Object>> {
    const list: Array<Record<string, Object>> = [];
    for (const row of rows) {
      const one: Record<string, Object> = {
        'name': row.name,
        'kind': row.kind,
        'version': row.version,
        'latestVersion': row.latestVersion,
        'outdated': row.outdated,
        'installedAsDependency': row.installedAsDependency,
      };
      list.push(one);
    }
    return list;
  }

  private static trendingRows(rows: SkillTrendingRow[]): Array<Record<string, Object>> {
    const list: Array<Record<string, Object>> = [];
    for (const row of rows) {
      const one: Record<string, Object> = {
        'rank': row.rank,
        'token': row.token,
        'desc': row.desc,
        'installs30d': row.installs30d,
        'installs365d': row.installs365d,
        'score': row.score,
      };
      list.push(one);
    }
    return list;
  }

  private static categoryRows(rows: SkillCategoryRow[]): Array<Record<string, Object>> {
    const list: Array<Record<string, Object>> = [];
    for (const row of rows) {
      const one: Record<string, Object> = {
        'categoryKey': row.categoryKey,
        'name': row.name,
        'itemCount': row.itemCount,
      };
      list.push(one);
    }
    return list;
  }

  private static usageRows(rows: SkillUsageRow[]): Array<Record<string, Object>> {
    const list: Array<Record<string, Object>> = [];
    for (const row of rows) {
      const one: Record<string, Object> = {
        'desc': row.desc,
        'code': row.code,
        'hasPlaceholder': row.hasPlaceholder,
      };
      list.push(one);
    }
    return list;
  }

  /** argv 取参：对象形态读具名键（直接属性访问，不做动态索引），否则按位取 */
  private static argOf(argv: string[], key: string, index: number): string {
    if (argv.length > 0) {
      const first: string = argv[0].trim();
      if (first.length > 1 && first.charAt(0) === '{') {
        const args: SkillArgs | null = BrewSkill.parseArgs(first);
        if (args !== null) {
          if (key === 'query' && args.query !== undefined) {
            return args.query.trim();
          }
          if (key === 'token' && args.token !== undefined) {
            return args.token.trim();
          }
          if (key === 'filter' && args.filter !== undefined) {
            return args.filter.trim();
          }
          if (key === 'scope' && args.scope !== undefined) {
            return args.scope.trim();
          }
          if (key === 'board' && args.board !== undefined) {
            return args.board.trim();
          }
          if (key === 'kind' && args.kind !== undefined) {
            return args.kind.trim();
          }
        }
        return '';
      }
    }
    if (argv.length > index) {
      return argv[index].trim();
    }
    return '';
  }

  /** limit 取参：JSON 数字，钳到 1–50；缺省/非法返回 0（=服务端默认值） */
  private static limitOf(argv: string[]): number {
    if (argv.length === 0) {
      return 0;
    }
    const first: string = argv[0].trim();
    if (first.length > 1 && first.charAt(0) === '{') {
      const args: SkillArgs | null = BrewSkill.parseArgs(first);
      if (args !== null && args.limit !== undefined && typeof args.limit === 'number') {
        const value: number = args.limit;
        if (value < 1) {
          return 0;
        }
        if (value > 50) {
          return 50;
        }
        return Math.floor(value);
      }
    }
    return 0;
  }

  private static parseArgs(text: string): SkillArgs | null {
    let value: SkillArgs | null = BrewSkill.tryParseArgs(text);
    if (value === null) {
      // 命令行传输层可能把内部双引号转义成 \" 后整段传入（真实 harness 有此形态）：
      // 还原后重试一次，两种形态都收。
      value = BrewSkill.tryParseArgs(text.replace(/\\"/g, '"'));
    }
    return value;
  }

  private static tryParseArgs(text: string): SkillArgs | null {
    try {
      const parsed = JSON.parse(text) as Object;
      if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
        return null;
      }
      return parsed as SkillArgs;
    } catch (err) {
      return null;
    }
  }

  /** argv 形态校验：空 argv 或「看着像 JSON 却解析不了」都算形态错误（自动重试的判定锚点） */
  private static argvShapeOk(argv: string[]): boolean {
    if (argv.length === 0) {
      return false;
    }
    const first: string = argv[0].trim();
    if (first.charAt(0) === '{') {
      return BrewSkill.parseArgs(first) !== null;
    }
    // 位置参数形态仅作兼容（SKILL.md 契约仍要求单一 JSON 字符串），不判形态错误
    return true;
  }

  /** 无参/可选参函数的 argv 形态校验：没有 argv 视为合法；给了就必须是可解析的 JSON 对象 */
  private static optionalArgsOk(argv: string[]): boolean {
    if (argv.length === 0) {
      return true;
    }
    return BrewSkill.argvShapeOk(argv);
  }

  /** 成员集合校验 */
  private static inSet(value: string, set: string[]): boolean {
    for (const one of set) {
      if (one === value) {
        return true;
      }
    }
    return false;
  }

  /** argv 形态错误：errMsg 带「参数传递格式错误」锚点，SKILL.md 据此指示自动压参重试一次 */
  private async replyMalformed(info: scriptManager.ArkTSScriptInfo): Promise<void> {
    const data: Record<string, Object> = {};
    await this.reply(info, -1, BrewSkill.failedPayload(SKILL_ERR_INVALID_PARAMS,
      '参数传递格式错误：argv[0] 必须是可解析的 JSON 对象字符串。',
      '请先对完整参数对象执行 JSON.stringify，再把结果作为唯一参数传入；命令行调用时转义内部双引号。',
      data));
    console.info('[skill] reply malformed-argv');
  }

  /** token 形状校验：非空、无空白、目录名常见字符。存在性校验在 Bridge（G7） */
  private static isSafeToken(token: string): boolean {
    return token.length > 0 && token.match(TOKEN_RE) !== null;
  }

  /** 唯一回包出口：只封装 API 调用与异常打印，不参与结果构造（官方约定） */
  private async reply(info: scriptManager.ArkTSScriptInfo, code: number,
    payload: Record<string, Object>): Promise<void> {
    const result: scriptManager.ExecuteResult = { code: code, result: payload };
    try {
      await scriptManager.completeArkTSScriptInApp(info.context, info.requestCode, result);
      console.info('[skill] reply ok, requestCode=' + info.requestCode);
    } catch (err) {
      const error = err as BusinessError;
      console.error('[skill] completeArkTSScriptInApp failed, code: ' + error.code +
        ', message: ' + error.message);
    }
  }

  private async replyInvalid(info: scriptManager.ArkTSScriptInfo,
    errMsg: string, suggestion: string): Promise<void> {
    const data: Record<string, Object> = {};
    await this.reply(info, -1,
      BrewSkill.failedPayload(SKILL_ERR_INVALID_PARAMS, errMsg, suggestion, data));
    console.info('[skill] reply invalid-params, requestCode=' + info.requestCode);
  }

  /** G7：不存在的名字一律显式失败并引导 searchPackages，不猜、不改写、不「纠正成相近包名」 */
  private async replyNotFound(info: scriptManager.ArkTSScriptInfo, token: string): Promise<void> {
    const keywords: Array<string> = [token];
    const data: Record<string, Object> = { 'searchedKeywords': keywords };
    await this.reply(info, -1, BrewSkill.failedPayload(SKILL_ERR_NOT_FOUND,
      'token not found in catalog',
      SUGGEST_NOT_FOUND_PREFIX + token + SUGGEST_NOT_FOUND_SUFFIX, data));
    console.info('[skill] reply not-found, token=' + token);
  }

  private async replyInternal(info: scriptManager.ArkTSScriptInfo,
    err: Error, suggestion: string): Promise<void> {
    const message: string = err.message.length > 0 ? err.message : 'internal error';
    const data: Record<string, Object> = {};
    await this.reply(info, -1,
      BrewSkill.failedPayload(SKILL_ERR_INTERNAL, message, suggestion, data));
    console.error('[skill] reply internal, message=' + message);
  }
}
