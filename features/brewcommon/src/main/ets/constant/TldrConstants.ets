/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

/**
 * tldr 用法示例的取数常量。
 *
 * 全部口径以 docs/superpowers/specs/2026-11-22-tldr-usage-examples-spec.md §3 / §5 为准；
 * 路径结构与分支名经 2026-11-22 探针实测（记录在该 spec §3.1）。
 */

/** tldr 的日志 tag。G1/G7/G8/G9 的可观测证据都按这个前缀打 */
export const TLDR_LOG_TAG: string = '[tldr]';

/**
 * 落盘缓存 TTL（14 天）。上游内容按月级变化，14 天的陈旧窗口对「抄命令」这个用途
 * 完全可接受；过期不意味着失效 —— stale-while-revalidate 会先展示旧值再后台刷新（G8）。
 */
export const TLDR_TTL_MS: number = 14 * 24 * 60 * 60 * 1000;

/**
 * 404 负缓存 TTL（24 小时，G9）。jsDelivr 实测对 404 响应
 * `Cache-Control: no-cache, no-store, must-revalidate`（CDN 不负缓存），
 * 所以这个窗口必须由本地自己实现：token 没有对应页面的结论（如 ripgrep → rg）
 * 在 24h 内不再重复请求。
 */
export const TLDR_NEG_TTL_MS: number = 24 * 60 * 60 * 1000;

/** 单页请求的超时。单页 markdown 只有几 KB，10s 与详情页其它请求同档 */
export const TLDR_HTTP_TIMEOUT_MS: number = 10000;

/** 渠道标识（日志与 meta 记录用） */
export const TLDR_CHANNEL_JSDELIVR: string = 'jsdelivr';
export const TLDR_CHANNEL_GITHUB: string = 'github';

/**
 * 渠道 URL 基址（不含页面路径）。路径模板与分支名经 2026-11-22 探针实测
 * （spec §3.1）：`<基址>/<pages.zh|pages>/<平台>/<token>.md`，分支 `main`。
 */
export const TLDR_URL_JSDELIVR_BASE: string = 'https://cdn.jsdelivr.net/gh/tldr-pages/tldr@main';
export const TLDR_URL_GITHUB_BASE: string = 'https://raw.githubusercontent.com/tldr-pages/tldr/main';

/**
 * 渠道顺序（**可配置点**，spec §3.1/G7）：先 jsDelivr、后 GitHub raw。
 *
 * 逐渠道试完**整条回落链**再切下一渠道（渠道优先、路径次之）：jsDelivr 健康时
 * zh/common 一次命中就结束；它整体不可达时才把 4 条路径交给 GitHub 重试一遍。
 * 这样「渠道不可达」的代价只付一次，而「某条路径 404」不会提前把请求打到慢渠道上。
 *
 * 2026-11-22 探针：GitHub raw 在开发机网络下连接被重置（spec §3.1），渠道顺序与
 * 回落语义不变 —— GitHub 何时可达随部署网络而定。
 */
export const TLDR_CHANNELS: string[] = [TLDR_CHANNEL_JSDELIVR, TLDR_CHANNEL_GITHUB];

/** 语言/平台回落路径（依次尝试）。中文页优先（G1），无中文页回落英文（spec §3.1 c） */
export const TLDR_PAGE_PATHS: string[] = [
  'pages.zh/common',
  'pages/common',
  'pages/linux',
  'pages/osx',
];

/** 页面语言（缓存目录与 TldrPage.locale 用） */
export const TLDR_LOCALE_ZH: string = 'zh';
export const TLDR_LOCALE_EN: string = 'en';

/**
 * 缓存目录（`filesDir` 下相对路径）：`<locale>/<token>.md` + `<token>.meta.json`（spec §3.1）。
 * 归属登记在 BrewCacheAdmin 统一清理；**不随 CacheEpoch（换源）清理** —— tldr 与浏览源无关。
 */
export const TLDR_CACHE_ROOT: string = 'brew_live/tldr';

/**
 * 404 负缓存的落盘标记（`filesDir/brew_live/tldr/<token>.neg.json`，记 fetchedAt）。
 * spec §3.1 只约定了正缓存的目录形状，负缓存落盘位置是实现细节 —— 放在 tldr 根目录
 * 而不是某个 locale 子目录，因为「没有这一页」是对**全部语言**的结论。
 */
export const TLDR_NEG_SUFFIX: string = '.neg.json';

/** meta 文件后缀（与 spec §3.1 的 `<token>.meta.json` 一致） */
export const TLDR_META_SUFFIX: string = '.meta.json';

/** tldr-pages 仓库地址（署名行跳转目标，G11） */
export const TLDR_REPO_URL: string = 'https://github.com/tldr-pages/tldr';

/** F3/F6 时日志里带走的原文头部长度（spec §5：报告原文前 200 字节） */
export const TLDR_FAIL_HEAD_BYTES: number = 200;

/**
 * F2：后台刷新**连续**失败多少次后本次会话停止刷新。
 * 会话内计数，进程重启自然归零；成功一次即清零。
 */
export const TLDR_REFRESH_FAIL_LIMIT: number = 3;
