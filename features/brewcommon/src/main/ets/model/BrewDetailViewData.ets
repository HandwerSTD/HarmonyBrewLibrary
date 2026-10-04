/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

/**
 * 详情页的展示数据（已归一化）。
 *
 * 为什么要有这一层：`BrewFormulaDetail` 与 `BrewCaskDetail` 字段差异很大
 * （formula 有 license / executables / bottleTags / serviceSupported，
 *   cask 有 artifacts / supportedPlatforms / macosRequirement / autoUpdates），
 * 而 ArkTS 没有可收窄的判别联合 —— UI 里到处写 `if (isCask) {...}` 既啰嗦又容易漏。
 * 因此由 BrewDetailNormalizer 把两种包各自摊平成「行 + 分区」，
 * 页面只认这一套结构，两种包共用同一份渲染代码。
 *
 * 用 class 而不是 interface：UI 需要构造实例作为兜底值，且要在 @Prop 里传递。
 */

/** 一行：左标签 + 右值。
 *
 * 两侧都用 `ResourceStr` 而不是 `Resource`：
 *   - 左标签可能是动态字符串（cask 的 artifactType：app / binary / pkg …）
 *   - 右值可能是带占位符的资源（`$r('app.string.brew_format_items', 10)`）
 * 用 Resource 会把这些情况排除掉。
 */
export class BrewInfoRow {
  public label: ResourceStr;
  public value: ResourceStr;

  public constructor(label: ResourceStr, value: ResourceStr) {
    this.label = label;
    this.value = value;
  }
}

/** 一个分区：标题 + 若干行。行数为 0 的分区不会被创建（见 Normalizer 的 addSection）。 */
export class BrewInfoSection {
  public title: ResourceStr;
  public rows: BrewInfoRow[];

  public constructor(title: ResourceStr, rows: BrewInfoRow[]) {
    this.title = title;
    this.rows = rows;
  }
}

/** 生命周期提示（废弃 / 停用）。命中任何一个才创建。 */
export class BrewLifecycleNotice {
  /** 提示条主标题：brew_state_deprecated / brew_state_disabled */
  public label: ResourceStr;
  /** 说明文案：brew_hint_deprecated / brew_hint_disabled */
  public hint: ResourceStr;
  /** 废弃/停用原因，可能为空 */
  public reason: string;
  /** 替代包（formula 或 cask 的 token），可能为空 */
  public replacement: string;

  public constructor(label: ResourceStr, hint: ResourceStr, reason: string, replacement: string) {
    this.label = label;
    this.hint = hint;
    this.reason = reason;
    this.replacement = replacement;
  }
}

/** 详情页一次加载产出的全部展示数据 */
export class BrewInfoPageData {
  /** 包名（formula 用 token，cask 用 name 全称） */
  public name: string = '';
  /** 包名下方的英文一句话描述 */
  public desc: string = '';
  /** 标题栏短名（token），避免 cask 全称过长把标题栏撑开 */
  public shortName: string = '';
  /**
   * 包所在的 tap（如 `homebrew/core`）。执行安装 / 升级命令时用它拼 qualified name
   * （第三方 tap 需要 `tap/token` 前缀，见 BrewCommandGenerator.qualifiedName）。
   * 详情接口没给时为空串。
   */
  public tap: string = '';
  /** 安装命令，如 brew install zsh */
  public installCommand: string = '';
  /** 顶部元信息：版本 / 许可 / 安装量 / 分类排名 —— 渲染成一行小块 */
  public meta: BrewInfoRow[] = [];
  /** 中部各分区 */
  public sections: BrewInfoSection[] = [];
  /** 安装提示（caveats），单独一块展示 */
  public caveats: string = '';
  /**
   * 生命周期提示内容。**恒非 null**，由 `hasLifecycle` 决定是否渲染。
   * 不用 `BrewLifecycleNotice | null`：ArkUI 的 `if` 分支不会给属性表达式做联合类型收窄，
   * `if (data.lifecycle) { Banner({ notice: data.lifecycle }) }` 这种写法过不了类型检查。
   */
  public lifecycle: BrewLifecycleNotice = new BrewLifecycleNotice('', '', '', '');
  /** 是否命中 deprecated / disabled */
  public hasLifecycle: boolean = false;
  /** 是否本地已安装（mock 阶段恒为 false，接 brew info --json 后才有值） */
  public installed: boolean = false;
}
