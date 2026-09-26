/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

/**
 * 目录聚合输入的叶子类型。
 *
 * 放在独立模块里，避免适配器为了复用 BrewService 内部的 CatalogProbeResult
 * 而反向 import BrewService；BrewService 后续只负责把本类型映射成既有探针结果。
 */
export interface BrewCatalogInput {
  kind: string;
  win: string;
  url: string;
  text: string;
  lastModified: string;
}
