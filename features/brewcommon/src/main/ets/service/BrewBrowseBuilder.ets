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
import type { LiveCaskDoc, LiveFormulaDoc } from './BrewApiMapper';
import type { CatalogEntry } from './BrewService';

/**
 * 用**目录 + 现网单条**在设备端拼出两个首页的数据（形状与内置快照完全一致，UI 零改动）。
 *
 * 为什么不再读 `brew-{formula,cask}-page.json`：那两个文件就是"分类 + 成员"的一次冻结快照，
 * 而分类是自建词表算出来的（官方 API 无分类字段）、成员只需要安装量排序 —— 两样东西设备端
 * 现在都有（目录给了全量安装量、`BrewTaxonomy` 给了词表），没有理由继续冻结在那 240 个包上。
 *
 * 与生成器 `generate.py` 的口径对应关系：
 *   - 成员：按 `vol30d` 降序取**目录全量**（生成器是人工策展清单，这里换成量）；
 *   - 分类：`tokens.json` 策展覆盖 → `lexicon.json` 关键词 → 兜底档（见 `BrewTaxonomy`）；
 *   - 版面：`styleType` 按 `STYLE_CYCLE` 轮转、`sequence` 递增、`hasMore = itemCount > 5`；
 *   - 名次：**分类内按 30d 安装量重排**，`categoryRank/categorySize` 在目录全量内计算。
 *
 * `desc` 有两个来源，`descIndex`（元数据索引，后台同步 `formula.json`/`cask.json` 的产物）优先，
 * `docs`（逐条 hydrate 到的现网单条）补位 —— 索引就绪时一个单条请求都不用发。
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

  /** formula 首页：8 张分类卡，卡内是该分类的条目 */
  public static formulaPage(rows: CatalogEntry[], docs: Record<string, LiveFormulaDoc>,
    descIndex: Record<string, string>, categoryOrder: string[], pageSize: number):
    BrewPageData<BrewFormulaPageData> {
    // [perf] 把「逐条分类 + 建 item」与「分组/排序/建卡」分开计时：
    // 首页只渲染 8 卡 × 5 条预览，但这里给**全量 rows** 都建了 item 并塞进 card.formulaContents。
    const t0: number = Date.now();
    const grouped: Map<string, BrewPackageItem[]> = new Map<string, BrewPackageItem[]>();
    rows.forEach((row: CatalogEntry) => {
      const doc: LiveFormulaDoc | undefined = docs[row.token];
      const desc: string = BrewBrowseBuilder.descOf(row.token, descIndex, doc?.desc);
      const categoryKey: string = BrewTaxonomy.categoryOf(BrewKind.FORMULA, row.token, desc);
      const item: BrewPackageItem = BrewBrowseBuilder.formulaItem(row, doc, desc, categoryKey);
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
    const data: BrewFormulaPageData = new BrewFormulaPageData();
    data.cardData = cards;
    if (BREW_PERF_TRACE) {
      Logger.info(TAG, `[perf] formulaPage rows=${rows.length} groupMs=${tGroup - t0} ` +
        `cardMs=${Date.now() - tGroup} cards=${cards.length}`);
    }
    return BrewBrowseBuilder.page(cards.length, pageSize, data);
  }

  /** cask 首页：8 张分类卡（与 formulaPage 同构，只是卡的数据多一层 `caskCards`） */
  public static caskPage(rows: CatalogEntry[], docs: Record<string, LiveCaskDoc>,
    descIndex: Record<string, string>, categoryOrder: string[], categoryNames: string[],
    pageSize: number): BrewPageData<BrewCaskPageData> {
    // [perf] 同 formulaPage：分类+建 item 与建卡分开计时
    const t0: number = Date.now();
    const grouped: Map<string, BrewPackageItem[]> = new Map<string, BrewPackageItem[]>();
    rows.forEach((row: CatalogEntry) => {
      const doc: LiveCaskDoc | undefined = docs[row.token];
      const desc: string = BrewBrowseBuilder.descOf(row.token, descIndex, doc?.desc);
      const categoryKey: string = BrewTaxonomy.categoryOf(BrewKind.CASK, row.token, desc);
      const item: BrewPackageItem = BrewBrowseBuilder.caskItem(row, doc, desc, categoryKey);
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
      category.categoryName = categoryNames[index] ?? card.title;
      category.sequence = index + 1;
      category.caskCards = [card];
      categories.push(category);
    });
    const data: BrewCaskPageData = new BrewCaskPageData();
    data.caskCategories = categories;
    if (BREW_PERF_TRACE) {
      Logger.info(TAG, `[perf] caskPage rows=${rows.length} groupMs=${tGroup - t0} ` +
        `cardMs=${Date.now() - tGroup} categories=${categories.length}`);
    }
    return BrewBrowseBuilder.page(categories.length, pageSize, data);
  }

  /**
   * 空页（目录拿不到时用）。
   *
   * 内置的 `brew-{formula,cask}-page.json` 已经删除（C 档），所以"无目录"确实无内容可渲染 ——
   * 这时返回空列表让 UI 走它自己的空态，比抛错让页面变成失败态更合适：
   * 断网时"什么都没加载出来"是事实，不是错误。
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

  /** 页信封：`totalSize` 给卡片数（Formulae 的"加载更多"判据是卡片数 × pageSize），单页返回 */
  private static page<T>(totalSize: number, pageSize: number, data: T): BrewPageData<T> {
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
   * `desc` 的唯一取数口径：**元数据索引优先、逐条 doc 补位**。
   *
   * 为什么把优先级写在这里而不是各个调用点：`desc` 同时是**分类输入**和**列表主文案**
   * （`item.title`），两处必须永远取到同一个值 —— 分开写就会出现"分类按索引、文案按 doc"
   * 这类不一致（看起来正常，但行与分类对不上）。
   *
   * 调用方用**它的长度**当"能不能上屏"的判据（空串 = 没东西可展示）：
   * `"desc": null`（cask 有 2,645 条）与空串都会落到 `''`，那种行不应上屏。
   */
  public static descOf(token: string, descIndex: Record<string, string>, docDesc?: string): string {
    return descIndex[token] ?? docDesc ?? '';
  }

  /**
   * 行数据的唯一构造口径（分类首页与搜索结果都用它，避免两处各写一遍导致漂移）。
   * `doc` 允许 `undefined`：搜索结果不拉现网单条，而下面每个字段都是 `doc?.x ?? ''`，
   * 缺省时拿到空串而不是崩 —— 列表行只展示 `token` / `desc` / `installs30d`。
   */
  public static formulaItem(row: CatalogEntry, doc: LiveFormulaDoc | undefined, desc: string,
    categoryKey: string): BrewPackageItem {
    const item: BrewPackageItem = new BrewPackageItem();
    item.id = BrewBrowseBuilder.tokenId(row.token);
    item.token = row.token;
    // 展示槽位：primary=token、secondary=英文 desc（与内置快照的槽位语义一致）
    item.subTitle = row.token;
    item.title = desc;
    item.categoryKey = categoryKey;
    item.stableVersion = doc?.versions?.stable ?? '';
    item.license = doc?.license ?? '';
    item.homepage = doc?.homepage ?? '';
    item.installs30d = row.vol30d;
    item.kegOnly = doc?.keg_only ?? false;
    item.deprecated = doc?.deprecated ?? false;
    item.disabled = doc?.disabled ?? false;
    return item;
  }

  /** 同 `formulaItem`：`doc` 允许缺省，搜索结果不拉单条 */
  public static caskItem(row: CatalogEntry, doc: LiveCaskDoc | undefined, desc: string,
    categoryKey: string): BrewPackageItem {
    const item: BrewPackageItem = new BrewPackageItem();
    item.id = BrewBrowseBuilder.tokenId(row.token);
    item.token = row.token;
    item.subTitle = row.token;
    item.title = desc;
    item.categoryKey = categoryKey;
    item.stableVersion = doc?.version ?? '';
    item.homepage = doc?.homepage ?? '';
    item.installs30d = row.vol30d;
    item.autoUpdates = doc?.auto_updates ?? false;
    item.deprecated = doc?.deprecated ?? false;
    item.disabled = doc?.disabled ?? false;
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
