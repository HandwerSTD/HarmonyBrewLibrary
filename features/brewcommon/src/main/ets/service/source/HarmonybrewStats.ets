/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { fileIo } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger, StorageKey } from '@ohos/common';
import { BrewHttp } from '../BrewHttp';
import type { BrewHttpResult } from '../BrewHttp';
import { BrewSourceUrl } from '../BrewSourceUrl';
import {
  BREW_HARMONYBREW_STATS_CONCURRENCY,
  BREW_HARMONYBREW_STATS_CURRENT_DAYS,
  BREW_HARMONYBREW_STATS_PATH_TEMPLATE,
  BREW_HARMONYBREW_STATS_PRIOR_DAYS,
  BREW_HARMONYBREW_STATS_TOTAL_DAYS,
} from '../../constant/BrewSourceConstants';
import type { BrewCatalogInput } from './BrewCatalogInput';

const TAG: string = '[HarmonybrewStats]';
const DAY_MS: number = 24 * 60 * 60 * 1000;
const CATEGORY: string = 'harmonybrew-stats';

interface NewestDay {
  key: string;
  timestamp: number;
  lastModified: string;
}

interface WindowDay {
  key: string;
  iso: string;
  current: boolean;
}

interface DayFile {
  key: string;
  current: boolean;
  state: string;
  text: string;
}

interface FetchSummary {
  days: DayFile[];
  cached: number;
  fetched: number;
  missing: number;
  failed: number;
}

interface SumResult {
  a30: Record<string, number>;
  aOld: Record<string, number>;
  a365: Record<string, number>;
  total30: number;
  totalPrior: number;
}

interface FormulaCountEntry {
  formula: string;
  count: string;
}

interface SynthAnalyticsDoc {
  category: string;
  total_items: number;
  total_count: number;
  start_date: string;
  end_date: string;
  formulae: Record<string, FormulaCountEntry[]>;
}

/** Harmonybrew 日文件取数、按天缓存与 30d/365d 上游文档合成。 */
export class HarmonybrewStats {
  /**
   * 取到窗口内所有可用的日文件，返回合成好的两份 CatalogAnalyticsDoc JSON 文本。
   * 任何步骤都无法得到可用日文件时返回 undefined；单日 404 只记 missing。
   */
  public static async synth(baseUrl: string, sourceId: string): Promise<BrewCatalogInput[] | undefined> {
    let newest: NewestDay | undefined = undefined;
    let newestStep: string = 'latest=today-1';
    try {
      newest = await HarmonybrewStats.findNewest(baseUrl);
    } catch (error) {
      const err = error as BusinessError;
      Logger.error(TAG, `at=${newestStep} failed code=${err?.code} msg=${err?.message}`);
      return undefined;
    }
    if (newest === undefined) {
      return undefined;
    }

    let window: WindowDay[] = [];
    let windowStep: string = 'window';
    try {
      window = HarmonybrewStats.makeWindow(newest.timestamp);
      Logger.info(TAG, `at=${windowStep} newest=${newest.key} days=${window.length} ` +
        `current=${BREW_HARMONYBREW_STATS_CURRENT_DAYS} prior=${BREW_HARMONYBREW_STATS_PRIOR_DAYS} ` +
        'caliber=30d+60d');
    } catch (error) {
      const err = error as BusinessError;
      Logger.error(TAG, `at=${windowStep} failed code=${err?.code} msg=${err?.message}`);
      return undefined;
    }

    let cacheDirectory: string = '';
    let summary: FetchSummary | undefined = undefined;
    let cacheStep: string = 'cache-setup';
    try {
      cacheDirectory = HarmonybrewStats.ensureCacheDirectory(sourceId);
      if (cacheDirectory.length > 0) {
        summary = await HarmonybrewStats.loadWindow(baseUrl, cacheDirectory, window);
        Logger.info(TAG, `at=cache-fetch newest=${newest.key} days=${window.length} ` +
          `cached=${summary.cached} fetched=${summary.fetched} missing=${summary.missing} ` +
          `failed=${summary.failed}`);
      }
    } catch (error) {
      const err = error as BusinessError;
      Logger.error(TAG, `at=${cacheStep} failed id=${sourceId} code=${err?.code} msg=${err?.message}`);
      return undefined;
    }
    if (summary === undefined) {
      return undefined;
    }
    const available: number = summary.cached + summary.fetched;
    if (available === 0) {
      Logger.warn(TAG, 'at=cache-fetch unavailable=all days failed or missing');
      return undefined;
    }

    let removed: number = 0;
    let evictStep: string = 'evict-list';
    try {
      removed = HarmonybrewStats.evictOutside(cacheDirectory, window);
      Logger.info(TAG, `at=evict removed=${removed} kept=${window.length}`);
    } catch (error) {
      const err = error as BusinessError;
      Logger.warn(TAG, `at=${evictStep} failed id=${sourceId} code=${err?.code} msg=${err?.message}`);
    }

    let sums: SumResult | undefined = undefined;
    let sumStep: string = 'sum';
    try {
      sums = HarmonybrewStats.sumWindows(window, summary.days);
      Logger.info(TAG, `at=${sumStep} window 30d=${window[window.length - BREW_HARMONYBREW_STATS_CURRENT_DAYS].iso}` +
        `..${window[window.length - 1].iso} tokens=${Object.keys(sums.a30).length} total=${sums.total30}`);
      Logger.info(TAG, `at=${sumStep} window prior=${window[0].iso}..` +
        `${window[BREW_HARMONYBREW_STATS_CURRENT_DAYS - 1].iso} days=${BREW_HARMONYBREW_STATS_PRIOR_DAYS} ` +
        `tokens=${Object.keys(sums.aOld).length} total=${sums.totalPrior}`);
    } catch (error) {
      const err = error as BusinessError;
      Logger.error(TAG, `at=${sumStep} failed code=${err?.code} msg=${err?.message}`);
      return undefined;
    }
    if (sums === undefined) {
      return undefined;
    }

    let inputs: BrewCatalogInput[] = [];
    let synthStep: string = 'synthesize';
    try {
      // ⚠ `window` 是**从新到旧**排列的（`makeWindow` 用 `newestTimestamp - offset * DAY_MS` 展开）：
      //   window[0]                     = 最新一天
      //   window[CURRENT_DAYS - 1]      = 当前窗口（最近 30 天）的**最早**一天
      //   window[TOTAL_DAYS - 1]        = 基线窗口的**最早**一天
      // 上一版把下标按「从旧到新」写了：`currentStart` 取了 `window[length - CURRENT_DAYS]`
      // （= window[60]，那其实是**基线**窗口的起点），`end` 取了 `window[length - 1]`
      // （= **最旧**一天）—— 于是真机日志出现 `win=2026-07-25~2026-06-26`，**起点晚于终点**。
      // 影响：`start_date`/`end_date` 只进 `CatalogKindMeta`、**不进算法**，所以榜单与排序不受影响；
      // 但 Discover 页下方「基于最近可用数据 <日期>」取自 `windowEnd`，会显示成 6 月而不是 9 月。
      // 这是「看着像正常范围」的错 —— 不盯着起点/终点的先后就看不出来。
      const newestIso: string = window[0].iso;
      const currentStart: string = window[BREW_HARMONYBREW_STATS_CURRENT_DAYS - 1].iso;
      const oldest: string = window[window.length - 1].iso;
      const doc30: SynthAnalyticsDoc = HarmonybrewStats.makeDoc(sums.a30, currentStart, newestIso);
      const doc365: SynthAnalyticsDoc = HarmonybrewStats.makeDoc(sums.a365, oldest, newestIso);
      // 这两个 URL 是**合成标记**，只用作 `stamps` 的键，**永远不会被请求**。
      // 不拼成真实地址形态，以免日后有人以为它们是可访问的端点。
      const url30: string = 'synth://harmonybrew/stats-30d';
      const url365: string = 'synth://harmonybrew/stats-365d';
      const input30: BrewCatalogInput = {
        kind: 'formula', win: '30d', url: url30, text: JSON.stringify(doc30),
        lastModified: newest.lastModified,
      };
      const input365: BrewCatalogInput = {
        kind: 'formula', win: '365d', url: url365, text: JSON.stringify(doc365),
        lastModified: newest.lastModified,
      };
      inputs = [input30, input365];
      const a365: Record<string, number> = sums.a365;
      const shared: number = Object.keys(sums.a30).filter((token: string) => a365[token] !== undefined).length;
      Logger.info(TAG, `at=${synthStep} key=formulae win30=${Object.keys(sums.a30).length} ` +
        `win365=${Object.keys(sums.a365).length} shared=${shared}`);
    } catch (error) {
      const err = error as BusinessError;
      Logger.error(TAG, `at=${synthStep} failed code=${err?.code} msg=${err?.message}`);
      return undefined;
    }

    Logger.info(TAG, `at=complete newest=${newest.key} days=${BREW_HARMONYBREW_STATS_TOTAL_DAYS} ` +
      `available=${available} inputs=${inputs.length}`);
    return inputs;
  }

  /** Step 1：today-1（UTC）不可用时只对 404 回退到 today-2。 */
  private static async findNewest(baseUrl: string): Promise<NewestDay | undefined> {
    const now: Date = new Date();
    const today: number = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());
    const firstKey: string = HarmonybrewStats.dayKey(today - DAY_MS);
    // URL 进日志：上一版只打了 `candidate=<日期>`，于是「路径拼错成 /api/stats」
    // 这个 bug 只能靠真机往返才发现 —— 宿主机 curl 同一个日期是 200，日志里却只有 404。
    const firstUrl: string = HarmonybrewStats.statsUrl(baseUrl, firstKey);
    let response: BrewHttpResult;
    try {
      response = await BrewHttp.head(firstUrl, {}, BrewHttp.TIMEOUT_PROBE);
    } catch (error) {
      const err = error as BusinessError;
      Logger.error(TAG, `at=latest=today-1 request-failed code=${err?.code} ` +
        `msg=${err?.message} url=${firstUrl}`);
      return undefined;
    }
    if (response.code === http.ResponseCode.OK) {
      Logger.info(TAG, `at=latest=today-1 selected=${firstKey} url=${firstUrl}`);
      return { key: firstKey, timestamp: today - DAY_MS, lastModified: response.headers['last-modified'] ?? '' };
    }
    if (response.code !== 404) {
      Logger.warn(TAG, `at=latest=today-1 rejected code=${response.code} ` +
        `candidate=${firstKey} url=${firstUrl}`);
      return undefined;
    }

    let fallback: BrewHttpResult;
    const secondKey: string = HarmonybrewStats.dayKey(today - 2 * DAY_MS);
    const secondUrl: string = HarmonybrewStats.statsUrl(baseUrl, secondKey);
    try {
      fallback = await BrewHttp.head(secondUrl, {}, BrewHttp.TIMEOUT_PROBE);
    } catch (error) {
      const err = error as BusinessError;
      Logger.error(TAG, `at=latest=today-2 request-failed candidate=${secondKey} ` +
        `code=${err?.code} msg=${err?.message} url=${secondUrl}`);
      return undefined;
    }
    if (fallback.code === http.ResponseCode.OK) {
      Logger.info(TAG, `at=latest=today-2 selected=${secondKey} reason=today-1-404 url=${secondUrl}`);
      return { key: secondKey, timestamp: today - 2 * DAY_MS, lastModified: fallback.headers['last-modified'] ?? '' };
    }
    Logger.warn(TAG, `at=latest=today-2 rejected code=${fallback.code} ` +
      `candidate=${secondKey} url=${secondUrl}`);
    return undefined;
  }

  /** Step 2：从最新日向过去展开 30 + 60 个日历日。 */
  private static makeWindow(newestTimestamp: number): WindowDay[] {
    const out: WindowDay[] = [];
    for (let offset: number = 0; offset < BREW_HARMONYBREW_STATS_TOTAL_DAYS; offset++) {
      const key: string = HarmonybrewStats.dayKey(newestTimestamp - offset * DAY_MS);
      const current: boolean = offset < BREW_HARMONYBREW_STATS_CURRENT_DAYS;
      out.push({ key: key, iso: HarmonybrewStats.isoDate(key), current: current });
    }
    return out;
  }

  /** Step 3：存在则读缓存；缺失日以固定并发拉取。 */
  private static async loadWindow(baseUrl: string, cacheDirectory: string,
    window: WindowDay[]): Promise<FetchSummary> {
    const missing: WindowDay[] = [];
    const days: DayFile[] = [];
    let cached: number = 0;
    window.forEach((day: WindowDay) => {
      const text: string = HarmonybrewStats.readCache(cacheDirectory, day.key);
      let valid: boolean = false;
      if (text.length > 0) {
        try {
          valid = HarmonybrewStats.validDay(text);
        } catch (error) {
          const err = error as BusinessError;
          Logger.warn(TAG, `at=cache-validate date=${day.key} failed code=${err?.code} msg=${err?.message}`);
        }
      }
      if (valid) {
        cached++;
        days.push({ key: day.key, current: day.current, state: 'cached', text: text });
      } else {
        missing.push(day);
      }
    });

    let fetched: number = 0;
    let missingCount: number = 0;
    let failed: number = 0;
    for (let start: number = 0; start < missing.length; start += BREW_HARMONYBREW_STATS_CONCURRENCY) {
      const end: number = Math.min(start + BREW_HARMONYBREW_STATS_CONCURRENCY, missing.length);
      const batch: WindowDay[] = missing.slice(start, end);
      const loaded: DayFile[] = await Promise.all(batch.map((day: WindowDay) =>
        HarmonybrewStats.fetchDay(baseUrl, cacheDirectory, day)));
      loaded.forEach((day: DayFile) => {
        days.push(day);
        if (day.state === 'fetched') {
          fetched++;
        } else if (day.state === 'missing') {
          missingCount++;
        } else {
          failed++;
        }
      });
    }
    return { days: days, cached: cached, fetched: fetched, missing: missingCount, failed: failed };
  }

  /** 单日缓存命中时完全不发请求。 */
  private static async fetchDay(baseUrl: string, cacheDirectory: string, day: WindowDay): Promise<DayFile> {
    let response: BrewHttpResult;
    try {
      response = await BrewHttp.request(HarmonybrewStats.statsUrl(baseUrl, day.key), http.RequestMethod.GET,
        {}, BrewHttp.TIMEOUT_DEFAULT);
    } catch (error) {
      const err = error as BusinessError;
      Logger.error(TAG, `at=day-fetch date=${day.key} failed code=${err?.code} msg=${err?.message}`);
      return { key: day.key, current: day.current, state: 'failed', text: '' };
    }
    if (response.code === 404) {
      Logger.info(TAG, `at=day-missing date=${day.key} code=404`);
      return { key: day.key, current: day.current, state: 'missing', text: '' };
    }
    if (response.code !== http.ResponseCode.OK || response.text.length === 0) {
      Logger.warn(TAG, `at=day-fetch date=${day.key} rejected code=${response.code} bytes=${response.text.length}`);
      return { key: day.key, current: day.current, state: 'failed', text: '' };
    }
    try {
      if (!HarmonybrewStats.validDay(response.text)) {
        Logger.warn(TAG, `at=day-validate date=${day.key} rejected=not-flat-counts`);
        return { key: day.key, current: day.current, state: 'failed', text: '' };
      }
    } catch (error) {
      const err = error as BusinessError;
      Logger.error(TAG, `at=day-validate date=${day.key} failed code=${err?.code} msg=${err?.message}`);
      return { key: day.key, current: day.current, state: 'failed', text: '' };
    }
    try {
      if (!HarmonybrewStats.writeCache(cacheDirectory, day.key, response.text)) {
        return { key: day.key, current: day.current, state: 'failed', text: '' };
      }
    } catch (error) {
      const err = error as BusinessError;
      Logger.error(TAG, `at=cache-write date=${day.key} failed code=${err?.code} msg=${err?.message}`);
      return { key: day.key, current: day.current, state: 'failed', text: '' };
    }
    return { key: day.key, current: day.current, state: 'fetched', text: response.text };
  }

  /** Step 4：只保留当前 90 天窗口内的 YYYYMMDD.json。 */
  private static evictOutside(cacheDirectory: string, window: WindowDay[]): number {
    const keep: Set<string> = new Set<string>();
    window.forEach((day: WindowDay) => keep.add(day.key + '.json'));
    const names: string[] = fileIo.listFileSync(cacheDirectory);
    let removed: number = 0;
    names.forEach((name: string) => {
      if (name.length !== 13 || !name.endsWith('.json') || keep.has(name)) {
        return;
      }
      const digits: string = name.substring(0, 8);
      for (let i: number = 0; i < digits.length; i++) {
        if (digits.charAt(i) < '0' || digits.charAt(i) > '9') {
          return;
        }
      }
      try {
        if (fileIo.accessSync(cacheDirectory + '/' + name)) {
          fileIo.unlinkSync(cacheDirectory + '/' + name);
          removed++;
        }
      } catch (error) {
        const err = error as BusinessError;
        Logger.warn(TAG, `at=evict-unlink file=${name} failed code=${err?.code} msg=${err?.message}`);
      }
    });
    return removed;
  }

  /** Step 5：最近 30 天为 a30，此前 60 天为 aOld；365d 从 a30 起累加以确保是其超集。 */
  private static sumWindows(window: WindowDay[], days: DayFile[]): SumResult {
    const byKey: Record<string, DayFile> = {};
    days.forEach((day: DayFile) => {
      if (day.text.length > 0) {
        byKey[day.key] = day;
      }
    });
    const a30: Record<string, number> = {};
    const aOld: Record<string, number> = {};
    const a365: Record<string, number> = {};
    let total30: number = 0;
    let totalPrior: number = 0;
    window.forEach((day: WindowDay) => {
      const file: DayFile | undefined = byKey[day.key];
      if (file === undefined) {
        return;
      }
      let raw: Record<string, Object>;
      try {
        raw = JSON.parse(file.text) as Record<string, Object>;
      } catch (error) {
        const err = error as BusinessError;
        Logger.error(TAG, `at=sum-parse date=${day.key} failed code=${err?.code} msg=${err?.message}`);
        return;
      }
      Object.keys(raw).forEach((token: string) => {
        const count: number = HarmonybrewStats.countOf(raw[token]);
        if (count <= 0) {
          return;
        }
        if (day.current) {
          a30[token] = (a30[token] ?? 0) + count;
          a365[token] = (a365[token] ?? 0) + count;
          total30 += count;
        } else {
          aOld[token] = (aOld[token] ?? 0) + count;
          a365[token] = (a365[token] ?? 0) + count;
          totalPrior += count;
        }
      });
    });
    return { a30: a30, aOld: aOld, a365: a365, total30: total30, totalPrior: totalPrior };
  }

  /** Step 6：上游按 formulae 键分派；count 沿用 analytics 的字符串形状。 */
  private static makeDoc(counts: Record<string, number>, start: string, end: string): SynthAnalyticsDoc {
    const formulae: Record<string, FormulaCountEntry[]> = {};
    let total: number = 0;
    Object.keys(counts).forEach((token: string) => {
      const count: number = counts[token];
      const entry: FormulaCountEntry = { formula: token, count: `${count}` };
      formulae[token] = [entry];
      total += count;
    });
    return {
      category: CATEGORY,
      total_items: Object.keys(formulae).length,
      total_count: total,
      start_date: start,
      end_date: end,
      formulae: formulae,
    };
  }

  private static ensureCacheDirectory(sourceId: string): string {
    const ctx: Context | undefined = HarmonybrewStats.context();
    if (ctx === undefined) {
      Logger.error(TAG, 'at=cache-setup failed reason=uicontext-undefined');
      return '';
    }
    const directory: string = ctx.filesDir + '/brew_src/' + sourceId + '/stats';
    try {
      fileIo.mkdirSync(directory, true);
    } catch (error) {
      const err = error as BusinessError;
      if (err?.code !== 13900015) {
        throw new Error(`stats mkdir failed code=${err?.code} msg=${err?.message}`);
      }
    }
    return directory;
  }

  private static readCache(directory: string, day: string): string {
    const path: string = directory + '/' + day + '.json';
    let file: fileIo.File | undefined = undefined;
    try {
      if (!fileIo.accessSync(path)) {
        return '';
      }
      file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      const size: number = fileIo.statSync(file.fd).size;
      const buffer: ArrayBuffer = new ArrayBuffer(size);
      const read: number = fileIo.readSync(file.fd, buffer, { offset: 0, length: size });
      fileIo.closeSync(file);
      file = undefined;
      if (read !== size) {
        Logger.warn(TAG, `at=cache-read date=${day} short read=${read} expected=${size}`);
        return '';
      }
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      return decoder.decodeToString(new Uint8Array(buffer), { stream: false });
    } catch (error) {
      if (file !== undefined) {
        fileIo.closeSync(file);
      }
      const err = error as BusinessError;
      Logger.warn(TAG, `at=cache-read date=${day} failed code=${err?.code} msg=${err?.message}`);
      return '';
    }
  }

  private static writeCache(directory: string, day: string, text: string): boolean {
    const path: string = directory + '/' + day + '.json';
    const temporary: string = path + '.tmp';
    let file: fileIo.File | undefined = undefined;
    try {
      if (fileIo.accessSync(temporary)) {
        fileIo.unlinkSync(temporary);
      }
      file = fileIo.openSync(temporary, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE |
        fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, text);
      fileIo.closeSync(file);
      file = undefined;
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
      fileIo.renameSync(temporary, path);
      return true;
    } catch (error) {
      if (file !== undefined) {
        fileIo.closeSync(file);
      }
      const err = error as BusinessError;
      Logger.error(TAG, `at=cache-write date=${day} failed code=${err?.code} msg=${err?.message}`);
      return false;
    }
  }

  private static validDay(text: string): boolean {
    const value: Object = JSON.parse(text) as Object;
    if (typeof value !== 'object' || value === null || Array.isArray(value)) {
      return false;
    }
    const dict: Record<string, Object> = value as Record<string, Object>;
    const keys: string[] = Object.keys(dict);
    if (keys.length === 0) {
      return false;
    }
    return keys.every((token: string) => HarmonybrewStats.countOf(dict[token]) >= 0);
  }

  private static countOf(value: Object): number {
    if (typeof value === 'number') {
      return value as number;
    }
    if (typeof value === 'string') {
      return Number(value);
    }
    return Number.NaN;
  }

  private static statsUrl(baseUrl: string, day: string): string {
    // ⚠ **必须用 originJoin，不能用 join**：本源的 baseUrl 是 `…/api`，
    // 而 stats 在站点根 `/stats/` 下。用 join 会得到 `/api/stats/…` → 404（真机实测过）。
    return BrewSourceUrl.originJoin(baseUrl,
      BREW_HARMONYBREW_STATS_PATH_TEMPLATE.replace('YYYYMMDD', day));
  }

  private static dayKey(timestamp: number): string {
    const date: Date = new Date(timestamp);
    const year: string = `${date.getUTCFullYear()}`.padStart(4, '0');
    const month: string = `${date.getUTCMonth() + 1}`.padStart(2, '0');
    const day: string = `${date.getUTCDate()}`.padStart(2, '0');
    return year + month + day;
  }

  private static isoDate(key: string): string {
    return key.substring(0, 4) + '-' + key.substring(4, 6) + '-' + key.substring(6, 8);
  }

  private static context(): Context | undefined {
    const uiContext: UIContext | undefined = AppStorage.get<UIContext>(StorageKey.UI_CONTEXT);
    return uiContext === undefined ? undefined : uiContext.getHostContext();
  }
}
