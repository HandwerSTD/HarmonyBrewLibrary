/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { Logger } from '@ohos/common';
import { BrewTaxonomy } from '../constant/BrewTaxonomy';
import { BREW_CATEGORY_PREVIEW_COUNT, BREW_PERF_TRACE } from '../constant/BrewConstants';
import {
  BrewCaskCard,
  BrewCaskCategory,
  BrewCaskPageData,
  BrewCategoryCard,
  BrewFormulaPageData,
  BrewKind,
  BrewPackageItem,
  BrewPageData,
} from '../model/BrewModels';
import type { CatalogEntry } from './BrewTable';

/**
 * 把浏览集算成两个首页的结构（分类卡 / 分类，成员已排序已编号）。
 *
 * **纯计算，一次网络请求都不发**：成员来自包表（`BrewTable.rows`，即安装量片的键 ∩
 * 描述片的键），`desc` 来自同一张表的描述片。所以本文件现在只需要两个入参
 * （行 + 描述表），原先的 `docs`（逐条 hydrate 的现网单条）已经没有了。
 *
 * 调用点只有一处：`BrewTable` 建表时算一次并留在内存里，页面构页变成读引用。
 *
 * 与生成器 `generate.py` 的口径对应关系：
 *   - 成员：按 `vol30d` 降序取**目录全量**（生成器是人工策展清单，这里换成量）；
 *   - 分类：`tokens.json` 策展覆盖 → `lexicon.json` 关键词 → 兜底档（见 `BrewTaxonomy`）；
 *   - 版面：`styleType` 按 `STYLE_CYCLE` 轮转、`sequence` 递增、`hasMore = itemCount > 5`；
 *   - 名次：**分类内按 30d 安装量重排**，`categoryRank/categorySize` 在目录全量内计算。
 */

/** 版面节奏，与 `generate.py` 的 `STYLE_CYCLE` 一致 */
const STYLE_CYCLE: number[] = [1, 3, 2, 3, 1, 3, 2, 3];

/** [perf] 探针用的 TAG */
const TAG: string = '[BrewBrowseBuilder]';

/** 卡片风格常量（`BrewCaskCard` 只有一种卡） */
const CASK_CARD_STYLE: number = 1;

export class BrewBrowseBuilder {
  /**
   * token -> 稳定 id。**决定性的**：同一个 token 每次、每个入口（列表/榜单/详情）都得到同一个 id，
   * 否则详情页路由与 Preference 缓存会错位。
   *
   * 用 FNV-1a 32 位再抹掉符号位：空间 2^31，全量 1.3 万 token 的碰撞概率约 0.004%
   * （而且**碰撞也无害** —— 详情页按 token 查骨架，id 只当路由参数与缓存键）。
   */
  public static tokenId(token: string): number {
    let hash: number = 0x811c9dc5;
    for (let i = 0; i < token.length; i++) {
      hash = hash ^ token.charCodeAt(i);
      // FNV 质数 16777619；用 Math.imul 保持 32 位整数语义（ArkTS 的 number 是 double）
      hash = Math.imul(hash, 0x01000193);
    }
    return (hash >>> 0) % 2000000000 + 1;
  }

  /**
   * formula 首页：分类卡，卡内是该分类的条目。
   *
   * **不再接现网单条文档**：描述片（`brew_table` 的 `desc` 一半）里已经有 desc，
   * 而行组件只渲染四项（token / desc / 分类内名次 / 30 天安装量）——版本、许可、
   * 主页、kegOnly、deprecated 全仓库只有详情页读，而详情页本来就会重新取单条。
   * 所以浏览页构页现在是纯计算，一次网络请求都不发。
   */
  public static formulaPage(rows: CatalogEntry[], descIndex: Record<string, string>,
    categoryOrder: string[]): BrewCategoryCard[] {
    const t0: number = Date.now();
    const grouped: Map<string, BrewPackageItem[]> = new Map<string, BrewPackageItem[]>();
    rows.forEach((row: CatalogEntry) => {
      const desc: string = descIndex[row.token] ?? '';
      const categoryKey: string = BrewTaxonomy.categoryOf(BrewKind.FORMULA, row.token, desc);
      const item: BrewPackageItem = BrewBrowseBuilder.formulaItem(row, desc, categoryKey);
      const bucket: BrewPackageItem[] = grouped.get(categoryKey) ?? [];
      bucket.push(item);
      grouped.set(categoryKey, bucket);
    });
    const tGroup: number = Date.now();
    const cards: BrewCategoryCard[] = [];
    categoryOrder.forEach((categoryKey: string, index: number) => {
      const items: BrewPackageItem[] = grouped.get(categoryKey) ?? [];
      if (items.length === 0) {
        return;
      }
      BrewBrowseBuilder.rankWithin(items);
      const card: BrewCategoryCard = new BrewCategoryCard();
      card.id = index + 1;
      card.categoryKey = categoryKey;
      card.title = BrewBrowseBuilder.categoryEn(BrewKind.FORMULA, categoryKey);
      card.subTitle = `${items.length} packages`;
      card.styleType = STYLE_CYCLE[index % STYLE_CYCLE.length];
      card.sequence = index + 1;
      card.itemCount = items.length;
      card.hasMore = items.length > BREW_CATEGORY_PREVIEW_COUNT;
      card.formulaContents = items;
      cards.push(card);
    });
    if (BREW_PERF_TRACE) {
      Logger.info(TAG, `[perf] formulaPage rows=${rows.length} groupMs=${tGroup - t0} ` +
        `cardMs=${Date.now() - tGroup} cards=${cards.length}`);
    }
    return cards;
  }

  /** cask 首页：分类卡（与 formulaPage 同构，只是卡的数据多一层 `caskCards`） */
  public static caskPage(rows: CatalogEntry[], descIndex: Record<string, string>,
    categoryOrder: string[]): BrewCaskCategory[] {
    const t0: number = Date.now();
    const grouped: Map<string, BrewPackageItem[]> = new Map<string, BrewPackageItem[]>();
    rows.forEach((row: CatalogEntry) => {
      const desc: string = descIndex[row.token] ?? '';
      const categoryKey: string = BrewTaxonomy.categoryOf(BrewKind.CASK, row.token, desc);
      const item: BrewPackageItem = BrewBrowseBuilder.caskItem(row, desc, categoryKey);
      const bucket: BrewPackageItem[] = grouped.get(categoryKey) ?? [];
      bucket.push(item);
      grouped.set(categoryKey, bucket);
    });
    const tGroup: number = Date.now();
    const categories: BrewCaskCategory[] = [];
    categoryOrder.forEach((categoryKey: string, index: number) => {
      const items: BrewPackageItem[] = grouped.get(categoryKey) ?? [];
      if (items.length === 0) {
        return;
      }
      BrewBrowseBuilder.rankWithin(items);
      const card: BrewCaskCard = new BrewCaskCard();
      card.id = index + 1;
      card.unionId = index + 1;
      card.title = BrewBrowseBuilder.categoryEn(BrewKind.CASK, categoryKey);
      card.styleType = CASK_CARD_STYLE;
      card.sequence = 1;
      // 分类身份与包数复制到卡片上：首页按分类平铺渲染，卡片要自己取分类名/图标，
      // 表头的包数也必须是**总数**（卡内只预览前 N 条）。`hasMore` 与卡内截断共用
      // `BREW_CATEGORY_PREVIEW_COUNT`，与 formulaPage 完全同款。
      card.categoryKey = categoryKey;
      card.itemCount = items.length;
      card.hasMore = items.length > BREW_CATEGORY_PREVIEW_COUNT;
      card.caskContents = items;

      const category: BrewCaskCategory = new BrewCaskCategory();
      category.id = index + 1;
      category.categoryKey = categoryKey;
      category.categoryName = BrewBrowseBuilder.categoryEn(BrewKind.CASK, categoryKey);
      category.sequence = index + 1;
      category.caskCards = [card];
      categories.push(category);
    });
    if (BREW_PERF_TRACE) {
      Logger.info(TAG, `[perf] caskPage rows=${rows.length} groupMs=${tGroup - t0} ` +
        `cardMs=${Date.now() - tGroup} categories=${categories.length}`);
    }
    return categories;
  }

  /**
   * 空页。表里没有任何成员时用它（只可能在两片都还没到的进程初期出现）。
   */
  public static emptyFormulaPage(pageSize: number): BrewPageData<BrewFormulaPageData> {
    const data: BrewFormulaPageData = new BrewFormulaPageData();
    data.cardData = [];
    return BrewBrowseBuilder.page(0, pageSize, data);
  }

  /** 同 emptyFormulaPage */
  public static emptyCaskPage(pageSize: number): BrewPageData<BrewCaskPageData> {
    const data: BrewCaskPageData = new BrewCaskPageData();
    data.caskCategories = [];
    return BrewBrowseBuilder.page(0, pageSize, data);
  }

  /** 页信封：`totalSize` 给卡片数（"加载更多"判据是卡片数），单页返回 */
  public static page<T>(totalSize: number, pageSize: number, data: T): BrewPageData<T> {
    const page: BrewPageData<T> = {
      currentPage: 1,
      pageSize: pageSize,
      totalPage: 1,
      totalSize: totalSize,
      data: data,
    };
    return page;
  }

  /** 分类内按 30d 安装量重排并编号（1 起算） */
  private static rankWithin(items: BrewPackageItem[]): void {
    items.sort((a: BrewPackageItem, b: BrewPackageItem) => b.installs30d - a.installs30d);
    items.forEach((item: BrewPackageItem, index: number) => {
      item.categoryRank = index + 1;
      item.categorySize = items.length;
      item.sequence = index + 1;
    });
  }

  /**
   * 行数据的唯一构造口径（分类首页与搜索结果都用它，避免两处各写一遍导致漂移）。
   *
   * **只填四项**：token、desc（`title` 槽位）、分类、30 天安装量 —— 就是行组件渲染的四项。
   * 版本、许可、主页、kegOnly、deprecated 这些**浏览页一个都不显示**，
   * 全仓库只有详情页读，而详情页本来就会重新取单条。
   */
  public static formulaItem(row: CatalogEntry, desc: string, categoryKey: string): BrewPackageItem {
    const item: BrewPackageItem = new BrewPackageItem();
    item.id = BrewBrowseBuilder.tokenId(row.token);
    item.token = row.token;
    // 展示槽位：primary=token、secondary=英文 desc
    item.subTitle = row.token;
    item.title = desc;
    item.categoryKey = categoryKey;
    item.installs30d = row.vol30d;
    return item;
  }

  /** 同 `formulaItem` */
  public static caskItem(row: CatalogEntry, desc: string, categoryKey: string): BrewPackageItem {
    const item: BrewPackageItem = new BrewPackageItem();
    item.id = BrewBrowseBuilder.tokenId(row.token);
    item.token = row.token;
    item.subTitle = row.token;
    item.title = desc;
    item.categoryKey = categoryKey;
    item.installs30d = row.vol30d;
    return item;
  }

  /**
   * 分类英文名（卡片的第二行）。中文名由 UI 侧按 key 自己查
   * （`FORMULA_CATEGORY_NAME` / `CASK_CATEGORY_NAME`），所以这里只维护英文。
   */
  public static categoryEn(kind: string, categoryKey: string): string {
    return CATEGORY_EN.get(`${kind}:${categoryKey}`) ?? categoryKey;
  }
}

/** 分类英文名，键位与 `mockgen/categories.json` 的 `en` 字段一一对应 */
const CATEGORY_EN: Map<string, string> = buildCategoryEn();

function buildCategoryEn(): Map<string, string> {
  const names: Map<string, string> = new Map<string, string>();
  names.set('formula:terminal', 'Terminal & Shell');
  names.set('formula:devtools', 'Developer Toolchain');
  names.set('formula:network', 'Network & Transfer');
  names.set('formula:data', 'Data & Databases');
  names.set('formula:cloudnative', 'Container & Cloud Native');
  names.set('formula:media', 'Media & Image');
  names.set('formula:ai', 'AI & Machine Learning');
  names.set('formula:lib', 'Libraries & Frameworks');
  names.set('formula:system', 'System & Operations');
  names.set('cask:devide', 'Development & IDE');
  names.set('cask:browser', 'Browser');
  names.set('cask:productivity', 'Productivity & Notes');
  names.set('cask:comm', 'Communication');
  names.set('cask:design', 'Design & Creative');
  names.set('cask:av', 'Audio & Video');
  names.set('cask:systemtool', 'System Utilities');
  names.set('cask:aivm', 'AI · VM & Container');
  return names;
}
