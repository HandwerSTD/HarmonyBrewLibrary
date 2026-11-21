/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

/** 官方源的稳定 id。恒存在、不可删、baseUrl 固定，且恒为注册表第 0 项 */
export const BREW_OFFICIAL_SOURCE_ID: string = 'official';

/**
 * 官方 API 基地址。用户新增的源都是它的镜像（必须提供同样的 /api 目录结构）。
 *
 * ⚠ 容量：`formula.json` / `cask.json` 实测 **32.4 MB / 18.9 MB**（gzip 5.29 MB / 2.05 MB），
 * **页面加载路径严禁拉取**（见 docs/brew-api-design.md §7）—— 那里只能走单条 `/formula/<token>.json`。
 * 全量包只给后台同步用（`BrewMetaSync`）。
 */
export const BREW_OFFICIAL_BASE_URL: string = 'https://formulae.brew.sh/api';

/** Homebrew 上游 API 方言；内置源与存量源均使用此形状 */
export const BREW_DIALECT_UPSTREAM: string = 'upstream';

/** Harmonybrew 单文件 JWS 目录方言 */
export const BREW_DIALECT_HARMONYBREW: string = 'harmonybrew';

/**
 * 内置 Harmonybrew 源的稳定 id。与官方源一样恒存在、不可删、baseUrl 固定，但**默认不启用**
 * （`activeId` 初始为官方源），且只在能执行 brew 的产品（pc_acl）上展示。
 */
export const BREW_HARMONYBREW_SOURCE_ID: string = 'harmonybrew';

/**
 * 内置 Harmonybrew 源的 API 基地址。
 *
 * ⚠ 它**不是**官方源的镜像：站点根下只有逐日下载统计，`/api` 下只有一份按 bottle tag 分区的
 * JWS 目录，没有 per-token 端点、cask 与 analytics（见 docs/brew-api-design.md §7.5.2）。
 */
export const BREW_HARMONYBREW_BASE_URL: string = 'https://harmonybrew.atomgit.com/api';

/** 探测 Harmonybrew 时先尝试的 bottle tag；探测成功后会使用响应里的真实 tag。也是内置 Harmonybrew 源的初始 tag */
export const BREW_HARMONYBREW_DEFAULT_TAG: string = 'arm64_ohos';

/**
 * Harmonybrew 按日下载统计路径模板，调用时把 YYYYMMDD 替换为 UTC 日期键。
 *
 * ⚠ **这是站点根相对路径，必须用 `BrewSourceUrl.originJoin` 拼，不能用 `join`。**
 * 本源的 baseUrl 是 `https://harmonybrew.atomgit.com/api`，而 stats 在
 * `https://harmonybrew.atomgit.com/stats/…` —— 用 `join` 会拼成 `/api/stats/…`，实测 404
 * （真机现场：`at=latest=today-1 rejected code=404`，而宿主机 curl 同一日期是 200）。
 */
export const BREW_HARMONYBREW_STATS_PATH_TEMPLATE: string = '/stats/stats-YYYYMMDD.json';

/** 目录当前窗口：最近 30 天 */
export const BREW_HARMONYBREW_STATS_CURRENT_DAYS: number = 30;

/** 目录基线窗口：当前窗口之前的 60 天 */
export const BREW_HARMONYBREW_STATS_PRIOR_DAYS: number = 60;

/** 每次目录刷新读取的日历窗口总天数（30 + 60 = 90） */
export const BREW_HARMONYBREW_STATS_TOTAL_DAYS: number =
  BREW_HARMONYBREW_STATS_CURRENT_DAYS + BREW_HARMONYBREW_STATS_PRIOR_DAYS;

/** 缺失日文件的并发数；对第三方域名保持克制 */
export const BREW_HARMONYBREW_STATS_CONCURRENCY: number = 6;

/** Harmonybrew 的 JWS 目录路径。tag 来自服务端 payload，不固化在端点里 */
export function BREW_HARMONYBREW_CATALOG_PATH(tag: string): string {
  return `/internal/packages.${tag}.jws.json`;
}

/** Range 探测读取的字节数，足够确认 JWS 信封、bottle tag 与 JSON content type */
export const BREW_HARMONYBREW_RANGE_PROBE_BYTES: number = 1024;

/**
 * 每个源的 Preferences store 名前缀，实际名 = `brew_src_<sourceId>`。
 *
 * 用独立 store 而不是「共享 store + 键前缀」：Preferences 是「一个文件一个实例、整份加载、整份落盘」，
 * 共享 store 会让加载/flush/删除的成本随**源数量**线性增长（3 个源时每次 flush 要重写 8MB+）。
 * 独立 store 还让「删源」退化成删文件，且**漏改调用点会编译不过**，不会静默串源。
 */
export const BREW_SOURCE_STORE_PREFIX: string = 'brew_src_';

/** 源注册表（`BrewSourceRegistry`）在主 store 里的键。只有几百字节，不值得单独开 store */
export const BREW_SOURCE_REGISTRY_KEY: string = 'brew_sources';

/** 运行期健康记录（`Record<sourceId, BrewSourceHealthRecord>`）在主 store 里的键 */
export const BREW_SOURCE_HEALTH_KEY: string = 'brew_source_health';

/** 探测超时。单条文档 ~5KB，8s 足够区分「慢」与「不通」 */
export const BREW_SOURCE_PROBE_TIMEOUT_MS: number = 8000;

/** 探测用的 token。选 `wget` 是因为它长期存在、体积小、且在任何镜像上都该有 */
export const BREW_SOURCE_PROBE_TOKEN: string = 'wget';

/** baseUrl 长度上限（防手滑粘贴一坨东西） */
export const BREW_SOURCE_MAX_URL_LEN: number = 256;

/** 源名长度上限 */
export const BREW_SOURCE_MAX_NAME_LEN: number = 40;

/**
 * 自检开关。**默认关**。
 *
 * 与 `BREW_META_VERIFY` 同一模式：编译通过不等于行为正确，而本项目不用 ohosTest，
 * 所以需要一条「开一次、看日志、关掉」的诊断通道。开启后 `BrewSourceDiagnostics.run()`
 * 会在进程启动时跑一遍：注册表不变量、会话快照、URL 校验用例、探测分类用例、
 * 以及用一次性 throwaway 源走完 stats → clear → drop（**不碰真实数据**）。
 * ⚠ 注意：自检里的 clear 用例**跨了** `persistNow()`，所以「clear 之后重新读」那一条同时是持久化断言；
 * 但真正的「跨进程」验证（杀进程后重开）只能由设备侧做。
 */
export const BREW_SOURCE_VERIFY: boolean = false;
