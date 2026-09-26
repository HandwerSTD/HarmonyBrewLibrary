/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

/**
 * Homebrew 应用市场 · 数据模型
 *
 * 设计原则
 * 1. 字段命名保留 Homebrew API 原生语义（token / tap / bottle / artifacts / dependsOn / kegOnly …），
 *    未来把 MockRequest 换成真实 HTTP 请求时，解析层零改动。
 * 2. 卡片条目额外提供 BaseData 展示槽位（title / subTitle），以便复用现有卡片渲染器：
 *      subTitle -> primaryText  放 token
 *      title    -> secondaryText 放英文 desc
 * 3. 详情页不复用组件演练场引擎（见 docs/brew-api-design.md §5）：官方 API 的 `options` 字段恒为空，
 *    安装命令区只展示基础命令，因此模型里不再有 props。
 */

// ---------------------------------------------------------------- 基础枚举

/** 包类型 */
export enum BrewKind {
  FORMULA = 'formula',
  CASK = 'cask',
}

// ---------------------------------------------------------------- 安装选项

/** formula 的系统要求，如 openjdk 需要 xcode。 */
export interface BrewRequirement {
  /** 要求名，如 xcode / macos */
  name: string;
  version: string;
  /** 生效阶段：build / test / optional … */
  contexts: string[];
}

// ---------------------------------------------------------------- 卡片条目

/**
 * 分类卡/卡片内的包条目。含 BaseData 展示槽位。
 *
 * 用 class 而非 interface：UI 层（LazyForEach / 卡片组件）需要能直接实例化它做兜底，
 * 且作为 IDataSource 的返回类型。字段一律给默认值，避免 JSON 缺字段时拿到 undefined。
 */
export class BrewPackageItem {
  public id: number = 0;
  /** Formulae 页：所属分类卡 id */
  public formulaCardId: number = 0;
  /** Casks 页：所属卡片 id */
  public caskCardId: number = 0;
  public mediaType: string = 'IMAGE';
  public mediaUrl: string = '';
  /** 展示槽位 secondaryText：英文 desc */
  public title: string = '';
  /** 展示槽位 primaryText：token */
  public subTitle: string = '';
  public version: number = -1;
  public sequence: number = -1;
  public tagIds: number[] = [];
  public contentType: number = 1;
  /** brew 包名，如 ripgrep / google-chrome */
  public token: string = '';
  public license: string = '';
  public homepage: string = '';
  public stableVersion: string = '';
  public installs30d: number = 0;
  /** 分类内安装量排名（从 1 开始） */
  public categoryRank: number = 0;
  /** 分类内包总数 */
  public categorySize: number = 0;
  public kegOnly: boolean = false;
  public autoUpdates: boolean = false;
  public deprecated: boolean = false;
  public disabled: boolean = false;
  public categoryKey: string = '';
}

// ---------------------------------------------------------------- 分页与首页


/** Formulae 首页：分类大卡（对齐 component-page.json） */
export class BrewCategoryCard {
  public id: number = 0;
  public categoryKey: string = '';
  /** 英文分类名（中文名由 FORMULA_CATEGORY_NAME 资源映射提供） */
  public title: string = '';
  public subTitle: string = '';
  public styleType: number = 0;
  public image: string = '';
  public iconSymbol: string = '';
  public themeColor: string = '';
  public sequence: number = -1;
  public contentType: number = 1;
  public itemCount: number = 0;
  public hasMore: boolean = false;
  public formulaContents: BrewPackageItem[] = [];
}

export class BrewFormulaPageData {
  public cardData: BrewCategoryCard[] = [];
}

/** Casks 首页：分类 Tab + 卡片（对齐 sample-page.json） */
export class BrewCaskCard {
  public id: number = 0;
  public unionId: number = 0;
  public title: string = '';
  public styleType: number = 0;
  public image: string = '';
  public sequence: number = -1;
  /**
   * 所属分类的 categoryKey。mock 里它挂在 `BrewCaskCategory` 上（卡片是分类的子节点），
   * 但首页要**按分类平铺**渲染卡片，所以由 `BrewBrowseBuilder.caskPage` 复制一份到卡片上 ——
   * 卡片自己就能取到分类名与图标，与 `BrewCategoryCard` 同款（那边本来就是平铺的）。
   */
  public categoryKey: string = '';
  /** 该分类的**总**条数（卡内只预览前 N 条，表头的包数要显示总数） */
  public itemCount: number = 0;
  /** 还有没显示出来的成员（判据是 `BREW_CATEGORY_PREVIEW_COUNT`，与卡内截断同源） */
  public hasMore: boolean = false;
  public caskContents: BrewPackageItem[] = [];
}

export class BrewCaskCategory {
  public id: number = 0;
  public categoryKey: string = '';
  public categoryName: string = '';
  public defaultIcon: string = '';
  public selectedIcon: string = '';
  public sequence: number = -1;
  public caskCards: BrewCaskCard[] = [];
}

export class BrewCaskPageData {
  public caskCategories: BrewCaskCategory[] = [];
}

/** 分页信封，对齐 commonbusiness 的 PageData 结构 */
export interface BrewPageData<T> {
  currentPage: number;
  pageSize: number;
  totalPage: number;
  totalSize: number;
  data: T;
}

// ---------------------------------------------------------------- 详情公共

export interface BrewDependency {
  name: string;
  fullName: string;
}

export interface BrewKegOnlyReason {
  reason: string;
  explanation: string;
}

/** 废弃 / 停用状态。Homebrew 是三态：正常、deprecated（可用但警告）、disabled（不可安装）。 */
export interface BrewLifecycleInfo {
  deprecated: boolean;
  deprecationDate: string;
  deprecationReason: string;
  deprecationReplacementFormula: string;
  deprecationReplacementCask: string;
  disabled: boolean;
  disableDate: string;
  disableReason: string;
}

/** 安装产物（cask artifacts 的归一化结果） */
export interface BrewArtifact {
  /** app | binary | pkg | font | colorpicker | qlplugin | installer | manpage | prefpane | suite | service … */
  artifactType: string;
  path: string;
}

export interface BrewArch {
  type: string;
  bits: number;
}

export interface BrewCaskDependsOn {
  formula: BrewDependency[];
  cask: BrewDependency[];
  /** 形如 { "<=": ["14"] } */
  macos: Record<string, string[]>;
  arch: BrewArch[];
}

// ---------------------------------------------------------------- 详情

export interface BrewFormulaDetail extends BrewLifecycleInfo {
  id: number;
  token: string;
  fullToken: string;
  tap: string;
  name: string;
  desc: string;
  homepage: string;
  license: string;
  stableVersion: string;
  headVersion: string;
  versionedFormulae: string[];
  aliases: string[];
  kegOnly: boolean;
  kegOnlyReason: BrewKegOnlyReason | null;
  serviceSupported: boolean;
  /** brew services 的启动命令（如 ['$HOMEBREW_PREFIX/opt/redis/bin/redis-server', ...]） */
  serviceRun: string[];
  /** immediate / interval … */
  serviceRunType: string;
  /** 安装后提供的命令，如 ripgrep -> ['rg']、postgresql@16 -> 34 个命令 */
  executables: string[];
  /** 安装/构建要求 */
  requirements: BrewRequirement[];
  caveats: string;
  bottleAvailable: boolean;
  bottleTags: string[];
  bottleRebuild: number;
  dependencies: BrewDependency[];
  buildDependencies: BrewDependency[];
  optionalDependencies: BrewDependency[];
  recommendedDependencies: BrewDependency[];
  usesFromMacos: string[];
  conflictsWith: string[];
  installs30d: number;
  installs90d: number;
  installs365d: number;
  categoryRank: number;
  categorySize: number;
  installCommand: string;
  categoryKey: string;
}

export interface BrewCaskDetail extends BrewLifecycleInfo {
  id: number;
  token: string;
  fullToken: string;
  tap: string;
  name: string;
  names: string[];
  desc: string;
  homepage: string;
  version: string;
  autoUpdates: boolean;
  /** 支持的平台标签，如 ['arm64_sequoia', 'sonoma', ...] */
  supportedPlatforms: string[];
  /** 已压成可展示字符串，如 'macOS >= 13' */
  macosRequirement: string;
  /** Bundle 版本。是点分版本号（如 '15526.9.3'），Homebrew 侧类型不固定，统一为字符串 */
  bundleVersion: string;
  artifacts: BrewArtifact[];
  zapPathCount: number;
  dependsOn: BrewCaskDependsOn;
  conflictsWith: string[];
  caveats: string;
  installs30d: number;
  installs90d: number;
  installs365d: number;
  categoryRank: number;
  categorySize: number;
  installCommand: string;
  categoryKey: string;
}

/** 详情页统一视图类型（避免 UI 层分别处理两种包） */
export type BrewPackageDetail = BrewFormulaDetail | BrewCaskDetail;

// ---------------------------------------------------------------- 本机状态（Mine，纯 Mock）

export interface BrewInstalledPackage {
  name: string;
  fullName: string;
  version: string;
  latestVersion: string;
  installedOnRequest: boolean;
  installedAsDependency: boolean;
  pouredFromBottle: boolean;
  installedAt: number;
  autoUpdates: boolean;
  outdated: boolean;
  kind: string;
}

export interface BrewPageParam {
  currentPage: number;
  pageSize: number;
}

/** 单条查询参数。MockRequest 依据 singleId 在 body 数组里按 id 命中。 */
export interface BrewSingleIdParam {
  singleId: number;
}

/**
 * 详情页路由参数（Formulae / Casks 共用）。
 *
 * 必须带 `kind`：详情页要据此决定读哪个 JSON（formula-details / cask-details）
 * 以及按哪种包渲染分区。不要靠 id 区间去推断包类型 —— 当前 mock 里
 * formula 从 1001 起、cask 从 2001 起，只是生成器的巧合，不是契约。
 */
export interface BrewDetailParams {
  /** 包类型 */
  kind: BrewKind;
  /** 标题栏标题（先展示列表里已有的信息，详情回来后再覆写） */
  title: string;
  id: number;
  token: string;
  categoryKey: string;
}

// ------------------------------------------------------------------ Discover

/**
 * 榜单类型。值与 JSON 里的 `boardKey` 一致，不做二次映射。
 */
export enum BrewDiscoverBoardKey {
  /** 趋势榜：近 30 天增速（仅此榜的 `score` 有意义） */
  TRENDING = 'trending',
  /** 历史榜：365 天累计主动安装量 */
  ALLTIME = 'alltime',
  /** 新星榜：无历史但已有量 */
  FRESH = 'fresh'
}

/** 榜单里的一条 */
export class BrewDiscoverEntry {
  /** 榜内名次，从 1 开始 */
  public rank: number = 0;
  /** 包详情 id（生成器 join 后写入；0 表示没有详情数据，不可点） */
  public id: number = 0;
  public token: string = '';
  /** 市场名。formula 通常等于 token，cask 是 `Microsoft Visual Studio Code` 这类可读名 */
  public name: string = '';
  /** 英文原文描述（中文只在 UI 文案层）。单 App 大图卡要展示 */
  public desc: string = '';
  /** 供详情页的「同分类其他包」使用 */
  public categoryKey: string = '';
  public installs30d: number = 0;
  public installs365d: number = 0;
  /** 此前 11 个月的月均。0 表示无历史（新包） */
  public priorMonthly: number = 0;
  /** `installs30d / priorMonthly`。0 表示无历史 —— 不要显示成「0 倍」 */
  public velocity: number = 0;
  /** `log1p(velocity) * log1p(installs30d)`。**仅趋势榜有意义**，其余榜按量排序 */
  public score: number = 0;
}

/** 一张榜 */
export class BrewDiscoverBoard {
  public id: number = 0;
  /** `'formula'` | `'cask'`，转 `BrewKind` 用 `brewKindOf()` */
  public kind: string = '';
  public boardKey: string = '';
  public sequence: number = 0;
  public entryCount: number = 0;
  public entries: BrewDiscoverEntry[] = [];
}

/** 快照元信息（窗口、候选数、门槛）。供页面标注「基于最近可用数据」 */
export class BrewDiscoverMeta {
  public windowStart: string = '';
  public windowEnd: string = '';
  public totalItems: number = 0;
  public totalCount: number = 0;
  public rawTokens: number = 0;
  public families: number = 0;
  public candidates: number = 0;
}

/**
 * 「单 App 大图卡」的一条 —— 一张卡就是一个包。
 *
 * 比榜单条目多两个字段：`kind` / `boardKey`，用来显示「今日热门 · #1」这种来源徽章。
 *
 * ⚠ 它**不再决定卡片的主题色** —— 大图卡的配色已改为所有卡共用同一个池子
 * （需求方：「不使用颜色配色区分大图卡类型」），榜的身份只由徽章文字承担。
 * `kind` 仍用于取分类图标与类型色，`boardKey` 只用于徽章文字。
 * 选取规则在生成器里（`FEATURED_RULE`），UI 不参与挑选。
 */
export class BrewDiscoverFeatured extends BrewDiscoverEntry {
  /** `'formula'` | `'cask'` */
  public kind: string = '';
  /** 来自哪张榜：`'trending'` | `'fresh'` */
  public boardKey: string = '';
}

export class BrewDiscoverPageData {
  /** 数据窗口结束日，如 `'2026-09-17'` */
  public snapshotDate: string = '';
  public topN: number = 0;
  public meta: Record<string, BrewDiscoverMeta> = {};
  public boards: BrewDiscoverBoard[] = [];
  /** 单 App 大图卡，排在瀑布流最前面。可能与榜卡里的包重复，这是有意的（需求方确认共存） */
  public featured: BrewDiscoverFeatured[] = [];
}

/**
 * 榜单二级页路由参数。
 *
 * 只传 `boardId`，不把榜单条目当参数穿过页面栈 —— 二是数据结构、二是逃页面栈的
 * 序列化限制。二级页自己去仓库取（已命中 Preference 缓存）再按 id 选榜，
 * 与「我的 - 本机包」三个入口共用 MinePackagesView 的做法一致。
 */
export interface BrewDiscoverBoardParams {
  boardId: number;
}

/**
 * 分类二级页（分类卡的「查看全部」）路由参数。
 *
 * 只传 `categoryKey`，不把成员列表当参数穿过页面栈 —— 与 `BrewDiscoverBoardParams` 同一个理由：
 * 列表是数据，不是参数（二是数据结构、二是逃页面栈的序列化限制）。二级页自己去仓库取
 * （成员是设备端用「目录 + 词表」现算的，重取一次命中目录缓存），再按 key 选分类。
 */
export interface BrewCategoryParams {
  categoryKey: string;
}

/** mock 响应信封，对齐 common/model/ResponseData.ets */
export interface BrewResponseData<T> {
  success: boolean;
  code: string;
  msg: string;
  body: T;
}
