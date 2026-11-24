/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { Logger } from '@ohos/common';
import { ReleaseIntelDiff } from '../model/ReleaseIntelModels';

const TAG: string = '[release-intel]';

/**
 * formula 配方 diff（spec G3：**零 AI**，纯本地对比）。
 *
 * 对比对象是两份**原始 API JSON**（Record 形态）：
 *   - 旧 = 基线库里的「已装版本」配方快照（ReleaseIntelBaselineStore）；
 *   - 新 = 详情页刚抓到的现网单条 JSON（BrewService.cachedRawDoc）。
 *
 * 对比字段与口径（spec §3.1）：
 *   dependencies / build_dependencies（新增与移除）、caveats 是否变化、
 *   bottle.stable.rebuild 是否变化（重打包单独成行）。
 *   uses_from_macos 在 API 里可以是字符串或对象，统一取其 `formula`/字符串值后对比。
 *
 * 防御式抽取：字段缺失 / 形态不符按空值处理，**不抛错**——diff 失败最多少一行展示，
 * 不值得让情报卡整体失败。
 */
export class FormulaDiffer {
  public static diff(oldRaw: Object, newRaw: Object): ReleaseIntelDiff {
    const diff: ReleaseIntelDiff = new ReleaseIntelDiff();
    diff.baselineAvailable = true;
    const oldObj: Record<string, Object> = oldRaw as Record<string, Object>;
    const newObj: Record<string, Object> = newRaw as Record<string, Object>;
    const oldDeps: string[] = FormulaDiffer.norm(FormulaDiffer.strArray(oldObj, 'dependencies'));
    const newDeps: string[] = FormulaDiffer.norm(FormulaDiffer.strArray(newObj, 'dependencies'));
    diff.depsAdded = FormulaDiffer.added(oldDeps, newDeps);
    diff.depsRemoved = FormulaDiffer.added(newDeps, oldDeps);
    const oldBuild: string[] = FormulaDiffer.norm(FormulaDiffer.strArray(oldObj, 'build_dependencies'));
    const newBuild: string[] = FormulaDiffer.norm(FormulaDiffer.strArray(newObj, 'build_dependencies'));
    diff.buildDepsAdded = FormulaDiffer.added(oldBuild, newBuild);
    const oldCaveats: string = FormulaDiffer.strField(oldObj, 'caveats');
    const newCaveats: string = FormulaDiffer.strField(newObj, 'caveats');
    diff.caveatsChanged = oldCaveats.trim() !== newCaveats.trim();
    diff.bottleRepacked = FormulaDiffer.bottleRebuild(oldObj) !== FormulaDiffer.bottleRebuild(newObj);
    if (diff.depsAdded.length > 0 || diff.depsRemoved.length > 0 || diff.buildDepsAdded.length > 0 ||
      diff.caveatsChanged || diff.bottleRepacked) {
      Logger.info(TAG, `diff deps+${diff.depsAdded.length}/-${diff.depsRemoved.length} ` +
        `build+${diff.buildDepsAdded.length} caveats=${diff.caveatsChanged} ` +
        `rebuild=${diff.bottleRepacked}`);
    }
    return diff;
  }

  /** 字符串数组字段（缺失/形态不符 → 空）。 */
  private static strArray(obj: Record<string, Object>, key: string): string[] {
    const value: Object | undefined = obj[key];
    if (value === undefined || value === null || !Array.isArray(value)) {
      return [];
    }
    const list: Array<Object> = value as Array<Object>;
    const out: string[] = [];
    for (let i: number = 0; i < list.length; i++) {
      const one: Object = list[i];
      if (typeof one === 'string') {
        out.push(one as string);
      } else if (one !== null && one !== undefined) {
        // uses_from_macos 的对象形态：{macos, reason?} 或直接带 formula 键
        const rec: Record<string, Object> = one as Record<string, Object>;
        const name: Object | undefined = rec['formula'];
        if (typeof name === 'string') {
          out.push(name as string);
        } else {
          const macos: Object | undefined = rec['macos'];
          if (typeof macos === 'string') {
            out.push(macos as string);
          }
        }
      }
    }
    return out;
  }

  /** 字符串字段（缺失 → 空串；caveats 可为 null）。 */
  private static strField(obj: Record<string, Object>, key: string): string {
    const value: Object | undefined = obj[key];
    return typeof value === 'string' ? value as string : '';
  }

  /** bottle.stable.rebuild（缺失 → -1，让「双方都缺失」也不误报重打包）。 */
  private static bottleRebuild(obj: Record<string, Object>): number {
    const bottle: Object | undefined = obj['bottle'];
    if (bottle === undefined || bottle === null) {
      return -1;
    }
    const bottleObj: Record<string, Object> = bottle as Record<string, Object>;
    const stable: Object | undefined = bottleObj['stable'];
    if (stable === undefined || stable === null) {
      return -1;
    }
    const stableObj: Record<string, Object> = stable as Record<string, Object>;
    const rebuild: Object | undefined = stableObj['rebuild'];
    return typeof rebuild === 'number' ? rebuild as number : -1;
  }

  /** 归一：去重 + 排序（API 偶发的顺序漂移不该报成「依赖变化」）。 */
  private static norm(list: string[]): string[] {
    const seen: Set<string> = new Set<string>();
    const out: string[] = [];
    list.forEach((name: string) => {
      const key: string = name.trim().toLowerCase();
      if (key.length > 0 && !seen.has(key)) {
        seen.add(key);
        out.push(key);
      }
    });
    out.sort();
    return out;
  }

  /** in(current) 且不在 previous 的名字。 */
  private static added(previous: string[], current: string[]): string[] {
    const prev: Set<string> = new Set<string>(previous);
    const out: string[] = [];
    current.forEach((name: string) => {
      if (!prev.has(name)) {
        out.push(name);
      }
    });
    return out;
  }
}
