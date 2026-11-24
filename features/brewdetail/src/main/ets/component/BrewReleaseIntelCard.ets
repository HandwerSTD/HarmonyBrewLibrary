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
import type { ReleaseIntelCard } from '@ohos/brewcommon';
import { common } from '@kit.AbilityKit';

/**
 * Y · 更新情报卡（release intel spec §4；v1.3 起为 App Store「What's New」形态）。
 *
 * **定调（用户 2026-11-24）：真正的 App Store 风格更新日志卡片——卡内只放
 * 版本号、有用的信息、若干操作按钮。**因此本卡刻意做减法：
 *
 * - 第一行就是「版本 X」（App Store 语义：用户关心的是升到哪，不是卡片标题）；
 * - verdict（大版本升级 / 功能更新…）做副行，major 用警示色；
 * - 正文是 AI 一句话摘要（或 AI 缺席时的 notes 原文节选，零编造降级）；
 * - 重大变更 / 安全 / 修复 / 新功能全部扁平成带前缀的要点列表（总数封顶），
 *   不再有分区标题——摘要卡不是报表；
 * - 结构化 diff 压成几行小字（依赖增减 / caveats 变化），bottle 重打包这种
 *   用户无感的口径不渲染；
 * - AI 报告的 gaps（「notes 没讲什么」）是内部元信息，不渲染；
 * - 状态脚注（AI 失败 / 数据过期 / 原文截断）横排一行小字，不再三条竖排。
 *
 * ## 操作行（spec §4 / G6）
 *
 * 固定版本（复制 `brew pin <token>`，只有复制永不执行 G13）/ 忽略此版本 /
 * 暂停提醒（7 天 / 30 天 / 无限期菜单）/ 重新生成（AI 失败时才有，G8 force）/
 * 查看原文（外跳 `{repo}/releases/tag/{tag}`）。
 *
 * ## 缺口行（spec §5）
 *
 * gapCode 非空时渲染对应缺口文案（F1/F2/F3/F4），视觉弱化（secondary 色，非红非报错）：
 * 「没拿到上游情报」是数据状态，不是故障。F2–F4 不提供重试语义，F1（网络）由「重新生成」覆盖。
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

  /** 通用外跳：来源页外跳共用。 */
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

  /** verdict 词（major 警示色；unknown 也给词，淡化处理） */
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

  /**
   * 正文要点（v1.3 App Store 形态）：breaking → security → fixes → new 扁平成
   * 带前缀的 bullet，总数封顶 RELEASE_INTEL_BULLET_MAX（克制：摘要卡不是全文）。
   * 每条是 `$r(前缀键, 文本)` ——类别前缀走资源，正文是字符串拼接（合法：
   * 只有「资源嵌资源」才渲染不出）。
   */
  private bulletItems(): ResourceStr[] {
    const card: ReleaseIntelCard | null = this.snapshot.card;
    const items: ResourceStr[] = [];
    if (card === null) {
      return items;
    }
    for (let i: number = 0; i < card.breakingChanges.length && items.length < RELEASE_INTEL_BULLET_MAX; i++) {
      const one = card.breakingChanges[i];
      let text: string = one.title;
      if (one.impact.length > 0) {
        text += `：${one.impact}`;
      }
      if (one.action.length > 0) {
        text += `（${one.action}）`;
      }
      items.push($r('app.string.release_intel_bullet_breaking', text));
    }
    for (let i: number = 0; i < card.securityClaims.length && items.length < RELEASE_INTEL_BULLET_MAX; i++) {
      items.push($r('app.string.release_intel_bullet_security', card.securityClaims[i].claim));
    }
    for (let i: number = 0; i < card.fixes.length && items.length < RELEASE_INTEL_BULLET_MAX; i++) {
      items.push($r('app.string.release_intel_bullet_fix', card.fixes[i]));
    }
    for (let i: number = 0; i < card.newFeatures.length && items.length < RELEASE_INTEL_BULLET_MAX; i++) {
      items.push($r('app.string.release_intel_bullet_new', card.newFeatures[i]));
    }
    return items;
  }

  /** 结构化 diff 是否有可展示内容（baselineAvailable=false 时整区不渲染，F5） */
  private diffHasContent(): boolean {
    const diff = this.snapshot.diff;
    return diff.baselineAvailable && (diff.depsAdded.length > 0 || diff.depsRemoved.length > 0 ||
      diff.buildDepsAdded.length > 0 || diff.caveatsChanged);
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
      // ---------- 头部：版本号（App Store 语义） + verdict 副行 ----------
      Text($r('app.string.release_intel_version_of', this.snapshot.toVersion))
        .fontSize($r('sys.float.Body_M'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .width('100%')
      Text(this.verdictLabel())
        .fontSize($r('sys.float.Body_S'))
        .fontColor(this.snapshot.verdict === 'major' ? $r('sys.color.warning') :
        $r('sys.color.font_tertiary'))
        .width('100%')

      // ---------- 正文：AI 摘要 / AI 缺席时的 notes 原文节选（零编造降级） ----------
      if (this.snapshot.card !== null && this.snapshot.card.oneLiner.length > 0) {
        Text(this.snapshot.card.oneLiner)
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
      }
      // AI 失败（aiFailed）也降级渲染原文——正文缺席才是最伤用户的形态（v1.3 自查修正）
      if (this.snapshot.card === null && this.snapshot.notesPreview.length > 0) {
        Text(this.snapshot.notesPreview)
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
      }

      // ---------- 要点列表（扁平带前缀，空卡整体不渲染，G5） ----------
      ForEach(this.bulletItems(), (item: ResourceStr) => {
        Text(item)
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('sys.color.font_primary'))
          .width('100%')
          .padding({ left: 10 })
      }, (item: ResourceStr, index: number) => `bullet_${index}`)

      // ---------- 结构化 diff（G3 零 AI）：压成几行小字，无分区标题 ----------
      if (this.diffHasContent()) {
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
        if (this.snapshot.diff.caveatsChanged) {
          this.DiffLine($r('app.string.release_intel_caveats_changed'), '')
        }
      }

      // ---------- 通道缺口行（F1/F2/F3/F4；视觉弱化：secondary 色，非红非报错） ----------
      if (this.snapshot.gapCode.length > 0) {
        Text(this.gapText())
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')
      }

      // ---------- 状态脚注（横排一行小字：AI 失败 / 数据过期 / 原文截断） ----------
      if (this.snapshot.aiFailed || this.snapshot.stale || this.snapshot.notesTruncated) {
        Row({ space: 8 }) {
          if (this.snapshot.aiFailed) {
            Text($r('app.string.release_intel_ai_failed'))
              .fontSize($r('sys.float.Body_S'))
              .fontColor($r('sys.color.font_tertiary'))
          }
          if (this.snapshot.stale) {
            Text($r('app.string.release_intel_stale'))
              .fontSize($r('sys.float.Body_S'))
              .fontColor($r('sys.color.font_tertiary'))
          }
          if (this.snapshot.notesTruncated) {
            Text($r('app.string.release_intel_truncated'))
              .fontSize($r('sys.float.Body_S'))
              .fontColor($r('sys.color.font_tertiary'))
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }

      // ---------- 来源声明行（G13 隐私口径：说清楚归纳依据） ----------
      Text(this.snapshot.card === null ? $r('app.string.release_intel_source') :
      $r('app.string.release_intel_ai_badge'))
        .fontSize($r('sys.float.Body_S'))
        .fontColor($r('sys.color.font_tertiary'))
        .width('100%')
      if (this.snapshot.card !== null && this.snapshot.card.securityClaims.length > 0) {
        Text($r('app.string.release_intel_security_note'))
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_tertiary'))
          .width('100%')
      }

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
        if (this.snapshot.sourceUrl.length > 0) {
          Text($r('app.string.release_intel_view_source'))
            .fontSize($r('sys.float.Body_S'))
            .fontColor($r('sys.color.font_emphasize'))
            .onClick(() => {
              this.openSource();
            })
            .padding({ right: 16 })
        }
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

/** 要点列表封顶（App Store 摘要克制口径：重大变更/安全/修复/新功能合计不超过 6 条） */
const RELEASE_INTEL_BULLET_MAX: number = 6;
