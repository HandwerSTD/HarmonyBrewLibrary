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
 * notes 原文节选长度（v1.3.3 用户定调：约 4 行——App Store 更新日志卡是「摘要」
 * 不是全文）。notes 提取本身仍是 4KB（喂 AI 用）,全文走「查看全文」半模态
 * （snapshot.notesFull）,外跳发布页兜底。
 */
export const RELEASE_INTEL_NOTES_PREVIEW_CHARS: number = 160;

/**
 * 整卡快照缓存（v1.3.4）：assemble 产物按 (token, toVersion) 落盘,1h 内同版本
 * 重复进详情页**零网络**直接复用（atom 抓取是装配里唯一网络步,重复进页重拉纯属浪费）。
 * F1（net）瞬态失败不缓存；F2/F3/F4 是稳定事实照常缓存。AI 摘要另有自身 24h 缓存,
 * 两者独立:TTL 过期后重装配,card 段大概率仍命中 AI 缓存。
 * 布局：`<root>/<token>/<toVersion>.json`,全局 LRU cap 40 条；随 BrewCacheAdmin 清。
 */
export const RELEASE_INTEL_SNAPSHOT_SEGMENT: string = 'brew_live/ai/release_intel_snapshot';
export const RELEASE_INTEL_SNAPSHOT_CAP: number = 40;
export const RELEASE_INTEL_SNAPSHOT_TTL_MS: number = 60 * 60 * 1000;