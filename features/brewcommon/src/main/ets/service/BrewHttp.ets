/*
 * Copyright (c) 2025 Huawei Device Co., Ltd.
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

const TAG: string = '[BrewHttp]';

/** 一次响应的最小信息：状态码 + 响应头 + 文本体。条件请求要靠响应头判新鲜度。 */
export interface BrewHttpResult {
  code: number;
  /** 响应头。**key 统一转小写** —— 不同 CDN 的大小写不一致（实测 Fastly 用 `Last-Modified`/`ETag`） */
  headers: Record<string, string>;
  text: string;
}

/**
 * formulae.brew.sh 的 HTTP 封装。
 *
 * 只做一件事：把 `@ohos.net.http` 的 `HttpResponse` 收敛成「拿到结果或者抛错」，
 * 让上层（BrewService / Repository）不必重复处理状态码、超时与字符串解码。
 *
 * 几个刻意的取舍：
 * 1. **用 `createHttp()` 每次新建并 `destroy()`**：官方要求用完销毁，否则句柄泄漏。
 *    connectTimeout / readTimeout 都显式给值 —— 默认 60s，详情页等 60s 体感上就是卡死。
 * 2. **`getJson` 里非 200 一律当失败**：`formulae.brew.sh` 对不存在的 token 返回 404 + 一个 HTML
 *    404 页（实测 `Content-Type: text/html`），把它当成功去 `JSON.parse` 会抛一个
 *    与真实原因无关的语法错误，排查时全是噪声。
 *    需要看 304 的调用方用 `request()` / `head()`，它们**不把状态码当错误**。
 * 3. **`result` 只在 string 时使用**：请求头里声明了 `Accept: application/json`，
 *    实测返回的就是 string。若将来服务端改返回类型，这里会走到「空响应体」分支报错，
 *    而不是把 `ArrayBuffer` 强转成 string 拿到一堆乱码。
 */
export class BrewHttp {
  /** 连接 + 读取各自的上限。详情页是可交互路径，取 10s；大文件（analytics）单独放宽。 */
  public static readonly TIMEOUT_DEFAULT: number = 10000;
  public static readonly TIMEOUT_LARGE: number = 30000;
  /** 探针是 HEAD + 0 字节，失败也不影响正确性，所以给一个更短的超时 */
  public static readonly TIMEOUT_PROBE: number = 5000;

  /**
   * 通用请求。**不判状态码**：304 / 404 都原样返回给调用方（条件请求要的就是 304）。
   */
  public static async request(url: string, method: http.RequestMethod = http.RequestMethod.GET,
    extraHeaders: Record<string, string> = {}, timeoutMs: number = BrewHttp.TIMEOUT_DEFAULT):
    Promise<BrewHttpResult> {
    const client: http.HttpRequest = http.createHttp();
    const startAt: number = Date.now();
    try {
      const header: Record<string, string> = {
        'Accept': 'application/json',
        // UA 里带项目名：formulae.brew.sh 是 GitHub Pages + Fastly，出问题时能对上日志
        'User-Agent': 'brew-marketplace-harmonyos/1.0',
      };
      Object.keys(extraHeaders).forEach((key: string) => {
        header[key] = extraHeaders[key];
      });
      const resp: http.HttpResponse = await client.request(url, {
        method: method,
        header: header,
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs,
        // 不依赖系统 HTTP 缓存：条件请求由我们自己发，缓存策略要可预测（TTL / 探针 / 落盘都在 BrewService）
        usingCache: false,
      });
      const text: string = typeof resp.result === 'string' ? resp.result as string : '';
      const result: BrewHttpResult = {
        code: resp.responseCode,
        headers: BrewHttp.lowerCaseHeaders(resp.header),
        text: text,
      };
      Logger.info(TAG, `${method} ${result.code}, ${Date.now() - startAt}ms, ${text.length}B, ${url}`);
      return result;
    } catch (error) {
      const err = error as BusinessError;
      // 记住**耗时**：超时与 DNS/连接失败在 code 上可能都是 2300003，只有耗时能区分
      Logger.error(TAG, `${method} failed, ${Date.now() - startAt}ms, code=${err?.code}, msg=${err?.message}, ${url}`);
      throw error as Error;
    } finally {
      client.destroy();
    }
  }

  /** HEAD：只要响应头，不要响应体。用于数据集探针（`formula.json` 解压后有 32.4 MB，不能在这里 GET）。 */
  public static head(url: string, extraHeaders: Record<string, string> = {},
    timeoutMs: number = BrewHttp.TIMEOUT_PROBE): Promise<BrewHttpResult> {
    return BrewHttp.request(url, http.RequestMethod.HEAD, extraHeaders, timeoutMs);
  }

  /** GET JSON。非 200（含 304/404）一律抛错 —— 需要区分状态码的调用方请用 `request()`。 */
  public static async getJson<T>(url: string, timeoutMs: number = BrewHttp.TIMEOUT_DEFAULT,
    extraHeaders: Record<string, string> = {}): Promise<T> {
    const resp: BrewHttpResult = await BrewHttp.request(url, http.RequestMethod.GET, extraHeaders, timeoutMs);
    if (resp.code !== http.ResponseCode.OK) {
      throw new Error(`unexpected status ${resp.code}`);
    }
    if (resp.text.length === 0) {
      throw new Error('empty response body');
    }
    return JSON.parse(resp.text) as T;
  }

  /** 响应头 key 统一小写。`resp.header` 的值可能是 string 或 string[]（同名头多次出现时）。 */
  private static lowerCaseHeaders(raw: Object): Record<string, string> {
    const out: Record<string, string> = {};
    const dict: Record<string, Object> = raw as Record<string, Object>;
    Object.keys(dict).forEach((key: string) => {
      const value: Object = dict[key];
      out[key.toLowerCase()] = Array.isArray(value) ? (value as string[]).join(', ') : `${value}`;
    });
    return out;
  }
}
