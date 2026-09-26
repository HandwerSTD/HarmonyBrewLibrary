/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { BrewChipItem, BrewFormat, BrewSearchModel } from '@ohos/brewcommon';
import type { BrewSearchHit, BrewSearchResult } from '@ohos/brewcommon';
import { Logger } from '@ohos/common';
import { BrewSearchRow } from '../model/BrewSearchRowSource';
import { BrewSearchState } from './BrewSearchState';
import { BrewSearchHistoryStore } from './BrewSearchHistoryStore';
import {
  BREW_SEARCH_CHIP_ALL,
  BREW_SEARCH_CHIP_CASK,
  BREW_SEARCH_CHIP_FORMULA,
  BREW_SEARCH_DISCOVERY_COUNT,
  BREW_SEARCH_DISCOVERY_POOL_SIZE,
  BREW_SEARCH_HISTORY_LIMIT,
} from '../constant/BrewSearchConstants';

const TAG: string = '[BrewSearch]';

/**
 * 搜索的门面。持有**会话级**状态（历史 / 发现的轮换位置），
 * **每页**状态（关键字、chips、结果）由调用方通过 `BrewSearchState` 传进来。
 *
 * 历史与发现**都是真数据**（本轮变更）：
 *   - 历史 = 用户真正执行过的搜索，由 `recordSearch()` 写入并落盘（重启后仍在，
 *     见 `BrewSearchHistoryStore`）；本类因此是历史的唯一写者；
 *   - 发现 = 设备端目录里的真实热门包（`BrewSearchModel.hotTokens`），池内轮换。
 *
 * 这样切分的理由：搜索页（可被销毁重建）每次都要读到同一份历史与发现，
 * 只有共享一份才不会出现「刚搜过的词在重新进页面后不见了」。而结果本身必须每页独立
 * （`state` 留在调用方那里正是为此）。
 */
export class BrewSearchVM {
  private static instance: BrewSearchVM | undefined = undefined;
  private model: BrewSearchModel = BrewSearchModel.getInstance();
  /** 历史的内存副本。`historyLoaded` 为 false 时还没读过盘（见 `history()`） */
  private historyWords: string[] = [];
  private historyLoaded: boolean = false;
  private discoveryOffset: number = 0;
  /**
   * 真实热门池的进程内缓存（见 `hotPool()`）。
   *
   * **只在拿到非空结果时缓存**：首次安装 / 断网时 `hotTokens` 返回空数组，若把空值也缓存，
   * 「目录后来到了」也永远是空态（页面不重建就看不到发现）。非空才缓存，则一次会话最多算两次。
   */
  private hotPoolCache: string[] = [];
  private chipItems: BrewChipItem[] = [
    new BrewChipItem(BREW_SEARCH_CHIP_ALL, $r('app.string.brew_search_filter_all')),
    new BrewChipItem(BREW_SEARCH_CHIP_FORMULA, $r('app.string.brew_search_filter_formula')),
    new BrewChipItem(BREW_SEARCH_CHIP_CASK, $r('app.string.brew_search_filter_cask')),
  ];

  public static getInstance(): BrewSearchVM {
    if (BrewSearchVM.instance === undefined) {
      BrewSearchVM.instance = new BrewSearchVM();
    }
    return BrewSearchVM.instance;
  }

  public chips(): BrewChipItem[] {
    return this.chipItems;
  }

  /**
   * 历史（**真实搜索记录**，落盘在 Preference）。
   *
   * 首次访问才读盘，不在构造时读：`PreferenceManager` 依赖 `AppStorage` 里的 `UIContext`，
   * 而本类是单例 —— 构造时机不由我们挑（可能早到 UI 还没起来），放到第一次真要用时读最稳。
   * 读完后 `historyLoaded` 置位，之后一律读内存副本（写盘也会同步更新它）。
   */
  public history(): string[] {
    if (!this.historyLoaded) {
      this.historyLoaded = true;
      this.historyWords = BrewSearchHistoryStore.load();
    }
    return this.historyWords;
  }

  /**
   * 记一次搜索。**调用点是「真正执行了搜索」的那一刻**（`BrewSearchResultView.apply`），
   * 而不是输入框每次变化 —— 半截词（`nod`）不该进历史。
   *
   * 规则：去首尾空白 → 空串直接忽略 → **大小写不敏感**去重（保留最新写法，`Node` 搜过再搜
   * `node` 只留 `node`）→ 置顶 → 截断到 `BREW_SEARCH_HISTORY_LIMIT`。
   * **0 结果也记**：历史是「我用过的词」，不是「搜到过东西的词」。
   */
  public recordSearch(word: string): void {
    const trimmed: string = word.trim();
    if (trimmed.length === 0) {
      return;
    }
    const next: string[] = [trimmed];
    this.history().forEach((old: string) => {
      if (next.length < BREW_SEARCH_HISTORY_LIMIT && old.toLowerCase() !== trimmed.toLowerCase()) {
        next.push(old);
      }
    });
    // 点历史项把同一个词再搜一遍：列表没变就不必再刷一次盘
    if (BrewSearchVM.sameWords(this.historyWords, next)) {
      return;
    }
    this.historyWords = next;
    BrewSearchHistoryStore.save(next);
    Logger.info(TAG, `search history +"${trimmed}" → ${next.length} words`);
  }

  public clearHistory(): void {
    // 先确保读过盘：没读过就清，盘上的旧数据会在下次 `history()` 时被读回来（看起来像没清掉）
    this.history();
    this.historyWords = [];
    BrewSearchHistoryStore.clear();
  }

  /**
   * 发现：**设备端目录里的真实热门包**取一窗，池内轮换（`换一批`）。
   *
   * 池 = `BrewSearchModel.hotTokens`（formula + cask 按 30 天安装量归并，同步、零请求）。
   * 拿不到目录（首次安装 / 断网且盘上没目录）时返回空数组 —— UI 显示空态，
   * **不回落任何写死的词**（那些词在 Homebrew 里不存在，点下去必然空结果）。
   * 池比窗口还短时按池的实际长度出满（`want`），不把同一条重复摆在两格上。
   */
  public discoveries(): string[] {
    const pool: string[] = this.hotPool();
    const want: number = Math.min(BREW_SEARCH_DISCOVERY_COUNT, pool.length);
    const out: string[] = [];
    for (let i: number = 0; i < want; i++) {
      out.push(pool[(this.discoveryOffset + i) % pool.length]);
    }
    return out;
  }

  /** 「换一批」：池内轮换（+窗口大小取模）。池为空时不动 offset，否则会把位置推到池外 */
  public rotateDiscovery(): void {
    const size: number = this.hotPool().length;
    if (size === 0) {
      return;
    }
    this.discoveryOffset = (this.discoveryOffset + BREW_SEARCH_DISCOVERY_COUNT) % size;
  }

  /** 热门池：非空即缓存（理由见字段注释） */
  private hotPool(): string[] {
    if (this.hotPoolCache.length > 0) {
      return this.hotPoolCache;
    }
    this.hotPoolCache = this.model.hotTokens(BREW_SEARCH_DISCOVERY_POOL_SIZE);
    return this.hotPoolCache;
  }

  /** 两个历史列表是否逐项相同（重复搜同一个词时用来跳过写盘） */
  private static sameWords(a: string[], b: string[]): boolean {
    if (a.length !== b.length) {
      return false;
    }
    for (let i: number = 0; i < a.length; i++) {
      if (a[i] !== b[i]) {
        return false;
      }
    }
    return true;
  }

  /**
   * 当前 chips 对应的 kind（空串 = 不过滤），与 `BrewSearchEngine.filterByKind` 的语义一致。
   *
   * 从**选中 chip 自己的 id** 取，不按 `filterIndex` 硬编码「1 = formula / 2 = cask」：
   * chips 的顺序与内容都是在 `chipItems` 里定义的，硬编码下标会在调整顺序（或插一项）时
   * 静默错配 —— chip 写着「Cask」，过滤却按 formula 走，不报错也没日志。
   */
  public filterKindOf(state: BrewSearchState): string {
    // 越界下标（chips 变短）按「全部」处理，宁可不过滤也不能拿错 kind
    const id: string = this.chipItems[state.filterIndex]?.id ?? BREW_SEARCH_CHIP_ALL;
    // 「全部」这一项的**过滤值是空串**（引擎约定空串 = 不过滤）—— 它的 id 与过滤值不是一回事
    return id === BREW_SEARCH_CHIP_ALL ? '' : id;
  }

  /**
   * 跑一次搜索并把结果写进**这一页**的 state。
   *
   * 返回 `undefined` = 这次调用已经过期（关键字在返回前又被改过），调用方**不要覆盖列表**。
   */
  public search(keyword: string, state: BrewSearchState): Promise<BrewSearchRow[] | undefined> {
    return this.model.search(keyword).then((result: BrewSearchResult) => {
      // 与**本页最近一次请求**比：`state.keyword` 由调用方在发起请求前同步写入。
      // 不能拿 `result.keyword` 与 `BrewSearchEngine.normalize(keyword)` 比 —— 模型里的
      // `result.keyword` 就是 `normalize(同一个入参)`，两边永远相等，那个判定是句废话，
      // 拦不住「旧结果回来把新列表盖掉」。
      if (state.keyword !== keyword) {
        return undefined;
      }
      state.result = result;
      state.total = result.total;
      state.indexReady = result.indexReady;
      state.rowsFromIndexOnly = result.rowsFromIndexOnly;
      return this.rowsOf(state);
    });
  }

  /** 按当前 chips 从**已算好的**结果里取行（chips 切换不重跑引擎） */
  public rowsOf(state: BrewSearchState): BrewSearchRow[] {
    const result: BrewSearchResult | undefined = state.result;
    if (result === undefined) {
      return [];
    }
    const kind: string = this.filterKindOf(state);
    const rows: BrewSearchRow[] = [];
    result.hits.forEach((hit: BrewSearchHit, index: number) => {
      if (kind.length === 0 || hit.kind === kind) {
        rows.push(new BrewSearchRow(BrewFormat.brewKindOf(hit.kind), result.items[index]));
      }
    });
    return rows;
  }
}
