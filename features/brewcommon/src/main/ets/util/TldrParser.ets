/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { TldrExample, TldrPage } from '../model/TldrPage';

/**
 * tldr 页 markdown 的解析器：**纯函数层**（输入 markdown → 输出 TldrPage | null）。
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
 * 两条刻意约束（与 BrewSearchEngine 同源）：
 *   1. **只 import TldrPage** —— 于是 `hmosword-build/brew-tldr/check_tldr_parser.mjs`
 *      能把本文件连同模型一起拷进临时目录当 `.mts` 跑（检查脚本对这一行 import 做断言式
 *      改写，其余字节原样）。除模型外不允许再出现任何 import。
 *   2. **无状态、无网络、无时间** —— 不读全局、不发请求、不取 Date.now()，
 *      「同输入同输出」是检查脚本用来当正确性判据的性质。
 *
 * 防御点（对应失败分级 F3 / F6）：
 *   - 首个非空行不是 `# <命令>` 标题 → 返回 null（F3，非预期结构）；
 *   - 标题与 token 不匹配（小写比较）→ 返回 null（F6，防御抓错页）；
 *   - 占位符原样保留在 `code` 里，渲染层用 `splitCodeSegments` 高亮，不改写不填值。
 */
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
   * `token` 用于标题校验（小写比较，spec §3.1 的 v1 口径：精确匹配、不做别名表）；
   * `locale` 是取数层的回落结论（'zh' | 'en'），解析器原样带到页面上。
   *
   * 返回 null 的两种情况都不是「没有这一页」（那是取数层的 404），而是「拿到的内容
   * 不能安全地当成这一页的正文」—— 调用方按 F3 / F6 处理：分区隐藏 + 报日志。
   */
  public static parse(markdown: string, token: string, locale: string): TldrPage | null {
    const lines: string[] = markdown.split('\n');
    // ---- 1. 标题行：首个非空行必须是 `# <命令>`
    const title: string | null = TldrParser.titleOf(lines);
    if (title === null) {
      return null;
    }
    // ---- 2. 标题与 token 校验（F6：不匹配整页丢弃）
    const normalizedToken: string = token.trim().toLowerCase();
    if (normalizedToken.length === 0 || title.toLowerCase() !== normalizedToken) {
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
