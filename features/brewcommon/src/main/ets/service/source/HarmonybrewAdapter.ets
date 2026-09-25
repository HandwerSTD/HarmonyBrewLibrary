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

import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '@ohos/common';
import { BrewProbeResult } from '../../model/BrewSourceModels';
import { BrewKind } from '../../model/BrewModels';
import { BrewHttp } from '../BrewHttp';
import type { BrewHttpResult } from '../BrewHttp';
import { BrewSourceStore } from '../BrewSourceStore';
import { BrewSourceUrl, BrewSourceUrlCheck } from '../BrewSourceUrl';
import {
  BREW_DIALECT_HARMONYBREW,
  BREW_HARMONYBREW_CATALOG_PATH,
  BREW_HARMONYBREW_DEFAULT_TAG,
  BREW_HARMONYBREW_RANGE_PROBE_BYTES,
  BREW_SOURCE_PROBE_TIMEOUT_MS,
} from '../../constant/BrewSourceConstants';
import type { BrewCatalogInput } from './BrewCatalogInput';
import type { BrewCatalogResult, BrewSourceAdapter } from './BrewSourceAdapter';
import { BrewJsonScan } from '../BrewJsonScan';
import { BrewCatalogFile } from '../BrewCatalogFile';
import { HarmonybrewMap } from './HarmonybrewMap';
import type { HarmonybrewFormula } from './HarmonybrewModels';
import type { LiveFormulaDoc } from '../BrewApiMapper';
import { HarmonybrewStats } from './HarmonybrewStats';

const TAG: string = '[HarmonybrewAdapter]';

class HarmonybrewProbeReason {
  public static readonly OK: string = 'ok';
  public static readonly INVALID_URL: string = 'invalid-url';
  public static readonly DNS: string = 'dns';
  public static readonly TIMEOUT: string = 'timeout';
  public static readonly TLS: string = 'tls';
  public static readonly HTTP_404: string = 'http-404';
  public static readonly HTTP_4XX: string = 'http-4xx';
  public static readonly HTTP_5XX: string = 'http-5xx';
  public static readonly NOT_JSON: string = 'not-json';
  public static readonly HTML_BODY: string = 'html-body';
  public static readonly SHAPE_MISMATCH: string = 'shape-mismatch';
  public static readonly NETWORK_UNKNOWN: string = 'network-unknown';
}

/** Harmonybrew 单文件 JWS 方言：只提供 formulae，casks 恒为空。 */
export class HarmonybrewAdapter implements BrewSourceAdapter {
  public readonly dialect: string = BREW_DIALECT_HARMONYBREW;
  public readonly supportsCasks: boolean = false;
  public readonly supportsAnalytics: boolean = false;
  public readonly priorDivisor: number = 60 / 30.4;

  public synthCatalogDocs(baseUrl: string): Promise<BrewCatalogInput[] | undefined> {
    return HarmonybrewStats.synth(baseUrl, BrewSourceStore.sessionActive().id);
  }

  public async probe(baseUrl: string): Promise<BrewProbeResult> {
    const startAt: number = Date.now();
    const urlCheck: BrewSourceUrlCheck = BrewSourceUrl.check(baseUrl);
    if (!urlCheck.ok) {
      return this.done(false, HarmonybrewProbeReason.INVALID_URL, 0, startAt, urlCheck.reason);
    }
    const url: string = BrewSourceUrl.join(urlCheck.normalized,
      BREW_HARMONYBREW_CATALOG_PATH(BREW_HARMONYBREW_DEFAULT_TAG));
    const range: string = `bytes=0-${BREW_HARMONYBREW_RANGE_PROBE_BYTES - 1}`;
    try {
      const response: BrewHttpResult = await BrewHttp.request(url, http.RequestMethod.GET, {
        'Range': range,
      }, BREW_SOURCE_PROBE_TIMEOUT_MS);
      return this.classify(response, url, startAt);
    } catch (error) {
      const err = error as BusinessError;
      const reason: string = this.classifyError(err);
      const detail: string = `code=${err?.code}, msg=${err?.message}`;
      Logger.info(TAG, `ok=false code=0 reason=${reason} ms=${Date.now() - startAt} ${detail} url=${url}`);
      return this.done(false, reason, 0, startAt, detail);
    }
  }

  /**
   * 下载并解包 JWS 目录。本任务只产出 token→desc 索引；归一化 doc 与目录落盘由后续任务负责。
   */
  public async fetchCatalog(baseUrl: string, sinceStamp: string, kind: string,
    idKey: string): Promise<BrewCatalogResult> {
    if (kind === BrewKind.CASK) {
      const emptyCasks: BrewCatalogResult = {
        ok: true, notModified: false, stamp: '', indexJson: '{}', pairs: 0, skips: 0,
        detail: 'casks unsupported by harmonybrew',
      };
      return emptyCasks;
    }
    // 全量端点使用探测阶段已写回源配置的 tag；仅在存量/异常配置为空时回退默认 tag。
    const sourceTag: string = BrewSourceStore.sessionActive().tag;
    const requestTag: string = sourceTag.length > 0 ? sourceTag : BREW_HARMONYBREW_DEFAULT_TAG;
    const url: string = BrewSourceUrl.join(baseUrl, BREW_HARMONYBREW_CATALOG_PATH(requestTag));
    const headers: Record<string, string> = {
      'Accept': 'application/json',
    };
    if (sinceStamp.length > 0) {
      headers['If-None-Match'] = sinceStamp;
    }
    try {
      const response: BrewHttpResult = await BrewHttp.request(url, http.RequestMethod.GET, headers);
      const etag: string = response.headers['etag'] ?? sinceStamp;
      if (response.code === 304) {
        const unchanged: BrewCatalogResult = {
          ok: true, notModified: true, stamp: etag, indexJson: '', pairs: 0, skips: 0,
          detail: 'download=304B',
        };
        Logger.info(TAG, `meta sync [formula]: ok=true code=304 pairs=0 skips=0 notModified=true etag=${etag}`);
        return unchanged;
      }
      if (response.code !== http.ResponseCode.OK || response.text.length === 0) {
        const failed: BrewCatalogResult = {
          ok: false, notModified: false, stamp: etag, indexJson: '', pairs: 0, skips: 0,
          detail: `code=${response.code} text=${response.text.length}B`,
        };
        Logger.info(TAG, `meta sync [formula]: ok=false code=${response.code} text=${response.text.length}B`);
        return failed;
      }
      const envelope: Record<string, Object> = JSON.parse(response.text) as Record<string, Object>;
      const payloadValue: Object = envelope['payload'];
      if (typeof payloadValue !== 'string') {
        const failed: BrewCatalogResult = {
          ok: false, notModified: false, stamp: etag, indexJson: '', pairs: 0, skips: 0,
          detail: 'envelope payload is not a string',
        };
        Logger.info(TAG, `meta sync [formula]: ok=false envelope=payload-invalid bytes=${response.text.length}`);
        return failed;
      }
      const payloadJson: string = payloadValue as string;
      const payload: Record<string, Object> = JSON.parse(payloadJson) as Record<string, Object>;
      const metadata: Record<string, Object> = payload['metadata'] as Record<string, Object>;
      const tagValue: Object = metadata['bottle_tag'];
      const formulae: Record<string, Object> = payload['formulae'] as Record<string, Object>;
      if (typeof tagValue !== 'string' || formulae === undefined) {
        const failed: BrewCatalogResult = {
          ok: false, notModified: false, stamp: etag, indexJson: '', pairs: 0, skips: 0,
          detail: 'payload metadata.bottle_tag or formulae missing',
        };
        Logger.info(TAG, `meta sync [formula]: ok=false payload-shape-invalid bytes=${payloadJson.length}`);
        return failed;
      }
      const tag: string = tagValue as string;
      const ranges: Record<string, number[]> = BrewJsonScan.formulaeRanges(payloadJson);
      const index: Record<string, string> = {};
      const catalog: Record<string, LiveFormulaDoc> = {};
      let skips: number = 0;
      let unparsed: number = 0;
      let emptyDesc: number = 0;
      // 当前仍在主线程执行下载 → 两次 JSON.parse → 逐条映射 → stringify。
      // 相比上游 32MB taskpool 路径体积小得多，但 3.6MB 仍可能带来约 0.5~2s 可感知卡顿；
      // 本任务不扩张到 taskpool，后续需先验证 @Concurrent 能否调用这些静态方法。
      Object.keys(formulae).forEach((token: string) => {
        const range: number[] | undefined = ranges[token];
        if (range === undefined || range.length !== 2) {
          skips++;
          unparsed++;
          return;
        }
        try {
          const source: HarmonybrewFormula = JSON.parse(
            payloadJson.substring(range[0], range[1])) as HarmonybrewFormula;
          catalog[token] = HarmonybrewMap.formulaToLive(token, tag, source);
          const desc: string = source.desc ?? '';
          if (desc.length === 0) {
            skips++;
            emptyDesc++;
          } else {
            index[token] = desc;
          }
        } catch (error) {
          skips++;
          unparsed++;
        }
      });
      const pairs: number = Object.keys(index).length;
      const catalogPairs: number = Object.keys(catalog).length;
      const result: BrewCatalogResult = {
        ok: pairs > 0 && unparsed === 0, notModified: false, stamp: etag, indexJson: JSON.stringify(index), pairs: pairs,
        skips: skips, detail: `envelope=${response.text.length}B payload=${payloadJson.length}B tag=${tag} ` +
          `unparsed=${unparsed} emptyDesc=${emptyDesc}`,
        catalogJson: JSON.stringify(catalog), catalogPairs: catalogPairs,
      };
      Logger.info(TAG, `dialect=${BREW_DIALECT_HARMONYBREW} pairs=${pairs} skips=${skips} ` +
        `unparsed=${unparsed} emptyDesc=${emptyDesc} tag=${tag} envelope=${response.text.length}B ` +
        `payload=${payloadJson.length}B`);
      return result;
    } catch (error) {
      const err = error as BusinessError;
      const failed: BrewCatalogResult = {
        ok: false, notModified: false, stamp: '', indexJson: '', pairs: 0, skips: 0,
        detail: `download/parse failed code=${err?.code} msg=${err?.message}`,
      };
      Logger.error(TAG, `meta sync [formula] failed, code=${err?.code}, msg=${err?.message}`);
      return failed;
    }
  }

  public async fetchDoc(baseUrl: string, token: string, kind: string,
    headers: Record<string, string>): Promise<BrewHttpResult> {
    const sourceId: string = BrewSourceStore.sessionActive().id;
    if (!BrewCatalogFile.has(sourceId)) {
      Logger.info(TAG, `fetchDoc catalog unavailable, retryable 503, token=${token} kind=${kind}`);
      const unavailable: BrewHttpResult = { code: 503, headers: {}, text: '' };
      return unavailable;
    }
    const text: string | null = BrewCatalogFile.readRange(sourceId, token);
    if (text === null) {
      Logger.info(TAG, `fetchDoc catalog token absent, code=404 token=${token} kind=${kind}`);
      const absent: BrewHttpResult = { code: 404, headers: {}, text: '' };
      return absent;
    }
    try {
      JSON.parse(text);
      const result: BrewHttpResult = { code: 200, headers: {}, text: text };
      return result;
    } catch (error) {
      const err = error as BusinessError;
      Logger.warn(TAG, `fetchDoc catalog JSON invalid, code=404 token=${token} code=${err?.code}`);
      const invalid: BrewHttpResult = { code: 404, headers: {}, text: '' };
      return invalid;
    }
  }

  private classify(response: BrewHttpResult, url: string, startAt: number): BrewProbeResult {
    const body: string = response.text.trim();
    let reason: string = HarmonybrewProbeReason.OK;
    let ok: boolean = false;
    if (response.code !== 200 && response.code !== 206) {
      if (response.code === 404 || response.code === 410) {
        reason = HarmonybrewProbeReason.HTTP_404;
      } else if (response.code >= 500) {
        reason = HarmonybrewProbeReason.HTTP_5XX;
      } else if (response.code >= 400) {
        reason = HarmonybrewProbeReason.HTTP_4XX;
      } else {
        reason = HarmonybrewProbeReason.NETWORK_UNKNOWN;
      }
    } else if (body.startsWith('<')) {
      reason = HarmonybrewProbeReason.HTML_BODY;
    } else if (!response.headers['content-type']?.toLowerCase().includes('json')) {
      reason = HarmonybrewProbeReason.NOT_JSON;
    } else if (!body.startsWith('{"payload":"')) {
      reason = this.probeShapeReason(body);
    } else {
      const tag: string = this.probeTag(body);
      if (tag.length === 0) {
        reason = HarmonybrewProbeReason.SHAPE_MISMATCH;
      } else {
        ok = true;
        reason = HarmonybrewProbeReason.OK;
      }
    }
    const contentType: string = response.headers['content-type'] ?? '';
    const tag: string = this.probeTag(body);
    const detail: string = `bodyLen=${body.length}, ct=${contentType}, ` +
      `dialect=${BREW_DIALECT_HARMONYBREW}, tag=${tag}`;
    Logger.info(TAG, `ok=${ok} code=${response.code} reason=${reason} ms=${Date.now() - startAt} ` +
      `${detail} url=${url}`);
    return this.done(ok, reason, response.code, startAt, detail, tag);
  }

  private probeShapeReason(body: string): string {
    if (body.length === 0) {
      return HarmonybrewProbeReason.NOT_JSON;
    }
    try {
      const envelope: Record<string, Object> = JSON.parse(body) as Record<string, Object>;
      return envelope['payload'] === undefined ? HarmonybrewProbeReason.NOT_JSON : HarmonybrewProbeReason.SHAPE_MISMATCH;
    } catch (error) {
      return HarmonybrewProbeReason.NOT_JSON;
    }
  }

  private probeTag(body: string): string {
    const expression: RegExp = new RegExp('bottle_tag\\\\?":\\\\?"([^"\\\\]+)');
    const match: RegExpExecArray | null = expression.exec(body);
    return match === null ? '' : match[1];
  }

  private classifyError(err: BusinessError): string {
    const code: number = err?.code ?? 0;
    if (code === 2300028) {
      return HarmonybrewProbeReason.TIMEOUT;
    }
    if (code === 2300005 || code === 2300006) {
      return HarmonybrewProbeReason.DNS;
    }
    if (code === 2300060) {
      return HarmonybrewProbeReason.TLS;
    }
    const message: string = (err?.message ?? '').toLowerCase();
    if (message.indexOf('resolve') >= 0 || message.indexOf('dns') >= 0 ||
      message.indexOf('name or service not known') >= 0 || message.indexOf('nodename') >= 0) {
      return HarmonybrewProbeReason.DNS;
    }
    if (message.indexOf('timeout') >= 0 || message.indexOf('timed out') >= 0) {
      return HarmonybrewProbeReason.TIMEOUT;
    }
    if (message.indexOf('certificate') >= 0 || message.indexOf('ssl') >= 0 || message.indexOf('tls') >= 0) {
      return HarmonybrewProbeReason.TLS;
    }
    return HarmonybrewProbeReason.NETWORK_UNKNOWN;
  }

  private done(ok: boolean, reason: string, httpCode: number, startAt: number,
    detail: string, tag: string = ''): BrewProbeResult {
    const result: BrewProbeResult = new BrewProbeResult(ok, reason, httpCode, Date.now() - startAt, detail);
    result.dialect = BREW_DIALECT_HARMONYBREW;
    result.tag = tag;
    return result;
  }
}
