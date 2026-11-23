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
  /**
   * 「自动生成 AI 讲解」开关（默认开）。**无 Key 时 AiSettingsStore.autoExplain()
   * 恒回 false**——快照里的值即详情页装配的最终判据，装配层不用再查 Key。
   */
  public autoExplain: boolean = false;
}

/** D1 讲解卡。字段名对齐 spec §4 的四段结构；二期增列「依赖与版本」两段（P1-2）。 */
export class AiExplainCard {
  /** 定位一句话 */
  public summary: string = '';
  /** 适用场景 ≤3（空字段原则：模型可输出 []，此时 UI 不渲染该分区） */
  public scenarios: string[] = [];
  /** 注意与坑 ≤3（caveats 中文化 + 风险点） */
  public caveats: string[] = [];
  /** 上手步骤 2–3 条（spec §3.2 兼容性修复 ③：部分模型习惯输出两条，放宽后不再误判 E4） */
  public steps: string[] = [];
  /** 依赖与版本解释 ≤3（AI 二期 P1-2：解释为什么带这些依赖、版本口径；空数组不渲染） */
  public depsExplain: string[] = [];
  /** 版本口径备注 ≤2（bottle tag / 别名 / 版本化配方，无则 []） */
  public versionNotes: string[] = [];

  public isValid(): boolean {
    // scenarios 允许 0（spec §4 空字段原则：包没有场景信息时 D1_SYSTEM 允许输出 []，
    // 这里若仍强制 >0 会被误判成 E4 schema mismatch）。summary 必填不变。
    // 二期两段上限 3/2：解析层 stringArrayOf 已截，这里只防异常超限。
    return this.summary.trim().length > 0 && this.scenarios.length <= 3 &&
      this.caveats.length <= 3 && this.steps.length >= 2 && this.steps.length <= 3 &&
      this.depsExplain.length <= 3 && this.versionNotes.length <= 2;
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

/** D1 的 grounding 输入（spec §4：只用包元数据已有字段；二期 P1-2 扩列）。 */
export class AiExplainInput {
  public token: string = '';
  public kind: string = '';
  public desc: string = '';
  public caveats: string = '';
  /** 依赖名的平铺列表（不含版本约束）。 */
  public dependencies: string[] = [];
  /** 构建依赖（仅 formula；cask 路径恒空）。 */
  public buildDependencies: string[] = [];
  /** uses_from_macos 展开名（macOS 系统库，不会重复安装——prompt 里向用户解释这层语义）。 */
  public usesFromMacos: string[] = [];
  /** 别名（alt name）。 */
  public aliases: string[] = [];
  /** 版本化配方（python@3.12 之类）。 */
  public versionedFormulae: string[] = [];
  /** bottle 可用 tag（平台覆盖口径）。 */
  public bottleTags: string[] = [];
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

// ---------------------------------------------------------------- AI 二期（P1-1/P1-3/P1-4）

/** insight 形态输出（P1-1 榜单 / P1-3 弃用 / P1-4 诊断共用）：一句话 + 要点 ≤3 + 行动提示。 */
export class AiInsightCard {
  /** 一句话解读（榜单卡片折叠行直接展示的文本） */
  public oneLiner: string = '';
  /** 展开后的要点 ≤3 */
  public points: string[] = [];
  /** 行动提示（可空；诊断卡里渲染成复制 chip） */
  public actionHint: string = '';

  public isValid(): boolean {
    return this.oneLiner.trim().length > 0 && this.points.length <= 3;
  }
}

/** 榜单解读的单包数字（P1-1）。数值 -1 = 该字段在本卡上下文里不可得。 */
export class AiBoardInsightEntry {
  public token: string = '';
  public rank: number = 0;
  /** 30 天安装量（内嵌 analytics 口径）。 */
  public installs30d: number = -1;
  /** 365 天安装量（-1 = 未取到）。 */
  public installs365d: number = -1;
  /** 前一月安装量（0 = 无历史，比较无意义）。 */
  public priorMonthly: number = 0;
  /** 增速（0 = 无历史）。 */
  public velocity: number = 0;
}

/** P1-1 榜单解读的 grounding 输入（A 级：全部数字来自目录统计，AI 只准原样引用）。 */
export class AiBoardInsightInput {
  /** 'board'（整榜多包）| 'featured'（单包聚焦卡） */
  public scope: string = 'board';
  /** 榜单 key（trending / fresh / …；featured 时也带上，供日志与缓存键）。 */
  public boardKey: string = '';
  /** 'formula' | 'cask' */
  public kind: string = 'formula';
  /** 快照日期（YYYY-MM-DD，来自目录快照；缓存键组成部分）。 */
  public snapshotDate: string = '';
  /** HEAD 安装量（-1 = 未知；≥0 时 UI 追加 head_note 行）。 */
  public headInstalls: number = -1;
  /** ghcr 拉取量（-1 = 未知；≥0 时 UI 追加 ghcr_note 行，口径不同单独标注）。 */
  public ghcrDownloads: number = -1;
  /** 榜内条目（board 截前 10；featured 恒 1 条）。 */
  public entries: AiBoardInsightEntry[] = [];
}

/** P1-3 弃用解读的 grounding 输入（A 级：全部来自 formula/cask 生命周期字段）。 */
export class AiLifecycleInput {
  public token: string = '';
  public kind: string = 'formula';
  /** 'deprecated' | 'disabled' */
  public state: string = 'deprecated';
  /** 弃用/禁用原因（deprecation_reason / disable_reason 原文）。 */
  public reason: string = '';
  /** 弃用日期（YYYY-MM-DD，空 = 未排期）。 */
  public deprecationDate: string = '';
  /** 禁用日期（YYYY-MM-DD，空 = 未排期）。 */
  public disableDate: string = '';
  /** 官方指定替代 formula（空 = 上游未指定）。 */
  public replacementFormula: string = '';
  /** 官方指定替代 cask（空 = 上游未指定）。 */
  public replacementCask: string = '';
}

/** P1-4 数据源诊断的 grounding 输入（A 级：probe 结构化结果；detail 为 B 级、已脱敏）。 */
export class AiDiagnosisInput {
  public sourceId: string = '';
  public sourceName: string = '';
  public baseUrl: string = '';
  /** HTTP 状态码（0 = 网络层失败，没拿到响应）。 */
  public httpCode: number = 0;
  /** 探测耗时 ms。 */
  public tookMs: number = 0;
  /** 失败原因码（invalid-url / dns-failed / …，与既有 probeReasonText 分支同源）。 */
  public reason: string = '';
  /** 探测补充诊断（bodyLen / content-type / 平台错误消息；**发送前已脱敏本机路径**）。 */
  public detail: string = '';
}

/**
 * 错误文本脱敏（spec §6 P1-4）：把疑似本机路径的片段替换成省略号再喂给模型。
 * 只做「替换」不做「判断是否泄露」——保守起见，凡是像路径的都打码（宁多勿漏）。
 * 纯字符串函数，单测直接覆盖（spec §9）。
 */
export function aiMaskLocalPaths(text: string): string {
  if (text.length === 0) {
    return text;
  }
  // HarmonyOS 应用沙盒：/data/app…、/data/storage…、/data/service…
  let out: string = text.replace(/\/data\/(app|storage|service|el2|el1)[A-Za-z0-9_\-./]*/g, '…');
  // macOS / Linux 用户目录：/Users/<name>/…
  out = out.replace(/\/Users\/[A-Za-z0-9_.\-]+[A-Za-z0-9_\-./]*/g, '…');
  // Windows 用户目录：C:\Users\<name>\…
  out = out.replace(/[A-Za-z]:\\Users\\[A-Za-z0-9_.\-]+[A-Za-z0-9_.\-\\]*/g, '…');
  return out;
}
