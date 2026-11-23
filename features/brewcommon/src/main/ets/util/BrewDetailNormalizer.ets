/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { BrewKind } from '../model/BrewModels';
import type {
  BrewArtifact,
  BrewCaskDetail,
  BrewDependency,
  BrewFormulaDetail,
  BrewRequirement,
} from '../model/BrewModels';
import {
  BREW_SECTION_KEY_EXECUTABLES,
  BrewAiGrounding,
  BrewInfoPageData,
  BrewInfoRow,
  BrewInfoSection,
  BrewLifecycleNotice,
} from '../model/BrewDetailViewData';
import { BrewCommandGenerator } from './BrewCommandGenerator';
import { BrewFormat } from './BrewFormat';

/**
 * 把 `BrewFormulaDetail` / `BrewCaskDetail` 归一化成 `BrewInfoPageData`。
 *
 * 分区顺序对应 docs/brew-api-design.md §5.3：
 *   1 Hero / 2 安装命令 / 3 元信息  -> BrewInfoPageData 的 name/desc/installCommand/meta
 *   4 提供的命令(formula) ｜ 安装内容(cask)  -> sections
 *   5 兼容性与要求 / 6 依赖 / 7 后台服务或自动更新 / 8 安装提示 / 9 生命周期 / 11 来源与主页
 *
 * **空分区不创建**：`addSection` 会丢掉 rows 为空的分区，所以 UI 侧不需要再判空。
 *
 * 全部字段都来自 Homebrew 官方 API 的原始语义，没有推算出来的假数据 ——
 * 特别是「热度」只用 `installs30d/90d/365d` 与 `categoryRank/categorySize`，
 * 不做星级（Homebrew 无评分数据，见 §5.4）。
 */
export class BrewDetailNormalizer {

  public static fromFormula(detail: BrewFormulaDetail): BrewInfoPageData {
    const data: BrewInfoPageData = new BrewInfoPageData();
    data.name = detail.name || detail.token;
    data.desc = detail.desc;
    data.shortName = detail.token;
    data.tap = detail.tap;
    data.installCommand = BrewCommandGenerator.installCommandOf(detail, BrewKind.FORMULA);
    data.meta = BrewDetailNormalizer.metaRows(
      detail.stableVersion, detail.license, detail.installs30d,
      detail.categoryRank, detail.categorySize);
    data.caveats = detail.caveats;
    data.lifecycle = BrewDetailNormalizer.lifecycleOf(detail);
    data.hasLifecycle = detail.deprecated || detail.disabled;
    BrewDetailNormalizer.fillLifecycleGrounding(detail, data);
    BrewDetailNormalizer.fillAiGroundingFormula(detail, data.aiGrounding);

    // 4 提供的命令。原始清单单独留给 tldr 候选名链（spec §3.1）；key 供详情页把
    // tldr「用法示例」装配在它正下方（formula 独有，cask 路径不创建这个分区，
    // 所以 G2 在数据层就成立）
    if (detail.executables.length > 0) {
      data.executables = detail.executables;
      const executables: BrewInfoSection = new BrewInfoSection(
        $r('app.string.brew_label_executables'),
        [new BrewInfoRow($r('app.string.brew_label_executables'), detail.executables.join(', '))]);
      executables.key = BREW_SECTION_KEY_EXECUTABLES;
      data.sections.push(executables);
    }

    // 5 兼容性与要求
    const compatRows: BrewInfoRow[] = [];
    BrewDetailNormalizer.pushJoined(compatRows, $r('app.string.brew_label_requirements'),
      BrewDetailNormalizer.requirementTexts(detail.requirements));
    BrewDetailNormalizer.pushJoined(compatRows, $r('app.string.brew_label_bottle_tags'), detail.bottleTags);
    BrewDetailNormalizer.pushJoined(compatRows, $r('app.string.brew_label_uses_from_macos'), detail.usesFromMacos);
    BrewDetailNormalizer.addSection(data, $r('app.string.brew_label_requirements'), compatRows);

    // 6 依赖
    const depRows: BrewInfoRow[] = [];
    BrewDetailNormalizer.pushJoined(depRows, $r('app.string.brew_label_dependencies'),
      BrewDetailNormalizer.dependencyNames(detail.dependencies));
    BrewDetailNormalizer.pushJoined(depRows, $r('app.string.brew_label_build_dependencies'),
      BrewDetailNormalizer.dependencyNames(detail.buildDependencies));
    BrewDetailNormalizer.pushJoined(depRows, $r('app.string.brew_label_optional_dependencies'),
      BrewDetailNormalizer.dependencyNames(detail.optionalDependencies));
    BrewDetailNormalizer.pushJoined(depRows, $r('app.string.brew_label_conflicts_with'), detail.conflictsWith);
    BrewDetailNormalizer.addSection(data, $r('app.string.brew_label_dependencies'), depRows);

    // 7 后台服务
    if (detail.serviceSupported) {
      const serviceRows: BrewInfoRow[] = [];
      if (detail.serviceRunType) {
        serviceRows.push(new BrewInfoRow($r('app.string.brew_label_service'), detail.serviceRunType));
      }
      BrewDetailNormalizer.pushJoined(serviceRows, $r('app.string.brew_label_service'), detail.serviceRun);
      BrewDetailNormalizer.addSection(data, $r('app.string.brew_label_service'), serviceRows);
    }

    // 补充事实：安装量趋势 / 版本细节 / 别名 / 来源
    BrewDetailNormalizer.addSection(data, $r('app.string.brew_label_installs'),
      BrewDetailNormalizer.installsRows(detail.installs30d, detail.installs90d, detail.installs365d));
    BrewDetailNormalizer.addSection(data, $r('app.string.brew_label_version'),
      BrewDetailNormalizer.versionDetailRows(detail.headVersion, detail.versionedFormulae));
    // 别名单独成区：它们的语义是「同一个包的其他名字」，不属于「版本」（之前混在一个区里）
    BrewDetailNormalizer.addSection(data, $r('app.string.brew_label_aliases'),
      BrewDetailNormalizer.aliasRows(detail.aliases));
    if (detail.kegOnly) {
      BrewDetailNormalizer.addSection(data, $r('app.string.brew_state_keg_only'),
        [new BrewInfoRow($r('app.string.brew_state_keg_only'),
          detail.kegOnlyReason?.explanation || detail.kegOnlyReason?.reason || '')]);
    }
    BrewDetailNormalizer.addSection(data, $r('app.string.brew_label_source'),
      BrewDetailNormalizer.sourceRows(detail.tap, detail.homepage));
    return data;
  }

  public static fromCask(detail: BrewCaskDetail): BrewInfoPageData {
    const data: BrewInfoPageData = new BrewInfoPageData();
    // cask 的 name 是全称（如 "Microsoft Visual Studio Code"），标题栏短名仍用 token
    data.name = detail.name || detail.token;
    data.desc = detail.desc;
    data.shortName = detail.token;
    data.tap = detail.tap;
    data.installCommand = BrewCommandGenerator.installCommandOf(detail, BrewKind.CASK);
    // cask 没有 license 字段（实测 Homebrew cask API 不提供），传空串让 metaRows 跳过
    data.meta = BrewDetailNormalizer.metaRows(
      detail.version, '', detail.installs30d, detail.categoryRank, detail.categorySize);
    data.caveats = detail.caveats;
    data.lifecycle = BrewDetailNormalizer.lifecycleOf(detail);
    data.hasLifecycle = detail.deprecated || detail.disabled;
    BrewDetailNormalizer.fillLifecycleGrounding(detail, data);
    // cask 的 AI grounding：只有依赖有语义（formula/cask 两类平铺合并），其余留空表
    data.aiGrounding.dependencies = BrewDetailNormalizer.dependencyNames(detail.dependsOn.formula)
      .concat(BrewDetailNormalizer.dependencyNames(detail.dependsOn.cask));

    // 4 安装内容（artifacts）
    if (detail.artifacts.length > 0) {
      const artifactRows: BrewInfoRow[] = detail.artifacts.map((item: BrewArtifact) =>
        new BrewInfoRow(item.artifactType, item.path));
      data.sections.push(new BrewInfoSection($r('app.string.brew_label_artifacts'), artifactRows));
    }

    // 5 兼容性：系统版本要求 + 支持的平台
    const compatRows: BrewInfoRow[] = [];
    if (detail.macosRequirement) {
      compatRows.push(new BrewInfoRow($r('app.string.brew_label_macos_requirement'), detail.macosRequirement));
    }
    BrewDetailNormalizer.pushJoined(compatRows, $r('app.string.brew_label_supported_platforms'),
      detail.supportedPlatforms);
    BrewDetailNormalizer.addSection(data, $r('app.string.brew_label_requirements'), compatRows);

    // 6 依赖（cask 的依赖同样分 formula / cask 两类）
    const depRows: BrewInfoRow[] = [];
    BrewDetailNormalizer.pushJoined(depRows, $r('app.string.brew_label_dependencies'),
      BrewDetailNormalizer.dependencyNames(detail.dependsOn.formula));
    BrewDetailNormalizer.pushJoined(depRows, $r('app.string.brew_label_dependencies'),
      BrewDetailNormalizer.dependencyNames(detail.dependsOn.cask));
    BrewDetailNormalizer.pushJoined(depRows, $r('app.string.brew_label_conflicts_with'), detail.conflictsWith);
    BrewDetailNormalizer.addSection(data, $r('app.string.brew_label_dependencies'), depRows);

    // 7 应用自身行为：自动更新 / 残留项 / Bundle 版本
    const appRows: BrewInfoRow[] = [
      new BrewInfoRow($r('app.string.brew_label_auto_updates'),
        detail.autoUpdates ? $r('app.string.brew_value_yes') : $r('app.string.brew_value_no')),
    ];
    if (detail.zapPathCount > 0) {
      appRows.push(new BrewInfoRow($r('app.string.brew_label_zap'),
        $r('app.string.brew_format_items', detail.zapPathCount)));
    }
    if (detail.bundleVersion) {
      appRows.push(new BrewInfoRow($r('app.string.brew_label_bundle_version'), detail.bundleVersion));
    }
    data.sections.push(new BrewInfoSection($r('app.string.brew_label_auto_updates'), appRows));

    BrewDetailNormalizer.addSection(data, $r('app.string.brew_label_installs'),
      BrewDetailNormalizer.installsRows(detail.installs30d, detail.installs90d, detail.installs365d));
    // cask 的 names 是「全部名称」，只有多于 1 个时才值得单独列
    if (detail.names.length > 1) {
      BrewDetailNormalizer.addSection(data, $r('app.string.brew_label_aliases'),
        [new BrewInfoRow($r('app.string.brew_label_aliases'), detail.names.join(', '))]);
    }
    BrewDetailNormalizer.addSection(data, $r('app.string.brew_label_source'),
      BrewDetailNormalizer.sourceRows(detail.tap, detail.homepage));
    return data;
  }

  // ------------------------------------------------------------ 共用片段

  /** 顶部元信息：版本 / 许可 / 近 30 天安装量 / 分类内排名。空值跳过。 */
  private static metaRows(version: string, license: string, installs30d: number,
    rank: number, size: number): BrewInfoRow[] {
    const rows: BrewInfoRow[] = [];
    if (version) {
      rows.push(new BrewInfoRow($r('app.string.brew_label_version'), version));
    }
    if (license) {
      rows.push(new BrewInfoRow($r('app.string.brew_label_license'), license));
    }
    if (installs30d > 0) {
      rows.push(new BrewInfoRow($r('app.string.brew_label_installs_30d'), BrewFormat.compactCount(installs30d)));
    }
    if (rank > 0 && size > 0) {
      rows.push(new BrewInfoRow($r('app.string.brew_label_category_rank'),
        BrewFormat.rankText(rank, size)));
    }
    return rows;
  }

  /**
   * 90/365 天安装量。**三档都为 0 时返回空**，分区随之不创建。
   *
   * 30d 不无条件压一行：方言只给目录量值时，90/365 恒为 0，而目录尚未同步时
   * 连 30d 也是 0 —— 那时硬写一个「近 30 天安装量 0」是在说一件我们并不知道的事。
   */
  private static installsRows(installs30d: number, installs90d: number, installs365d: number): BrewInfoRow[] {
    const rows: BrewInfoRow[] = [];
    if (installs30d > 0) {
      rows.push(new BrewInfoRow($r('app.string.brew_label_installs_30d'), BrewFormat.compactCount(installs30d)));
    }
    if (installs90d > 0) {
      rows.push(new BrewInfoRow($r('app.string.brew_label_installs_90d'), BrewFormat.compactCount(installs90d)));
    }
    if (installs365d > 0) {
      rows.push(new BrewInfoRow($r('app.string.brew_label_installs_365d'), BrewFormat.compactCount(installs365d)));
    }
    return rows;
  }

  /** 开发版 / 历史版本 */
  private static versionDetailRows(headVersion: string, versionedFormulae: string[]): BrewInfoRow[] {
    const rows: BrewInfoRow[] = [];
    if (headVersion) {
      rows.push(new BrewInfoRow($r('app.string.brew_label_head_version'), headVersion));
    }
    BrewDetailNormalizer.pushJoined(rows, $r('app.string.brew_label_versioned_formulae'), versionedFormulae);
    return rows;
  }

  /** 别名（formula 的 aliases / cask 的 names） */
  private static aliasRows(aliases: string[]): BrewInfoRow[] {
    const rows: BrewInfoRow[] = [];
    BrewDetailNormalizer.pushJoined(rows, $r('app.string.brew_label_aliases'), aliases);
    return rows;
  }

  /** 来源 tap + 主页。Homebrew 详情接口不含源码仓库地址，因此没有「源码」行。 */
  private static sourceRows(tap: string, homepage: string): BrewInfoRow[] {
    const rows: BrewInfoRow[] = [];
    if (tap) {
      rows.push(new BrewInfoRow($r('app.string.brew_label_tap'), tap));
    }
    if (homepage) {
      rows.push(new BrewInfoRow($r('app.string.brew_label_homepage'), homepage));
    }
    return rows;
  }

  private static lifecycleOf(detail: BrewFormulaDetail | BrewCaskDetail): BrewLifecycleNotice {
    const replacement: string =
      detail.deprecationReplacementFormula || detail.deprecationReplacementCask || '';
    if (detail.disabled) {
      return new BrewLifecycleNotice($r('app.string.brew_state_disabled'),
        $r('app.string.brew_hint_disabled'), detail.disableReason, replacement);
    }
    if (detail.deprecated) {
      return new BrewLifecycleNotice($r('app.string.brew_state_deprecated'),
        $r('app.string.brew_hint_deprecated'), detail.deprecationReason, replacement);
    }
    return new BrewLifecycleNotice('', '', '', '');
  }

  /**
   * 生命周期 grounding 原文字段（AI 二期 P1-3）。与 `lifecycleOf` 同一次判定、
   * 同一份输入：state/日期/按类型替代包。cask 的 deprecationDate 等字段同样存在
   * （BrewLifecycleInfo 两类包共用），无需分叉。
   */
  private static fillLifecycleGrounding(detail: BrewFormulaDetail | BrewCaskDetail,
    data: BrewInfoPageData): void {
    data.replacementFormula = detail.deprecationReplacementFormula;
    data.replacementCask = detail.deprecationReplacementCask;
    if (detail.disabled) {
      data.lifecycleState = 'disabled';
      data.disableDate = detail.disableDate;
      return;
    }
    if (detail.deprecated) {
      data.lifecycleState = 'deprecated';
      data.deprecationDate = detail.deprecationDate;
    }
  }

  /** formula 的 AI grounding 原文（P1-2）。cask 无 build/uses/bottle 语义，留空表。 */
  private static fillAiGroundingFormula(detail: BrewFormulaDetail, grounding: BrewAiGrounding): void {
    grounding.dependencies = BrewDetailNormalizer.dependencyNames(detail.dependencies);
    grounding.buildDependencies = BrewDetailNormalizer.dependencyNames(detail.buildDependencies);
    grounding.usesFromMacos = detail.usesFromMacos;
    grounding.aliases = detail.aliases;
    grounding.versionedFormulae = detail.versionedFormulae;
    grounding.bottleTags = detail.bottleTags;
  }

  private static dependencyNames(list: BrewDependency[]): string[] {
    return list.map((item: BrewDependency) => item.name);
  }

  private static requirementTexts(list: BrewRequirement[]): string[] {
    return list.map((item: BrewRequirement) => {
      const version: string = item.version ? ` ${item.version}` : '';
      const contexts: string = item.contexts.length > 0 ? ` (${item.contexts.join('/')})` : '';
      return `${item.name}${version}${contexts}`;
    });
  }

  /** 只在 values 非空时加一行 —— 避免出现「依赖  （空）」这种行。 */
  private static pushJoined(rows: BrewInfoRow[], label: ResourceStr, values: string[]): void {
    if (values.length > 0) {
      rows.push(new BrewInfoRow(label, values.join(', ')));
    }
  }

  /** 空分区不入列 */
  private static addSection(data: BrewInfoPageData, title: ResourceStr, rows: BrewInfoRow[]): void {
    if (rows.length > 0) {
      data.sections.push(new BrewInfoSection(title, rows));
    }
  }
}
