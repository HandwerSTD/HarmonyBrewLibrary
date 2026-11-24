/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

/**
 * 更新情报中心的类型（spec `docs/superpowers/specs/2026-11-23-release-intel-spec.md`）。
 *
 * 与 AiTypes 同规：全部 class 而非 interface——UI 要构造实例做兜底值（BrewDetailState
 * 的 `releaseIntel` 恒非 null 实例），@Prop/@State 传对象需要运行时形态；解析
 * provider 返回的 JSON 后逐字段填充校验，不把 JSON.parse 的结果直接当响应对象。
 */

import {
  AI_MAX_TOKENS_RI,
  RELEASE_INTEL_CONFIDENCE_FULL,
  RELEASE_INTEL_CONFIDENCE_NONE,
  RELEASE_INTEL_CONFIDENCE_PARTIAL,
} from '../constant/ReleaseIntelConstants';

/** 重大变更条目（AI 输出 `breaking_changes[]` 的一条）。 */
export class ReleaseIntelBreakingChange {
  /** 变更是什么（一句话） */
  public title: string = '';
  /** 对本机使用的影响 */
  public impact: string = '';
  /** 建议动作（改配置 / 迁移命令 / 查迁移指南；模型没有依据时允许为空串） */
  public action: string = '';
}

/** 安全相关声明（AI 输出 `security_claims[]` 的一条）。 */
export class ReleaseIntelSecurityClaim {
  /** 上游 Release Notes 里**原样转述**的安全信息（模型不得自行推断严重性） */
  public claim: string = '';
}

/**
 * AI 情报卡（spec §3.1 的输出 schema）。落盘缓存的就是它的 JSON。
 * 字段名用驼峰（对齐 AiExplainCard），与模型输出的 snake_case 在解析层逐字段映射。
 */
export class ReleaseIntelCard {
  /** 一句话：这次更新最值得注意什么 */
  public oneLiner: string = '';
  /** 新功能 ≤3 */
  public newFeatures: string[] = [];
  /** 修复 ≤3 */
  public fixes: string[] = [];
  /** 重大变更 ≤3（每条 title/impact/action） */
  public breakingChanges: ReleaseIntelBreakingChange[] = [];
  /** 安全相关 ≤2（上游自述，UI 侧加「未经漏洞库核验」标注，spec §6） */
  public securityClaims: ReleaseIntelSecurityClaim[] = [];
  /** 信息缺口 ≤3（notes 没覆盖的方面，如「无兼容性说明」） */
  public gaps: string[] = [];
  /** 信心档：full / partial / none */
  public confidence: string = RELEASE_INTEL_CONFIDENCE_NONE;

  public isValid(): boolean {
    if (this.oneLiner.trim().length === 0) {
      return false;
    }
    if (this.newFeatures.length > 3 || this.fixes.length > 3 ||
      this.breakingChanges.length > 3 || this.securityClaims.length > 2 ||
      this.gaps.length > 3) {
      return false;
    }
    for (let i: number = 0; i < this.breakingChanges.length; i++) {
      if (this.breakingChanges[i].title.trim().length === 0) {
        return false;
      }
    }
    for (let i: number = 0; i < this.securityClaims.length; i++) {
      if (this.securityClaims[i].claim.trim().length === 0) {
        return false;
      }
    }
    return this.confidence === RELEASE_INTEL_CONFIDENCE_FULL ||
      this.confidence === RELEASE_INTEL_CONFIDENCE_PARTIAL ||
      this.confidence === RELEASE_INTEL_CONFIDENCE_NONE;
  }
}

/** AI 任务的输入（spec G4：只含 token / 版本区间 / 剥标签 notes / diff JSON）。 */
export class ReleaseIntelInput {
  public token: string = '';
  public from: string = '';
  public to: string = '';
  /** 上游 Release Notes 纯文本（已剥 HTML、已截 ≤4KB，可能为空——空时任务侧直接跳过 AI） */
  public notes: string = '';
  /** FormulaDiffer 结果的 JSON 文本（依赖增删 / caveats 变化 / bottle 重打包） */
  public diffJson: string = '';
}

/** 零 AI 的结构化 diff（spec G3：全部来自本地对比，不可用时 baselineAvailable=false）。 */
export class ReleaseIntelDiff {
  /** 基线可用（基线库里有「已装版本」的配方快照）；false 时依赖对比不可用（F5） */
  public baselineAvailable: boolean = false;
  /** 新增运行依赖 */
  public depsAdded: string[] = [];
  /** 移除运行依赖 */
  public depsRemoved: string[] = [];
  /** 新增构建依赖 */
  public buildDepsAdded: string[] = [];
  /** caveats（安装注意事项）有变化 */
  public caveatsChanged: boolean = false;
  /** bottle 重打包（rebuild 变了，代码未变——例行修复的典型形态） */
  public bottleRepacked: boolean = false;
}

/** 版本跨度判定（SemverJudge 的输出）。 */
export class ReleaseIntelVerdict {
  /** major | minor | patch | revision | unknown */
  public kind: string = 'unknown';
  public from: string = '';
  public to: string = '';
}

/**
 * 详情页的情报快照（spec §4 卡片的数据源）。**恒非 null 实例 + hasReleaseIntel 开关**
 * （与 BrewDetailState.tldrPage/hasTldr 同规：ArkUI 的 if 不收窄联合类型）。
 * `card === null` 时 UI 渲染结构化区 + 缺口行 + notes 原文节选（AI 不可用时的降级）；
 * `hasReleaseIntel === false` 时整卡不渲染。
 */
export class ReleaseIntelSnapshot {
  public token: string = '';
  /** formula | cask（cask 在 v1 不装配情报卡，字段保留是为了档案回显） */
  public kind: string = '';
  public fromVersion: string = '';
  public toVersion: string = '';
  /** major | minor | patch | revision | unknown */
  public verdict: string = 'unknown';
  /** 零 AI 结构化区（G3） */
  public diff: ReleaseIntelDiff = new ReleaseIntelDiff();
  /** 缺口码（ReleaseIntelGap* 常量；空串 = 无缺口） */
  public gapCode: string = '';
  /** 发布页 URL（`{repo}/releases/tag/{tag}`；无来源时为空串，「查看原文」不渲染） */
  public sourceUrl: string = '';
  /** notes 因超限被截断（4KB），来源行提示 */
  public notesTruncated: boolean = false;
  /** AI 情报卡；null = 无 Key / AI 失败 / 缺口无 notes（只渲染结构化区，spec G1/G5） */
  public card: ReleaseIntelCard | null = null;
  /** AI 调过但失败（区别于「没配 Key 的静默」：UI 给重试入口） */
  public aiFailed: boolean = false;
  /**
   * AI 摘要进行中（v1.3.8 两阶段装配）：结构化区 + notes 原文先落卡，AI 段后台补跑，
   * 期间操作行的 AI 入口渲染 [spinner] AI 解析中。**瞬态字段**——只活在内存快照，
   * 从不落盘（snapshotFromJson 强制 false，同 loading 的口径）。
   */
  public aiPending: boolean = false;
  /**
   * notes 原文节选（≤700 字符，中英文原样）。AI 不可用（无 Key / 失败 / 调试期关 AI）
   * 时卡片用它渲染「原始发布说明」——上游原文直接展示，零编造（G5 缺口策略的补充：
   * 能给原文就不只给一句「AI 不可用」）。card 非 null 时 UI 不渲染该组。
   */
  public notesPreview: string = '';

  /**
   * notes 全文（extract 输出，≤4KB；v1.3.3）。卡片正文只渲染 `notesPreview`
   * （4 行口径），「查看全文」半模态渲染这里——只放内存，不落盘档案。
   */
  public notesFull: string = '';

  /**
   * 占位快照（v1.3.3）：情报获取期间 VM 先落的「版本号 + spinner」卡，
   * assemble 完成后整体替换。仅 VM 构造，service 产物恒为 false。
   */
  public loading: boolean = false;
  /** 本次快照完成时间（F7 的「数据截至 HH:mm」用它） */
  public fetchedAt: number = 0;
  /** true = 展示的是过期缓存且后台刷新也失败了（F7） */
  public stale: boolean = false;
}

/** 更新档案条目（spec G7）。内嵌情报卡 JSON——AI 缓存可能已被清理，档案必须自含内容。 */
export class ReleaseIntelArchiveEntry {
  public token: string = '';
  public kind: string = '';
  public from: string = '';
  public to: string = '';
  /** 升级完成时间（epoch ms） */
  public at: number = 0;
  /** 当时情报卡的 JSON 文本（可能为空串 = 当时没有 AI 卡） */
  public cardJson: string = '';
}

/** 档案解析的兜底值。 */
export function releaseIntelArchiveEntryOf(
  token: string, kind: string, from: string, to: string, at: number,
  cardJson: string): ReleaseIntelArchiveEntry {
  const entry: ReleaseIntelArchiveEntry = new ReleaseIntelArchiveEntry();
  entry.token = token;
  entry.kind = kind;
  entry.from = from;
  entry.to = to;
  entry.at = at;
  entry.cardJson = cardJson;
  return entry;
}

/**
 * 快照浅拷贝（v1.3.8 两阶段装配用）：AI 段完成后要带 card 落卡，但 @Prop 靠
 * **新对象引用**触发更新——原地改字段 UI 不刷新。diff/card 按引用共享是安全的：
 * 两者只被整体替换、从不原地改写。
 */
export function releaseIntelSnapshotFork(src: ReleaseIntelSnapshot): ReleaseIntelSnapshot {
  const out: ReleaseIntelSnapshot = new ReleaseIntelSnapshot();
  out.token = src.token;
  out.kind = src.kind;
  out.fromVersion = src.fromVersion;
  out.toVersion = src.toVersion;
  out.verdict = src.verdict;
  out.diff = src.diff;
  out.gapCode = src.gapCode;
  out.sourceUrl = src.sourceUrl;
  out.notesTruncated = src.notesTruncated;
  out.card = src.card;
  out.aiFailed = src.aiFailed;
  out.aiPending = src.aiPending;
  out.notesPreview = src.notesPreview;
  out.notesFull = src.notesFull;
  out.loading = src.loading;
  out.fetchedAt = src.fetchedAt;
  out.stale = src.stale;
  return out;
}

/** max_tokens 常量转发（AiTasks 侧 import 用，避免两条常量链互相牵扯）。 */
export function releaseIntelMaxTokens(): number {
  return AI_MAX_TOKENS_RI;
}
