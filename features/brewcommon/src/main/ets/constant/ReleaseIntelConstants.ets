/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

/**
 * 更新情报中心（Y · Release Intelligence）的常量。
 *
 * 规格见 `docs/superpowers/specs/2026-11-23-release-intel-spec.md`：
 * 通道探测实证见 `docs/knowledge/2026-11-23-release-channels-probe.md`。
 * AI 侧常量（promptVersion / TTL / 温度）沿用 AiConstants 的命名习惯但单独成文件，
 * 因为它们只被 release intel 一条链路使用，不进 AiConstants 的 D1/D2/D3 清单。
 */

/** AiCache 的 feature 目录名：`filesDir/brew_live/ai/release_intel/<providerModelKey>/<token_to>.json`。 */
export const RELEASE_INTEL_FEATURE: string = 'release_intel';

/**
 * prompt 版本（spec G8）。**变更即全部情报摘要缓存失效**——改 prompt 必须同时 +1。
 */
export const AI_PROMPT_VERSION_RI: number = 1;

/** 情报摘要缓存 TTL（spec G8：24h；上游一次发布只归纳一次，足够新鲜）。 */
export const AI_CACHE_TTL_RI_MS: number = 24 * 60 * 60 * 1000;

/** 温度（spec §3.1：与 D2/D3 同档 0.2，归纳任务不需要发散）。 */
export const AI_TEMPERATURE_RI: number = 0.2;

/**
 * 输出护栏：结构化输出按
 * `{one_liner, new_features≤3, fixes≤3, breaking_changes≤3, security_claims≤2, gaps≤3}`
 * 估算约 500 token，700 留余量（截断即 E4-truncated，走 F6 降级）。
 */
export const AI_MAX_TOKENS_RI: number = 700;

/** Release Notes 纯文本上限（spec G4：剥标签后截 ≤4KB，超限标注「已截断」）。 */
export const RELEASE_INTEL_NOTES_MAX_CHARS: number = 4096;

/**
 * Stage-0 探针门（spec G9）：`github.com/{repo}/releases.atom` 5s 超时。
 * 超时/网络失败 → 缺口卡（F1），**不尝试任何镜像**（ghfast.top 实测不代理 atom，403）。
 */
export const RELEASE_INTEL_ATOM_TIMEOUT_MS: number = 5000;

/** GitHub Releases atom 的固定路径（与 repo URL 拼接）。 */
export const RELEASE_INTEL_ATOM_PATH: string = 'releases.atom';

/** Release 页 URL 的固定前缀段（`{repo}/releases/tag/{tag}`）。 */
export const RELEASE_INTEL_RELEASES_PATH: string = 'releases/tag';

/** 策略偏好的 GSKV store 与键（spec §3.2；宿主进程读写，扩展进程不触碰）。 */
export const RELEASE_INTEL_PREFS_STORE: string = 'brew_release_intel';
export const RELEASE_INTEL_PREFS_KEY_IGNORED: string = 'release_intel_ignored';
export const RELEASE_INTEL_PREFS_KEY_PAUSED: string = 'release_intel_paused';

/** 暂停提醒的三档时长（spec §4：7 天 / 30 天 / 无限期=0）。 */
export const RELEASE_INTEL_PAUSE_7D_MS: number = 7 * 24 * 60 * 60 * 1000;
export const RELEASE_INTEL_PAUSE_30D_MS: number = 30 * 24 * 60 * 60 * 1000;
export const RELEASE_INTEL_PAUSE_FOREVER_MS: number = 0;

/**
 * diff 基线库目录（spec §3.1）。放在 `brew_live/ai` 之下，随 `BrewCacheAdmin.clear`
 * 一并清空（换数据源 = 基线口径已失效，清掉是正确行为）。
 * 布局：`<root>/<token>/<version>.json`，每个 token 只保留「已装版本」那一份。
 */
export const RELEASE_INTEL_BASELINE_SEGMENT: string = 'brew_live/ai/release_intel_baseline';

/** 基线库全局条目上限（LRU 按 ts 淘汰；单条 ~5KB，40 条 ≈ 200KB 封顶）。 */
export const RELEASE_INTEL_BASELINE_CAP: number = 40;

/**
 * 更新档案（spec §3.3 / G7）：`<root>/archive.json`，**单文件**，cap 20 条。
 * 条目内嵌当时的情报卡 JSON（AI 缓存可能被 TTL/清理回收，档案必须自带内容可渲染）。
 */
export const RELEASE_INTEL_ARCHIVE_SEGMENT: string = 'brew_live/ai/release_intel_archive';
export const RELEASE_INTEL_ARCHIVE_FILE: string = 'archive.json';
export const RELEASE_INTEL_ARCHIVE_CAP: number = 20;

/** confidence 的三个合法取值（模型输出其它值时按 none 处理，不判 E4）。 */
export const RELEASE_INTEL_CONFIDENCE_FULL: string = 'full';
export const RELEASE_INTEL_CONFIDENCE_PARTIAL: string = 'partial';
export const RELEASE_INTEL_CONFIDENCE_NONE: string = 'none';

/**
 * 缺口码（spec §5 失败态与 §4 缺口行的映射）。空串 = 无缺口。
 * repo：上游非 GitHub；tag：feed 里没有匹配 to 的发布；net：atom 通道不可达（F1）；
 * notes：匹配到发布但正文为空（F4）。
 */
export const RELEASE_INTEL_GAP_NONE: string = '';
export const RELEASE_INTEL_GAP_REPO: string = 'repo';
export const RELEASE_INTEL_GAP_TAG: string = 'tag';
export const RELEASE_INTEL_GAP_NET: string = 'net';
export const RELEASE_INTEL_GAP_NOTES: string = 'notes';

/**
 * AtomGit 打包通道（v1.1，spec G14）。
 *
 * harmonybrew 源的包，其「打包上游」不是 GitHub 而是 AtomGit 仓库
 * `Harmonybrew/homebrew-core`（组织页实证，2026-11-24；formula 大多搬迁自上游
 * Homebrew/homebrew-core，目录布局同为 `Formula/<首字母>/<token>.rb` 分片）。
 * 情报通道 = 按该文件路径过滤的提交列表：
 * `GET {api}/repos/{owner}/{repo}/commits?path=<formulaPath>&per_page=N`
 * （api-doc「允许匿名访问」，实测匿名共享配额 p_repoRobot 10W/hour 会 429 —— 429/失败
 * 一律静默降级为不渲染该组，**绝不**重试轰炸）。
 */
export const RELEASE_INTEL_ATOMGIT_API_BASE: string = 'https://api.atomgit.com/api/v5';
export const RELEASE_INTEL_TAP_OWNER: string = 'Harmonybrew';
export const RELEASE_INTEL_TAP_REPO: string = 'homebrew-core';
/** 打包提交条数上限（渲染 ≤3 条，请求 5 条留筛选余量）。 */
export const RELEASE_INTEL_PACK_COMMITS_MAX: number = 3;
export const RELEASE_INTEL_PACK_COMMITS_PER_PAGE: number = 5;
/** AtomGit commits 通道超时（与 atom 探针同档）。 */
export const RELEASE_INTEL_COMMITS_TIMEOUT_MS: number = 5000;

/**
 * 【临时调试开关,观察期结束后删除】true = 情报卡跳过 AI 调用（card 恒 null），
 * 只渲染结构化区：判定徽章 / 版本区间 / 本地 diff / 上游缺口 / AtomGit 打包记录。
 * 用途：真机观察 AtomGit 打包通道的原始返回是否符合预期（用户观察期,Y v1.1）。
 * 恢复 AI 时改回 false 或整段删除;assemble() 的引用见 ReleaseIntelService。
 */
export const RELEASE_INTEL_DEBUG_AI_OFF: boolean = true;
