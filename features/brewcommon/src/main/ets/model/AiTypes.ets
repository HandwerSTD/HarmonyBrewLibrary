/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

/**
 * AI Companion 的类型：三个任务（D1 讲解 / D2 找工具 / D3 报错解读）的请求、响应与错误。
 *
 * 全部用 class 而不是 interface：UI 需要构造实例做兜底值（与 `BrewDetailViewData` 同理），
 * 且 `@Prop` / `@State` 传对象时 class 才有运行时形态。解析 provider 返回的 JSON 后
 * 逐字段填充并校验（不符即 E4），**不把 JSON.parse 的结果直接当响应对象用**——
 * 那会把「字段缺失」静默地带进渲染层。
 */

import {
  AI_D2_MAX_CANDIDATES,
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
}

/** D1 讲解卡。字段名对齐 spec §4 的四段结构。 */
export class AiExplainCard {
  /** 定位一句话 */
  public summary: string = '';
  /** 适用场景 ≤3 */
  public scenarios: string[] = [];
  /** 注意与坑 ≤3（caveats 中文化 + 风险点） */
  public caveats: string[] = [];
  /** 上手三步（固定 3 条；不足 3 条的响应判 E4） */
  public steps: string[] = [];

  public isValid(): boolean {
    return this.summary.trim().length > 0 && this.scenarios.length > 0 &&
      this.scenarios.length <= 3 && this.caveats.length <= 3 && this.steps.length === 3;
  }
}

/** D2 候选条目：包 token + 推荐理由（AI 只提名，排序交给本地引擎）。 */
export class AiToolCandidate {
  /** 包 token。目录外的一律被过滤器丢弃（G5）。 */
  public token: string = '';
  /** 一句话推荐理由（渲染在 token 下方）。 */
  public why: string = '';
}

/** D2 结果：过滤与重排之后的候选列表 + 丢弃计数。 */
export class AiToolResult {
  /** 存活候选（已按本地引擎排序、已截断）。 */
  public candidates: AiToolCandidate[] = [];
  /** 目录外被丢弃的名字数（进日志，不展示具体名单——防 slopsquatting 需求就是不给它们曝光）。 */
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

/**
 * D2 的意图查询。wordlist 模式（离线降级）与 AI 模式共用它，
 * 返回侧统一是 `AiToolResult`。
 */
export class AiIntentInput {
  public intent: string = '';
}

/**
 * provider 名是否合法（设置页保存前校验）。
 */
export function isKnownAiProvider(provider: string): boolean {
  return provider === AI_PROVIDER_DEEPSEEK || provider === AI_PROVIDER_CUSTOM;
}

/** D2 候选数上限的护栏（解析时用它截断并判 E4：超多的响应视为格式不符）。 */
export function d2CandidateCap(): number {
  return AI_D2_MAX_CANDIDATES;
}
