/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { objKeys } from './objkeys';

/**
 * 目录统计数字解析器（AI 二期 spec §3 / G4：数字一致性）。
 *
 * 两条统计口径**必须分开解析**（2026-11-23 实测，见 brew-api-design 勘误）：
 * - 内嵌 analytics：formula/cask 单条 JSON 里的 `analytics.install_on_request` 等
 *   已经是**扁平 map** `{"<token>": 123059, "<token> --HEAD": 296}`——值是裸数字，
 *   HEAD 行键名带 `--HEAD`，**单列、不计入主计数**；
 * - 聚合端点（/api/analytics/install/…）：`items[].count` 是**带逗号字符串**
 *   （"516,535"）、`percent` 也是字符串（"2.11"）。
 *
 * 另承载 AI 二期 G5「数字回溯制」的过滤函数：AI 输出的要点里出现 grounding 中
 * 不存在的数字时，该条在任务层（服务端侧）被丢弃。
 */

/** 内嵌 analytics 的拆分结果：main = 非 HEAD 行合计；head = HEAD 行合计（单列展示）。 */
export class AiInlineAnalyticsCounts {
  public main: number = 0;
  public head: number = 0;
}

export class AnalyticsNumberParser {
  /**
   * 解析内嵌 analytics 扁平 map。键含 `--HEAD`（不区分大小写）的行进 head 桶，
   * 其余进 main 桶。map 为 null / 空表 / 值非数字 → 对应桶记 0（不抛错）。
   */
  public static parseInlineAnalytics(map: Record<string, Object> | null): AiInlineAnalyticsCounts {
    const out: AiInlineAnalyticsCounts = new AiInlineAnalyticsCounts();
    if (map === null) {
      return out;
    }
    const keys: string[] = objKeys(map);
    for (let i: number = 0; i < keys.length; i++) {
      const value: Object | undefined = map[keys[i]];
      if (typeof value !== 'number') {
        continue;
      }
      const count: number = value as number;
      if (keys[i].toLowerCase().includes('--head')) {
        out.head += count;
      } else {
        out.main += count;
      }
    }
    return out;
  }

  /** 聚合端点的 count 字符串（"516,535"）→ 数字；空串 / 非数字 → 0。 */
  public static parseCommaCount(text: string): number {
    const cleaned: string = text.replace(/,/g, '').trim();
    if (cleaned.length === 0) {
      return 0;
    }
    const parsed: number = Number.parseInt(cleaned, 10);
    return Number.isNaN(parsed) ? 0 : parsed;
  }

  /** 聚合端点的 percent 字符串（"2.11"/"2.11%"）→ 数字；空 / 非数字 → 0。 */
  public static parsePercent(text: string): number {
    const cleaned: string = text.replace(/%/g, '').trim();
    if (cleaned.length === 0) {
      return 0;
    }
    const parsed: number = Number.parseFloat(cleaned);
    return Number.isNaN(parsed) ? 0 : parsed;
  }

  /**
   * G5 数字回溯过滤：point 里出现的每一个数字（含千分位写法）都必须能在
   * grounding JSON 原文里找到（逐字回溯，去逗号后比对），否则**整条丢弃**。
   * 没有数字的要点原样保留；输出截到 maxPoints（AI 二期上限 3）。
   *
   * 局限（记录在案）：模型若做了单位换算（「12.3 万」）会因数字对不上被丢弃——
   * 这是设计行为：prompt 明令「数字必须原样引用，不得换算单位」，被丢弃说明模型违反了，
   * 宁可少一条也不展示编造数字。
   */
  public static filterTraceable(points: string[], groundingJson: string, maxPoints: number = 3): string[] {
    if (points.length === 0 || groundingJson.length === 0) {
      return [];
    }
    // grounding 与 point 同规约化（去逗号）后再做子串匹配
    const groundingNorm: string = groundingJson.replace(/,/g, '');
    const out: string[] = [];
    for (let i: number = 0; i < points.length && out.length < maxPoints; i++) {
      const point: string = points[i];
      if (!AnalyticsNumberParser.pointTraceable(point, groundingNorm)) {
        continue;
      }
      out.push(point);
    }
    return out;
  }

  /** 单条要点是否可回溯：无数字 → true；有数字 → 每个数字都在 grounding 里出现才 true。 */
  private static pointTraceable(point: string, groundingNorm: string): boolean {
    const numberRe: RegExp = /\d[\d,]*(?:\.\d+)?/g;
    let matched: RegExpExecArray | null = numberRe.exec(point);
    while (matched !== null) {
      const token: string = matched[0].replace(/,/g, '');
      if (!groundingNorm.includes(token)) {
        return false;
      }
      matched = numberRe.exec(point);
    }
    return true;
  }
}
