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

import { BrewProbeResult } from '../model/BrewSourceModels';
import { BrewSourceUrl } from './BrewSourceUrl';
import type { BrewSourceUrlCheck } from './BrewSourceUrl';
import { UpstreamAdapter } from './source/UpstreamAdapter';
import { HarmonybrewAdapter } from './source/HarmonybrewAdapter';

/**
 * 激活数据源前的探测入口。
 *
 * 探测对象是尚未激活的新源，因此不能按当前会话源的方言分派。固定先试上游、再试
 * Harmonybrew：任一成功即返回其方言；两者都失败时返回上游结果，保留原有的具体原因码。
 */
export class BrewSourceProbe {
  public static async check(baseUrl: string): Promise<BrewProbeResult> {
    const urlCheck: BrewSourceUrlCheck = BrewSourceUrl.check(baseUrl);
    if (!urlCheck.ok) {
      return new BrewProbeResult(false, 'invalid-url', 0, 0, urlCheck.reason);
    }
    const upstream: UpstreamAdapter = new UpstreamAdapter();
    const upstreamResult: BrewProbeResult = await upstream.probe(urlCheck.normalized);
    if (upstreamResult.ok) {
      return upstreamResult;
    }
    const harmonybrew: HarmonybrewAdapter = new HarmonybrewAdapter();
    const harmonybrewResult: BrewProbeResult = await harmonybrew.probe(urlCheck.normalized);
    if (harmonybrewResult.ok) {
      return harmonybrewResult;
    }
    // 两者都失败时返回上游结果，保留改动前信息量最大的具体原因码。
    return upstreamResult;
  }
}
