/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { Logger } from '@ohos/common';
import { BrewLoadLog } from '../util/BrewLoadLog';
import { BrewNetNotice } from '../util/BrewNetNotice';
import { BrewService } from '../service/BrewService';
import { BrewTable, BrewKindText } from '../service/BrewTable';
import type { CatalogEntry, CatalogKindMeta } from '../service/BrewTable';
import { BrewBrowseBuilder } from '../service/BrewBrowseBuilder';
import { BrewTaxonomy } from '../constant/BrewTaxonomy';
import { BrewApiMapper } from '../service/BrewApiMapper';
import type { LiveCaskDoc, LiveFormulaDoc } from '../service/BrewApiMapper';
import { BREW_CATALOG_BOARDS } from '../service/BrewCatalogAlgo';
import { BREW_CATALOG_TOP_N, BREW_SEARCH_LIMIT } from '../constant/BrewConstants';
import { BrewSearchEngine, BrewSearchEntry } from './BrewSearchEngine';
import type { BrewSearchHit } from './BrewSearchEngine';
import {
  BrewCaskCard,
  BrewCaskCategory,
  BrewCaskPageData,
  BrewCategoryCard,
  BrewFormulaDetail,
  BrewFormulaPageData,
  BrewPackageItem,
  BrewPageData,
} from './BrewModels';
import type { BrewCaskDetail } from './BrewModels';
// 这几个是**类 / 枚举**（要 new 或当值用），必须值导入，不能 import type
import {
  BrewDiscoverBoard,
  BrewDiscoverBoardKey,
  BrewDiscoverEntry,
  BrewDiscoverFeatured,
  BrewDiscoverMeta,
  BrewDiscoverPageData,
  BrewKind,
} from './BrewModels';

const TAG: string = '[BrewRepository]';

/**
 * 搜索的日志标签**故意与 `TAG` 分开**：搜索的验收判据是 `devecocli log --keyword BrewSearch`，
 * 若沿用 `[BrewRepository]`，那行日志会被过滤掉，读起来像「搜索根本没跑」。
 */
const SEARCH_TAG: string = '[BrewSearch]';

/**
 * Repository 层。
 *
 * 数据只有两条通道：
 *   - **包表**（`BrewTable`）：榜与分类的成员、卡片版面、分类、安装量、描述、可搜索的词池。
 *     全部是设备端用「安装量片 ∩ 描述片」现算的，**稳态下零请求**。
 *   - **现网单条**（`BrewService`）：详情页的版本 / 依赖 / 许可 / 主页 / 生命周期。
 *     这是单条端点的唯一消费者。
 *
 * 浏览页、榜单与搜索的构页都是**读引用**（表在内存里已经算好了），不缓存整页：
 * 榜单是「算法在某个时间点的一次冻结」，浏览页的版面跟随表的内容，缓存整页会在
 * 表更新后仍然显示上一次组装结果。
 */
export class BrewFormulaModel {
  private static instance: BrewFormulaModel;

  private constructor() {
  }

  public static getInstance(): BrewFormulaModel {
    if (!BrewFormulaModel.instance) {
      BrewFormulaModel.instance = new BrewFormulaModel();
    }
    return BrewFormulaModel.instance;
  }

  /**
   * 分类卡首页。**读表，不发请求**。
   *
   * 表里没有成员时返回空页而不是抛错 —— 让 UI 按表的两个分片状态区分
   * 「正在建立本地数据」与「无法获取数据」（见 `stateOf`），而不是渲染一张空白页。
   */
  public getFormulaPage(currentPage: number, pageSize: number): Promise<BrewPageData<BrewFormulaPageData>> {
    const t0: number = Date.now();
    const cards: BrewCategoryCard[] = BrewTable.formulaBrowse();
    const data: BrewFormulaPageData = new BrewFormulaPageData();
    data.cardData = cards;
    const page: BrewPageData<BrewFormulaPageData> = {
      currentPage: 1,
      pageSize: pageSize,
      totalPage: 1,
      totalSize: cards.length,
      data: data,
    };
    Logger.info(TAG, `formula browse read from table, ${cards.length} cards, ` +
      `${BrewBrowseCount.entries(cards)} entries | ${BrewTable.statsLine()}`);
    BrewLoadLog.info('formula_page', 'assembled', Date.now() - t0,
      `cards=${cards.length} entries=${BrewBrowseCount.total(cards)} tableState=${BrewTable.state()}`);
    return Promise.resolve(page);
  }

  /**
   * 全部分类卡（每张卡含该分类的**完整**成员）。分类二级页与详情页的同类包都建立在它上面
   */
  public getFormulaCategories(): Promise<BrewCategoryCard[]> {
    return Promise.resolve(BrewTable.formulaBrowse());
  }

  /** 某个分类的全部成员 */
  public getCategoryPackages(categoryKey: string): Promise<BrewPackageItem[]> {
    const card: BrewCategoryCard | undefined =
      BrewTable.formulaBrowse().find((one: BrewCategoryCard) => one.categoryKey === categoryKey);
    const items: BrewPackageItem[] = card?.formulaContents ?? [];
    // 分类二级页拿到 0 条有三种完全不同的情况，日志必须能区分：
    // 分类不存在（词表与数据对不上）、分类存在但成员为空（相邻两片都正常）
    BrewLoadLog.debug('formula_page', card === undefined ? 'no-such-category' : 'category-hit', 0,
      `categoryKey=${categoryKey} items=${items.length}`);
    return Promise.resolve(items);
  }

  /** 同分类的其他包，供详情页的「同分类其他包」使用 */
  public getSameCategoryPackages(categoryKey: string, excludeToken: string,
    limit: number): Promise<BrewPackageItem[]> {
    return this.getCategoryPackages(categoryKey)
      .then((contents: BrewPackageItem[]) =>
        contents.filter((item: BrewPackageItem) => item.token !== excludeToken).slice(0, limit));
  }

  /**
   * 包详情。顺序：
   *   1. 现网单条 `/api/formula/<token>.json` —— 描述 / 版本 / 依赖 / bottle / 热度全在这里；
   *   2. 本地才有的两样由设备端算：`id`（token 的稳定哈希，只当路由参数与缓存键）与
   *      `categoryKey`（`BrewTaxonomy`：策展覆盖 → 关键词 → 兜底）；
   *   3. 现网失败 → 上一次成功归一过的详情 → 只剩骨架的 base（降级但不报错）。
   *
   * 降级也不报错：详情页的失败态应该只留给「这个 token 根本不存在」，
   * 而不是「网不好的时候打不开已缓存内容」。
   */
  public getFormulaDetail(componentId: number, token: string): Promise<BrewFormulaDetail> {
    const id: number = componentId > 0 ? componentId : BrewBrowseBuilder.tokenId(token);
    if (token.length === 0) {
      return Promise.resolve(this.degradedFormula(token, id));
    }
    return BrewService.fetchFormulaDoc(token)
      .then((doc: LiveFormulaDoc) => {
        const categoryKey: string = BrewTaxonomy.categoryOf(BrewKindText.FORMULA, token, doc.desc ?? '');
        const base: BrewFormulaDetail = BrewApiMapper.formulaBase(token, id, categoryKey,
          BrewService.catalogInstallsOf(BrewKindText.FORMULA, token));
        return BrewApiMapper.mergeFormula(base, doc);
      })
      .then((merged: BrewFormulaDetail) => {
        BrewService.saveDetail(componentId, merged);
        Logger.info(TAG, `getFormulaDetail live ok, token=${token}, v=${merged.stableVersion}`);
        return merged;
      })
      .catch((error: Error) => {
        Logger.error(TAG, `getFormulaDetail live failed, fallback to cache/base. token=${token}, ${error.message}`);
        return this.cachedFormulaDetail(componentId, this.degradedFormula(token, id));
      });
  }

  /** 降级骨架：只有 token / id / 分类（按词表猜）/ 目录里的安装量，其余字段留空 */
  private degradedFormula(token: string, id: number): BrewFormulaDetail {
    const categoryKey: string = BrewTaxonomy.categoryOf(BrewKindText.FORMULA, token, '');
    return BrewApiMapper.formulaBase(token, id, categoryKey,
      BrewService.catalogInstallsOf(BrewKindText.FORMULA, token));
  }

  /** 现网失败时的回落：优先用上一次成功合并的详情，没有就用骨架 */
  private cachedFormulaDetail(componentId: number, base: BrewFormulaDetail): BrewFormulaDetail {
    return BrewService.cachedDetail<BrewFormulaDetail>(componentId) ?? base;
  }
}

export class BrewCaskModel {
  private static instance: BrewCaskModel;

  private constructor() {
  }

  public static getInstance(): BrewCaskModel {
    if (!BrewCaskModel.instance) {
      BrewCaskModel.instance = new BrewCaskModel();
    }
    return BrewCaskModel.instance;
  }

  public getCaskPage(currentPage: number, pageSize: number): Promise<BrewPageData<BrewCaskPageData>> {
    const t0: number = Date.now();
    const categories: BrewCaskCategory[] = BrewTable.caskBrowse();
    const data: BrewCaskPageData = new BrewCaskPageData();
    data.caskCategories = categories;
    const page: BrewPageData<BrewCaskPageData> = {
      currentPage: 1,
      pageSize: pageSize,
      totalPage: 1,
      totalSize: categories.length,
      data: data,
    };
    Logger.info(TAG, `cask browse read from table, ${categories.length} categories | ${BrewTable.statsLine()}`);
    BrewLoadLog.info('cask_page', 'assembled', Date.now() - t0,
      `categories=${categories.length} cards=${BrewCaskCount.cards(categories)} ` +
      `entries=${BrewCaskCount.entries(categories)} tableState=${BrewTable.state()}`);
    return Promise.resolve(page);
  }

  /** 同 getFormulaDetail（cask 的现网单条口径是 `analytics.install`、版本字段是 `version`） */
  public getCaskDetail(componentId: number, token: string): Promise<BrewCaskDetail> {
    const id: number = componentId > 0 ? componentId : BrewBrowseBuilder.tokenId(token);
    if (token.length === 0) {
      return Promise.resolve(this.degradedCask(token, id));
    }
    return BrewService.fetchCaskDoc(token)
      .then((doc: LiveCaskDoc) => {
        const categoryKey: string = BrewTaxonomy.categoryOf(BrewKindText.CASK, token, doc.desc ?? '');
        const base: BrewCaskDetail = BrewApiMapper.caskBase(token, id, categoryKey,
          BrewService.catalogInstallsOf(BrewKindText.CASK, token));
        return BrewApiMapper.mergeCask(base, doc);
      })
      .then((merged: BrewCaskDetail) => {
        BrewService.saveDetail(componentId, merged);
        Logger.info(TAG, `getCaskDetail live ok, token=${token}, v=${merged.version}`);
        return merged;
      })
      .catch((error: Error) => {
        Logger.error(TAG, `getCaskDetail live failed, fallback to cache/base. token=${token}, ${error.message}`);
        return this.cachedCaskDetail(componentId, this.degradedCask(token, id));
      });
  }

  private degradedCask(token: string, id: number): BrewCaskDetail {
    const categoryKey: string = BrewTaxonomy.categoryOf(BrewKindText.CASK, token, '');
    return BrewApiMapper.caskBase(token, id, categoryKey,
      BrewService.catalogInstallsOf(BrewKindText.CASK, token));
  }

  private cachedCaskDetail(componentId: number, base: BrewCaskDetail): BrewCaskDetail {
    return BrewService.cachedDetail<BrewCaskDetail>(componentId) ?? base;
  }

  public getCaskCategories(): Promise<BrewCaskCategory[]> {
    return Promise.resolve(BrewTable.caskBrowse());
  }
  /** 同分类的其他包。cask 的分类是三层结构（分类 → 卡 → 条目），需要先摊平 */
  public getSameCategoryPackages(categoryKey: string, excludeToken: string,
    limit: number): Promise<BrewPackageItem[]> {
    return this.getCaskCategories()
      .then((categories: BrewCaskCategory[]) => {
        const category: BrewCaskCategory | undefined =
          categories.find((one: BrewCaskCategory) => one.categoryKey === categoryKey);
        const contents: BrewPackageItem[] = category === undefined ? [] : BrewCaskModel.contentsOf(category);
        return contents.filter((item: BrewPackageItem) => item.token !== excludeToken).slice(0, limit);
      });
  }

  /** 把「分类 → 卡 → 条目」三层摊平成条目数组 */
  private static contentsOf(category: BrewCaskCategory): BrewPackageItem[] {
    const items: BrewPackageItem[] = [];
    (category.caskCards ?? []).forEach((card) => {
      (card.caskContents ?? []).forEach((item: BrewPackageItem) => items.push(item));
    });
    return items;
  }
}

/**
 * Discover 六张榜（Formulae / Casks 各 趋势 / 历史 / 新星）。
 *
 * 骨架在代码里构造，成员唯一来源是包表的 `boards`。
 * **榜单页不缓存整页**：它是「算法在某个时间点的一次冻结」，而底层表已经带新鲜窗口与
 * 条件请求缓存；在本层再缓存一份就会出现「表更新了、页面还显示上一次组装结果」。
 */
export class BrewDiscoverModel {
  private static instance: BrewDiscoverModel;

  private constructor() {
  }

  public static getInstance(): BrewDiscoverModel {
    if (!BrewDiscoverModel.instance) {
      BrewDiscoverModel.instance = new BrewDiscoverModel();
    }
    return BrewDiscoverModel.instance;
  }

  /**
   * 组装整页。**不发请求**（除了大图卡里 cask 的显示名，见 `fillFeaturedNames`）。
   *
   * 安装量片未到时六张榜都是空的，骨架仍然返回 —— 页面据此走空态而不是错误态。
   */
  public getDiscoverPage(): Promise<BrewDiscoverPageData> {
    const tStart: number = Date.now();
    const page: BrewDiscoverPageData = BrewDiscoverModel.emptyDiscoverPage();
    const state: string = BrewTable.state();
    if (state !== 'ready') {
      Logger.info(TAG, `discover read from table, table state=${state} → boards stay empty`);
      BrewLoadLog.warn('discover_page', 'empty-table', Date.now() - tStart, `table state=${state} → 榜成员为空`);
      // ⚠ 必须与 `BrewTable` 里的 `willFetch` **成对**：表取数会先弹一条「正在获取」，
      // 不 settle 的话常驻提示会一直挂着不消失
      BrewNetNotice.settle('discover_page', `table state=${state}`);
      return Promise.resolve(page);
    }
    BrewDiscoverModel.applyCatalogMembers(page);
    BrewNetNotice.settle('discover_page', 'boards=' + page.boards.length +
      ' entries=' + BrewDiscoverModel.entryCount(page));
    return BrewDiscoverModel.fillFeaturedNames(page).then((filled: BrewDiscoverPageData) => {
      BrewLoadLog.info('discover_page', 'assembled', Date.now() - tStart,
        `entries=${BrewDiscoverModel.entryCount(filled)} featured=${filled.featured.length}`);
      return filled;
    });
  }

  /**
   * 榜骨架。
   *
   * **顺序与 id 固定**：`id = sequence = 1..6`，kind 外层 formula 先、cask 后，
   * 内层 `trending / alltime / fresh`。死守这个顺序是因为 `id` 是榜单二级页的路由参数，
   * 骨架恒为 6 张榜 → 二级页永远找得到对应那张。
   */
  private static emptyDiscoverPage(): BrewDiscoverPageData {
    const page: BrewDiscoverPageData = new BrewDiscoverPageData();
    page.topN = BREW_CATALOG_TOP_N;
    page.snapshotDate = '';
    page.meta = {};
    page.featured = [];
    let id: number = 0;
    [BrewKind.FORMULA, BrewKind.CASK].forEach((kind: string) => {
      BREW_CATALOG_BOARDS.forEach((pair: string[]) => {
        id++;
        const board: BrewDiscoverBoard = new BrewDiscoverBoard();
        board.id = id;
        board.sequence = id;
        board.kind = kind;
        board.boardKey = pair[0];
        board.entries = [];
        board.entryCount = 0;
        page.boards.push(board);
      });
    });
    return page;
  }

  /** 整页条目数 */
  private static entryCount(page: BrewDiscoverPageData): number {
    let total: number = 0;
    page.boards.forEach((board: BrewDiscoverBoard) => {
      total += board.entries.length;
    });
    return total;
  }

  /**
   * 把榜成员从表里取出来。
   *
   * 四条规则：
   *   1. 不过滤白名单：`id` 由 token 的稳定哈希给出，详情页只用现网单条渲染，
   *      所以「榜上的包点不进去」从根上不存在；
   *   2. `name` 先填 token、`desc` 填描述片里的值 —— 两者都在表里，不需要请求；
   *   3. 数字（30d / 365d / 增速 / score）**直接用表给的**：它们本来就是这台设备上算出来的，
   *      不该在展示层按单条重算（重算口径一旦与表不同步，就会出现「第 1 名的安装量比第 3 名少」）；
   *   4. `meta` 与 `snapshotDate` 一并换成实测值，页面下方那句「基于最近可用数据」有据可查。
   */
  private static applyCatalogMembers(page: BrewDiscoverPageData): void {
    const topN: number = page.topN > 0 ? page.topN : BREW_CATALOG_TOP_N;
    let resolved: number = 0;
    page.boards.forEach((board: BrewDiscoverBoard) => {
      const entries: BrewDiscoverEntry[] = [];
      BrewTable.boardRows(board.kind, board.boardKey).forEach((row: CatalogEntry) => {
        if (entries.length >= topN) {
          return;
        }
        const entry: BrewDiscoverEntry = new BrewDiscoverEntry();
        entry.rank = entries.length + 1;
        entry.id = BrewBrowseBuilder.tokenId(row.token);
        entry.token = row.token;
        entry.name = row.token;
        entry.desc = BrewTable.descOf(board.kind, row.token);
        entry.categoryKey = BrewTaxonomy.categoryOf(board.kind, row.token, entry.desc);
        entry.installs30d = row.vol30d;
        entry.installs365d = row.vol365d;
        entry.priorMonthly = row.prior;
        entry.velocity = row.velocity;
        entry.score = row.score;
        entries.push(entry);
        resolved++;
      });
      board.entries = entries;
      board.entryCount = entries.length;
    });
    [BrewKind.FORMULA, BrewKind.CASK].forEach((kind: string) => {
      const one: CatalogKindMeta | undefined = BrewTable.metaOf(kind);
      if (one === undefined) {
        return;
      }
      const meta: BrewDiscoverMeta = new BrewDiscoverMeta();
      meta.windowStart = one.windowStart;
      meta.windowEnd = one.windowEnd;
      meta.totalItems = one.totalItems;
      meta.totalCount = one.totalCount;
      meta.rawTokens = one.rawTokens;
      meta.families = one.families;
      meta.candidates = one.candidates;
      page.meta[kind] = meta;
      if (kind === BrewKind.FORMULA && one.windowEnd.length > 0) {
        page.snapshotDate = one.windowEnd;
      }
    });
    Logger.info(TAG, `table members applied, ${resolved} entries on screen, window=${page.snapshotDate}`);
  }

  /**
   * 大图卡。**必须在成员取齐之后选**，因为卡上展示的 `name` / `desc` 刚填进来。
   *
   * 选取规则与 `docs/brew-discover-algo.md` 的 FEATURED_RULE 逐字对应；
   * 顺序也不能改：它按 kind 外层展开，页面上大图卡与榜卡的混排顺序由它与
   * `boards` 的顺序共同决定。
   */
  private static buildFeatured(page: BrewDiscoverPageData): BrewDiscoverFeatured[] {
    const featured: BrewDiscoverFeatured[] = [];
    BrewDiscoverModel.FEATURED_RULE.forEach((rule: FeaturedRule) => {
      const board: BrewDiscoverBoard | undefined =
        page.boards.find((one: BrewDiscoverBoard) => one.kind === rule.kind && one.boardKey === rule.boardKey);
      const entries: BrewDiscoverEntry[] = board?.entries ?? [];
      entries.slice(0, rule.count).forEach((entry: BrewDiscoverEntry, index: number) => {
        const card: BrewDiscoverFeatured = new BrewDiscoverFeatured();
        card.rank = index + 1;
        card.id = entry.id;
        card.token = entry.token;
        card.name = entry.name;
        card.desc = entry.desc;
        card.categoryKey = entry.categoryKey;
        card.installs30d = entry.installs30d;
        card.installs365d = entry.installs365d;
        card.priorMonthly = entry.priorMonthly;
        card.velocity = entry.velocity;
        card.score = entry.score;
        card.kind = rule.kind;
        card.boardKey = rule.boardKey;
        featured.push(card);
      });
    });
    return featured;
  }

  /** 大图卡规则（编辑口径，见 `docs/brew-discover-algo.md` FEATURED_RULE） */
  private static readonly FEATURED_RULE: FeaturedRule[] = [
    { kind: BrewKind.FORMULA, boardKey: BrewDiscoverBoardKey.TRENDING, count: 2 },
    { kind: BrewKind.FORMULA, boardKey: BrewDiscoverBoardKey.FRESH, count: 1 },
    { kind: BrewKind.CASK, boardKey: BrewDiscoverBoardKey.TRENDING, count: 1 },
    { kind: BrewKind.CASK, boardKey: BrewDiscoverBoardKey.FRESH, count: 1 },
  ];

  /**
   * 大图卡的显示名。
   *
   * formula 的 `name` 恒等于 token（上游 formula 数组就是用 `name` 当标识的），
   * 所以表里的 `name = token` 已经正确；cask 的 `name` 是显示名数组，只存在于单条端点里。
   * 规则里 cask 只占 2 条 —— **最多发 2 个请求**，原先是 60 个。
   *
   * 取不到就保留 token 当显示名（`applyCatalogMembers` 已填），不报错。
   */
  private static fillFeaturedNames(page: BrewDiscoverPageData): Promise<BrewDiscoverPageData> {
    page.featured = BrewDiscoverModel.buildFeatured(page);
    const tokens: string[] = [];
    page.featured.forEach((card: BrewDiscoverFeatured) => {
      if (card.kind === BrewKind.CASK) {
        tokens.push(card.token);
      }
    });
    if (tokens.length === 0) {
      return Promise.resolve(page);
    }
    return Promise.all(tokens.map((token: string) => BrewService.fetchCaskDoc(token)
      .catch(() => undefined)))
      .then((docs: (LiveCaskDoc | undefined)[]) => {
        docs.forEach((doc: LiveCaskDoc | undefined, index: number) => {
          const names: string[] | undefined = doc?.name;
          if (doc === undefined || names === undefined || names.length === 0) {
            return;
          }
          page.featured.forEach((card: BrewDiscoverFeatured) => {
            if (card.token === tokens[index] && card.kind === BrewKind.CASK) {
              card.name = names[0];
            }
          });
        });
        Logger.info(TAG, `featured cask names filled, ${docs.filter((doc: LiveCaskDoc | undefined) =>
          doc !== undefined).length}/${tokens.length}`);
        return page;
      });
  }
}

/** FEATURED_RULE 的一项 */
interface FeaturedRule {
  kind: string;
  boardKey: string;
  count: number;
}

// ---------------------------------------------------------------- 搜索

/**
 * 一次搜索的结果。
 *
 * `hits` 与 `items` 是**等长同序的平行数组**（`items[i]` 就是 `hits[i]` 的行数据）：
 * UI 侧要 `kind`（在 hit 上）也要行数据（在 item 上），拆成两个类数组比拼成一个类更好读，
 * 但**不变量必须写死在这里** —— 任何改动都要保持两者同步，否则列表会串行。
 */
export class BrewSearchResult {
  /** 归一化后的关键字。UI 用它判断「这是不是我这次要的结果」（陈旧结果丢弃） */
  public keyword: string = '';
  /** 命中总数（**截断前**），用于「共 N 个结果」 */
  public total: number = 0;
  /** 描述片是否已就绪。false = 描述一律为空，只按包名匹配过 */
  public indexReady: boolean = true;
  /** 安装量片是否已就绪。false = 行是仅凭描述造出来的（`vol30d` 全为 0，排序信息不全） */
  public rowsFromIndexOnly: boolean = false;
  public hits: BrewSearchHit[] = [];
  public items: BrewPackageItem[] = [];
}

/**
 * 搜索。**同步计算，全程不发请求**。
 *
 * 三条口径：
 *   1. 匹配数据就是浏览集（`BrewTable.rows`），已经在内存里，匹配是毫秒级纯函数计算；
 *   2. **安装量片未到时仍然可搜**：浏览集退化成描述片的全部键（`vol30d` 恒为 0），
 * *     这正是「有描述没安装量」时最该能用的场景；
 *   3. 不做结果缓存：数据本身已在内存，缓存只会引入「数据变了但结果不变」。
 */
export class BrewSearchModel {
  private static instance: BrewSearchModel | undefined = undefined;

  private constructor() {
  }

  public static getInstance(): BrewSearchModel {
    if (BrewSearchModel.instance === undefined) {
      BrewSearchModel.instance = new BrewSearchModel();
    }
    return BrewSearchModel.instance;
  }

  public search(keyword: string): Promise<BrewSearchResult> {
    const started: number = Date.now();
    const k: string = BrewSearchEngine.normalize(keyword);
    const result: BrewSearchResult = new BrewSearchResult();
    result.keyword = k;
    if (k.length === 0) {
      return Promise.resolve(result);
    }
    result.indexReady = BrewTable.descReady();
    result.rowsFromIndexOnly = !BrewTable.volReady();
    const entries: BrewSearchEntry[] = [];
    let order: number = 0;
    [BrewKindText.FORMULA, BrewKindText.CASK].forEach((kind: string) => {
      BrewTable.rows(kind).forEach((row: CatalogEntry) => {
        entries.push(BrewSearchModel.entryOf(kind, row.token, BrewTable.descOf(kind, row.token),
          row.vol30d, order++));
      });
      if (BrewTable.rows(kind).length === 0 && result.indexReady) {
        // 安装量片未到：浏览集为空，用描述片的键当行（vol30d = 0）。
        // 两片都没到时这里也是空 —— 结果为空，UI 有「未就绪」提示条兜着，不报错。
        const desc: Record<string, string> = BrewTable.current().desc[kind] ?? {};
        Object.keys(desc).forEach((token: string) => {
          entries.push(BrewSearchModel.entryOf(kind, token, desc[token], 0, order++));
        });
      }
    });
    const all: BrewSearchHit[] = BrewSearchEngine.rank(k, entries, 0);
    result.total = all.length;
    const limited: BrewSearchHit[] = all.length > BREW_SEARCH_LIMIT ? all.slice(0, BREW_SEARCH_LIMIT) : all;
    result.hits = limited;
    limited.forEach((hit: BrewSearchHit) => result.items.push(BrewSearchModel.itemOf(hit)));
    Logger.info(SEARCH_TAG, `search "${k}" → ${result.total} hits, ${result.hits.length} items, ` +
      `descReady=${result.indexReady}, volReady=${!result.rowsFromIndexOnly}, ` +
      `${Date.now() - started}ms | top: ${BrewSearchModel.topLine(result.hits)}`);
    return Promise.resolve(result);
  }

  /**
   * 「搜索发现」的成员来源：formula 与 cask 的真实浏览集合并后，按近 30 天安装量降序取前 `limit` 个。
   *
   * 三条口径：
   *   1. **同步、零请求**：表已在内存，发现区不需要 loading 态；也**不该**为它去拉网络 ——
   *      聚合端点探针实测十几秒，而发现区是搜索页的默认内容；
   *   2. **定序必须确定**：`CatalogEntry` 上没有 kind，若用 `sort` 合并，同量条目的先后就取决于
   *      sort 的稳定性（引擎那边明令禁止依赖它）。所以手写双指针归并：同量时 formula 优先；
   *   3. 池为空就返回空数组（首次安装 / 断网且盘上没表）：UI 显示空态，**不回落任何写死的词**。
   */
  public hotTokens(limit: number): string[] {
    const formulae: CatalogEntry[] = BrewTable.rows(BrewKindText.FORMULA);
    const casks: CatalogEntry[] = BrewTable.rows(BrewKindText.CASK);
    const out: string[] = [];
    // 同名 token 在 formula 与 cask 里都可能存在：池子里只留一条。
    // 不去重的话发现区可能在同一屏里摆出两个一样的词，而 `ForEach` 的 key 就是词 → 重复 key 是运行期问题。
    const seen: Set<string> = new Set<string>();
    let i: number = 0;
    let j: number = 0;
    while (out.length < limit && (i < formulae.length || j < casks.length)) {
      const takeFormula: boolean = j >= casks.length ||
        (i < formulae.length && formulae[i].vol30d >= casks[j].vol30d);
      const token: string = takeFormula ? formulae[i].token : casks[j].token;
      if (takeFormula) {
        i++;
      } else {
        j++;
      }
      if (seen.has(token)) {
        continue;
      }
      seen.add(token);
      out.push(token);
    }
    Logger.info(SEARCH_TAG, `hot tokens (discovery pool): ${out.length} of ` +
      `formula=${formulae.length} cask=${casks.length} | top: ${out.slice(0, 5).join(' ')}`);
    return out;
  }

  /** 命中行 → 列表行。只补 `token` / `vol30d` 两个字段 */
  private static itemOf(hit: BrewSearchHit): BrewPackageItem {
    const row: CatalogEntry = {
      token: hit.token,
      vol30d: hit.vol30d,
      vol365d: 0,
      prior: 0,
      velocity: 0,
      score: 0,
    };
    const categoryKey: string = BrewTaxonomy.categoryOf(hit.kind, hit.token, hit.desc);
    return hit.kind === BrewKindText.CASK
      ? BrewBrowseBuilder.caskItem(row, hit.desc, categoryKey)
      : BrewBrowseBuilder.formulaItem(row, hit.desc, categoryKey);
  }

  private static entryOf(kind: string, token: string, desc: string, vol30d: number,
    order: number): BrewSearchEntry {
    const entry: BrewSearchEntry = new BrewSearchEntry();
    entry.kind = kind;
    entry.token = token;
    entry.desc = desc;
    entry.vol30d = vol30d;
    entry.order = order;
    return entry;
  }

  /** 日志判据行：Top5 的 `token(分数/方式)` */
  private static topLine(hits: BrewSearchHit[]): string {
    return hits.slice(0, 5)
      .map((hit: BrewSearchHit) => `${hit.kind === BrewKindText.CASK ? 'cask:' : ''}${hit.token}` +
        `(${hit.score}/${hit.matchedBy})`)
      .join(' ');
  }
}

/** 分类卡内的条目数一行（判据日志用） */
class BrewBrowseCount {
  public static entries(cards: BrewCategoryCard[]): string {
    return cards.map((card: BrewCategoryCard) => `${card.categoryKey}=${card.formulaContents.length}`).join(' ');
  }

  public static total(cards: BrewCategoryCard[]): number {
    let sum: number = 0;
    cards.forEach((card: BrewCategoryCard) => {
      sum += card.formulaContents.length;
    });
    return sum;
  }
}

/** cask 的三层结构（分类 → 卡 → 条目）规模计数（判据日志用） */
class BrewCaskCount {
  public static cards(categories: BrewCaskCategory[]): number {
    let sum: number = 0;
    categories.forEach((category: BrewCaskCategory) => {
      sum += (category.caskCards ?? []).length;
    });
    return sum;
  }

  public static entries(categories: BrewCaskCategory[]): number {
    let sum: number = 0;
    categories.forEach((category: BrewCaskCategory) => {
      (category.caskCards ?? []).forEach((card: BrewCaskCard) => {
        sum += (card.caskContents ?? []).length;
      });
    });
    return sum;
  }
}