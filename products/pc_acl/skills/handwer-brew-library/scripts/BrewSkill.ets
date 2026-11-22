/**
 * Harmonybrew Agent Skill 入口脚本（薄适配层，spec 2026-11-22-agent-skill-spec.md §3.2）。
 *
 * 官方机制（API 26.0.0+，@ohos.app.ability.scriptManager）：系统智能体（小艺 Work）依据
 * SKILL.md 完成意图匹配后，经 exec-cli 调用本文件里与 functionName 同名的 public async
 * 方法；本方法解析 argv、调用应用内既有业务、按契约构造 ExecuteResult 并回包。
 *
 * 本文件只做三件事：按 SKILL.md 的 args 约定取参、调 BrewSkillBridge（应用内只读业务）、
 * 按契约回包。**业务逻辑一律不进脚本**；import 白名单
 * （audit_skill_no_exec.mjs 校验）：scriptManager / BusinessError / BrewSkillBridge。
 *
 * 契约常量在这里是本地副本——skills/ 目录不引跨模块包（探针 Q3 未决），与
 * features/brewcommon 的 SkillConstants.ets 逐字一致，check_skill_contract.mjs 核对。
 */

import { scriptManager } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { BrewSkillBridge } from '../../../src/main/ets/skill/BrewSkillBridge';
import type {
  SkillPreviewItem,
  SkillPreviewResult,
  SkillQueryResult,
  SkillSearchRow,
} from '../../../src/main/ets/skill/BrewSkillBridge';

const SKILL_FN_SEARCH: string = 'searchPackages';
const SKILL_FN_QUERY: string = 'queryPackage';
const SKILL_FN_PREVIEW: string = 'previewInstall';
const SKILL_FN_REQUEST: string = 'requestInstall';

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

/** SKILL.md args Schema 的对象形态（exec-cli --args 传 JSON 对象时的形状） */
interface SkillArgs {
  query?: string;
  token?: string;
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

  /** 预演：SKILL.md 场景3。`brew install --dry-run`，只读 */
  public async previewInstall(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    console.info('[skill] fn=' + SKILL_FN_PREVIEW + ' begin');
    await this.previewAndReply(info, argv, false);
  }

  /** AI 发起安装：SKILL.md 场景4。与预演同一实现，只换回包语义与指路文案（G5） */
  public async requestInstall(info: scriptManager.ArkTSScriptInfo, ...argv: string[]): Promise<void> {
    console.info('[skill] fn=' + SKILL_FN_REQUEST + ' begin');
    await this.previewAndReply(info, argv, true);
  }

  // ------------------------------------------------------------ 私有：预演共用链

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
        }
        return '';
      }
    }
    if (argv.length > index) {
      return argv[index].trim();
    }
    return '';
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
