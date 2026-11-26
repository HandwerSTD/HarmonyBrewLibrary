/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

/**
 * AI Companion 的常量：promptVersion / TTL / 截断上限 / Asset alias。
 *
 * 改动清单见 spec §11；失败态分级（E1–E6）与文案 key 见 spec §8 / §10。
 * 这些值被 AiClient / AiSettingsStore 两处共用，所以收在一份里。
 */

/** 每个任务 prompt 的版本号。**变更即该任务的全部落盘缓存失效**（spec G9）。 */
export const AI_PROMPT_VERSION_D1: number = 2;
/** D2 v2：问答化 schema（{lead, picks}），v1 候选列表缓存全部失效。 */
export const AI_PROMPT_VERSION_D2: number = 2;
export const AI_PROMPT_VERSION_D4: number = 1;

/**
 * 缓存 TTL（spec §3.3）：D1 7 天 / D2 1 天 / D3 不缓存（D3 无目录，也不落盘）。
 * D4（AI 发现流）1 天：画像由安装集决定，一天内反复进出不重算。
 * 过期不删：先返回旧值再后台刷新（stale-while-revalidate，G10）。
 */
export const AI_CACHE_TTL_D1_MS: number = 7 * 24 * 60 * 60 * 1000;
export const AI_CACHE_TTL_D2_MS: number = 24 * 60 * 60 * 1000;
export const AI_CACHE_TTL_D4_MS: number = 24 * 60 * 60 * 1000;

/**
 * prompt 总长上限（spec §3.2，8KB）。超出按各任务规则先截 caveats（D1）、
 * 再截 stderr / stdout（D3）。是 **UTF-16 code unit** 计数：ArkTS string 长度语义，
 * 与 HTTP body 的字节数有偏差但对「8KB 量级」的护栏足够。
 */
export const AI_PROMPT_MAX_CHARS: number = 8192;

/** D3 单独的截断上限（spec §6）：stderr 尾部 ≤4KB、stdout 尾部 ≤2KB。 */
export const AI_D3_STDERR_TAIL_CHARS: number = 4096;
export const AI_D3_STDOUT_TAIL_CHARS: number = 2048;

/** 各任务的温度（spec §3.2：低温度 D1 0.3 / D3 0.2）。D2 v2 叙事语气略活 0.3。 */
export const AI_TEMPERATURE_D1: number = 0.3;
export const AI_TEMPERATURE_D2: number = 0.3;
export const AI_TEMPERATURE_D3: number = 0.2;
/** D4（AI 发现流）：推荐要多样性，高于 D2 的 0.2。 */
export const AI_TEMPERATURE_D4: number = 0.5;

/** 测试连接的最小 completion 输出上限（spec §3.1：max_tokens=8）。 */
export const AI_PROBE_MAX_TOKENS: number = 8;

/**
 * 输出护栏（spec §9 成本护栏）：
 * D1 讲解卡四段合计约 300 token 足够；D2 v2 问答要 lead + 5×intro（每段一两句话），
 * 实测约 700，maxTokens 给到 900 留余量（截断即 E4-truncated）；D3 三段各一句话。
 */
export const AI_MAX_TOKENS_D1: number = 800;
export const AI_MAX_TOKENS_D2: number = 900;
export const AI_MAX_TOKENS_D3: number = 500;
/**
 * D4（AI 发现流）：10 picks × 中文 why + profile + JSON 开销。
 * 截断（finish=length）走 E4-truncated，失败占位卡重试可解。
 */
export const AI_MAX_TOKENS_D4: number = 1200;

/**
 * 缓存目录（spec §3.3）：`filesDir/brew_live/ai/<feature>/<providerModelKey>/<cacheKey>.json`。
 * 已登记进 `BrewCacheAdmin`（统一清理），与 CacheEpoch 无关。
 */
export const AI_CACHE_ROOT_SEGMENT: string = 'brew_live/ai';
/** 功能目录名。 */
export const AI_FEATURE_D1: string = 'd1';
export const AI_FEATURE_D2: string = 'd2';
/** D4（AI 发现流）的功能目录名（第四个 D 系任务）。 */
export const AI_FEATURE_D4: string = 'd4';

/**
 * Asset Store Kit 的关键资产别名。Key 只存在这里（G1）；
 * baseURL / model / provider 等非敏感字段在普通偏好里。
 */
export const AI_ASSET_ALIAS_API_KEY: string = 'brew_ai_api_key';

/**
 * AI 设置的偏好键（GSKV store `brew_ai_settings`，键名带 `brew_` 前缀对齐既有缓存键口径）。
 * **这里永远没有 Key**——Key 只进 Asset Store（G1）。
 */
export const AI_PREFS_STORE: string = 'brew_ai_settings';
export const AI_PREFS_KEY_CONFIG: string = 'brew_ai_config';

/** 预置 provider 的 id（spec §3.1：预置 DeepSeek，v1 单配置）。 */
export const AI_PROVIDER_DEEPSEEK: string = 'deepseek';
export const AI_PROVIDER_CUSTOM: string = 'custom';

/**
 * 「自动生成 AI 讲解」开关的偏好键（默认开）：
 * 开 = 详情页装配时有 Key 即自动触发讲解请求（缓存链路复用，失败静默）；
 * 关 = 显式按钮触发。布尔单独存，不进 config JSON（与 nonStreaming 曾用的模式同构）。
 */
export const AI_PREFS_KEY_AUTO_EXPLAIN: string = 'brew_ai_auto_explain';

/**
 * 「自动解析更新日志」开关的偏好键（Y 更新情报中心的 AI 摘要闸，默认开）：
 * 开 = 详情页情报卡允许发起 AI 摘要（缓存链路复用，失败静默）；
 * 关 = 情报卡只渲染上游 notes 原文节选。布尔单独存，不进 config JSON。
 */
export const AI_PREFS_KEY_AUTO_RELEASE_INTEL: string = 'brew_ai_auto_release_intel';

/**
 * 「AI 搜索问答」开关的偏好键（搜索框内的 AI pill，默认关）：
 * 开 = 搜索提交走 AI 问答（无 Key 时提交即 E1 → 通知条 + 自动本地搜索，不引导配 Key）。
 * 与 autoExplain 不同，**不做「无 Key 恒 false」**——这是用户的显式模式选择，
 * 开关状态忠实于用户操作，E1 降级在提交时兜底。布尔单独存，不进 config JSON。
 */
export const AI_PREFS_KEY_AI_SEARCH: string = 'brew_ai_search_enabled';

/** DeepSeek 预置模板（spec §3.1）。baseURL 不含 `/chat/completions` 尾段。 */
export const AI_DEEPSEEK_BASE_URL: string = 'https://api.deepseek.com';
export const AI_DEEPSEEK_DEFAULT_MODEL: string = 'deepseek-chat';

/** D2 的 picks 上限（spec §5：AI 一次最多推荐 5 个）。 */
export const AI_D2_MAX_CANDIDATES: number = 5;
/** D2 展示合计上限（picks + related 尾行补足目标）。 */
export const AI_D2_RESULT_LIMIT: number = 8;
/** D2 lead 总起段字数上限（解析校验用；prompt 约束更严）。 */
export const AI_D2_LEAD_MAX_CHARS: number = 80;
/** D2 单条 intro 介绍段字数上限（解析校验用；prompt 约束更严）。 */
export const AI_D2_INTRO_MAX_CHARS: number = 200;
/** D2 related 尾行条数上限。 */
export const AI_D2_TAIL_ROWS_MAX: number = 5;

/** AiClient 的请求超时（spec §3.2：15s，连接与读取各一份）。 */
export const AI_TIMEOUT_MS: number = 15000;

/**
 * Asset Store 不可用时的**会话内存兜底标记**（不落盘）：
 * 存不进 Asset 的 Key 只活在本进程内存里，设置页会提示用户重启后需重填。
 */
export const AI_KEY_MEMORY_ONLY_NOTE: boolean = true;

// ------------------------------------------------------------ D4 · AI 发现流
// spec：docs/superpowers/specs/2026-11-26-ai-discover-feed-spec.md §5

/** 少于 3 个已安装包推不出画像 → AI 区不出现（hidden）。 */
export const AI_D4_MIN_INSTALLED: number = 3;
/** prompt 安装清单上限（installedAt 降序截，近装优先）。 */
export const AI_D4_INSTALLED_CAP: number = 150;
/** 候选池 formula 条数（vol30d 降序，目录子集 = G5 校验的唯一依据）。 */
export const AI_D4_POOL_FORMULA: number = 200;
/** 候选池 cask 条数。 */
export const AI_D4_POOL_CASK: number = 130;
/** 期望输出 picks 数（prompt 写死「恰好 10 个」）。 */
export const AI_D4_PICKS: number = 10;
/** G5 + 已安装过滤后存活下限，低于判失败（失败占位卡）。 */
export const AI_D4_PICKS_MIN: number = 3;
/** 上大图卡的 picks 前缀数（「若干」的落地值，spec §8 评审可调 2–5）。 */
export const AI_D4_FEATURED_COUNT: number = 3;
/** 画像标签个数上限。 */
export const AI_D4_PROFILE_TAGS_MAX: number = 4;
/** 画像标签单条字数上限（解析校验用；prompt 约束 8 字）。 */
export const AI_D4_PROFILE_TAG_MAX_CHARS: number = 16;
/** headline 字数上限（解析校验用；prompt 约束 30 字）。 */
export const AI_D4_HEADLINE_MAX_CHARS: number = 40;
/** why 字数上限（解析校验用；prompt 约束 40 字）。 */
export const AI_D4_WHY_MAX_CHARS: number = 60;
/** basis 字数上限（解析校验用；prompt 约束 40 字）。 */
export const AI_D4_BASIS_MAX_CHARS: number = 60;
/** 「近装」标记窗口（天）：installedAt 在窗口内带 `*` 进 prompt。 */
export const AI_D4_RECENT_DAYS: number = 30;
