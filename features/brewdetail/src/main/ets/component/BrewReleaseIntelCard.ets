/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { Logger, PasteboardUtil } from '@ohos/common';
import {
  RELEASE_INTEL_GAP_NET,
  RELEASE_INTEL_GAP_NOTES,
  RELEASE_INTEL_GAP_REPO,
  RELEASE_INTEL_GAP_TAG,
  RELEASE_INTEL_PAUSE_30D_MS,
  RELEASE_INTEL_PAUSE_7D_MS,
  RELEASE_INTEL_PAUSE_FOREVER_MS,
  ReleaseIntelSnapshot,
} from '@ohos/brewcommon';
import type {
  ReleaseIntelBreakingChange,
  ReleaseIntelSecurityClaim,
} from '@ohos/brewcommon';
import { common } from '@kit.AbilityKit';

/**
 * Y · 更新情报卡（release intel spec §4）。
 *
 * 与 D1 讲解卡（`BrewAiExplainCard`）同一条视觉基调：像一段归纳，不是一张表——
 * 分区标题弱化、分区从属靠字重与留白表达；**空数组分区整体不渲染**（G5）。
 *
 * 与 D1 的两点结构差异：
 * - **数据驱动直渲**：本卡没有 D1 式的入口按钮——出现时机由装配层决定
 *   （`BrewDetailState.hasReleaseIntel` 开关：本机已装且 OUTDATED 的 formula 才装配）；
 * - **结构化区先行（G1/G3）**：verdict / diff 零 AI 同步可得，AI 卡（`snapshot.card`）
 *   缺席时结构化区照常渲染，AI 失败只落脚注（F6 一期降级）。
 *
 * ## 操作行（spec §4 / G6）
 *
 * - 固定版本：复制 `brew pin <token>` 命令文本，**只有复制，永不执行**（G13；
 *   brew pin 仅 formula 有语义，cask 的 pinCommand 恒空串、入口不渲染）；
 * - 忽略此版本 / 撤销忽略：精确到 to 版本的忽略，H 通知计数随之变化（G6）；
 * - 暂停提醒：7 天 / 30 天 / 无限期三档菜单；
 * - 重新生成：旁路 AI 缓存强制取数（G8，与 D1 的 force 同口径）；
 * - 查看原文：外跳 `{repo}/releases/tag/{tag}`。
 *
 * ## 缺口行（spec §5）
 *
 * gapCode 非空时渲染对应缺口文案（F1/F2/F3/F4），视觉弱化（secondary 色，非红非报错）：
 * 「没拿到上游情报」是数据状态，不是故障。F2–F4 不提供重试语义（重试解决不了
 * 「上游不是 GitHub」「没有匹配 tag」这类事实性缺口），F1（网络）由「重新生成」覆盖。
 */
@Component
export struct BrewReleaseIntelCard {
  /** 情报快照（装配层产出，恒非 null；`hasReleaseIntel=false` 时整卡不渲染） */
  @Prop @Require snapshot: ReleaseIntelSnapshot;
  /** `brew pin <token>` 命令文本（空串 = 不渲染固定入口，cask / 名称不安全时为空） */
  @Prop pinCommand: string = '';
  /** 当前 to 版本是否已被忽略（控制「忽略此版本 / 撤销忽略」的文案切换） */
  @Prop ignored: boolean = false;
  /** 忽略 / 撤销忽略（页面处理器：写 ReleaseIntelPrefs + 翻 state 开关） */
  onToggleIgnore: () => void = () => {
  };
  /** 暂停提醒（页面处理器：写 ReleaseIntelPrefs；durationMs=0 表示无限期） */
  onPause: (durationMs: number) => void = () => {
  };
  /** 重新生成（页面处理器：VM 旁路缓存强制重跑） */
  onRegenerate: () => void = () => {
  };

  /** 「查看原文」外跳（BrewTldrSectionView.openRepo 同款：UIAbilityContext.openLink） */
  private openSource(): void {
    if (this.snapshot.sourceUrl.length === 0) {
      return;
    }
    this.openUrl(this.snapshot.sourceUrl);
  }

  /** 通用外跳：来源页 / 打包提交页共用（harmonybrew 打包记录行也用，v1.1 G14）。 */
  private openUrl(url: string): void {
    const host: Context | undefined = this.getUIContext().getHostContext();
    if (host === undefined) {
      Logger.warn(TAG, 'release intel openUrl: host context missing');
      return;
    }
    const ability: common.UIAbilityContext = host as common.UIAbilityContext;
    ability.openLink(url).catch((error: Error) => {
      Logger.warn(TAG, `release intel openUrl failed. reason=${error.message}`);
    });
  }

  /** 版本跨度徽章文案（verdict.kind → 资源键；unknown 也给词，徽章淡化处理） */
  private verdictLabel(): ResourceStr {
    const kind: string = this.snapshot.verdict;
    if (kind === 'major') {
      return $r('app.string.release_intel_verdict_major');
    }
    if (kind === 'minor') {
      return $r('app.string.release_intel_verdict_minor');
    }
    if (kind === 'patch') {
      return $r('app.string.release_intel_verdict_patch');
    }
    if (kind === 'revision') {
      return $r('app.string.release_intel_verdict_revision');
    }
    return $r('app.string.release_intel_verdict_unknown');
  }

  /** 结构化 diff 是否有可展示内容（baselineAvailable=false 时不渲染依赖对比区，F5） */
  private diffHasContent(): boolean {
    const diff = this.snapshot.diff;
    return diff.baselineAvailable && (diff.depsAdded.length > 0 || diff.depsRemoved.length > 0 ||
      diff.buildDepsAdded.length > 0 || diff.caveatsChanged || diff.bottleRepacked);
  }

  /** 依赖名称列表的展示串：去空、去重、逗号连接；全空返回空串（调用方判空跳过） */
  private namesLabel(names: string[]): string {
    const seen: Set<string> = new Set<string>();
    const parts: string[] = [];
    for (const name of names) {
      const trimmed: string = name.trim();
      if (trimmed.length > 0 && !seen.has(trimmed)) {
        seen.add(trimmed);
        parts.push(trimmed);
      }
    }
    return parts.join(', ');
  }

  build() {
    Column({ space: 12 }) {
      // ---------- 标题行：标题 + 跨度/安全徽章 ----------
      Row() {
        Text($r('app.string.release_intel_title'))
          .fontSize($r('sys.float.Body_M'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .layoutWeight(1)
        if (this.snapshot.card !== null && this.snapshot.card.securityClaims.length > 0) {
          Text($r('app.string.release_intel_security'))
            .fontSize($r('sys.float.Body_S'))
            .fontColor($r('sys.color.warning'))
            .margin({ right: $r('sys.float.padding_level2') })
        }
        Text(this.verdictLabel())
          .fontSize($r('sys.float.Body_S'))
          .fontColor(this.snapshot.verdict === 'major' ? $r('sys.color.warning') :
          $r('sys.color.font_tertiary'))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 版本区间（from/to 都是本地事实：已装版本 → 源上最新版本）
      Text(`${this.snapshot.fromVersion} → ${this.snapshot.toVersion}`)
        .fontSize($r('sys.float.Body_S'))
        .fontColor($r('sys.color.font_secondary'))
        .width('100%')

      // ---------- AI 一句话（G1：card 缺席时整区不渲染，不渲染占位） ----------
      if (this.snapshot.card !== null && this.snapshot.card.oneLiner.length > 0) {
        Text(this.snapshot.card.oneLiner)
          .fontSize($r('sys.float.Body_M'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .width('100%')
      }

      // ---------- 重大变更（AI 区；空数组整体不渲染，G5） ----------
      if (this.snapshot.card !== null && this.snapshot.card.breakingChanges.length > 0) {
        this.SectionTitle($r('app.string.release_intel_major'))
        ForEach(this.snapshot.card.breakingChanges, (item: ReleaseIntelBreakingChange) => {
          Column({ space: 2 }) {
            Text(item.title)
              .fontSize($r('sys.float.Body_M'))
              .fontColor($r('sys.color.font_primary'))
              .width('100%')
              .padding({ left: 10 })
            if (item.impact.length > 0) {
              Text(item.impact)
                .fontSize($r('sys.float.Body_S'))
                .fontColor($r('sys.color.font_secondary'))
                .width('100%')
                .padding({ left: 10 })
            }
            if (item.action.length > 0) {
              // 建议动作只是文本提示；执行入口不存在（G13）
              Text(item.action)
                .fontSize($r('sys.float.Body_S'))
                .fontColor($r('sys.color.font_emphasize'))
                .width('100%')
                .padding({ left: 10 })
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }, (item: ReleaseIntelBreakingChange, index: number) => `brk_${index}`)
      }

      // ---------- 安全相关（上游自述 + 未经核验标注，spec §6） ----------
      if (this.snapshot.card !== null && this.snapshot.card.securityClaims.length > 0) {
        this.SectionTitle($r('app.string.release_intel_security'))
        ForEach(this.snapshot.card.securityClaims, (item: ReleaseIntelSecurityClaim) => {
          Text(item.claim)
            .fontSize($r('sys.float.Body_M'))
            .fontColor($r('sys.color.font_primary'))
            .width('100%')
            .padding({ left: 10 })
        }, (item: ReleaseIntelSecurityClaim, index: number) => `sec_${index}`)
        Text($r('app.string.release_intel_security_note'))
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_tertiary'))
          .width('100%')
      }

      // ---------- 修复 / 新功能（空数组整体不渲染） ----------
      if (this.snapshot.card !== null && this.snapshot.card.fixes.length > 0) {
        this.SectionTitle($r('app.string.release_intel_fixes'))
        ForEach(this.snapshot.card.fixes, (item: string) => {
          this.Bullet(item)
        }, (item: string, index: number) => `fix_${index}`)
      }
      if (this.snapshot.card !== null && this.snapshot.card.newFeatures.length > 0) {
        this.SectionTitle($r('app.string.release_intel_new'))
        ForEach(this.snapshot.card.newFeatures, (item: string) => {
          this.Bullet(item)
        }, (item: string, index: number) => `new_${index}`)
      }

      // ---------- AI 报告的信息缺口（notes 没覆盖的方面） ----------
      if (this.snapshot.card !== null && this.snapshot.card.gaps.length > 0) {
        this.SectionTitle($r('app.string.release_intel_gap_diff'))
        ForEach(this.snapshot.card.gaps, (item: string) => {
          this.Bullet(item)
        }, (item: string, index: number) => `agap_${index}`)
      }

      // ---------- 结构化依赖对比（G3：零 AI；baseline 缺失整区不渲染，F5） ----------
      if (this.diffHasContent()) {
        this.SectionTitle($r('app.string.release_intel_diff_title'))
        if (this.snapshot.diff.depsAdded.length > 0) {
          this.DiffLine($r('app.string.release_intel_deps_add'),
            this.namesLabel(this.snapshot.diff.depsAdded))
        }
        if (this.snapshot.diff.buildDepsAdded.length > 0) {
          this.DiffLine($r('app.string.release_intel_deps_build_add'),
            this.namesLabel(this.snapshot.diff.buildDepsAdded))
        }
        if (this.snapshot.diff.depsRemoved.length > 0) {
          this.DiffLine($r('app.string.release_intel_deps_remove'),
            this.namesLabel(this.snapshot.diff.depsRemoved))
        }
        if (this.snapshot.diff.bottleRepacked) {
          this.DiffLine($r('app.string.release_intel_deps_repack'), '')
        }
        if (this.snapshot.diff.caveatsChanged) {
          this.DiffLine($r('app.string.release_intel_caveats_changed'), '')
        }
      }

      // ---------- 原始发布说明（AI 不可用时的降级：上游 notes 原文节选,零编造） ----------
      if (this.snapshot.card === null && !this.snapshot.aiFailed &&
        this.snapshot.notesPreview.length > 0) {
        this.SectionTitle($r('app.string.release_intel_notes_preview'))
        Text(this.snapshot.notesPreview)
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
      }

      // ---------- 通道缺口行（F1/F2/F3/F4；视觉弱化：secondary 色，非红非报错） ----------
      if (this.snapshot.gapCode.length > 0) {
        Text(this.gapText())
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
      }

      // ---------- 底部状态脚注（F6 AI 失败 / F7 缓存过期 / notes 截断） ----------
      if (this.snapshot.aiFailed) {
        Text($r('app.string.release_intel_ai_failed'))
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_tertiary'))
          .width('100%')
      }
      if (this.snapshot.stale) {
        Text($r('app.string.release_intel_stale'))
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_tertiary'))
          .width('100%')
      }
      if (this.snapshot.notesTruncated) {
        Text($r('app.string.release_intel_truncated'))
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_tertiary'))
          .width('100%')
      }

      // ---------- 来源与声明行（G13 隐私口径：说清楚归纳依据） ----------
      Row() {
        Text(this.snapshot.card === null ? $r('app.string.release_intel_source') :
        $r('app.string.release_intel_ai_badge'))
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_tertiary'))
          .layoutWeight(1)
        if (this.snapshot.sourceUrl.length > 0) {
          Text($r('app.string.release_intel_view_source'))
            .fontSize($r('sys.float.Body_S'))
            .fontColor($r('sys.color.font_emphasize'))
            .onClick(() => {
              this.openSource();
            })
            .padding({ left: 8 })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // ---------- 操作行（G6：全部是策略与复制，没有任何执行入口） ----------
      Flex({ wrap: FlexWrap.Wrap, alignItems: ItemAlign.Center }) {
        if (this.pinCommand.length > 0) {
          Text($r('app.string.release_intel_pin'))
            .fontSize($r('sys.float.Body_S'))
            .fontColor($r('sys.color.font_emphasize'))
            .onClick(() => {
              PasteboardUtil.copyText(this.pinCommand);
            })
            .padding({ right: 16 })
        }
        Text(this.ignored ? $r('app.string.release_intel_unignore') :
        $r('app.string.release_intel_ignore'))
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_emphasize'))
          .onClick(() => {
            this.onToggleIgnore();
          })
          .padding({ right: 16 })
        Text($r('app.string.release_intel_pause'))
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_emphasize'))
          .bindMenu(this.pauseMenuItems())
          .padding({ right: 16 })
        // 重新生成只在有 AI 产物或 AI 失败待重试时有意义;结构化-only(无 Key/调试期)
        // 不渲染,避免点了没反应的「假按钮」。
        if (this.snapshot.card !== null || this.snapshot.aiFailed) {
          Text($r('app.string.ai_d1_regen'))
            .fontSize($r('sys.float.Body_S'))
            .fontColor($r('sys.color.font_emphasize'))
            .onClick(() => {
              this.onRegenerate();
            })
            .padding({ right: 16 })
        }
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .borderRadius($r('sys.float.corner_radius_level8'))
  }

  /** 缺口码 → 文案（spec §5；F2–F4 是事实性缺口，不给「重试」误导） */
  private gapText(): ResourceStr {
    const code: string = this.snapshot.gapCode;
    if (code === RELEASE_INTEL_GAP_REPO) {
      return $r('app.string.release_intel_gap_repo');
    }
    if (code === RELEASE_INTEL_GAP_TAG) {
      return $r('app.string.release_intel_gap_tag');
    }
    if (code === RELEASE_INTEL_GAP_NET) {
      return $r('app.string.release_intel_gap_net');
    }
    if (code === RELEASE_INTEL_GAP_NOTES) {
      return $r('app.string.release_intel_gap_empty');
    }
    return $r('app.string.release_intel_gap_net');
  }

  /** 暂停提醒的三档菜单（spec §4：7 天 / 30 天 / 无限期；bindMenu 先例 BrewSourceSettingView） */
  private pauseMenuItems(): MenuElement[] {
    const items: Array<MenuElement> = [
      {
        value: $r('app.string.release_intel_pause_7'),
        action: () => {
          this.onPause(RELEASE_INTEL_PAUSE_7D_MS);
        },
      },
      {
        value: $r('app.string.release_intel_pause_30'),
        action: () => {
          this.onPause(RELEASE_INTEL_PAUSE_30D_MS);
        },
      },
      {
        value: $r('app.string.release_intel_pause_forever'),
        action: () => {
          this.onPause(RELEASE_INTEL_PAUSE_FOREVER_MS);
        },
      },
    ];
    return items;
  }

  /** 分区标题：弱化的引导词（与 D1 同款，spec §4 视觉基调） */
  @Builder
  SectionTitle(label: ResourceStr) {
    Text(label)
      .fontSize($r('sys.float.Body_S'))
      .fontWeight(FontWeight.Normal)
      .fontColor($r('sys.color.font_tertiary'))
      .width('100%')
  }

  /** 要点行：缩进无符号（D1 同款） */
  @Builder
  Bullet(text: string) {
    Text(text)
      .fontSize($r('sys.float.Body_M'))
      .fontColor($r('sys.color.font_primary'))
      .width('100%')
      .padding({ left: 10 })
  }

  /**
   * 结构化 diff 行：标签与内容分列渲染。**不做字符串拼接**——ResourceStr 嵌进
   * 模板串只会渲染出 Resource 对象而不是本地化文案，这是 ArkUI 的硬约束。
   */
  @Builder
  DiffLine(label: ResourceStr, value: string) {
    Row() {
      Text(label)
        .fontSize($r('sys.float.Body_S'))
        .fontColor($r('sys.color.font_secondary'))
      if (value.length > 0) {
        Text(value)
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_secondary'))
          .layoutWeight(1)
          .padding({ left: 6 })
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ left: 10 })
  }
}

/** 打点 tag（与 sentinel/ai 的文件级常量同规） */
const TAG: string = '[release-intel]';
