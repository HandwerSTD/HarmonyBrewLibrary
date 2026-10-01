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

// ——— 元数据索引（`BrewMetaSync`）：后台同步全量元数据，抽 token → desc，替代“逐条拉 desc”。

/** 开关。false 即完全退回“逐条 hydrate”的老路径（浏览集会跟着降级到前 N 个）。 */
export const BREW_META_SYNC: boolean = true;

/** 索引的独立存储 key。**严禁并入 `brew_live_data`**（那是“整份 doc ~5KB/条”的口径，1.3 万条≈65MB） */
export const BREW_META_INDEX_KEY: string = 'brew_meta_index';

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
 * 作用只有一个：让第二个 kind 不必排在一个慢下载后面。落盘由下载**真正结束**时触发
 * （见 `BrewMetaSync.syncKindWithBudget` 的“迟到落盘”）。
 *
 * 取 90s 的依据：上游健康时单文件实测 **21.7s**，所以正常情况不会触发；只有上游慢时才生效。
 * ⚠ 不要拿它当 `readTimeout` 用（见上）。
 */
export const BREW_META_SYNC_BUDGET_MS: number = 90000;

/**
 * 全量包的 `Last-Modified` 基准（kind → 值），条件请求用。
 *
 * 与 `brew_meta_index` 分开存：索引是**结果**，基准是**下次怎么问**，两者生命周期不同
 * （索引可以因格式变化被丢弃，基准仍有效）。
 */
export const BREW_META_STAMP_KEY: string = 'brew_meta_stamp';

/**
 * 可选自检：抽 200 个 token，把索引里的 desc 与单条 API 逐字比对并打日志。
 *
 * 默认关：它要多发 200 个请求，只应该在验证扫描器改动时开一次。
 */
export const BREW_META_VERIFY: boolean = false;

/**
 * 现网单条数据的**新鲜窗口**（不是“过期就重下”的 TTL）。
 *
 * 窗口内直接用缓存；超出窗口后**先探针、再条件请求**（见 BrewService.datasetProbe）：
 *   - 探针 304（数据集未变）→ 全部缓存续期，**0 字节**；
 *   - 数据集变了 → 对该 token 发 `If-None-Match`，304 也只需 0 字节。
 * 实测（curl）：两个条件请求都是 `code=304 bytes=0`，HEAD 探针 `200/304` 也是 0 字节。
 *
 * 所以窗口可以取得比“盲猜 TTL”短很多：官方 `Cache-Control: max-age=600`、数据按天生成，
 * 这里取 1 小时 —— 最多每小时花 2 次 HEAD（formula / cask 各一）就能确认全量数据是否变过。
 */
export const BREW_LIVE_FRESH_MS: number = 60 * 60 * 1000;

/** 数据集版本戳的存储 key（Last-Modified / ETag 基准，跨进程保留） */
export const BREW_LIVE_DATASET_KEY: string = 'brew_live_dataset';

/** 现网数据的 Preference 存储 key。2026-10 起 brew 只剩这一类存储（内置 mock 的 rawfile 链路已删） */
export const BREW_LIVE_STORAGE_KEY: string = 'brew_live_data';

/**
 * hydrate（把列表条目刷成现网值）的并发上限。
 *
 * 官网是 GitHub Pages + Fastly，单条 5 KB；并发 6 实测不会触发限流，
 * 同时也不会把页面的首屏时间拉长到不可接受（100 条约 2s，第二次走 TTL 缓存为 0）。
 */
export const BREW_HYDRATE_CONCURRENCY: number = 6;

/**
 * 一次页面加载最多花在 hydrate 上的时间。
 *
 * 超时不是失败：已拿到的值照常用，剩下的请求继续在后台跑并把结果写进 TTL 缓存，
 * 下一次进页面直接命中。这样“现网”不会变成“网差就打不开页面”。
 */
export const BREW_HYDRATE_TIMEOUT_MS: number = 6000;

/**
 * 目录（全量 token + 三张榜）的存储 key。
 *
 * 与 `BREW_LIVE_STORAGE_KEY`（单包文档缓存）分开存：两者生命周期完全不同 ——
 * 单包文档按 token 逐条过期，目录是**整批**一起生成的（按天）。
 */
export const BREW_CATALOG_STORAGE_KEY: string = 'brew_catalog';

/**
 * 目录的新鲜窗口。
 *
 * **2026-09-23 从 1h 调到 6h，并推翻了两条旧描述：**
 *   - 旧注释写“源站每天重新生成一次” —— **实测是每 ~5~10 分钟一代**
 *     （`Last-Modified` 在 5 分钟内从 `00:58:15` 变成 `01:38:38`）。
 *   - 旧注释写“超出窗口先条件请求，全 304 就 0 字节” —— 实测**条件请求几乎永不命中**：
 *     内容每 10 分钟变，而本窗口是小时级，基准必然对不上 → 每次都是全量下载。
 *     而且边缘 `Cache-Control: max-age=600`（10 分钟）比本窗口短得多，
 *     所以探针必然打在过期的边缘副本上 → 回源 → 实测 `catalog_fetch ms=17437`（设备）。
 *
 * 调大的理由：探针的成本是**用户实打实等的 17 秒**（Discover 整页实测 21.7s），
 * 而榜单最多旧 6 小时的代价用户感知不到 —— 它本来就每 10 分钟在变。
 * 6h 的含义：隔夜后第一次打开不再吃这个等待。
 *
 * 仍保留条件请求：它是**免费**的（未命中只是多一个被忽略的头），
 * 在“10 分钟内重复打开”这类场景下能省 358KB。
 */
export const BREW_CATALOG_FRESH_MS: number = 6 * 60 * 60 * 1000;

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
 * **降级**浏览集的请求预算：只在元数据索引**不可信**（`covered < BREW_INDEX_MIN_TRUST`，
 * 即首次安装 / 同步失败 / 断网 / 扫描口径变了）时生效。
 *
 * 索引可信时浏览集 = 目录 ∩ 索引、首屏零请求，这个常量**完全不参与**；它管的是另一件事：
 * 当 `desc` 只能逐条拉时，一次进页面只能支付这么多请求（前 100 个 × 单条 gzip 约 1.2KB
 * ≈ 120KB，并发 6 冷启动约 5s；之后走 TTL 缓存）。没有这道闸，索引不可用时会把 1.3 万
 * 个 token 全丢给 hydrate，超时批量返回，页面反而只剩零星几条。
 *
 * 为什么要保留降级而不是硬依赖索引：索引是后台下载的，首次启动必然“还没有”；
 * 那时页面必须仍然像今天一样能用（只是少一点）。
 */
export const BREW_BROWSE_HYDRATE_LIMIT: number = 100;

/**
 * 元数据索引的**可信度闸门**：某 kind 的索引至少覆盖这么多条目录行，才把索引当作
 * "上游有哪些包"的权威清单（从而走主路径：候选 = 目录 ∩ 索引、首屏零请求）。
 *
 * 为什么"非空 + 够一页"就够了，而不是用覆盖率比例（例如 `covered/all ≥ 0.9`）：
 * 一个 kind 的索引表是**原子地产出**的 —— `BrewMetaSync.syncKind()` 只在整份大文件扫完
 * 且 `pairs > 0` 时才返回新表，否则返回 `undefined` 让调用方保留旧表。所以不存在"半张表"，
 * 非空就意味着它是某次全量扫描的完整结果（只可能来自更早的一次同步，即已接受的 staleness）。
 *
 * 而**比例闸门会误伤 cask**：`cask.json` 有 2,645 条 `desc: null`，落盘时故意不写空串
 * （见 `brew-catalog-fullsync-spec.md` §4.6③），所以 cask 的覆盖率天然只有一半左右 ——
 * 用 0.9 会让 cask 永远走降级路径。
 *
 * 取 100（与 `BREW_BROWSE_HYDRATE_LIMIT` 同值但是**两个不同的概念**）：真出现
 * "表非空但覆盖率极低"（例如上游改了标识键导致只扫出几十条错配）时，此时"前 100 条 +
 * 逐条 hydrate"比"只显示这几十条"更有用，与改动前的行为一致。两个常量恰好同值，
 * 但改一个不必改另一个。
 */
export const BREW_INDEX_MIN_TRUST: number = 100;

/**
 * 负缓存时长：把一个"确认上游不存在"的 token 挡在逐条 hydrate 之外的时长。
 *
 * 目录来自 analytics（30d/90d/365d 安装量），会**保留历史上已下线/改名/弃用的包名**，
 * 而索引来自当前的 `formula.json` / `cask.json` —— 两者的差集里有相当一部分是幽灵 token：
 * 逐条拉必然 404，而 404 不进 `brew_live_data`（失败不缓存），于是**每轮页面重绘都要重打一遍**
 * （真机实测：一轮 94 次 404，且首屏被拖到 4.8s）。
 *
 * 只记确定性失败（404/410）：超时/断网这类瞬时失败不入负缓存，网络恢复后照常重试。
 * 定 6h 是为了“万一它真回来了”时不至于离线太久 —— 进程重启不影响（内存态），
 * 即每次启动最多重试一轮，成本可控。
 */
export const BREW_MISS_TTL_MS: number = 6 * 60 * 60 * 1000;

/**
 * 首页分类卡**卡内预览**的条数。超过这个数的大卡在底部给一行「查看全部」（进分类二级页）。
 *
 * 同时是数据层的 `hasMore` 判据与 UI 的截断口径 —— 两处必须同源：
 * UI 那边在 `BrewCategoryCardView`，数据层在 `BrewBrowseBuilder`，分开写就会漂成
 * 「预览装得下却给了查看全部」（或反之）。
 */
export const BREW_CATEGORY_PREVIEW_COUNT: number = 5;

/**
 * 浏览页拉 desc 的预算（**比 hydrate 的 6s 宽**）。
 *
 * 只在不降级路径上才用得上：索引就绪时页面一个单条请求都不发；索引不可用时才走 hydrate，
 * 而这批请求是**构页的输入**（分类要看 desc），所以宁可等也不能给出错分类的页面。
 *
 * 为什么必须单独给：分类要看 desc，所以这批单条请求是**构页的输入**，不是"锦上添花的刷新"。
 * 实测 100 条在 6s 预算下只到 53 条（单条中位 273ms、并发 6），剩下的 desc 为空会让关键词
 * 判不出来 → 全被塞进兜底分类，页面看起来正常但**分类是错的**。宁可等（15s 上限，
 * 且 TTL 缓存命中后为 0）也不能给出错分类的页面。
 */
export const BREW_BROWSE_HYDRATE_MS: number = 15000;

/**
 * 在途去重的 **join 时效上限**：超过它就不再复用那个未完成的构建，改为新建一个。
 *
 * 为什么需要它：`hydrate` 的截止时间只在**每个 worker 取下一个 token 之前**检查，而它最后
 * `Promise.all` 等所有 lane —— 若某个 `BrewHttp.request` 永不 settle（平台层面），整个构建就永不 settle。
 * 没有这道守卫的话，那个死 Promise 会**永久**留在在途字段里，之后每次构页（含重进页签、
 * 失败页的重试按钮）都 join 它 → 页面永久停在 LOADING 直到重启 App。这比改动前**更糟**
 * （改动前只是慢，重试会重新发起）—— 所以它是本次新增去重所欠下的债，必须当场还。
 *
 * 取值 = 浏览页 hydrate 预算 + 两个单条请求超时（`BrewHttp.TIMEOUT_DEFAULT = 10000`：
 * connect / read 各一次）—— 正常情况下早就该结束了。
 */
export const BREW_PAGE_INFLIGHT_JOIN_MS: number = BREW_BROWSE_HYDRATE_MS + 20000;

/** 聚合单文件最大 ~3.9 MB（365d）、gzip 后 ~750 KB，给足读取时间 */
export const BREW_CATALOG_TIMEOUT_MS: number = 30000;

// 2026-10：内置 mock 数据与其 trigger 枚举（`common` 的 `TriggerEnums` / `MockRequest`）已整条删除，
// 本层不再有「内置快照」这种数据来源：成员由目录 + 词表现算，详情由现网单条渲染，
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
