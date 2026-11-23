/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

/**
 * AI Companion 的常量：promptVersion / TTL / 截断上限 / 词表规模 / Asset alias。
 *
 * 改动清单见 spec §11；失败态分级（E1–E6）与文案 key 见 spec §8 / §10。
 * 这些值被 AiClient / AiSettingsStore / AiTaskWords 三处共用，所以收在一份里。
 */

/**
 * 每个任务 prompt 的版本号。**变更即该任务的全部落盘缓存失效**（spec G9）。
 * D1=2：AI 二期 P1-2 在 D1 schema 上增列 deps_explain / version_notes 两段
 * （spec 2026-11-23 ai-companion-phase2 §3），旧缓存靠版本号自动失效。
 */
export const AI_PROMPT_VERSION_D1: number = 2;
export const AI_PROMPT_VERSION_D2: number = 1;

/** AI 二期三个新任务（P1-1 榜单解读 / P1-3 弃用解读 / P1-4 数据源诊断）的 prompt 版本。 */
export const AI_PROMPT_VERSION_BI: number = 1;
export const AI_PROMPT_VERSION_LC: number = 1;
export const AI_PROMPT_VERSION_SD: number = 1;

/**
 * 缓存 TTL（spec §3.3）：D1 7 天 / D2 1 天 / D3 不缓存（D3 无目录，也不落盘）。
 * 过期不删：先返回旧值再后台刷新（stale-while-revalidate，G10）。
 */
export const AI_CACHE_TTL_D1_MS: number = 7 * 24 * 60 * 60 * 1000;
export const AI_CACHE_TTL_D2_MS: number = 24 * 60 * 60 * 1000;
/** AI 二期：榜单解读按快照日期缓存 1 天（同一天的数字不变，无需更久）；
 * 弃用解读 7 天（排期文本极稳定）；诊断不缓存（每次探测结果都可能不同，对齐 D3）。 */
export const AI_CACHE_TTL_BI_MS: number = 24 * 60 * 60 * 1000;
export const AI_CACHE_TTL_LC_MS: number = 7 * 24 * 60 * 60 * 1000;

/**
 * prompt 总长上限（spec §3.2，8KB）。超出按各任务规则先截 caveats（D1）、
 * 再截 stderr / stdout（D3）。是 **UTF-16 code unit** 计数：ArkTS string 长度语义，
 * 与 HTTP body 的字节数有偏差但对「8KB 量级」的护栏足够。
 */
export const AI_PROMPT_MAX_CHARS: number = 8192;

/** D3 单独的截断上限（spec §6）：stderr 尾部 ≤4KB、stdout 尾部 ≤2KB。 */
export const AI_D3_STDERR_TAIL_CHARS: number = 4096;
export const AI_D3_STDOUT_TAIL_CHARS: number = 2048;

/** 各任务的温度（spec §3.2：低温度 D1 0.3 / D2 0.2 / D3 0.2；二期三任务同为事实陈述，取 0.2）。 */
export const AI_TEMPERATURE_D1: number = 0.3;
export const AI_TEMPERATURE_D2: number = 0.2;
export const AI_TEMPERATURE_D3: number = 0.2;
export const AI_TEMPERATURE_BI: number = 0.2;
export const AI_TEMPERATURE_LC: number = 0.2;
export const AI_TEMPERATURE_SD: number = 0.2;

/** 测试连接的最小 completion 输出上限（spec §3.1：max_tokens=8）。 */
export const AI_PROBE_MAX_TOKENS: number = 8;

/**
 * 输出护栏（spec §9 成本护栏）：
 * D1 讲解卡四段合计约 300 token 足够；D2 只回 5 个 `{"token","why"}`——
 * 中英混排 5 条候选实测贴近 400，maxTokens 给到 600 留余量（截断即 E4-truncated）；
 * D3 三段各一句话。
 */
export const AI_MAX_TOKENS_D1: number = 800;
export const AI_MAX_TOKENS_D2: number = 600;
export const AI_MAX_TOKENS_D3: number = 500;
/** AI 二期：insight 形态 {one_liner + points≤3 + action_hint?}，一句话量级 500 足够。 */
export const AI_MAX_TOKENS_BI: number = 500;
export const AI_MAX_TOKENS_LC: number = 450;
export const AI_MAX_TOKENS_SD: number = 500;

/**
 * 缓存目录（spec §3.3）：`filesDir/brew_live/ai/<feature>/<providerModelKey>/<cacheKey>.json`。
 * 已登记进 `BrewCacheAdmin`（统一清理），与 CacheEpoch 无关。
 */
export const AI_CACHE_ROOT_SEGMENT: string = 'brew_live/ai';
/** 功能目录名。 */
export const AI_FEATURE_D1: string = 'd1';
export const AI_FEATURE_D2: string = 'd2';
/** AI 二期功能目录名（P1-1 榜单解读 / P1-3 弃用解读 / P1-4 数据源诊断）。 */
export const AI_FEATURE_BI: string = 'bi';
export const AI_FEATURE_LC: string = 'lc';
export const AI_FEATURE_SD: string = 'sd';

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

/** DeepSeek 预置模板（spec §3.1）。baseURL 不含 `/chat/completions` 尾段。 */
export const AI_DEEPSEEK_BASE_URL: string = 'https://api.deepseek.com';
export const AI_DEEPSEEK_DEFAULT_MODEL: string = 'deepseek-chat';

/**
 * 中文任务词表的 rawfile 路径与规模（spec §5：28 条策展表，rawfile/ai/taskwords.json）。
 * 校验脚本 `hmosword-build/brew-ai/check_taskwords.py` 钉住结构与规模。
 */
export const AI_TASKWORDS_RAWFILE: string = 'ai/taskwords.json';
export const AI_TASKWORDS_MIN_COUNT: number = 20;
/** D2 的候选上限（spec §5：AI 一次最多提名 5 个）。 */
export const AI_D2_MAX_CANDIDATES: number = 5;
/** D2 结果展示上限（过滤 + 引擎重排后仍截到 8 行，超出部分不再渲染）。 */
export const AI_D2_RESULT_LIMIT: number = 8;

/** AiClient 的请求超时（spec §3.2：15s，连接与读取各一份）。 */
export const AI_TIMEOUT_MS: number = 15000;

/**
 * Asset Store 不可用时的**会话内存兜底标记**（不落盘）：
 * 存不进 Asset 的 Key 只活在本进程内存里，设置页会提示用户重启后需重填。
 */
export const AI_KEY_MEMORY_ONLY_NOTE: boolean = true;

/**
 * AI 二期 grounding 登记（spec G2：声明制——每个任务只允许引用下面登记的字段，
 * UI 来源行按登记口径写「基于目录统计 / 基于上游公告」。A 级 = 结构化字段直读，
 * B 级 = 半结构化文本（需标注来源）。登记即合同：prompt 只放这些字段，来源行只写这些口径。
 */
/** P1-1 榜单解读：目录内嵌 analytics（扁平 map）+ 聚合端点 count/percent + github_packages_downloads（A 级）。 */
export const AI_GROUNDING_BI: string =
  'A: inline analytics flat map + aggregate count/percent + github_packages_downloads';
/** P1-3 弃用解读：formula/cask 的 deprecated/deprecation_date/reason/deprecate_args/disable_date（A 级）。 */
export const AI_GROUNDING_LC: string =
  'A: deprecated/deprecation_date/deprecation_reason/deprecate_args/disable_date';
/** P1-4 数据源诊断：BrewSourceProbe 探测结果（httpCode/tookMs/reason/detail，A 级）+ 错误文本（B 级，标注来源）。 */
export const AI_GROUNDING_SD: string =
  'A: BrewProbeResult(httpCode/tookMs/reason/detail) + B: error text (source-labeled)';
