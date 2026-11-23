/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { Logger } from '@ohos/common';
import { BrewSearchEngine } from '../model/BrewSearchEngine';
import type { BrewSearchEntry, BrewSearchHit } from '../model/BrewSearchEngine';
import {
  AI_CACHE_TTL_BI_MS,
  AI_CACHE_TTL_D1_MS,
  AI_CACHE_TTL_D2_MS,
  AI_CACHE_TTL_LC_MS,
  AI_D2_MAX_CANDIDATES,
  AI_D2_RESULT_LIMIT,
  AI_D3_STDERR_TAIL_CHARS,
  AI_D3_STDOUT_TAIL_CHARS,
  AI_FEATURE_BI,
  AI_FEATURE_LC,
  AI_PROMPT_MAX_CHARS,
  AI_MAX_TOKENS_BI,
  AI_MAX_TOKENS_D1,
  AI_MAX_TOKENS_D2,
  AI_MAX_TOKENS_D3,
  AI_MAX_TOKENS_LC,
  AI_MAX_TOKENS_SD,
  AI_PROMPT_VERSION_BI,
  AI_PROMPT_VERSION_D1,
  AI_PROMPT_VERSION_D2,
  AI_PROMPT_VERSION_LC,
  AI_PROMPT_VERSION_SD,
  AI_TEMPERATURE_BI,
  AI_TEMPERATURE_D1,
  AI_TEMPERATURE_D2,
  AI_TEMPERATURE_D3,
  AI_TEMPERATURE_LC,
  AI_TEMPERATURE_SD,
} from '../constant/AiConstants';
import {
  AiError,
  AiErrorKind,
  AiExplainCard,
  AiExplainInput,
  AiFailureCard,
  AiFailureInput,
  AiIntentInput,
  AiBoardInsightInput,
  AiDiagnosisInput,
  AiInsightCard,
  AiLifecycleInput,
  AiToolCandidate,
  AiToolResult,
  aiMaskLocalPaths,
} from '../model/AiTypes';
import { AnalyticsNumberParser } from '../util/AnalyticsNumberParser';
import { AiCache, AiCacheReadResult } from './AiCache';
import { AiClient } from './AiClient';
import type { AiClientTask, AiCompletion as AiCompletion2 } from './AiClient';
import { AiSettingsStore } from './AiSettingsStore';
import { AiTaskWords as AiTaskWordsStatic, AiTaskWord } from '../util/AiTaskWords';

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
    // grounding：全部字段来自详情页既有数据；超限先截 caveats（spec §4）。
    // 二期 P1-2：追加依赖/版本口径字段（buildDependencies / usesFromMacos /
    // aliases / versionedFormulae / bottleTags），模型据此输出 deps_explain / version_notes。
    let caveats: string = input.caveats;
    let deps: string = input.dependencies.join(', ');
    let base: string = AiTasks.d1GroundingBase(input, caveats, deps);
    while ((AiTasks.D1_SYSTEM.length + base.length) > AI_PROMPT_MAX_CHARS &&
      caveats.length > 0) {
      // 先砍 caveats，再砍 dependencies；desc 与 token 是定位的最小集合，不砍
      caveats = caveats.substring(0, Math.floor(caveats.length / 2));
      base = AiTasks.d1GroundingBase(input, caveats, deps);
      if (caveats.length < 32) {
        caveats = '';
        deps = '';
        base = AiTasks.d1GroundingBase(input, caveats, deps);
        break;
      }
    }
    return base + '\n请按 schema 输出 JSON。';
  }

  /** D1 grounding 正文（caveats/deps 由截断循环控制，其余字段原样拼装）。 */
  private static d1GroundingBase(input: AiExplainInput, caveats: string, deps: string): string {
    let extra: string = '';
    if (input.buildDependencies.length > 0) {
      extra += `\nbuild_dependencies: ${input.buildDependencies.join(', ')}`;
    }
    if (input.usesFromMacos.length > 0) {
      extra += `\nuses_from_macos: ${input.usesFromMacos.join(', ')}（macOS 系统自带库，不会重复安装）`;
    }
    if (input.aliases.length > 0) {
      extra += `\naliases: ${input.aliases.join(', ')}`;
    }
    if (input.versionedFormulae.length > 0) {
      extra += `\nversioned_formulae: ${input.versionedFormulae.join(', ')}`;
    }
    if (input.bottleTags.length > 0) {
      extra += `\nbottle_tags: ${input.bottleTags.join(', ')}`;
    }
    return `token: ${input.token}\nkind: ${input.kind}\ndesc: ${input.desc}\n` +
      `caveats: ${caveats}\ndependencies: ${deps}${extra}`;
  }

  private static readonly D1_SYSTEM: string = '你是 Homebrew 包讲解助手，像懂行的朋友向新手介绍这个包，' +
    '不是在填表。只基于用户提供的字段回答，用简体中文；不得虚构版本号、命令或功能；' +
    'caveats 是英文原文时翻译成中文并归纳风险点；字段里没有的信息就直说无法判断。\n' +
    '风格：要点 2–5 条、长短自然，不硬凑等长；summary 用自然的口语衔接，不用「该包」「本工具」开头。\n' +
    '空字段原则：某输入字段为空（caveats/dependencies 栏空白）时，对应数组输出 []，' +
    '**禁止**输出「未提供」「为空」「暂无」之类的填充句——宁可少一段，不写废话。\n' +
    'deps_explain：解释这个包为什么带这些依赖、构建依赖与运行依赖的差别、' +
    'uses_from_macos 是 macOS 系统自带库不会重复安装；没有可解释的就输出 []。\n' +
    'version_notes：解释版本口径——bottle_tags 表示官方预编译覆盖的平台、' +
    'versioned_formulae 是并行安装的版本化配方、aliases 是别名；没有可说的就输出 []。\n' +
    '输出仍然必须是 JSON，字段结构不变：' +
    '{"summary":"定位一句话或两句话","scenarios":["适用场景，0–3条，自然短语"],' +
    '"caveats":["注意与坑，0–3条"],"steps":["上手步骤，2–3条，命令要可直接复制"],' +
    '"deps_explain":["依赖与版本解释，0–3条"],"version_notes":["版本口径备注，0–2条"]}。';

  private static parseExplain(text: string, outcome?: ParseOutcome): AiExplainCard | null {
    return parseJsonSafe(text, (obj: Record<string, Object>): AiExplainCard | null => {
      const card: AiExplainCard = new AiExplainCard();
      card.summary = typeof obj['summary'] === 'string' ? obj['summary'] as string : '';
      card.scenarios = stringArrayOf(obj['scenarios'], 3);
      card.caveats = stringArrayOf(obj['caveats'], 3);
      // steps 上限 3（isValid 收 2–3 条）；解析层 6 是给「超限即格式不符」判据留的余量口径不变
      card.steps = stringArrayOf(obj['steps'], 3);
      // 二期 P1-2：依赖与版本两段（空数组 UI 不渲染该分区）
      card.depsExplain = stringArrayOf(obj['deps_explain'], 3);
      card.versionNotes = stringArrayOf(obj['version_notes'], 2);
      if (!card.isValid()) {
        return null;
      }
      return card;
    });
  }

  // ------------------------------------------------------------ D2 · 找工具

  /**
   * AI 找工具（spec §5）：提名 → 目录过滤（G5）→ 引擎排序 → 截断。
   *
   * `entries` 是本地目录的搜索索引（调用方从 BrewTable 组装，与主搜索同源）。
   * AI 模式失败（E2/E3/E4）时**不在这里**降级——调用方拿 `AiError.kind` 自己决定
   * 是否切词表模式（spec §8 的降级矩阵）。
   */
  public static findTools(input: AiIntentInput, entries: BrewSearchEntry[]): Promise<AiToolResult> {
    const cacheKey: string = slugOf(input.intent);
    const providerKey: string = AiTasks.providerModelKey();
    const cached: AiCacheLookup = AiTasks.lookup('d2', providerKey, cacheKey,
      AI_PROMPT_VERSION_D2, AI_CACHE_TTL_D2_MS);
    if (cached.hit) {
      const result: AiToolResult | null = AiTasks.filterAndRank(cached.dataJson, entries, input.intent);
      if (result !== null) {
        Logger.info(TAG, `d2 cache hit key=${cacheKey} age=${cached.age}`);
        return Promise.resolve(result);
      }
    }
    const task: AiClientTask = AiClient.newTask();
    task.system = AiTasks.D2_SYSTEM;
    task.user = `用户意图：${input.intent}\n请按 schema 输出 JSON。`;
    task.temperature = AI_TEMPERATURE_D2;
    task.maxTokens = AI_MAX_TOKENS_D2;
    return AiClient.complete(task).then((completion) => {
      const outcome: ParseOutcome = new ParseOutcome();
      const result: AiToolResult | null = AiTasks.filterAndRank(completion.content, entries,
        input.intent, outcome);
      if (result === null) {
        throw new AiError(AiErrorKind.E4_BAD_FORMAT,
          `d2 reason=${e4ReasonOf(completion, outcome.reason)}`);
      }
      AiCache.write('d2', providerKey, cacheKey, AI_PROMPT_VERSION_D2, completion.model,
        JSON.stringify(completion.content));
      Logger.info(TAG, `d2 ok dropped=${result.dropped} kept=${result.candidates.length} ` +
        `latency=${completion.latencyMs}`);
      return result;
    });
  }

  /**
   * 离线词表模式（G6）：中文意图 → 词表条目 → 候选去重 → 引擎排序。
   * **不发任何请求**。命中空表的意图由 UI 显示空态。
   */
  public static findToolsOffline(intent: string, entries: BrewSearchEntry[],
    words: AiTaskWord[]): AiToolResult {
    const result: AiToolResult = new AiToolResult();
    const seen: Set<string> = new Set<string>();
    const hits: AiTaskWord[] =
      AiTasks.wordlistMatch(intent, words);
    hits.forEach((word) => {
      word.tokens.forEach((token: string) => {
        if (!seen.has(token)) {
          seen.add(token);
          const cand: AiToolCandidate = new AiToolCandidate();
          cand.token = token;
          cand.why = word.note;
          result.candidates.push(cand);
        }
      });
    });
    return AiTasks.rankCandidates(result, entries, intent);
  }

  private static wordlistMatch(intent: string, words: AiTaskWord[]): AiTaskWord[] {
    // 与 `AiTaskWords.match()` 同口径（精确 / 前缀）。AiTaskWords 是零依赖纯工具类，
    // 这里直接 import 不构成循环；匹配逻辑收在 AiTaskWords 一处、这里只做转发更干净。
    return AiTaskWordsStatic.match(intent, words);
  }

  /** 目录过滤 + 引擎排序（G5 / spec §5 第 2、3 步）。AI 文本解析失败返回 null（E4）。 */
  private static filterAndRank(aiText: string, entries: BrewSearchEntry[], intent: string,
    outcome?: ParseOutcome): AiToolResult | null {
    const candidates: AiToolCandidate[] | null = AiTasks.parseCandidates(aiText, outcome);
    if (candidates === null) {
      return null;
    }
    const known: Map<string, BrewSearchEntry> = new Map<string, BrewSearchEntry>();
    entries.forEach((entry: BrewSearchEntry) => {
      known.set(entry.token, entry);
    });
    const result: AiToolResult = new AiToolResult();
    const seen: Set<string> = new Set<string>();
    candidates.forEach((cand: AiToolCandidate) => {
      const token: string = cand.token.trim().toLowerCase();
      if (token.length === 0 || seen.has(token)) {
        return;
      }
      if (!known.has(token)) {
        // 目录外名字：计数进日志，**名单不留存、不展示**（G5 防 slopsquatting）
        result.dropped++;
        return;
      }
      seen.add(token);
      result.candidates.push(cand);
    });
    Logger.info(TAG, `d2 filtered dropped=${result.dropped} kept=${result.candidates.length}`);
    AiTasks.rankCandidates(result, entries, intent);
    // 目录侧补充召回（spec §5 第 2.5 步）：LLM 的知识里没有 Harmonybrew 特有包
    // （鸿蒙生态 token 不在训练语料里），提名阶段就永远不会出现——但本地目录索引
    // 有。结果不足 LIMIT 时用意图原文跑一次引擎排序，取未被 AI 候选覆盖的条目
    // 补足（why 用固定模板文案，与 AI 提名行区分）。这些行**来自目录本身**，
    // G5 无幻觉风险。空态也受益：AI 候选 + 词表全空时仍可能有目录相关结果。
    AiTasks.supplementFromCatalog(result, entries, intent);
    return result;
  }

  /**
   * 目录补充召回：引擎对意图原文的排序命中里，取未被 AI 候选覆盖的条目补进结果
   * （补足到 AI_D2_RESULT_LIMIT 封顶）。AI 候选为空时同样生效——「候选太少」与
   * 「空态」统一退化为「至少有目录相关结果」。dropped 只统计 AI 提名的目录外数，
   * 补充行不计入。
   */
  private static supplementFromCatalog(result: AiToolResult, entries: BrewSearchEntry[],
    intent: string): void {
    const room: number = AI_D2_RESULT_LIMIT - result.candidates.length;
    if (room <= 0) {
      return;
    }
    const covered: Set<string> = new Set<string>();
    result.candidates.forEach((cand: AiToolCandidate) => {
      covered.add(cand.token.trim().toLowerCase());
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
      const cand: AiToolCandidate = new AiToolCandidate();
      cand.token = hit.token;
      cand.why = ''; // why 由渲染层用 ai_d2_related 资源文案（补充行标记），不走 AI 文本
      result.candidates.push(cand);
      added++;
    }
    if (added > 0) {
      Logger.info(TAG, `d2 supplement added=${added} total=${result.candidates.length}`);
    }
  }

  /** 引擎重排：AI 只提名，顺序由 BrewSearchEngine 说了算（spec §5 第 3 步）。 */
  private static rankCandidates(result: AiToolResult, entries: BrewSearchEntry[],
    intent: string): AiToolResult {
    if (result.candidates.length === 0) {
      return result;
    }
    const byToken: Map<string, AiToolCandidate> = new Map<string, AiToolCandidate>();
    result.candidates.forEach((cand: AiToolCandidate) => {
      byToken.set(cand.token.toLowerCase(), cand);
    });
    const intentHits: BrewSearchHit[] = BrewSearchEngine.rank(intent, entries, 0);
    const scoreByToken: Map<string, number> = new Map<string, number>();
    intentHits.forEach((hit: BrewSearchHit, index: number) => {
      scoreByToken.set(hit.token, 1000 - index);
    });
    result.candidates.sort((a: AiToolCandidate, b: AiToolCandidate): number => {
      const sa: number = scoreByToken.get(a.token.toLowerCase()) ?? 0;
      const sb: number = scoreByToken.get(b.token.toLowerCase()) ?? 0;
      if (sa !== sb) {
        return sb - sa;
      }
      return a.token.localeCompare(b.token);
    });
    if (result.candidates.length > AI_D2_RESULT_LIMIT) {
      result.candidates = result.candidates.slice(0, AI_D2_RESULT_LIMIT);
    }
    return result;
  }

  private static parseCandidates(text: string, outcome?: ParseOutcome): AiToolCandidate[] | null {
    // 裸数组形态（结构性差异修复 ①）：部分模型对 D2 会输出 `[{token,why},...]`（不带
    // candidates 包裹）——先探测，命中直接当候选数组解析，不走对象壳。
    const bare: AiToolCandidate[] | null = AiTasks.parseCandidatesBareArray(text, outcome);
    if (bare !== null) {
      return bare;
    }
    return parseJsonSafe(text, (obj: Record<string, Object>): AiToolCandidate[] | null => {
      const listObj: Object | undefined = obj['candidates'];
      if (!Array.isArray(listObj)) {
        return null;
      }
      return AiTasks.castCandidateList(listObj);
    });
  }

  /**
   * 裸数组形态探测（D2 专属）：顶层就是数组且元素是候选对象（带非空 token）。
   * 与 parseJsonSafe 尝试 3 的「数组包裹取首元素」互补——那条路把数组当包裹，
   * 这条路把数组当**数据本身**。非候选对象数组（如 D1/D3 的包裹形态）返回 null
   * 交回通用壳处理。
   */
  private static parseCandidatesBareArray(text: string, outcome?: ParseOutcome):
    AiToolCandidate[] | null {
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
    const out: AiToolCandidate[] | null = AiTasks.castCandidateList(parsed);
    if (out !== null && outcome !== undefined) {
      outcome.reason = E4_REASON_OK;
    }
    return out;
  }

  /**
   * 候选数组逐条 cast（对象壳与裸数组壳共用）：
   * - 空数组 = **合法空态**（结构性差异修复 ②）：意图太泛时模型输出 `{"candidates":[]}`
   *   是「不确定的宁可不推荐」的正确行为，返回空列表走空态 UI，不再判 E4；
   * - 单条缺 token **跳过该条**（与 filterAndRank 的单条 drop 精神一致），不再整页拒绝；
   * - 超上限才是格式不符（返回 null → E4）。
   */
  private static castCandidateList(listObj: Object): AiToolCandidate[] | null {
    if (!Array.isArray(listObj)) {
      return null;
    }
    const list: Array<Object> = listObj as Array<Object>;
    if (list.length > AI_D2_MAX_CANDIDATES) {
      return null;
    }
    const out: AiToolCandidate[] = [];
    for (let i: number = 0; i < list.length; i++) {
      const rec: Object | undefined = list[i];
      if (rec === undefined || rec === null) {
        continue;
      }
      const recObj: Record<string, Object> = rec as Record<string, Object>;
      const token: string = typeof recObj['token'] === 'string' ? recObj['token'] as string : '';
      const why: string = typeof recObj['why'] === 'string' ? recObj['why'] as string : '';
      if (token.trim().length === 0) {
        continue;
      }
      const cand: AiToolCandidate = new AiToolCandidate();
      cand.token = token;
      cand.why = why;
      out.push(cand);
    }
    return out;
  }

  private static readonly D2_SYSTEM: string = '你是 Homebrew 工具推荐助手。根据用户的中文意图，' +
    '推荐最多 5 个真实存在的通用命令行工具（Homebrew 包名）。' +
    '输出 JSON：{"candidates":[{"token":"包名（英文小写）","why":"一句话中文理由"}]}，' +
    '**candidates 必须是对象里的数组键，不要输出裸数组**；' +
    '没有合适的推荐就输出 {"candidates":[]}，这是合法结果，不要编造包名。';

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
    '"nextSteps":["下一步建议，最多3条，可以包含具体命令"]}。';

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

  // ------------------------------------------------- BI · 榜单解读（二期 P1-1）

  /**
   * 榜单/单包统计解读（spec ai-companion-phase2 §3 P1-1）。
   * 缓存键 = `<scope>_<boardKey 或单 token>_<snapshotDate>`：同一快照日内数字不变，
   * TTL 1 天。grounding JSON 全量进 user prompt；解析后走 G5 数字回溯过滤
   * （fresh 路径带 grounding；缓存路径跳过——写缓存前已过滤）。
   */
  public static boardInsight(input: AiBoardInsightInput,
    onRefreshed: (card: AiInsightCard) => void, force: boolean = false): Promise<AiInsightCard> {
    const cacheKey: string = AiTasks.biCacheKey(input);
    const providerKey: string = AiTasks.providerModelKey();
    if (force) {
      return AiTasks.fetchBoardInsight(input, providerKey, onRefreshed);
    }
    const cached: AiCacheLookup = AiTasks.lookup(AI_FEATURE_BI, providerKey, cacheKey,
      AI_PROMPT_VERSION_BI, AI_CACHE_TTL_BI_MS);
    if (cached.hit) {
      const card: AiInsightCard | null = AiTasks.parseInsight(cached.dataJson, '');
      if (card !== null) {
        Logger.info(TAG, `bi cache hit key=${cacheKey} age=${cached.age}`);
        return Promise.resolve(card);
      }
    }
    if (cached.stale) {
      const staleCard: AiInsightCard | null = AiTasks.parseInsight(cached.dataJson, '');
      if (staleCard !== null) {
        Logger.info(TAG, `stale-while-revalidate feature=bi key=${cacheKey}`);
        AiTasks.fetchBoardInsight(input, providerKey, onRefreshed);
        return Promise.resolve(staleCard);
      }
    }
    return AiTasks.fetchBoardInsight(input, providerKey, onRefreshed);
  }

  /** 缓存键：featured 用单 token（一卡一包），board 用 boardKey（一榜一键）。 */
  private static biCacheKey(input: AiBoardInsightInput): string {
    const scopeToken: string =
      input.scope === 'featured' && input.entries.length === 1 ? input.entries[0].token : input.boardKey;
    return `${input.scope}_${scopeToken}_${input.snapshotDate}`;
  }

  private static fetchBoardInsight(input: AiBoardInsightInput, providerKey: string,
    onRefreshed: (card: AiInsightCard) => void): Promise<AiInsightCard> {
    const task: AiClientTask = AiClient.newTask();
    task.system = AiTasks.INSIGHT_SYSTEM;
    task.user = AiTasks.insightUserPrompt(
      '以下是目录统计 grounding JSON（数字只能从这里原样引用）：\n' + JSON.stringify(input), '');
    task.temperature = AI_TEMPERATURE_BI;
    task.maxTokens = AI_MAX_TOKENS_BI;
    return AiClient.complete(task).then((completion) => {
      const outcome: ParseOutcome = new ParseOutcome();
      // fresh 路径：grounding 原文参与数字回溯过滤
      const card: AiInsightCard | null =
        AiTasks.parseInsight(completion.content, JSON.stringify(input), outcome);
      if (card === null) {
        throw new AiError(AiErrorKind.E4_BAD_FORMAT,
          `bi reason=${e4ReasonOf(completion, outcome.reason)}`);
      }
      AiCache.write(AI_FEATURE_BI, providerKey, AiTasks.biCacheKey(input), AI_PROMPT_VERSION_BI,
        completion.model, JSON.stringify(card));
      Logger.info(TAG, `bi ok latency=${completion.latencyMs}`);
      onRefreshed(card);
      return card;
    });
  }

  // ------------------------------------------------- LC · 弃用解读（二期 P1-3）

  /** 生命周期解读（P1-3）。缓存键带日期：上游改排期即产生新键，旧值自然过期。 */
  public static lifecycleExplain(input: AiLifecycleInput,
    onRefreshed: (card: AiInsightCard) => void, force: boolean = false): Promise<AiInsightCard> {
    const cacheKey: string = `${input.token}_${input.state}_` +
      `${input.deprecationDate.length > 0 ? input.deprecationDate : input.disableDate}`;
    const providerKey: string = AiTasks.providerModelKey();
    if (force) {
      return AiTasks.fetchLifecycle(input, providerKey, onRefreshed);
    }
    const cached: AiCacheLookup = AiTasks.lookup(AI_FEATURE_LC, providerKey, cacheKey,
      AI_PROMPT_VERSION_LC, AI_CACHE_TTL_LC_MS);
    if (cached.hit) {
      const card: AiInsightCard | null = AiTasks.parseInsight(cached.dataJson, '');
      if (card !== null) {
        Logger.info(TAG, `lc cache hit token=${input.token} age=${cached.age}`);
        return Promise.resolve(card);
      }
    }
    if (cached.stale) {
      const staleCard: AiInsightCard | null = AiTasks.parseInsight(cached.dataJson, '');
      if (staleCard !== null) {
        Logger.info(TAG, `stale-while-revalidate feature=lc token=${input.token}`);
        AiTasks.fetchLifecycle(input, providerKey, onRefreshed);
        return Promise.resolve(staleCard);
      }
    }
    return AiTasks.fetchLifecycle(input, providerKey, onRefreshed);
  }

  private static fetchLifecycle(input: AiLifecycleInput, providerKey: string,
    onRefreshed: (card: AiInsightCard) => void): Promise<AiInsightCard> {
    const task: AiClientTask = AiClient.newTask();
    task.system = AiTasks.INSIGHT_SYSTEM;
    task.user = AiTasks.insightUserPrompt(
      '以下是该包的生命周期 grounding JSON（日期与替代包名只能从这里原样引用）：\n' + JSON.stringify(input),
      AiTasks.LIFECYCLE_RULE);
    task.temperature = AI_TEMPERATURE_LC;
    task.maxTokens = AI_MAX_TOKENS_LC;
    return AiClient.complete(task).then((completion) => {
      const outcome: ParseOutcome = new ParseOutcome();
      const card: AiInsightCard | null =
        AiTasks.parseInsight(completion.content, JSON.stringify(input), outcome);
      if (card === null) {
        throw new AiError(AiErrorKind.E4_BAD_FORMAT,
          `lc reason=${e4ReasonOf(completion, outcome.reason)}`);
      }
      const cacheKey: string = `${input.token}_${input.state}_` +
        `${input.deprecationDate.length > 0 ? input.deprecationDate : input.disableDate}`;
      AiCache.write(AI_FEATURE_LC, providerKey, cacheKey, AI_PROMPT_VERSION_LC,
        completion.model, JSON.stringify(card));
      Logger.info(TAG, `lc ok token=${input.token} latency=${completion.latencyMs}`);
      onRefreshed(card);
      return card;
    });
  }

  // ------------------------------------------------- SD · 数据源诊断（二期 P1-4）

  /**
   * 数据源诊断（P1-4）。**不缓存**（对齐 D3：每次探测结果都可能不同）。
   * detail 是 B 级 grounding：任务层统一过 `aiMaskLocalPaths` 脱敏（spec §6）——
   * 脱敏责任收在发送边界，调用方漏做也不会泄露用户目录。
   */
  public static sourceDiagnosis(input: AiDiagnosisInput): Promise<AiInsightCard> {
    const masked: AiDiagnosisInput = new AiDiagnosisInput();
    masked.sourceId = input.sourceId;
    masked.sourceName = input.sourceName;
    masked.baseUrl = input.baseUrl;
    masked.httpCode = input.httpCode;
    masked.tookMs = input.tookMs;
    masked.reason = input.reason;
    masked.detail = aiMaskLocalPaths(input.detail);
    const task: AiClientTask = AiClient.newTask();
    task.system = AiTasks.INSIGHT_SYSTEM;
    task.user = AiTasks.insightUserPrompt(
      '以下是数据源探测结果 grounding JSON（HTTP 码/耗时/原因码只能从这里原样引用）：\n' +
      JSON.stringify(masked), AiTasks.DIAGNOSIS_RULE);
    task.temperature = AI_TEMPERATURE_SD;
    task.maxTokens = AI_MAX_TOKENS_SD;
    return AiClient.complete(task).then((completion) => {
      const outcome: ParseOutcome = new ParseOutcome();
      // 诊断文本没有需要回溯的统计数字：grounding 传空 = 跳过数字过滤（要点不丢）
      const card: AiInsightCard | null = AiTasks.parseInsight(completion.content, '', outcome);
      if (card === null) {
        throw new AiError(AiErrorKind.E4_BAD_FORMAT,
          `sd reason=${e4ReasonOf(completion, outcome.reason)}`);
      }
      Logger.info(TAG, `sd ok latency=${completion.latencyMs}`);
      return card;
    });
  }

  // ------------------------------------------------- insight 三任务共用件

  /** insight 形态的输出 schema（P1-1/3/4 共用，spec §3）。 */
  private static readonly INSIGHT_SCHEMA_JSON: string =
    '{"one_liner":"一句话解读","points":["要点，0–3条"],"action_hint":"行动提示，可为空串"}';

  /**
   * insight 任务的 system：三任务共用输出形态，差异在「事实来源与禁止事项」——
   * 由各任务在 user prompt 首行声明（见 fetchBoardInsight / fetchLifecycle / sourceDiagnosis）。
   */
  private static readonly INSIGHT_SYSTEM: string = '你是 Homebrew 目录数据解读助手。基于用户提供的 ' +
    'grounding JSON 回答，用简体中文。数字规则：只能原样引用 grounding 里出现的数字，' +
    '不得换算单位、不得编造任何 grounding 里没有的数字或百分比；velocity 与 priorMonthly ' +
    '为 0 表示没有历史数据，不要解读成「下降」。日期原样引用（YYYY-MM-DD）。' +
    '禁止编造包名、URL 或端口号。空字段原则：没有可说的就输出 []，' +
    '禁止输出「暂无数据」之类的填充句。\n' +
    `输出仍然必须是 JSON：${AiTasks.INSIGHT_SCHEMA_JSON}。`;

  /** P1-3 专属补充：替代包口径（没指定替代就必须明说，这是 G5「替代包零编造」的落实位）。 */
  private static readonly LIFECYCLE_RULE: string =
    '本任务解读包的弃用/禁用排期。replacement_formula 与 replacement_cask 都为空时，' +
    'one_liner 或 points 必须明确「上游未指定替代包」，禁止猜一个。';

  /** P1-4 专属补充：诊断只读（G7：建议只描述操作，不输出可执行命令）。 */
  private static readonly DIAGNOSIS_RULE: string =
    '本任务解读数据源探测失败原因。nextStep 类建议只描述操作（如「检查地址是否以 https 开头」），' +
    '禁止输出可执行命令行；action_hint 同样只放操作描述文字。';

  /**
   * insight 任务 user prompt：任务专属规则行（可空）+ grounding JSON + schema 收尾。
   * rules 按任务传：LC 传 LIFECYCLE_RULE、SD 传 DIAGNOSIS_RULE、BI 传空串
   * （INSIGHT_SYSTEM 已覆盖 BI 的数字口径，再拼规则只会稀释重点）。
   */
  private static insightUserPrompt(groundingBlock: string, rules: string): string {
    // 超长护栏（对齐 D1 循环砍半思路）：grounding JSON 里可牺牲的是 detail / entries，
    // 这里先整体砍半再判断（三任务输入量级都在 1–2KB，一般触发不了）。
    let block: string = groundingBlock;
    while ((AiTasks.INSIGHT_SYSTEM.length + rules.length + block.length) > AI_PROMPT_MAX_CHARS &&
      block.length > 256) {
      block = block.substring(0, Math.floor(block.length / 2));
    }
    return `${rules.length > 0 ? rules + '\n' : ''}${block}\n请按 schema 输出 JSON。`;
  }

  /** insight 解析：schema 三字段 + G5 数字回溯（groundingJson 为空 = 跳过过滤）。 */
  private static parseInsight(text: string, groundingJson: string, outcome?: ParseOutcome): AiInsightCard | null {
    const card: AiInsightCard | null = parseJsonSafe(text,
      (obj: Record<string, Object>): AiInsightCard | null => {
        const out: AiInsightCard = new AiInsightCard();
        out.oneLiner = typeof obj['one_liner'] === 'string' ? obj['one_liner'] as string : '';
        out.points = stringArrayOf(obj['points'], 3);
        out.actionHint = typeof obj['action_hint'] === 'string' ? obj['action_hint'] as string : '';
        if (!out.isValid()) {
          return null;
        }
        return out;
      }, outcome);
    if (card === null || groundingJson.length === 0) {
      return card;
    }
    // G5 数字回溯制：要点里出现 grounding 中不存在的数字 → 整条丢弃（spec §6）
    card.points = AnalyticsNumberParser.filterTraceable(card.points, groundingJson);
    return card;
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

/** string[] 字段抽取：非数组 / 元素非字符串 / 超上限都判格式不符。 */
function stringArrayOf(value: Object | undefined, max: number): string[] {
  if (value === undefined || !Array.isArray(value)) {
    return [];
  }
  const list: Array<Object> = value as Array<Object>;
  if (list.length > max) {
    return [];
  }
  const out: string[] = [];
  for (let i: number = 0; i < list.length; i++) {
    const one: Object = list[i];
    if (typeof one !== 'string') {
      return [];
    }
    const text: string = one as string;
    if (text.trim().length === 0) {
      return [];
    }
    out.push(text);
  }
  return out;
}
