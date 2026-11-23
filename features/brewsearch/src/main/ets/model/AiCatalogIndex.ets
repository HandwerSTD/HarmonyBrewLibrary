/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { BrewTable, BrewKindText, BrewSearchEntry } from '@ohos/brewcommon';

/**
 * D2 的本地目录索引（spec §5：候选过滤 + 引擎排序都要「目录成员」这一真相）。
 *
 * 组装口径与 `BrewSearchModel.search()` 完全一致（formula + cask 的浏览集，
 * 安装量片未到时退描述片的键）——抽成独立入口是为了让 AI 找工具与主搜索
 * **共用同一份目录成员判定**，两处各写一份就会出现「主搜索搜得到、AI 提名被过滤掉」。
 */
export class AiCatalogIndex {
  private static cached: BrewSearchEntry[] | null = null;

  /** 组装目录索引。进程内缓存：表在内存里是稳定的，重复组装是浪费。 */
  public static entries(): BrewSearchEntry[] {
    if (AiCatalogIndex.cached !== null) {
      return AiCatalogIndex.cached;
    }
    const entries: BrewSearchEntry[] = [];
    let order: number = 0;
    [BrewKindText.FORMULA, BrewKindText.CASK].forEach((kind: string) => {
      BrewTable.rows(kind).forEach((row: CatalogEntryOf) => {
        const entry: BrewSearchEntry = new BrewSearchEntry();
        entry.kind = kind;
        entry.token = row.token;
        entry.desc = BrewTable.descOf(kind, row.token);
        entry.vol30d = row.vol30d;
        entry.order = order++;
        entries.push(entry);
      });
      if (BrewTable.rows(kind).length === 0 && BrewTable.descReady()) {
        // 安装量片未到：退描述片的键（与主搜索同款兜底）
        const desc: Record<string, string> = BrewTable.current().desc[kind] ?? {};
        objForEach(desc, (token: string, text: string) => {
          const entry: BrewSearchEntry = new BrewSearchEntry();
          entry.kind = kind;
          entry.token = token;
          entry.desc = text;
          entry.vol30d = 0;
          entry.order = order++;
          entries.push(entry);
        });
      }
    });
    AiCatalogIndex.cached = entries;
    return entries;
  }

  /** 表刷新后失效缓存（目录成员可能变了）。 */
  public static invalidate(): void {
    AiCatalogIndex.cached = null;
  }

  /** token 是否在目录里（D2 过滤的最终判据）。 */
  public static has(token: string): boolean {
    const key: string = token.trim().toLowerCase();
    if (key.length === 0) {
      return false;
    }
    const entries: BrewSearchEntry[] = AiCatalogIndex.entries();
    for (let i: number = 0; i < entries.length; i++) {
      if (entries[i].token === key) {
        return true;
      }
    }
    return false;
  }

  /** token 的 kind（渲染行要）。未命中返回 'formula' 的调用方兜底。 */
  public static kindOf(token: string): string {
    const key: string = token.trim().toLowerCase();
    const entries: BrewSearchEntry[] = AiCatalogIndex.entries();
    for (let i: number = 0; i < entries.length; i++) {
      if (entries[i].token === key) {
        return entries[i].kind;
      }
    }
    return 'formula';
  }
}

/** CatalogEntry 的本地别名（避免 import type 与 interface 展开的兼容问题）。 */
class CatalogEntryOf {
  public token: string = '';
  public vol30d: number = 0;
}

function objForEach(map: Record<string, string>, fn: (token: string, desc: string) => void): void {
  const keys: string[] = Object.keys(map);
  keys.forEach((key: string) => {
    fn(key, map[key]);
  });
}
