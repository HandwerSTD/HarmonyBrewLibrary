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
 * AtomGit 打包提交条目（v1.1 G14：harmonybrew 源的包没有 GitHub 上游 release，
 * 「动过该 formula 文件的提交」就是它的打包更新记录）。字段取自
 * `GET /api/v5/repos/{owner}/{repo}/commits?path=...` 的 GitHub 兼容形状。
 */
export class ReleaseIntelPackCommit {
  /** 提交短 sha（前 7 位，UI 展示用） */
  public sha: string = '';
  /** 提交信息首行（≤120 字符截断） */
  public message: string = '';
  /** 提交日期（YYYY-MM-DD，取 commit.author.date 的日期部分） */
  public date: string = '';
  /** 提交页 URL（html_url；为空时该行不可点） */
  public url: string = '';
}

/**
 * 详情页的情报快照（spec §4 卡片的数据源）。**恒非 null 实例 + hasReleaseIntel 开关**
 * （与 BrewDetailState.tldrPage/hasTldr 同规：ArkUI 的 if 不收窄联合类型）。
 * `card === null` 时 UI 只渲染结构化区 + 缺口行；`hasReleaseIntel === false` 时整卡不渲染。
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
   * AtomGit 打包提交（v1.1 G14，仅 harmonybrew 源的包非空）。空数组 =
   * 非 harmonybrew 源 / 通道不可达（429 等，静默）/ tap 里没有提交——三种情况
   * UI 都不渲染该组（诚实降级，不编造）。
   */
  public packCommits: ReleaseIntelPackCommit[] = [];
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

/** max_tokens 常量转发（AiTasks 侧 import 用，避免两条常量链互相牵扯）。 */
export function releaseIntelMaxTokens(): number {
  return AI_MAX_TOKENS_RI;
}
