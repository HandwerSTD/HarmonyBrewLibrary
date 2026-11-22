/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { TldrExample, TldrPage } from '../model/TldrPage';

/**
 * tldr 候选名链与页 markdown 的解析：**纯函数层**。
 *
 * 解析规则见 docs/superpowers/specs/2026-11-22-tldr-usage-examples-spec.md §3.2，
 * 页面真实格式以 2026-11-22 的探针记录为准（spec §3.1）：
 *
 * ```
 * # wget
 *
 * > 从网络上下载文件。
 * > 支持 HTTP，HTTPS 和 FTP。
 * > 另请参阅：`wcurl`, `curl`。
 * > 更多信息：<https://...>。
 *
 * - 将该 URL 的内容下载到文件中（在这个例子中文件名为 "foo"）：
 *
 * `wget {{https://example.com/foo}}`
 * ```
 *
 * 候选名链（spec §3.1，命名错位修复）：`查询候选 = [token, 剥 @version 后缀,
 * …executables]`，去重保序、全小写；取数层按序逐候选取数，**命中即停**。
 * 链的纯决策（`resolveChain`）也在这层，让「首候选 404 不毒化整链」「网络失败立即终止」
 * 这两条硬规则可以被检查脚本直接断言。
 *
 * 两条刻意约束（与 BrewSearchEngine 同源）：
 *   1. **只 import TldrPage** —— 于是 `hmosword-build/brew-tldr/check_tldr_parser.mjs`
 *      能把本文件连同模型一起拷进临时目录当 `.mts` 跑（检查脚本对这一行 import 做断言式
 *      改写，其余字节原样）。除模型外不允许再出现任何 import；也因此本文件**不用 enum**
 *      （Node 类型剥离不支持），结论类别一律用字符串常量。
 *   2. **无状态、无网络、无时间** —— 不读全局、不发请求、不取 Date.now()，
 *      「同输入同输出」是检查脚本用来当正确性判据的性质。
 *
 * 防御点（对应失败分级 F3 / F6）：
 *   - 首个非空行不是 `# <命令>` 标题 → 返回 null（F3，非预期结构）；
 *   - 标题与**任一候选**都不匹配（小写比较）→ 返回 null（F6，防御抓错页）；
 *   - 占位符原样保留在 `code` 里，渲染层用 `splitCodeSegments` 高亮，不改写不填值。
 */

/** 合法候选字符集。tldr 页名是小写字母数字与 `-_.@+`；路径穿越字符在构建期就挡掉 */
const CANDIDATE_PATTERN: RegExp = /^[a-z0-9@._+-]+$/;

/** 候选上限。executables 来自数据源，防御异常长清单拖慢取数链 */
const CANDIDATE_MAX: number = 20;

/** 单候选长度上限（与落盘文件名约束同口径） */
const CANDIDATE_MAX_LENGTH: number = 100;

/** TldrCandidateOutcome.kind：拿到 markdown */
export const TLDR_OUTCOME_HIT: string = 'hit';
/** TldrCandidateOutcome.kind：确凿的「没有这一页」（全渠道 404） */
export const TLDR_OUTCOME_NOT_FOUND: string = 'not_found';
/** TldrCandidateOutcome.kind：网络/非 404 失败 */
export const TLDR_OUTCOME_FAILED: string = 'failed';

/** TldrChainResult.status：链上某候选命中 */
export const TLDR_CHAIN_HIT: string = 'hit';
/** TldrChainResult.status：全部候选都确凿无页 */
export const TLDR_CHAIN_ALL_NOT_FOUND: string = 'all_not_found';
/** TldrChainResult.status：链上出现网络失败，立即终止 */
export const TLDR_CHAIN_FAILED: string = 'failed';

/** TldrCandidateOutcome.origin / TldrChainResult.hitOrigin：内容来自落盘缓存 */
export const TLDR_ORIGIN_DISK: string = 'disk';
/** TldrCandidateOutcome.origin / TldrChainResult.hitOrigin：内容来自网络（需要落盘） */
export const TLDR_ORIGIN_NETWORK: string = 'network';

/**
 * 单候选的一次取数结论。由取数层（TldrService）的回调产出，纯函数层只消费：
 * `hit` 必须带 markdown 与 locale；`not_found` 表示「确凿无页」（可写该候选的负缓存）；
 * `failed` 表示网络失败（链立即终止）。
 */
export class TldrCandidateOutcome {
  /** 'hit' | 'not_found' | 'failed'（TLDR_OUTCOME_*） */
  public kind: string = TLDR_OUTCOME_FAILED;
  /** kind=hit 时的原始 markdown */
  public markdown: string = '';
  /** kind=hit 时的页面语言（'zh' | 'en'），来自取数路径的回落结论 */
  public locale: string = '';
  /** kind=hit 时内容的来源：'disk'（无需落盘）| 'network'（解析通过后要落盘） */
  public origin: string = '';
  /** kind=hit 且 origin=network 时的渠道标识（日志用） */
  public channel: string = '';
}

/**
 * 候选链的一次完整结论。
 */
export class TldrChainResult {
  /** 'hit' | 'all_not_found' | 'failed'（TLDR_CHAIN_*） */
  public status: string = TLDR_CHAIN_ALL_NOT_FOUND;
  /** status=hit 时的页面 */
  public page: TldrPage | null = null;
  /** status=hit 时的原始 markdown —— 落盘缓存存的是原文，不是解析产物 */
  public hitMarkdown: string = '';
  /** status=hit 时命中的候选（页名） */
  public candidate: string = '';
  /** status=hit 时内容的来源（'disk' | 'network'），落盘决策用 */
  public hitOrigin: string = '';
  /** status=hit 且来自网络时的渠道标识（日志用） */
  public hitChannel: string = '';
  /**
   * 链上被跳过的「标题对不上任一候选」的 markdown 头部（F3/F6 日志用）。
   * 记最后一次；status != hit 且本字段非空时由取数层打 `[tldr] parse fail`。
   */
  public parseFailHead: string = '';
}

export class TldrCodeSegment {
  /** 该段文本。占位符段**包含** `{{` 与 `}}` 本身 —— 展示与复制都必须是原文 */
  public text: string = '';
  /** 是否为 `{{...}}` 占位符段（渲染成高亮样式） */
  public placeholder: boolean = false;
}

export class TldrParser {
  /** 占位符判定（spec §3.2 的原始正则）。`code` 含任一 `{{...}}` 即为真 */
  public static hasPlaceholder(code: string): boolean {
    return /{{.+?}}/.test(code);
  }

  /**
   * 无占位符的示例才允许一键执行（G4）。这里只做**结构判定**；
   * 执行通道侧（BrewCommandRunner）会再验一次，两处共用本函数。
   */
  public static isExecutable(code: string): boolean {
    return code.length > 0 && !TldrParser.hasPlaceholder(code);
  }

  /**
   * 构建候选名链（spec §3.1）：`[token, 剥 @version 后缀, …executables]`，
   * 去重保序、全小写；空串、超长、路径穿越与字符集不过的候选直接丢弃。
   *
   * 剥 @version 取**首个** `@` 之前的部分（`python@3.12` → `python`）：
   * tldr 页名不含 `@`，而 brew 的 @version 只出现在 token 尾部，一处剥离即可覆盖
   * `openssl@3` / `python@3.12` 两类实测 miss。
   */
  public static buildCandidates(token: string, executables: string[]): string[] {
    const candidates: string[] = [];
    const addCandidate: (value: string) => void = (value: string) => {
      if (candidates.length >= CANDIDATE_MAX) {
        return;
      }
      const normalized: string = value.trim().toLowerCase();
      if (normalized.length === 0 || normalized.length > CANDIDATE_MAX_LENGTH ||
        normalized.indexOf('..') >= 0 || normalized.indexOf('/') >= 0 ||
        normalized.indexOf('\\') >= 0) {
        return;
      }
      if (!CANDIDATE_PATTERN.test(normalized)) {
        return;
      }
      if (candidates.indexOf(normalized) >= 0) {
        return;
      }
      candidates.push(normalized);
    };
    addCandidate(token);
    const at: number = token.indexOf('@');
    if (at > 0) {
      addCandidate(token.substring(0, at));
    }
    executables.forEach((executable: string) => {
      addCandidate(executable);
    });
    return candidates;
  }

  /**
   * 候选链的命中即停决策（纯函数，可被检查脚本直接断言）。
   *
   * 按候选序逐个调 `resolver`（**按需调用**：命中即停 ⇒ 后面的候选不会被请求，
   * 脚本据此断言调用次数）；对每个结论：
   *   - `failed`（网络失败）→ 链立即终止（F1），**不**继续候选、负缓存由取数层负责；
   *   - `hit` → 解析（标题 = 任一候选，F6）：通过即返回；对不上按 F3 记头部后
   *     **跳过本候选继续**（拿到的坏内容不该掩护住后面可能的好候选）；
   *   - `not_found`（确凿无页）→ 本候选终结（负缓存已由取数层写入），继续下一个。
   * 全部候选走完仍无命中 → `all_not_found`（整链隐藏）。
   */
  public static async resolveChain(candidates: string[],
    resolver: (candidate: string) => Promise<TldrCandidateOutcome>): Promise<TldrChainResult> {
    const result: TldrChainResult = new TldrChainResult();
    for (const candidate of candidates) {
      const outcome: TldrCandidateOutcome = await resolver(candidate);
      if (outcome.kind === TLDR_OUTCOME_FAILED) {
        result.status = TLDR_CHAIN_FAILED;
        return result;
      }
      if (outcome.kind === TLDR_OUTCOME_HIT) {
        const page: TldrPage | null = TldrParser.parse(outcome.markdown, candidates, outcome.locale);
        if (page !== null) {
          result.status = TLDR_CHAIN_HIT;
          result.page = page;
          result.hitMarkdown = outcome.markdown;
          result.candidate = candidate;
          result.hitOrigin = outcome.origin;
          result.hitChannel = outcome.channel;
          return result;
        }
        result.parseFailHead = TldrParser.headOf(outcome.markdown);
        continue;
      }
      // not_found：本候选确凿无页，继续下一个
    }
    result.status = TLDR_CHAIN_ALL_NOT_FOUND;
    return result;
  }

  /**
   * 把命令原文切成「普通文本 / 占位符」交替的段序列。
   *
   * 渲染层对每段出一个 `Span`（占位符段给高亮色）；所有段的 text 顺序拼接**必须**与
   * `code` 逐字一致 —— 这是 G3（复制逐字一致）在展示侧的另一半：显示什么就复制什么。
   */
  public static splitCodeSegments(code: string): TldrCodeSegment[] {
    const segments: TldrCodeSegment[] = [];
    let plain: string = '';
    let index: number = 0;
    while (index < code.length) {
      if (code.startsWith('{{', index)) {
        const end: number = code.indexOf('}}', index + 2);
        if (end >= 0) {
          if (plain.length > 0) {
            segments.push(TldrParser.makeSegment(plain, false));
            plain = '';
          }
          segments.push(TldrParser.makeSegment(code.substring(index, end + 2), true));
          index = end + 2;
          continue;
        }
      }
      plain += code.charAt(index);
      index++;
    }
    if (plain.length > 0) {
      segments.push(TldrParser.makeSegment(plain, false));
    }
    return segments;
  }

  /**
   * 解析一页 tldr markdown。
   *
   * `candidates` 是候选名链（小写）：标题与**任一**候选匹配即通过（命名错位修复，
   * spec §3.1 —— ripgrep 的页名是 rg，标题校验必须认得链上的每一个名字），
   * 防抓错页的防御不松：对不上任何候选仍是 null。
   * `locale` 是取数层的回落结论（'zh' | 'en'），解析器原样带到页面上。
   *
   * 返回 null 的两种情况都不是「没有这一页」（那是取数层的 404），而是「拿到的内容
   * 不能安全地当成这一页的正文」—— 调用方按 F3 / F6 处理：分区隐藏 + 报日志。
   */
  public static parse(markdown: string, candidates: string[], locale: string): TldrPage | null {
    const lines: string[] = markdown.split('\n');
    // ---- 1. 标题行：首个非空行必须是 `# <命令>`
    const title: string | null = TldrParser.titleOf(lines);
    if (title === null) {
      return null;
    }
    // ---- 2. 标题与候选链校验（F6：任一候选都不匹配 → 整页丢弃）
    const normalizedTitle: string = title.toLowerCase();
    let matched: boolean = false;
    for (const raw of candidates) {
      const normalized: string = raw.trim().toLowerCase();
      if (normalized.length > 0 && normalized === normalizedTitle) {
        matched = true;
        break;
      }
    }
    if (!matched) {
      return null;
    }
    // ---- 3. 页首引用组 → 说明段（另请参阅 / More information 行丢弃）
    const summary: string = TldrParser.summaryOf(lines);
    // ---- 4. 示例：`- <说明>` + 紧随的代码行
    const page: TldrPage = new TldrPage();
    page.locale = locale;
    page.command = title;
    page.summary = summary;
    page.examples = TldrParser.examplesOf(lines);
    return page;
  }

  // ---------------------------------------------------------------- 内部

  private static makeSegment(text: string, placeholder: boolean): TldrCodeSegment {
    const segment: TldrCodeSegment = new TldrCodeSegment();
    segment.text = text;
    segment.placeholder = placeholder;
    return segment;
  }

  /** F3/F6 日志用：原文头部压成单行（取数层把它截到 200 字节） */
  private static headOf(text: string): string {
    return text.replace(/[\r\n]+/g, ' ');
  }

  /** 首个非空行的标题捕获。不是 `# <命令>` 形状时返回 null */
  private static titleOf(lines: string[]): string | null {
    for (const line of lines) {
      if (line.trim().length === 0) {
        continue;
      }
      if (!line.startsWith('# ')) {
        return null;
      }
      return line.substring(2).trim();
    }
    return null;
  }

  /**
   * 标题之后的连续引用行合并为说明段。
   *
   * 「另请参阅 / See also」「更多信息 / More information」是页面导航元数据，
   * 按 spec §3.2「其他内容丢弃」剔除 —— 它们对「怎么用」没有信息量，
   * 留着还会把仓库链接渲染成不可点的纯文本。
   */
  private static summaryOf(lines: string[]): string {
    const parts: string[] = [];
    let started: boolean = false;
    for (const raw of lines) {
      const isQuote: boolean = raw.startsWith('>');
      if (!isQuote) {
        if (started) {
          break;
        }
        continue;
      }
      started = true;
      const text: string = TldrParser.stripQuoteMarker(raw);
      if (TldrParser.isMetaLine(text)) {
        continue;
      }
      if (text.length > 0) {
        parts.push(text);
      }
    }
    return parts.join('\n');
  }

  private static stripQuoteMarker(raw: string): string {
    // `> ` / `>` 两种形态都剥掉；剥完 trim，空行不进说明段
    if (raw.startsWith('> ')) {
      return raw.substring(2).trim();
    }
    return raw.substring(1).trim();
  }

  private static isMetaLine(text: string): boolean {
    const lower: string = text.toLowerCase();
    return lower.startsWith('另请参阅') || lower.startsWith('see also') ||
      lower.startsWith('更多信息') || lower.startsWith('more information');
  }

  /**
   * 示例扫描。状态机：
   *   `- <说明>` 开启一个待完成示例；随后**空行**把说明行封口；
   *   紧随的独占一行单反引号代码（探针实测的主格式）落码完成；
   *   ``` 围栏代码块作为防御性兼容（§3.1 探针记录）。
   * 说明未封口前的普通行并入说明（多行说明）；已封口后、落码前的杂散行丢弃。
   * 没等到代码的悬空说明直接丢弃 —— 没有命令原文的示例项没有任何用途。
   */
  private static examplesOf(lines: string[]): TldrExample[] {
    const examples: TldrExample[] = [];
    let descParts: string[] = [];
    let descOpen: boolean = false;
    let fencedCode: string[] = [];
    let inFence: boolean = false;
    for (const line of lines) {
      if (inFence) {
        if (line.trim().startsWith('```')) {
          // 围栏闭合：合并多行为一条示例的 code
          TldrParser.completeExample(examples, descParts, fencedCode.join('\n'));
          fencedCode = [];
          descParts = [];
          descOpen = false;
          inFence = false;
          continue;
        }
        fencedCode.push(line);
        continue;
      }
      if (line.trim().startsWith('```')) {
        // 围栏开启：把「待落码」切到围栏模式
        fencedCode = [];
        inFence = true;
        continue;
      }
      if (line.trim().length === 0) {
        // 空行把说明行封口（探针格式里说明与代码之间恰好隔一个空行）
        descOpen = false;
        continue;
      }
      if (TldrParser.isInlineCodeLine(line)) {
        TldrParser.completeExample(examples, descParts, line.substring(1, line.length - 1));
        descParts = [];
        descOpen = false;
        continue;
      }
      if (line.startsWith('- ')) {
        // 新说明行：上一个没落码的悬空说明就地丢弃
        descParts = [line.substring(2).trim()];
        descOpen = true;
        continue;
      }
      if (descOpen) {
        // 多行说明的续行（spec §3.2 构造用例之一）
        descParts.push(line.trim());
      }
      // 其余（More information 散行、分隔线等）一律丢弃
    }
    return examples;
  }

  /** 独占一行的单反引号代码（探针实测的 tldr 主格式） */
  private static isInlineCodeLine(line: string): boolean {
    return line.length >= 2 && line.startsWith('`') && line.endsWith('`');
  }

  private static completeExample(examples: TldrExample[], descParts: string[], code: string): void {
    if (descParts.length === 0 || code.length === 0) {
      // 说明或命令缺一边都不构成示例：丢弃，不产出空壳
      return;
    }
    const example: TldrExample = new TldrExample();
    example.desc = descParts.join('\n');
    example.code = code;
    example.hasPlaceholder = TldrParser.hasPlaceholder(code);
    examples.push(example);
  }
}
