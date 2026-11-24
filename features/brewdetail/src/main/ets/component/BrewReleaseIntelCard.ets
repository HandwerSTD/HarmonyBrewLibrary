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
 * - 正文默认是 notes 原文节选（约 4 行，零编造），AI 解析后可切换视图；
 * - 重大变更 / 安全 / 修复 / 新功能全部扁平成带前缀的要点列表（总数封顶）；
 * - 结构化 diff 压成几行小字（依赖增减 / caveats 变化）；AI gaps 不渲染；
 * - 状态脚注（AI 失败 / 数据过期 / 原文截断）横排一行小字。
 *
 * ## v1.3.3（用户定调）三件交互
 *
 * - **占位卡**：`snapshot.loading=true` 时只渲染「版本号 + spinner」——情报获取
 *   期间卡就上屏（更新是主打功能），assemble 完成后 VM 整体替换快照；
 * - **查看全文**：原文截断时操作行给「查看全文」（半模态,hero + notes 全文,
 *   `snapshot.notesFull`,只放内存）;节选正文封顶 4 行 ellipsis（v1.3.5）。
 * - **手动 AI 解析**：自动解析关闭时操作行给「AI 解析」入口(v1.3.5 并入操作行
 *   文字链)——解析中 spinner,完成前正文一直是原文,完成后自动切到 AI 视图
 *   （@Watch 捕获 card 落地）。
 *
 * ## 操作行（v1.3.5:单行文字链,全部同款不强调）
 *
 * 固定版本（复制 `brew pin <token>`，只有复制永不执行 G13）/「忽略」合并菜单
 * （忽略此版本或撤销 + 暂停 7 天 / 30 天 / 无限期三档）/ 发布页外跳
 * `{repo}/releases/tag/{tag}` / 手动 AI 解析（自动解析关闭时;解析中 spinner）/
 * 查看全文（截断且全文在手,半模态）/ 重新生成（AI 失败时才有,G8 force）。
 *
 * ## 缺口行（spec §5）
 *
 * gapCode 非空时渲染对应缺口文案（F1/F2/F3/F4），视觉弱化（secondary 色，非红非报错）：
 * 「没拿到上游情报」是数据状态，不是故障。
 */
@Component
export struct BrewReleaseIntelCard {
  /** 情报快照（装配层产出，恒非 null；`hasReleaseIntel=false` 时整卡不渲染） */
  @Prop @Watch('onSnapshotUpdated') @Require snapshot: ReleaseIntelSnapshot;
  /** `brew pin <token>` 命令文本（空串 = 不渲染固定入口，cask / 名称不安全时为空） */
  @Prop pinCommand: string = '';
  /** 当前 to 版本是否已被忽略（控制「忽略此版本 / 撤销忽略」的文案切换） */
  @Prop ignored: boolean = false;
  /** 是否已配 AI Key（无 Key 不渲染手动「AI 解析」按钮） */
  @Prop hasKey: boolean = false;
  /** 忽略 / 撤销忽略（页面处理器：写 ReleaseIntelPrefs + 翻 state 开关） */
  onToggleIgnore: () => void = () => {
  };
  /** 暂停提醒（页面处理器：写 ReleaseIntelPrefs；durationMs=0 表示无限期） */
  onPause: (durationMs: number) => void = () => {
  };
  /** 重新生成（页面处理器：VM 旁路缓存强制重跑，manualAi=true） */
  onRegenerate: () => void = () => {
  };
  /**
   * 手动「AI 解析」（页面处理器：VM 用 stash 输入补跑 AI 段）。
   * 返回 Promise——按钮在解析期间禁用 + spinner，resolve 后收尾。
   */
  onManualAi: () => Promise<void> = () => Promise.resolve();
  /** 正文视图开关：默认展示原文，「AI 解析」点按后展示 AI 解析、按钮变「展示原文」 */
  @State showOriginal: boolean = true;
  /** 手动 AI 解析进行中（按钮禁用 + spinner；完成前正文保持原文） */
  @State aiRequesting: boolean = false;
  /** 「查看全文」半模态开关 */
  @State sheetShown: boolean = false;

  /** 手动「AI 解析」按钮可见性：有原文、有 Key、AI 没产物也没在失败态、不在占位期 */
  private manualAiVisible(): boolean {
    return !this.snapshot.loading && this.snapshot.card === null && !this.snapshot.aiFailed &&
      this.hasKey && this.snapshot.notesPreview.length > 0;
  }

  /**
   * 快照替换回调（@Watch）：手动解析完成时 card 从 null 变为有值——把正文切到
   * AI 视图（用户定调「解析完成后再替换为 AI 解析」）。自动流不受影响
   * （aiRequesting=false 不动 showOriginal）。
   */
  onSnapshotUpdated(): void {
    if (this.aiRequesting && this.snapshot.card !== null) {
      this.showOriginal = false;
    }
  }

  /** 手动解析点击：防重入 → 回调 → 收尾（卡片文案由 @Watch 切） */
  private handleManualAi(): void {
    if (this.aiRequesting) {
      return;
    }
    this.aiRequesting = true;
    this.onManualAi()
      .then(() => {
        if (this.snapshot.card === null && !this.snapshot.aiFailed) {
          Logger.info(TAG, 'release intel manual ai finished without card');
        }
      })
      .catch((error: Error) => {
        Logger.warn(TAG, `release intel manual ai click failed. reason=${error.message}`);
      })
      .finally(() => {
        this.aiRequesting = false;
      });
  }

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

  /** 当前是否处于「AI 解析」正文视图（card 缺席时恒否——正文恒为原文，零编造） */
  private showAiBody(): boolean {
    return !this.showOriginal && this.snapshot.card !== null;
  }

  /** AI 一句话摘要（card 缺席返回空串；UI 块内不收窄联合类型，取值收敛到方法里） */
  private aiOneLiner(): string {
    const card: ReleaseIntelCard | null = this.snapshot.card;
    return card === null ? '' : card.oneLiner;
  }

  /** 安全免责行判据：仅 AI 解析视图且存在安全条目时显示 */
  private showSecurityNote(): boolean {
    const card: ReleaseIntelCard | null = this.snapshot.card;
    return !this.showOriginal && card !== null && card.securityClaims.length > 0;
  }

  /** 「查看全文」按钮可见性：正文被截断且全文在手（半模态渲染 notesFull） */
  private viewFullVisible(): boolean {
    return this.snapshot.notesTruncated && this.snapshot.notesFull.length > 0;
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
      // ---------- 头部：版本号 + verdict 标签同行（App Store 语义；v1.3.1 用户定调） ----------
      Row({ space: 8 }) {
        Text($r('app.string.release_intel_version_of', this.snapshot.toVersion))
          .fontSize($r('sys.float.Body_M'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
        Text(this.verdictLabel())
          .fontSize($r('sys.float.Body_S'))
          .fontColor(this.snapshot.verdict === 'major' ? $r('sys.color.warning') :
          $r('sys.color.font_tertiary'))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // ---------- 占位期（v1.3.3）：版本行之外只有 spinner，不渲染任何正文/操作 ----------
      if (this.snapshot.loading) {
        Row({ space: 8 }) {
          LoadingProgress()
            .width(16)
            .height(16)
            .color($r('sys.color.font_tertiary'))
          Text($r('app.string.release_intel_fetching'))
            .fontSize($r('sys.float.Body_S'))
            .fontColor($r('sys.color.font_tertiary'))
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ top: 4, bottom: 4 })
      }

      // ---------- 完整期：视图切换 / 正文 / diff / 缺口 / 脚注 / 操作行 ----------
      if (!this.snapshot.loading) {
        // 正文视图切换：默认原文；AI 可用时按钮在「AI 解析 / 展示原文」间翻转
        if (this.snapshot.card !== null && this.snapshot.notesPreview.length > 0) {
          Text(this.showOriginal ? $r('app.string.release_intel_toggle_ai') :
          $r('app.string.release_intel_toggle_original'))
            .fontSize($r('sys.float.Body_S'))
            .fontColor($r('sys.color.font_emphasize'))
            .onClick(() => {
              this.showOriginal = !this.showOriginal;
            })
        }

        // 正文：原文（默认，零编造）/ AI 解析（点按切换；card 缺席时恒为原文）。
        // 节选展示封顶 4 行 + ellipsis（v1.3.5 用户定调;数据层仍是 160 字符节选）
        if (this.showOriginal || this.snapshot.card === null) {
          if (this.snapshot.notesPreview.length > 0) {
            Text(this.snapshot.notesPreview)
              .fontSize($r('sys.float.Body_S'))
              .fontColor($r('sys.color.font_secondary'))
              .width('100%')
              .maxLines(4)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        if (this.showAiBody()) {
          if (this.aiOneLiner().length > 0) {
            Text(this.aiOneLiner())
              .fontSize($r('sys.float.Body_M'))
              .fontColor($r('sys.color.font_primary'))
              .width('100%')
          }
          // 要点列表（扁平带前缀，空数组整体不渲染，G5）
          ForEach(this.bulletItems(), (item: ResourceStr) => {
            Text(item)
              .fontSize($r('sys.float.Body_M'))
              .fontColor($r('sys.color.font_primary'))
              .width('100%')
              .padding({ left: 10 })
          }, (item: ResourceStr, index: number) => `bullet_${index}`)
        }

        // 结构化 diff（G3 零 AI）：压成几行小字，无分区标题
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

        // 通道缺口行（F1/F2/F3/F4；视觉弱化：secondary 色，非红非报错）
        if (this.snapshot.gapCode.length > 0) {
          Text(this.gapText())
            .fontSize($r('sys.float.Body_S'))
            .fontColor($r('sys.color.font_secondary'))
            .width('100%')
        }

        // 状态脚注（横排一行小字：AI 失败 / 数据过期 / 原文截断）
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

        // 安全声明免责（仅 AI 解析视图显示；上游自述未经核验）
        if (this.showSecurityNote()) {
          Text($r('app.string.release_intel_security_note'))
            .fontSize($r('sys.float.Body_S'))
            .fontColor($r('sys.color.font_tertiary'))
            .width('100%')
        }

        // 操作行（G6：全部是策略与复制，没有任何执行入口）。
        // v1.3.5 用户定调:「AI 解析」与「查看全文」并入本行、同款文字链不强调
        // （手动解析与查看全文条件互不重叠,「重新生成」与手动解析互斥渲染）。
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
          Text($r('app.string.release_intel_ignore_menu'))
            .fontSize($r('sys.float.Body_S'))
            .fontColor($r('sys.color.font_emphasize'))
            .bindMenu(this.ignoreMenuItems())
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
          // 手动「AI 解析」（v1.3.5 并入操作行）:解析中 spinner 占位替代文字
          // （防重入由 handleManualAi 兜底）,完成前正文保持原文,完成后 @Watch 切视图
          if (this.manualAiVisible()) {
            if (this.aiRequesting) {
              LoadingProgress()
                .width(16)
                .height(16)
                .color($r('sys.color.font_emphasize'))
                .padding({ right: 16 })
            } else {
              Text($r('app.string.release_intel_toggle_ai'))
                .fontSize($r('sys.float.Body_S'))
                .fontColor($r('sys.color.font_emphasize'))
                .onClick(() => {
                  this.handleManualAi();
                })
                .padding({ right: 16 })
            }
          }
          // 「查看全文」:在手动 AI 解析右侧（v1.3.5 用户定调）,半模态全文零编造
          if (this.viewFullVisible()) {
            Text($r('app.string.release_intel_view_full'))
              .fontSize($r('sys.float.Body_S'))
              .fontColor($r('sys.color.font_emphasize'))
              .onClick(() => {
                this.sheetShown = true;
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
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .borderRadius($r('sys.float.corner_radius_level8'))
    // 「查看全文」半模态（FeedbackSheet 同款材质口径）：hero + notes 全文
    .bindSheet(this.sheetShown, this.FullNotesSheet(), {
      height: SheetSize.MEDIUM,
      preferType: SheetType.CENTER,
      showClose: true,
      onWillDisappear: () => {
        this.sheetShown = false;
      },
    } as SheetOptions)
  }

  /** 「查看全文」半模态：hero（包名 + 版本行）+ 全文滚动区（notesFull，零加工原文） */
  @Builder
  FullNotesSheet() {
    Column({ space: 12 }) {
      Text(this.snapshot.token)
        .fontSize($r('sys.float.Title_S'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
      Row({ space: 8 }) {
        Text($r('app.string.release_intel_version_of', this.snapshot.toVersion))
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_secondary'))
        Text(this.verdictLabel())
          .fontSize($r('sys.float.Body_S'))
          .fontColor(this.snapshot.verdict === 'major' ? $r('sys.color.warning') :
          $r('sys.color.font_tertiary'))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Divider()
        .strokeWidth('1px')
        .color($r('sys.color.comp_background_tertiary'))

      Scroll() {
        Text(this.snapshot.notesFull)
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_primary'))
          .width('100%')
      }
      .width('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({
      left: $r('sys.float.padding_level8'),
      right: $r('sys.float.padding_level8'),
      top: $r('sys.float.padding_level8'),
      bottom: $r('sys.float.padding_level8'),
    })
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

  /**
   * 「忽略」合并菜单（v1.3.2 用户定调：忽略此版本与暂停更新合而为一）：
   * 首项 = 忽略此版本 / 撤销忽略（随 ignored 翻转），后接暂停三档。
   */
  private ignoreMenuItems(): MenuElement[] {
    const items: Array<MenuElement> = [
      {
        value: this.ignored ? $r('app.string.release_intel_unignore') :
        $r('app.string.release_intel_ignore'),
        action: () => {
          this.onToggleIgnore();
        },
      },
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
