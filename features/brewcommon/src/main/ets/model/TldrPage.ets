/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

/**
 * tldr 页的展示模型（详情页「用法示例」分区的数据形状）。
 *
 * 数据来自 tldr-pages 仓库（CC BY 4.0），由 `TldrParser` 从原始 markdown 解析而来。
 * 与 `BrewDetailViewData` 同一条设计约束：UI 需要构造实例作为兜底值，所以用 class
 * 而不是 interface，且字段全部带默认值 —— 构造一个空实例就是「无数据」的合法表达。
 */

/** 一条用法示例：说明行 + 命令原文。 */
export class TldrExample {
  /** 示例说明（tldr 页里 `- ` 开头的行，可跨行合并） */
  public desc: string = '';
  /**
   * 命令原文。**逐字保留**：复制（G3）与一键执行送进执行 Sheet 的都是这段文本，
   * `{{...}}` 占位符原样在其中，渲染层按 `segments` 高亮，不改写、不填值（spec §6）。
   */
  public code: string = '';
  /** `code` 是否含 `{{占位符}}`。含占位符的示例只有「复制」，没有「执行」（G4） */
  public hasPlaceholder: boolean = false;
}

/**
 * 一页 tldr 内容。
 *
 * `locale` 是**页面实际语言**（zh 命中中文页、回落时是 en），缓存目录与署名展示都用它；
 * `summary` 是页首 `>` 引用组合并出的说明段（另请参阅 / More information 行已剔除）；
 * `examples` 为空表示该页没有示例（解析成功但无可展示的命令）——服务层据此把分区隐藏。
 */
export class TldrPage {
  /** 'zh' | 'en'。页面实际语言，与取数时的回落结果一致 */
  public locale: string = '';
  /** 页面标题行里的命令名（已按 token 校验过） */
  public command: string = '';
  /** 页首引用组合并的说明段，可能为空串 */
  public summary: string = '';
  public examples: TldrExample[] = [];
}
