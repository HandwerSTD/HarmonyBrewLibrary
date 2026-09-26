/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

/**
 * `Object.keys` 的包装。
 *
 * 官方文档明确：ArkTS 下 `Object.keys` 不能直接作用于 `Object` 类型，
 * 需要把该调用单独抽离到 `.ts` 文件再 import。`preferences.getAllSync()` 返回的正是 `Object`，
 * 所以 `BrewSourcePrefs.keys()` / `stats()` 必须走这里。
 */
export function objKeys(obj: Object): string[] {
  return Object.keys(obj);
}
