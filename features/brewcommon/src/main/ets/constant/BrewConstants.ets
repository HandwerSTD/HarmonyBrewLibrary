/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import {
  BreakpointType,
  CommonConstants,
  GlobalInfoModel,
  HdsUtil,
  StorageKey,
} from '@ohos/common';
import { BrewKind } from '../model/BrewModels';
import { SHELL_TIMEOUT_MAX_MS } from '@ohos/pcnative';

export { BrewKind };

// ---------------------------------------------------------------- 数据来源

// 2026-10：内置 brew 数据快照（`rawfile/mockdata/*.json`）与 Mock 请求链路已整条删除，
// 数据只来自设备端目录（聚合端点）与现网单条。「走不走网络 / 用哪个源」的开关随之取消：
// 用哪个源是 `BrewSource*` 的事（见 docs/superpowers/specs/2026-09-23-brew-multi-source-design.md），
// 走不走网络由取数失败时的空态策略决定，不再是常量。

// ---------------------------------------------------------------- 性能打点开关

/**
 * 冷启动分段打点的总开关。**默认关**。
 *
 * 为什么要留一个开关而不是测完就删：这一轮（2026-09-22）的实测结论是"瓶颈在请求语义，
 * 不在 I/O"，而这类结论**会随数据变化失效**（上游一改口径，`dropped` 的量级就变）。
 * 下次回归只需把它改成 `true` 重新量一遍，不用重写探针。
 *
 * 打开后会出现 `[perf]` 前缀的日志与 `browse … built` 行尾的分段耗时；
 * 覆盖 `BrewService.ensureCatalog`、`BrewMetaSync.ensureIndex`、`BrewBrowseBuilder.formulaPage/caskPage`。
 * 冷启动的起点用 `PcAbility` 的 `Ability onCreate` 生命周期日志（hilog 时间戳即可做差），
 * 终点用 `BrewFormulaHomeViewModel` 已有的 `loadFormulaPage success` 行 —— 这两处**不需要**探针。
 */
export const BREW_PERF_TRACE: boolean = false;

/**
 * 「这次加载算慢」的阈值（毫秒）。超过它，`BrewLoadLog` 会额外补一行 **warn**。
 *
 * 为什么要有这个阈值：冷启动的验收口径是「数据进 state ≤ 1100ms」（见
 * `docs/superpowers/specs/2026-09-22-brew-coldstart-design.md` §10 A1），
 * 所以任何**单个**数据类型的加载超过 2s 就已经单独吃掉了整个预算 ——
 * 这种量级不该埋在 info 行里靠人比数字发现。
 *
 * 与 `BREW_PERF_TRACE` 无关：`[load]` 行是**常驻**打点，不跟着那个开关走。
 */
export const BREW_LOAD_SLOW_MS: number = 2000;

/*
 * （原 `BREW_NET_NOTICE_MIN_INTERVAL_MS = 30000` 已删，2026-09-23）
 *
 * 提示从 Toast 换成 HDS SnackBar 后，去重模型从「时间窗」变成「常驻 + 主动撤掉」：
 * `BrewNetNotice` 内部的 `shown` 布尔量天然表达“同一时刻只提示一件事”，
 * 而 `settle()` 之后再次 `willFetch()` 会正常重新弹 —— 语义比时间窗更贴合意图。
 * 详见 `docs/superpowers/specs/2026-09-22-brew-fetch-toast-design.md` §13.6。
 */

// ——— 描述片（`BrewMetaSync` → `BrewTable`）：后台拉全量包，只抽 token → desc。

/** 全量元数据请求的响应体上限。http 默认只有 5MB，而 formula.json 的 gzip 体就有 5.29MB。 */
export const BREW_META_MAX_LIMIT: number = 100 * 1024 * 1024;

/**
 * 全量元数据的**连接**超时。
 *
 * 必须与读取超时分开：一开始两者用同一个值，结果“连不上”会把 10 分钟预算全耗尽、
 * 日志只剩一句 `2300028 Operation timeout` —— 分不出是“连不上”还是“下得慢”。
 * 建连本该是秒级的事，给 10s 就够，失败快、日志也能直接指向原因。
 */
export const BREW_META_CONNECT_TIMEOUT_MS: number = 10000;

/**
 * 全量元数据的**读取**超时。
 *
 * 一次拿 32MB（解压后，压缩体 5.29MB）。
 *
 * ⚠ **它必须远大于 `BREW_META_SYNC_BUDGET_MS`（等待预算），否则“迟到落盘”不成立。**
 * 第一版修复把两者写成同一个值（90s），真机验证立刻暴露：下载在 90s 被 `readTimeout`
 * **中止**（`meta sync [formula]: ok=false code=0 text=0B download=90024ms`），
 * 根本没有“迟到的结果”可落 —— 于是索引永远刷不新，比改动前更差
 * （旧代码靠一直等，`total=798998ms` 后确实成功了）。
 *
 * 实测上游慢时单文件要 **578s**，所以保留 10 分钟：它只是防止连接彻底挂死，
 * 不是“我们愿意等多久”—— 后者是 `BREW_META_SYNC_BUDGET_MS` 的事。
 */
export const BREW_META_READ_TIMEOUT_MS: number = 600000;

/**
 * 一个 kind 的**等待预算**（不是超时）：超过它就先开始下一个 kind，**不丢弃结果**。
 *
 * 作用只有一个：让第二个 kind 不必排在一个慢下载后面。写入由下载**真正结束**时触发
 * （见 `BrewMetaSync.startKind` 的“迟到写入”）。
 *
 * 取 90s 的依据：上游健康时单文件实测 **21.7s**，所以正常情况不会触发；只有上游慢时才生效。
 * ⚠ 不要拿它当 `readTimeout` 用（见上）。
 */
export const BREW_META_SYNC_BUDGET_MS: number = 90000;

/**
 * 可选自检：抽 200 个 token，把描述片里的 desc 与单条 API 逐字比对并打日志。
 *
 * 默认关：它要多发 200 个请求，只应该在验证扫描器改动时开一次。
 */
export const BREW_META_VERIFY: boolean = false;

/**
 * 现网单条数据的**新鲜窗口**（不是“过期就重下”的 TTL）。
 *
 * 窗口内直接用；超出后带 `If-Modified-Since` 发条件请求，304 就 0 字节续期。
 * 官方 `Cache-Control: max-age=600`、数据按天生成，这里取 1 小时 ——
 * 一小时里一个包最多多付一次 0 字节的条件请求。
 */
export const BREW_LIVE_FRESH_MS: number = 60 * 60 * 1000;

/**
 * 单条文档缓存的 key。条目是 `{ts, schemaVersion, lastModified, data}` ——
 * `lastModified` 跟着条目走，所以仍然能用 `If-Modified-Since` 拿 304 的 0 字节续期。
 *
 * 与 `brew_detail_view`（归一后的详情）同 store、不同 key：前者按 `kind_token` 索引、
 * 存原始文档；后者按 componentId 索引、存 UI 直接消费的视图数据。
 */
export const BREW_DETAIL_CACHE_KEY: string = 'brew_detail_cache';

/** 归一后详情的缓存 key（按 componentId 索引）。现网失败时的回落来源 */
export const BREW_DETAIL_VIEW_KEY: string = 'brew_detail_view';

/** 聚合单文件最大 ~3.9 MB（365d）、gzip 后 ~750 KB，给足读取时间 */
export const BREW_CATALOG_TIMEOUT_MS: number = 30000;

/**
 * 包表的存储 key。**本层唯一的 brew 缓存键**（原先是六个：
 * `brew_catalog` / `brew_meta_index` / `brew_meta_stamp` / `brew_live_data` /
 * `brew_live_dataset` / `brew_detail_page_data`，后者并入详情缓存）。
 *
 * 表分两片：安装量片（4 个聚合端点）与描述片（两个全量包），各自记条件请求基准、
 * 各自标记新鲜度，一片失败不牵连另一片。浏览集成员规则是 `vol` 的键 ∩ `desc` 的键。
 */
export const BREW_TABLE_STORAGE_KEY: string = 'brew_table';

/**
 * 表的形状版本。**结构一变就 +1**，读盘时版本对不上整表按空处理。
 * 留着是为了防止「旧版留了某个字段、新版直接 `Object.keys` 它」那类崩溃。
 */
export const BREW_TABLE_SCHEMA_VERSION: number = 1;

/**
 * 安装量片的新鲜窗口。
 *
 * 2026-09-23 从 1h 调到 6h，并推翻了两条旧描述：
 *   - 旧注释写“源站每天重新生成一次” —— **实测是每 ~5~10 分钟一代**
 *     （`Last-Modified` 在 5 分钟内从 `00:58:15` 变成 `01:38:38`）。
 *   - 旧注释写“超出窗口先条件请求，全 304 就 0 字节” —— 实测**条件请求几乎永不命中**：
 *     内容每 10 分钟变，而本窗口是小时级，基准必然对不上 → 每次都是全量下载。
 *     而且边缘 `Cache-Control: max-age=600`（10 分钟）比本窗口短得多，
 *     所以条件请求必然回源 → 设备实测 `catalog_fetch ms=17437`。
 *
 * 调大的理由：探针的成本是**用户实打实等的十几秒**，而榜单最多旧 6 小时的代价用户感知不到。
 * 6h 的含义：隔夜后第一次打开不再吃这个等待。
 *
 * 仍保留条件请求：它是**免费**的（未命中只是多一个被忽略的头）。
 */
export const BREW_VOL_FRESH_MS: number = 6 * 60 * 60 * 1000;

/**
 * 描述片的新鲜窗口。12 小时。
 *
 * 上游的两个全量包按天生成，所以一次进程启动最多一次条件请求就该够了；
 * 取 12 小时是给「用户把应用开着过夜」留余量 —— 命中时 0 字节，
 * 没命中也只是重下一次（gzip 合计 7.3 MB）。
 */
export const BREW_DESC_FRESH_MS: number = 12 * 60 * 60 * 1000;

// ——— 本机包（`BrewInstalledLoader`）：执行设备上的 brew 命令，读已安装列表。

/**
 * 本机包快照的新鲜窗口（不是「过期就重读」的 TTL，窗口内根本不执行命令）。
 *
 * 取 10 分钟的依据是「读取一次的代价」与「数据变化的来源」：读取要拉起 vendored Ruby
 * （首跑 2–3 秒），而本机包只在有人装 / 升 / 卸时变化，其中由本应用发起的变化在命令结束后
 * 会主动让快照失效，剩下的只有用户在终端里直接操作 brew 这一种 —— 10 分钟的陈旧窗口对它可接受。
 *
 * 超出窗口时不阻塞页面：`loadSets()` 先返回旧快照，再在后台刷新一次。
 */
export const BREW_INSTALLED_FRESH_MS: number = 10 * 60 * 1000;

/**
 * 本机包快照的存储键。
 *
 * 放在全局 store（`PreferenceManager`）而不是某个 brew 缓存键旁边：本机包是**设备状态**，
 * 不属于任何数据源，清空某个源的缓存不应该把它一起删掉。冷启动先用它立刻显示数量。
 */
export const BREW_INSTALLED_SNAPSHOT_KEY: string = 'brew_installed_snapshot';

/**
 * 快照的形状版本。**结构或口径一变就 +1**，读盘时版本对不上整份按「没有快照」处理。
 *
 * 盘上只存 `installed` 一个集合，`outdated` 与 `updated` 读时派生。
 *
 * 由 1 升到 2（2026-10-06）：版本 1 的盘上快照只有 formula（解析器当时丢弃 cask 条目），
 * 沿用会让升级后的首次启动先显示一份缺 cask 的列表，等下一次读取才补上。
 */
export const BREW_INSTALLED_SNAPSHOT_VERSION: number = 2;

/**
 * 本机包命令的超时。
 *
 * 30 秒是上限：brew 启动要拉起 vendored Ruby，首跑可能到秒级；
 * 实测值在设备上量过之后按需调整（见 spec §9）。
 */
export const BREW_INSTALLED_TIMEOUT_MS: number = 30000;

// ——— 写命令（`BrewCommandRunner`）：单飞执行一条 brew 写命令，流式显示输出，可中断。

/**
 * 流式输出的轮询周期。
 *
 * 取 200ms 是为了与界面刷新节奏一致：一次轮询把到的新输出合成一批行再渲染，
 * 既避免每一小段输出都触发一次渲染，也让用户看到的是连续成行的日志而不是逐字跳动。
 */
export const BREW_COMMAND_POLL_MS: number = 200;

/**
 * 日志区保留的行数上限。
 *
 * 超出时丢弃最旧的行并在日志区顶部累计「已省略前 N 行」。升级一次的真实输出量远低于这个上限，
 * 它只是防止一条刷屏的命令把内存与渲染拖垮。
 */
export const BREW_COMMAND_LOG_MAX_LINES: number = 1000;

/**
 * 中断的宽限期。
 *
 * 中断发出后这段时间内「中断」按钮禁用、状态显示「正在中断…」；到点仍在运行就允许强制终止。
 * 留这段时间是因为 brew 的 Ruby 层收到 SIGINT 后可能先删半成品再退出，
 * 立刻强杀会把它的清理动作打断。
 */
export const BREW_COMMAND_INTERRUPT_GRACE_MS: number = 5000;

/**
 * 写命令的超时。与执行通道的上限同值。
 *
 * 这里它是「进程完全没有进展」的兜底，不是执行时长限制：命令有可见输出与「中断」入口，
 * 用户随时能结束它；一次升级要下载并装上多个包，设备上还可能从源码构建，不能按分钟算。
 */
export const BREW_COMMAND_TIMEOUT_MS: number = SHELL_TIMEOUT_MAX_MS;

/** 每张榜展示的条数（与 `check_algo.py` 的榜口径、`brew-discover-algo.md` 一致） */
export const BREW_CATALOG_TOP_N: number = 10;

/**
 * 每张榜落盘的条数（> TOP_N）。
 *
 * 留冗余是因为「榜上的包必须有内置详情才能点进去」——join 过滤掉没有本地 id 的条目后
 * 还要能把榜补满到 TOP_N。留多少直接决定补位能力：40 条是实测够用的量。
 */
export const BREW_CATALOG_KEEP: number = 40;

/**
 * 首页分类卡**卡内预览**的条数。超过这个数的大卡在底部给一行「查看全部」（进分类二级页）。
 *
 * 同时是数据层的 `hasMore` 判据与 UI 的截断口径 —— 两处必须同源：
 * UI 那边在 `BrewCategoryCardView`，数据层在 `BrewBrowseBuilder`，分开写就会漂成
 * 「预览装得下却给了查看全部」（或反之）。
 */
export const BREW_CATEGORY_PREVIEW_COUNT: number = 5;

// 2026-10：内置 mock 数据与其 trigger 枚举（`common` 的 `TriggerEnums` / `MockRequest`）已整条删除，
// 本层不再有「内置快照」这种数据来源：成员由包表 + 词表现算，详情由现网单条渲染，
// Discover 的榜骨架在代码里构造（`BrewRepository.emptyDiscoverPage`）。

/** 分类 key。与 mockgen/categories.json、页面 JSON 的 categoryKey 一一对应。 */
export enum FormulaCategoryKey {
  TERMINAL = 'terminal',
  DEVTOOLS = 'devtools',
  NETWORK = 'network',
  DATA = 'data',
  CLOUDNATIVE = 'cloudnative',
  MEDIA = 'media',
  AI = 'ai',
  SYSTEM = 'system',
}

export enum CaskCategoryKey {
  DEVIDE = 'devide',
  BROWSER = 'browser',
  PRODUCTIVITY = 'productivity',
  COMM = 'comm',
  DESIGN = 'design',
  AV = 'av',
  SYSTEMTOOL = 'systemtool',
  AIVM = 'aivm',
}

/**
 * 分类中文名映射。
 * 中文文案必须走 string.json（zh_CN），不落进 mock JSON —— 避免中英混排从数据层漏进 UI。
 */
export const FORMULA_CATEGORY_NAME: Record<string, Resource> = {
  'terminal': $r('app.string.brew_cat_formula_terminal'),
  'devtools': $r('app.string.brew_cat_formula_devtools'),
  'network': $r('app.string.brew_cat_formula_network'),
  'data': $r('app.string.brew_cat_formula_data'),
  'cloudnative': $r('app.string.brew_cat_formula_cloudnative'),
  'media': $r('app.string.brew_cat_formula_media'),
  'ai': $r('app.string.brew_cat_formula_ai'),
  'lib': $r('app.string.brew_cat_formula_lib'),
  'system': $r('app.string.brew_cat_formula_system'),
};

export const CASK_CATEGORY_NAME: Record<string, Resource> = {
  'devide': $r('app.string.brew_cat_cask_devide'),
  'browser': $r('app.string.brew_cat_cask_browser'),
  'productivity': $r('app.string.brew_cat_cask_productivity'),
  'comm': $r('app.string.brew_cat_cask_comm'),
  'design': $r('app.string.brew_cat_cask_design'),
  'av': $r('app.string.brew_cat_cask_av'),
  'systemtool': $r('app.string.brew_cat_cask_systemtool'),
  'aivm': $r('app.string.brew_cat_cask_aivm'),
};

/**
 * 分类图标（HDS Symbol）。分类卡在没有包图标时用它兜底。
 *
 * 必须是 `Resource` 而不是 symbol 名的字符串：ArkTS 的 `$r()` 只接受编译期字面量，
 * 无法用运行时字符串拼出 `sys.symbol.*`，因此这里直接存 `$r()` 结果。
 *
 * 下面每个名字都是**实测验证过的**（写错会在 `CompileArkTS` 报 `Unknown resource name`），
 * 不是照搬 SF Symbols 猜的 —— 本项目实测：`pc` / `compass` / `message` / `magnifyingglass`
 * 有效，而 `laptopcomputer` / `safari` / `bubble` / `terminal` 无效。
 *
 * 注意 `ohos_` 前缀不统一：media 用 `ohos_photo`，而 data 用裸名 `externaldrive`。
 */
export const FORMULA_CATEGORY_SYMBOL: Record<string, Resource> = {
  'terminal': $r('sys.symbol.code'),
  'devtools': $r('sys.symbol.hammer_fill'),
  'network': $r('sys.symbol.wifi'),
  'data': $r('sys.symbol.externaldrive'),
  'cloudnative': $r('sys.symbol.cloud'),
  'media': $r('sys.symbol.ohos_photo'),
  'ai': $r('sys.symbol.lightbulb'),
  'lib': $r('sys.symbol.book_pages'),
  'system': $r('sys.symbol.gearshape'),
};

export const CASK_CATEGORY_SYMBOL: Record<string, Resource> = {
  'devide': $r('sys.symbol.pc'),
  'browser': $r('sys.symbol.compass'),
  'productivity': $r('sys.symbol.list_checkmark'),
  'comm': $r('sys.symbol.message'),
  'design': $r('sys.symbol.paintbrush'),
  'av': $r('sys.symbol.play_circle'),
  // 非 fill 版（需求方指定）：分类图标一律用线性版，**实心版留给左侧页签**
  // （`TabBarModel` 的 formulae 页签仍是 `wrench_and_screwdriver_fill`）。
  // 这两个名字都在 SDK 符号表里实测存在。
  'systemtool': $r('sys.symbol.wrench_and_screwdriver'),
  'aivm': $r('sys.symbol.bolt'),
};

/** 按包类型取分类名映射 */
export function getCategoryNameMap(kind: string): Record<string, Resource> {
  return kind === BrewKind.CASK ? CASK_CATEGORY_NAME : FORMULA_CATEGORY_NAME;
}

/** 按包类型取分类图标映射 */
export function getCategorySymbolMap(kind: string): Record<string, Resource> {
  return kind === BrewKind.CASK ? CASK_CATEGORY_SYMBOL : FORMULA_CATEGORY_SYMBOL;
}

/** 分类 key 列表，顺序与 mockgen/categories.json 一致 */
export const FORMULA_CATEGORY_ORDER: string[] = ['terminal', 'devtools', 'network', 'data', 'cloudnative', 'media', 'ai', 'lib', 'system'];
export const CASK_CATEGORY_ORDER: string[] = ['devide', 'browser', 'productivity', 'comm', 'design', 'av', 'systemtool', 'aivm'];

/**
 * chips 行挂在标题栏 `bottomBuilder` 上的高度。
 *
 * 样例页 PracticesView 同样取 `NAVIGATION_HEIGHT`（56vp），这里与它保持一致。
 * 这个值必须与各页 `bottomBuilder.height` 用的是同一个常量 ——
 * 标题栏是浮层，内容要靠下方 `brewTitleBarTotalHeight()` 手动让位，
 * 两处不一致就会出现「chips 盖住第一张卡」或「内容上方多一条空白」。
 */
export const BREW_CHIP_BAR_HEIGHT: number = CommonConstants.NAVIGATION_HEIGHT;

/**
 * chip 栏自己的左右内缩。
 *
 * 栏内 chips 的左右留白与栏右侧常驻 chip 的右内缩共用这一个值 —— 各写一份会让同一行里的
 * 左右留白不一致。
 *
 * 为什么需要它：标题栏 `bottomBuilder` 的底区是整宽的，chip 栏自己的左右内缩就是这一行
 * 唯一的左右留白（隐藏 chip 不补右内缩时会贴到窗口右边缘）。所以两处必须用同一个值。
 */
export function brewChipBarHorizontalInset(globalInfo: GlobalInfoModel): Length {
  return new BreakpointType<Length>({
    sm: $r('sys.float.padding_level6'),
    md: $r('sys.float.padding_level12'),
    lg: $r('sys.float.padding_level16'),
  }).getValue(globalInfo.widthBreakpoint);
}

/**
 * 内容区需要为标题栏让出的高度（顶部）—— 公式只在这里定义一次。
 *
 * `hasChipsRow` 表达「标题栏底部有没有挂 chips 行」：chips 挂在标题栏的 `bottomBuilder` 上，
 * 也算标题栏的高度。标题栏模糊的区间起点要与这个数对齐 —— 两者一旦不一致，就会出现
 * 「内容已经钻到标题栏下面了但模糊还没开始」（用户说的空行程）或反之（来不及糊）。
 * 所以 `BrewTitleBar` 里的模糊区间也调这个函数，而不是另写一份 `statusBar + NAVIGATION_HEIGHT`。
 */
export function brewContentTopInset(statusBarHeight: number, hasChipsRow: boolean): number {
  return statusBarHeight + CommonConstants.NAVIGATION_HEIGHT + (hasChipsRow ? BREW_CHIP_BAR_HEIGHT : 0);
}

/**
 * 标题栏（含 chips 行）的总高度，即内容区顶部需要让位的距离。
 *
 * 为什么必须手动让位：`HdsNavDestination` 开了 `ignoreLayoutSafeArea([SYSTEM], [TOP])`，
 * 且标题栏是**浮层**，不会把内容顶下去 —— 组件页与 Formulae 页是靠 banner 区块撑出
 * 这段空间的（`BaseHomeViewModel.changeBannerHeight()` 里
 * `statusBarHeight + NAVIGATION_HEIGHT + SPACE_8`）。brew 的页签页与详情页都没有
 * banner（`bannerHeight` 被覆写为 0），所以只能显式补。
 *
 * 组成：
 *   statusBarHeight        —— 状态栏
 *   NAVIGATION_HEIGHT      —— 标题行
 *   BREW_CHIP_BAR_HEIGHT   —— bottomBuilder 里的 chips 行
 *
 * 保留这个名字是因为调用点多（两个页签页 + 两个二级页），实现与 `brewContentTopInset(_, true)`
 * 完全相同 —— 不要再抄一份公式出来。
 */
export function brewTitleBarTotalHeight(statusBarHeight: number): number {
  return brewContentTopInset(statusBarHeight, true);
}

/**
 * brew 列表页内容的左右边距。
 *
 * 抽到这里的理由与 chips / 常量相同：**Formulae 与 Casks 两个页签的边距必须一致** ——
 * 它们是并列的页签，边距不同会让切换页签时内容左右跳动。原先只有 Casks 有这段
 * （`contentLeft()` / `contentRight()`），Formulae 一个都没有：左右间距只设了 `columnsGap`，
 * 那是列与列之间，与窗口边缘无关，于是最左最右的卡片直接贴边。
 *
 * lg 档的左侧比右侧大，是为了避开左上角的 tab bar / 侧边栏：
 * 侧边栏布局或新材质下内容已经从侧边栏右侧开始，不必再让；否则要让出 TAB_BAR_WIDTH。
 */
export function brewPageContentLeft(globalInfo: GlobalInfoModel): Length {
  return new BreakpointType<Length>({
    sm: $r('sys.float.padding_level8'),
    md: $r('sys.float.padding_level12'),
    lg: (HdsUtil.isSupportNewMaterialApi() || AppStorage.get<boolean>(StorageKey.IS_SIDEBAR_LAYOUT)) ?
      CommonConstants.SPACE_32 : CommonConstants.SPACE_32 + CommonConstants.TAB_BAR_WIDTH,
  }).getValue(globalInfo.widthBreakpoint);
}

export function brewPageContentRight(globalInfo: GlobalInfoModel): Length {
  return new BreakpointType<Length>({
    sm: $r('sys.float.padding_level8'),
    md: $r('sys.float.padding_level12'),
    lg: $r('sys.float.padding_level16'),
  }).getValue(globalInfo.widthBreakpoint);
}

/**
 * 搜索结果一次上屏的条数上限。
 *
 * 归属说明：它决定的是**数据层返回多少行**（`BrewSearchModel` 里用它 `slice`），
 * 所以必须待在 brewcommon；brewsearch 的 `BrewSearchConstants` 只放 UI 侧的东西
 * （死写词组、防抖、几何）。放在 brewsearch 会让 brewcommon → brewsearch 成环。
 */
export const BREW_SEARCH_LIMIT: number = 50;
