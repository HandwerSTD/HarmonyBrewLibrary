/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import type { BrewHttpResult } from '../BrewHttp';
import type { BrewProbeResult } from '../../model/BrewSourceModels';
import type { BrewCatalogInput } from './BrewCatalogInput';
import { UpstreamAdapter } from './UpstreamAdapter';
import { HarmonybrewAdapter } from './HarmonybrewAdapter';
import { BREW_DIALECT_HARMONYBREW } from '../../constant/BrewSourceConstants';

/**
 * 方言无关的全量目录结果。
 *
 * `stamp` 是条件请求基准；上游为 `Last-Modified`。`indexJson` 是
 * `token → desc` 索引的 JSON 文本，刻意沿用 MetaSync 的小字段回传边界。
 */
export interface BrewCatalogResult {
  ok: boolean;
  notModified: boolean;
  stamp: string;
  indexJson: string;
  pairs: number;
  skips: number;
  detail: string;
  /** Harmonybrew 的归一化 formula 目录；上游不设，继续使用 per-token 端点。 */
  catalogJson?: string;
  /** 归一化目录条数；它可能与 desc 索引的 pairs 因空 desc 而不同。 */
  catalogPairs?: number;
}

/**
 * 数据源 transport 级方言适配器。
 *
 * adapter 负责取得并归一化数据，调用方继续复用既有缓存、条件请求与世代号守卫。
 */
export interface BrewSourceAdapter {
  readonly dialect: string;
  readonly supportsCasks: boolean;
  readonly supportsAnalytics: boolean;
  /** 趋势基线折成月均时的除数；由各数据源按自身窗口标定。 */
  readonly priorDivisor: number;

  probe(baseUrl: string): Promise<BrewProbeResult>;
  /** 无 analytics 端点时，由适配器合成现有目录算法可消费的两份输入。 */
  synthCatalogDocs(baseUrl: string): Promise<BrewCatalogInput[] | undefined>;
  /**
   * `kind` 与 `idKey` 都由调用方从同一个 `kind` 派生后传入（见 `BrewMetaSync.syncKind`）。
   * **不要试图从 `idKey` 反推 `kind` 或路径** —— 曾经写成 `idKey.slice(1, len-2)` 得到
   * `name.json` / `token.json`，上游 404，而两个 kind 拿到的是同一个 9379B 的 404 页，
   * 日志看着像「上游挂了」，实际是 URL 拼错。
   */
  fetchCatalog(baseUrl: string, sinceStamp: string, kind: string,
    idKey: string): Promise<BrewCatalogResult>;
  /** 返回 BrewHttpResult 形状，让 conditionalFetch 的状态码与响应头处理保持不变。 */
  fetchDoc(baseUrl: string, token: string, kind: string,
    headers: Record<string, string>): Promise<BrewHttpResult>;
}

/** 按已选中的方言取得 transport adapter。 */
export function adapterFor(dialect: string): BrewSourceAdapter {
  if (dialect === BREW_DIALECT_HARMONYBREW) {
    return new HarmonybrewAdapter();
  }
  return new UpstreamAdapter();
}
