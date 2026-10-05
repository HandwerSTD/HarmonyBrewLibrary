/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

// ---------------------------------------------------------------- 模型

export { BrewKind } from './src/main/ets/model/BrewModels';

// 这些类型在 UI 层需要被实例化（`new BrewCategoryCard()` 作为 IDataSource 的兜底返回值），
// 因此必须作为值导出；ArkTS 的 `export type` 会让它们在运行时不可用。
export {
  BrewCategoryCard,
  BrewCaskCard,
  BrewCaskCategory,
  BrewCaskPageData,
  BrewDiscoverBoard,
  BrewDiscoverEntry,
  BrewDiscoverFeatured,
  BrewDiscoverMeta,
  BrewDiscoverPageData,
  BrewFormulaPageData,
  BrewPackageItem,
} from './src/main/ets/model/BrewModels';

export { BrewDiscoverBoardKey } from './src/main/ets/model/BrewModels';

// 详情页展示数据（已归一化）。UI 需要 new 出来做兜底，所以是值导出。
export {
  BrewInfoPageData,
  BrewInfoRow,
  BrewInfoSection,
  BrewLifecycleNotice,
} from './src/main/ets/model/BrewDetailViewData';

export type {
  BrewArch,
  BrewArtifact,
  BrewCaskDependsOn,
  BrewCaskDetail,
  BrewCategoryParams,
  BrewDependency,
  BrewDetailParams,
  BrewDiscoverBoardParams,
  BrewFormulaDetail,
  BrewInstalledPackage,
  BrewKegOnlyReason,
  BrewLifecycleInfo,
  BrewPackageDetail,
  BrewPageData,
  BrewPageParam,
  BrewRequirement,
  BrewSingleIdParam,
} from './src/main/ets/model/BrewModels';

export {
  BrewCaskModel,
  BrewDiscoverModel,
  BrewFormulaModel,
  BrewSearchModel,
  BrewSearchResult,
} from './src/main/ets/model/BrewRepository';

// 搜索的匹配引擎（纯函数）。导出它是因为 brewsearch 要用 normalize 做「陈旧结果」判定。
export {
  BrewSearchEngine,
  BREW_SEARCH_SCORE_DESC,
  BREW_SEARCH_SCORE_DESC_HEAD,
  BREW_SEARCH_SCORE_EXACT,
  BREW_SEARCH_SCORE_PREFIX_BASE,
  BREW_SEARCH_SCORE_PREFIX_PENALTY_MAX,
  BREW_SEARCH_SCORE_SUBSTR,
  BREW_SEARCH_SCORE_WORD,
} from './src/main/ets/model/BrewSearchEngine';

export type { BrewSearchEntry, BrewSearchHit } from './src/main/ets/model/BrewSearchEngine';

// ---------------------------------------------------------------- 常量

export {
  BREW_CHIP_BAR_HEIGHT,
  BREW_CATEGORY_PREVIEW_COUNT,
  BREW_SEARCH_LIMIT,
  brewChipBarHorizontalInset,
  brewContentTopInset,
  brewPageContentLeft,
  brewPageContentRight,
  brewTitleBarTotalHeight,
  CASK_CATEGORY_NAME,
  CASK_CATEGORY_ORDER,
  CASK_CATEGORY_SYMBOL,
  CaskCategoryKey,
  FORMULA_CATEGORY_NAME,
  FORMULA_CATEGORY_ORDER,
  FORMULA_CATEGORY_SYMBOL,
  FormulaCategoryKey,
  getCategoryNameMap,
  getCategorySymbolMap,
} from './src/main/ets/constant/BrewConstants';

// ---------------------------------------------------------------- 服务 / 工具

export { BrewDocAbsentError, BrewService } from './src/main/ets/service/BrewService';

// 设备端包表：安装量片（4 个聚合端点）+ 描述片（两个全量包），两片独立。
// 浏览页、榜单、搜索全部读它（稳态零请求）；详情页的现网单条是唯一的另一个消费者。
// 启动入口是 `BrewTable.refresh()`。
export { BrewTable, BrewKindText } from './src/main/ets/service/BrewTable';
export type { CatalogEntry, CatalogKindMeta, BrewVolRow } from './src/main/ets/service/BrewTable';

// 描述片构建器：把两个全量包抽成 `token → desc` 交给包表。见 docs/brew-catalog-fullsync-spec.md。
export { BrewMetaSync } from './src/main/ets/service/BrewMetaSync';
export type { DescShardOutcome } from './src/main/ets/service/BrewMetaSync';

export { BrewCommandGenerator } from './src/main/ets/util/BrewCommandGenerator';

// 设备上的 brew 调用口径：路径发现、环境前缀、命令行拼装。读取与执行共用同一份。
export { BrewCli } from './src/main/ets/service/BrewCli';

// 写命令的执行层：单飞、200ms 轮询、行缓冲、中断与终止。命令状态在单例里，Sheet 可随时关开。
export { BrewCommandRunner } from './src/main/ets/service/BrewCommandRunner';

// 命令状态类型。UI 层要用它们实例化（BrewCommandRequest 由页面 new 出来），所以是值导出。
export {
  BrewCommandLine,
  BrewCommandRequest,
  BrewCommandStartResult,
  BrewCommandState,
  BrewCommandStatus,
  brewCommandStatusText,
  isBrewCommandEnded,
} from './src/main/ets/model/BrewCommandModels';

// 执行 Sheet 的内容组件，两个页面共用一份。
export { BrewCommandSheet } from './src/main/ets/component/BrewCommandSheet';

// 标题栏模糊：brew 所有页共用一份实现（区间位置/长度只在 BrewTitleBar.ets 里定义）。
// 改模糊表现只改这里 —— 各页原先各写一份，结果出现「有的页没有渐变、有的页先空行程再猛增」。
export {
  brewBlurScrollEffect,
  brewLogRampForPage,
  brewTitleBarStyle,
  BREW_TITLEBAR_BLUR_MIN_RAMP,
  BREW_TITLEBAR_BLUR_RAMP,
} from './src/main/ets/util/BrewTitleBar';

export { BrewFormat } from './src/main/ets/util/BrewFormat';

// 冷启动各数据类型的加载打点（`[load] kind=… reason=… ms=… at=…`）。
// 格式与 reason 词表的读法都在该文件头部；改格式只改这一处。
export { BrewLoadLog } from './src/main/ets/util/BrewLoadLog';

export { BrewDetailNormalizer } from './src/main/ets/util/BrewDetailNormalizer';

// ---------------------------------------------------------------- 共享 UI 原子

// Formulae / Casks / Discover / 详情页共用的包行。
// 放在这里而不是某个页签模块，是为了让各页签模块彼此独立（不出现 casks -> formulae 这种反向依赖）。
export { BrewPackageRow } from './src/main/ets/component/BrewPackageRow';

// 本机已安装包的行（「我的」页与其子页面用）。与 BrewPackageRow 分开的原因见该文件注释。
export { BrewLocalPackageRow } from './src/main/ets/component/BrewLocalPackageRow';

// 包图标基底：中性底圆角方块 + 类型色 symbol。四个渲染点（两个包行 / Discover 行 /
// Discover 大图卡 / 详情页头部）共用，样式源在 constant/BrewIconStyle.ets。
export { BrewPackageIcon } from './src/main/ets/component/BrewPackageIcon';

// 包图标的唯一样式来源（图标字形 / 比例 / 尺寸档位 / 类型色）。
// 美工替换图标或配色只改这里。
export {
  BREW_PACKAGE_ICON,
  BREW_PACKAGE_ICON_BORDER_WIDTH,
  BREW_PACKAGE_ICON_BOX_BACKGROUND,
  BREW_PACKAGE_ICON_RATIO,
  BrewIconSize,
  brewKindIconColor,
} from './src/main/ets/constant/BrewIconStyle';

// 通用胶囊 chip 栏（Casks 分类 chips 与「我的」筛选 chips 共用）。
// 单个 chip 的外观在 BrewChip 里，「我的 - 本机包」标题栏右侧的隐藏 chip 也用同一个组件。
export { BrewChipBar, BrewChipItem } from './src/main/ets/component/BrewChipBar';

export { BrewChip } from './src/main/ets/component/BrewChip';

// 分类卡的卡头（首页分类卡与两张分类二级页共用一份）
export { BrewCategoryCardHeader } from './src/main/ets/component/BrewCategoryCardHeader';

// ------------------------------------------------------------------ 数据源

// 包列表的 LazyForEach 数据源（分类二级页的虚拟滚动）
export { BrewPackageItemSource } from './src/main/ets/model/BrewPackageItemSource';

// ------------------------------------------------------------------ 数据源（多源 + 按源缓存）

export {
  BrewSource,
  BrewSourceRegistry,
  BrewSourceHealth,
  BrewSourceReach,
  BrewSourceHealthRecord,
  BrewProbeResult,
  BrewSourceCacheStats,
} from './src/main/ets/model/BrewSourceModels';

export {
  BREW_DIALECT_HARMONYBREW,
  BREW_DIALECT_UPSTREAM,
  BREW_HARMONYBREW_CATALOG_PATH,
  BREW_HARMONYBREW_DEFAULT_TAG,
  BREW_HARMONYBREW_RANGE_PROBE_BYTES,
  BREW_OFFICIAL_SOURCE_ID,
  BREW_OFFICIAL_BASE_URL,
  BREW_SOURCE_STORE_PREFIX,
  BREW_SOURCE_VERIFY,
} from './src/main/ets/constant/BrewSourceConstants';

export type { BrewCatalogResult, BrewSourceAdapter } from './src/main/ets/service/source/BrewSourceAdapter';
export { adapterFor } from './src/main/ets/service/source/BrewSourceAdapter';

export { BrewSourceUrl, BrewSourceUrlCheck } from './src/main/ets/service/BrewSourceUrl';export { BrewSourceStore, BrewSourceUpdateResult } from './src/main/ets/service/BrewSourceStore';
export { BrewSourceDiagnostics } from './src/main/ets/service/BrewSourceDiagnostics';
export { BrewSourcePrefs } from './src/main/ets/service/BrewSourcePrefs';
export { BrewSourceProbe } from './src/main/ets/service/BrewSourceProbe';
export { BrewCacheAdmin } from './src/main/ets/service/BrewCacheAdmin';
export { BrewCacheEpoch } from './src/main/ets/service/BrewCacheEpoch';
export { BrewSourceRestart } from './src/main/ets/service/BrewSourceRestart';

// ------------------------------------------------------------------ 本机包（设备上的 brew 安装记录）

// 执行设备上的 `brew info --json=v2 --installed` 并把结果归一成三个集合。
// 失败分类在抛出的异常的 message 里（`BrewInstalledFailure` 的取值）。
export { BrewInstalledLoader, BrewInstalledFailure, BrewInstalledOutcome, BrewInstalledSets } from './src/main/ets/service/BrewInstalledLoader';
export { BrewInstalledParser } from './src/main/ets/util/BrewInstalledParser';
export type { BrewCaskDoc, BrewFormulaDoc, BrewInstalledDoc, BrewInstalledKegDoc } from './src/main/ets/model/BrewInstalledDoc';
