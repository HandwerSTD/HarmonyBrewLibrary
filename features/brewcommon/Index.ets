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
  BrewDiscoverAiEntry,
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
  BREW_SECTION_KEY_EXECUTABLES,
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

export type { BrewSearchHit } from './src/main/ets/model/BrewSearchEngine';
// BrewSearchEntry 是值导出（AI 找工具的目录索引要 new 它），与 BrewSearchHit 分开。
export { BrewSearchEntry } from './src/main/ets/model/BrewSearchEngine';

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

// tokenId（token → 稳定 id 的决定性哈希）是路由与缓存键的公共口径，
// AI 找工具的结果行也要走同一套 id，所以从 brewcommon 导出。
export { BrewBrowseBuilder } from './src/main/ets/service/BrewBrowseBuilder';

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

// 终端配色与 ANSI 解析：日志段的颜色与字体加成都由它切出来。
export { BrewAnsiParser, BrewTextSegment } from './src/main/ets/util/BrewAnsi';

// 执行 Sheet 的内容组件，两个页面共用一份。
export { BrewCommandSheet } from './src/main/ets/component/BrewCommandSheet';

// D3 · AI 报错解读卡（执行 Sheet 失败终态的附加卡；G13：下一步只有复制、没有执行入口）。
export { BrewAiFailureCard } from './src/main/ets/component/BrewAiFailureCard';

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

// 底部悬浮操作栏的取值（栏高 / 遮罩渐变长度 / 按钮尺寸）与判据日志。
// 包详情页与「我的 - 待更新」页共用 —— 两条栏长得一样只由这一处保证。
export {
  BREW_ACTION_BAR_HEIGHT,
  BREW_ACTION_BAR_MASK_GRADIENT,
  BREW_ACTION_BUTTON_BOTTOM_EXTRA,
  BREW_ACTION_BUTTON_HEIGHT,
  BREW_ACTION_BUTTON_MAX_WIDTH,
  BREW_ACTION_BUTTON_WIDTH,
  brewActionBarHeight,
  brewActionBarMaskHeight,
  brewLogActionBar,
} from './src/main/ets/constant/BrewActionBar';

// 冷启动各数据类型的加载打点（`[load] kind=… reason=… ms=… at=…`）。
// 格式与 reason 词表的读法都在该文件头部；改格式只改这一处。
export { BrewLoadLog } from './src/main/ets/util/BrewLoadLog';

export { BrewDetailNormalizer } from './src/main/ets/util/BrewDetailNormalizer';

// ---------------------------------------------------------------- tldr 用法示例

// tldr 取数层：内存/落盘缓存（TTL 14 天 + stale-while-revalidate）、双渠道抓取、24h 负缓存。
// 详情页的「用法示例」分区是它的唯一 UI 消费者（specs/2026-11-22-tldr-usage-examples-spec.md）。
export { TldrService } from './src/main/ets/service/TldrService';

// tldr 解析器（纯函数）。BrewCommandRunner 的原始命令安全闸与检查脚本共用它。
export { TldrParser } from './src/main/ets/util/TldrParser';
export type { TldrCodeSegment } from './src/main/ets/util/TldrParser';

// tldr 展示模型。UI 需要 new 出来做兜底（BrewDetailState），所以是值导出。
export { TldrExample, TldrPage } from './src/main/ets/model/TldrPage';

// 署名行跳转目标（G11）。详情页组件要用它 openLink，单独导出常量而不是整个常量模块。
export { TLDR_REPO_URL } from './src/main/ets/constant/TldrConstants';

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
  BREW_HARMONYBREW_BASE_URL,
  BREW_HARMONYBREW_CATALOG_PATH,
  BREW_HARMONYBREW_DEFAULT_TAG,
  BREW_HARMONYBREW_RANGE_PROBE_BYTES,
  BREW_HARMONYBREW_SOURCE_ID,
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

// ------------------------------------------------------------------ 更新哨兵（桌面卡片）

// 哨兵服务：宿主进程与扩展进程（Form/WorkScheduler 回调）共用同一份，公开方法一律收 context。
// 只读 BrewInstalledLoader 的快照，不跑命令（审计脚本 hmosword-build/brew-sentinel 拦触达点）。
export { BrewSentinelService } from './src/main/ets/service/BrewSentinelService';

// 哨兵常量：GSKV 键 / 卡片数据键 / 卡片规格 / 三档调度开关（通知与频控常量已随二期 N 线移除）。
// 不入 CommonEnums.StorageKey —— 哨兵键是跨进程 preferences 键，与 AppStorage 键物理分开（spec §2）。
export {
  SENTINEL_CARD_ITEMS_LIMIT,
  SENTINEL_DATA_AS_OF,
  SENTINEL_DATA_COUNT,
  SENTINEL_DATA_DIMENSION,
  SENTINEL_DATA_FORM_ID,
  SENTINEL_DATA_HAS_SNAPSHOT,
  SENTINEL_DATA_ITEMS,
  SENTINEL_DATA_STALE,
  SENTINEL_DIMENSION_2_2,
  SENTINEL_DIMENSION_2_4,
  SENTINEL_DIMENSION_4_4,
  SENTINEL_DIMENSION_DEFAULT,
  SENTINEL_FORM_NAME,
  SENTINEL_PREFERENCES_NAME,
  SENTINEL_STALE_MS,
  SENTINEL_TOP_NAMES_LIMIT,
  SENTINEL_WANT_KEY_ROUTE,
  SENTINEL_WORK_ID,
  SENTINEL_WORK_INTERVAL_MS,
  SENTINEL_WORK_SCHEDULER_ENABLED,
} from './src/main/ets/constant/SentinelConstants';
// ------------------------------------------------------------------ AI Companion（BYOK 底座 + D1/D2/D3/D4）
// D2 已问答化（2026-11-26-ai-search-ask-spec）：AiSearchPick/AiSearchAnswer 替代旧
// AiToolCandidate/AiToolResult；词表（AiTaskWords）随贴片退役一并删除。

export { AiClient } from './src/main/ets/service/AiClient';
export { AiErrorDetail } from './src/main/ets/util/AiErrorDetail';
export { AiSettingsStore } from './src/main/ets/service/AiSettingsStore';
export { AiCache, AiCacheRead, AiCacheReadResult, AiCacheEnvelope } from './src/main/ets/service/AiCache';
export { AiTasks } from './src/main/ets/service/AiTasks';
export {
  AiError,
  AiErrorKind,
  AiProviderConfig,
  AiSettingsSnapshot,
  AiExplainCard,
  AiSearchPick,
  AiSearchAnswer,
  AiFailureCard,
  AiExplainInput,
  AiFailureInput,
  AiIntentInput,
  isKnownAiProvider,
  AiDiscoverProfile,
  AiDiscoverPick,
  AiDiscoverResult,
  AiInstalledBrief,
  AiCandidate,
  AiDiscoverInput,
} from './src/main/ets/model/AiTypes';
export {
  AI_PROMPT_VERSION_D1,
  AI_PROMPT_VERSION_D2,
  AI_PROMPT_VERSION_D4,
  AI_CACHE_TTL_D1_MS,
  AI_CACHE_TTL_D2_MS,
  AI_CACHE_TTL_D4_MS,
  AI_PROMPT_MAX_CHARS,
  AI_D3_STDERR_TAIL_CHARS,
  AI_D3_STDOUT_TAIL_CHARS,
  AI_D2_LEAD_MAX_CHARS,
  AI_D2_INTRO_MAX_CHARS,
  AI_D2_TAIL_ROWS_MAX,
  AI_D2_MAX_CANDIDATES,
  AI_D2_RESULT_LIMIT,
  AI_TIMEOUT_MS,
  AI_PROVIDER_DEEPSEEK,
  AI_PROVIDER_CUSTOM,
  AI_DEEPSEEK_BASE_URL,
  AI_DEEPSEEK_DEFAULT_MODEL,
  AI_ASSET_ALIAS_API_KEY,
  AI_PREFS_KEY_AUTO_EXPLAIN,
  AI_PREFS_KEY_AI_SEARCH,
  AI_D4_MIN_INSTALLED,
  AI_D4_INSTALLED_CAP,
  AI_D4_POOL_FORMULA,
  AI_D4_POOL_CASK,
  AI_D4_PICKS,
  AI_D4_PICKS_MIN,
  AI_D4_FEATURED_COUNT,
  AI_D4_RECENT_DAYS,
} from './src/main/ets/constant/AiConstants';
// ------------------------------------------------------------------ AI 发现流（D4 · 发现页个性化推荐）
// spec 2026-11-26-ai-discover-feed-spec.md：画像 + 推荐取数（brewcommon 侧）、
// 装配与渲染在 brewdiscover。fnv1a32 是 install 集签名（cacheKey 材料）。
export { fnv1a32 } from './src/main/ets/util/BrewHash';

// ------------------------------------------------------------------ Y · 更新情报中心（Release Intelligence）

// 详情页懒加载的更新情报：上游 Release Notes（releases.atom）+ 本地 formula diff + BYOK 归纳。
// 服务编排与策略（忽略/暂停）都在 brewcommon，UI 卡在 brewdetail（spec 2026-11-23 §8）。
export { ReleaseIntelService } from './src/main/ets/service/ReleaseIntelService';
export { ReleaseIntelFilter } from './src/main/ets/service/ReleaseIntelFilter';
export { ReleaseIntelPrefs } from './src/main/ets/service/ReleaseIntelPrefs';
export { ReleaseIntelBaselineStore } from './src/main/ets/service/ReleaseIntelBaselineStore';
export { ReleaseIntelSnapshotStore, SnapshotCacheRead } from './src/main/ets/service/ReleaseIntelSnapshotStore';
export { SemverJudge } from './src/main/ets/util/SemverJudge';
export { FormulaDiffer } from './src/main/ets/util/FormulaDiffer';
export { BrewNotesExtractor } from './src/main/ets/util/BrewNotesExtractor';
export { ReleaseIntelRepoResolver, ReleaseIntelTagFilter } from './src/main/ets/util/ReleaseIntelRepoResolver';
export {
  ReleaseIntelCard,
  ReleaseIntelBreakingChange,
  ReleaseIntelSecurityClaim,
  ReleaseIntelInput,
  ReleaseIntelDiff,
  ReleaseIntelVerdict,
  ReleaseIntelSnapshot,
  ReleaseIntelArchiveEntry,
  releaseIntelArchiveEntryOf,
  releaseIntelSnapshotFork,
} from './src/main/ets/model/ReleaseIntelModels';
export {
  RELEASE_INTEL_FEATURE,
  AI_PROMPT_VERSION_RI,
  AI_CACHE_TTL_RI_MS,
  RELEASE_INTEL_NOTES_MAX_CHARS,
  RELEASE_INTEL_ATOM_TIMEOUT_MS,
  RELEASE_INTEL_PREFS_STORE,
  RELEASE_INTEL_PREFS_KEY_IGNORED,
  RELEASE_INTEL_PREFS_KEY_PAUSED,
  RELEASE_INTEL_PAUSE_7D_MS,
  RELEASE_INTEL_PAUSE_30D_MS,
  RELEASE_INTEL_PAUSE_FOREVER_MS,
  RELEASE_INTEL_ARCHIVE_CAP,
  RELEASE_INTEL_CONFIDENCE_FULL,
  RELEASE_INTEL_CONFIDENCE_PARTIAL,
  RELEASE_INTEL_CONFIDENCE_NONE,
  RELEASE_INTEL_GAP_NONE,
  RELEASE_INTEL_GAP_REPO,
  RELEASE_INTEL_GAP_TAG,
  RELEASE_INTEL_GAP_NET,
  RELEASE_INTEL_GAP_NOTES,
  RELEASE_INTEL_SNAPSHOT_SEGMENT,
  RELEASE_INTEL_SNAPSHOT_CAP,
  RELEASE_INTEL_SNAPSHOT_TTL_MS,
} from './src/main/ets/constant/ReleaseIntelConstants';

// ------------------------------------------------------------------ 本机包（设备上的 brew 安装记录）

// 执行设备上的 `brew info --json=v2 --installed` 并把结果归一成三个集合。
// 失败分类在抛出的异常的 message 里（`BrewInstalledFailure` 的取值）。
export { BrewInstalledLoader, BrewInstalledFailure, BrewInstalledOutcome, BrewInstalledSets,
  BrewInstalledSnapshot } from './src/main/ets/service/BrewInstalledLoader';
export { BrewTaxonomy } from './src/main/ets/constant/BrewTaxonomy';
export { BrewInstalledParser } from './src/main/ets/util/BrewInstalledParser';
export type { BrewCaskDoc, BrewFormulaDoc, BrewInstalledDoc, BrewInstalledKegDoc } from './src/main/ets/model/BrewInstalledDoc';

// ---------------------------------------------------------------- Agent Skill（32 号功能点）

// `brew install/upgrade --dry-run` 输出解析（纯函数层）。Agent Skill 的预演与检查脚本共用同一份；
// 检查脚本按 tldr 的方式把本文件拷成 .mts 在 node 里跑，因此它保持零 import、字符串常量。
export { BrewDryRunParser, BrewDryRunItem, BrewDryRunResult } from './src/main/ets/util/BrewDryRunParser';

// `brew uses --installed` 输出解析（纯函数层）：卸载预演的反向依赖查询。
export { BrewUsesParser, BrewUsesResult, BREW_USES_NAME_RE } from './src/main/ets/util/BrewUsesParser';

// `brew config` 输出解析（纯函数层）：checkBrew 的版本与前缀抽取。
export { BrewConfigParser, BrewConfigResult } from './src/main/ets/util/BrewConfigParser';

// `brew info <name...>` 多包文本解析（纯函数层）：预演 sizes 补测的当前占用。
export { BrewInfoSizeParser, BrewInfoSize, BrewInfoSizeResult } from './src/main/ets/util/BrewInfoSizeParser';

// Skill 契约常量（specs/2026-11-22-agent-skill-spec.md §3）。skills/ 目录的入口脚本不引跨模块包，
// 那边另有逐字一致的本地副本，契约检查脚本核对两处与 SKILL.md 不漂移。
export {
  SKILL_BREW_QUICK_TIMEOUT_MS,
  SKILL_BREW_TIMEOUT_MS,
  SKILL_CAVEATS_MAX_CHARS,
  SKILL_ERR_INTERNAL,
  SKILL_ERR_INVALID_PARAMS,
  SKILL_ERR_NOT_FOUND,
  SKILL_FN_CHECK,
  SKILL_FN_CATEGORIES,
  SKILL_FN_DETAIL,
  SKILL_FN_LIST_INSTALLED,
  SKILL_FN_LIST_OUTDATED,
  SKILL_FN_PREVIEW,
  SKILL_FN_PREVIEW_UNINSTALL,
  SKILL_FN_PREVIEW_UPGRADE,
  SKILL_FN_PREVIEW_UPGRADE_ALL,
  SKILL_FN_QUERY,
  SKILL_FN_REQUEST,
  SKILL_FN_SEARCH,
  SKILL_FN_TRENDING,
  SKILL_FN_USAGE,
  SKILL_INFO_NAMES_LIMIT,
  SKILL_LIST_LIMIT,
  SKILL_NAME,
  SKILL_SCRIPT_PATH,
  SKILL_SEARCH_LIMIT,
  SKILL_TRENDING_LIMIT,
  SKILL_USAGE_LIMIT,
  SKILL_VERSION,
} from './src/main/ets/constant/SkillConstants';
