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

import { BrewSourceStore } from './BrewSourceStore';
import { BrewSourceUrl } from './BrewSourceUrl';
import { adapterFor } from './source/BrewSourceAdapter';
import type { CatalogThresholds } from '../constant/BrewCatalogThresholds';

/**
 * Discover 推荐算法的**设备端实现**，与 `hmosword-build/brew-mockgen/check_algo.py` 逐条对应。
 *
 * 为什么把它搬到设备端：三张榜的输入是两个**聚合端点**（全量宇宙的安装量统计），
 * 在构建期已跑过一遍，所以算法本身是可移植的纯函数；搬过来之后"谁上榜"就不再是一份
 * 冻结快照，而是每次刷新现算。参照实现与自检仍在 Python 侧（`check_algo.py`），
 * 两边口径必须一致 —— 改了这里要同步改那边，反之亦然。
 *
 * 权限边界：**这里只有"算法"，没有"分类体系"**。官方 API 没有任何分类字段，
 * 分类是自建词表（`lexicon.json`）的产物，仍未移植 —— 所以设备端能算"榜单成员"，
 * 算不出"这个包属于哪个分类"。
 *
 * 已实测的三个坑（详见 docs/brew-discover-algo.md §1.3），解析时必须处理：
 *   1. `formulae` / `casks` 是「token -> 条目数组」的**字典**，不是数组；
 *   2. 一个 token 可能有多条记录（`gh` + `gh --HEAD`）→ **必须求和**；
 *   3. `count` 是**带千分位逗号的字符串**（`"62,667"`），且没有 `percent` 字段。
 */

/** 一个聚合端点的契约 */
export class CatalogSource {
  public kind: string;
  public win: string;
  public url: string;

  public constructor(kind: string, win: string, url: string) {
    this.kind = kind;
    this.win = win;
    this.url = url;
  }
}

/**
 * 4 个聚合端点。**函数而不是常量数组** —— 常量数组会在**模块导入期**求值，
 * 而 base URL 现在是运行期从会话快照解析的（且导入期 `UIContext` 未必就绪，
 * 会拼出空 URL）。这是本文件唯一必须改成函数的地方。
 *
 * 与 check_algo.py 的 SOURCES 逐字对应，不要在别处重新拼 URL。
 */
export function catalogSources(): CatalogSource[] {
  const out: CatalogSource[] = [];
  const sourceId: string = BrewSourceStore.sessionActive().id;
  const adapter = adapterFor(BrewSourceStore.dialectOf(sourceId));
  if (!adapter.supportsAnalytics) {
    return out;
  }
  const base: string = BrewSourceStore.activeBaseUrl();
  out.push(new CatalogSource('formula', '30d', BrewSourceUrl.join(base,
    '/analytics/install-on-request/homebrew-core/30d.json')));
  out.push(new CatalogSource('formula', '365d', BrewSourceUrl.join(base,
    '/analytics/install-on-request/homebrew-core/365d.json')));
  out.push(new CatalogSource('cask', '30d', BrewSourceUrl.join(base,
    '/analytics/cask-install/homebrew-cask/30d.json')));
  out.push(new CatalogSource('cask', '365d', BrewSourceUrl.join(base,
    '/analytics/cask-install/homebrew-cask/365d.json')));
  return out;
}

/** 榜单定义：(boardKey, build() 结果里的键)。顺序即展示顺序，与 generate.py 的 DISCOVER_BOARDS 一致 */
export const BREW_CATALOG_BOARDS: string[][] = [
  ['trending', 'rising'],
  ['alltime', 'alltime'],
  ['fresh', 'fresh'],
];

/** 聚合文件的条目（字段名随 kind 变化：formula / cask） */
export interface CatalogAnalyticsItem {
  formula?: string;
  cask?: string;
  count?: string;
}

/** 聚合文件的真实形状（`formulae` 与 `casks` 同一个位置，cask 文件里 key 也叫 `formulae`） */
export interface CatalogAnalyticsDoc {
  category?: string;
  total_items?: number;
  total_count?: number;
  start_date?: string;
  end_date?: string;
  formulae?: Record<string, CatalogAnalyticsItem[]>;
  casks?: Record<string, CatalogAnalyticsItem[]>;
}

export interface CatalogWindowMeta {
  category: string;
  totalItems: number;
  totalCount: number;
  windowStart: string;
  windowEnd: string;
  /** 摊平后的 token 数 */
  tokens: number;
  /** 「一个 token 多条记录」的个数 —— 这个数字是坑 2 的现场证据，要打出来 */
  multiEntryTokens: number;
}

export interface CatalogCounts {
  counts: Record<string, number>;
  meta: CatalogWindowMeta;
}

/** 一个 family 的代表记录（三张榜引用同一批对象） */
export interface CatalogRecord {
  token: string;
  family: string;
  vol30d: number;
  vol365d: number;
  prior: number;
  velocity: number;
  /** 只有趋势榜候选会被赋值 */
  score: number;
}

export interface CatalogKindResult {
  kind: string;
  rawTokens: number;
  families: number;
  rising: CatalogRecord[];
  alltime: CatalogRecord[];
  fresh: CatalogRecord[];
  /** 按 30d 安装量降序（family 已去重）。浏览页取它的前 N 个 —— 榜单要的是"涨得快"，浏览要的是"装得多" */
  byVolume: CatalogRecord[];
  candidates: number;
  /** 实际分位数（用于与门槛对比，看基数有没有漂移） */
  actualVolP: number;
  actualPriorP: number;
}

export class BrewCatalogAlgo {
  /**
   * 把聚合 JSON 摊成 `token -> 安装量`。
   *
   * 三个坑都在这一个函数里（字典 / 多条求和 / 千分位字符串）。
   * `key` 的取法照 Python：有 `formulae` 就用它 —— **cask 文件里这个 key 也叫 `formulae`**。
   */
  public static parseCounts(payload: CatalogAnalyticsDoc): CatalogCounts {
    const key: string = payload.formulae !== undefined ? 'formulae' : 'casks';
    const table: Record<string, CatalogAnalyticsItem[]> | undefined =
      key === 'formulae' ? payload.formulae : payload.casks;
    const counts: Record<string, number> = {};
    let multi: number = 0;
    if (table !== undefined && table !== null) {
      Object.keys(table).forEach((token: string) => {
        const entries: CatalogAnalyticsItem[] = table[token] ?? [];
        if (entries.length > 1) {
          multi++;
        }
        let sum: number = 0;
        entries.forEach((entry: CatalogAnalyticsItem) => {
          sum += BrewCatalogAlgo.intOf(entry.count);
        });
        counts[token] = sum;
      });
    }
    const meta: CatalogWindowMeta = {
      category: payload.category ?? '',
      totalItems: payload.total_items ?? 0,
      totalCount: payload.total_count ?? 0,
      windowStart: payload.start_date ?? '',
      windowEnd: payload.end_date ?? '',
      tokens: Object.keys(counts).length,
      multiEntryTokens: multi,
    };
    return { counts: counts, meta: meta };
  }

  /**
   * family 去重键：`go@1.26 -> go`。
   *
   * `family_exceptions.json` 在仓库里**不存在**（Python 侧实测同样走空表），所以这里没有例外表；
   * 若要加例外，必须两边同时加，否则设备端与生成器会算出不同的榜。
   */
  public static familyOf(token: string): string {
    const at: number = token.indexOf('@');
    return at < 0 ? token : token.substring(0, at);
  }

  /**
   * 与 Python `percentiles()` 同一口径：`idx = min(len-1, floor(len*p))`（**不做插值**）。
   * 换成"标准"分位算法会得到不同的门槛，进而得到另一张榜。
   */
  public static percentile(values: number[], pct: number): number {
    if (values.length === 0) {
      return 0;
    }
    const ordered: number[] = values.slice().sort((a: number, b: number) => a - b);
    const idx: number = Math.min(ordered.length - 1, Math.floor(ordered.length * pct));
    return ordered[idx];
  }

  /**
   * 算出三张榜。
   *
   * 口径（docs/brew-discover-algo.md §3/§5）：
   *   - `prior = (365d − 30d) / priorDivisor`，**分母不加 `max(1, ·)`**
   *     （"没有历史"是独立类别，见新星榜）；
   *   - `velocity = 30d / prior`，`prior <= 0` 时记 0（0 = 无历史，不要显示成"0 倍"）；
   *   - 趋势榜 `score = log1p(velocity) × log1p(30d)`，**不 cap**（cap 会把整张榜压平）；
   *   - family 去重：同 family 只留 30d 最大的 token（否则 `python@3.1x` 会一起挤进榜）。
   *
   * 官方源的调用约定：必须传 **`11.0`**。这是官方 335 天窗口折算月均后的**标定值**；
   * 不要改成 `335 / 30.4`（约 11.02），否则会改变上游 `prior`，进而悄悄改变上游榜单。
   * 其它源应传自身基线天数折算后的除数。
   */
  public static build(kind: string, a30: Record<string, number>, a365: Record<string, number>,
    priorDivisor: number, thresholds: CatalogThresholds): CatalogKindResult {
    const cfg: CatalogThresholds = thresholds;
    const shared: string[] = Object.keys(a30).filter((token: string) => a365[token] !== undefined);

    const keep: Record<string, string> = {};
    shared.forEach((token: string) => {
      const family: string = BrewCatalogAlgo.familyOf(token);
      const current: string | undefined = keep[family];
      if (current === undefined || a30[token] > a30[current]) {
        keep[family] = token;
      }
    });

    const records: CatalogRecord[] = Object.keys(keep).map((family: string) => {
      const token: string = keep[family];
      const prior: number = (a365[token] - a30[token]) / priorDivisor;
      const record: CatalogRecord = {
        token: token,
        family: family,
        vol30d: a30[token],
        vol365d: a365[token],
        prior: prior,
        velocity: prior > 0 ? a30[token] / prior : 0,
        score: 0,
      };
      return record;
    });

    const rising: CatalogRecord[] = records.filter((r: CatalogRecord) =>
      r.vol30d >= cfg.volFloor && r.prior >= cfg.minPrior);
    rising.forEach((r: CatalogRecord) => {
      r.score = Math.log(1 + r.velocity) * Math.log(1 + r.vol30d);
    });
    rising.sort((a: CatalogRecord, b: CatalogRecord) => b.score - a.score);

    const alltime: CatalogRecord[] = records.slice()
      .sort((a: CatalogRecord, b: CatalogRecord) => b.vol365d - a.vol365d);

    const fresh: CatalogRecord[] = records.filter((r: CatalogRecord) =>
      r.vol30d >= cfg.newFloor && r.prior < cfg.minPrior)
      .sort((a: CatalogRecord, b: CatalogRecord) => b.vol30d - a.vol30d);

    const byVolume: CatalogRecord[] = records.slice()
      .sort((a: CatalogRecord, b: CatalogRecord) => b.vol30d - a.vol30d);

    return {
      kind: kind,
      rawTokens: shared.length,
      families: records.length,
      rising: rising,
      alltime: alltime,
      fresh: fresh,
      byVolume: byVolume,
      candidates: rising.length,
      actualVolP: BrewCatalogAlgo.percentile(records.map((r: CatalogRecord) => r.vol30d), cfg.volPct),
      actualPriorP: BrewCatalogAlgo.percentile(
        records.filter((r: CatalogRecord) => r.prior > 0).map((r: CatalogRecord) => r.prior), cfg.priorPct),
    };
  }

  /** `"62,667"` -> `62667`。取不到数字时给 0（Python 侧会抛错，这里不给一条脏数据毁掉整张榜） */
  private static intOf(raw: string | undefined): number {
    if (raw === undefined || raw === null) {
      return 0;
    }
    const parsed: number = parseInt(raw.replace(/,/g, ''), 10);
    return Number.isNaN(parsed) ? 0 : parsed;
  }
}
