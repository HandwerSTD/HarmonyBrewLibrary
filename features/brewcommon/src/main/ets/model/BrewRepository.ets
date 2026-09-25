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

import { ImageKnifeUtil, Logger } from '@ohos/common';
import { BrewLoadLog } from '../util/BrewLoadLog';
import { BrewNetNotice } from '../util/BrewNetNotice';
import { BrewService } from '../service/BrewService';
import type { BrewCatalog, CatalogEntry, CatalogKindMeta } from '../service/BrewService';
import { BrewKindText } from '../service/BrewService';
import { BrewBrowseBuilder } from '../service/BrewBrowseBuilder';
import { BrewMetaSync } from '../service/BrewMetaSync';
import { BrewTaxonomy } from '../constant/BrewTaxonomy';
import { BrewApiMapper } from '../service/BrewApiMapper';
import type { LiveCaskDoc, LiveFormulaDoc } from '../service/BrewApiMapper';
import { BREW_CATALOG_MEMBERSHIP, BREW_CATALOG_TOP_N, BREW_DATA_MODE, BREW_SEARCH_LIMIT, BrewDataMode } from '../constant/BrewConstants';
import type {
  BrewCaskCard,
  BrewCaskCategory,
  BrewCaskDetail,
  BrewCaskPageData,
  BrewCategoryCard,
  BrewDiscoverBoard,
  BrewDiscoverPageData,
  BrewFormulaDetail,
  BrewFormulaPageData,
  BrewInstalledPackage,
  BrewPageData,
  BrewPackageItem,
} from './BrewModels';
// 这两个是**类**（要 new），必须值导入，不能 import type
import { BrewDiscoverBoardKey, BrewDiscoverEntry, BrewDiscoverFeatured, BrewDiscoverMeta, BrewKind } from './BrewModels';
import type { LiveAnalytics } from '../service/BrewApiMapper';
import { BrewSearchEngine, BrewSearchEntry, BrewSearchHit } from './BrewSearchEngine';

const TAG: string = '[BrewRepository]';

/**
 * 搜索的日志标签**故意与 `TAG` 分开**：搜索的验收判据是 `devecocli log --keyword BrewSearch`，
 * 若沿用 `[BrewRepository]`，那行日志会被过滤掉，读起来像「搜索根本没跑」。
 */
const SEARCH_TAG: string = '[BrewSearch]';

/** 取「同分类其他包」时一次拉全量分类，该值只需大到一个页面能装下全部分类 */
const SIBLING_PAGE_SIZE: number = 100;

/**
 * Repository 层。
 *
 * **数据分两层，职责不同：**
 *   - **骨架**（分类 / 成员 / 卡片版面 / 图标 / id）：内置 rawfile 快照。官方 API 没有分类字段，
 *     这部分不能联网；读 rawfile 也比读 Preference 快，所以**不做页面级缓存**；
 *   - **包自身属性**（版本 / 描述 / 依赖 / 安装量 / 生命周期）：现网请求，
 *     由 `BrewService` 带 TTL 缓存（键 = token）。
 *
 * 现网值的填充（hydrate）发生在**本层返回之前**，所以 VM 与 UI 完全不知道数据来自哪里 ——
 * 这正是 docs/brew-api-design.md §7 当初留的改动面：对外签名与返回类型不变。
 *
 * 单例 + getInstance()，与 ComponentListModel / ComponentDetailModel 一致。
 */

export class BrewFormulaModel {
  private static instance: BrewFormulaModel;
  private service: BrewService = new BrewService();

  private constructor() {
  }

  public static getInstance(): BrewFormulaModel {
    if (!BrewFormulaModel.instance) {
      BrewFormulaModel.instance = new BrewFormulaModel();
    }
    return BrewFormulaModel.instance;
  }

  /**
   * 分类卡首页。
   *
   * **不再吃 Preference 页面缓存**：骨架（分类 / 成员 / 图标 / 版面）来自内置 rawfile，
   * 读它比读 Preference 还快，没有缓存的必要；而真正需要缓存的是**现网字段**，
   * 那部分由 `BrewService` 的单条 TTL 缓存负责（键 = token）。
   * 这样也避开了“缓存了整页 → 现网值永远进不来”这类毛病（榜单页吃过这个亏，见 BrewDiscoverModel 注释）。
   */
  public getFormulaPage(currentPage: number, pageSize: number): Promise<BrewPageData<BrewFormulaPageData>> {
    return this.service.buildFormulaPage(currentPage, pageSize)
      .then((built: BrewPageData<BrewFormulaPageData> | undefined) => {
        if (built !== undefined) {
          // 设备端拼页时已经拉过一遍现网单条（分类必须看 desc），所以这里不再 hydrate 第二遍
          return built;
        }
        // 拿不到目录（无网 / SNAPSHOT 模式）→ 空页。内置 page 快照已删除（C 档），
        // 所以这里没有回落对象：让 UI 走它自己的空态，而不是抛错变成失败态。
        Logger.info(TAG, 'formula browse empty (catalog unavailable)');
        return BrewBrowseBuilder.emptyFormulaPage(pageSize);
      });
  }

  /**
   * 包详情。
   *
   * 顺序（C 档后**不再读任何"详情快照"**）：
   *   1. 现网单条 `/api/formula/<token>.json` —— 描述/版本/依赖/bottle/artifacts/热度全在这里；
   *   2. 本地才有的三样由设备端算：`id`（token 的稳定哈希，只当路由参数与缓存键）、
   *      `categoryKey`（`BrewTaxonomy`：策展覆盖 → 关键词 → 兜底）、名次（浏览集内，见 alignCategoryRank）；
   *   3. 现网失败 → 上一次成功合并的整页缓存 → 只剩骨架的 base（降级但不报错）。
   *
   * 为什么降级也不报错：详情页的失败态应该只留给"这个 token 根本不存在"，
   * 而不是"网不好的时候打不开已缓存内容"。
   */
  public getFormulaDetail(componentId: number, token: string): Promise<BrewFormulaDetail> {
    const id: number = componentId > 0 ? componentId : BrewBrowseBuilder.tokenId(token);
    if (BREW_DATA_MODE !== BrewDataMode.REMOTE || token.length === 0) {
      return Promise.resolve(this.degradedFormula(token, id));
    }
    return this.service.getLiveFormulaDoc(token)
      .then((doc: LiveFormulaDoc) => {
        const categoryKey: string = BrewTaxonomy.categoryOf(BrewKindText.FORMULA, token, doc.desc ?? '');
        const base: BrewFormulaDetail = BrewApiMapper.formulaBase(token, id, categoryKey,
          this.service.catalogInstallsOf(BrewKindText.FORMULA, token));
        const merged: BrewFormulaDetail = BrewApiMapper.mergeFormula(base, doc);
        return this.alignCategoryRank(merged);
      })
      .then((merged: BrewFormulaDetail) => {
        this.service.setFormulaDetailToPreference(componentId, merged);
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
      this.service.catalogInstallsOf(BrewKindText.FORMULA, token));
  }

  /** 现网失败时的回落：优先用上一次成功合并的整页缓存，没有就用骨架 */
  private cachedFormulaDetail(componentId: number,
    base: BrewFormulaDetail): Promise<BrewFormulaDetail> {
    return this.service.getFormulaDetailByPreference(componentId)
      .then((cached: BrewFormulaDetail) => cached ?? base)
      .catch((): BrewFormulaDetail => base) as Promise<BrewFormulaDetail>;
  }

  /**
   * 用同分类的**现网**名次校正详情页上的 `categoryRank / categorySize`。
   *
   * 为什么必须校正：详情页同时展示「近 30 天安装量」与「分类内第 N 名」，
   * 安装量已经是现网值、名次若仍是快照值，两者就会对不上 ——
   * 而列表页的名次是同一次 hydrate 后重算的，详情页跟着它才一致。
   *
   * 失败时保留快照名次（不报错）：名次是展示值，不值得把详情页变成错误态。
   */
  private alignCategoryRank(detail: BrewFormulaDetail): Promise<BrewFormulaDetail> {
    return this.getFormulaPage(1, SIBLING_PAGE_SIZE)
      .then((page: BrewPageData<BrewFormulaPageData>) => {
        const card: BrewCategoryCard | undefined =
          page.data.cardData?.find((one: BrewCategoryCard) => one.categoryKey === detail.categoryKey);
        const item: BrewPackageItem | undefined =
          (card?.formulaContents ?? []).find((one: BrewPackageItem) => one.token === detail.token);
        if (item !== undefined) {
          detail.categoryRank = item.categoryRank;
          detail.categorySize = item.categorySize;
        }
        return detail;
      })
      .catch((): BrewFormulaDetail => detail);
  }

  /** 首页预热：把分类卡里的图标提前下好，减少滚动时的白块。 */
  public preload(page: BrewPageData<BrewFormulaPageData>): Promise<void> {
    return new Promise((resolve: () => void) => {
      page.data.cardData?.forEach((card) => {
        card.formulaContents?.forEach((item) => {
          if (item.mediaUrl) {
            ImageKnifeUtil.preloadImg(item.mediaUrl);
          }
        });
      });
      resolve();
    });
  }

  /**
   * 全部分类卡（每张卡含该分类的**完整**成员，成员与名次都已算好）。
   *
   * 分类「查看全部」二级页要的不是“一个分类”，而是“全部分类 + 当前选中哪个”
   * （它版式同 Casks 一级页：chips 切换 + 当前分类的卡），所以直接给整页的 cardData。
   * 详情页的「同分类其他包」也建立在它上面。
   *
   * 不新增端点：成员本来就是设备端用「目录 + 词表」现算的（见 `BrewBrowseBuilder`），
   * 再取一次首页就是命中目录缓存。任何失败都返回空数组：页签页面自己去区分空态/失败态，
   * 而不是把异常跨模块抛到 UI 层（目录拿不到时 `buildFormulaPage` 本来也是给空页）。
   */
  public getFormulaCategories(): Promise<BrewCategoryCard[]> {
    return this.getFormulaPage(1, SIBLING_PAGE_SIZE)
      .then((page: BrewPageData<BrewFormulaPageData>) => page.data.cardData ?? [])
      .catch((): BrewCategoryCard[] => {
        Logger.error(TAG, 'getFormulaCategories failed');
        return [];
      });
  }

  /** 某个分类的**全部成员**（分类卡的「查看全部」与详情页的「同分类其他包」共用） */
  public getCategoryPackages(categoryKey: string): Promise<BrewPackageItem[]> {
    return this.getFormulaCategories()
      .then((cards: BrewCategoryCard[]) => {
        const card: BrewCategoryCard | undefined =
          cards.find((one: BrewCategoryCard) => one.categoryKey === categoryKey);
        return card?.formulaContents ?? [];
      });
  }

  /**
   * 同分类的其他包，供详情页的「同分类其他包」使用。
   *
   * 详情接口本身不返回同类包（`recommendList` 实测为空），数据只在「目录 + 词表」现算的浏览页里，
   * 而浏览页已被页签加载过（走 `BrewService` 的单条 TTL 缓存），所以这里复用 `getFormulaPage`
   * 而不是新增端点。任何失败都返回空数组 —— 推荐位是锦上添花，不应该让整个详情页报错。
   */
  public getSameCategoryPackages(categoryKey: string, excludeToken: string,
    limit: number): Promise<BrewPackageItem[]> {
    return this.getCategoryPackages(categoryKey)
      .then((contents: BrewPackageItem[]) =>
        contents.filter((item: BrewPackageItem) => item.token !== excludeToken).slice(0, limit));
  }
}

export class BrewCaskModel {
  private static instance: BrewCaskModel;
  private service: BrewService = new BrewService();

  private constructor() {
  }

  public static getInstance(): BrewCaskModel {
    if (!BrewCaskModel.instance) {
      BrewCaskModel.instance = new BrewCaskModel();
    }
    return BrewCaskModel.instance;
  }

  public getCaskPage(currentPage: number, pageSize: number): Promise<BrewPageData<BrewCaskPageData>> {
    return this.service.buildCaskPage(currentPage, pageSize)
      .then((built: BrewPageData<BrewCaskPageData> | undefined) => {
        if (built !== undefined) {
          return built;
        }
        Logger.info(TAG, 'cask browse empty (catalog unavailable)');
        return BrewBrowseBuilder.emptyCaskPage(pageSize);
      });
  }

  /** 同 getFormulaDetail（cask 的现网单条口径是 `analytics.install`、版本字段是 `version`）。 */
  public getCaskDetail(componentId: number, token: string): Promise<BrewCaskDetail> {
    const id: number = componentId > 0 ? componentId : BrewBrowseBuilder.tokenId(token);
    if (BREW_DATA_MODE !== BrewDataMode.REMOTE || token.length === 0) {
      return Promise.resolve(this.degradedCask(token, id));
    }
    return this.service.getLiveCaskDoc(token)
      .then((doc: LiveCaskDoc) => {
        const categoryKey: string = BrewTaxonomy.categoryOf(BrewKindText.CASK, token, doc.desc ?? '');
        const base: BrewCaskDetail = BrewApiMapper.caskBase(token, id, categoryKey,
          this.service.catalogInstallsOf(BrewKindText.CASK, token));
        const merged: BrewCaskDetail = BrewApiMapper.mergeCask(base, doc);
        return this.alignCategoryRank(merged);
      })
      .then((merged: BrewCaskDetail) => {
        this.service.setCaskDetailToPreference(componentId, merged);
        Logger.info(TAG, `getCaskDetail live ok, token=${token}, v=${merged.version}`);
        return merged;
      })
      .catch((error: Error) => {
        Logger.error(TAG, `getCaskDetail live failed, fallback to cache/base. token=${token}, ${error.message}`);
        return this.cachedCaskDetail(componentId, this.degradedCask(token, id));
      });
  }

  /** 降级骨架：同 degradedFormula */
  private degradedCask(token: string, id: number): BrewCaskDetail {
    const categoryKey: string = BrewTaxonomy.categoryOf(BrewKindText.CASK, token, '');
    return BrewApiMapper.caskBase(token, id, categoryKey,
      this.service.catalogInstallsOf(BrewKindText.CASK, token));
  }

  /** 现网失败时的回落：优先用上一次成功合并的整页缓存，没有就用骨架 */
  private cachedCaskDetail(componentId: number, base: BrewCaskDetail): Promise<BrewCaskDetail> {
    return this.service.getCaskDetailByPreference(componentId)
      .then((cached: BrewCaskDetail) => cached ?? base)
      .catch((): BrewCaskDetail => base) as Promise<BrewCaskDetail>;
  }

  /** 把「分类 -> 卡 -> 条目」三层摊平成条目数组（cask 的数据形状比 formula 多一层） */
  private static contentsOf(category: BrewCaskCategory): BrewPackageItem[] {
    const items: BrewPackageItem[] = [];
    (category.caskCards ?? []).forEach((card: BrewCaskCard) => {
      (card.caskContents ?? []).forEach((item: BrewPackageItem) => items.push(item));
    });
    return items;
  }

  /** 同 BrewFormulaModel.alignCategoryRank。Casks 的名次是整个分类范围（跨卡）。 */
  private alignCategoryRank(detail: BrewCaskDetail): Promise<BrewCaskDetail> {
    return this.getCaskPage(1, SIBLING_PAGE_SIZE)
      .then((page: BrewPageData<BrewCaskPageData>) => {
        const category: BrewCaskCategory | undefined =
          page.data.caskCategories?.find((one: BrewCaskCategory) => one.categoryKey === detail.categoryKey);
        const item: BrewPackageItem | undefined = category === undefined ? undefined :
          BrewCaskModel.contentsOf(category).find((one: BrewPackageItem) => one.token === detail.token);
        if (item !== undefined) {
          detail.categoryRank = item.categoryRank;
          detail.categorySize = item.categorySize;
        }
        return detail;
      })
      .catch((): BrewCaskDetail => detail);
  }

  public preload(page: BrewPageData<BrewCaskPageData>): Promise<void> {
    return new Promise((resolve: () => void) => {
      page.data.caskCategories?.forEach((category) => {
        category.caskCards?.forEach((card) => {
          card.caskContents?.forEach((item) => {
            if (item.mediaUrl) {
              ImageKnifeUtil.preloadImg(item.mediaUrl);
            }
          });
        });
      });
      resolve();
    });
  }

  /**
   * 全部分类（每个分类自带它的卡片与**完整**成员）。
   *
   * 同 `BrewFormulaModel.getFormulaCategories`：不新增端点，复用已被页签加载过的整页
   * （命中目录缓存），异常吞成空数组由调用方判空态。
   */
  public getCaskCategories(): Promise<BrewCaskCategory[]> {
    return this.getCaskPage(1, SIBLING_PAGE_SIZE)
      .then((page: BrewPageData<BrewCaskPageData>) => page.data.caskCategories ?? [])
      .catch((): BrewCaskCategory[] => {
        Logger.error(TAG, 'getCaskCategories failed');
        return [];
      });
  }

  /**
   * 同分类的其他包，供详情页的「同分类其他包」使用。
   * Casks 的分类是三层结构（分类 -> 卡片 -> 条目），需要先把选中分类下的所有卡片拍平。
   * 任何失败都返回空数组，理由同 BrewFormulaModel.getSameCategoryPackages。
   */
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
}

/** 本机状态（Mine）。纯 Mock，未来接 brew 命令输出。 */
export class BrewLocalModel {
  private static instance: BrewLocalModel;
  private service: BrewService = new BrewService();

  private constructor() {
  }

  public static getInstance(): BrewLocalModel {
    if (!BrewLocalModel.instance) {
      BrewLocalModel.instance = new BrewLocalModel();
    }
    return BrewLocalModel.instance;
  }

  public getInstalledFormulae(): Promise<BrewInstalledPackage[]> {
    return this.service.getInstalledFormulae();
  }

  public getInstalledCasks(): Promise<BrewInstalledPackage[]> {
    return this.service.getInstalledCasks();
  }

  public getOutdated(): Promise<BrewInstalledPackage[]> {
    return this.service.getOutdated();
  }
}

/**
 * Discover 三张榜。
 *
 * 与其它 Model 一样：先吃 Preference 缓存，未命中再请求，成功后回写。
 * 榜单页与「查看全部」二级页共用同一份数据，第二次进二级页会直接命中缓存，
 * 所以二级页可以只收一个 boardId、自己去取整份数据（见 BrewDiscoverBoardParams）。
 */
export class BrewDiscoverModel {
  private static instance: BrewDiscoverModel;
  private service: BrewService = new BrewService();

  private constructor() {
  }

  public static getInstance(): BrewDiscoverModel {
    if (!BrewDiscoverModel.instance) {
      BrewDiscoverModel.instance = new BrewDiscoverModel();
    }
    return BrewDiscoverModel.instance;
  }

  /**
   * **刻意不吃 Preference 缓存**，与其它 Model 的做法相反 —— 这是有意的。
   *
   * 榜单是"算法在某个时间点的一次冻结快照"，页面的全部意义就是让人看到**当前**那一份。
   * 走缓存会造成一个很难查的故障：生成器更新了 `brew-discover-page.json`，
   * 但 App 一直返回上一次写进 Preference 的旧副本，新内容静默不生效 ——
   * 补「单 App 大图卡」时就真踩到了：字段已经产出、装机也成功，
   * 页面上却只有榜卡，看起来像"代码没生效"，其实是缓存在挡。
   *
   * 快照只有 ~21KB，读 rawfile 的成本可以忽略；
   * 接真实 API 时应改为**带 TTL 的缓存**（见 docs/brew-discover-algo.md §7 的刷新频率建议），
   * 而不是"永久缓存直到写失败"。
   */
  public getDiscoverPage(): Promise<BrewDiscoverPageData> {
    const tProbe0: number = Date.now();
    return this.service.getDiscoverPage().then((page: BrewDiscoverPageData) => {
      const tSnapshot: number = Date.now();
      BrewLoadLog.info('discover_snapshot', 'rawfile', tSnapshot - tProbe0,
        'boards=' + page.boards.length + ' featured=' + (page.featured?.length ?? 0) +
        ' snapshotDate=' + page.snapshotDate + '（内置回落快照，不走网络）');
      return this.service.getCatalog().then((catalog: BrewCatalog | undefined) => {
        const tCatalog: number = Date.now();
        BrewDiscoverModel.auditCatalogMembers(page, catalog);
        // 拿不到目录（或开关关闭）→ 继续用内置快照成员，页面不受影响
        const fromCatalog: boolean = catalog !== undefined && BREW_CATALOG_MEMBERSHIP;
        if (fromCatalog) {
          BrewDiscoverModel.applyCatalogMembers(page, catalog!);
        }
        BrewDiscoverModel.fillCategoryKeys(page);
        const tApply: number = Date.now();
        return this.hydratePage(page, fromCatalog).then((hydrated: BrewDiscoverPageData) => {
          BrewLoadLog.info('discover_page', 'assembled', Date.now() - tProbe0,
            'snapshotMs=' + (tSnapshot - tProbe0) + ' getCatalogMs=' + (tCatalog - tSnapshot) +
            ' membersApplyMs=' + (tApply - tCatalog) + ' hydrateMs=' + (Date.now() - tApply) +
            ' membersFromCatalog=' + fromCatalog + ' boards=' + hydrated.boards.length);
          // 数据已上屏 → 撤掉常驻提示（与 `getCatalog`/`hydrate*Docs` 里的 `willFetch` 成对）。
          // Discover 的等待是「目录探针（最长、实测 17.4s）+ live hydrate」两段，
          // 所以只在**整页组装完**时才 settle —— 在 `fetchCatalog` 那一步就撤会把第二段漏在外面。
          BrewNetNotice.settle('discover_page', 'boards=' + hydrated.boards.length +
            ' membersFromCatalog=' + fromCatalog);
          return hydrated;
        });
      });
    });
  }

  /**
   * 目录对账：把**设备端现算**的六张榜（聚合端点 -> 全量分布 -> 算法）与内置快照的成员逐榜对比，打一行差异。
   *
   * 为什么要留这一行：它是「成员能不能用现网」的判断依据 —— 榜是按**全球分布**算的，
   * 而能点进详情的包只有内置的 240 个（`id` 是样例工程的本地主键，官方 API 没有），
   * 所以关键数字是“前 N 名里有多少能落到内置详情”（`resolved`）。实测 10/10，
   * 且 `same=10/10`（六张榜里只有 cask/trending 差一个），所以切换是安全的。
   * 榜单成员以后若换成“全球前十”的语义，`resolved` 会下降 —— 那行日志会告警。
   */
  private static auditCatalogMembers(page: BrewDiscoverPageData, catalog: BrewCatalog | undefined): void {
    if (catalog === undefined) {
      Logger.info(TAG, 'catalog unavailable, discover members stay from snapshot');
      return;
    }
    const topN: number = page.topN > 0 ? page.topN : BREW_CATALOG_TOP_N;
    const diffs: string[] = [];
    page.boards.forEach((board: BrewDiscoverBoard) => {
      const liveTokens: string[] = BrewService.catalogRows(catalog, board.kind, board.boardKey)
        .slice(0, topN).map((row: CatalogEntry) => row.token);
      const snapshotTokens: string[] = board.entries.map((entry: BrewDiscoverEntry) => entry.token);
      const added: string[] = liveTokens.filter((token: string) => snapshotTokens.indexOf(token) < 0);
      const dropped: string[] = snapshotTokens.filter((token: string) => liveTokens.indexOf(token) < 0);
      diffs.push(`${board.kind}/${board.boardKey} live=${liveTokens.length} ` +
        `same=${liveTokens.length - added.length}/${snapshotTokens.length}` +
        (added.length > 0 ? ` +[${added.join(',')}]` : '') +
        (dropped.length > 0 ? ` -[${dropped.join(',')}]` : ''));
    });
    Logger.info(TAG, `catalog members vs snapshot: ${diffs.join(' | ')}`);
  }

  /**
   * 把榜成员换成设备端现算的结果。
   *
   * 四条规则：
   *   1. **不再按白名单过滤**（C 档的变化）：`id` 由 token 的稳定哈希给出，详情页也能
   *      只用现网单条渲染，所以"榜上的包点不进去"这个问题从根上消失了 ——
   *      榜现在就是**全球前 N**，不再是"内置 240 个里的前 N"；
   *   2. `name` / `desc` / `categoryKey` 先留空：可读名与描述都在现网单条里，由紧随其后的
   *      hydrate 覆盖。⚠ `categoryKey` 的留空**不代表它依赖 desc** —— 它由
   *      `fillCategoryKeys` 在 hydrate 之前就补好，理由见那里；
   *   3. `meta` 与 `snapshotDate` 一并换成**现网实测值**：页面下方那句“基于最近可用数据”
   *      的日期就来自它，成员来自现网而日期还写快照日会是自相矛盾的。
   */
  private static applyCatalogMembers(page: BrewDiscoverPageData, catalog: BrewCatalog): void {
    const topN: number = page.topN > 0 ? page.topN : BREW_CATALOG_TOP_N;
    let resolved: number = 0;
    page.boards.forEach((board: BrewDiscoverBoard) => {
      const entries: BrewDiscoverEntry[] = [];
      BrewService.catalogRows(catalog, board.kind, board.boardKey).forEach((row: CatalogEntry) => {
        if (entries.length >= topN) {
          return;
        }
        const entry: BrewDiscoverEntry = new BrewDiscoverEntry();
        entry.rank = entries.length + 1;
        entry.id = BrewBrowseBuilder.tokenId(row.token);
        entry.token = row.token;
        entry.name = row.token;
        entry.desc = '';
        entry.categoryKey = '';
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
    Object.keys(catalog.meta).forEach((kind: string) => {
      const one: CatalogKindMeta = catalog.meta[kind];
      const meta: BrewDiscoverMeta = new BrewDiscoverMeta();
      meta.windowStart = one.windowStart;
      meta.windowEnd = one.windowEnd;
      meta.totalItems = one.totalItems;
      meta.totalCount = one.totalCount;
      meta.rawTokens = one.rawTokens;
      meta.families = one.families;
      meta.candidates = one.candidates;
      page.meta[kind] = meta;
    });
    const formulaMeta: CatalogKindMeta | undefined = catalog.meta['formula'];
    if (formulaMeta !== undefined && formulaMeta.windowEnd.length > 0) {
      page.snapshotDate = formulaMeta.windowEnd;
    }
    Logger.info(TAG, `catalog members applied, ${resolved} entries on screen, ` +
      `window=${page.snapshotDate}`);
  }

  /**
   * 榜单的现网化。
   *
   * **成员与门槛来自快照，数字与顺序来自现网** —— 这是刻意的分工：
   *   - 成员（哪 10 个包上榜）由聚合端点在全球宇宙（formula 7,976 个 family）上算出，
   *     还要按分位标定阈值、按 family 去重（见 docs/brew-discover-algo.md §3/§4/§5）。
   *     客户端没有全球分布，重算不了 —— **重算会得到另一张榜**，不是“更准的同一张榜”；
   *   - 数字（30d / 365d / 增速 / 名次）只需要**这个包自己**的数据，单条详情接口里就有，
   *     所以能刷成现网值。
   *
   * 刷新后重新排序，否则会出现“第 1 名的安装量比第 3 名少”这种看得到的矛盾。
   * 各榜排序口径与 `check_algo.py` 一致（trending 按 score，alltime 按 365d，fresh 按 30d）。
   */
  /**
   * 补 `categoryKey`：**在 hydration 之前**跑，且只补空值。
   *
   * 为什么必须提前补：`categoryKey` 原先只在 hydration 的回填里赋值（`applyFormulaEntry` /
   * `applyCaskEntry`），而 hydration 有超时、会切掉排在最后的那张榜 —— 于是那批条目
   * `categoryKey` 一直是空串，大图卡拿不到分类图标。**这与「描述为空」是同一个根因**
   * （见 `BrewService.hydrateFormulaDocs` 的超时切尾）。
   *
   * 而 `categoryKey` 其实**不需要现网描述**：`BrewTaxonomy.categoryOf` 的第一层是策展覆盖，
   * 只看 `kind + token`，且策展表本来就是照着 Discover 榜单那批 token 建的 ——
   * 实测榜单 48 条 **48 条全部命中策展层**，所以 `desc` 传空串也能得到正确分类。
   *
   * 只补空值：目录/快照里若已带分类，不覆盖。hydration 之后仍会按 `desc` 重算一次，
   * 对**未被策展覆盖**的 token 能得到比兜底档更细的分类。
   */
  private static fillCategoryKeys(page: BrewDiscoverPageData): void {
    let filled: number = 0;
    page.boards.forEach((board: BrewDiscoverBoard) => {
      board.entries.forEach((entry: BrewDiscoverEntry) => {
        if (entry.categoryKey.length > 0) {
          return;
        }
        entry.categoryKey = BrewTaxonomy.categoryOf(board.kind, entry.token, entry.desc);
        filled++;
      });
    });
    Logger.info(TAG, `categoryKey filled before hydration: ${filled} entries`);
  }

  private hydratePage(page: BrewDiscoverPageData, membersFromCatalog: boolean): Promise<BrewDiscoverPageData> {
    if (BREW_DATA_MODE !== BrewDataMode.REMOTE) {
      return Promise.resolve(page);
    }
    const formulaTokens: string[] = [];
    const caskTokens: string[] = [];
    page.boards.forEach((board: BrewDiscoverBoard) => {
      const target: string[] = board.kind === BrewKind.CASK ? caskTokens : formulaTokens;
      board.entries.forEach((entry: BrewDiscoverEntry) => target.push(entry.token));
    });
    return this.service.hydrateFormulaDocs(formulaTokens).then((formulaDocs: Record<string, LiveFormulaDoc>) => {
      return this.service.hydrateCaskDocs(caskTokens).then((caskDocs: Record<string, LiveCaskDoc>) => {
        page.boards.forEach((board: BrewDiscoverBoard) => {
          const isCask: boolean = board.kind === BrewKind.CASK;
          board.entries.forEach((entry: BrewDiscoverEntry) => {
            if (isCask) {
              BrewDiscoverModel.applyCaskEntry(entry, caskDocs[entry.token], board.boardKey, !membersFromCatalog);
            } else {
              BrewDiscoverModel.applyFormulaEntry(entry, formulaDocs[entry.token], board.boardKey, !membersFromCatalog);
            }
          });
          if (!membersFromCatalog) {
            BrewDiscoverModel.sortBoard(board);
          }
        });
        // 大图卡是“各榜前 N 名”的选择结果（FEATURED_RULE，编辑口径），
        // 榜重排后必须重新选一遍，否则卡上的“第 1 名”会指到榜里不是第 1 的那个包
        page.featured = BrewDiscoverModel.buildFeatured(page);
        return page;
      });
    });
  }

  /**
   * 大图卡的选取规则，与 `generate.py` 的 `FEATURED_RULE` **逐字对应**。
   *
   * 顺序也不能改：生成器是按 kind 外层循环（formula 先、cask 后）依次 append 的，
   * 所以已发布的快照里 featured 的顺序就是这份规则展开后的顺序。
   */
  private static readonly FEATURED_RULE: FeaturedRule[] = [
    { kind: BrewKind.FORMULA, boardKey: BrewDiscoverBoardKey.TRENDING, count: 2 },
    { kind: BrewKind.FORMULA, boardKey: BrewDiscoverBoardKey.FRESH, count: 1 },
    { kind: BrewKind.CASK, boardKey: BrewDiscoverBoardKey.TRENDING, count: 1 },
    { kind: BrewKind.CASK, boardKey: BrewDiscoverBoardKey.FRESH, count: 1 },
  ];

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

  private static applyFormulaEntry(entry: BrewDiscoverEntry, doc: LiveFormulaDoc | undefined,
    boardKey: string, metricsFromLive: boolean): void {
    if (doc === undefined || doc === null) {
      return;
    }
    entry.desc = doc.desc ?? entry.desc;
    entry.name = doc.name ?? entry.name;
    // 分类只能看 desc 算（官方 API 无分类字段）——所以必须在拿到现网 doc 之后补
    entry.categoryKey = BrewTaxonomy.categoryOf(BrewKindText.FORMULA, entry.token, entry.desc);
    if (!metricsFromLive) {
      return;
    }
    const analytics: LiveAnalytics = doc.analytics ?? {};
    BrewDiscoverModel.applyMetrics(entry, analytics.install_on_request?.['30d'],
      analytics.install_on_request?.['365d'], boardKey);
  }

  private static applyCaskEntry(entry: BrewDiscoverEntry, doc: LiveCaskDoc | undefined,
    boardKey: string, metricsFromLive: boolean): void {
    if (doc === undefined || doc === null) {
      return;
    }
    entry.desc = doc.desc ?? entry.desc;
    const names: string[] | undefined = doc.name;
    if (names !== undefined && names.length > 0) {
      entry.name = names[0];
    }
    entry.categoryKey = BrewTaxonomy.categoryOf(BrewKindText.CASK, entry.token, entry.desc);
    if (!metricsFromLive) {
      return;
    }
    const analytics: LiveAnalytics = doc.analytics ?? {};
    BrewDiscoverModel.applyMetrics(entry, analytics.install?.['30d'],
      analytics.install?.['365d'], boardKey);
  }

  /**
   * 与 `check_algo.py` §3 同一套公式 + 与生成器同一套取整。
   *
   * `prior = (365d − 30d) / 11`（此前 11 个月的月均，**分母不加 max(1, ·)**），
   * `velocity = 30d / prior`，`score = log1p(velocity) × log1p(30d)`。
   * `prior <= 0`（无历史）时 velocity/prior 均为 0 —— 保留“0 就是无历史”这个语义。
   */
  private static applyMetrics(entry: BrewDiscoverEntry, bucket30: Record<string, number> | undefined,
    bucket365: Record<string, number> | undefined, boardKey: string): void {
    const vol: number = BrewApiMapper.installCount(bucket30, entry.token);
    const year: number = BrewApiMapper.installCount(bucket365, entry.token);
    const prior: number = (year - vol) / 11;
    entry.installs30d = vol;
    entry.installs365d = year;
    entry.priorMonthly = prior > 0 ? Math.round(prior * 10) / 10 : 0;
    entry.velocity = prior > 0 ? Math.round(vol / prior * 100) / 100 : 0;
    // score 只在趋势榜有意义（模型注释与生成器同口径），其余榜写 0
    entry.score = boardKey === BrewDiscoverBoardKey.TRENDING ?
      Math.round(Math.log1p(entry.velocity) * Math.log1p(vol) * 100) / 100 : 0;
  }

  /** 按各榜口径重排并重新编号（1 起算） */
  private static sortBoard(board: BrewDiscoverBoard): void {
    if (board.boardKey === BrewDiscoverBoardKey.TRENDING) {
      board.entries.sort((a: BrewDiscoverEntry, b: BrewDiscoverEntry) => b.score - a.score);
    } else if (board.boardKey === BrewDiscoverBoardKey.ALLTIME) {
      board.entries.sort((a: BrewDiscoverEntry, b: BrewDiscoverEntry) => b.installs365d - a.installs365d);
    } else {
      board.entries.sort((a: BrewDiscoverEntry, b: BrewDiscoverEntry) => b.installs30d - a.installs30d);
    }
    board.entries.forEach((entry: BrewDiscoverEntry, index: number) => {
      entry.rank = index + 1;
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
  /** 元数据索引是否就绪。false = desc 一律为空，只按包名匹配过 */
  public indexReady: boolean = true;
  /** 目录拿不到、行是仅凭 desc 索引造出来的（此时 `vol30d` 全为 0，排序信息不全） */
  public rowsFromIndexOnly: boolean = false;
  public hits: BrewSearchHit[] = [];
  public items: BrewPackageItem[] = [];
}

/**
 * 搜索的数据入口（单例 + getInstance，与 `BrewFormulaModel` 等一致）。
 *
 * 三条口径：
 *   1. **同步计算**：目录在内存、索引在内存/Preference，全程不发请求 —— 所以这里
 *      没有 loading 态可言（`Promise` 只是跟随既有仓库层签名，不是真异步）。
 *   2. **目录缺失时回落到 desc 索引**：索引是落盘的、离线可用；只认目录会让
 *      「有索引没目录」（断网 / SNAPSHOT）变成整页空态，而那正是最该能用的时候。
 *   3. **不做结果缓存**：索引与目录本身已在内存，匹配是毫秒级纯计算；
 *      缓存只会引入「数据变了但结果不变」（Discover 吃过这个亏）。
 *
 * 另外提供 `hotTokens()`：「搜索发现」的成员来源 —— 同一份目录的**真实**热门榜，
 * 取代了原先写死的词组（那些词在 Homebrew 里不存在，点下去必然空结果）。
 */
export class BrewSearchModel {
  private static instance: BrewSearchModel | undefined = undefined;
  private service: BrewService = new BrewService();

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
    result.indexReady = BrewMetaSync.ready();
    const entries: BrewSearchEntry[] = [];
    let order: number = 0;
    [BrewKindText.FORMULA, BrewKindText.CASK].forEach((kind: string) => {
      const descIndex: Record<string, string> = BrewMetaSync.descOf(kind);
      const rows: CatalogEntry[] = this.service.searchRows(kind);
      if (rows.length > 0) {
        rows.forEach((row: CatalogEntry) => {
          entries.push(BrewSearchModel.entryOf(kind, row.token,
            BrewBrowseBuilder.descOf(row.token, descIndex), row.vol30d, order++));
        });
        return;
      }
      // 目录缺失：用 desc 索引的键当行（vol30d = 0）。索引为空时这一趟也拿不到东西，
      // 于是结果为空 —— UI 那边有「索引未就绪」的提示条兜着，不报错。
      result.rowsFromIndexOnly = true;
      Object.keys(descIndex).forEach((token: string) => {
        entries.push(BrewSearchModel.entryOf(kind, token, descIndex[token], 0, order++));
      });
    });
    const all: BrewSearchHit[] = BrewSearchEngine.rank(k, entries, 0);
    result.total = all.length;
    const limited: BrewSearchHit[] = all.length > BREW_SEARCH_LIMIT ? all.slice(0, BREW_SEARCH_LIMIT) : all;
    result.hits = limited;
    limited.forEach((hit: BrewSearchHit) => result.items.push(this.itemOf(hit)));
    Logger.info(SEARCH_TAG, `search "${k}" → ${result.total} hits, ${result.hits.length} items, ` +
      `indexReady=${result.indexReady}, indexOnly=${result.rowsFromIndexOnly}, ` +
      `${Date.now() - started}ms | top: ${BrewSearchModel.topLine(result.hits)}`);
    return Promise.resolve(result);
  }

  /**
   * 「搜索发现」的成员来源：formula 与 cask 的真实目录行合并后，按近 30 天安装量降序取前 `limit` 个 token。
   *
   * 三条口径与 `search()` 完全一致（同一份目录、同一个排序依据）：
   *   1. **同步、零请求**：目录在内存里（`BrewService.ensureCatalog` 首次访问读一次 Preference），
   *      所以发现区不需要 loading 态；**也不该为它去拉网络** —— 聚合端点探针实测最长 17s，
   *      而发现区是搜索页的默认内容，拉网络等于让空关键字态的搜索页先转十几秒圈。
   *   2. **定序必须确定**：`CatalogEntry` 上没有 kind，若用 `sort` 合并，同量条目的先后就取决于
   *      sort 的稳定性（引擎那边明令禁止依赖它）。所以手写双指针归并：两侧各自已按量降序，
   *      同量时 formula 优先 —— 同一份目录必得同一个序列。
   *   3. **拿不到目录就返回空数组**（首次安装 / 断网且盘上没目录）：UI 显示空态，
   *      **不回落任何写死的词**（那些词在 Homebrew 里一个都不存在）。
   *
   * 只归并到 `limit` 个就停：不会为了取 40 条而遍历全量 1.3 万条。
   */
  public hotTokens(limit: number): string[] {
    const formulae: CatalogEntry[] = this.service.searchRows(BrewKindText.FORMULA);
    const casks: CatalogEntry[] = this.service.searchRows(BrewKindText.CASK);
    const out: string[] = [];
    // 同名 token 在 formula 与 cask 里都可能存在（例如都有 `docker` 类的历史遗留）：
    // 池子里只留一条。不去重的话发现区可能在同一屏里摆出两个一样的词，
    // 而 `ForEach` 的 key 就是词 → 重复 key 是运行期问题。
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
    // 判据行：池子空不空、池子里是谁，一眼可见（池为空 = 目录还没到，UI 会走空态）
    Logger.info(SEARCH_TAG, `hot tokens (discovery pool): ${out.length} of ` +
      `formula=${formulae.length} cask=${casks.length} | top: ${out.slice(0, 5).join(' ')}`);
    return out;
  }

  /**
   * 命中行 → 列表行。只补 `token` / `vol30d` 两个字段：`formulaItem` / `caskItem`
   * 内部只读这两个（其余是榜单语义，搜索结果里没有）。
   */
  private itemOf(hit: BrewSearchHit): BrewPackageItem {
    const row: CatalogEntry = {
      token: hit.token,
      vol30d: hit.vol30d,
      vol365d: 0,
      prior: 0,
      velocity: 0,
      score: 0,
    };
    const categoryKey: string = BrewTaxonomy.categoryOf(hit.kind, hit.token, hit.desc);
    // 分支放这里而不是 BrewBrowseBuilder：`BrewKindText` 定义在 BrewService.ets，
    // 而 BrewService 已经 import 了 BrewBrowseBuilder —— 反向 import 会成环。
    return hit.kind === BrewKindText.CASK
      ? BrewBrowseBuilder.caskItem(row, undefined, hit.desc, categoryKey)
      : BrewBrowseBuilder.formulaItem(row, undefined, hit.desc, categoryKey);
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

  /** 日志判据行：Top5 的 `token(分数/方式)`，一眼能看出排序是否合理 */
  private static topLine(hits: BrewSearchHit[]): string {
    return hits.slice(0, 5)
      .map((hit: BrewSearchHit) => `${hit.kind === BrewKindText.CASK ? 'cask:' : ''}${hit.token}` +
        `(${hit.score}/${hit.matchedBy})`)
      .join(' ');
  }
}
