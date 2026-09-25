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

import { BREW_SOURCE_MAX_URL_LEN } from '../constant/BrewSourceConstants';

/** 校验结果：`reason === ''` 表示合法 */
export class BrewSourceUrlCheck {
  public ok: boolean;
  public normalized: string;
  public reason: string;

  public constructor(ok: boolean, normalized: string, reason: string) {
    this.ok = ok;
    this.normalized = normalized;
    this.reason = reason;
  }
}

/**
 * baseUrl 的归一化与格式校验。**纯函数、无 I/O、无副作用**。
 *
 * 为什么要把「去尾斜杠」独立出来：所有 URL 都是 `${base}/formula/...` 这样拼的，
 * 用户粘一个带尾斜杠的地址进来就会得到 `//formula` —— 多数 CDN 能容忍，但部分镜像会 404，
 * 而且日志里会出现两种形态、难以对账。所以归一化在**写入注册表之前**做一次，之后全链路信任。
 *
 * 为什么拒绝 query / fragment：baseUrl 后面还要拼路径，带 `?` 会把后续路径吃掉。
 */
export class BrewSourceUrl {
  /**
   * 归一化：`trim` + 剥掉 **authority 之后** 的尾斜杠。
   *
   * **为什么不能无限剥尾斜杠**（本函数原先的写法）：`https://` 会被剥成 `https:`，
   * 于是 `validate` 的 `startsWith('https://')` 判定失败、返回 `scheme`。
   * 而 §8.1 的原因文案已经接到界面上，所以用户在地址栏输入 `https://` 会看到
   * 「地址必须以 http:// 或 https:// 开头」—— 协议他明明写对了，真实问题是**缺主机名**。
   * 这是错误提示，不是模糊提示。
   *
   * 所以剥的边界是 `schemeEnd + 3`（即 `://` 之后），保证分隔符与空 authority 不被吃掉：
   *   `https://`         → `https://`（不动）  → `validate` 判 `host` ✅
   *   `http://`          → `http://`（不动）   → `host` ✅
   *   `https://host/`    → `https://host`      ✅
   *   `https://host////` → `https://host`      ✅
   *   `https:`           → 原样（没有 `://`）   → `validate` 判 `scheme` ✅
   *
   * 没有 `://` 的输入一律原样返回（`schemeEnd <= 0`）：归一化**不做校验**，
   * 「这到底合不合法」是 `validate` 的职责；两者分开才能让原因码准确。
   */
  public static normalize(raw: string): string {
    let out: string = raw.trim();
    const schemeEnd: number = out.indexOf('://');
    if (schemeEnd <= 0) {
      return out;
    }
    let end: number = out.length;
    while (end > schemeEnd + 3 && out.charAt(end - 1) === '/') {
      end--;
    }
    return out.substring(0, end);
  }

  /** 返回 `''` 表示合法；否则返回原因码（`empty` / `too-long` / `scheme` / `query` / `fragment` / `host`） */
  public static validate(normalized: string): string {
    if (normalized.length === 0) {
      return 'empty';
    }
    if (normalized.length > BREW_SOURCE_MAX_URL_LEN) {
      return 'too-long';
    }
    const https: boolean = normalized.startsWith('https://');
    const http: boolean = normalized.startsWith('http://');
    if (!https && !http) {
      return 'scheme';
    }
    if (normalized.indexOf('?') >= 0) {
      return 'query';
    }
    if (normalized.indexOf('#') >= 0) {
      return 'fragment';
    }
    const rest: string = https ? normalized.substring(8) : normalized.substring(7);
    const segments: string[] = rest.split('/');
    const host: string = segments[0];
    if (host.length === 0 || host.indexOf(' ') >= 0) {
      return 'host';
    }
    return '';
  }

  public static check(raw: string): BrewSourceUrlCheck {
    const normalized: string = BrewSourceUrl.normalize(raw);
    const reason: string = BrewSourceUrl.validate(normalized);
    return new BrewSourceUrlCheck(reason.length === 0, normalized, reason);
  }

  /**
   * 在 baseUrl 后面拼一段路径。
   *
   * **只在这一处拼 URL**：baseUrl 可能自带路径前缀（`https://host/homebrew/api`），
   * 各处自己写模板字符串就会漂成 `//` 或缺段。所有调用方（单条文档 / 全量包 / 探针 / analytics）
   * 都必须走这里。
   */
  public static join(baseUrl: string, path: string): string {
    const suffix: string = path.startsWith('/') ? path : '/' + path;
    return baseUrl + suffix;
  }

  /**
   * 取 `scheme://host[:port]` —— **丢掉 baseUrl 自带的路径前缀**。
   *
   * 为什么必须有这个函数：**Harmonybrew 的日统计不在 API 前缀下**。
   * 它的 baseUrl 是 `https://harmonybrew.atomgit.com/api`，而 stats 在
   * `https://harmonybrew.atomgit.com/stats/…`。把 `/stats/…` 用 `join` 拼到 baseUrl 上
   * 会得到 `/api/stats/…`，实测 **404**。
   *
   * 真机抓到的现场：`[HarmonybrewStats] at=latest=today-2 rejected code=404 candidate=20260922`
   * —— 而同一时刻宿主机 `curl https://harmonybrew.atomgit.com/stats/stats-20260922.json` 是 200。
   * 两者差的就是 `/api` 这一段。
   *
   * 与 `join` 的分工（**用错就是静默 404**）：
   *   - `join`       —— **在 API 前缀之内**的路径（formula / cask / analytics）
   *   - `originJoin` —— **站点根之下**的路径（本仓库目前只有 Harmonybrew 的 stats）
   *
   * 没有 `://` 或没有路径时返回原值，不抛错（与 `normalize` 一样：不做校验，校验是 `validate` 的事）。
   */
  public static origin(baseUrl: string): string {
    const schemeEnd: number = baseUrl.indexOf('://');
    if (schemeEnd <= 0) {
      return baseUrl;
    }
    const slash: number = baseUrl.indexOf('/', schemeEnd + 3);
    return slash < 0 ? baseUrl : baseUrl.substring(0, slash);
  }

  /** 拼到 **站点根**（`scheme://host`）下，而不是 baseUrl 下。理由见 `origin`。 */
  public static originJoin(baseUrl: string, path: string): string {
    const suffix: string = path.startsWith('/') ? path : '/' + path;
    return BrewSourceUrl.origin(baseUrl) + suffix;
  }
}
