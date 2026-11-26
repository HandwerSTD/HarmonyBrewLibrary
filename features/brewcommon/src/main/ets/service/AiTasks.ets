/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { Logger } from '@ohos/common';
import { BrewSearchEngine } from '../model/BrewSearchEngine';
import type { BrewSearchEntry, BrewSearchHit } from '../model/BrewSearchEngine';
import {
  AI_CACHE_TTL_D1_MS,
  AI_PROMPT_MAX_CHARS,
  AI_CACHE_TTL_D2_MS,
  AI_CACHE_TTL_D4_MS,
  AI_D2_INTRO_MAX_CHARS,
  AI_D2_LEAD_MAX_CHARS,
  AI_D2_MAX_CANDIDATES,
  AI_D2_RESULT_LIMIT,
  AI_D2_TAIL_ROWS_MAX,
  AI_D3_STDERR_TAIL_CHARS,
  AI_D3_STDOUT_TAIL_CHARS,
  AI_D4_PICKS,
  AI_D4_PICKS_MIN,
  AI_D4_POOL_CASK,
  AI_D4_POOL_FORMULA,
  AI_D4_PROFILE_TAGS_MAX,
  AI_D4_WHY_MAX_CHARS,
  AI_FEATURE_D4,
  AI_MAX_TOKENS_D1,
  AI_MAX_TOKENS_D2,
  AI_MAX_TOKENS_D3,
  AI_MAX_TOKENS_D4,
  AI_PROMPT_VERSION_D1,
  AI_PROMPT_VERSION_D2,
  AI_PROMPT_VERSION_D4,
  AI_TEMPERATURE_D1,
  AI_TEMPERATURE_D2,
  AI_TEMPERATURE_D3,
  AI_TEMPERATURE_D4,
} from '../constant/AiConstants';
// RI（更新情报）的常量单独成文件：只被 release intel 一条链路使用，见 ReleaseIntelConstants
import {
  AI_CACHE_TTL_RI_MS,
  AI_MAX_TOKENS_RI,
  AI_PROMPT_VERSION_RI,
  AI_TEMPERATURE_RI,
  RELEASE_INTEL_FEATURE,
} from '../constant/ReleaseIntelConstants';
import {
  AiCandidate,
  AiDiscoverInput,
  AiDiscoverPick,
  AiDiscoverProfile,
  AiDiscoverResult,
  AiError,
  AiErrorKind,
  AiExplainCard,
  AiExplainInput,
  AiFailureCard,
  AiFailureInput,
  AiIntentInput,
  AiSearchAnswer,
  AiSearchPick,
} from '../model/AiTypes';
import {
  ReleaseIntelBreakingChange,
  ReleaseIntelCard,
  ReleaseIntelInput,
  ReleaseIntelSecurityClaim,
} from '../model/ReleaseIntelModels';
import { AiCache, AiCacheReadResult } from './AiCache';
import { AiClient } from './AiClient';
import type { AiClientTask, AiCompletion as AiCompletion2 } from './AiClient';
import { AiSettingsStore } from './AiSettingsStore';
import { fnv1a32 } from '../util/BrewHash';

const TAG: string = '[ai]';

/** 缓存 read 的内部展开（三个任务共用一次 read 调用的结论）。 */
class AiCacheLookup {
  public hit: boolean = false;
  public stale: boolean = false;
  public dataJson: string = '';
  public missReason: string = '';
  public model: string = '';
  public age: number = 0;
}

/**
 * AI 三个任务（D1 讲解 / D2 找工具 / D3 报错解读）的任务层。
 *
 * AiClient 只负责「发一次请求、拿回正文」；prompt 组装、JSON 解析校验、缓存、
 * 目录过滤与引擎排序都在这里。UI 层只认这三个入口与 `AiError.kind`。
 *
 * ## 缓存与降级总则（spec §3.3 / §8）
 *
 * - D1 / D2 落盘缓存（TTL 7 天 / 1 天，stale-while-revalidate）；D3 不缓存；
 * - 无 Key（E1）/ 网络失败（E2）/ 超时（E3）→ 调用方按 spec §8 的列降级：
 *   D1 引导、D2 切词表、D3 隐藏。本类**不**吞错误——降级是 UI 的决定权；
 * - D2 的 AI 候选**必须**过目录过滤（G5 防幻觉）+ 引擎排序（AI 只提名）。
 */
export class AiTasks {
  // ------------------------------------------------------------ D1 · 讲解卡

  /**
   * 取讲解卡：缓存命中直接返回（G3 秒开）；否则调模型、写缓存。
   * stale 时先返回旧值，再在后台刷新（G10，刷新结果经 onRefreshed 回调给 UI）。
   */
  /**
   * D1 取数。force=false（默认）走缓存命中秒开（G3）与 stale-while-revalidate（G10）；
   * force=true（「重新生成」按钮）**旁路缓存**直接取数——否则 7 天 TTL 内点击永远原样
   * 返回缓存卡（2026-11-23 验收实测「重新生成没反应」的根因）。两条路径都写回缓存。
   */
  public static explain(input: AiExplainInput, onRefreshed: (card: AiExplainCard) => void,
    force: boolean = false): Promise<AiExplainCard> {
    const cacheKey: string = input.token;
    const providerKey: string = AiTasks.providerModelKey();
    if (force) {
      return AiTasks.fetchExplain(input, providerKey, onRefreshed);
    }
    const cached: AiCacheLookup = AiTasks.lookup('d1', providerKey, cacheKey,
      AI_PROMPT_VERSION_D1, AI_CACHE_TTL_D1_MS);
    if (cached.hit) {
      const card: AiExplainCard | null = AiTasks.parseExplain(cached.dataJson);
      if (card !== null) {
        Logger.info(TAG, `d1 cache hit token=${input.token} age=${cached.age} model=${cached.model}`);
        return Promise.resolve(card);
      }
    }
    if (cached.stale) {
      const staleCard: AiExplainCard | null = AiTasks.parseExplain(cached.dataJson);
      if (staleCard !== null) {
        Logger.info(TAG, `stale-while-revalidate feature=d1 token=${input.token}`);
        AiTasks.fetchExplain(input, providerKey, onRefreshed);
        return Promise.resolve(staleCard);
      }
    }
    return AiTasks.fetchExplain(input, providerKey, onRefreshed);
  }

  private static fetchExplain(input: AiExplainInput, providerKey: string,
    onRefreshed: (card: AiExplainCard) => void): Promise<AiExplainCard> {
    const task: AiClientTask = AiClient.newTask();
    task.system = AiTasks.D1_SYSTEM;
    task.user = AiTasks.d1UserPrompt(input);
    task.temperature = AI_TEMPERATURE_D1;
    task.maxTokens = AI_MAX_TOKENS_D1;
    return AiClient.complete(task).then((completion) => {
      const outcome: ParseOutcome = new ParseOutcome();
      const card: AiExplainCard | null = AiTasks.parseExplain(completion.content, outcome);
      if (card === null) {
        throw new AiError(AiErrorKind.E4_BAD_FORMAT,
          `d1 reason=${e4ReasonOf(completion, outcome.reason)}`);
      }
      AiCache.write('d1', providerKey, input.token, AI_PROMPT_VERSION_D1, completion.model,
        JSON.stringify(card));
      Logger.info(TAG, `d1 ok token=${input.token} latency=${completion.latencyMs}`);
      onRefreshed(card);
      return card;
    });
  }

  private static d1UserPrompt(input: AiExplainInput): string {
    // grounding：全部字段来自详情页既有数据；超限先截 caveats（spec §4）
    let caveats: string = input.caveats;
    let deps: string = input.dependencies.join(', ');
    let base: string = `token: ${input.token}\nkind: ${input.kind}\ndesc: ${input.desc}\n` +
      `caveats: ${caveats}\ndependencies: ${deps}`;
    while ((AiTasks.D1_SYSTEM.length + base.length) > AI_PROMPT_MAX_CHARS &&
      caveats.length > 0) {
      // 先砍 caveats，再砍 dependencies；desc 与 token 是定位的最小集合，不砍
      caveats = caveats.substring(0, Math.floor(caveats.length / 2));
      base = `token: ${input.token}\nkind: ${input.kind}\ndesc: ${input.desc}\n` +
        `caveats: ${caveats}\ndependencies: ${deps}`;
      if (caveats.length < 32) {
        caveats = '';
        deps = '';
        base = `token: ${input.token}\nkind: ${input.kind}\ndesc: ${input.desc}\n` +
          `caveats: \ndependencies: `;
        break;
      }
    }
    return base + '\n请按 schema 输出 JSON。';
  }

  /**
   * 平台口径（全任务共用，拼在每个 system prompt 末尾）：用户设备是 HarmonyOS PC
   * （2in1 电脑），不是 macOS——但上游资料（Release Notes、系统要求、报错输出）里
   * 满篇都是 macOS 语境，模型会顺嘴把「macOS」写进解读。术语解释（formula/cask/
   * bottle）不受影响；引用原文时 macOS 字样保留，面向用户的表述一律按 HarmonyOS PC。
   */
  private static readonly PLATFORM_RULE: string =
    '平台口径：用户的设备是 HarmonyOS PC（2in1 电脑），不是 macOS。解释 Homebrew 术语' +
    '（formula/cask/bottle 等）不受影响；但任何涉及「在什么系统上运行/安装」的表述都' +
    '必须以 HarmonyOS PC 为准，不得把 macOS 说成用户的设备系统或建议 macOS 专属操作；' +
    '引用上游原文（发布说明、系统要求、报错输出）时 macOS 字样保留原文，' +
    '面向用户的解读一律按 HarmonyOS PC 语境。';

  private static readonly D1_SYSTEM: string = '你是 Homebrew 包讲解助手，像懂行的朋友向新手介绍这个包，' +
    '不是在填表。只基于用户提供的字段回答，用简体中文；不得虚构版本号、命令或功能；' +
    'caveats 是英文原文时翻译成中文并归纳风险点；字段里没有的信息就直说无法判断。\n' +
    '风格：要点 2–5 条、长短自然，不硬凑等长；summary 用自然的口语衔接，不用「该包」「本工具」开头。\n' +
    '空字段原则：某输入字段为空（caveats/dependencies 栏空白）时，对应数组输出 []，' +
    '**禁止**输出「未提供」「为空」「暂无」之类的填充句——宁可少一段，不写废话。\n' +
    '输出仍然必须是 JSON，字段结构不变：' +
    '{"summary":"定位一句话或两句话","scenarios":["适用场景，0–3条，自然短语"],' +
    '"caveats":["注意与坑，0–3条"],"steps":["上手步骤，2–3条，命令要可直接复制"]}。' +
    AiTasks.PLATFORM_RULE;

  private static parseExplain(text: string, outcome?: ParseOutcome): AiExplainCard | null {
    return parseJsonSafe(text, (obj: Record<string, Object>): AiExplainCard | null => {
      const card: AiExplainCard = new AiExplainCard();
      card.summary = typeof obj['summary'] === 'string' ? obj['summary'] as string : '';
      card.scenarios = stringArrayOf(obj['scenarios'], 3);
      card.caveats = stringArrayOf(obj['caveats'], 3);
      // steps 上限 3（isValid 收 2–3 条）；超限由 stringArrayOf 截断取前 3
      card.steps = stringArrayOf(obj['steps'], 3);
      if (!card.isValid()) {
        return null;
      }
      return card;
    });
  }

  // ------------------------------------------------------------ D2 · AI 搜索问答

  /**
   * AI 搜索问答（2026-11-26-ai-search-ask-spec §3）：单次 LLM 调用产出
   * lead 总起段 + picks[{token, intro}] 推荐对；本地目录校验（G5）后
   * 拼上引擎召回的 related 尾行。
   *
   * 答案顺序 = **LLM 叙事序**（首选在前），不经本地引擎重排——
   * 引擎只负责 related 尾行的召回排序。
   * `entries` 是本地目录的搜索索引（调用方从 BrewTable 组装，与主搜索同源）。
   * E1–E5 的降级在调用方（搜索页）处理：E1/E2/E3 → 本地搜索 + 通知条；
   * E4/E5 → 错误卡（重试 / 用本地搜索）。
   */
  public static askSearch(input: AiIntentInput, entries: BrewSearchEntry[]): Promise<AiSearchAnswer> {
    const cacheKey: string = slugOf(input.intent);
    const providerKey: string = AiTasks.providerModelKey();
    const cached: AiCacheLookup = AiTasks.lookup('d2', providerKey, cacheKey,
      AI_PROMPT_VERSION_D2, AI_CACHE_TTL_D2_MS);
    if (cached.hit) {
      const answer: AiSearchAnswer | null = AiTasks.parseAnswer(cached.dataJson, entries, input.intent);
      if (answer !== null) {
        Logger.info(TAG, `d2 cache hit key=${cacheKey} age=${cached.age}`);
        return Promise.resolve(answer);
      }
    }
    const task: AiClientTask = AiClient.newTask();
    task.system = AiTasks.D2_SYSTEM;
    task.user = `用户意图：${input.intent}\n请按 schema 输出 JSON。`;
    task.temperature = AI_TEMPERATURE_D2;
    task.maxTokens = AI_MAX_TOKENS_D2;
    return AiClient.complete(task).then((completion) => {
      const outcome: ParseOutcome = new ParseOutcome();
      const answer: AiSearchAnswer | null = AiTasks.parseAnswer(completion.content, entries,
        input.intent, outcome);
      if (answer === null) {
        throw new AiError(AiErrorKind.E4_BAD_FORMAT,
          `d2 reason=${e4ReasonOf(completion, outcome.reason)}`);
      }
      AiCache.write('d2', providerKey, cacheKey, AI_PROMPT_VERSION_D2, completion.model,
        JSON.stringify(completion.content));
      Logger.info(TAG, `d2 ok picks=${answer.picks.length} related=${answer.related.length} ` +
        `dropped=${answer.dropped} latency=${completion.latencyMs}`);
      return answer;
    });
  }

  /**
   * 解析 + 组装（G5）：LLM 文本 → lead + picks（目录过滤，token 用目录正字）+
   * related（引擎召回）。解析失败（非 JSON / 壳不符 / picks 超上限）返回 null（E4）。
   */
  private static parseAnswer(aiText: string, entries: BrewSearchEntry[], intent: string,
    outcome?: ParseOutcome): AiSearchAnswer | null {
    const raw: AiSearchAnswer | null = AiTasks.parsePicks(aiText, outcome);
    if (raw === null) {
      return null;
    }
    const known: Map<string, BrewSearchEntry> = new Map<string, BrewSearchEntry>();
    entries.forEach((entry: BrewSearchEntry) => {
      known.set(entry.token, entry);
    });
    const answer: AiSearchAnswer = new AiSearchAnswer();
    answer.lead = raw.lead;
    const seen: Set<string> = new Set<string>();
    raw.picks.forEach((pick: AiSearchPick) => {
      const token: string = pick.token.trim().toLowerCase();
      if (token.length === 0 || seen.has(token)) {
        return;
      }
      const entry: BrewSearchEntry | undefined = known.get(token);
      if (entry === undefined) {
        // 目录外名字（本机源里查不到）：进 missed 名单在答案尾部披露（m01462——
        // lead 说 5 个而只匹配 3 个会显得诡异），但不可点击、无详情、无安装入口
        // （G5 防 slopsquatting 的本质是防诱导，披露缺失恰是反诱导）。
        answer.dropped++;
        answer.missed.push(token);
        return;
      }
      seen.add(token);
      const kept: AiSearchPick = new AiSearchPick();
      kept.token = entry.token; // 目录正字（单一事实源），不信模型的大小写
      kept.intro = pick.intro;
      answer.picks.push(kept);
    });
    Logger.info(TAG, `d2 filtered dropped=${answer.dropped} kept=${answer.picks.length}`);
    // related 尾行召回：picks 不足 AI_D2_RESULT_LIMIT 时用意图原文跑一次引擎排序，
    // 取未被 AI 覆盖的条目补足。这些行**来自目录本身**，G5 无幻觉风险。
    // 「目录里查得到」是它唯一的出场资格——与 AI 推荐对（有介绍段）视觉区分。
    AiTasks.buildRelated(answer, entries, intent);
    return answer;
  }

  /**
   * related 尾行召回（原 supplementFromCatalog 的问答化变体）：引擎对意图原文的
   * 排序命中里，取未被 picks 覆盖的条目，补足到 AI_D2_RESULT_LIMIT 封顶、
   * AI_D2_TAIL_ROWS_MAX 截断。intro 恒空——渲染层用「目录中相关」标题区分。
   * picks 为空时同样生效（空态兜底：至少给目录相关结果）。
   */
  private static buildRelated(answer: AiSearchAnswer, entries: BrewSearchEntry[],
    intent: string): void {
    const room: number = Math.min(AI_D2_RESULT_LIMIT - answer.picks.length, AI_D2_TAIL_ROWS_MAX);
    if (room <= 0) {
      return;
    }
    const covered: Set<string> = new Set<string>();
    answer.picks.forEach((pick: AiSearchPick) => {
      covered.add(pick.token.trim().toLowerCase());
    });
    const hits: BrewSearchHit[] = BrewSearchEngine.rank(intent, entries, 0);
    let added: number = 0;
    for (let i: number = 0; i < hits.length && added < room; i++) {
      const hit: BrewSearchHit = hits[i];
      const token: string = hit.token.trim().toLowerCase();
      if (token.length === 0 || covered.has(token)) {
        continue;
      }
      covered.add(token);
      const rel: AiSearchPick = new AiSearchPick();
      rel.token = hit.token;
      rel.intro = ''; // 尾行无介绍段，由渲染层的标题承担身份
      answer.related.push(rel);
      added++;
    }
    if (added > 0) {
      Logger.info(TAG, `d2 related added=${added} total=${answer.picks.length + added}`);
    }
  }

  /**
   * LLM 文本 → {lead, picks} 原始结构（未做目录过滤）。
   * - 对象壳：`{"lead":"…","picks":[{token,intro}…]}`；
   * - 裸数组形态（结构性差异修复 ① 的沿用）：部分模型输出 `[{token,intro}…]`
   *   不带壳——接受为 picks（lead 空串）；
   * - picks 空数组合法（宁可不推荐的空态）；超 AI_D2_MAX_CANDIDATES 判 null（E4）；
   * - lead / intro 超长 **clamp**（不判 E4——字数溢出是内容问题不是结构问题）。
   */
  private static parsePicks(text: string, outcome?: ParseOutcome): AiSearchAnswer | null {
    // 裸数组形态探测：顶层就是数组且元素是 pick 对象（带非空 token）。
    const bare: AiSearchAnswer | null = AiTasks.parsePicksBareArray(text, outcome);
    if (bare !== null) {
      return bare;
    }
    return parseJsonSafe(text, (obj: Record<string, Object>): AiSearchAnswer | null => {
      const listObj: Object | undefined = obj['picks'];
      if (!Array.isArray(listObj)) {
        return null;
      }
      const picks: AiSearchPick[] | null = AiTasks.castPickList(listObj);
      if (picks === null) {
        return null;
      }
      const out: AiSearchAnswer = new AiSearchAnswer();
      out.lead = AiTasks.clampText(obj['lead'], AI_D2_LEAD_MAX_CHARS);
      out.picks = picks;
      if (outcome !== undefined) {
        outcome.reason = E4_REASON_OK;
      }
      return out;
    }, outcome);
  }

  /**
   * 裸数组形态探测（D2 专属）：顶层就是数组且元素是 pick 对象（带非空 token）。
   * 与 parseJsonSafe 尝试 3 的「数组包裹取首元素」互补——那条路把数组当包裹，
   * 这条路把数组当**数据本身**（lead 以空串兜底）。非 pick 数组返回 null 交回通用壳。
   */
  private static parsePicksBareArray(text: string, outcome?: ParseOutcome):
    AiSearchAnswer | null {
    let parsed: Object | null = tryParseObject(text);
    if (parsed !== null) {
      // 原文直接就是 JSON 对象：不是裸数组形态，交回对象壳
      return null;
    }
    // 直接 parse 失败（栅栏/前后缀包裹）才走剥离路径（与 parseJsonSafe 同口径）
    const body: string = stripJsonWrapping(text);
    parsed = tryParseArray(body);
    if (parsed === null) {
      return null;
    }
    const picks: AiSearchPick[] | null = AiTasks.castPickList(parsed);
    if (picks === null) {
      return null;
    }
    const out: AiSearchAnswer = new AiSearchAnswer();
    out.lead = '';
    out.picks = picks;
    if (outcome !== undefined) {
      outcome.reason = E4_REASON_OK;
    }
    return out;
  }

  /**
   * pick 数组逐条 cast（对象壳与裸数组壳共用）：
   * - 空数组 = **合法空态**：意图太泛时模型输出 `{"picks":[]}` 是「不确定的
   *   宁可不推荐」的正确行为，返回空列表走空态 UI，不再判 E4；
   * - 单条缺 token **跳过该条**（与 parseAnswer 的单条 drop 精神一致），不整页拒绝；
   * - 超上限才是格式不符（返回 null → E4）。
   */
  private static castPickList(listObj: Object): AiSearchPick[] | null {
    if (!Array.isArray(listObj)) {
      return null;
    }
    const list: Array<Object> = listObj as Array<Object>;
    if (list.length > AI_D2_MAX_CANDIDATES) {
      return null;
    }
    const out: AiSearchPick[] = [];
    for (let i: number = 0; i < list.length; i++) {
      const rec: Object | undefined = list[i];
      if (rec === undefined || rec === null) {
        continue;
      }
      const recObj: Record<string, Object> = rec as Record<string, Object>;
      const token: string = typeof recObj['token'] === 'string' ? recObj['token'] as string : '';
      if (token.trim().length === 0) {
        continue;
      }
      const intro: string = typeof recObj['intro'] === 'string' ? recObj['intro'] as string : '';
      const pick: AiSearchPick = new AiSearchPick();
      pick.token = token;
      pick.intro = AiTasks.clampText(intro, AI_D2_INTRO_MAX_CHARS);
      out.push(pick);
    }
    return out;
  }

  /** 字符串字段读取 + 超长截断（clamp 不判错：字数溢出是内容问题不是结构问题）。 */
  private static clampText(value: Object | undefined, maxChars: number): string {
    if (typeof value !== 'string') {
      return '';
    }
    const text: string = value as string;
    if (text.length <= maxChars) {
      return text;
    }
    return text.substring(0, maxChars);
  }

  private static readonly D2_SYSTEM: string = '你是 Homebrew 工具推荐助手。用户会用一句话描述想做的事' +
    '（中英文都可能），你给出一份「首选加次选」的推荐清单。' +
    '输出 JSON：{"lead":"一两句话总起，点明共几个工具、首选是谁",' +
    '"picks":[{"token":"包名（英文小写）","intro":"两三句中文介绍：它是什么、为什么适合用户的意图"}]}。' +
    '规则：最多 5 个 picks，顺序就是推荐顺序（最合适的放第一）；' +
    'token 只能是真实存在的 Homebrew 包名，**绝不编造**，拿不准就不要放进 picks；' +
    'lead 不超过 50 字；每条 intro 不超过 120 字，写「它是什么 + 为什么适合」；' +
    'lead 与 intro 用中文写（包名除外）；' +
    '**picks 必须是对象里的数组键，不要输出裸数组**；' +
    '没有合适的推荐就输出 {"lead":"","picks":[]}，这是合法结果，不要编造包名。' +
    AiTasks.PLATFORM_RULE;

  // ------------------------------------------------------------ D3 · 报错解读

  /** 报错解读（spec §6）。不缓存（每次失败现场解读）；下一步建议 UI 侧只给复制（G13）。 */
  public static explainFailure(input: AiFailureInput): Promise<AiFailureCard> {
    const task: AiClientTask = AiClient.newTask();
    task.system = AiTasks.D3_SYSTEM;
    task.user = AiTasks.d3UserPrompt(input);
    task.temperature = AI_TEMPERATURE_D3;
    task.maxTokens = AI_MAX_TOKENS_D3;
    return AiClient.complete(task).then((completion) => {
      const outcome: ParseOutcome = new ParseOutcome();
      const card: AiFailureCard | null = AiTasks.parseFailure(completion.content, outcome);
      if (card === null) {
        throw new AiError(AiErrorKind.E4_BAD_FORMAT,
          `d3 reason=${e4ReasonOf(completion, outcome.reason)}`);
      }
      Logger.info(TAG, `d3 ok latency=${completion.latencyMs}`);
      return card;
    });
  }

  private static d3UserPrompt(input: AiFailureInput): string {
    // 截断规则（spec §6）：stderr 尾部 ≤4KB、stdout 尾部 ≤2KB
    let stderr: string = input.stderrTail;
    let stdout: string = input.stdoutTail;
    if (stderr.length > AI_D3_STDERR_TAIL_CHARS) {
      stderr = stderr.substring(stderr.length - AI_D3_STDERR_TAIL_CHARS);
    }
    if (stdout.length > AI_D3_STDOUT_TAIL_CHARS) {
      stdout = stdout.substring(stdout.length - AI_D3_STDOUT_TAIL_CHARS);
    }
    let total: string = `命令: ${input.command}\n失败分类: ${input.failureKind}\n` +
      `包名: ${input.token}\nstderr(尾部):\n${stderr}\nstdout(尾部):\n${stdout}`;
    if ((AiTasks.D3_SYSTEM.length + total.length) > AI_PROMPT_MAX_CHARS) {
      // 总量超限时丢 stdout，再超限就把 stderr 砍半
      stdout = '';
      total = `命令: ${input.command}\n失败分类: ${input.failureKind}\n` +
        `包名: ${input.token}\nstderr(尾部):\n${stderr}\nstdout(尾部):\n`;
      while ((AiTasks.D3_SYSTEM.length + total.length) > AI_PROMPT_MAX_CHARS &&
        stderr.length > 64) {
        stderr = stderr.substring(stderr.length / 2);
        total = `命令: ${input.command}\n失败分类: ${input.failureKind}\n` +
          `包名: ${input.token}\nstderr(尾部):\n${stderr}\nstdout(尾部):\n`;
      }
    }
    return total + '\n请按 schema 输出 JSON。';
  }

  private static readonly D3_SYSTEM: string = '你是 Homebrew 命令报错解读助手。' +
    '基于给出的命令、失败分类与输出尾部，解释失败原因。用简体中文；只陈述输出里有依据的结论，' +
    '推测要标注「可能」。输出 JSON：{"what":"发生了什么，一句话","causes":["可能原因，最多3条"],' +
    '"nextSteps":["下一步建议，最多3条，可以包含具体命令"]}。' +
    AiTasks.PLATFORM_RULE;

  private static parseFailure(text: string, outcome?: ParseOutcome): AiFailureCard | null {
    return parseJsonSafe(text, (obj: Record<string, Object>): AiFailureCard | null => {
      const card: AiFailureCard = new AiFailureCard();
      card.what = typeof obj['what'] === 'string' ? obj['what'] as string : '';
      card.causes = stringArrayOf(obj['causes'], 3);
      card.nextSteps = stringArrayOf(obj['nextSteps'], 3);
      if (!card.isValid()) {
        return null;
      }
      return card;
    });
  }

  // ------------------------------------------------------------ RI · 更新情报摘要（Y）

  /**
   * 更新情报摘要（Y spec G8）：TTL 24h、stale-while-revalidate、promptVersion=ri-1。
   * 缓存键 `<token>_<to>`（同一目标版本只归纳一次；to 变了 = 新一次归纳）。
   * force（「重新生成」）旁路缓存直接取数（对齐 D1 的 2026-11-23 修复结论）。
   */
  public static releaseIntel(input: ReleaseIntelInput,
    onRefreshed?: (card: ReleaseIntelCard) => void, force: boolean = false): Promise<ReleaseIntelCard> {
    const cacheKey: string = `${input.token}_${input.to}`;
    const providerKey: string = AiTasks.providerModelKey();
    if (force) {
      return AiTasks.fetchIntel(input, providerKey, onRefreshed);
    }
    const cached: AiCacheLookup = AiTasks.lookup(RELEASE_INTEL_FEATURE, providerKey, cacheKey,
      AI_PROMPT_VERSION_RI, AI_CACHE_TTL_RI_MS);
    if (cached.hit) {
      const card: ReleaseIntelCard | null = AiTasks.parseIntel(cached.dataJson);
      if (card !== null) {
        Logger.info(TAG, `ri cache hit token=${input.token} age=${cached.age}`);
        return Promise.resolve(card);
      }
    }
    if (cached.stale) {
      const staleCard: ReleaseIntelCard | null = AiTasks.parseIntel(cached.dataJson);
      if (staleCard !== null) {
        Logger.info(TAG, `ri stale-while-revalidate token=${input.token}`);
        // 后台刷新失败只意味着继续用旧值，吞掉 rejection 防 unhandled
        AiTasks.fetchIntel(input, providerKey, onRefreshed)
          .catch((err: Error) => {
            Logger.warn(TAG, `ri background refresh failed. reason=${err.message}`);
          });
        return Promise.resolve(staleCard);
      }
    }
    return AiTasks.fetchIntel(input, providerKey, onRefreshed);
  }

  /**
   * 读「已有」的情报卡（档案钩子用，spec §3.3）：只查缓存不发请求，HIT/STALE 都收。
   * 升级完成时详情页大概率已经打开过情报卡（Y 的入口就在详情页），缓存命中是常态；
   * miss（用户没打开过）→ 返回 null，档案条目 cardJson 留空，档案区退化为版本区间行。
   */
  public static cachedIntelCard(token: string, to: string): ReleaseIntelCard | null {
    const providerKey: string = AiTasks.providerModelKey();
    const cached: AiCacheLookup = AiTasks.lookup(RELEASE_INTEL_FEATURE, providerKey,
      `${token}_${to}`, AI_PROMPT_VERSION_RI, AI_CACHE_TTL_RI_MS);
    if (cached.dataJson.length === 0) {
      return null;
    }
    return AiTasks.parseIntel(cached.dataJson);
  }

  private static fetchIntel(input: ReleaseIntelInput, providerKey: string,
    onRefreshed?: (card: ReleaseIntelCard) => void): Promise<ReleaseIntelCard> {
    const task: AiClientTask = AiClient.newTask();
    task.system = AiTasks.RI_SYSTEM;
    task.user = AiTasks.riUserPrompt(input);
    task.temperature = AI_TEMPERATURE_RI;
    task.maxTokens = AI_MAX_TOKENS_RI;
    const cacheKey: string = `${input.token}_${input.to}`;
    return AiClient.complete(task).then((completion) => {
      const outcome: ParseOutcome = new ParseOutcome();
      const card: ReleaseIntelCard | null = AiTasks.parseIntel(completion.content, outcome);
      if (card === null) {
        // 诊断打点（真机归因用）：finish=length 即 max_tokens 截断；tail 能看出
        // JSON 断在哪。head 由 AiClient 打点，这里补 tail 与总长。
        Logger.warn(TAG, `ri parse fail finish=${completion.finishReason} ` +
          `len=${completion.content.length} ` +
          `tail=${AiClient.sanitize(completion.content.substring(Math.max(0,
          completion.content.length - 80)))}`);
        throw new AiError(AiErrorKind.E4_BAD_FORMAT,
          `ri reason=${e4ReasonOf(completion, outcome.reason)}`);
      }
      // 缓存存**模型原始输出**（snake_case），与读侧 parseIntel 同口径——此前存
      // JSON.stringify(card)（驼峰），读侧按 snake_case 解析永远 miss，缓存形同虚设
      AiCache.write(RELEASE_INTEL_FEATURE, providerKey, cacheKey, AI_PROMPT_VERSION_RI,
        completion.model, completion.content);
      Logger.info(TAG, `ri ok token=${input.token} latency=${completion.latencyMs}`);
      if (onRefreshed !== undefined) {
        onRefreshed(card);
      }
      return card;
    });
  }

  private static riUserPrompt(input: ReleaseIntelInput): string {
    // grounding（spec G4）：notes（已剥标签 ≤4KB）+ diff JSON + 版本区间，没有别的。
    // notes 超限时循环砍半（对齐 D1 的 caveats 砍法）；diff 与版本区间是最小集合不砍。
    let notes: string = input.notes;
    let base: string = RiTasksPromptShell.of(input, notes);
    while ((AiTasks.RI_SYSTEM.length + base.length) > AI_PROMPT_MAX_CHARS && notes.length > 64) {
      notes = notes.substring(0, Math.floor(notes.length / 2));
      base = RiTasksPromptShell.of(input, notes);
    }
    return base + '\n请按 schema 输出 JSON。';
  }

  private static readonly RI_SYSTEM: string = '你是 Homebrew 包更新情报助手，向熟悉命令行的用户' +
    '归纳一次版本更新。只基于给定的 Release Notes 与本地 diff JSON 回答，用简体中文；' +
    'notes 没有的信息不得编造，没有依据的方面写进 gaps（如「无兼容性说明」）；' +
    '安全相关内容只逐条转述 notes 原文（security_claims），不得自行推断严重性或补充漏洞编号。' +
    'breaking_changes 每条给出 impact（对本机使用的影响）与 action（建议动作），' +
    '没有可靠依据时 action 输出空串。\n' +
    '条数硬上限（发布说明里条目再多也只挑最重要的，绝不超出）：new_features≤3、' +
    'fixes≤3、breaking_changes≤3、security_claims≤2、gaps≤3；每条控制在一句话。' +
    '输出必须是一个**完整**的 JSON 对象，不得中途截断。\n' +
    '空字段原则：new_features/fixes/breaking_changes/security_claims/gaps 没有内容时输出 []，' +
    '禁止输出「无」「暂无」之类的填充句。\n' +
    '输出 JSON：{"one_liner":"这次更新最值得注意什么，一句话","new_features":["0–3条"],' +
    '"fixes":["0–3条"],"breaking_changes":[{"title":"变更是什么","impact":"对本机使用的影响",' +
    '"action":"建议动作，可为空串"}],"security_claims":[{"claim":"上游自述原文转述"}],' +
    '"gaps":["0–3条"],"confidence":"full|partial|none"}。' +
    AiTasks.PLATFORM_RULE;

  private static parseIntel(text: string, outcome?: ParseOutcome): ReleaseIntelCard | null {
    return parseJsonSafe(text, (obj: Record<string, Object>): ReleaseIntelCard | null => {
      const card: ReleaseIntelCard = new ReleaseIntelCard();
      card.oneLiner = typeof obj['one_liner'] === 'string' ? obj['one_liner'] as string : '';
      card.newFeatures = stringArrayOf(obj['new_features'], 3);
      card.fixes = stringArrayOf(obj['fixes'], 3);
      card.gaps = stringArrayOf(obj['gaps'], 3);
      // breaking_changes 逐条 cast：缺 title 的条目跳过;超上限**截断**不整页拒绝
      // （v1.3.7b 修:此前 >3 整页 null→E4,cups 7 条 CVE 实证必炸;与 snapshotFromJson 同口径）
      const breaking: Object | undefined = obj['breaking_changes'];
      if (breaking !== undefined && Array.isArray(breaking)) {
        const list: Array<Object> = breaking as Array<Object>;
        for (let i: number = 0; i < list.length && card.breakingChanges.length < 3; i++) {
          const rec: Object | undefined = list[i];
          if (rec === undefined || rec === null) {
            continue;
          }
          const recObj: Record<string, Object> = rec as Record<string, Object>;
          const title: string = typeof recObj['title'] === 'string' ? recObj['title'] as string : '';
          if (title.trim().length === 0) {
            continue;
          }
          const item: ReleaseIntelBreakingChange = new ReleaseIntelBreakingChange();
          item.title = title;
          item.impact = typeof recObj['impact'] === 'string' ? recObj['impact'] as string : '';
          item.action = typeof recObj['action'] === 'string' ? recObj['action'] as string : '';
          card.breakingChanges.push(item);
        }
      }
      // security_claims 容两种元素形态：纯字符串（自述原文）或 {claim} 对象;超 2 条**截断**
      // （v1.3.7b 修:此前 >2 整页 null→E4,cups 7 条 CVE 实证必炸）
      const security: Object | undefined = obj['security_claims'];
      if (security !== undefined && Array.isArray(security)) {
        const list: Array<Object> = security as Array<Object>;
        for (let i: number = 0; i < list.length && card.securityClaims.length < 2; i++) {
          const rec: Object | undefined = list[i];
          if (rec === undefined || rec === null) {
            continue;
          }
          let claim: string = '';
          if (typeof rec === 'string') {
            claim = rec as string;
          } else {
            const recObj: Record<string, Object> = rec as Record<string, Object>;
            claim = typeof recObj['claim'] === 'string' ? recObj['claim'] as string : '';
          }
          if (claim.trim().length === 0) {
            continue;
          }
          const item: ReleaseIntelSecurityClaim = new ReleaseIntelSecurityClaim();
          item.claim = claim;
          card.securityClaims.push(item);
        }
      }
      const confidence: string =
        typeof obj['confidence'] === 'string' ? obj['confidence'] as string : '';
      if (confidence.length > 0) {
        card.confidence = confidence; // 非法值由 isValid 兜底判 false
      }
      if (!card.isValid()) {
        return null;
      }
      return card;
    });
  }

  // ------------------------------------------------------------ D4 · AI 发现流

  /**
   * AI 发现流取数（spec §3.4）：单次调用同时产出画像 + 10 个推荐。
   *
   * cacheKey = `d4_{安装集哈希}_{目录世代}_{locale}`——安装集 / 目录 / 语言任一变化
   * 都是新 key 自动 MISS；TTL 1 天，stale-while-revalidate；缓存存模型原始输出，
   * 读回重新走同一套解析 + G5 过滤（cacheKey 含 epoch 保证候选池未变）。
   *
   * force（「换一批」）旁路读缓存直接调用，prompt 附 exclude 列表（排除当前已展示
   * 的 picks），**照常写回同一 key**——安装集没变画像就不该变，换的是推荐不是画像。
   */
  public static discover(input: AiDiscoverInput, force: boolean = false): Promise<AiDiscoverResult> {
    const cacheKey: string = AiTasks.d4CacheKey(input);
    const providerKey: string = AiTasks.providerModelKey();
    if (force) {
      return AiTasks.fetchDiscover(input, providerKey, cacheKey);
    }
    const cached: AiCacheLookup = AiTasks.lookup(AI_FEATURE_D4, providerKey, cacheKey,
      AI_PROMPT_VERSION_D4, AI_CACHE_TTL_D4_MS);
    if (cached.hit) {
      const result: AiDiscoverResult | null = AiTasks.parseDiscover(cached.dataJson, input);
      if (result !== null) {
        Logger.info(TAG, `d4 cache hit picks=${result.picks.length} age=${cached.age}`);
        return Promise.resolve(result);
      }
    }
    if (cached.stale) {
      const staleResult: AiDiscoverResult | null = AiTasks.parseDiscover(cached.dataJson, input);
      if (staleResult !== null) {
        Logger.info(TAG, `d4 stale-while-revalidate picks=${staleResult.picks.length}`);
        // 后台刷新失败只意味着继续用旧值，吞掉 rejection 防 unhandled
        AiTasks.fetchDiscover(input, providerKey, cacheKey)
          .catch((err: Error) => {
            Logger.warn(TAG, `d4 background refresh failed. reason=${err.message}`);
          });
        return Promise.resolve(staleResult);
      }
    }
    return AiTasks.fetchDiscover(input, providerKey, cacheKey);
  }

  private static fetchDiscover(input: AiDiscoverInput, providerKey: string,
    cacheKey: string): Promise<AiDiscoverResult> {
    const task: AiClientTask = AiClient.newTask();
    task.system = AiTasks.d4System(input.locale);
    task.user = AiTasks.d4UserPrompt(input);
    task.temperature = AI_TEMPERATURE_D4;
    task.maxTokens = AI_MAX_TOKENS_D4;
    return AiClient.complete(task).then((completion) => {
      const outcome: ParseOutcome = new ParseOutcome();
      const result: AiDiscoverResult | null = AiTasks.parseDiscover(completion.content, input, outcome);
      if (result === null) {
        // 诊断打点（对齐 RI）：finish=length 即 max_tokens 截断；tail 看 JSON 断在哪
        Logger.warn(TAG, `d4 parse fail finish=${completion.finishReason} ` +
          `len=${completion.content.length} ` +
          `tail=${AiClient.sanitize(completion.content.substring(Math.max(0,
          completion.content.length - 80)))}`);
        throw new AiError(AiErrorKind.E4_BAD_FORMAT,
          `d4 reason=${e4ReasonOf(completion, outcome.reason)}`);
      }
      // 缓存存模型原始输出，读侧 parseDiscover 同口径（对齐 D2 / RI 的教训）
      AiCache.write(AI_FEATURE_D4, providerKey, cacheKey, AI_PROMPT_VERSION_D4,
        completion.model, completion.content);
      Logger.info(TAG, `d4 ok picks=${result.picks.length} dropped=${result.dropped} ` +
        `droppedInstalled=${result.droppedInstalled} latency=${completion.latencyMs}`);
      return result;
    });
  }

  /**
   * cacheKey：`d4_{fnv1a32(安装集签名)}_{epoch}_{locale}`。
   * 签名 = 排序小写 token 逗号连接（顺序无关）；≤64 chars 满足 AiCache.pathOf 的
   * sanitize 预算（8 hex + epoch + locale + 两段前缀 ≈ 20+ chars）。
   */
  private static d4CacheKey(input: AiDiscoverInput): string {
    const tokens: string[] = [];
    for (const one of input.installed) {
      tokens.push(one.token.toLowerCase().trim());
    }
    tokens.sort();
    const sig: string = fnv1a32(tokens.join(','));
    return `d4_${sig}_${input.epoch}_${input.locale}`;
  }

  /**
   * user prompt（spec §3.2 紧凑格式）。预算超限时的收缩顺序：
   * 候选池两侧各减 20（保 vol30d 最高的头部），到 40/26 的下限后交给
   * AiClient 的 8KB 守卫（E4 兜底，正常数据量不可达——7.6K 常态预算见 spec）。
   */
  private static d4UserPrompt(input: AiDiscoverInput): string {
    let formulaCount: number = AI_D4_POOL_FORMULA;
    let caskCount: number = AI_D4_POOL_CASK;
    let lines: string[] = AiTasks.d4PromptLines(input, formulaCount, caskCount);
    while ((AiTasks.d4System(input.locale).length + lines.join('\n').length) > AI_PROMPT_MAX_CHARS &&
      formulaCount > 40) {
      formulaCount -= 20;
      caskCount = Math.max(26, caskCount - 20);
      lines = AiTasks.d4PromptLines(input, formulaCount, caskCount);
    }
    return lines.join('\n') + '\n请按 schema 输出 JSON。';
  }

  /** prompt 的分段行（installed / candidates / exclude），两处调用保持口径一致 */
  private static d4PromptLines(input: AiDiscoverInput, formulaCount: number,
    caskCount: number): string[] {
    const lines: string[] = [];
    lines.push(`locale: ${input.locale}`);
    // installed：kind 前缀 + `*` = 近 30 天安装（画像的新鲜信号）
    lines.push('installed (f=formula c=cask *=installed within 30d):');
    let fLine: string = 'f:';
    let cLine: string = 'c:';
    for (const one of input.installed) {
      const entry: string = `${one.token}${one.recent ? '*' : ''}`;
      if (one.kind === 'cask') {
        cLine += ` ${entry}`;
      } else {
        fLine += ` ${entry}`;
      }
    }
    if (fLine.length > 2) {
      lines.push(fLine);
    }
    if (cLine.length > 2) {
      lines.push(cLine);
    }
    // candidates：kind + token + 分类（模型聚类线索）；候选池已按 vol30d 降序
    lines.push('candidates (kind: token [category]):');
    let fLeft: number = formulaCount;
    let cLeft: number = caskCount;
    for (const one of input.candidates) {
      if (one.kind === 'cask') {
        if (cLeft <= 0) {
          continue;
        }
        cLeft--;
      } else {
        if (fLeft <= 0) {
          continue;
        }
        fLeft--;
      }
      lines.push(`${one.kind === 'cask' ? 'c' : 'f'}: ${one.token} [${one.categoryKey}]`);
    }
    // exclude：仅换一批（force）时出现
    if (input.exclude.length > 0) {
      lines.push(`exclude (do not recommend again): ${input.exclude.join(' ')}`);
    }
    return lines;
  }

  /** system prompt（spec §3.2 schema）。locale 插值：画像文本按 UI 语言输出。 */
  private static d4System(locale: string): string {
    return '你是 Homebrew 生态的个性化推荐引擎。根据用户已安装的包推断用户画像，' +
      '并从候选池中推荐最符合画像的包。严格输出 JSON，不要输出其他内容：\n' +
      '{"profile":{"headline":"画像一句话，第二人称「你」，概括技术角色与偏好",' +
      '"tags":["画像标签，1-4个"],"basis":"画像依据，引用最具代表性的已安装包"},' +
      '"picks":[{"token":"候选池里的包名，原样照抄","kind":"formula|cask",' +
      '"why":"为什么推荐给这个画像，要具体贴合画像，不复述包功能"}]}\n' +
      '规则：picks 恰好 10 个；token 只能取自候选池，禁止编造；' +
      '不推荐已安装列表里出现过的包；formula 与 cask 混合，比例贴合画像；' +
      `headline ≤30 字、tags 每个 ≤8 字、basis ≤40 字、why 每个 ≤40 字；` +
      `全部文本用 ${locale === 'en' ? '英文' : '简体中文'}。\n` +
      '输出必须是一个**完整**的 JSON 对象，不得中途截断。\n' +
      AiTasks.PLATFORM_RULE;
  }

  /**
   * D4 解析（spec §3.3）：profile 逐字段校验（isValid）；picks 条数 ∈ [3,10]
   * （超 10 视为 schema 不符 → E4）；token 规范化小写后过**候选池**（G5 防幻影）
   * 与**已安装**两道过滤，丢弃计数进结果（只进日志不进 UI）；重复 token 保留首个。
   *
   * kind 不信模型输出——候选池命中即取池内的 kind（G5 单一事实源）。
   */
  private static parseDiscover(text: string, input: AiDiscoverInput,
    outcome?: ParseOutcome): AiDiscoverResult | null {
    // G5 与已安装过滤的查找结构（闭包捕获；parseJsonSafe 最多重试三次，重建成本可忽略）
    const candidateByToken: Map<string, AiCandidate> = new Map<string, AiCandidate>();
    for (const one of input.candidates) {
      candidateByToken.set(one.token.toLowerCase().trim(), one);
    }
    const installedSet: Set<string> = new Set<string>();
    for (const one of input.installed) {
      installedSet.add(one.token.toLowerCase().trim());
    }
    return parseJsonSafe(text, (obj: Record<string, Object>): AiDiscoverResult | null => {
      // ---- profile ----
      const profileRaw: Object | undefined = obj['profile'];
      if (profileRaw === undefined || profileRaw === null || Array.isArray(profileRaw)) {
        return null;
      }
      const profileObj: Record<string, Object> = profileRaw as Record<string, Object>;
      const profile: AiDiscoverProfile = new AiDiscoverProfile();
      profile.headline = typeof profileObj['headline'] === 'string' ? profileObj['headline'] as string : '';
      profile.tags = stringArrayOf(profileObj['tags'], AI_D4_PROFILE_TAGS_MAX);
      profile.basis = typeof profileObj['basis'] === 'string' ? profileObj['basis'] as string : '';
      if (!profile.isValid()) {
        Logger.warn(TAG, `d4 profile invalid headline=${profile.headline.length} ` +
          `tags=${profile.tags.length} basis=${profile.basis.length}`);
        return null;
      }
      // ---- picks ----
      const picksRaw: Object | undefined = obj['picks'];
      if (picksRaw === undefined || !Array.isArray(picksRaw)) {
        return null;
      }
      const list: Array<Object> = picksRaw as Array<Object>;
      if (list.length < AI_D4_PICKS_MIN || list.length > AI_D4_PICKS) {
        Logger.warn(TAG, `d4 picks count=${list.length} out of range`);
        return null;
      }
      const result: AiDiscoverResult = new AiDiscoverResult();
      result.profile = profile;
      const seen: Set<string> = new Set<string>();
      for (const rec of list) {
        if (rec === undefined || rec === null) {
          continue;
        }
        const recObj: Record<string, Object> = rec as Record<string, Object>;
        const token: string = typeof recObj['token'] === 'string' ?
          (recObj['token'] as string).toLowerCase().trim() : '';
        const why: string = typeof recObj['why'] === 'string' ? recObj['why'] as string : '';
        if (token.length === 0 || why.trim().length === 0 || why.length > AI_D4_WHY_MAX_CHARS) {
          result.dropped++;
          continue;
        }
        if (seen.has(token)) {
          continue; // 去重：保留首个，不计 dropped
        }
        if (installedSet.has(token)) {
          result.droppedInstalled++;
          continue;
        }
        const candidate: AiCandidate | undefined = candidateByToken.get(token);
        if (candidate === undefined) {
          result.dropped++; // G5：幻影 token（候选池外 = 目录外）
          continue;
        }
        seen.add(token);
        const pick: AiDiscoverPick = new AiDiscoverPick();
        pick.token = candidate.token;
        pick.kind = candidate.kind;
        pick.why = why.trim();
        result.picks.push(pick);
      }
      if (result.picks.length < AI_D4_PICKS_MIN) {
        Logger.warn(TAG, `d4 survivors=${result.picks.length} below min, ` +
          `dropped=${result.dropped} droppedInstalled=${result.droppedInstalled}`);
        return null;
      }
      return result;
    }, outcome);
  }

  // ------------------------------------------------------------ 缓存与工具

  /** providerModel 缓存段：`<provider>_<model>`（sanitize 在 AiCache 里再做）。 */
  public static providerModelKey(): string {
    const config = AiSettingsStore.loadConfig();
    return `${config.provider}_${config.model}`.toLowerCase();
  }

  private static lookup(feature: string, providerKey: string, cacheKey: string,
    promptVersion: number, ttlMs: number): AiCacheLookup {
    const out: AiCacheLookup = new AiCacheLookup();
    const read = AiCache.read(feature, providerKey, cacheKey, promptVersion, ttlMs);
    if (read.result === AiCacheReadResult.HIT && read.envelope !== null) {
      out.hit = true;
      out.stale = false;
      out.dataJson = read.envelope.dataJson;
      out.model = read.envelope.model;
      out.age = Date.now() - read.envelope.fetchedAt;
      return out;
    }
    if (read.result === AiCacheReadResult.STALE && read.envelope !== null) {
      out.stale = true;
      out.dataJson = read.envelope.dataJson;
      out.model = read.envelope.model;
      out.age = Date.now() - read.envelope.fetchedAt;
      return out;
    }
    out.missReason = read.missReason;
    Logger.info(TAG, `cache miss feature=${feature} reason=${read.missReason}`);
    return out;
  }
}

// ------------------------------------------------------- 模块级工具函数

/** ri prompt 的拼装壳（超限砍半循环里复用，保持两次拼装口径一致）。 */
class RiTasksPromptShell {
  public static of(input: ReleaseIntelInput, notes: string): string {
    return `包名: ${input.token}\n版本区间: ${input.from} → ${input.to}\n` +
      `本地结构化 diff(JSON): ${input.diffJson}\n` +
      `上游 Release Notes(纯文本，超长已截断):\n${notes}`;
  }
}

/** E4 的 reason 判定：finishReason=length 即截断；其余用解析层的归类（schema/fence/nonjson）。 */
function e4ReasonOf(completion: AiCompletion2, parseReason: string): string {
  if (completion.finishReason === 'length') {
    return 'truncated';
  }
  return parseReason.length > 0 ? parseReason : 'schema';
}


/** 意图 → 缓存 key 的 slug（非字母数字折 `-`；中文意图在 AI 模式也能成为合法文件名段）。 */
function slugOf(text: string): string {
  let out: string = '';
  for (let i: number = 0; i < text.length; i++) {
    const ch: string = text.charAt(i).toLowerCase();
    const isAlnum: boolean = (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9');
    out += isAlnum ? ch : '-';
  }
  const trimmed: string = out.replace(/-+/g, '-');
  return trimmed.length === 0 ? 'empty' : trimmed.substring(0, 48);
}

/**
 * 剥离 provider 输出里的非 JSON 包裹（spec §3.2 兼容性修复 ①）。
 *
 * 自建/第三方 OpenAI 兼容端点常忽略 `response_format: json_object`，输出带
 * ```` ```json ```` 代码栅栏或「好的，以下是结果：」之类前后缀文本。策略：
 *   1. 先剥 markdown 代码栅栏（```json …``` / ``` …```）；
 *   2. 再取首个 `{` 到最后一个 `}` 的子串（前后缀文本一并剥掉）。
 * 都不奏效时原样返回，让 JSON.parse 自己报错（走 E4 通用路径）。
 */
function stripJsonWrapping(text: string): string {
  let out: string = text.trim();
  const fenceStart: number = out.indexOf('```');
  if (fenceStart >= 0) {
    // 跳过栅栏行（```json / ```）
    const lineBreak: number = out.indexOf('\n', fenceStart);
    if (lineBreak > fenceStart) {
      out = out.substring(lineBreak + 1);
    }
    const fenceEnd: number = out.lastIndexOf('```');
    if (fenceEnd >= 0) {
      out = out.substring(0, fenceEnd);
    }
    out = out.trim();
  }
  const braceStart: number = out.indexOf('{');
  const braceEnd: number = out.lastIndexOf('}');
  if (braceStart >= 0 && braceEnd > braceStart) {
    return out.substring(braceStart, braceEnd + 1);
  }
  return out;
}

/**
 * 一次解析尝试的 reason 归类（E4 细分，UI 与日志共用）：
 *   - 'ok'：解析且校验通过；
 *   - 'schema'：JSON 合法但字段校验不过；
 *   - 'fence'：剥离包裹后仍不是合法 JSON 对象；
 *   - 'nonjson'：剥离后连 `{` 都没有——端点返回了 HTML 错误页 / 纯文本
 *     （路径错、鉴权失败、网关拦截的典型形态），文案引导检查端点与 Key。
 */
const E4_REASON_OK: string = 'ok';
const E4_REASON_SCHEMA: string = 'schema';
const E4_REASON_FENCE: string = 'fence';
const E4_REASON_NONJSON: string = 'nonjson';

/**
 * JSON 解析 + 对象级校验的统一壳。
 *
 * 尝试顺序：原文直接 parse → 剥离包裹（栅栏 / 前后缀）parse → 数组包裹（`[...]`，
 * 部分端点对小 prompt 返回数组）取首元素 parse。`reasonOut.reason` 带回归类供
 * 调用方抛带 reason 的 E4；找不到任何 `{` / `[` 时归 nonjson。
 */
class ParseOutcome {
  public reason: string = E4_REASON_OK;
}

function parseJsonSafe<T>(text: string, cast: (obj: Record<string, Object>) => T | null,
  reasonOut?: ParseOutcome): T | null {
  const setReason = (r: string): void => {
    if (reasonOut !== undefined) {
      reasonOut.reason = r;
    }
  };
  // ---- 尝试 1：原文直接 parse ----
  let parsed: Object | null = tryParseObject(text);
  if (parsed !== null) {
    const casted: T | null = cast(parsed as Record<string, Object>);
    if (casted === null) {
      Logger.warn(TAG, `json schema mismatch, reason=schema, len=${text.length}`);
      setReason(E4_REASON_SCHEMA);
      return null;
    }
    setReason(E4_REASON_OK);
    return casted;
  }
  // ---- 尝试 2：剥离栅栏 / 前后缀 ----
  const body: string = stripJsonWrapping(text);
  // 剥离后既无 `{` 也无 `[`：端点给的不是 JSON（HTML 错误页 / 纯文本），单独归类
  if (body.indexOf('{') < 0 && body.indexOf('[') < 0) {
    Logger.warn(TAG, `json parse failed, reason=nonjson, len=${body.length}`);
    setReason(E4_REASON_NONJSON);
    return null;
  }
  parsed = tryParseObject(body);
  if (parsed !== null) {
    const casted: T | null = cast(parsed as Record<string, Object>);
    if (casted === null) {
      Logger.warn(TAG, `json schema mismatch, reason=schema, len=${body.length}`);
      setReason(E4_REASON_SCHEMA);
      return null;
    }
    setReason(E4_REASON_OK);
    return casted;
  }
  // ---- 尝试 3：JSON 数组包裹（取首个对象元素）----
  const arrStart: number = body.indexOf('[');
  const arrEnd: number = body.lastIndexOf(']');
  if (arrStart >= 0 && arrEnd > arrStart) {
    const arrParsed: Object | null = tryParseObject(body.substring(arrStart, arrEnd + 1));
    if (arrParsed !== null && Array.isArray(arrParsed)) {
      const list: Array<Object> = arrParsed as Array<Object>;
      if (list.length > 0) {
        const first: Object | undefined = list[0];
        if (first !== undefined && first !== null) {
          const casted: T | null = cast(first as Record<string, Object>);
          if (casted === null) {
            Logger.warn(TAG, `json schema mismatch, reason=schema, len=${body.length}`);
            setReason(E4_REASON_SCHEMA);
            return null;
          }
          setReason(E4_REASON_OK);
          return casted;
        }
      }
    }
  }
  Logger.warn(TAG, `json parse failed, reason=fence, len=${body.length}`);
  setReason(E4_REASON_FENCE);
  return null;
}

/** tryParseObject：JSON.parse 且结果必须是对象（非数组）时返回，否则 null。 */
function tryParseObject(text: string): Object | null {
  try {
    const parsed: Object = JSON.parse(text) as Object;
    if (parsed === null || parsed === undefined || Array.isArray(parsed)) {
      return null;
    }
    return parsed;
  } catch (err) {
    return null;
  }
}

/** tryParseArray：JSON.parse 且结果必须是数组时返回，否则 null（裸数组形态探测用）。 */
function tryParseArray(text: string): Object | null {
  try {
    const parsed: Object = JSON.parse(text) as Object;
    if (parsed === null || parsed === undefined || !Array.isArray(parsed)) {
      return null;
    }
    return parsed;
  } catch (err) {
    return null;
  }
}

/**
 * string[] 字段抽取：非数组 → 空表；元素非串/空白串跳过；**超上限截断取前 max 条**
 * （v1.3.8：此前超限整段丢弃返回 []——模型多写一条就整段白费，截断保住已有内容；
 * isValid 的上限校验仍兜底）。
 */
function stringArrayOf(value: Object | undefined, max: number): string[] {
  if (value === undefined || !Array.isArray(value)) {
    return [];
  }
  const list: Array<Object> = value as Array<Object>;
  const out: string[] = [];
  for (let i: number = 0; i < list.length && out.length < max; i++) {
    const one: Object = list[i];
    if (typeof one !== 'string') {
      continue;
    }
    const text: string = one as string;
    if (text.trim().length === 0) {
      continue;
    }
    out.push(text);
  }
  return out;
}
