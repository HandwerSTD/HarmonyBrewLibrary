/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { http } from '@kit.NetworkKit';
import { taskpool } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '@ohos/common';
import { BREW_SOURCE_PROBE_TIMEOUT_MS, BREW_SOURCE_PROBE_TOKEN } from '../../constant/BrewSourceConstants';
// `BrewProbeResult` 是**值**导入（`done()` 里要 `new`），不能写成 `import type`
import { BrewProbeResult } from '../../model/BrewSourceModels';
import { BrewHttp } from '../BrewHttp';
import type { BrewHttpResult } from '../BrewHttp';
import { BrewSourceUrl, BrewSourceUrlCheck } from '../BrewSourceUrl';
import {
  BREW_META_CONNECT_TIMEOUT_MS,
  BREW_META_MAX_LIMIT,
  BREW_META_READ_TIMEOUT_MS,
} from '../../constant/BrewConstants';
import { BREW_DIALECT_UPSTREAM } from '../../constant/BrewSourceConstants';
import type { BrewCatalogInput } from './BrewCatalogInput';
import type { BrewCatalogResult, BrewSourceAdapter } from './BrewSourceAdapter';

const TAG: string = '[UpstreamAdapter]';

/** 原因码常量。与 probe 的错误分类表一一对应。 */
class ProbeReason {
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

/** taskpool 扫描回传；只带小字段，32MB 响应体不跨线程传递。 */
interface UpstreamScanResult {
  ok: boolean;
  code: number;
  textLen: number;
  downloadMs: number;
  scanMs: number;
  pairs: number;
  skips: number;
  indexJson: string;
  err: string;
  notModified: boolean;
  lastModified: string;
}

/**
 * 上游全量目录下载 + 流式扫描。
 *
 * 扫描逻辑刻意内联：`@Concurrent` 不允许调用本文件定义的其它函数。匹配规则、边界与
 * BrewMetaSync 改动前保持一致：只在第一个 name/token 到 desc 之间配对，并让 JSON.parse
 * 负责处理转义。
 */
@Concurrent
async function upstreamMetaScanTask(url: string, maxLimit: number, connectTimeoutMs: number,
  readTimeoutMs: number, idKey: string, sinceStamp: string): Promise<UpstreamScanResult> {
  const out: UpstreamScanResult = {
    ok: false, code: 0, textLen: 0, downloadMs: 0, scanMs: 0, pairs: 0, skips: 0,
    indexJson: '', err: '', notModified: false, lastModified: '',
  };
  const client: http.HttpRequest = http.createHttp();
  const t0: number = Date.now();
  let text: string = '';
  try {
    const headers: Record<string, string> = {
      'Accept': 'application/json',
      'User-Agent': 'brew-marketplace-harmonyos/1.0-metasync',
    };
    if (sinceStamp.length > 0) {
      headers['If-Modified-Since'] = sinceStamp;
    }
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: headers,
      connectTimeout: connectTimeoutMs,
      readTimeout: readTimeoutMs,
      usingCache: false,
      maxLimit: maxLimit,
      expectDataType: http.HttpDataType.STRING,
    };
    Logger.info('[BrewMetaSync]', `meta sync request, ims=[${sinceStamp}] ${url}`);
    const resp: http.HttpResponse = await client.request(url, options);
    out.code = resp.responseCode;
    const rawHeaders: Record<string, Object> = resp.header as Record<string, Object>;
    Object.keys(rawHeaders).forEach((key: string) => {
      if (key.toLowerCase() === 'last-modified') {
        const value: Object = rawHeaders[key];
        out.lastModified = Array.isArray(value) ? (value as string[]).join(', ') : `${value}`;
      }
    });
    if (resp.responseCode === 304) {
      out.notModified = true;
      out.ok = true;
      out.downloadMs = Date.now() - t0;
      return out;
    }
    text = typeof resp.result === 'string' ? resp.result as string : '';
    out.textLen = text.length;
    out.ok = resp.responseCode === http.ResponseCode.OK && text.length > 0;
  } catch (error) {
    const err = error as BusinessError;
    out.err = `download code=${err?.code}, msg=${err?.message}`;
  } finally {
    client.destroy();
  }
  out.downloadMs = Date.now() - t0;
  if (!out.ok) {
    return out;
  }

  const t1: number = Date.now();
  const index: Record<string, string> = {};
  let from: number = 0;
  while (from < text.length) {
    const dAnchor: number = text.indexOf('"desc":', from);
    if (dAnchor < 0) {
      break;
    }
    if (dAnchor > 0 && text.charCodeAt(dAnchor - 1) === 92) {
      from = dAnchor + 7;
      out.skips++;
      continue;
    }
    let d: number = dAnchor + 7;
    while (d < text.length) {
      const c: number = text.charCodeAt(d);
      if (c === 32 || c === 9 || c === 10 || c === 13) {
        d++;
        continue;
      }
      break;
    }
    if (d >= text.length || text.charCodeAt(d) !== 34) {
      from = dAnchor + 7;
      out.skips++;
      continue;
    }
    const nAnchor: number = text.lastIndexOf(idKey, d);
    if (nAnchor < 0 || nAnchor < from) {
      from = dAnchor + 7;
      out.skips++;
      continue;
    }
    let nameQuote: number = nAnchor + idKey.length;
    while (nameQuote < text.length) {
      const c: number = text.charCodeAt(nameQuote);
      if (c === 32 || c === 9 || c === 10 || c === 13) {
        nameQuote++;
        continue;
      }
      break;
    }
    if (nameQuote >= text.length || nameQuote > d || text.charCodeAt(nameQuote) !== 34) {
      from = dAnchor + 7;
      out.skips++;
      continue;
    }
    const nameStart: number = nameQuote + 1;
    let i: number = nameStart;
    let nameEnd: number = -1;
    while (i < d) {
      const code: number = text.charCodeAt(i);
      if (code === 92) {
        i += 2;
        continue;
      }
      if (code === 34) {
        nameEnd = i;
        break;
      }
      i++;
    }
    if (nameEnd < 0) {
      from = dAnchor + 7;
      out.skips++;
      continue;
    }
    const descStart: number = d + 1;
    let j: number = descStart;
    let descEnd: number = -1;
    while (j < text.length) {
      const code: number = text.charCodeAt(j);
      if (code === 92) {
        j += 2;
        continue;
      }
      if (code === 34) {
        descEnd = j;
        break;
      }
      j++;
    }
    if (descEnd < 0) {
      break;
    }
    try {
      const token: string = JSON.parse(`"${text.substring(nameStart, nameEnd)}"`) as string;
      const desc: string = JSON.parse(`"${text.substring(descStart, descEnd)}"`) as string;
      if (token.length > 0) {
        index[token] = desc;
      }
    } catch (error) {
      out.skips++;
    }
    from = descEnd + 1;
  }
  out.scanMs = Date.now() - t1;
  out.pairs = Object.keys(index).length;
  out.indexJson = JSON.stringify(index);
  return out;
}

/** Homebrew 上游 API 方言。请求、扫描与错误分类均由原实现平移而来。 */
export class UpstreamAdapter implements BrewSourceAdapter {
  public readonly dialect: string = BREW_DIALECT_UPSTREAM;
  public readonly supportsCasks: boolean = true;
  public readonly supportsAnalytics: boolean = true;
  // 官方 335 天窗口折月均的既有标定值；不要改成 335 / 30.4，否则上游榜会变化。
  public readonly priorDivisor: number = 11.0;

  public async synthCatalogDocs(baseUrl: string): Promise<BrewCatalogInput[] | undefined> {
    return undefined;
  }

  public async probe(baseUrl: string): Promise<BrewProbeResult> {
    const startAt: number = Date.now();
    const urlCheck: BrewSourceUrlCheck = BrewSourceUrl.check(baseUrl);
    if (!urlCheck.ok) {
      return this.done(false, ProbeReason.INVALID_URL, 0, startAt, urlCheck.reason);
    }
    const url: string = BrewSourceUrl.join(urlCheck.normalized,
      `/formula/${BREW_SOURCE_PROBE_TOKEN}.json`);
    try {
      const res: BrewHttpResult = await BrewHttp.request(url, undefined, {},
        BREW_SOURCE_PROBE_TIMEOUT_MS);
      return this.classify(res, url, startAt);
    } catch (error) {
      const err = error as BusinessError;
      const reason: string = this.classifyError(err);
      Logger.info(TAG, `ok=false code=0 reason=${reason} ms=${Date.now() - startAt} ` +
        `errCode=${err?.code} errMsg=${err?.message} url=${url}`);
      return this.done(false, reason, 0, startAt, `code=${err?.code}, msg=${err?.message}`);
    }
  }

  public async fetchCatalog(baseUrl: string, sinceStamp: string, kind: string,
    idKey: string): Promise<BrewCatalogResult> {
    try {
      // 全量端点路径必须用 `kind`（`formula.json` / `cask.json`），**不能从 `idKey` 反推**。
      // 曾经写成 `idKey.slice(1, idKey.length - 2)`，得到 `name.json` / `token.json` → 上游 404，
      // 而两个 kind 拿到的是同一个 9379B 的 404 页 —— 日志看着像「上游挂了」，实际是 URL 拼错。
      // 长期没暴露的原因：失败时保留旧索引与旧目录缓存，界面照常出数据。
      const url: string = BrewSourceUrl.join(baseUrl, `/${kind}.json`);
      const task: taskpool.Task = new taskpool.Task(
        upstreamMetaScanTask, url,
        BREW_META_MAX_LIMIT, BREW_META_CONNECT_TIMEOUT_MS, BREW_META_READ_TIMEOUT_MS, idKey, sinceStamp);
      const out: UpstreamScanResult = await taskpool.execute(task) as UpstreamScanResult;
      // 保留原日志 tag 与字段，供上游行为回归逐行对账。
      Logger.info('[BrewMetaSync]', `meta sync [${kind}]: ` +
        `ok=${out.ok} code=${out.code} text=${out.textLen}B ` +
        `(connect ${BREW_META_CONNECT_TIMEOUT_MS}ms, read ${BREW_META_READ_TIMEOUT_MS}ms) ` +
        `anchor=${idKey} download=${out.downloadMs}ms scan=${out.scanMs}ms ` +
        `pairs=${out.pairs} skips=${out.skips} notModified=${out.notModified} err=${out.err}`);
      return this.toCatalogResult(out);
    } catch (error) {
      const err = error as BusinessError;
      Logger.error(TAG, `meta sync [${kind}]: taskpool failed, code=${err?.code}, msg=${err?.message}`);
      const failed: BrewCatalogResult = {
        ok: false, notModified: false, stamp: '', indexJson: '', pairs: 0, skips: 0,
        detail: 'taskpool failed code=' + err?.code + ' msg=' + err?.message,
      };
      return failed;
    }
  }

  public fetchDoc(baseUrl: string, token: string, kind: string,
    headers: Record<string, string>): Promise<BrewHttpResult> {
    const url: string = BrewSourceUrl.join(baseUrl,
      `/${kind}/${encodeURIComponent(token)}.json`);
    return BrewHttp.request(url, undefined, headers);
  }

  private toCatalogResult(out: UpstreamScanResult): BrewCatalogResult {
    if (out.notModified) {
      const unchanged: BrewCatalogResult = {
        ok: true, notModified: true, stamp: out.lastModified, indexJson: '',
        pairs: out.pairs, skips: out.skips, detail: 'download=' + out.downloadMs + 'ms',
      };
      return unchanged;
    }
    if (!out.ok || out.pairs === 0) {
      const failed: BrewCatalogResult = {
        ok: out.ok, notModified: false, stamp: out.lastModified, indexJson: '',
        pairs: out.pairs, skips: out.skips,
        detail: 'ok=' + out.ok + ' code=' + out.code + ' text=' + out.textLen + 'B pairs=' + out.pairs +
          ' skips=' + out.skips + ' err=' + out.err,
      };
      return failed;
    }
    const ok: BrewCatalogResult = {
      ok: true, notModified: false, stamp: out.lastModified, indexJson: out.indexJson,
      pairs: out.pairs, skips: out.skips,
      detail: 'download=' + out.downloadMs + 'ms scan=' + out.scanMs + 'ms skips=' + out.skips,
    };
    return ok;
  }

  private classify(res: BrewHttpResult, url: string, startAt: number): BrewProbeResult {
    const code: number = res.code;
    const body: string = res.text.trim();
    let reason: string = ProbeReason.OK;
    let ok: boolean = false;
    if (code === http.ResponseCode.OK) {
      if (body.startsWith('<')) {
        reason = ProbeReason.HTML_BODY;
      } else {
        const shape: string = this.checkShape(body);
        if (shape.length > 0) {
          reason = shape;
        } else {
          reason = ProbeReason.OK;
          ok = true;
        }
      }
    } else if (code === 404 || code === 410) {
      reason = ProbeReason.HTTP_404;
    } else if (code >= 500) {
      reason = ProbeReason.HTTP_5XX;
    } else if (code >= 400) {
      reason = ProbeReason.HTTP_4XX;
    } else {
      reason = ProbeReason.NETWORK_UNKNOWN;
    }
    const detail: string = `bodyLen=${body.length}, ct=${res.headers['content-type'] ?? ''}`;
    Logger.info(TAG, `ok=${ok} code=${code} reason=${reason} ms=${Date.now() - startAt} ${detail} url=${url}`);
    return this.done(ok, reason, code, startAt, detail);
  }

  private checkShape(body: string): string {
    if (body.length === 0) {
      return ProbeReason.NOT_JSON;
    }
    let parsed: Record<string, Object> | null = null;
    try {
      parsed = JSON.parse(body) as Record<string, Object>;
    } catch (err) {
      return ProbeReason.NOT_JSON;
    }
    if (parsed === null || parsed === undefined) {
      return ProbeReason.NOT_JSON;
    }
    const hasName: boolean = parsed['name'] !== undefined;
    const hasVersions: boolean = parsed['versions'] !== undefined;
    return (hasName || hasVersions) ? '' : ProbeReason.SHAPE_MISMATCH;
  }

  private classifyError(err: BusinessError): string {
    const code: number = err?.code ?? 0;
    if (code === 2300028) {
      return ProbeReason.TIMEOUT;
    }
    if (code === 2300005 || code === 2300006) {
      return ProbeReason.DNS;
    }
    if (code === 2300060) {
      return ProbeReason.TLS;
    }
    const message: string = err?.message ?? '';
    const lower: string = message.toLowerCase();
    if (lower.indexOf('resolve') >= 0 || lower.indexOf('dns') >= 0 ||
      lower.indexOf('name or service not known') >= 0 || lower.indexOf('nodename') >= 0) {
      return ProbeReason.DNS;
    }
    if (lower.indexOf('timeout') >= 0 || lower.indexOf('timed out') >= 0) {
      return ProbeReason.TIMEOUT;
    }
    if (lower.indexOf('certificate') >= 0 || lower.indexOf('ssl') >= 0 || lower.indexOf('tls') >= 0) {
      return ProbeReason.TLS;
    }
    return ProbeReason.NETWORK_UNKNOWN;
  }

  private done(ok: boolean, reason: string, httpCode: number, startAt: number,
    detail: string): BrewProbeResult {
    return new BrewProbeResult(ok, reason, httpCode, Date.now() - startAt, detail);
  }
}
