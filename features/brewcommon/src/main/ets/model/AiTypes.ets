/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

/**
 * AI Companion 的类型：四个任务（D1 讲解 / D2 AI 搜索问答 / D3 报错解读 / D4 发现流）
 * 的请求、响应与错误。
 *
 * 全部用 class 而不是 interface：UI 需要构造实例做兜底值（与 `BrewDetailViewData` 同理），
 * 且 `@Prop` / `@State` 传对象时 class 才有运行时形态。解析 provider 返回的 JSON 后
 * 逐字段填充并校验（不符即 E4），**不把 JSON.parse 的结果直接当响应对象用**——
 * 那会把「字段缺失」静默地带进渲染层。
 */

import {
  AI_D4_BASIS_MAX_CHARS,
  AI_D4_HEADLINE_MAX_CHARS,
  AI_D4_PROFILE_TAG_MAX_CHARS,
  AI_D4_PROFILE_TAGS_MAX,
  AI_PROVIDER_CUSTOM,
  AI_PROVIDER_DEEPSEEK,
} from '../constant/AiConstants';

/** 失败分级（spec §8）。全任务共用；UI 按 D1/D2/D3 的列查行为。 */
export enum AiErrorKind {
  /** 未配置 Key */
  E1_NO_KEY = 'e1',
  /** 网络失败 */
  E2_NETWORK = 'e2',
  /** 超时（15s） */
  E3_TIMEOUT = 'e3',
  /** 响应格式不符 / Schema 校验失败 */
  E4_BAD_FORMAT = 'e4',
  /** Provider 内容安全拒绝 */
  E5_BLOCKED = 'e5',
  /** 用户取消 */
  E6_CANCELLED = 'e6',
}

/** 一次 AI 调用失败的完整描述。`message` 只进日志，UI 文案按 kind 从资源表取。 */
export class AiError extends Error {
  public kind: AiErrorKind;

  public constructor(kind: AiErrorKind, message: string) {
    super(message);
    this.kind = kind;
  }
}

/** provider 配置（偏好里存的部分；Key 不在这里——见 `AiSettingsStore`）。 */
export class AiProviderConfig {
  /** AI_PROVIDER_DEEPSEEK | AI_PROVIDER_CUSTOM */
  public provider: string = AI_PROVIDER_DEEPSEEK;
  /** OpenAI 兼容端点，不含 `/chat/completions` 尾段；预置 DeepSeek 时锁定模板值。 */
  public baseUrl: string = '';
  /** 模型名，如 deepseek-chat。 */
  public model: string = '';

  /** 是否已填到能发请求的程度（Key 在 Asset 里另查）。 */
  public isComplete(): boolean {
    return this.baseUrl.trim().length > 0 && this.model.trim().length > 0;
  }

  /** provider 是否取预置模板（DeepSeek 的 baseURL 由代码给定，UI 不给输入框）。 */
  public isDeepSeek(): boolean {
    return this.provider === AI_PROVIDER_DEEPSEEK;
  }
}

/** AI 设置的完整快照（含 Key 是否存在的标记，**不含 Key 本身**）。 */
export class AiSettingsSnapshot {
  public config: AiProviderConfig = new AiProviderConfig();
  /** Asset 里是否存着 Key（只回答「有没有」，值永远不进本对象）。 */
  public hasKey: boolean = false;
  /** Key 是否只存在会话内存里（Asset 不可用时的兜底，重启后需重填）。 */
  public keyMemoryOnly: boolean = false;
  /**
   * 「自动生成 AI 讲解」开关（默认开）。**无 Key 时 AiSettingsStore.autoExplain()
   * 恒回 false**——快照里的值即详情页装配的最终判据，装配层不用再查 Key。
   */
  public autoExplain: boolean = false;
  /**
   * 「自动解析更新日志」开关（Y 更新情报中心的 AI 摘要闸，默认开）。同上，
   * 无 Key 时 AiSettingsStore.autoReleaseIntel() 恒回 false。
   */
  public autoReleaseIntel: boolean = false;
}

/** D1 讲解卡。字段名对齐 spec §4 的四段结构。 */
export class AiExplainCard {
  /** 定位一句话 */
  public summary: string = '';
  /** 适用场景 ≤3（空字段原则：模型可输出 []，此时 UI 不渲染该分区） */
  public scenarios: string[] = [];
  /** 注意与坑 ≤3（caveats 中文化 + 风险点） */
  public caveats: string[] = [];
  /** 上手步骤 2–3 条（spec §3.2 兼容性修复 ③：部分模型习惯输出两条，放宽后不再误判 E4） */
  public steps: string[] = [];

  public isValid(): boolean {
    // scenarios 允许 0（spec §4 空字段原则：包没有场景信息时 D1_SYSTEM 允许输出 []，
    // 这里若仍强制 >0 会被误判成 E4 schema mismatch）。summary 必填不变。
    return this.summary.trim().length > 0 && this.scenarios.length <= 3 &&
      this.caveats.length <= 3 && this.steps.length >= 2 && this.steps.length <= 3;
  }
}

/**
 * D2 · AI 搜索问答的推荐条目：包 token + AI 写的介绍段。
 * 顺序 = LLM 叙事序（首选在前），**不经本地引擎重排**；
 * token 一律经候选目录校验（G5），kind 由调用侧从目录查（不信模型）。
 */
export class AiSearchPick {
  /** 包 token。目录外的一律被过滤器丢弃（G5）。 */
  public token: string = '';
  /** AI 介绍段（渲染在该 pick 的包行上方）。related 尾行 intro 恒空。 */
  public intro: string = '';
}

/**
 * D2 问答答案：lead 总起段 + picks 推荐对 + related 目录召回尾行 + missed 缺失名单
 * + 丢弃计数。渲染为「文本段与包行交替」的混排（spec 2026-11-26-ai-search-ask-spec §4.4）。
 */
export class AiSearchAnswer {
  /** 总起段（一句话概括 + 首选点名），≤ AI_D2_LEAD_MAX_CHARS。 */
  public lead: string = '';
  /** AI 推荐条目（叙事序，1..AI_D2_MAX_CANDIDATES 条）。 */
  public picks: AiSearchPick[] = [];
  /** 目录召回尾行（引擎对意图原文排序的未覆盖条目；intro 空，仅 token）。 */
  public related: AiSearchPick[] = [];
  /**
   * 目录外（本机源里查不到）的 token 名单（m01462：不再静默丢弃）。
   * 渲染为答案尾部的纯文本披露行——**不可点击、无详情路由、无任何安装入口**：
   * G5 的本意是防 slopsquatting（诱导装不存在的包），明示「AI 提到但本机源没有」
   * 恰是这个威胁模型的正确答案。dropped 计数 = missed.length（日志口径不变）。
   */
  public missed: string[] = [];
  /** 目录外被丢弃的名字数（进日志；与 missed.length 等价，保留双写仅为兼容日志口径）。 */
  public dropped: number = 0;
}

/** D3 报错解读卡。三段结构对齐 spec §6。 */
export class AiFailureCard {
  /** 发生了什么（一句话） */
  public what: string = '';
  /** 可能原因 ≤3 */
  public causes: string[] = [];
  /** 下一步 ≤3。**UI 只渲染复制按钮，永不提供执行入口（G13）** */
  public nextSteps: string[] = [];

  public isValid(): boolean {
    return this.what.trim().length > 0 && this.causes.length > 0 && this.causes.length <= 3 &&
      this.nextSteps.length > 0 && this.nextSteps.length <= 3;
  }
}

/** D1 的 grounding 输入（spec §4：只用包元数据已有字段）。 */
export class AiExplainInput {
  public token: string = '';
  public kind: string = '';
  public desc: string = '';
  public caveats: string = '';
  /** 依赖名的平铺列表（不含版本约束）。 */
  public dependencies: string[] = [];
}

/** D3 的输入（spec §6：命令原文 + 输出尾部 + 失败分类）。 */
export class AiFailureInput {
  public command: string = '';
  public stderrTail: string = '';
  public stdoutTail: string = '';
  /** 既有六分类标签（BrewCommandStatus 语义：failed / timeout / interrupted）。 */
  public failureKind: string = '';
  public token: string = '';
}

/** D2 的意图查询。返回侧统一是 `AiSearchAnswer`。 */
export class AiIntentInput {
  public intent: string = '';
}

// ------------------------------------------------------------ D4 · AI 发现流

/**
 * D4 的画像对象（AI 发现流 spec §3.2）。
 *
 * MVP 只渲染 headline（AI 榜卡 Hero 标题位）；tags / basis 保留在结果里
 * 供后续画像二级页使用。`isValid()` 与 D1 同纪律：逐字段校验，不把
 * JSON.parse 的结果直接当响应对象。
 */
export class AiDiscoverProfile {
  /** ≤40 字的画像一句话，第二人称（prompt 约束 30 字，解析留余量） */
  public headline: string = '';
  /** 1–4 个，每个 ≤16 字 */
  public tags: string[] = [];
  /** ≤60 字，画像依据（引用代表性已安装包） */
  public basis: string = '';

  public isValid(): boolean {
    if (this.headline.trim().length === 0 || this.headline.length > AI_D4_HEADLINE_MAX_CHARS) {
      return false;
    }
    if (this.tags.length === 0 || this.tags.length > AI_D4_PROFILE_TAGS_MAX) {
      return false;
    }
    for (const tag of this.tags) {
      if (tag.trim().length === 0 || tag.length > AI_D4_PROFILE_TAG_MAX_CHARS) {
        return false;
      }
    }
    return this.basis.trim().length > 0 && this.basis.length <= AI_D4_BASIS_MAX_CHARS;
  }
}

/** D4 的一条推荐。token/kind 经候选池校验存活后才出现在这里。 */
export class AiDiscoverPick {
  public token: string = '';
  /** `'formula'` | `'cask'` */
  public kind: string = '';
  /** ≤60 字的推荐理由（榜单行副文案位直接显示） */
  public why: string = '';
}

/**
 * D4 的解析结果。`picks` 是过滤后的存活列表；
 * `dropped` / `droppedInstalled` 是 G5（候选池外）与已安装过滤的丢弃计数，
 * 只进日志不进 UI（spec G3）。
 */
export class AiDiscoverResult {
  public profile: AiDiscoverProfile = new AiDiscoverProfile();
  public picks: AiDiscoverPick[] = [];
  public dropped: number = 0;
  public droppedInstalled: number = 0;
}

/** D4 输入里的一条已安装包摘要（token + kind + 近装标记）。 */
export class AiInstalledBrief {
  public token: string = '';
  /** `'formula'` | `'cask'` */
  public kind: string = '';
  /** installedAt 在 AI_D4_RECENT_DAYS(30) 天内 */
  public recent: boolean = false;
}

/** D4 候选池里的一条（目录子集，G5 校验的唯一依据）。 */
export class AiCandidate {
  public token: string = '';
  /** `'formula'` | `'cask'` */
  public kind: string = '';
  /** BrewTaxonomy 分类，prompt 里给模型聚类线索 */
  public categoryKey: string = '';
  public vol30d: number = 0;
  public velocity: number = 0;
}

/**
 * D4 的输入（AI 发现流 spec §3.1 装配管线产物）。
 *
 * `epoch` 由调用方（VM）取 `BrewCacheEpoch.current()` 填入 —— AiTasks 不 import
 * 目录层，缓存键的目录世代由输入携带（cacheKey = d4_{安装集哈希}_{epoch}_{locale}）。
 */
export class AiDiscoverInput {
  /** `'zh'` | `'en'`（UI 语言） */
  public locale: string = 'zh';
  /** 已安装包摘要，installedAt 降序，≤ AI_D4_INSTALLED_CAP(150) */
  public installed: AiInstalledBrief[] = [];
  /** 候选池，vol30d 降序（formula top200 + cask top130 − 已安装） */
  public candidates: AiCandidate[] = [];
  /** 换一批时上一次已展示的 token 列表（force 路径才进 prompt） */
  public exclude: string[] = [];
  /** 目录世代号（BrewCacheEpoch.current()） */
  public epoch: number = 0;
}

/**
 * provider 名是否合法（设置页保存前校验）。
 */
export function isKnownAiProvider(provider: string): boolean {
  return provider === AI_PROVIDER_DEEPSEEK || provider === AI_PROVIDER_CUSTOM;
}
