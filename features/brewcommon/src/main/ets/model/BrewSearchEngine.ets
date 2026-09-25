/*
 * Copyright (c) 2025 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/**
 * 搜索的匹配与排序：**纯函数层**。
 *
 * 三条刻意约束，都不是风格问题：
 *   1. **零 import** —— 于是 `hmosword-build/brew-search/check_engine.mjs` 能把本文件原样
 *      当成 `.mts` 跑起来（Node 的类型剥离）。加任何 import 都会让那份检查失效。
 *   2. **kind 用 `string` 而不是 `BrewKind`** —— 同上：`BrewKind` 在 `BrewModels.ets` 里，
 *      import 它就破坏了第 1 条。`BrewService` / `BrewTaxonomy` 本来就是拿 `string`
 *      当 kind 用的（`BrewKindText.FORMULA`），口径一致。
 *   3. **无状态、无网络、无时间** —— 排序的 tie-break 里不允许出现 `Date.now()` 或随机，
 *      否则「同输入同输出」这条性质就没了（生成器那边正是拿它当正确性判据的）。
 */

export class BrewSearchEntry {
  public kind: string = '';
  public token: string = '';
  public desc: string = '';
  public vol30d: number = 0;
  /** 目录里的原始下标：同分同安装量时的稳定 tie-break */
  public order: number = 0;
}

export class BrewSearchHit {
  public kind: string = '';
  public token: string = '';
  public desc: string = '';
  public vol30d: number = 0;
  public score: number = 0;
  /** 'exact' | 'prefix' | 'word' | 'substr' | 'descHead' | 'desc' | 'none'，只用于日志。
   * `rank()` 每次都会赋值，这里的初始值只是占位：取 **枚举内的 `'none'`**（不是 `''`），
   * 与 `BrewSearchScore.matchedBy` 口径一致，读日志时不会看到枚举外的空串。 */
  public matchedBy: string = 'none';
  /** 目录里的原始下标。**不在 UI 上展示** */
  public order: number = 0;
}

export const BREW_SEARCH_SCORE_EXACT: number = 100;
export const BREW_SEARCH_SCORE_PREFIX_BASE: number = 80;
/** 前缀档的长度惩罚上限：把前缀档的下界钉在 70（= 词边界档），始终高于子串档 60 */
export const BREW_SEARCH_SCORE_PREFIX_PENALTY_MAX: number = 10;
export const BREW_SEARCH_SCORE_WORD: number = 70;
export const BREW_SEARCH_SCORE_SUBSTR: number = 60;
export const BREW_SEARCH_SCORE_DESC_HEAD: number = 40;
export const BREW_SEARCH_SCORE_DESC: number = 20;

/**
 * 分数与命中方式**同源**的载体：`evaluate()` 一次判定里同时填这两个字段。
 *
 * 为什么必须同源：**70 分可由两条不同规则给出** —— 前缀惩罚封顶到 10、以及词边界命中。
 * 因此任何「从分数反推标签」的映射（`score >= 70 → 'prefix'`）都会把词边界误标成 `prefix`。
 * 同一分数对应不同规则时，只有携带规则本身的判定结果才能给出正确标签。
 */
export class BrewSearchScore {
  public score: number = 0;
  /** 'exact' | 'prefix' | 'word' | 'substr' | 'descHead' | 'desc' | 'none'，只用于日志 */
  public matchedBy: string = 'none';
}

export class BrewSearchEngine {
  public static normalize(keyword: string): string {
    return keyword.trim().toLowerCase();
  }

  /**
   * 判定一次，同时得到分数与命中方式。
   *
   * 规则链按优先级自上而下：exact → prefix → word → substr → descHead → desc，停在第一个
   * 命中的档位上（所以一个条目只算一次分）。分数与标签在同一个分支里一起写，二者不可能不一致。
   *
   * `k` **必须是 `normalize()` 过的**（调用点只有 `rank()`，所以这条由 `rank` 保证）。
   */
  public static evaluate(k: string, token: string, desc: string): BrewSearchScore {
    const result: BrewSearchScore = new BrewSearchScore();
    // 契约：`k` **必须已由 `normalize()` 归一化**。生产路径上的唯一调用点是 `rank()`（它先归一化
    // 再判空）；`scoreOf()` / `matchedByOf()` 只是转发，供检查脚本使用。这里只判 `k.length === 0`，
    // **不 trim**：传入未归一化的原始关键字（例如 `' '`）不在支持范围内。
    if (k.length === 0) {
      return result;
    }
    if (token === k) {
      result.score = BREW_SEARCH_SCORE_EXACT;
      result.matchedBy = 'exact';
      return result;
    }
    if (token.startsWith(k)) {
      result.score = BREW_SEARCH_SCORE_PREFIX_BASE -
        Math.min(BREW_SEARCH_SCORE_PREFIX_PENALTY_MAX, token.length - k.length);
      result.matchedBy = 'prefix';
      return result;
    }
    if (BrewSearchEngine.hasWordSegment(token, k)) {
      result.score = BREW_SEARCH_SCORE_WORD;
      result.matchedBy = 'word';
      return result;
    }
    if (token.includes(k)) {
      result.score = BREW_SEARCH_SCORE_SUBSTR;
      result.matchedBy = 'substr';
      return result;
    }
    const lower: string = desc.toLowerCase();
    if (BrewSearchEngine.hasWordHead(lower, k)) {
      result.score = BREW_SEARCH_SCORE_DESC_HEAD;
      result.matchedBy = 'descHead';
      return result;
    }
    if (lower.includes(k)) {
      result.score = BREW_SEARCH_SCORE_DESC;
      result.matchedBy = 'desc';
      return result;
    }
    return result;
  }

  /** 打分。转发到 `evaluate()`：与 `matchedByOf()` 出自同一条判定链 */
  public static scoreOf(k: string, token: string, desc: string): number {
    return BrewSearchEngine.evaluate(k, token, desc).score;
  }

  /** 命中方式（日志用）。转发到 `evaluate()`：与 `scoreOf()` 出自同一条判定链 */
  public static matchedByOf(k: string, token: string, desc: string): string {
    return BrewSearchEngine.evaluate(k, token, desc).matchedBy;
  }

  /** `-` 与 `@` 都算分隔符：`node@20` 里 `20` 是独立一段（`python@3.13` 同理） */
  private static splitSegments(token: string): string[] {
    const out: string[] = [];
    token.split('-').forEach((part: string) => {
      part.split('@').forEach((piece: string) => {
        if (piece.length > 0) {
          out.push(piece);
        }
      });
    });
    return out;
  }

  private static hasWordSegment(token: string, k: string): boolean {
    return BrewSearchEngine.splitSegments(token).some((seg: string) => seg === k);
  }

  private static isWordChar(ch: string): boolean {
    return (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9');
  }

  /**
   * desc 里是否有**词首**等于 `k`。手写扫描而不用正则/`split(/[^a-z0-9]+/)`：
   * 正则在这条路径上是每次匹配都在编译，而这里是 2.6 万行的热循环。
   * 注意 `atHead` 只在遇到非单词字符时置位 —— `research` 里的 `search` 不算词首。
   */
  private static hasWordHead(lowerDesc: string, k: string): boolean {
    let atHead: boolean = true;
    for (let i: number = 0; i < lowerDesc.length; i++) {
      const ch: string = lowerDesc.charAt(i);
      if (!BrewSearchEngine.isWordChar(ch)) {
        atHead = true;
        continue;
      }
      if (atHead && lowerDesc.substring(i, i + k.length) === k) {
        return true;
      }
      atHead = false;
    }
    return false;
  }

  /**
   * 排序 + 截断。`limit <= 0` 表示不截断（调用方要「命中总数」时用它）。
   *
   * 三级定序：`score` 降序 → `vol30d` 降序 → `order` 升序。
   * `order` 唯一，所以结果是全序，不依赖 `sort` 的稳定性。
   */
  public static rank(keyword: string, entries: BrewSearchEntry[], limit: number): BrewSearchHit[] {
    const k: string = BrewSearchEngine.normalize(keyword);
    if (k.length === 0) {
      return [];
    }
    const hits: BrewSearchHit[] = [];
    entries.forEach((entry: BrewSearchEntry) => {
      const scored: BrewSearchScore = BrewSearchEngine.evaluate(k, entry.token, entry.desc);
      if (scored.score > 0) {
        const hit: BrewSearchHit = new BrewSearchHit();
        hit.kind = entry.kind;
        hit.token = entry.token;
        hit.desc = entry.desc;
        hit.vol30d = entry.vol30d;
        hit.score = scored.score;
        hit.matchedBy = scored.matchedBy;
        hit.order = entry.order;
        hits.push(hit);
      }
    });
    hits.sort((a: BrewSearchHit, b: BrewSearchHit) => {
      if (a.score !== b.score) {
        return b.score - a.score;
      }
      if (a.vol30d !== b.vol30d) {
        return b.vol30d - a.vol30d;
      }
      return a.order - b.order;
    });
    return limit > 0 && hits.length > limit ? hits.slice(0, limit) : hits;
  }

  /** chips 过滤。`kind` 为空串表示不过滤（「全部」） */
  public static filterByKind(hits: BrewSearchHit[], kind: string): BrewSearchHit[] {
    return kind.length === 0 ? hits : hits.filter((hit: BrewSearchHit) => hit.kind === kind);
  }
}
