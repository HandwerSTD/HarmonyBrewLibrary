/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { BrewBrowseBuilder, BrewKind, BrewPackageItem } from '@ohos/brewcommon';
import type { AiToolCandidate, AiToolResult } from '@ohos/brewcommon';

/**
 * 「AI 找工具」的渲染行：包行组件（BrewPackageRow）需要的 BrewPackageItem + 推荐理由。
 * 与 `BrewSearchRow` 同构（包行 + 附带信息），不共用是为了不把 AI 字段漏进主搜索。
 */
export class AiFindRow {
  public kind: BrewKind = BrewKind.FORMULA;
  public item: BrewPackageItem = new BrewPackageItem();
  /** AI / 词表给的一句话理由。 */
  public why: string = '';

  public constructor(kind: BrewKind, item: BrewPackageItem, why: string) {
    this.kind = kind;
    this.item = item;
    this.why = why;
  }
}

/**
 * 结果列表的 `LazyForEach` 数据源（IDataSource），形状与 `BrewSearchRowSource` 一致。
 * 换数据必须走 `setDataArray`（替换并通知）。
 */
export class AiFindRowSource implements IDataSource {
  private rows: AiFindRow[] = [];
  private listeners: DataChangeListener[] = [];

  public setDataArray(rows: AiFindRow[]): void {
    this.rows = rows;
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataReloaded();
    });
  }

  public totalCount(): number {
    return this.rows.length;
  }

  public getData(index: number): AiFindRow {
    if (index >= 0 && index < this.rows.length) {
      return this.rows[index];
    }
    return new AiFindRow(BrewKind.FORMULA, new BrewPackageItem(), '');
  }

  public registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  public unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos: number = this.listeners.indexOf(listener);
    if (pos >= 0) {
      this.listeners.splice(pos, 1);
    }
  }

  /** ForEach 直接遍历（非 LazyForEach 场景）用的只读副本。 */
  public all(): AiFindRow[] {
    return this.rows;
  }
}

/**
 * AiToolResult → AiFindRow[] 的转换器。
 *
 * 行构造走 `BrewBrowseBuilder.tokenId`（与主搜索同一 id 口径，路由参数不会错位）；
 * kind 由目录索引判定（调用方传 kindOf 回调）。
 */
export class AiFindResultSource {
  public rowsOf(result: AiToolResult, kindOf?: (token: string) => BrewKind): AiFindRow[] {
    const rows: AiFindRow[] = [];
    result.candidates.forEach((cand: AiToolCandidate) => {
      const item: BrewPackageItem = new BrewPackageItem();
      item.id = BrewBrowseBuilder.tokenId(cand.token);
      item.token = cand.token;
      item.subTitle = cand.token;
      item.title = cand.why;
      const kind: BrewKind = kindOf !== undefined ? kindOf(cand.token) : BrewKind.FORMULA;
      rows.push(new AiFindRow(kind, item, cand.why));
    });
    return rows;
  }
}
