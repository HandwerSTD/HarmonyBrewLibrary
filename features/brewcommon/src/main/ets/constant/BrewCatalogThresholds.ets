/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { BREW_DIALECT_HARMONYBREW } from './BrewSourceConstants';

/** 榜单门槛及计算实测分位所需的测量口径。 */
export interface CatalogThresholds {
  /** 趋势榜的下限 ≈ 30d 分布的 p89 */
  volFloor: number;
  /** `prior` 下限 ≈ prior 分布的 p55 */
  minPrior: number;
  /** 新星榜下限 */
  newFloor: number;
  volPct: number;
  priorPct: number;
}

/**
 * 上游（Homebrew 官方）标定值 —— 逐字沿用，不要动。
 *
 * 这些值对应 Homebrew 官方全球分布；上游的 priorDivisor 仍由调用方传 11.0。
 */
function buildUpstreamThresholds(): Record<string, CatalogThresholds> {
  const thresholds: Record<string, CatalogThresholds> = {};
  const formula: CatalogThresholds =
    { volFloor: 500, minPrior: 50, newFloor: 300, volPct: 0.89, priorPct: 0.55 };
  const cask: CatalogThresholds =
    { volFloor: 200, minPrior: 20, newFloor: 300, volPct: 0.89, priorPct: 0.55 };
  thresholds['formula'] = formula;
  thresholds['cask'] = cask;
  return thresholds;
}
export const BREW_CATALOG_THRESHOLDS_UPSTREAM: Record<string, CatalogThresholds> = buildUpstreamThresholds();

/**
 * Harmonybrew：按本源自己的实测分位标定（测量于 2026-09-24）。
 *
 * 样本是 2026-05-20~2026-09-23 共 88 天日文件、4379 个 family：
 * volFloor=10 为本源 30d 分布实测 p89，minPrior=2.5 为 prior 分布实测 p55（精确 2.53）。
 * newFloor=10 是判断，不是文档给出的分位规则；它与 volFloor 使用同一个 p89 口径，
 * 语义是新星榜要「已经有量」，而「量」的定义与趋势榜一致，并替代此前接近噪声底的绝对值。
 * 基数会漂移，偏差日志是漂移探测器；这里仍使用显式门槛，不做运行期自动自适应。
 *
 * casks 条目也给出同 formula 值：Harmonybrew 的 casks 恒空，实际不会走到。
 */
function buildHarmonybrewThresholds(): Record<string, CatalogThresholds> {
  const thresholds: Record<string, CatalogThresholds> = {};
  const formula: CatalogThresholds =
    { volFloor: 10, minPrior: 2.5, newFloor: 10, volPct: 0.89, priorPct: 0.55 };
  const cask: CatalogThresholds =
    { volFloor: 10, minPrior: 2.5, newFloor: 10, volPct: 0.89, priorPct: 0.55 };
  thresholds['formula'] = formula;
  thresholds['cask'] = cask;
  return thresholds;
}
export const BREW_CATALOG_THRESHOLDS_HARMONYBREW: Record<string, CatalogThresholds> = buildHarmonybrewThresholds();

/** 按源方言取门槛；未知 kind 回退到该表的 formula 条目。 */
export function catalogThresholdsFor(dialect: string, kind: string): CatalogThresholds {
  const table: Record<string, CatalogThresholds> = dialect === BREW_DIALECT_HARMONYBREW ?
    BREW_CATALOG_THRESHOLDS_HARMONYBREW : BREW_CATALOG_THRESHOLDS_UPSTREAM;
  const thresholds: CatalogThresholds = table[kind];
  return thresholds !== undefined ? thresholds : table['formula'];
}
