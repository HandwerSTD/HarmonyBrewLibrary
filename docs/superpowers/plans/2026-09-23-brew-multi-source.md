# Homebrew 多数据源与按源缓存维护 · 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让用户可以配置多个 Homebrew API 数据源，每种源拥有独立、可单独查看/清空的本地缓存；切换源必须重启才生效，删除源连带删除其缓存。

**Architecture:** 每个源一个独立的 Preferences store（`brew_src_<id>`，GSKV 模式），隔离由平台原语保证而非键名纪律；源注册表存在既有主 store 里。进程启动时把 active 源**冻结成会话快照**，所有 URL 与 store 名都取它 —— 于是「写新的 activeId」对当前进程零影响，重启成为硬需求。激活链路是「单端点探测 → 确认弹窗 → 写 activeId → `UIAbilityContext.restartApp`」。

**Tech Stack:** HarmonyOS NEXT / ArkTS / ArkUI、`@ohos.data.preferences`（GSKV）、`@kit.NetworkKit`、`@kit.UIDesignKit`（HDS）、hvigor + devecocli。

**Spec:** `docs/superpowers/specs/2026-09-23-brew-multi-source-design.md`

## Global Constraints

- **不做** Node 测试、**不做** `ohosTest`（handover §9.3：HAR 的 `ohosTest` 不能用 `devecocli build` 跑）。每个任务的验证环 = `devecocli build` 编译 + 判据日志 +（必要时）真机点击。
- **不做** XML 回退：per-source store 固定 `preferences.StorageType.GSKV`，不做 `isStorageTypeSupported` 探测。
- **不改** `common` 模块的任何文件。多 store 封装写在 `features/brewcommon` 内。
- **不改** 六条缓存键的名字与数据形状：`brew_live_data` / `brew_live_dataset` / `brew_catalog` / `brew_meta_index` / `brew_meta_stamp` / `brew_detail_page_data`。
- `brew_search_history` 留在主 store，**不属于**源缓存，不参与查看/清空/删源连带。
- 新概念统一用 `BrewSource*`；旧 `BrewDataSource` / `BREW_DATA_SOURCE` 改名为 `BrewDataMode` / `BREW_DATA_MODE`。
- 所有新代码必须过 ArkTS 语法：不用 `any` / `var` / 解构赋值 / `for..in`；对象字面量只能赋给已声明的 interface/class 类型；**无类型对象字面量不能作为实参传出去**（`arkts-no-untyped-obj-literals`，即使包在 `JSON.stringify(...)` 里也不行 —— 直接写 JSON 字符串字面量）；`Record<string, T>` 一律「先声明再逐字段赋值」，不写字面量。
- 模板字符串里**禁止**把 `${…}` 拆到以 `` ` `` 结尾的下一行 —— 那样 `${` 从不闭合，解析器会失去同步并报出一堆与根因无关的错。跨行插值先把值算成局部变量再插。
- **ArkTS 不支持函数重载**：同作用域内两个同名函数会报 `Duplicate function implementation`，需要时改名（如 `find` / `findInList`）。
- `Object.keys` 不能直接作用于 `Object` 类型 → 走 `features/brewcommon/src/main/ets/util/objkeys.ts`。
- 每轮 build 后按 handover §9.5.1 查两项：新符号在 `modules.abc` 里（`grep -c`，**不加** `^$` 锚点）、HAR 路由合并进 HAP 的 `router_map.json`。
- 提交信息用 `feat(brew):` / `refactor(brew):` / `docs(brew):` 前缀，中文正文。
- **步骤粒度已按本项目的验证条件调整**：本项目没有自动化测试，所以不存在「写测试 → 看它失败 → 实现 → 看它通过」这个循环。每个步骤是**一个可独立完成的产出**（一个文件 / 一组机械替换 / 一次真机验证），任务末尾固定是「编译 + 真机日志对账 + 提交」。计划里给出的代码块是**可直接落地的完整实现**，不是伪代码。

## Review Focus

以下 6 类输入/条件是 spec 隐含、但「编译通过」覆盖不到的，最可能伤到真实用户。每一条都在对应任务里有明确的验证步骤：

1. **baseUrl 带路径前缀的镜像**（如 `https://host/homebrew/api`）——拼接后必须得到 `https://host/homebrew/api/formula/wget.json`，不能出现双斜杠、不能丢掉 `/homebrew` 段。→ Task 3 / Task 5
2. **镜像只有单条文档、没有 analytics**（部分可用）——目录取数每次都失败，但**不能**把浏览页/Discover 变成错误态，必须回落旧目录或空态，并在列表标「部分可用」。→ Task 6 / Task 7
3. **清空激活源时后台元数据同步正在跑**——刚清掉的缓存不能被在途写入回填（世代号守卫）。→ Task 6
4. **删除一个源后立刻用不同 id 新增同名源**——不能复用旧缓存（store 名带 id，天然不复用；要有验证）。→ Task 6
5. **源名为空 / 超长 / 含 emoji**——列表与弹窗渲染不能崩，保存时要拒绝空名。→ Task 7
6. **`restartApp` 在 3 秒内被重复触发**——必须走兜底链而不是静默卡死。→ Task 8

---

## 文件结构

### 新增（`features/brewcommon/src/main/ets/`）

| 文件 | 职责 |
|---|---|
| `constant/BrewSourceConstants.ets` | 官方源常量、store 名前缀、注册表/健康键名、探测超时、自检开关 |
| `util/objkeys.ts` | `Object.keys(Object)` 的 ArkTS 包装（纯 `.ts`） |
| `model/BrewSourceModels.ets` | `BrewSource` / `BrewSourceRegistry` / `BrewSourceHealth` / `BrewSourceHealthRecord` / `BrewProbeResult` / `BrewSourceCacheStats` |
| `service/BrewSourceUrl.ets` | baseUrl 归一化与格式校验（纯函数，无 I/O） |
| `service/BrewSourceStore.ets` | 注册表读写 + 不变量 + 会话冻结 + `activeBaseUrl()` + 健康记录 |
| `service/BrewSourcePrefs.ets` | 每源 store 的 get/set/keys/stats/clear/drop + 组键子键读写 |
| `service/BrewSourceProbe.ets` | 单端点探测与 11 类错误分类 |
| `service/BrewCacheEpoch.ets` | 缓存世代号（独立文件，避免 `BrewService` ↔ `BrewCacheAdmin` 循环 import） |
| `service/BrewCacheAdmin.ets` | 维护入口：stats / clear / drop + 内存重置 |
| `service/BrewSourceRestart.ets` | 重启三级兜底链 |
| `service/BrewSourceDiagnostics.ets` | 自检（`BREW_SOURCE_VERIFY` 开关，默认关），被 Task 1/5/6 逐步扩展 |

### 新增（`features/mine/src/main/ets/`）

| 文件 | 职责 |
|---|---|
| `view/BrewSourceSettingView.ets` | 数据源设置页 |
| `viewmodel/BrewSourceSettingState.ets` | 页面状态 |
| `viewmodel/BrewSourceSettingVM.ets` | 页面逻辑（列表组装、表单、探测、激活、缓存维护） |

### 修改

| 文件 | 改动 |
|---|---|
| `features/brewcommon/Index.ets` | 导出新符号 |
| `features/brewcommon/src/main/ets/constant/BrewConstants.ets` | 删 `BREW_API_BASE`；`BrewDataSource`→`BrewDataMode` |
| `features/brewcommon/src/main/ets/service/BrewService.ets` | URL 取 `activeBaseUrl()`；缓存读写走 `BrewSourcePrefs`；`resetMemoryCaches()`；世代号守卫 |
| `features/brewcommon/src/main/ets/service/BrewMetaSync.ets` | 同上 + 启动时跑自检 |
| `features/brewcommon/src/main/ets/service/BrewCatalogAlgo.ets` | `BREW_CATALOG_SOURCES` → `catalogSources()` |
| `features/brewcommon/src/main/ets/model/BrewRepository.ets` | 仅改名 |
| `features/brewcommon/src/main/ets/service/BrewApiMapper.ets` | 仅注释里的常量名 |
| `features/mine/src/main/ets/view/MineSettingView.ets` | 加「数据源」入口 |
| `features/mine/src/main/resources/base/profile/router_map.json` | 加路由 |
| `features/mine/src/main/resources/{base,zh_CN,en_US}/element/string.json` | 新文案 |
| `docs/brew-handover.md`、`docs/brew-api-design.md` | 文档更新 |

---

### Task 1: 源模型、URL 校验、注册表与会话冻结

**Files:**
- Create: `features/brewcommon/src/main/ets/constant/BrewSourceConstants.ets`
- Create: `features/brewcommon/src/main/ets/util/objkeys.ts`
- Create: `features/brewcommon/src/main/ets/model/BrewSourceModels.ets`
- Create: `features/brewcommon/src/main/ets/service/BrewSourceUrl.ets`
- Create: `features/brewcommon/src/main/ets/service/BrewSourceStore.ets`
- Create: `features/brewcommon/src/main/ets/service/BrewSourceDiagnostics.ets`
- Modify: `features/brewcommon/Index.ets`
- Modify: `features/brewcommon/src/main/ets/service/BrewMetaSync.ets:344`（`BrewMetaSync.start()` 里 `BrewLoadLog.info('cold_start', …)` 之后）

**Interfaces:**
- Consumes: `PreferenceManager`、`Logger`（`@ohos/common`）
- Produces:
  - `BrewSource { id, name, baseUrl, builtin, createdAt }`
  - `BrewSourceRegistry { sources: BrewSource[], activeId: string }`
  - `BrewSourceHealthRecord { lastProbeOk, lastProbeReason, lastProbeAt, lastErrorKind, lastErrorMessage, lastErrorAt, catalogOkAt, metaIndexTokensAt }`
  - `BrewSourceHealth { UNKNOWN, OK, PARTIAL, FAILING }`
  - `BrewSourceUrl.normalize(raw: string): string`
  - `BrewSourceUrl.validate(normalized: string): string`（返回 `''` 表示合法，否则是原因码）
  - `BrewSourceStore.listSources(): BrewSource[]`
  - `BrewSourceStore.activeId(): string`
  - `BrewSourceStore.sessionActive(): BrewSource`
  - `BrewSourceStore.activeBaseUrl(): string`
  - `BrewSourceStore.setActiveId(id: string): boolean`
  - `BrewSourceStore.addSource(name: string, baseUrl: string): BrewSource | undefined`
  - `BrewSourceStore.updateSource(id: string, name: string, baseUrl: string): BrewSourceUpdateResult`
  - `BrewSourceUpdateResult { ok: boolean, baseUrlChanged: boolean }`
  - `BrewSourceStore.removeSource(id: string): boolean`
  - `BrewSourceStore.healthOf(id: string): BrewSourceHealthRecord`
  - `BrewSourceStore.noteProbe(id: string, ok: boolean, reason: string): void`
  - `BrewSourceStore.noteError(id: string, kind: string, message: string): void`
  - `BrewSourceStore.noteCatalogOk(id: string): void`
  - `BrewSourceStore.healthState(id: string): BrewSourceHealth`
  - `BrewSourceDiagnostics.run(): void`

- [ ] **Step 1: 写常量与 ArkTS 工具**

`features/brewcommon/src/main/ets/constant/BrewSourceConstants.ets`：

```ts
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

/** 官方源的稳定 id。恒存在、不可删、baseUrl 固定，且恒为注册表第 0 项 */
export const BREW_OFFICIAL_SOURCE_ID: string = 'official';

/** 官方 API 基地址。用户新增的源都是它的镜像（必须提供同样的 /api 目录结构） */
export const BREW_OFFICIAL_BASE_URL: string = 'https://formulae.brew.sh/api';

/**
 * 每个源的 Preferences store 名前缀，实际名 = `brew_src_<sourceId>`。
 *
 * 用独立 store 而不是「共享 store + 键前缀」：Preferences 是「一个文件一个实例、整份加载、整份落盘」，
 * 共享 store 会让加载/flush/删除的成本随**源数量**线性增长（3 个源时每次 flush 要重写 8MB+）。
 * 独立 store 还让「删源」退化成删文件，且**漏改调用点会编译不过**，不会静默串源。
 */
export const BREW_SOURCE_STORE_PREFIX: string = 'brew_src_';

/** 源注册表（`BrewSourceRegistry`）在主 store 里的键。只有几百字节，不值得单独开 store */
export const BREW_SOURCE_REGISTRY_KEY: string = 'brew_sources';

/** 运行期健康记录（`Record<sourceId, BrewSourceHealthRecord>`）在主 store 里的键 */
export const BREW_SOURCE_HEALTH_KEY: string = 'brew_source_health';

/** 探测超时。单条文档 ~5KB，8s 足够区分「慢」与「不通」 */
export const BREW_SOURCE_PROBE_TIMEOUT_MS: number = 8000;

/** 探测用的 token。选 `wget` 是因为它长期存在、体积小、且在任何镜像上都该有 */
export const BREW_SOURCE_PROBE_TOKEN: string = 'wget';

/** baseUrl 长度上限（防手滑粘贴一坨东西） */
export const BREW_SOURCE_MAX_URL_LEN: number = 256;

/** 源名长度上限 */
export const BREW_SOURCE_MAX_NAME_LEN: number = 40;

/**
 * 自检开关。**默认关**。
 *
 * 与 `BREW_META_VERIFY` 同一模式：编译通过不等于行为正确，而本项目不用 ohosTest，
 * 所以需要一条「开一次、看日志、关掉」的诊断通道。开启后 `BrewSourceDiagnostics.run()`
 * 会在进程启动时跑一遍：注册表不变量、会话快照、URL 校验用例、探测分类用例、
 * 以及用一次性 throwaway 源走完 stats → clear → drop（**不碰真实数据**）。
 */
export const BREW_SOURCE_VERIFY: boolean = false;
```

`features/brewcommon/src/main/ets/util/objkeys.ts`：

```ts
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
```

- [ ] **Step 2: 写数据模型**

`features/brewcommon/src/main/ets/model/BrewSourceModels.ets`：

```ts
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

/**
 * 一条数据源。
 *
 * **字段全部是 public 数据字段、没有方法**：这个类要经 `JSON.stringify` / `JSON.parse` 过一遍
 * Preferences，解析回来的是普通对象而不是类实例，方法会丢。所有行为放在 `BrewSourceStore` /
 * `BrewSourceUrl` 里。
 *
 * `id` 与 `baseUrl` 刻意解耦：改 URL 等于换了一份数据，必须清掉该源的 cache；
 * 而 `id` 生成后永不变更，所以改 URL 不会继承旧 cache。
 */
export class BrewSource {
  public id: string;
  public name: string;
  public baseUrl: string;
  public builtin: boolean;
  public createdAt: number;

  public constructor(id: string, name: string, baseUrl: string, builtin: boolean, createdAt: number) {
    this.id = id;
    this.name = name;
    this.baseUrl = baseUrl;
    this.builtin = builtin;
    this.createdAt = createdAt;
  }
}

/** 源注册表。不变量见 `BrewSourceStore.normalizeRegistry` */
export class BrewSourceRegistry {
  public sources: BrewSource[];
  public activeId: string;

  public constructor(sources: BrewSource[], activeId: string) {
    this.sources = sources;
    this.activeId = activeId;
  }
}

/**
 * 源的可用状态。
 *
 * `PARTIAL` 的口径：**单条文档可用（探测通过）但目录 / 全量包持续失败** —— 国内镜像常见
 * 「有 /formula/<token>.json，没有 /analytics/*」。不做预探测，靠运行期记录判定。
 */
export enum BrewSourceHealth {
  UNKNOWN = 'unknown',
  OK = 'ok',
  PARTIAL = 'partial',
  FAILING = 'failing',
}

/** 运行期健康记录。同样是纯数据字段 */
export class BrewSourceHealthRecord {
  public lastProbeOk: boolean = false;
  public lastProbeReason: string = '';
  public lastProbeAt: number = 0;
  public lastErrorKind: string = '';
  public lastErrorMessage: string = '';
  public lastErrorAt: number = 0;
  public catalogOkAt: number = 0;
  public metaIndexTokensAt: number = 0;
}

/** 探测结果 */
export class BrewProbeResult {
  public ok: boolean;
  public reason: string;
  public httpCode: number;
  public tookMs: number;
  public detail: string;

  public constructor(ok: boolean, reason: string, httpCode: number, tookMs: number, detail: string) {
    this.ok = ok;
    this.reason = reason;
    this.httpCode = httpCode;
    this.tookMs = tookMs;
    this.detail = detail;
  }
}

/** 单个源的缓存统计 */
export class BrewSourceCacheStats {
  public sourceId: string = '';
  public keys: number = 0;
  public entries: number = 0;
  public approxBytes: number = 0;
  public updatedAt: number = 0;
}
```

- [ ] **Step 3: 写 URL 归一化与校验**

`features/brewcommon/src/main/ets/service/BrewSourceUrl.ets`：

```ts
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
  public static normalize(raw: string): string {
    let out: string = raw.trim();
    while (out.endsWith('/')) {
      out = out.substring(0, out.length - 1);
    }
    return out;
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
}
```

- [ ] **Step 4: 写注册表与会话冻结**

`features/brewcommon/src/main/ets/service/BrewSourceStore.ets`：

```ts
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

import { Logger, PreferenceManager } from '@ohos/common';
import {
  BREW_OFFICIAL_BASE_URL,
  BREW_OFFICIAL_SOURCE_ID,
  BREW_SOURCE_HEALTH_KEY,
  BREW_SOURCE_MAX_NAME_LEN,
  BREW_SOURCE_REGISTRY_KEY,
} from '../constant/BrewSourceConstants';
import {
  BrewSource,
  BrewSourceHealth,
  BrewSourceHealthRecord,
  BrewSourceRegistry,
} from '../model/BrewSourceModels';
import { BrewSourceUrl, BrewSourceUrlCheck } from './BrewSourceUrl';

const TAG: string = '[BrewSource]';

/**
 * 源注册表 + 会话快照 + 健康记录。
 *
 * ## 为什么会话快照是「必须重启」的实现落点
 *
 * `sessionActive()` 在进程内**只读一次并冻结**。之后 `setActiveId()` 写进盘里对当前进程
 * **零影响** —— 所有 URL 与 store 名都取快照。于是：
 *   - 「切换源必须重启」不是靠约定，而是靠结构保证；
 *   - 不存在「已切换但还在跑旧源」或「新旧源缓存混杂」的中间态。
 *
 * ## 为什么注册表放主 store 而不是每源一个 store
 *
 * 注册表是**跨源**的、只有几百字节。给它单开一个 store 只会多一个文件、多一次加载，
 * 换不来任何隔离收益。
 */
export class BrewSourceStore {
  private static registry: BrewSourceRegistry | undefined = undefined;
  private static session: BrewSource | undefined = undefined;
  private static health: Record<string, BrewSourceHealthRecord> | undefined = undefined;

  // ------------------------------------------------------------ 读

  public static listSources(): BrewSource[] {
    return BrewSourceStore.ensureRegistry().sources;
  }

  public static activeId(): string {
    return BrewSourceStore.ensureRegistry().activeId;
  }

  /** 本会话冻结的 active 源。**唯一权威** —— URL 与 store 名都取它 */
  public static sessionActive(): BrewSource {
    if (BrewSourceStore.session === undefined) {
      const registry: BrewSourceRegistry = BrewSourceStore.ensureRegistry();
      let found: BrewSource | undefined = BrewSourceStore.find(registry.sources, registry.activeId);
      if (found === undefined) {
        found = BrewSourceStore.officialOf(registry.sources);
      }
      BrewSourceStore.session = found;
      Logger.info(TAG, `session active frozen, id=${found.id}, base=${found.baseUrl}`);
    }
    return BrewSourceStore.session;
  }

  public static activeBaseUrl(): string {
    return BrewSourceStore.sessionActive().baseUrl;
  }

  public static find(id: string): BrewSource | undefined {
    return BrewSourceStore.find(BrewSourceStore.listSources(), id);
  }

  // ------------------------------------------------------------ 写

  /** 只写注册表。**不影响当前进程**（见类注释），重启后生效 */
  public static setActiveId(id: string): boolean {
    const registry: BrewSourceRegistry = BrewSourceStore.ensureRegistry();
    if (BrewSourceStore.find(registry.sources, id) === undefined) {
      Logger.error(TAG, `setActiveId rejected, unknown id=${id}`);
      return false;
    }
    registry.activeId = id;
    BrewSourceStore.persistRegistry(registry);
    Logger.info(TAG, `activeId written, id=${id} (生效需重启；本会话仍用 ${BrewSourceStore.sessionActive().id})`);
    return true;
  }

  public static addSource(name: string, baseUrl: string): BrewSource | undefined {
    const check: BrewSourceUrlCheck = BrewSourceUrl.check(baseUrl);
    if (!check.ok) {
      Logger.error(TAG, `addSource rejected, url reason=${check.reason}, raw=${baseUrl}`);
      return undefined;
    }
    if (name.trim().length === 0 || name.trim().length > BREW_SOURCE_MAX_NAME_LEN) {
      Logger.error(TAG, `addSource rejected, bad name length=${name.trim().length}`);
      return undefined;
    }
    const registry: BrewSourceRegistry = BrewSourceStore.ensureRegistry();
    const source: BrewSource = new BrewSource(BrewSourceStore.newId(), name.trim(), check.normalized, false,
      Date.now());
    registry.sources.push(source);
    BrewSourceStore.persistRegistry(registry);
    Logger.info(TAG, `source added, id=${source.id}, name=${source.name}, base=${source.baseUrl}`);
    return source;
  }

  /** 改名与改 URL。返回 `baseUrlChanged` 供调用方决定是否清缓存 */
  public static updateSource(id: string, name: string, baseUrl: string): BrewSourceUpdateResult {
    const result: BrewSourceUpdateResult = new BrewSourceUpdateResult(false, false);
    const registry: BrewSourceRegistry = BrewSourceStore.ensureRegistry();
    const source: BrewSource | undefined = BrewSourceStore.find(registry.sources, id);
    if (source === undefined) {
      return result;
    }
    const trimmedName: string = name.trim();
    if (trimmedName.length === 0 || trimmedName.length > BREW_SOURCE_MAX_NAME_LEN) {
      return result;
    }
    if (source.builtin) {
      // 官方源只允许改名，不允许改 URL
      source.name = trimmedName;
      BrewSourceStore.persistRegistry(registry);
      result.ok = true;
      return result;
    }
    const check: BrewSourceUrlCheck = BrewSourceUrl.check(baseUrl);
    if (!check.ok) {
      return result;
    }
    source.name = trimmedName;
    result.baseUrlChanged = source.baseUrl !== check.normalized;
    source.baseUrl = check.normalized;
    BrewSourceStore.persistRegistry(registry);
    result.ok = true;
    Logger.info(TAG, `source updated, id=${id}, baseUrlChanged=${result.baseUrlChanged}`);
    return result;
  }

  public static removeSource(id: string): boolean {
    const registry: BrewSourceRegistry = BrewSourceStore.ensureRegistry();
    const source: BrewSource | undefined = BrewSourceStore.find(registry.sources, id);
    if (source === undefined) {
      return false;
    }
    if (source.builtin) {
      Logger.error(TAG, `removeSource rejected, builtin id=${id}`);
      return false;
    }
    if (id === BrewSourceStore.sessionActive().id) {
      // 删激活源会让本进程的 store 句柄悬空；而「切走」本身就是重启，重启后再删即可
      Logger.error(TAG, `removeSource rejected, id=${id} is the session active source`);
      return false;
    }
    const kept: BrewSource[] = registry.sources.filter((one: BrewSource) => one.id !== id);
    registry.sources = kept;
    BrewSourceStore.persistRegistry(registry);
    Logger.info(TAG, `source removed, id=${id}, left=${kept.length}`);
    return true;
  }

  // ------------------------------------------------------------ 健康记录

  public static healthOf(id: string): BrewSourceHealthRecord {
    const all: Record<string, BrewSourceHealthRecord> = BrewSourceStore.ensureHealth();
    let one: BrewSourceHealthRecord | undefined = all[id];
    if (one === undefined) {
      one = new BrewSourceHealthRecord();
      all[id] = one;
    }
    return one;
  }

  public static noteProbe(id: string, ok: boolean, reason: string): void {
    const one: BrewSourceHealthRecord = BrewSourceStore.healthOf(id);
    one.lastProbeOk = ok;
    one.lastProbeReason = reason;
    one.lastProbeAt = Date.now();
    BrewSourceStore.persistHealth();
  }

  public static noteError(id: string, kind: string, message: string): void {
    const one: BrewSourceHealthRecord = BrewSourceStore.healthOf(id);
    one.lastErrorKind = kind;
    one.lastErrorMessage = message;
    one.lastErrorAt = Date.now();
    BrewSourceStore.persistHealth();
  }

  public static noteCatalogOk(id: string): void {
    const one: BrewSourceHealthRecord = BrewSourceStore.healthOf(id);
    one.catalogOkAt = Date.now();
    BrewSourceStore.persistHealth();
  }

  /**
   * 状态判定。**不做预探测** —— 全靠运行期记录：
   *   - 探测没过 / 单条文档失败 → `FAILING`；
   *   - 探测过了，但目录或全量包持续失败 → `PARTIAL`（镜像缺 analytics）；
   *   - 都正常 → `OK`。
   */
  public static healthState(id: string): BrewSourceHealth {
    const one: BrewSourceHealthRecord = BrewSourceStore.healthOf(id);
    if (one.lastProbeAt === 0) {
      return BrewSourceHealth.UNKNOWN;
    }
    if (!one.lastProbeOk) {
      return BrewSourceHealth.FAILING;
    }
    const catalogBroken: boolean = one.lastErrorKind === 'catalog' && one.lastErrorAt > one.catalogOkAt;
    const metaBroken: boolean = one.lastErrorKind === 'meta' && one.lastErrorAt > one.metaIndexTokensAt;
    if (catalogBroken || metaBroken) {
      return BrewSourceHealth.PARTIAL;
    }
    return BrewSourceHealth.OK;
  }

  // ------------------------------------------------------------ 内部

  private static find(sources: BrewSource[], id: string): BrewSource | undefined {
    for (let i: number = 0; i < sources.length; i++) {
      if (sources[i].id === id) {
        return sources[i];
      }
    }
    return undefined;
  }

  private static officialOf(sources: BrewSource[]): BrewSource {
    const found: BrewSource | undefined = BrewSourceStore.find(sources, BREW_OFFICIAL_SOURCE_ID);
    return found !== undefined ? found : BrewSourceStore.newOfficial();
  }

  private static newOfficial(): BrewSource {
    return new BrewSource(BREW_OFFICIAL_SOURCE_ID, 'Official', BREW_OFFICIAL_BASE_URL, true, 0);
  }

  private static newId(): string {
    const rand: number = Math.floor(Math.random() * 1000000);
    return `src_${Date.now()}_${rand}`;
  }

  private static ensureRegistry(): BrewSourceRegistry {
    if (BrewSourceStore.registry === undefined) {
      const stored: BrewSourceRegistry | null =
        PreferenceManager.getInstance().getValue<BrewSourceRegistry>(BREW_SOURCE_REGISTRY_KEY);
      const normalized: BrewSourceRegistry = BrewSourceStore.normalizeRegistry(stored);
      BrewSourceStore.registry = normalized;
      Logger.info(TAG, `registry loaded, n=${normalized.sources.length}, active=${normalized.activeId}`);
    }
    return BrewSourceStore.registry;
  }

  /**
   * 不变量（每条越界都自愈 + 打日志）：
   *   1. 恒存在且仅存在一条 official，`builtin=true`、`baseUrl` 为官方地址；
   *   2. official 恒为 `sources[0]`；
   *   3. `activeId` 必须命中；不命中回落 official；
   *   4. 同时只有一条 active（由 `activeId` 单值天然保证）。
   */
  private static normalizeRegistry(stored: BrewSourceRegistry | null): BrewSourceRegistry {
    const sources: BrewSource[] = stored !== null && stored.sources !== undefined ? stored.sources : [];
    const cleaned: BrewSource[] = sources.filter((one: BrewSource) =>
      one !== undefined && one !== null && one.id !== BREW_OFFICIAL_SOURCE_ID && one.id !== undefined);
    let official: BrewSource | undefined = BrewSourceStore.find(sources, BREW_OFFICIAL_SOURCE_ID);
    if (official === undefined) {
      Logger.warn(TAG, 'official missing, recreated');
      official = BrewSourceStore.newOfficial();
    } else {
      official.builtin = true;
      official.baseUrl = BREW_OFFICIAL_BASE_URL;
    }
    const next: BrewSource[] = [official];
    cleaned.forEach((one: BrewSource) => next.push(one));
    let activeId: string = stored !== null && stored.activeId !== undefined ? stored.activeId : '';
    if (BrewSourceStore.find(next, activeId) === undefined) {
      Logger.warn(TAG, `activeId=${activeId} not found, fallback to official`);
      activeId = BREW_OFFICIAL_SOURCE_ID;
    }
    return new BrewSourceRegistry(next, activeId);
  }

  private static persistRegistry(registry: BrewSourceRegistry): void {
    BrewSourceStore.registry = registry;
    PreferenceManager.getInstance().setValue<BrewSourceRegistry>(BREW_SOURCE_REGISTRY_KEY, registry);
  }

  private static ensureHealth(): Record<string, BrewSourceHealthRecord> {
    if (BrewSourceStore.health === undefined) {
      const stored: Record<string, BrewSourceHealthRecord> | null =
        PreferenceManager.getInstance().getValue<Record<string, BrewSourceHealthRecord>>(BREW_SOURCE_HEALTH_KEY);
      BrewSourceStore.health = stored ?? {};
    }
    return BrewSourceStore.health;
  }

  private static persistHealth(): void {
    if (BrewSourceStore.health !== undefined) {
      PreferenceManager.getInstance().setValue<Record<string, BrewSourceHealthRecord>>(
        BREW_SOURCE_HEALTH_KEY, BrewSourceStore.health);
    }
  }
}

/** `updateSource` 的结果：`baseUrlChanged` 决定调用方是否要清该源缓存 */
export class BrewSourceUpdateResult {
  public ok: boolean;
  public baseUrlChanged: boolean;

  public constructor(ok: boolean, baseUrlChanged: boolean) {
    this.ok = ok;
    this.baseUrlChanged = baseUrlChanged;
  }
}
```

- [ ] **Step 5: 写自检入口（Task 1 版本）**

`features/brewcommon/src/main/ets/service/BrewSourceDiagnostics.ets`：

```ts
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

import { Logger } from '@ohos/common';
import { BREW_OFFICIAL_SOURCE_ID, BREW_SOURCE_VERIFY } from '../constant/BrewSourceConstants';
import { BrewSource } from '../model/BrewSourceModels';
import { BrewSourceStore } from './BrewSourceStore';
import { BrewSourceUrlCheck, BrewSourceUrl } from './BrewSourceUrl';

const TAG: string = '[BrewSource]';

/**
 * 源子系统的自检。**默认关**（`BREW_SOURCE_VERIFY`），只在验证改动时开一次。
 *
 * 与 `BREW_META_VERIFY` 同一模式：本项目不用 ohosTest，所以把「一次性验证」做成
 * 一条开关 + 一组 `[BrewSource] verify …` 判据行。Task 5 / Task 6 会往这里追加用例。
 *
 * 输出格式固定：`[BrewSource] verify <用例> … ok=<bool>` —— 一条 grep 就能对账。
 */
export class BrewSourceDiagnostics {
  public static run(): void {
    if (!BREW_SOURCE_VERIFY) {
      return;
    }
    BrewSourceDiagnostics.registryCases();
    BrewSourceDiagnostics.urlCases();
  }

  private static registryCases(): void {
    const sources: BrewSource[] = BrewSourceStore.listSources();
    const officialFirst: boolean = sources.length > 0 && sources[0].id === BREW_OFFICIAL_SOURCE_ID;
    const officialCount: number =
      sources.filter((one: BrewSource) => one.id === BREW_OFFICIAL_SOURCE_ID).length;
    Logger.info(TAG, `verify registry n=${sources.length} active=${BrewSourceStore.activeId()} ` +
      `officialFirst=${officialFirst} officialCount=${officialCount} ` +
      `ok=${officialFirst && officialCount === 1}`);
    const session: BrewSource = BrewSourceStore.sessionActive();
    Logger.info(TAG, `verify session id=${session.id} base=${session.baseUrl} ok=${session.baseUrl.length > 0}`);
  }

  private static urlCases(): void {
    // 用例 1：合法 + 去尾斜杠
    const good: BrewSourceUrlCheck = BrewSourceUrl.check('  https://formulae.brew.sh/api/  ');
    Logger.info(TAG, `verify url normalize ok=${good.ok && good.normalized === 'https://formulae.brew.sh/api'} ` +
      `value=${good.normalized}`);
    // 用例 2：带路径前缀的镜像必须原样保留路径段
    const prefixed: BrewSourceUrlCheck = BrewSourceUrl.check('https://host/homebrew/api');
    const joined: string = BrewSourceUrl.join(prefixed.normalized, '/formula/wget.json');
    Logger.info(TAG, `verify url prefix ok=${joined === 'https://host/homebrew/api/formula/wget.json'} ` +
      `value=${joined}`);
    // 用例 3：非法输入各自的原因码
    const cases: string[] = ['', 'ftp://host/api', 'https://host/api?a=1', 'https://host/api#x', 'https://'];
    cases.forEach((one: string) => {
      const check: BrewSourceUrlCheck = BrewSourceUrl.check(one);
      Logger.info(TAG, `verify url reject raw="${one}" ok=${!check.ok} reason=${check.reason}`);
    });
  }
}
```

- [ ] **Step 6: 导出符号并接到启动路径**

`features/brewcommon/Index.ets` 末尾追加：

```ts
// ------------------------------------------------------------------ 数据源（多源 + 按源缓存）

export {
  BrewSource,
  BrewSourceRegistry,
  BrewSourceHealth,
  BrewSourceHealthRecord,
  BrewProbeResult,
  BrewSourceCacheStats,
} from './src/main/ets/model/BrewSourceModels';

export {
  BREW_OFFICIAL_SOURCE_ID,
  BREW_OFFICIAL_BASE_URL,
  BREW_SOURCE_STORE_PREFIX,
  BREW_SOURCE_VERIFY,
} from './src/main/ets/constant/BrewSourceConstants';

export { BrewSourceUrl, BrewSourceUrlCheck } from './src/main/ets/service/BrewSourceUrl';
export { BrewSourceStore, BrewSourceUpdateResult } from './src/main/ets/service/BrewSourceStore';
export { BrewSourceDiagnostics } from './src/main/ets/service/BrewSourceDiagnostics';
```

`features/brewcommon/src/main/ets/service/BrewMetaSync.ets`：在 `start()` 里 `BrewLoadLog.info('cold_start', …)` 那行之后插入一行调用（先加 import）：

```ts
import { BrewSourceDiagnostics } from './BrewSourceDiagnostics';
```

```ts
    BrewLoadLog.info('cold_start', 'origin', 0,
      '数据层冷启动原点（≈ Ability onCreate 后 ~300ms）；其余 [load] 行的 at= 减本行即得相对耗时');
    // 源子系统的自检入口。默认关（BREW_SOURCE_VERIFY=false），只打日志。
    // 放在这里是因为 `start()` 是数据层在进程里的第一个动作，早于任何页面读取 activeBaseUrl。
    BrewSourceDiagnostics.run();
```

- [ ] **Step 7: 编译并确认新符号进了字节码**

```bash
devecocli build
```
Expected: `BUILD SUCCESSFUL`，0 error。

```bash
ABC=products/pc/build/default/intermediates/loader_out/default/ets/modules.abc
grep -c BrewSourceStore "$ABC"        # 期望 > 0
grep -c BrewSourceUrl "$ABC"          # 期望 > 0
```

> 为什么这样就能验证：`brewcommon/Index.ets` 已被可达代码（`brewformulae` → `@ohos/brewcommon`）静态 import，
> 而 `export { X } from './path'` 是 ESM 的静态边，会连带编译目标文件（handover §9.2）。

- [ ] **Step 8: 真机跑一次自检，确认不变量与 URL 用例**

把 `BREW_SOURCE_VERIFY` 临时改成 `true`，构建安装运行，抓日志：

```bash
devecocli run
devecocli log --from 60s | grep -E "verify (registry|session|url)"
```

Expected（逐条核对）：

```
[BrewSource] registry loaded, n=1, active=official
[BrewSource] session active frozen, id=official, base=https://formulae.brew.sh/api
[BrewSource] verify registry n=1 active=official officialFirst=true officialCount=1 ok=true
[BrewSource] verify session id=official base=https://formulae.brew.sh/api ok=true
[BrewSource] verify url normalize ok=true value=https://formulae.brew.sh/api
[BrewSource] verify url prefix ok=true value=https://host/homebrew/api/formula/wget.json
[BrewSource] verify url reject raw="" ok=true reason=empty
[BrewSource] verify url reject raw="ftp://host/api" ok=true reason=scheme
[BrewSource] verify url reject raw="https://host/api?a=1" ok=true reason=query
[BrewSource] verify url reject raw="https://host/api#x" ok=true reason=fragment
[BrewSource] verify url reject raw="https://" ok=true reason=host
```

**任何一条 `ok=false` 就是本任务没完成。** 验证完把 `BREW_SOURCE_VERIFY` 改回 `false`。

- [ ] **Step 9: 提交**

```bash
git add features/brewcommon/Index.ets \
  features/brewcommon/src/main/ets/constant/BrewSourceConstants.ets \
  features/brewcommon/src/main/ets/util/objkeys.ts \
  features/brewcommon/src/main/ets/model/BrewSourceModels.ets \
  features/brewcommon/src/main/ets/service/BrewSourceUrl.ets \
  features/brewcommon/src/main/ets/service/BrewSourceStore.ets \
  features/brewcommon/src/main/ets/service/BrewSourceDiagnostics.ets \
  features/brewcommon/src/main/ets/service/BrewMetaSync.ets
git commit -m "feat(brew): 数据源注册表、URL 校验与会话冻结

- 每源一个 store 的隔离方案由此起步；注册表放主 store（几百字节）
- sessionActive() 冻结 active 源：写 activeId 对当前进程零影响，重启成为硬需求
- BrewSourceUrl 收口 URL 归一化/校验/拼接，支持带路径前缀的镜像
- BrewSourceDiagnostics + BREW_SOURCE_VERIFY：本项目不用 ohosTest 的一次性验证通道"
```

---

### Task 2: `BrewSourcePrefs` 与缓存读写迁移

**Files:**
- Create: `features/brewcommon/src/main/ets/service/BrewSourcePrefs.ets`
- Modify: `features/brewcommon/src/main/ets/service/BrewService.ets`（6 处缓存读写 + 详情页 4 个方法）
- Modify: `features/brewcommon/src/main/ets/service/BrewMetaSync.ets`（3 处缓存读写）
- Modify: `features/brewcommon/src/main/ets/service/BrewSourceDiagnostics.ets`（加 store 打开用例）
- Modify: `features/brewcommon/Index.ets`

**Interfaces:**
- Consumes: `BrewSourceStore.sessionActive()`（Task 1）、`objKeys`（Task 1）
- Produces:
  - `BrewSourcePrefs.get<T>(key: string): T | null`
  - `BrewSourcePrefs.set<T>(key: string, value: T): void`
  - `BrewSourcePrefs.getSubValue<T>(groupKey: string, subKey: string): Promise<T>`
  - `BrewSourcePrefs.setSubValue<T>(groupKey: string, subKey: string, data: T): Promise<void>`
  - `BrewSourcePrefs.storeNameOf(sourceId: string): string`
  - `BrewSourcePrefs.openFor(sourceId: string): preferences.Preferences | null`（Task 6 的 stats/clear/drop 用）
  - `BrewSourcePrefs.releaseFor(sourceId: string): void`（Task 6 用）

- [ ] **Step 1: 写每源 store 封装**

`features/brewcommon/src/main/ets/service/BrewSourcePrefs.ets`：

```ts
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

import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger, StorageKey } from '@ohos/common';
import { BREW_SOURCE_STORE_PREFIX } from '../constant/BrewSourceConstants';
import { BrewSourceStore } from './BrewSourceStore';

const TAG: string = '[BrewSource]';

const PREFERENCE_NO_DATA_MSG: string = 'There is no data in the Preference.';

/**
 * 每个源一个 Preferences store（`brew_src_<sourceId>`，GSKV 模式）。
 *
 * ## 为什么是「每源一个 store」而不是「共享 store + 键前缀」
 *
 * Preferences 的成本模型是「一个文件 ↔ 一个实例、整份加载、整份落盘」：
 *   - 共享 store 时，**每次 flush 都要重写所有源的缓存之和**（3 个源约 8.4MB），
 *     首次加载也要把所有源解析进内存；
 *   - 独立 store 时，只加载/只重写**当前激活源**（约 2.8MB），未激活源零成本；
 *   - 「删源」从「逐键删 + 全 store 重写」退化成删文件；
 *   - 而且**漏改调用点会编译不过** —— 键前缀方案漏一处就是静默串源。
 *
 * ## 为什么句柄只缓存激活源那一个
 *
 * 这是内存能被压到「同时只有一个源」的地方。维护页访问非激活源时临时打开、用完
 * `releaseFor()` 释放（`removePreferencesFromCacheSync`），不把第二个源的缓存留在内存里。
 *
 * ## GSKV
 *
 * 固定 `StorageType.GSKV`：二进制、**实时落盘、无需 flush**、无全量重写。
 * 按需求方决定，不做 `isStorageTypeSupported` 探测、不设计 XML 回退。
 *
 * ## 为什么不复用 `PreferenceManager`
 *
 * `PreferenceManager` 是单 store 单例（`HMosWorldStoreWithNet`），加多 store 能力要改 `common`，
 * 而本轮约束是「不动 common」。所以这里自建薄封装，并复刻它的容错语义
 * （Context 未就绪时重试、JSON 解析失败时删键、所有异常只记日志不外抛）。
 */
export class BrewSourcePrefs {
  private static activeStore: preferences.Preferences | undefined = undefined;
  private static activeStoreId: string = '';
  /** 临时句柄（维护页用），key = sourceId */
  private static temp: Map<string, preferences.Preferences> = new Map<string, preferences.Preferences>();

  public static storeNameOf(sourceId: string): string {
    return BREW_SOURCE_STORE_PREFIX + sourceId;
  }

  /** 会话激活源的键读取。失败/无 Context/无 store 一律返回 `null`（与 `PreferenceManager.getValue` 同语义） */
  public static get<T>(key: string): T | null {
    const store: preferences.Preferences | null = BrewSourcePrefs.active();
    if (store === null) {
      return null;
    }
    let raw: string | undefined = undefined;
    try {
      const res: preferences.ValueType = store.getSync(key, '');
      if (typeof res === 'string') {
        raw = res as string;
      }
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.error(TAG, `prefs getSync ${key} failed, code=${e.code}, msg=${e.message}`);
      return null;
    }
    if (raw === undefined || raw.length === 0) {
      return null;
    }
    try {
      return JSON.parse(raw) as T;
    } catch (parseErr) {
      const e: BusinessError = parseErr as BusinessError;
      // 与 PreferenceManager 同语义：盘上数据坏了就删掉，下次当没有处理
      Logger.error(TAG, `prefs JSON.parse ${key} failed, data may be corrupted, code=${e.code}`);
      try {
        store.deleteSync(key);
      } catch (delErr) {
        Logger.error(TAG, `prefs delete corrupted ${key} failed`);
      }
      return null;
    }
  }

  /** 会话激活源的键写入。GSKV 实时落盘，**不调 flush** */
  public static set<T>(key: string, value: T): void {
    const store: preferences.Preferences | null = BrewSourcePrefs.active();
    if (store === null) {
      return;
    }
    try {
      store.putSync(key, JSON.stringify(value));
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.error(TAG, `prefs putSync ${key} failed, code=${e.code}, msg=${e.message}`);
    }
  }

  /**
   * 「组键 + 子键」读取。与 `PreferenceCacheHelper.getSubValue` 同形（详情页缓存在用）。
   *
   * **reject 的错误形状必须保持一致**（`PREFERENCE_NO_DATA_MSG`）：上层
   * `BrewService.cachedFormulaDetail` / `cachedCaskDetail` 靠 reject 走回落分支。
   */
  public static getSubValue<T>(groupKey: string, subKey: string): Promise<T> {
    return new Promise<T>((resolve: (value: T) => void, reject: (reason?: Object) => void) => {
      const group: Record<string, T> | null = BrewSourcePrefs.get<Record<string, T>>(groupKey);
      if (group === null) {
        reject({ message: PREFERENCE_NO_DATA_MSG } as BusinessError);
        return;
      }
      const value: T | undefined = group[subKey];
      if (value === undefined) {
        reject({ message: PREFERENCE_NO_DATA_MSG } as BusinessError);
        return;
      }
      resolve(value);
    });
  }

  /** 「组键 + 子键」写入：读改写整组。与 `PreferenceCacheHelper.setSubValue` 同形 */
  public static setSubValue<T>(groupKey: string, subKey: string, data: T): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      const group: Record<string, T> = BrewSourcePrefs.get<Record<string, T>>(groupKey) ?? {};
      group[subKey] = data;
      BrewSourcePrefs.set<Record<string, T>>(groupKey, group);
      resolve();
    });
  }

  /** 打开任意源的 store（维护页用）。返回 `null` 表示不可用 */
  public static openFor(sourceId: string): preferences.Preferences | null {
    if (sourceId === BrewSourceStore.sessionActive().id) {
      return BrewSourcePrefs.active();
    }
    const cached: preferences.Preferences | undefined = BrewSourcePrefs.temp.get(sourceId);
    if (cached !== undefined) {
      return cached;
    }
    const store: preferences.Preferences | null = BrewSourcePrefs.create(sourceId);
    if (store !== null) {
      BrewSourcePrefs.temp.set(sourceId, store);
    }
    return store;
  }

  /** 释放临时句柄（把该源从内存里踢掉） */
  public static releaseFor(sourceId: string): void {
    const store: preferences.Preferences | undefined = BrewSourcePrefs.temp.get(sourceId);
    if (store === undefined) {
      return;
    }
    BrewSourcePrefs.temp.delete(sourceId);
    const ctx: Context | undefined = BrewSourcePrefs.context();
    if (ctx === undefined) {
      return;
    }
    try {
      preferences.removePreferencesFromCacheSync(ctx, BrewSourcePrefs.storeNameOf(sourceId));
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.error(TAG, `removePreferencesFromCache failed, id=${sourceId}, code=${e.code}, msg=${e.message}`);
    }
  }

  /** 会话激活源的 store 句柄（懒加载一次） */
  private static active(): preferences.Preferences | null {
    const id: string = BrewSourceStore.sessionActive().id;
    if (BrewSourcePrefs.activeStore !== undefined && BrewSourcePrefs.activeStoreId === id) {
      return BrewSourcePrefs.activeStore;
    }
    const store: preferences.Preferences | null = BrewSourcePrefs.create(id);
    if (store === null) {
      return null;
    }
    BrewSourcePrefs.activeStore = store;
    BrewSourcePrefs.activeStoreId = id;
    return store;
  }

  private static create(sourceId: string): preferences.Preferences | null {
    const ctx: Context | undefined = BrewSourcePrefs.context();
    if (ctx === undefined) {
      // 与 PreferenceManager 一致：Context 未就绪时不是错误，调用方拿到 null 走「无缓存」
      Logger.warn(TAG, `store open deferred, uicontext is undefined, id=${sourceId}`);
      return null;
    }
    const name: string = BrewSourcePrefs.storeNameOf(sourceId);
    try {
      const options: preferences.Options = { name: name, storageType: preferences.StorageType.GSKV };
      const store: preferences.Preferences = preferences.getPreferencesSync(ctx, options);
      Logger.info(TAG, `store open, id=${sourceId}, name=${name}, mode=gskv, ok=true`);
      return store;
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.error(TAG, `store open, id=${sourceId}, name=${name}, mode=gskv, ok=false, ` +
        `code=${e.code}, msg=${e.message}`);
      return null;
    }
  }

  private static context(): Context | undefined {
    const uiContext: UIContext | undefined = AppStorage.get<UIContext>(StorageKey.UI_CONTEXT);
    if (uiContext === undefined) {
      return undefined;
    }
    return uiContext.getHostContext();
  }
}
```

- [ ] **Step 2: 迁移 `BrewService` 的缓存读写**

`BrewService.ets`：加 import，替换 6 处 `PreferenceManager` 调用（键名一字不改）。

```ts
import { BrewSourcePrefs } from './BrewSourcePrefs';
```

| 位置（当前行号） | 旧 | 新 |
|---|---|---|
| 648 | `PreferenceManager.getInstance().getValue<Record<string, LiveCacheEntry>>(BREW_LIVE_STORAGE_KEY)` | `BrewSourcePrefs.get<Record<string, LiveCacheEntry>>(BREW_LIVE_STORAGE_KEY)` |
| 679-680 | `PreferenceManager.getInstance().setValue<Record<string, LiveCacheEntry>>(BREW_LIVE_STORAGE_KEY, BrewService.liveCache)` | `BrewSourcePrefs.set<Record<string, LiveCacheEntry>>(BREW_LIVE_STORAGE_KEY, BrewService.liveCache)` |
| 685-686 | 同上，`BREW_LIVE_DATASET_KEY` / `BrewService.datasetStamps` | `BrewSourcePrefs.set<Record<string, DatasetStamp>>(BREW_LIVE_DATASET_KEY, BrewService.datasetStamps)` |
| 695 | `PreferenceManager.getInstance().getValue<Record<string, DatasetStamp>>(BREW_LIVE_DATASET_KEY)` | `BrewSourcePrefs.get<Record<string, DatasetStamp>>(BREW_LIVE_DATASET_KEY)` |
| 985 | `PreferenceManager.getInstance().getValue<BrewCatalog>(BREW_CATALOG_STORAGE_KEY)` | `BrewSourcePrefs.get<BrewCatalog>(BREW_CATALOG_STORAGE_KEY)` |
| 1009 | `PreferenceManager.getInstance().setValue<BrewCatalog>(BREW_CATALOG_STORAGE_KEY, catalog)` | `BrewSourcePrefs.set<BrewCatalog>(BREW_CATALOG_STORAGE_KEY, catalog)` |

`ensureCache()` 里读回来的可能是 `null`，现有代码是 `const stored: Record<...> | null = ...; BrewService.liveCache = stored ?? {};` —— **类型不变，不用改**。

详情页 4 个方法（当前 1482-1500）改为：

```ts
  public getFormulaDetailByPreference(componentId: number): Promise<BrewFormulaDetail> {
    return BrewSourcePrefs.getSubValue<BrewFormulaDetail>(
      BrewService.DETAIL_PAGE_DATA, `formula_${componentId}`);
  }

  public setFormulaDetailToPreference(componentId: number, data: BrewFormulaDetail): Promise<void> {
    return BrewSourcePrefs.setSubValue<BrewFormulaDetail>(
      BrewService.DETAIL_PAGE_DATA, `formula_${componentId}`, data);
  }

  public getCaskDetailByPreference(componentId: number): Promise<BrewCaskDetail> {
    return BrewSourcePrefs.getSubValue<BrewCaskDetail>(
      BrewService.DETAIL_PAGE_DATA, `cask_${componentId}`);
  }

  public setCaskDetailToPreference(componentId: number, data: BrewCaskDetail): Promise<void> {
    return BrewSourcePrefs.setSubValue<BrewCaskDetail>(
      BrewService.DETAIL_PAGE_DATA, `cask_${componentId}`, data);
  }
```

若 `PreferenceCacheHelper` 在 `BrewService` 里已无其他调用点，从 import 里删掉它（避免未使用 import）。

- [ ] **Step 3: 迁移 `BrewMetaSync` 的缓存读写**

`BrewMetaSync.ets`：加 `import { BrewSourcePrefs } from './BrewSourcePrefs';`，替换 3 处：

| 位置（当前行号） | 旧 | 新 |
|---|---|---|
| 359 | `PreferenceManager.getInstance().getValue<BrewMetaIndex>(BREW_META_INDEX_KEY)` | `BrewSourcePrefs.get<BrewMetaIndex>(BREW_META_INDEX_KEY)` |
| 491 | `PreferenceManager.getInstance().setValue<BrewMetaIndex>(BREW_META_INDEX_KEY, next)` | `BrewSourcePrefs.set<BrewMetaIndex>(BREW_META_INDEX_KEY, next)` |
| 500 | `PreferenceManager.getInstance().getValue<Record<string, string>>(BREW_META_STAMP_KEY)` | `BrewSourcePrefs.get<Record<string, string>>(BREW_META_STAMP_KEY)` |
| 516 | `PreferenceManager.getInstance().setValue<Record<string, string>>(BREW_META_STAMP_KEY, stamps)` | `BrewSourcePrefs.set<Record<string, string>>(BREW_META_STAMP_KEY, stamps)` |

同样删掉不再使用的 `PreferenceManager` import。

- [ ] **Step 4: 自检加一条 store 用例**

`BrewSourceDiagnostics.run()` 里追加 `BrewSourceDiagnostics.prefsCases();`，并实现：

```ts
  private static prefsCases(): void {
    // 只验证「能开、能读写、键名不变」。clear/drop 的用例在 Task 6 追加。
    const sessionId: string = BrewSourceStore.sessionActive().id;
    const name: string = BrewSourcePrefs.storeNameOf(sessionId);
    const probeKey: string = 'brew_verify_probe';
    BrewSourcePrefs.set<string>(probeKey, 'hello');
    const back: string | null = BrewSourcePrefs.get<string>(probeKey);
    const store: preferences.Preferences | null = BrewSourcePrefs.openFor(sessionId);
    let hasKey: boolean = false;
    try {
      hasKey = store !== null && store.hasSync(probeKey);
    } catch (err) {
      hasKey = false;
    }
    Logger.info(TAG, `verify prefs storeName=${name} writeBack=${back} hasKey=${hasKey} ` +
      `ok=${back === 'hello' && hasKey}`);
    // 清掉探针键，别把垃圾留在真实 store 里
    if (store !== null) {
      try {
        store.deleteSync(probeKey);
      } catch (err) {
        Logger.error(TAG, 'verify prefs cleanup failed');
      }
    }
  }
```

需要新增 import：`import { preferences } from '@kit.ArkData';` 与 `import { BrewSourcePrefs } from './BrewSourcePrefs';`。

`Index.ets` 追加 `export { BrewSourcePrefs } from './src/main/ets/service/BrewSourcePrefs';`

- [ ] **Step 5: 编译**

```bash
devecocli build
```
Expected: `BUILD SUCCESSFUL`，0 error。若报 `storageType` 不存在，说明本地 SDK 的
`preferences.Options` 缺该字段 —— 记录实际报错并停下（这是 GSKV 方案的硬前提）。

- [ ] **Step 6: 真机验证「缓存确实落在每源 store 里」**

把 `BREW_SOURCE_VERIFY` 改成 `true`，运行：

```bash
devecocli run
devecocli log --from 90s | grep -E "store open|verify prefs|\[load\] kind=(live_data|catalog|meta_index|dataset_stamps)"
```

Expected：

```
[BrewSource] store open, id=official, name=brew_src_official, mode=gskv, ok=true
[BrewSource] verify prefs storeName=brew_src_official writeBack=hello hasKey=true ok=true
[load] kind=live_data reason=missing …        ← 首次（主 store 里的旧键已不再被读）
[load] kind=meta_index reason=missing …
[load] kind=catalog reason=missing …
```

然后**再启动一次**（`devecocli run` 或手动重开），Expected：同样的三行变成 `reason=pref`：

```
[load] kind=live_data reason=pref …
[load] kind=meta_index reason=pref …
[load] kind=catalog reason=pref …
```

> 这就是「每源 store 真的在工作」的判据：第一次 `missing`、第二次 `pref`。
> 如果第二次仍是 `missing`，说明读写没落到同一个 store 上。
> 注意：这一步会**丢弃**主 store 里原有的 brew 缓存（按需求方决定，不做向下兼容），
> 所以第一次的 `missing` + 一次全量重下是预期行为。

- [ ] **Step 7: 提交**

```bash
git add features/brewcommon/Index.ets \
  features/brewcommon/src/main/ets/service/BrewSourcePrefs.ets \
  features/brewcommon/src/main/ets/service/BrewService.ets \
  features/brewcommon/src/main/ets/service/BrewMetaSync.ets \
  features/brewcommon/src/main/ets/service/BrewSourceDiagnostics.ets
git commit -m "feat(brew): 缓存迁移到每源独立 store（GSKV）

- BrewSourcePrefs 自建多 store 封装，不动 common
- 键名与数据形状不变，隔离由 store 承担；漏改调用点会编译不过
- 详情页的组键子键读写一并迁移，reject 形状保持不变
- 句柄只缓存激活源，未激活源零内存成本"
```

---

### Task 3: URL 运行时解析（删 `BREW_API_BASE`）

**Files:**
- Modify: `features/brewcommon/src/main/ets/constant/BrewConstants.ets:83-89`（删 `BREW_API_BASE`）
- Modify: `features/brewcommon/src/main/ets/service/BrewService.ets:18,330,336,488,882`
- Modify: `features/brewcommon/src/main/ets/service/BrewMetaSync.ets:44,525,608`
- Modify: `features/brewcommon/src/main/ets/service/BrewCatalogAlgo.ets:16,49-70`

**Interfaces:**
- Consumes: `BrewSourceStore.activeBaseUrl()`（Task 1）、`BrewSourceUrl.join()`（Task 1）
- Produces: `BrewCatalogAlgo.catalogSources(): CatalogSource[]`

- [ ] **Step 1: `BrewCatalogAlgo` 的常量数组改成函数**

删掉 `import { BREW_API_BASE } from '../constant/BrewConstants';`，把 `BREW_CATALOG_SOURCES` 整个替换为：

```ts
/**
 * 4 个聚合端点。**函数而不是常量数组** —— 常量数组会在**模块导入期**求值，
 * 而 base URL 现在是运行期从会话快照解析的（且导入期 `UIContext` 未必就绪，
 * 会拼出空 URL）。这是本文件唯一必须改成函数的地方。
 *
 * 与 check_algo.py 的 SOURCES 逐字对应，不要在别处重新拼 URL。
 */
export function catalogSources(): CatalogSource[] {
  const base: string = BrewSourceStore.activeBaseUrl();
  const out: CatalogSource[] = [];
  out.push(new CatalogSource('formula', '30d', BrewSourceUrl.join(base,
    '/analytics/install-on-request/homebrew-core/30d.json')));
  out.push(new CatalogSource('formula', '365d', BrewSourceUrl.join(base,
    '/analytics/install-on-request/homebrew-core/365d.json')));
  out.push(new CatalogSource('cask', '30d', BrewSourceUrl.join(base,
    '/analytics/cask-install/homebrew-cask/30d.json')));
  out.push(new CatalogSource('cask', '365d', BrewSourceUrl.join(base,
    '/analytics/cask-install/homebrew-cask/365d.json')));
  return out;
}
```

`CatalogSource` 当前是 interface。ArkTS 不允许对象字面量赋给 interface 时用作值构造的场景不稳定，
这里改为 class：

```ts
/** 一个聚合端点的契约 */
export class CatalogSource {
  public kind: string;
  public win: string;
  public url: string;

  public constructor(kind: string, win: string, url: string) {
    this.kind = kind;
    this.win = win;
    this.url = url;
  }
}
```

新增 import：

```ts
import { BrewSourceStore } from './BrewSourceStore';
import { BrewSourceUrl } from './BrewSourceUrl';
```

> ⚠ 若 `CatalogSource` 是 interface 且有别处 `as CatalogSource` 的用法，改成 class 后这些地方仍然可用（结构化类型），
> 但要检查有没有对象字面量直接赋给它的地方 —— 有的话一并改成 `new CatalogSource(...)`。

- [ ] **Step 2: `BrewService` 的 3 处 URL + `catalogJobs()`**

删 `BREW_API_BASE` import，加 `import { BrewSourceUrl } from './BrewSourceUrl';`，然后：

```ts
// 330 行附近
  public getLiveFormulaDoc(token: string): Promise<LiveFormulaDoc> {
    return this.getLiveDoc<LiveFormulaDoc>(`formula_${token}`,
      BrewSourceUrl.join(BrewSourceStore.activeBaseUrl(), `/formula/${encodeURIComponent(token)}.json`));
  }

// 336 行附近
  public getLiveCaskDoc(token: string): Promise<LiveCaskDoc> {
    return this.getLiveDoc<LiveCaskDoc>(`cask_${token}`,
      BrewSourceUrl.join(BrewSourceStore.activeBaseUrl(), `/cask/${encodeURIComponent(token)}.json`));
  }

// 488 行附近（datasetProbe）
    const task: Promise<boolean> = BrewHttp.head(
      BrewSourceUrl.join(BrewSourceStore.activeBaseUrl(), `/${kind}.json`), headers)

// 880-883 行（catalogJobs）
  /** 4 个聚合端点（URL 来自 `catalogSources()`，不在别处重拼） */
  private static catalogJobs(): CatalogFetchJob[] {
    return catalogSources();
  }
```

import 行改为：

```ts
import { BrewCatalogAlgo, BREW_CATALOG_BOARDS, BREW_CATALOG_CONFIG, catalogSources } from './BrewCatalogAlgo';
```

并加 `import { BrewSourceStore } from './BrewSourceStore';`

- [ ] **Step 3: `BrewMetaSync` 的 2 处 URL**

删 `BREW_API_BASE` import，加 `import { BrewSourceStore } from './BrewSourceStore';` 与
`import { BrewSourceUrl } from './BrewSourceUrl';`：

```ts
// 525 行附近
        metaScanTask, BrewSourceUrl.join(BrewSourceStore.activeBaseUrl(), `/${kind}.json`), BREW_META_MAX_LIMIT,

// 608 行附近
      const doc: MetaRawDoc = await BrewHttp.getJson<MetaRawDoc>(
        BrewSourceUrl.join(BrewSourceStore.activeBaseUrl(), `/formula/${token}.json`));
```

- [ ] **Step 4: 删常量**

`BrewConstants.ets` 删掉 `BREW_API_BASE` 及其上方注释块（83-89 行），把其中关于容量的重要信息
搬到 `BrewSourceConstants.BREW_OFFICIAL_BASE_URL` 的注释里（已经写了「必须提供同样的 /api 目录结构」，
在此处补一句容量警告）：

```ts
/**
 * 官方 API 基地址。用户新增的源都是它的镜像（必须提供同样的 /api 目录结构）。
 *
 * ⚠ 容量：`formula.json` / `cask.json` 实测 **32.4 MB / 18.9 MB**（gzip 5.29 MB / 2.05 MB），
 * **页面加载路径严禁拉取**（见 docs/brew-api-design.md §7）—— 那里只能走单条 `/formula/<token>.json`。
 * 全量包只给后台同步用（`BrewMetaSync`）。
 */
export const BREW_OFFICIAL_BASE_URL: string = 'https://formulae.brew.sh/api';
```

- [ ] **Step 5: 编译**

```bash
devecocli build
```
Expected: `BUILD SUCCESSFUL`，0 error。`grep -rn "BREW_API_BASE" features/` 应无结果。

- [ ] **Step 6: 真机验证 URL 仍然正确（含带路径前缀的镜像）**

```bash
devecocli run
devecocli log --from 90s | grep "\[BrewHttp\]"
```

Expected：所有 URL 都是 `https://formulae.brew.sh/api/...`，且**没有** `//` 双斜杠：

```
[BrewHttp] GET 200, … https://formulae.brew.sh/api/formula/wget.json
[BrewHttp] HEAD 304, … https://formulae.brew.sh/api/formula.json
[BrewHttp] GET 200, … https://formulae.brew.sh/api/analytics/install-on-request/homebrew-core/30d.json
```

再验证带路径前缀的镜像（Review Focus #1）：把 `BREW_SOURCE_VERIFY` 打开，日志里应出现

```
[BrewSource] verify url prefix ok=true value=https://host/homebrew/api/formula/wget.json
```

（Task 1 已覆盖该用例，这里只确认它仍在通过。）

- [ ] **Step 7: 提交**

```bash
git add features/brewcommon/src/main/ets/constant/BrewConstants.ets \
  features/brewcommon/src/main/ets/service/BrewService.ets \
  features/brewcommon/src/main/ets/service/BrewMetaSync.ets \
  features/brewcommon/src/main/ets/service/BrewCatalogAlgo.ets \
  features/brewcommon/src/main/ets/constant/BrewSourceConstants.ets
git commit -m "refactor(brew): base URL 改为运行期解析

- 删 BREW_API_BASE 常量，改取会话冻结的 activeBaseUrl()
- BrewCatalogAlgo 的 BREW_CATALOG_SOURCES 常量数组改 catalogSources() 函数
  （常量数组在模块导入期求值，那时 UIContext 未必就绪）
- 所有 URL 拼接收口到 BrewSourceUrl.join()，支持带路径前缀的镜像"
```

---

### Task 4: `BrewDataSource` → `BrewDataMode` 改名

**Files:**
- Modify: `features/brewcommon/src/main/ets/constant/BrewConstants.ets:38,44`
- Modify: `features/brewcommon/src/main/ets/model/BrewRepository.ets:27,123,272,609`
- Modify: `features/brewcommon/src/main/ets/service/BrewService.ets:26,39,355,722,1053,1055,1173,1175,1378,1426`
- Modify: `features/brewcommon/src/main/ets/service/BrewApiMapper.ets:174,187`（注释）

**Interfaces:**
- Produces: `BrewDataMode { REMOTE, SNAPSHOT }`、`BREW_DATA_MODE: BrewDataMode`

- [ ] **Step 1: 改枚举定义**

`BrewConstants.ets`：

```ts
/**
 * 数据**模式**（不是「数据源」）。
 * - `REMOTE`：现网 API 取字段，失败回落内置快照（默认）
 * - `SNAPSHOT`：完全用内置快照，一个网络请求都不发
 *
 * 为什么改名：`BrewDataSource` 这个名字现在属于「多数据源」特性
 * （`BrewSource*`，见 docs/superpowers/specs/2026-09-23-brew-multi-source-design.md）。
 * 本枚举表达的是「走不走网络」，与「用哪个源」是两个维度。
 */
export enum BrewDataMode {
  REMOTE = 'remote',
  SNAPSHOT = 'snapshot',
}

/** 当前数据模式。切到 SNAPSHOT 即可完全离线运行（无网络请求、无等待）。 */
export const BREW_DATA_MODE: BrewDataMode = BrewDataMode.REMOTE;
```

- [ ] **Step 2: 机械替换全部引用**

```bash
cd features/brewcommon/src/main/ets
grep -rl "BrewDataSource\|BREW_DATA_SOURCE" . | while read f; do
  sed -i 's/BREW_DATA_SOURCE/BREW_DATA_MODE/g; s/BrewDataSource/BrewDataMode/g' "$f"
done
grep -rn "BrewDataSource\|BREW_DATA_SOURCE" . || echo "clean"
```

注意 `BrewService.ets:1055` / `1175` 是**日志字符串里**的常量名（`'brew_catalog 缺失、或 BREW_DATA_SOURCE 不是 REMOTE → 页面空态。'`），
sed 会一并改掉 —— 这是想要的（日志里也要用新名）。

- [ ] **Step 3: 编译并确认无残留**

```bash
devecocli build
grep -rn "BrewDataSource\|BREW_DATA_SOURCE" features/ --include="*.ets" | grep -v "/build/" || echo "clean"
```
Expected: `BUILD SUCCESSFUL`；grep 无输出。

- [ ] **Step 4: 提交**

```bash
git add features/brewcommon/src/main/ets
git commit -m "refactor(brew): BrewDataSource 改名 BrewDataMode

「数据源」这个词让给新的多源特性（BrewSource*）；本枚举表达的是走不走网络。"
```

---

### Task 5: `BrewSourceProbe`（单端点探测 + 错误分类）

**Files:**
- Create: `features/brewcommon/src/main/ets/service/BrewSourceProbe.ets`
- Modify: `features/brewcommon/src/main/ets/service/BrewSourceDiagnostics.ets`
- Modify: `features/brewcommon/Index.ets`

**Interfaces:**
- Consumes: `BrewHttp.request()` / `BrewHttpResult`（现有）、`BrewSourceUrl.join()`、`BrewProbeResult`（Task 1）
- Produces: `BrewSourceProbe.check(baseUrl: string): Promise<BrewProbeResult>`

- [ ] **Step 1: 写探测**

`features/brewcommon/src/main/ets/service/BrewSourceProbe.ets`：

```ts
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
import { BREW_SOURCE_PROBE_TIMEOUT_MS, BREW_SOURCE_PROBE_TOKEN } from '../constant/BrewSourceConstants';
import { BrewProbeResult } from '../model/BrewSourceModels';
import { BrewHttp } from './BrewHttp';
import type { BrewHttpResult } from './BrewHttp';
import { BrewSourceUrl, BrewSourceUrlCheck } from './BrewSourceUrl';

const TAG: string = '[BrewSourceProbe]';

/** 原因码常量。与 spec §7.1 的表一一对应 */
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

/**
 * 激活一个数据源之前的**单端点探测**。
 *
 * 为什么是单端点：镜像可能只镜像了部分路径，激活前不可能把四类端点全验一遍
 * （那会拒掉大量只镜像单条文档的国内源）。所以这里只回答一个问题：
 * 「这个地址看起来是不是一个能用的 Homebrew API？」——用一条长期存在的小文档来问。
 * 缺 analytics / 全量包的情况由**运行期降级 + 健康记录**处理（`BrewSourceHealth.PARTIAL`）。
 *
 * 为什么失败是**硬阻断**：把 App 切到一个已确认不可用的源上，用户会看到全空页面，
 * 且因为「切换需重启」而很难退回来。宁可让他在这一步就知道原因。
 *
 * 错误分类必须具体到可行动：`dns` / `timeout` / `tls` / `http-404` / `not-json` / `html-body`
 * 对应完全不同的处置（换域名 / 换网络 / 装证书 / 换路径 / 该镜像不是 API / 该镜像返回了网页）。
 */
export class BrewSourceProbe {
  public static async check(baseUrl: string): Promise<BrewProbeResult> {
    const startAt: number = Date.now();
    const urlCheck: BrewSourceUrlCheck = BrewSourceUrl.check(baseUrl);
    if (!urlCheck.ok) {
      return BrewSourceProbe.done(false, ProbeReason.INVALID_URL, 0, startAt, urlCheck.reason);
    }
    const url: string = BrewSourceUrl.join(urlCheck.normalized, `/formula/${BREW_SOURCE_PROBE_TOKEN}.json`);
    try {
      const res: BrewHttpResult = await BrewHttp.request(url, undefined, {}, BREW_SOURCE_PROBE_TIMEOUT_MS);
      return BrewSourceProbe.classify(res, startAt);
    } catch (error) {
      const err = error as BusinessError;
      const reason: string = BrewSourceProbe.classifyError(err);
      Logger.info(TAG, `ok=false code=0 reason=${reason} ms=${Date.now() - startAt} ` +
        `errCode=${err?.code} errMsg=${err?.message} url=${url}`);
      return BrewSourceProbe.done(false, reason, 0, startAt, `code=${err?.code}, msg=${err?.message}`);
    }
  }

  private static classify(res: BrewHttpResult, startAt: number): BrewProbeResult {
    const code: number = res.code;
    const body: string = res.text.trim();
    let reason: string = ProbeReason.OK;
    let ok: boolean = false;
    if (code === http.ResponseCode.OK) {
      if (body.startsWith('<')) {
        // 镜像常见的 HTML 错误页（200 + 一坨 HTML）。必须先于 JSON.parse 判，
        // 否则会得到一个与真实原因无关的语法错误。
        reason = ProbeReason.HTML_BODY;
      } else {
        const shape: string = BrewSourceProbe.checkShape(body);
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
    Logger.info(TAG, `ok=${ok} code=${code} reason=${reason} ms=${Date.now() - startAt} ${detail}`);
    return BrewSourceProbe.done(ok, reason, code, startAt, detail);
  }

  /** 返回 `''` 表示形状正确；否则返回原因码 */
  private static checkShape(body: string): string {
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

  /**
   * 网络异常 → 原因码。
   *
   * ⚠ 超时与 DNS/连接失败在 `code` 上可能**都是 2300003**，只有耗时与 message 能区分 ——
   * 这与 `BrewHttp.request` 里那条注释是同一个坑。
   */
  private static classifyError(err: BusinessError): string {
    const message: string = err?.message ?? '';
    const lower: string = message.toLowerCase();
    if (lower.indexOf('timeout') >= 0 || lower.indexOf('timed out') >= 0) {
      return ProbeReason.TIMEOUT;
    }
    if (lower.indexOf('resolve') >= 0 || lower.indexOf('dns') >= 0 ||
      lower.indexOf('name or service not known') >= 0 || lower.indexOf('nodename') >= 0) {
      return ProbeReason.DNS;
    }
    if (lower.indexOf('certificate') >= 0 || lower.indexOf('ssl') >= 0 || lower.indexOf('tls') >= 0) {
      return ProbeReason.TLS;
    }
    return ProbeReason.NETWORK_UNKNOWN;
  }

  private static done(ok: boolean, reason: string, httpCode: number, startAt: number,
    detail: string): BrewProbeResult {
    return new BrewProbeResult(ok, reason, httpCode, Date.now() - startAt, detail);
  }
}
```

- [ ] **Step 2: 自检加探测用例**

`BrewSourceDiagnostics.run()` 追加 `BrewSourceDiagnostics.probeCases();`（它是异步的，用 `.catch` 吞掉）：

```ts
  private static probeCases(): void {
    // 用例 1：合法地址（会话激活源）→ 期望 ok
    BrewSourceProbe.check(BrewSourceStore.activeBaseUrl())
      .then((r: BrewProbeResult) => Logger.info(TAG,
        `verify probe ok-case ok=${r.ok} reason=${r.reason} code=${r.httpCode} ms=${r.tookMs}`))
      .catch(() => Logger.error(TAG, 'verify probe ok-case threw'));
    // 用例 2：格式非法 → invalid-url（不发请求）
    BrewSourceProbe.check('notaurl')
      .then((r: BrewProbeResult) => Logger.info(TAG,
        `verify probe invalid ok=${!r.ok && r.reason === 'invalid-url'} reason=${r.reason}`))
      .catch(() => Logger.error(TAG, 'verify probe invalid threw'));
    // 用例 3：DNS 必然失败 → dns / network-unknown
    BrewSourceProbe.check('https://nonexistent-host-for-verify.invalid/api')
      .then((r: BrewProbeResult) => Logger.info(TAG,
        `verify probe dns ok=${!r.ok} reason=${r.reason}`))
      .catch(() => Logger.error(TAG, 'verify probe dns threw'));
    // 用例 4：不存在的 token → http-404
    BrewSourceProbe.check(`${BrewSourceStore.activeBaseUrl()}`)
      .then(() => BrewSourceProbe.check(
        BrewSourceUrl.join(BrewSourceStore.activeBaseUrl(), '/formula/zzz-not-a-real-token-verify.json')))
      .then((r: BrewProbeResult) => Logger.info(TAG,
        `verify probe 404 ok=${!r.ok && r.reason === 'http-404'} reason=${r.reason} code=${r.httpCode}`))
      .catch(() => Logger.error(TAG, 'verify probe 404 threw'));
  }
```

新增 import：`import { BrewProbeResult } from '../model/BrewSourceModels';`、
`import { BrewSourceProbe } from './BrewSourceProbe';`、`import { BrewSourceUrl } from './BrewSourceUrl';`

`Index.ets` 追加 `export { BrewSourceProbe } from './src/main/ets/service/BrewSourceProbe';`

- [ ] **Step 3: 编译**

```bash
devecocli build
```
Expected: `BUILD SUCCESSFUL`，0 error。

- [ ] **Step 4: 真机验证 4 类 reason（Review Focus #2 的前半）**

`BREW_SOURCE_VERIFY = true`，运行后：

```bash
devecocli run
devecocli log --from 90s | grep "verify probe"
```

Expected（`ms` 会不同）：

```
[BrewSourceProbe] ok=true code=200 reason=ok ms=… bodyLen=…
[BrewSource] verify probe ok-case ok=true reason=ok code=200 ms=…
[BrewSource] verify probe invalid ok=true reason=invalid-url
[BrewSource] verify probe dns ok=true reason=dns
[BrewSourceProbe] ok=false code=404 reason=http-404 ms=…
[BrewSource] verify probe 404 ok=true reason=http-404 code=404
```

**判定**：`invalid` 用例必须**不发任何请求**（日志里看不到对应 `[BrewHttp]` 行）；
`dns` 用例的 reason 允许是 `dns` 或 `network-unknown`（不同网络栈的 message 文案不同），
但**不允许**是 `timeout`（那说明 DNS 失败被误判成超时，需修 `classifyError`）。
验证完把 `BREW_SOURCE_VERIFY` 改回 `false`。

- [ ] **Step 5: 提交**

```bash
git add features/brewcommon/Index.ets \
  features/brewcommon/src/main/ets/service/BrewSourceProbe.ets \
  features/brewcommon/src/main/ets/service/BrewSourceDiagnostics.ets
git commit -m "feat(brew): 数据源激活前的单端点探测与错误分类

- 11 类 reason：invalid-url/dns/timeout/tls/http-404/http-4xx/http-5xx/not-json/html-body/shape-mismatch/network-unknown
- HTML 体先于 JSON.parse 判定，避免拿到与真实原因无关的语法错误
- 超时与 DNS 失败在 code 上可能相同，靠 message 区分"
```

---

### Task 6: `BrewCacheAdmin`（stats / clear / drop + 世代号守卫 + 内存重置）

**Files:**
- Create: `features/brewcommon/src/main/ets/service/BrewCacheEpoch.ets`
- Create: `features/brewcommon/src/main/ets/service/BrewCacheAdmin.ets`
- Modify: `features/brewcommon/src/main/ets/service/BrewService.ets`（新增 `resetMemoryCaches()`；4 处写入口加世代号守卫）
- Modify: `features/brewcommon/src/main/ets/service/BrewMetaSync.ets`（新增 `resetMemoryIndex()`；2 处写入口加守卫）
- Modify: `features/brewcommon/src/main/ets/service/BrewSourceDiagnostics.ets`
- Modify: `features/brewcommon/Index.ets`

**Interfaces:**
- Consumes: `BrewSourcePrefs.openFor/releaseFor`（Task 2）、`BrewSourceStore`（Task 1）、`objKeys`（Task 1）
- Produces:
  - `BrewCacheEpoch.current(): number`、`BrewCacheEpoch.bump(): number`
  - `BrewCacheAdmin.stats(sourceId: string): BrewSourceCacheStats`
  - `BrewCacheAdmin.clear(sourceId: string): Promise<void>`
  - `BrewCacheAdmin.drop(sourceId: string): Promise<void>`
  - `BrewService.resetMemoryCaches(): void`
  - `BrewMetaSync.resetMemoryIndex(): void`

- [ ] **Step 1: 写世代号（独立文件，避免循环 import）**

`features/brewcommon/src/main/ets/service/BrewCacheEpoch.ets`：

```ts
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

/**
 * 缓存世代号。
 *
 * ## 它解决什么
 *
 * 「清空某源缓存」和「后台正在写入该源缓存」会撞车：元数据同步一次要跑几十秒到几分钟，
 * 目录刷新要 17 秒。用户在这期间点「清空缓存」，随后的写入会把刚清掉的东西**写回去** ——
 * 表现为「清了但没清掉」，而且下一次进页面数据又回来了，用户无法理解。
 *
 * ## 机制
 *
 * 清空/删除时 `bump()`。所有**长时间运行**的写入口在操作开始时 `current()` 存一份，
 * 写之前比对：不相等就**丢弃结果**（既不写盘也不更新内存），并打一条
 * `[BrewCache] epoch mismatch, dropped write key=…`。
 *
 * ## 为什么单独一个文件
 *
 * `BrewService` 需要读它、`BrewCacheAdmin` 需要写它、而 `BrewCacheAdmin` 又要调
 * `BrewService.resetMemoryCaches()`。放在两者任一里都会形成运行时循环 import。
 */
export class BrewCacheEpoch {
  private static value: number = 0;

  public static current(): number {
    return BrewCacheEpoch.value;
  }

  public static bump(): number {
    BrewCacheEpoch.value++;
    return BrewCacheEpoch.value;
  }
}
```

- [ ] **Step 2: 给 `BrewService` 加内存重置与守卫**

`BrewService` 新增公开方法（放在 `DETAIL_PAGE_DATA` 附近）：

```ts
  /**
   * 重置**全部**进程内缓存。清空当前激活源的缓存时必须调它，否则内存里的旧数据
   * 会在下一次 flush 时把盘上刚清掉的内容写回去。
   *
   * 注意 `activeHydrates` **不强制清零**：可能有在途批次正在跑，强清会破坏它的计数配对。
   * 在途写入靠 `BrewCacheEpoch` 丢弃，不需要动这个计数。
   */
  public static resetMemoryCaches(): void {
    BrewService.liveCache = undefined;
    BrewService.cacheDirty = false;
    BrewService.datasetStamps = undefined;
    BrewService.stampsDirty = false;
    BrewService.probeCache.clear();
    BrewService.missCache.clear();
    BrewService.inFlight.clear();
    BrewService.degradedWarned = {};
    BrewService.stats = { hit: 0, renewed: 0, notModified: 0, downloaded: 0, downloadedWithCond: 0,
      downloadedNoCond: 0, failed: 0, catalogFailed: 0 };
    BrewService.catalog = undefined;
    BrewService.catalogLoaded = false;
    BrewService.catalogInFlight = undefined;
    // 作废在途页面构建：自增序号后，旧构建完成时不会清掉新构建的在途字段
    BrewService.formulaPageInFlightId++;
    BrewService.formulaPageInFlight = undefined;
    BrewService.formulaPageInFlightPageSize = 0;
    BrewService.formulaPageInFlightAt = 0;
    BrewService.caskPageInFlightId++;
    BrewService.caskPageInFlight = undefined;
    BrewService.caskPageInFlightPageSize = 0;
    BrewService.caskPageInFlightAt = 0;
    Logger.info(TAG, 'memory caches reset');
  }
```

守卫加在 4 处写入口。以 `flushCache` 为例：

```ts
  /** 批次结束时刷一次盘（只在内存里有变更时） */
  private static flushCache(): void {
    // 世代号守卫：清空缓存之后，在途批次的写入必须丢弃，否则「清了没清掉」
    if (BrewService.flushEpoch !== BrewCacheEpoch.current()) {
      BrewService.cacheDirty = false;
      BrewService.stampsDirty = false;
      BrewService.flushEpoch = BrewCacheEpoch.current();
      Logger.info(TAG, '[BrewCache] epoch mismatch, dropped write key=brew_live_data');
      return;
    }
    if (BrewService.cacheDirty && BrewService.liveCache !== undefined) {
      BrewSourcePrefs.set<Record<string, LiveCacheEntry>>(BREW_LIVE_STORAGE_KEY, BrewService.liveCache);
      BrewService.cacheDirty = false;
      Logger.info(TAG, `live cache flushed, ${Object.keys(BrewService.liveCache).length} entries`);
    }
    if (BrewService.stampsDirty && BrewService.datasetStamps !== undefined) {
      BrewSourcePrefs.set<Record<string, DatasetStamp>>(BREW_LIVE_DATASET_KEY, BrewService.datasetStamps);
      BrewService.stampsDirty = false;
    }
  }
```

新增 static 字段 `private static flushEpoch: number = BrewCacheEpoch.current();`（与 `cacheDirty` 放一起）。

同样的守卫加到：

- `saveCatalog(catalog)`：

```ts
  private static saveCatalog(catalog: BrewCatalog): void {
    if (BrewService.catalogEpoch !== BrewCacheEpoch.current()) {
      BrewService.catalogEpoch = BrewCacheEpoch.current();
      Logger.info(TAG, '[BrewCache] epoch mismatch, dropped write key=brew_catalog');
      return;
    }
    BrewService.catalog = catalog;
    BrewService.catalogLoaded = true;
    BrewSourcePrefs.set<BrewCatalog>(BREW_CATALOG_STORAGE_KEY, catalog);
  }
```
（新增 static 字段 `private static catalogEpoch: number = BrewCacheEpoch.current();`）

- `rememberStamp(kind, lastModified, etag)`：在 `stamps[kind] = …` 之前比对 `BrewService.stampEpoch`，
  不匹配则直接 return 并打同一行日志（`key=brew_live_dataset`）。

- `datasetProbe` 的 `rememberStamp` 调用走同一个受保护的方法，无需额外处理。

`BrewService` 加 import：`import { BrewCacheEpoch } from './BrewCacheEpoch';`

- [ ] **Step 3: 给 `BrewMetaSync` 加内存重置与守卫**

```ts
  /**
   * 重置进程内索引。清空当前激活源缓存时调用。
   *
   * **`started` 保持不动**：清缓存不应该触发一次 5.29MB 的全量重下。索引留空，
   * 下次进程启动时 `start()` 自然会重新同步。代价是清空后浏览页会降级 —— 这是预期行为。
   */
  public static resetMemoryIndex(): void {
    BrewMetaSync.index = undefined;
    BrewMetaSync.stamps = undefined;
    Logger.info(TAG, 'meta memory index reset');
  }
```

`persistIndex(next)` 与 `rememberStamp(kind, lastModified)` 各加守卫：

```ts
  private static persistIndex(next: BrewMetaIndex): void {
    if (BrewMetaSync.epoch !== BrewCacheEpoch.current()) {
      BrewMetaSync.epoch = BrewCacheEpoch.current();
      Logger.info(TAG, '[BrewCache] epoch mismatch, dropped write key=brew_meta_index');
      return;
    }
    BrewMetaSync.index = next;
    const t0: number = Date.now();
    BrewSourcePrefs.set<BrewMetaIndex>(BREW_META_INDEX_KEY, next);
    Logger.info(TAG, `meta index persisted, formula=${Object.keys(next.formula).length} ` +
      `cask=${Object.keys(next.cask).length}, pref write=${Date.now() - t0}ms`);
  }
```

`rememberStamp`：

```ts
  private static rememberStamp(kind: string, lastModified: string): void {
    if (lastModified.length === 0) {
      return;
    }
    if (BrewMetaSync.epoch !== BrewCacheEpoch.current()) {
      BrewMetaSync.epoch = BrewCacheEpoch.current();
      Logger.info(TAG, '[BrewCache] epoch mismatch, dropped write key=brew_meta_stamp');
      return;
    }
    const stamps: Record<string, string> = BrewMetaSync.ensureStamps();
    if (stamps[kind] === lastModified) {
      return;
    }
    stamps[kind] = lastModified;
    BrewSourcePrefs.set<Record<string, string>>(BREW_META_STAMP_KEY, stamps);
  }
```

新增 static 字段 `private static epoch: number = BrewCacheEpoch.current();`，加 import。

- [ ] **Step 4: 写 `BrewCacheAdmin`**

`features/brewcommon/src/main/ets/service/BrewCacheAdmin.ets`：

```ts
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

import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '@ohos/common';
import { BrewSourceCacheStats } from '../model/BrewSourceModels';
import { objKeys } from '../util/objkeys';
import { BrewCacheEpoch } from './BrewCacheEpoch';
import { BrewService } from './BrewService';
import { BrewMetaSync } from './BrewMetaSync';
import { BrewSourcePrefs } from './BrewSourcePrefs';
import { BrewSourceStore } from './BrewSourceStore';

const TAG: string = '[BrewCache]';

/**
 * 源缓存的维护入口：查看 / 清空 / 删除。
 *
 * ## 为什么 clear/drop 要串行
 *
 * 官方文档明确：「不允许 `deletePreferences` 与其他接口多线程、多进程并发调用，
 * 否则可能会发生不可预期行为」。所以这里用一个 Promise 链把维护操作排成队列。
 *
 * ## 为什么清空激活源要重置内存
 *
 * 内存里还有一份 `liveCache` / `catalog` / 索引。只清盘不重置内存，下一次 flush
 * 就会把它们写回去 —— 用户看到「清了但数据还在」。配合 `BrewCacheEpoch` 一起，
 * 在途的后台写入也会被丢弃。
 *
 * ## 为什么删激活源被拒绝
 *
 * 本进程的 store 句柄正指着它，删掉会让句柄悬空；而「切走」这个动作本身就是重启，
 * 重启后再删即可。拒绝比「自动切回官方 + 重启」更可预测。
 */
export class BrewCacheAdmin {
  private static queue: Promise<void> = Promise.resolve();

  /** 单源缓存统计。**会打开该源的 store**（非激活源用完即释放） */
  public static stats(sourceId: string): BrewSourceCacheStats {
    const out: BrewSourceCacheStats = new BrewSourceCacheStats();
    out.sourceId = sourceId;
    const store: preferences.Preferences | null = BrewSourcePrefs.openFor(sourceId);
    if (store === null) {
      return out;
    }
    const t0: number = Date.now();
    try {
      const all: Object = store.getAllSync();
      const keys: string[] = objKeys(all);
      const map: Record<string, Object> = all as Record<string, Object>;
      out.keys = keys.length;
      keys.forEach((key: string) => {
        const raw: string = typeof map[key] === 'string' ? map[key] as string : JSON.stringify(map[key]);
        out.approxBytes += raw.length;
        out.entries += BrewCacheAdmin.countEntries(key, raw);
        const ts: number = BrewCacheAdmin.extractTs(key, raw);
        if (ts > out.updatedAt) {
          out.updatedAt = ts;
        }
      });
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.error(TAG, `stats failed, id=${sourceId}, code=${e.code}, msg=${e.message}`);
    }
    if (sourceId !== BrewSourceStore.sessionActive().id) {
      BrewSourcePrefs.releaseFor(sourceId);
    }
    Logger.info(TAG, `stats id=${sourceId} keys=${out.keys} entries=${out.entries} ` +
      `bytes=${out.approxBytes} ms=${Date.now() - t0}`);
    return out;
  }

  /** 清空某源的缓存。激活源会同时重置内存态 */
  public static clear(sourceId: string): Promise<void> {
    return BrewCacheAdmin.enqueue(() => {
      const isActive: boolean = sourceId === BrewSourceStore.sessionActive().id;
      const before: number = BrewCacheEpoch.current();
      // 先 bump 世代号：让在途写入从此刻起全部失效
      const after: number = BrewCacheEpoch.bump();
      const store: preferences.Preferences | null = BrewSourcePrefs.openFor(sourceId);
      if (store !== null) {
        try {
          store.clearSync();
        } catch (err) {
          const e: BusinessError = err as BusinessError;
          Logger.error(TAG, `clearSync failed, id=${sourceId}, code=${e.code}, msg=${e.message}`);
        }
      }
      if (isActive) {
        // 顺序很重要：先作废世代号，再重置内存指针，最后才清盘
        BrewService.resetMemoryCaches();
        BrewMetaSync.resetMemoryIndex();
      }
      if (sourceId !== BrewSourceStore.sessionActive().id) {
        BrewSourcePrefs.releaseFor(sourceId);
      }
      Logger.info(TAG, `clear id=${sourceId} active=${isActive} epoch=${before}→${after}`);
    });
  }

  /** 删除某源的整个 store。builtin 与会话激活源会被拒绝 */
  public static drop(sourceId: string): Promise<void> {
    return BrewCacheAdmin.enqueue(() => {
      if (sourceId === BrewSourceStore.sessionActive().id) {
        Logger.error(TAG, `drop rejected, id=${sourceId} is the session active source`);
        return;
      }
      const before: number = BrewCacheEpoch.current();
      const after: number = BrewCacheEpoch.bump();
      BrewSourcePrefs.releaseFor(sourceId);
      const removed: boolean = BrewSourceStore.removeSource(sourceId);
      if (!removed) {
        Logger.error(TAG, `drop rejected by registry, id=${sourceId}`);
        return;
      }
      Logger.info(TAG, `drop id=${sourceId} ok=true epoch=${before}→${after}`);
    });
  }

  private static enqueue(task: () => void): Promise<void> {
    const next: Promise<void> = BrewCacheAdmin.queue.then(() => {
      task();
    }).catch((err: BusinessError) => {
      Logger.error(TAG, `maintenance task failed, code=${err?.code}, msg=${err?.message}`);
    });
    BrewCacheAdmin.queue = next;
    return next;
  }

  /** 结构化条目数。口径见 spec §9.1。用 `objKeys`（ArkTS 不允许 `Object.keys(Object)`） */
  private static countEntries(key: string, raw: string): number {
    try {
      if (key === 'brew_live_data') {
        return objKeys(JSON.parse(raw) as Object).length;
      }
      if (key === 'brew_meta_index') {
        const index: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
        const formula: Record<string, string> | undefined = index['formula'] as Record<string, string> | undefined;
        const cask: Record<string, string> | undefined = index['cask'] as Record<string, string> | undefined;
        const n1: number = formula !== undefined ? objKeys(formula as Object).length : 0;
        const n2: number = cask !== undefined ? objKeys(cask as Object).length : 0;
        return n1 + n2;
      }
      if (key === 'brew_catalog') {
        const catalog: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
        const top: Record<string, Object[]> | undefined = catalog['topTokens'] as Record<string, Object[]> | undefined;
        if (top === undefined) {
          return 0;
        }
        let n: number = 0;
        objKeys(top as Object).forEach((kind: string) => {
          const rows: Object[] | undefined = top[kind];
          n += rows !== undefined ? rows.length : 0;
        });
        return n;
      }
      if (key === 'brew_detail_page_data') {
        return objKeys(JSON.parse(raw) as Object).length;
      }
    } catch (err) {
      return 0;
    }
    return 0;
  }

  private static extractTs(key: string, raw: string): number {
    try {
      if (key === 'brew_catalog') {
        const catalog: Record<string, number> = JSON.parse(raw) as Record<string, number>;
        return catalog['ts'] ?? 0;
      }
      if (key === 'brew_meta_index') {
        const index: Record<string, number> = JSON.parse(raw) as Record<string, number>;
        return index['ts'] ?? 0;
      }
    } catch (err) {
      return 0;
    }
    return 0;
  }
}
```

> `drop()` 里刻意**先** `releaseFor()` 再 `removeSource()`：`removeSource` 会检查「是不是激活源」，
> 而 `releaseFor` 只是释放临时句柄，不影响该判断。两者顺序无副作用耦合。
> 另外注意 `BrewSourceStore.removeSource` 只删注册表条目；**store 文件的删除由本方法的调用方
> 通过 `deletePreferences` 完成** —— 见 Step 5。

- [ ] **Step 5: 补 `drop` 的 store 文件删除**

`BrewSourcePrefs` 增加一个方法（因为只有它持有 Context）：

```ts
  /**
   * 删除一个源的 store 文件。**必须先释放句柄**（调用方负责），
   * 否则 `deletePreferences` 会因实例仍被占用而失败。
   *
   * `deletePreferences` 是异步 API 且不允许与其它接口并发 —— 调用方（`BrewCacheAdmin.drop`）
   * 已经把它排在串行队列里。
   */
  public static async deleteStore(sourceId: string): Promise<boolean> {
    const ctx: Context | undefined = BrewSourcePrefs.context();
    if (ctx === undefined) {
      Logger.error(TAG, `deleteStore deferred, uicontext is undefined, id=${sourceId}`);
      return false;
    }
    const name: string = BrewSourcePrefs.storeNameOf(sourceId);
    try {
      await preferences.deletePreferences(ctx, name);
      Logger.info(TAG, `store deleted, id=${sourceId}, name=${name}`);
      return true;
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.error(TAG, `store delete failed, id=${sourceId}, name=${name}, code=${e.code}, msg=${e.message}`);
      return false;
    }
  }
```

`BrewCacheAdmin.drop` 改为异步执行（`enqueue` 的 `task` 允许返回 Promise）：

```ts
  public static drop(sourceId: string): Promise<void> {
    return BrewCacheAdmin.enqueue(() => {
      if (sourceId === BrewSourceStore.sessionActive().id) {
        Logger.error(TAG, `drop rejected, id=${sourceId} is the session active source`);
        return Promise.resolve();
      }
      const before: number = BrewCacheEpoch.current();
      const after: number = BrewCacheEpoch.bump();
      BrewSourcePrefs.releaseFor(sourceId);
      const removed: boolean = BrewSourceStore.removeSource(sourceId);
      if (!removed) {
        Logger.error(TAG, `drop rejected by registry, id=${sourceId}`);
        return Promise.resolve();
      }
      return BrewSourcePrefs.deleteStore(sourceId).then((ok: boolean) => {
        Logger.info(TAG, `drop id=${sourceId} ok=${ok} epoch=${before}→${after}`);
      });
    });
  }

  private static enqueue(task: () => Promise<void>): Promise<void> {
    const next: Promise<void> = BrewCacheAdmin.queue.then(() => task())
      .catch((err: BusinessError) => {
        Logger.error(TAG, `maintenance task failed, code=${err?.code}, msg=${err?.message}`);
      });
    BrewCacheAdmin.queue = next;
    return next;
  }
```

`clear` 的 `task` 返回 `Promise.resolve()`。

- [ ] **Step 6: 自检加「一次性 throwaway 源」的 stats→clear→drop 用例**

这是 Review Focus #3 / #4 的验证点，且**完全不碰真实数据**。

`BrewSourceDiagnostics.run()` 追加 `BrewSourceDiagnostics.cacheCases();`

```ts
  private static cacheCases(): void {
    // 用一次性 throwaway 源走完整链路：新增 → 写垃圾 → stats → clear → drop → 确认 store 已删。
    // 全程不碰真实源，所以可以在任何设备上反复跑。
    const created: BrewSource | undefined = BrewSourceStore.addSource(
      'verify-throwaway', 'https://verify-throwaway.invalid/api');
    if (created === undefined) {
      Logger.error(TAG, 'verify cache setup failed (addSource returned undefined)');
      return;
    }
    const id: string = created.id;
    // 直接往该源的 store 里塞两个键
    const store: preferences.Preferences | null = BrewSourcePrefs.openFor(id);
    if (store === null) {
      Logger.error(TAG, 'verify cache setup failed (store null)');
      return;
    }
    try {
      // 直接写 JSON 字符串，不用 `JSON.stringify({...})`：
      // ArkTS 的 `arkts-no-untyped-obj-literals` 不允许把无类型对象字面量当实参传出去。
      // 形状与真实缓存一致：live_data = 3 个 doc，meta_index = formula 1 条 + cask 0 条（合计 4 条）。
      store.putSync('brew_live_data', '{"a":1,"b":2,"c":3}');
      store.putSync('brew_meta_index',
        '{"ts":' + Date.now() + ',"formula":{"x":"d"},"cask":{}}');
    } catch (err) {
      Logger.error(TAG, 'verify cache setup putSync failed');
    }
    BrewSourcePrefs.releaseFor(id);

    const stats1: BrewSourceCacheStats = BrewCacheAdmin.stats(id);
    Logger.info(TAG, `verify cache stats keys=${stats1.keys} entries=${stats1.entries} ` +
      `bytes=${stats1.approxBytes} ok=${stats1.keys === 2 && stats1.entries === 4}`);

    BrewCacheAdmin.clear(id).then(() => {
      const stats2: BrewSourceCacheStats = BrewCacheAdmin.stats(id);
      Logger.info(TAG, `verify cache cleared keys=${stats2.keys} ok=${stats2.keys === 0}`);
      return BrewCacheAdmin.drop(id);
    }).then(() => {
      // drop 之后再开同名 store 应该是空的（文件已删 → 重新创建）
      const stats3: BrewSourceCacheStats = BrewCacheAdmin.stats(id);
      const gone: boolean = BrewSourceStore.find(id) === undefined;
      Logger.info(TAG, `verify cache dropped registryGone=${gone} keysAfterDrop=${stats3.keys} ` +
        `ok=${gone && stats3.keys === 0}`);
      // Review Focus #4：删掉后立刻用**同名但新 id** 新增，不能复用旧缓存。
      // 复用会体现在「新源的 store 一开就有键」—— 因为 store 名带 id，所以这里必须是 0。
      const again: BrewSource | undefined = BrewSourceStore.addSource(
        'verify-throwaway', 'https://verify-throwaway.invalid/api');
      if (again === undefined) {
        Logger.error(TAG, 'verify cache re-add failed');
        return Promise.resolve();
      }
      const fresh: BrewSourceCacheStats = BrewCacheAdmin.stats(again.id);
      const distinct: boolean = again.id !== id;
      Logger.info(TAG, `verify cache re-added newId=${distinct} keys=${fresh.keys} ` +
        `ok=${distinct && fresh.keys === 0}`);
      return BrewCacheAdmin.drop(again.id);
    }).then(() => {
      // Review Focus #2：健康状态机。不碰网络，直接构造运行期记录。
      const id2: string = BrewSourceStore.sessionActive().id;
      BrewSourceStore.noteProbe(id2, true, 'ok');
      BrewSourceStore.noteCatalogOk(id2);
      const okState: BrewSourceHealth = BrewSourceStore.healthState(id2);
      BrewSourceStore.noteError(id2, 'catalog', 'verify-simulated');
      const partialState: BrewSourceHealth = BrewSourceStore.healthState(id2);
      BrewSourceStore.noteProbe(id2, false, 'http-404');
      const failState: BrewSourceHealth = BrewSourceStore.healthState(id2);
      const allOk: boolean = okState === BrewSourceHealth.OK &&
        partialState === BrewSourceHealth.PARTIAL && failState === BrewSourceHealth.FAILING;
      Logger.info(TAG, `verify health ok=${okState} partial=${partialState} failing=${failState} ` +
        `allOk=${allOk}`);
      // 复原：别把自检造出来的失败记录留在真实源上
      BrewSourceStore.noteProbe(id2, true, 'ok');
      BrewSourceStore.noteCatalogOk(id2);
    }).catch(() => Logger.error(TAG, 'verify cache chain threw'));
  }
```

新增 import：`import { BrewCacheAdmin } from './BrewCacheAdmin';`、
`import { BrewSourceCacheStats, BrewSourceHealth } from '../model/BrewSourceModels';`

`Index.ets` 追加：

```ts
export { BrewCacheAdmin } from './src/main/ets/service/BrewCacheAdmin';
export { BrewCacheEpoch } from './src/main/ets/service/BrewCacheEpoch';
```

- [ ] **Step 7: 编译**

```bash
devecocli build
```
Expected: `BUILD SUCCESSFUL`，0 error。

- [ ] **Step 8: 真机验证 stats / clear / drop（Review Focus #3、#4）**

`BREW_SOURCE_VERIFY = true`，运行后：

```bash
devecocli run
devecocli log --from 120s | grep -E "verify cache|\[BrewCache\]|store deleted"
```

Expected：

```
[BrewCache] stats id=src_… keys=2 entries=4 bytes=… ms=…
[BrewSource] verify cache stats keys=2 entries=4 bytes=… ok=true
[BrewCache] clear id=src_… active=false epoch=0→1
[BrewCache] stats id=src_… keys=0 entries=0 bytes=0 ms=…
[BrewSource] verify cache cleared keys=0 ok=true
[BrewSource] source removed, id=src_…, left=1
[BrewSource] store deleted, id=src_…, name=brew_src_src_…
[BrewCache] drop id=src_… ok=true epoch=1→2
[BrewSource] verify cache dropped registryGone=true keysAfterDrop=0 ok=true
[BrewSource] verify cache re-added newId=true keys=0 ok=true
[BrewSource] verify health ok=ok partial=partial failing=failing allOk=true
```

最后两行分别对应 **Review Focus #4**（删后同名重加不复用缓存）与 **Review Focus #2**（部分可用的状态机）。
`verify health` 之后会把自检造出来的失败记录复原，不会污染真实源。

**再单独验证世代号守卫（Review Focus #3）**：这一步需要一次「清空时后台同步在跑」的时机。
做法是在 `BrewCacheAdmin.clear` 的 `BrewCacheEpoch.bump()` 之后临时插入 `Logger.info` 已知它已执行，
然后在**冷启动后 5 秒内**（元数据同步还在下载 5.29MB）从设置页清空激活源缓存。若时序难以复现，
用更可靠的做法：临时把 `BREW_META_SYNC` 的等待预算改大以保证同步仍在跑，操作后确认日志出现

```
[BrewCache] epoch mismatch, dropped write key=brew_meta_index
```

且**没有**出现该次同步的 `meta index persisted`。验证完恢复 `BREW_META_SYNC` 原值、把
`BREW_SOURCE_VERIFY` 改回 `false`。

- [ ] **Step 9: 提交**

```bash
git add features/brewcommon/Index.ets \
  features/brewcommon/src/main/ets/service/BrewCacheEpoch.ets \
  features/brewcommon/src/main/ets/service/BrewCacheAdmin.ets \
  features/brewcommon/src/main/ets/service/BrewSourcePrefs.ets \
  features/brewcommon/src/main/ets/service/BrewService.ets \
  features/brewcommon/src/main/ets/service/BrewMetaSync.ets \
  features/brewcommon/src/main/ets/service/BrewSourceDiagnostics.ets
git commit -m "feat(brew): 源缓存的查看/清空/删除与世代号守卫

- BrewCacheAdmin：stats 走 getAllSync、clear 走 clearSync、drop 走 deletePreferences，全部串行
- 清空激活源时同时重置 BrewService/BrewMetaSync 的内存态
- BrewCacheEpoch 守卫：清空后在途的后台写入被丢弃，解决「清了没清掉」
- 删激活源与官方源被拒绝；删非激活源会释放句柄后再删文件"
```

---

### Task 7: 数据源设置页（列表 / 新增 / 编辑 / 删除 / 查看 / 清空）

**Files:**
- Create: `features/mine/src/main/ets/viewmodel/BrewSourceSettingState.ets`
- Create: `features/mine/src/main/ets/viewmodel/BrewSourceSettingVM.ets`
- Create: `features/mine/src/main/ets/view/BrewSourceSettingView.ets`
- Modify: `features/mine/src/main/ets/view/MineSettingView.ets`
- Modify: `features/mine/src/main/resources/base/profile/router_map.json`
- Modify: `features/mine/src/main/resources/{base,zh_CN,en_US}/element/string.json`

**Interfaces:**
- Consumes: `BrewSourceStore`、`BrewSourceHealth`、`BrewSourceCacheStats`、`BrewCacheAdmin`、`BrewSourceUrl`（Task 1/6）
- Produces: 路由名 `BrewSourceSettingView`、builder `BrewSourceSettingBuilder`；`BrewSourceSettingVM.sendEvent` 接受 `BrewSourceInitEvent` / `BrewSourceRefreshEvent` / `BrewSourceSaveEvent` / `BrewSourceClearEvent` / `BrewSourceDeleteEvent`

- [ ] **Step 1: 写状态**

`features/mine/src/main/ets/viewmodel/BrewSourceSettingState.ets`：

```ts
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

import { BaseState } from '@ohos/common';
import { BrewSource, BrewSourceHealth, BrewSourceCacheStats } from '@ohos/brewcommon';

/** 列表一行。`BrewSource` 是纯数据类，UI 需要额外的展示字段，所以包一层。
 *
 * 不加 `@Observed`：VM 每次 `refresh()` 都**整体替换** `state.rows`，靠 `@State` 的
 * 顶层赋值通知即可；给元素加 `@Observed` 而不配 `@ObjectLink` 是无效的。
 */
export class BrewSourceRow {
  public source: BrewSource;
  public health: BrewSourceHealth = BrewSourceHealth.UNKNOWN;
  public isActive: boolean = false;
  /** 本会话冻结的 active 源 id —— 「使用中」标注看它，不是看注册表的 activeId */
  public isSessionActive: boolean = false;
  public stats: BrewSourceCacheStats | undefined = undefined;

  public constructor(source: BrewSource) {
    this.source = source;
  }
}

@Observed
export class BrewSourceSettingState extends BaseState {
  public rows: BrewSourceRow[] = [];
  /** 正在编辑的源 id；空串表示没在编辑 */
  public editingId: string = '';
  public editingName: string = '';
  public editingUrl: string = '';
  /** 错误提示（表单校验 / 探测失败 / 操作被拒），空串表示无 */
  public errorText: string = '';
  /** 正在进行的操作提示 */
  public busyText: string = '';
  /** 缓存详情面板正在展示的源 id */
  public cachePanelId: string = '';
  public cachePanelStats: BrewSourceCacheStats | undefined = undefined;
  /** 激活流程：正在探测的源 id */
  public probingId: string = '';
  /** 本会话激活源 id（冻结值） */
  public sessionActiveId: string = '';
}
```

- [ ] **Step 2: 写 VM**

`features/mine/src/main/ets/viewmodel/BrewSourceSettingVM.ets`：

```ts
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

import { common } from '@kit.AbilityKit';
import { BaseVM, BaseVMEvent } from '@ohos/common';
import {
  BrewCacheAdmin,
  BrewSource,
  BrewSourceCacheStats,
  BrewSourceHealth,
  BrewSourceStore,
  BrewSourceUpdateResult,
  BrewSourceUrl,
  BrewSourceUrlCheck,
} from '@ohos/brewcommon';
import { BrewSourceRow, BrewSourceSettingState } from './BrewSourceSettingState';

export class BrewSourceInitEvent implements BaseVMEvent {
}

export class BrewSourceRefreshEvent implements BaseVMEvent {
}

export class BrewSourceSaveEvent implements BaseVMEvent {
  public id: string = '';
  public name: string = '';
  public url: string = '';

  public constructor(id: string, name: string, url: string) {
    this.id = id;
    this.name = name;
    this.url = url;
  }
}

export class BrewSourceClearEvent implements BaseVMEvent {
  public id: string = '';

  public constructor(id: string) {
    this.id = id;
  }
}

export class BrewSourceDeleteEvent implements BaseVMEvent {
  public id: string = '';

  public constructor(id: string) {
    this.id = id;
  }
}

export class BrewSourceEditStartEvent implements BaseVMEvent {
  public id: string = '';
  public name: string = '';
  public url: string = '';

  public constructor(id: string, name: string, url: string) {
    this.id = id;
    this.name = name;
    this.url = url;
  }
}

export class BrewSourceEditCancelEvent implements BaseVMEvent {
}

export class BrewSourceSettingVM extends BaseVM<BrewSourceSettingState> {
  private static instance: BrewSourceSettingVM;

  /**
   * 由 View 注入（VM 拿不到 `UIAbilityContext`）。
   *
   * 用函数而不是直接存 context：`UIAbilityContext` 属于 UI 层，VM 持有它会把两者绑死；
   * 存成「需要时再取」的提供者，也让 VM 在非 UI 环境下（自检/后续测试）可以不给它。
   */
  public contextProvider: (() => common.UIAbilityContext | undefined) | undefined = undefined;

  private constructor() {
    super(new BrewSourceSettingState());
  }

  public static getInstance(): BrewSourceSettingVM {
    if (!BrewSourceSettingVM.instance) {
      BrewSourceSettingVM.instance = new BrewSourceSettingVM();
    }
    return BrewSourceSettingVM.instance;
  }

  public sendEvent(event: BaseVMEvent): void {
    if (event instanceof BrewSourceInitEvent || event instanceof BrewSourceRefreshEvent) {
      this.refresh();
    } else if (event instanceof BrewSourceSaveEvent) {
      this.save(event);
    } else if (event instanceof BrewSourceEditStartEvent) {
      this.state.editingId = event.id;
      this.state.editingName = event.name;
      this.state.editingUrl = event.url;
      this.state.errorText = '';
    } else if (event instanceof BrewSourceEditCancelEvent) {
      this.state.editingId = '';
      this.state.editingName = '';
      this.state.editingUrl = '';
      this.state.errorText = '';
    } else if (event instanceof BrewSourceClearEvent) {
      this.clear(event.id);
    } else if (event instanceof BrewSourceDeleteEvent) {
      this.remove(event.id);
    }
  }

  public setEditingName(value: string): void {
    this.state.editingName = value;
  }

  public setEditingUrl(value: string): void {
    this.state.editingUrl = value;
  }

  public refresh(): void {
    const sessionId: string = BrewSourceStore.sessionActive().id;
    this.state.sessionActiveId = sessionId;
    const rows: BrewSourceRow[] = [];
    BrewSourceStore.listSources().forEach((one: BrewSource) => {
      const row: BrewSourceRow = new BrewSourceRow(one);
      row.health = BrewSourceStore.healthState(one.id);
      row.isSessionActive = one.id === sessionId;
      // 注册表的 activeId 与「本会话在用哪个」是两件事：前者重启后生效
      row.isActive = one.id === BrewSourceStore.activeId();
      rows.push(row);
    });
    this.state.rows = rows;
  }

  private save(event: BrewSourceSaveEvent): void {
    const name: string = event.name.trim();
    if (name.length === 0) {
      this.state.errorText = 'name-empty';
      return;
    }
    const check: BrewSourceUrlCheck = BrewSourceUrl.check(event.url);
    if (!check.ok) {
      this.state.errorText = 'url-' + check.reason;
      return;
    }
    if (event.id.length === 0) {
      const created: BrewSource | undefined = BrewSourceStore.addSource(name, check.normalized);
      if (created === undefined) {
        this.state.errorText = 'save-failed';
        return;
      }
    } else {
      const result: BrewSourceUpdateResult = BrewSourceStore.updateSource(event.id, name, check.normalized);
      if (!result.ok) {
        this.state.errorText = 'save-failed';
        return;
      }
      if (result.baseUrlChanged) {
        // 改 URL = 换了一份数据：清掉该源缓存（激活源会同时重置内存态）
        BrewCacheAdmin.clear(event.id).then(() => {
          this.refresh();
        });
      }
    }
    this.state.errorText = '';
    this.state.editingId = '';
    this.state.editingName = '';
    this.state.editingUrl = '';
    this.refresh();
  }

  private clear(id: string): void {
    this.state.busyText = 'clearing';
    BrewCacheAdmin.clear(id).then(() => {
      this.state.busyText = '';
      if (this.state.cachePanelId === id) {
        this.state.cachePanelStats = BrewCacheAdmin.stats(id);
      }
      this.refresh();
    });
  }

  private remove(id: string): void {
    this.state.busyText = 'deleting';
    BrewCacheAdmin.drop(id).then(() => {
      this.state.busyText = '';
      if (this.state.cachePanelId === id) {
        this.state.cachePanelId = '';
        this.state.cachePanelStats = undefined;
      }
      this.refresh();
    });
  }

  public showCache(id: string): void {
    this.state.cachePanelId = id;
    this.state.cachePanelStats = BrewCacheAdmin.stats(id);
  }

  public hideCache(): void {
    this.state.cachePanelId = '';
    this.state.cachePanelStats = undefined;
  }

  /** 官方源只允许改名 */
  public isBuiltin(id: string): boolean {
    const source: BrewSource | undefined = BrewSourceStore.find(id);
    return source !== undefined && source.builtin;
  }

  public healthLabel(health: BrewSourceHealth): string {
    if (health === BrewSourceHealth.OK) {
      return 'ok';
    }
    if (health === BrewSourceHealth.PARTIAL) {
      return 'partial';
    }
    if (health === BrewSourceHealth.FAILING) {
      return 'failing';
    }
    return 'unknown';
  }
}
```

- [ ] **Step 3: 写视图**

`features/mine/src/main/ets/view/BrewSourceSettingView.ets`：

```ts
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

import { CommonConstants } from '@ohos/common';
import { BrewSourceCacheStats, BrewSourceHealth } from '@ohos/brewcommon';
import {
  BrewSourceClearEvent,
  BrewSourceDeleteEvent,
  BrewSourceEditCancelEvent,
  BrewSourceEditStartEvent,
  BrewSourceInitEvent,
  BrewSourceRefreshEvent,
  BrewSourceSaveEvent,
  BrewSourceSettingVM,
} from '../viewmodel/BrewSourceSettingVM';
import { BrewSourceRow, BrewSourceSettingState } from '../viewmodel/BrewSourceSettingState';

@Component
export struct BrewSourceSettingView {
  viewModel: BrewSourceSettingVM = BrewSourceSettingVM.getInstance();
  @State state: BrewSourceSettingState = this.viewModel.getState();

  aboutToAppear(): void {
    this.viewModel.sendEvent(new BrewSourceInitEvent());
  }

  build() {
    NavDestination() {
      Column() {
        List() {
          ForEach(this.state.rows, (row: BrewSourceRow) => {
            ListItem() {
              this.SourceCard(row)
            }
          }, (row: BrewSourceRow) => row.source.id)

          ListItem() {
            this.AddButton()
          }
        }
        .width(CommonConstants.FULL_PERCENT)
        .height(CommonConstants.FULL_PERCENT)
        .padding($r('sys.float.padding_level8'))
        .backgroundColor($r('sys.color.background_secondary'))
      }
      .width(CommonConstants.FULL_PERCENT)
      .height(CommonConstants.FULL_PERCENT)
    }
    .title($r('app.string.brew_source_title'))
    .padding({ top: $r('sys.float.padding_level4') })
    .backgroundColor($r('sys.color.background_secondary'))
    .onShown(() => {
      this.viewModel.sendEvent(new BrewSourceRefreshEvent());
    })
  }

  @Builder
  SourceCard(row: BrewSourceRow) {
    Column() {
      Row() {
        Text(row.source.name)
          .fontSize($r('sys.float.Title_S'))
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
        if (row.isSessionActive) {
          Text($r('app.string.brew_source_in_use'))
            .fontSize($r('sys.float.Body_S'))
            .fontColor($r('sys.color.font_emphasize'))
            .margin({ right: $r('sys.float.padding_level2') })
        }
        if (row.source.builtin) {
          Text($r('app.string.brew_source_builtin'))
            .fontSize($r('sys.float.Body_S'))
            .fontColor($r('sys.color.font_secondary'))
        }
      }
      .width(CommonConstants.FULL_PERCENT)

      Text(row.source.baseUrl)
        .fontSize($r('sys.float.Body_S'))
        .fontColor($r('sys.color.font_secondary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width(CommonConstants.FULL_PERCENT)
        .margin({ top: $r('sys.float.padding_level1') })

      Text(this.healthText(row))
        .fontSize($r('sys.float.Body_S'))
        .fontColor(this.healthColor(row.health))
        .width(CommonConstants.FULL_PERCENT)
        .margin({ top: $r('sys.float.padding_level1') })

      if (this.state.cachePanelId === row.source.id && this.state.cachePanelStats !== undefined) {
        Text(this.cacheText(row))
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_secondary'))
          .width(CommonConstants.FULL_PERCENT)
          .margin({ top: $r('sys.float.padding_level1') })
      }

      if (this.state.editingId === row.source.id) {
        this.EditForm(row)
      } else {
        this.Actions(row)
      }
    }
    .padding($r('sys.float.padding_level4'))
    .margin({ bottom: $r('sys.float.padding_level2') })
    .borderRadius($r('sys.float.corner_radius_level8'))
    .backgroundColor($r('sys.color.comp_background_primary'))
    .width(CommonConstants.FULL_PERCENT)
  }

  @Builder
  EditForm(row: BrewSourceRow) {
    Column() {
      TextInput({
        text: this.state.editingName,
        placeholder: $r('app.string.brew_source_name_hint')
      })
        .onChange((value: string) => this.viewModel.setEditingName(value))
        .margin({ top: $r('sys.float.padding_level2') })
      TextInput({
        text: this.state.editingUrl,
        placeholder: $r('app.string.brew_source_url_hint')
      })
        .enabled(!row.source.builtin)
        .onChange((value: string) => this.viewModel.setEditingUrl(value))
        .margin({ top: $r('sys.float.padding_level1') })
      if (this.state.errorText.length > 0) {
        Text($r('app.string.brew_source_error_invalid'))
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.warning'))
          .margin({ top: $r('sys.float.padding_level1') })
      }
      Row() {
        Button($r('app.string.brew_source_save'))
          .onClick(() => {
            this.viewModel.sendEvent(new BrewSourceSaveEvent(row.source.id,
              this.state.editingName, this.state.editingUrl));
          })
        Button($r('app.string.brew_source_cancel'))
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          .fontColor($r('sys.color.font_primary'))
          .margin({ left: $r('sys.float.padding_level2') })
          .onClick(() => this.viewModel.sendEvent(new BrewSourceEditCancelEvent()))
      }
      .margin({ top: $r('sys.float.padding_level2') })
    }
    .width(CommonConstants.FULL_PERCENT)
  }

  @Builder
  Actions(row: BrewSourceRow) {
    Row() {
      if (!row.isSessionActive) {
        Button($r('app.string.brew_source_activate'))
          .onClick(() => this.confirmActivate(row))
      }
      Button($r('app.string.brew_source_edit'))
        .backgroundColor($r('sys.color.comp_background_tertiary'))
        .fontColor($r('sys.color.font_primary'))
        .margin({ left: $r('sys.float.padding_level2') })
        .onClick(() => {
          this.viewModel.sendEvent(new BrewSourceEditStartEvent(row.source.id,
            row.source.name, row.source.baseUrl));
        })
      Button($r('app.string.brew_source_cache'))
        .backgroundColor($r('sys.color.comp_background_tertiary'))
        .fontColor($r('sys.color.font_primary'))
        .margin({ left: $r('sys.float.padding_level2') })
        .onClick(() => {
          if (this.state.cachePanelId === row.source.id) {
            this.viewModel.hideCache();
          } else {
            this.viewModel.showCache(row.source.id);
          }
        })
      if (!row.source.builtin && !row.isSessionActive) {
        Button($r('app.string.brew_source_delete'))
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          .fontColor($r('sys.color.warning'))
          .margin({ left: $r('sys.float.padding_level2') })
          .onClick(() => this.confirmDelete(row))
      }
    }
    .margin({ top: $r('sys.float.padding_level2') })
    .width(CommonConstants.FULL_PERCENT)
  }

  @Builder
  AddButton() {
    Button($r('app.string.brew_source_add'))
      .width(CommonConstants.FULL_PERCENT)
      .onClick(() => {
        this.viewModel.sendEvent(new BrewSourceEditStartEvent('', '', ''));
      })
  }

  private confirmActivate(row: BrewSourceRow): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.brew_source_activate'),
      message: $r('app.string.brew_source_activate_confirm'),
      primaryButton: {
        value: $r('app.string.brew_source_cancel'),
        action: () => {
        }
      },
      secondaryButton: {
        value: $r('app.string.brew_source_activate_and_restart'),
        action: () => {
          // 激活链路（探测 → 写 activeId → 重启）在 Task 8 接入
        }
      }
    });
  }

  private confirmDelete(row: BrewSourceRow): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.brew_source_delete'),
      message: $r('app.string.brew_source_delete_confirm'),
      primaryButton: {
        value: $r('app.string.brew_source_cancel'),
        action: () => {
        }
      },
      secondaryButton: {
        value: $r('app.string.brew_source_delete'),
        fontColor: $r('sys.color.warning'),
        action: () => this.viewModel.sendEvent(new BrewSourceDeleteEvent(row.source.id))
      }
    });
  }

  private healthText(row: BrewSourceRow): ResourceStr {
    if (row.health === BrewSourceHealth.OK) {
      return $r('app.string.brew_source_health_ok');
    }
    if (row.health === BrewSourceHealth.PARTIAL) {
      return $r('app.string.brew_source_health_partial');
    }
    if (row.health === BrewSourceHealth.FAILING) {
      return $r('app.string.brew_source_health_failing');
    }
    return $r('app.string.brew_source_health_unknown');
  }

  private healthColor(health: BrewSourceHealth): ResourceColor {
    if (health === BrewSourceHealth.FAILING) {
      return $r('sys.color.warning');
    }
    return $r('sys.color.font_secondary');
  }

  private cacheText(row: BrewSourceRow): ResourceStr {
    const stats: BrewSourceCacheStats | undefined = this.state.cachePanelStats;
    if (stats === undefined) {
      return '';
    }
    return $r('app.string.brew_source_cache_summary', stats.keys, stats.entries, stats.approxBytes);
  }
}

@Builder
export function BrewSourceSettingBuilder() {
  BrewSourceSettingView()
}
```

> 上面的 `$r('app.string.*')` 引用的文案在 **Step 5** 一次性补齐（三份 `string.json`）。
> 所以本步骤写完**先不要编译** —— 编译检查在 Step 6，那时文案已就位。

- [ ] **Step 4: 注册路由与入口**

`features/mine/src/main/resources/base/profile/router_map.json` 追加一条（放在 `MinePackagesView` 之后）：

```json
    {
      "name": "BrewSourceSettingView",
      "pageSourceFile": "src/main/ets/view/BrewSourceSettingView.ets",
      "buildFunction": "BrewSourceSettingBuilder"
    }
```

`features/mine/src/main/ets/view/MineSettingView.ets`：在现有 `ListItemGroup` 的「关于」项**之前**插入：

```ts
            ListItem() {
              HmosListItem({
                title: $r('app.string.brew_source_title'),
                handleClickAction: () => {
                  this.pathStack.pushPath({ name: 'BrewSourceSettingView' });
                }
              })
            }
            .padding({
              left: $r('sys.float.padding_level2'),
              right: $r('sys.float.padding_level2'),
            })
```

- [ ] **Step 5: 补三份文案**

`features/mine/src/main/resources/base/element/string.json` 追加（`zh_CN` / `en_US` 同结构、同 name）：

| name | base (en) | zh_CN |
|---|---|---|
| `brew_source_title` | Data sources | 数据源 |
| `brew_source_in_use` | In use | 使用中 |
| `brew_source_builtin` | Built-in | 内置 |
| `brew_source_activate` | Activate | 激活 |
| `brew_source_activate_confirm` | Switching restarts the app. The current source's cache is kept. | 切换会重启应用；当前源的缓存不会被删除。 |
| `brew_source_activate_and_restart` | Switch and restart | 切换并重启 |
| `brew_source_edit` | Edit | 编辑 |
| `brew_source_cache` | Cache | 缓存 |
| `brew_source_delete` | Delete | 删除 |
| `brew_source_delete_confirm` | Deleting removes this source's cache. | 删除会一并移除该源的缓存。 |
| `brew_source_add` | Add data source | 新增数据源 |
| `brew_source_name_hint` | Name | 名称 |
| `brew_source_url_hint` | https://host/api | https://host/api |
| `brew_source_save` | Save | 保存 |
| `brew_source_cancel` | Cancel | 取消 |
| `brew_source_error_invalid` | Invalid input, check name and URL | 输入不合法，请检查名称与地址 |
| `brew_source_health_ok` | Available | 正常 |
| `brew_source_health_partial` | Partially available | 部分可用 |
| `brew_source_health_failing` | Last attempt failed | 上次失败 |
| `brew_source_health_unknown` | Not verified | 未验证 |
| `brew_source_cache_summary` | Cache: %d keys / %d entries / ~%d bytes | 缓存：%d 个键 / %d 条 / 约 %d 字节 |

把 `BrewSourceSettingView` 里对 `$r('app.string.brew_source_health_*')` 与
`$r('app.string.brew_source_cache_summary', …)` 的引用与上表逐条对账（name 必须完全一致）。
若报 `Unknown resource name`，说明 name 拼错或漏了某一份 `string.json`。

- [ ] **Step 6: 编译并查两项**

```bash
devecocli build
```
Expected: `BUILD SUCCESSFUL`，0 error。

```bash
ABC=products/pc/build/default/intermediates/loader_out/default/ets/modules.abc
grep -c BrewSourceSettingView "$ABC"       # 期望 > 0（不加 ^$ 锚点）
python3 -c "import json;print([r['name'] for r in json.load(open(\
  'products/pc/build/default/intermediates/router_map/default/router_map.json'))['routerMap']])"
```
Expected: 路由列表含 `BrewSourceSettingView`。

- [ ] **Step 7: 真机点击验证（Review Focus #5）**

```bash
devecocli run
devecocli ui click --text "设置"     # 进设置
devecocli ui layout | grep -E "数据源|关于"
devecocli ui click --text "数据源"
devecocli ui layout | grep -E "官方源|内置|新增数据源"
```

Expected：设置页出现「数据源」项；进入后官方源在第 0 项、带「内置」标注、有「新增数据源」按钮。

逐项验证：

| 操作 | 期望 |
|---|---|
| 点「新增数据源」→ 名称留空 → 保存 | 出现「输入不合法」，**不新增** |
| 名称填 `测试`，地址填 `ftp://x/api` → 保存 | 出现「输入不合法」，**不新增** |
| 名称填 `测试`，地址填 `https://host/homebrew/api/` → 保存 | 新增成功，列表显示的地址是**去掉尾斜杠**的 `https://host/homebrew/api` |
| 名称填 41 个字符 → 保存 | 被拒（`BREW_SOURCE_MAX_NAME_LEN`） |
| 名称填 emoji `🍺源` → 保存 | 正常保存且列表渲染不崩 |
| 点该源「缓存」 | 出现缓存摘要行（新源应为 `0 个键 / 0 条`） |
| 点「删除」→ 确认 | 该源消失；官方源与激活源没有删除按钮 |

- [ ] **Step 8: 提交**

```bash
git add features/mine/src/main/ets/viewmodel/BrewSourceSettingState.ets \
  features/mine/src/main/ets/viewmodel/BrewSourceSettingVM.ets \
  features/mine/src/main/ets/view/BrewSourceSettingView.ets \
  features/mine/src/main/ets/view/MineSettingView.ets \
  features/mine/src/main/resources/base/profile/router_map.json \
  features/mine/src/main/resources/base/element/string.json \
  features/mine/src/main/resources/zh_CN/element/string.json \
  features/mine/src/main/resources/en_US/element/string.json
git commit -m "feat(brew): 数据源设置页（增删改 + 缓存查看/清空）

- Mine > 设置 > 数据源；官方源恒在第 0 项、标注内置、不可删
- 新增/编辑只做格式校验（不探测）；改 URL 会清该源缓存
- 缓存摘要走 BrewCacheAdmin.stats；删除走 drop（连带删文件）
- 激活按钮的确认弹窗已就位，探测+重启链路在下一任务接入"
```

---

### Task 8: 激活链路（探测 → 确认 → 写 activeId → 重启）

**Files:**
- Create: `features/brewcommon/src/main/ets/service/BrewSourceRestart.ets`
- Modify: `features/mine/src/main/ets/viewmodel/BrewSourceSettingVM.ets`
- Modify: `features/mine/src/main/ets/view/BrewSourceSettingView.ets`
- Modify: `features/mine/src/main/resources/{base,zh_CN,en_US}/element/string.json`
- Modify: `features/brewcommon/Index.ets`

**Interfaces:**
- Consumes: `BrewSourceProbe.check()`（Task 5）、`BrewSourceStore.setActiveId/noteProbe/noteError`（Task 1）
- Produces:
  - `BrewSourceRestart.restart(context: common.UIAbilityContext): Promise<boolean>`
  - `BrewSourceSettingVM` 新增 `activate(id: string): void` 与 `probeState`

- [ ] **Step 1: 写重启三级兜底链**

`features/brewcommon/src/main/ets/service/BrewSourceRestart.ets`：

```ts
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

import { common, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger, ProcessUtil } from '@ohos/common';

const TAG: string = '[BrewSource]';

/**
 * 应用重启（切换数据源后的生效手段）。
 *
 * ## 三级兜底，顺序有理由
 *
 * 1. **`UIAbilityContext.restartApp(want)`**（API 22+，**保留窗口**）：用户视野停留在应用内，
 *    没有桌面闪现。已核对的约束：**仅主线程**、**应用需获焦**、**3 秒内不可重复调用**。
 * 2. **`ApplicationContext.restartApp(want)`**（API 12+，不保留窗口）：会露一下桌面，
 *    但约束更少（同样是主线程 + 获焦 + 3 秒）。
 * 3. **`ProcessUtil.exitApp()`**：最差情况退到「直接退进程」，由用户手动重开。
 *    到这一步说明前两级都不可用，继续等下去只会让用户以为按钮坏了。
 *
 * ## 为什么不使用 `appRecovery.restartApp()`
 *
 * 它有「两次重启的间隔应大于一分钟」的约束 —— 一分钟内重复调用**只退出、不重启**。
 * 用户连续切换两次源就会踩到，表现为「App 自己关了」。
 */
export class BrewSourceRestart {
  private static readonly BUNDLE_NAME: string = 'com.huawei.hmos.sample';
  private static readonly ABILITY_NAME: string = 'PcAbility';

  public static async restart(context: common.UIAbilityContext): Promise<boolean> {
    const want: Want = { bundleName: BrewSourceRestart.BUNDLE_NAME, abilityName: BrewSourceRestart.ABILITY_NAME };
    // 1) 保留窗口的重启
    try {
      await context.restartApp(want);
      Logger.info(TAG, 'activate restart via UIAbilityContext.restartApp, ok=true');
      return true;
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.error(TAG, `activate restart fallback=ApplicationContext, errCode=${e?.code}, errMsg=${e?.message}`);
    }
    // 2) 不保留窗口的重启
    try {
      const appContext: common.ApplicationContext = context.getApplicationContext();
      appContext.restartApp(want);
      Logger.info(TAG, 'activate restart via ApplicationContext.restartApp, ok=true');
      return true;
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.error(TAG, `activate restart fallback=exitApp, errCode=${e?.code}, errMsg=${e?.message}`);
    }
    // 3) 退进程，由用户手动重开
    ProcessUtil.exitApp();
    Logger.info(TAG, 'activate restart via ProcessUtil.exitApp, ok=true');
    return false;
  }
}
```

`Index.ets` 追加 `export { BrewSourceRestart } from './src/main/ets/service/BrewSourceRestart';`

- [ ] **Step 2: VM 加激活方法**

`BrewSourceSettingState` 追加一个字段（`probingId` 已在 Task 7 落地，**不要重复声明**）：

```ts
  /** 激活流程：探测失败的原因码，空串表示无 */
  public probeReason: string = '';
```

`BrewSourceSettingVM` 只**追加两个方法**（`contextProvider` 字段已在 Task 7 的类体顶部声明好，**不要重复声明**）：

```ts
  public activate(id: string): void {
    const source: BrewSource | undefined = BrewSourceStore.find(id);
    if (source === undefined) {
      return;
    }
    this.state.probingId = id;
    this.state.probeReason = '';
    BrewSourceProbe.check(source.baseUrl).then((result: BrewProbeResult) => {
      this.state.probingId = '';
      BrewSourceStore.noteProbe(id, result.ok, result.reason);
      if (!result.ok) {
        // 硬阻断：不写 activeId，不改任何状态
        this.state.probeReason = result.reason;
        this.refresh();
        return;
      }
      const written: boolean = BrewSourceStore.setActiveId(id);
      if (!written) {
        this.state.probeReason = 'write-failed';
        this.refresh();
        return;
      }
      const context = this.contextProvider !== undefined ? this.contextProvider() : undefined;
      if (context === undefined) {
        this.state.probeReason = 'no-context';
        this.refresh();
        return;
      }
      BrewSourceRestart.restart(context);
    }).catch((err: Error) => {
      this.state.probingId = '';
      this.state.probeReason = 'network-unknown';
      BrewSourceStore.noteError(id, 'probe', err.message);
      this.refresh();
    });
  }

  public probeReasonText(): ResourceStr {
    const reason: string = this.state.probeReason;
    if (reason === 'invalid-url') return $r('app.string.brew_source_probe_invalid_url');
    if (reason === 'dns') return $r('app.string.brew_source_probe_dns');
    if (reason === 'timeout') return $r('app.string.brew_source_probe_timeout');
    if (reason === 'tls') return $r('app.string.brew_source_probe_tls');
    if (reason === 'http-404') return $r('app.string.brew_source_probe_404');
    if (reason === 'http-4xx' || reason === 'http-5xx') return $r('app.string.brew_source_probe_http');
    if (reason === 'not-json' || reason === 'html-body') return $r('app.string.brew_source_probe_not_api');
    if (reason === 'shape-mismatch') return $r('app.string.brew_source_probe_not_api');
    if (reason.length === 0) return '';
    return $r('app.string.brew_source_probe_unknown');
  }
```

新增 import：`import { common } from '@kit.AbilityKit';`、
`import { BrewProbeResult, BrewSourceProbe, BrewSourceRestart } from '@ohos/brewcommon';`

- [ ] **Step 3: View 接上激活与失败弹窗**

`BrewSourceSettingView.aboutToAppear()` 注入 context：

```ts
  aboutToAppear(): void {
    this.viewModel.contextProvider = () => {
      return this.getUIContext().getHostContext() as common.UIAbilityContext;
    };
    this.viewModel.sendEvent(new BrewSourceInitEvent());
  }
```

`confirmActivate` 的 `secondaryButton.action` 改为：

```ts
        action: () => {
          this.viewModel.activate(row.source.id);
        }
```

并在 `SourceCard` 的状态行下面追加探测态与失败提示：

```ts
      if (this.state.probingId === row.source.id) {
        Row() {
          LoadingProgress().width(16).height(16)
          Text($r('app.string.brew_source_probing'))
            .fontSize($r('sys.float.Body_S'))
            .fontColor($r('sys.color.font_secondary'))
            .margin({ left: $r('sys.float.padding_level1') })
        }
        .margin({ top: $r('sys.float.padding_level1') })
      }
      if (this.state.probeReason.length > 0 && !row.isSessionActive && this.state.probingId.length === 0) {
        Text(this.viewModel.probeReasonText())
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.warning'))
          .width(CommonConstants.FULL_PERCENT)
          .margin({ top: $r('sys.float.padding_level1') })
      }
```

`probeReasonText()` 的返回类型是 `ResourceStr`，`Text()` 接受它。

- [ ] **Step 4: 补探测相关文案**

三份 `string.json` 追加：

| name | base (en) | zh_CN |
|---|---|---|
| `brew_source_probing` | Checking… | 正在检查… |
| `brew_source_probe_invalid_url` | Invalid address | 地址不合法 |
| `brew_source_probe_dns` | Cannot resolve the host | 域名无法解析 |
| `brew_source_probe_timeout` | Connection timed out | 连接超时 |
| `brew_source_probe_tls` | Certificate check failed | 证书校验失败 |
| `brew_source_probe_404` | No /api data at this address | 该地址没有 /api 数据 |
| `brew_source_probe_http` | Server rejected the request | 服务端拒绝了请求 |
| `brew_source_probe_not_api` | Not a Homebrew API (returned a web page or non-JSON) | 不是 Homebrew API（返回网页或非 JSON） |
| `brew_source_probe_unknown` | Network error | 网络错误 |

- [ ] **Step 5: 编译**

```bash
devecocli build
```
Expected: `BUILD SUCCESSFUL`，0 error。`grep -c BrewSourceRestart modules.abc` > 0。

- [ ] **Step 6: 真机走通激活链路（Review Focus #6 + G2/G6）**

```bash
devecocli run
```

| # | 操作 | 期望 |
|---|---|---|
| V4 | 新增一个**不可达**的源（如 `https://nonexistent-host-for-verify.invalid/api`）→ 点激活 → 确认 | 出现「正在检查…」→ 出现失败原因；`activeId` **未改变**（日志里没有 `activeId written`） |
| V5 | 新增一个**可用**源（填官方地址的另一个写法，如 `https://formulae.brew.sh/api/`）→ 点激活 → 确认 | 日志出现 `activeId written, id=src_…` 与 `activate restart via UIAbilityContext.restartApp, ok=true`；App 重启 |
| V5b | 重启后看日志 | `session active frozen, id=src_…`；所有 `[BrewHttp]` URL 走新源；`[load] kind=… reason=missing`（新源无缓存） |
| V11 | 连续两次点激活（第二次在 3 秒内） | 第二次走兜底链（日志出现 `fallback=ApplicationContext` 或 `fallback=exitApp`），**不能**静默无反应 |

日志抓取：

```bash
devecocli log --from 120s | grep -E "activeId written|activate restart|session active frozen|verify probe"
```

- [ ] **Step 7: 提交**

```bash
git add features/brewcommon/Index.ets \
  features/brewcommon/src/main/ets/service/BrewSourceRestart.ets \
  features/mine/src/main/ets/viewmodel/BrewSourceSettingState.ets \
  features/mine/src/main/ets/viewmodel/BrewSourceSettingVM.ets \
  features/mine/src/main/ets/view/BrewSourceSettingView.ets \
  features/mine/src/main/resources/base/element/string.json \
  features/mine/src/main/resources/zh_CN/element/string.json \
  features/mine/src/main/resources/en_US/element/string.json
git commit -m "feat(brew): 激活链路（探测 → 确认 → 写 activeId → 重启）

- 探测失败硬阻断，不写 activeId、不改任何状态
- 重启三级兜底：UIAbilityContext.restartApp（保留窗口）→ ApplicationContext → exitApp
- 不用 appRecovery.restartApp（两次重启间隔须 >1 分钟）"
```

---

### Task 9: 文档更新与收尾

**Files:**
- Modify: `docs/brew-handover.md`（§3 代码地图、§8.2 待办）
- Modify: `docs/brew-api-design.md`（§7.5 开关一节、§7 新增「多源」小节）
- Modify: `features/brewcommon/src/main/ets/service/BrewSourceDiagnostics.ets`（确认自检开关已关）

**Interfaces:**
- Consumes: 全部前序任务的产出
- Produces: 文档与最终提交

- [ ] **Step 1: 确认自检开关是关的、用户数据没被搬走**

```bash
# 自检必须关掉，不能把诊断日志带到发布版本
grep -n "BREW_SOURCE_VERIFY" features/brewcommon/src/main/ets/constant/BrewSourceConstants.ets
# 搜索历史是用户资产，不是源缓存 —— 必须仍在主 store（PreferenceManager）
grep -rn "BREW_SEARCH_HISTORY_KEY" features/brewsearch/src/main/ets/ | head
```
Expected: 第一项为 `export const BREW_SOURCE_VERIFY: boolean = false;`；
第二项显示 `BrewSearchModel` 仍通过 `PreferenceManager` 读写 `brew_search_history`
（**若它被误改成 `BrewSourcePrefs`，就是 spec §5.3 明令禁止的「把用户数据当源缓存」**，必须改回）。

- [ ] **Step 2: 更新 `docs/brew-api-design.md`**

在 §7.5「开关」之后新增一节：

```markdown
### 7.5.1 多数据源（2026-09-23）

`BREW_API_BASE` 常量已删除，base URL 改为运行期从**会话冻结的 active 源**解析
（`BrewSourceStore.activeBaseUrl()`）。用户可在 Mine > 设置 > 数据源 里维护多个镜像地址。

| 概念 | 实现 | 说明 |
|---|---|---|
| 源注册表 | 主 store 的 `brew_sources` | 官方源恒在第 0 项、不可删、baseUrl 固定 |
| 每源缓存 | 独立 store `brew_src_<id>`（GSKV） | 六条缓存键名不变，隔离由 store 承担 |
| 会话冻结 | `BrewSourceStore.sessionActive()` | 写 activeId 对当前进程零影响 → **切换必须重启** |
| 激活 | `BrewSourceProbe` 单端点探测 → 确认 → 写 activeId → `restartApp` | 探测失败硬阻断 |
| 维护 | `BrewCacheAdmin` stats/clear/drop | clear 会重置内存态；世代号守卫防在途回填 |
| 健康 | `brew_source_health` | 「部分可用」= 单条文档 OK 但目录/全量包持续失败 |

**为什么每源一个 store**：Preferences 是「一个文件一个实例、整份加载、整份落盘」，
共享 store 时加载/flush/删除的成本随源数量线性增长（3 个源时每次 flush 重写 8MB+）。

设计全文见 `docs/superpowers/specs/2026-09-23-brew-multi-source-design.md`。
```

把 §7.5 里 `BREW_DATA_SOURCE` 的字样改为 `BREW_DATA_MODE`。

- [ ] **Step 3: 更新 `docs/brew-handover.md`**

§3 代码地图追加 `brewcommon` 的新文件；§8.2 待办表追加两行：

```markdown
| **数据源请求的错误处理（后期）** | spec §10.2 登记了 7 项：`fetchCatalog` 的 `Promise.all` 无逐端点隔离、`buildCatalog` / `conditionalFetch` 的 `JSON.parse` 无 try/catch、`BrewHttp.getJson` 不区分 304/404/其他非 200、无重试退避、无每源熔断。触发条件：用户反馈某个镜像「时好时坏」或需要长期使用非官方源 |
| **`brew_live_data` 的大 blob 拆细** | GSKV 是实时落盘，但当前仍把全部 doc 当一个键整写（~1.2MB/批）。改成每 token 一键才能真正吃到 GSKV 的增量写优势。触发条件：hydrate 的落盘耗时进入首屏预算 |
```

- [ ] **Step 4: 全量编译 + 路由 + 符号三项终检**

```bash
devecocli build
ABC=products/pc/build/default/intermediates/loader_out/default/ets/modules.abc
for s in BrewSourceStore BrewSourcePrefs BrewSourceProbe BrewCacheAdmin BrewSourceRestart BrewSourceSettingView; do
  echo "$s: $(grep -c $s "$ABC")"
done
python3 -c "import json;print([r['name'] for r in json.load(open(\
  'products/pc/build/default/intermediates/router_map/default/router_map.json'))['routerMap']])"
```
Expected: `BUILD SUCCESSFUL`；6 个符号计数都 > 0；路由含 `BrewSourceSettingView`。

- [ ] **Step 5: 提交**

```bash
git add docs/brew-handover.md docs/brew-api-design.md
git commit -m "docs(brew): 多数据源与按源缓存维护的现状与后期项

- api-design §7.5.1 记录源注册表/每源 store/会话冻结/激活/维护
- handover 待办补两项：数据源请求的错误处理（spec §10.2 的 7 项）、大 blob 拆细"
```

---

## 完成判据

全部任务完成后，以下 7 条必须同时成立（对应 spec §1 的 G1-G7）：

| # | 判据 | 验证 |
|---|---|---|
| G1 | 可增删改源，官方源不可删 | Task 7 V7 表 |
| G2 | 切换必须重启，重启后所有请求走新 base | Task 8 V5/V5b |
| G3 | 每源缓存隔离 | Task 2 Step 6（首次 missing / 二次 pref）+ Task 8 V5b |
| G4 | 删源移除其缓存 | Task 6 Step 8（`store deleted` + `keysAfterDrop=0`） |
| G5 | 单源可查看/清空，且不被在途写入回填 | Task 6 Step 8 + 世代号守卫验证 |
| G6 | 探测失败硬阻断并给出具体原因 | Task 5 Step 4 + Task 8 V4 |
| G7 | 编译通过 | Task 9 Step 4 |
