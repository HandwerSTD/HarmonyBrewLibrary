/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { ReleaseIntelVerdict } from '../model/ReleaseIntelModels';

/**
 * 版本跨度判定（spec §3.1，零 AI）。
 *
 * 只做数值比较，不引入完整 semver：Homebrew 的 versions.stable 有日期版本
 * （`2023.01.15`）、两段版本（`8.5`）、字母后缀（`1.13.0_1` 的 `_1` 是 revision，
 * 不在本判定里——revision-only 由 from===to 识别）。任何一侧解析不出数字段即 unknown，
 * **unknown 不阻塞结构化区渲染**，只影响徽章文案（spec G1）。
 */
export class SemverJudge {
  /** 数值段提取：`8.5.1_2` → [8,5,1]；`v3.2` → [3,2]；`2023.01.15` → [2023,1,15]；
   *  `latest` / 空串 → []（unknown）。 */
  public static segments(version: string): number[] {
    const out: number[] = [];
    let started: boolean = false;
    let current: string = '';
    for (let i: number = 0; i < version.length; i++) {
      const ch: string = version.charAt(i);
      if (ch >= '0' && ch <= '9') {
        started = true;
        current += ch;
        continue;
      }
      if (ch === '.' && current.length > 0) {
        out.push(SemverJudge.toInt(current));
        current = '';
        continue;
      }
      // 首个非数字段（`v` 前缀之外的字母、`_`、`-`）终止数值部分
      if (started || (ch !== 'v' && ch !== 'V')) {
        break;
      }
    }
    if (current.length > 0) {
      out.push(SemverJudge.toInt(current));
    }
    return out;
  }

  /** 判定跨度。from/to 相等（含空）→ revision（bottle 重打包）；任一侧无数值段 → unknown。 */
  public static judge(from: string, to: string): ReleaseIntelVerdict {
    const verdict: ReleaseIntelVerdict = new ReleaseIntelVerdict();
    verdict.from = from;
    verdict.to = to;
    if (from === to) {
      verdict.kind = 'revision';
      return verdict;
    }
    const a: number[] = SemverJudge.segments(from);
    const b: number[] = SemverJudge.segments(to);
    if (a.length === 0 || b.length === 0) {
      verdict.kind = 'unknown';
      return verdict;
    }
    const len: number = a.length > b.length ? a.length : b.length;
    for (let i: number = 0; i < len; i++) {
      const av: number = i < a.length ? a[i] : 0;
      const bv: number = i < b.length ? b[i] : 0;
      if (av !== bv) {
        verdict.kind = i === 0 ? 'major' : (i === 1 ? 'minor' : 'patch');
        return verdict;
      }
    }
    verdict.kind = 'revision';
    return verdict;
  }

  private static toInt(text: string): number {
    // 超长数字段防溢出：截前 9 位足够（版本号不会真到 10^9）
    const safe: string = text.length > 9 ? text.substring(0, 9) : text;
    const value: number = Number.parseInt(safe, 10);
    return Number.isNaN(value) ? 0 : value;
  }
}
