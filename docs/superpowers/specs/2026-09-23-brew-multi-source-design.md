# Homebrew 多数据源与按源缓存维护 · 设计

> 状态：待评审。评审通过后由 `writing-plans` 产出实施计划。
> 相关文档：[`brew-api-design.md`](../../brew-api-design.md) §7（现网数据源）、[`brew-handover.md`](../../brew-handover.md)（代码地图 / 踩坑索引）。

---

## 1. 背景与目标

现状：全 App 只有一个硬编码的 API 基地址

```ts
// features/brewcommon/src/main/ets/constant/BrewConstants.ets:89
export const BREW_API_BASE: string = 'https://formulae.brew.sh/api';
```

所有远端 URL 都由它派生：单条 `/formula|/cask/<token>.json`、全量 `/formula.json|/cask.json`、
聚合 `/analytics/...`。而所有本地缓存都堆在**同一个** Preferences store（`HMosWorldStoreWithNet`）
里、**不区分来源**：`brew_live_data` / `brew_live_dataset` / `brew_catalog` / `brew_meta_index` /
`brew_meta_stamp` / `brew_detail_page_data`。

目标：**用户可以配置多个 Homebrew 数据源（API base URL 的镜像），每种源拥有独立、可单独维护的本地缓存。**

### 成功判据

| # | 判据 | 可观测证据 |
|---|---|---|
| G1 | 用户可新增 / 编辑 / 删除数据源，官方源不可删 | 设置页列表；重启后注册表仍在 |
| G2 | 切换数据源必须重启才生效；重启后**所有**远端请求走新 base URL | `[BrewHttp]` 日志里的完整 URL |
| G3 | 每个源的缓存物理隔离，互不串用 | 切换源后页面数据来自新源；旧源数据不出现 |
| G4 | 删除一个源会移除它的缓存 | 重启后该源的 store 不再存在，页面为空态而非旧数据 |
| G5 | 单个源的缓存可单独查看与清空，且清空后不会被在途写入回填 | 维护页条目数归零；日志判据 |
| G6 | 激活前探测失败则拒绝激活，并给出具体原因 | 弹窗文案 + `[BrewSourceProbe]` 日志 |
| G7 | 编译通过 | `devecocli build` `BUILD SUCCESSFUL`，0 error |

---

## 2. 已确认的决策

| 决策点 | 选择 | 说明 |
|---|---|---|
| 「数据源」的语义 | App 拉取数据的 **API base URL**（镜像 `formulae.brew.sh/api` 的整棵树） | 不涉及安装命令里的镜像环境变量 |
| 源列表来源 | **不预置镜像**；内置官方源，不可删、可回退 | 初始只有官方源 |
| 隔离方案 | **B1**：每源一个独立 Preferences store，封装写在 `brewcommon` 内，**不改 `common`** | 隔离由平台原语保证，而非键名纪律 |
| 存储模式 | **GSKV**，默认可用，**不做 `isStorageTypeSupported` 探测、不设计 XML 回退** | 见 §13 风险 |
| 切换生效 | 探测 → 确认弹窗 → 写 `activeId` → **重启**；**无中间态** | 会话内冻结 active 源 |
| 重启方式 | `UIAbilityContext.restartApp(want)`（API 22+，保留窗口）→ 兜底 `ApplicationContext.restartApp(want)` → 再兜底 `ProcessUtil.exitApp()` | 不采用 `appRecovery.restartApp()`（两次重启间隔须 >1 分钟） |
| 激活前探测 | **单端点**探测；失败**硬阻断**（无「强制激活」） | 探测端点 `/formula/wget.json` |
| 部分可用 | 不做预探测，靠**运行期记录**标注 | 见 §9.4 |
| 删除「当前激活源」 | **拒绝**，提示先切换到其他源 | 切走本身就是重启，重启后再删 |
| 缓存维护 | 单源**查看 + 清空**；删源连带清空；不动用户数据 | 搜索历史 / 账号不算源缓存 |
| 错误处理 | 本轮只做**激活前探测**；冷启请求失败逻辑**不改**，登记为后期 | 见 §10 |

### 明确不做（YAGNI）

- 热切换、运行时切换 base URL。
- 预置国内镜像列表。
- 多源同时启用 / 按 kind 分别指定源。
- 源级请求重试、退避、熔断（见 §10 后期表）。
- 把 `brew_live_data` 的大 blob 拆成每 token 一键（GSKV 下这才是真正的写优化，列为后续独立项）。

---

## 3. 命名与术语

现状里 `BrewDataSource` / `BREW_DATA_SOURCE`（`REMOTE` / `SNAPSHOT`）表达的是**数据模式**，
不是「数据源」。为避免同一份代码里两个「数据源」，本轮改名：

| 旧 | 新 |
|---|---|
| `BrewDataSource` | `BrewDataMode` |
| `BREW_DATA_SOURCE` | `BREW_DATA_MODE` |

引用面：3 个文件 / 14 处（`BrewConstants.ets`、`BrewRepository.ets` 3 处、`BrewService.ets` 9 处），
另有两处注释文字（`BrewApiMapper.ets`）。

新概念统一用 **源（source）**：`BrewSource`、`BrewSourceStore`、`BrewSourcePrefs`、`BrewSourceProbe`。

---

## 4. 数据模型与注册表

```ts
// features/brewcommon/src/main/ets/model/BrewSourceModels.ets
export class BrewSource {
  id: string;        // 稳定标识：'official'，或 'src_<ts>_<rand>'；生成后不变
  name: string;      // 展示名，用户可改
  baseUrl: string;   // 归一化后的 base URL（trim + 去尾斜杠）
  builtin: boolean;  // 官方源为 true：不可删、不可改 baseUrl
  createdAt: number;
}

export class BrewSourceRegistry {
  sources: BrewSource[];   // 恒含 official，且恒为第 0 项
  activeId: string;
}

export enum BrewSourceHealth {
  UNKNOWN = 'unknown',   // 未验证
  OK = 'ok',
  PARTIAL = 'partial',   // 单条文档可用，但目录 / 全量包持续失败
  FAILING = 'failing',
}
```

**存储位置**：注册表存**现有主 store**（`PreferenceManager`，键 `brew_sources`）—— 只有几百字节，
不值得为它再开一个 store。健康记录同 store，键 `brew_source_health`。

**不变量**（`BrewSourceStore` 负责维持，越界时回落并打日志）：

1. `sources` 中恒存在且仅存在一条 `id === 'official'`，`builtin === true`，`baseUrl` 恒为官方地址。
2. `official` 恒为 `sources[0]`。
3. `activeId` 必须命中 `sources` 中的某条；不命中（数据损坏 / 源被外部清掉）则回落 `official` 并落盘。
4. 同时只有一条 active。
5. `baseUrl` 在写入前必须通过 §8.1 的归一化与格式校验。

**`id` 与 `baseUrl` 解耦**：改 URL 等于换了一份数据，保存后清空该源 cache（若改的是激活源，同时重置内存态）。
改 `name` 不清。`id` 生成后永不变更，因此**改 URL 不会继承旧 cache**。

---

## 5. 存储层：`BrewSourcePrefs`（B1 + GSKV）

新增 `features/brewcommon/src/main/ets/service/BrewSourcePrefs.ets`，**自建，不动 `common`**。

### 5.1 store 与模式

- store 名：`brew_src_<sourceId>`（如 `brew_src_official`）。
- 存储模式：**固定 `preferences.StorageType.GSKV`**。
- Context 获取沿用 `PreferenceManager` 的做法：
  `AppStorage.get<UIContext>(StorageKey.UI_CONTEXT)?.getHostContext()`；拿不到时按同样方式重试，
  连续失败则记 error 并让调用方拿到空值（**不抛给 UI**，与现有缓存层语义一致）。
- store 创建失败（`getPreferencesSync` 抛错）：记 error，返回 `null`，所有读写退化为「无缓存」。
  页面因此走空态 / 降级路径 —— 这是**可观测的**（日志 + 维护页显示不可用），但不设计 XML 回退。

### 5.2 句柄策略

- **只缓存当前会话激活源的 store 句柄**（一个）。
- 维护页访问非激活源时**临时打开**，用完立即 `preferences.removePreferencesFromCacheSync(ctx, name)` 释放。
  这是 B 能把常驻内存压到「同时只有一个源」的关键。
- `clear` / `drop` 走**串行队列**：官方文档明确「不允许 `deletePreferences` 与其他接口多线程、多进程并发调用」。

### 5.3 API

```ts
class BrewSourcePrefs {
  static get<T>(key: string): T | null;                    // 激活源
  static set<T>(key: string, value: T): void;              // 激活源（GSKV：只写内存缓存页，需持久化时见 persistNow）
  static keys(sourceId: string): string[];                 // 临时句柄
  static stats(sourceId: string): BrewSourceCacheStats;    // 临时句柄
  static clear(sourceId: string): Promise<void>;           // 串行
  static drop(sourceId: string): Promise<void>;            // 串行；removePreferencesFromCacheSync → deletePreferences
  static storageMode(): string;                            // 恒为 'gskv'，仅用于日志
  // 与 PreferenceCacheHelper 同形的「组键 + 子键」读写（详情页缓存在用）
  static getSubValue<T>(groupKey: string, subKey: string): Promise<T>;
  static setSubValue<T>(groupKey: string, subKey: string, data: T): Promise<void>;
}
```

**键名不变**：`brew_live_data` / `brew_live_dataset` / `brew_catalog` / `brew_meta_index` /
`brew_meta_stamp` / `brew_detail_page_data` 六条常量（含 `BrewService.DETAIL_PAGE_DATA`）保持原名，
隔离由 store 承担。调用点从 `PreferenceManager.getInstance().getValue(K)` 换成 `BrewSourcePrefs.get(K)`。

**详情页缓存的特殊之处**：它走的是 `PreferenceCacheHelper.getSubValue/setSubValue`
（"组键 + 子键"，读改写整组），而不是单键读写。因此 `BrewSourcePrefs` 必须提供同形的两个方法，
让 `BrewService.getFormulaDetailByPreference` / `setFormulaDetailToPreference` 与 cask 两个对应方法
（当前 `BrewService.ets:1482-1500`）做 **1:1 替换**，并保持 reject 时的错误形状一致
（`'There is no data in the Preference.'`）—— 上层 `cachedFormulaDetail` / `cachedCaskDetail`
靠 reject 走回落分支，契约不能变。

**不搬走的**：`brew_search_history`（`brewsearch` 的用户数据）留在主 store —— 它是用户资产，不是源缓存，
不参与「查看 / 清空 / 删源连带」，也不受源切换影响。

**由此获得的关键性质**：漏改调用点会**编译不过**（不像「键前缀」方案那样静默串源）。

### 5.4 ArkTS 约束

`preferences.getAllSync()` 返回 `Object`，而 ArkTS 下 `Object.keys` 不能直接作用于 `Object`
（官方示例明确要求把该调用抽到独立的 `.ts` 文件再 import）。`BrewSourcePrefs` 需要键枚举，
因此新增一个 `features/brewcommon/src/main/ets/util/objkeys.ts`（纯 `Object.keys` 包装）。

---

## 6. 会话快照与 URL 解析

### 6.1 会话冻结（「必须重启」的实现落点）

- `BrewSourceStore.sessionActive(): BrewSource` —— 进程内**只读一次并冻结**。
- `BrewSourceStore.activeBaseUrl(): string` = `sessionActive().baseUrl`。

于是写入新的 `activeId` 对当前进程**零影响** → 重启是硬需求，且**不存在**「已切换但仍在跑旧源」的中间态。

### 6.2 必须修掉的导入期求值

`BrewCatalogAlgo.BREW_CATALOG_SOURCES` 是**模块导入期**就拼好 URL 的常量数组，而 base URL 现在要
运行时解析（且导入期 `UIContext` 未必就绪）。因此改为函数：

```ts
// BrewCatalogAlgo.ets：BREW_CATALOG_SOURCES 常量 → catalogSources() 函数
export function catalogSources(): CatalogSource[] { /* 每次调用时用 activeBaseUrl() 拼 URL */ }
```

`BREW_API_BASE` 常量删除，改为 `BrewSourceStore.activeBaseUrl()`。

### 6.3 改动点（当前行号，实施时以搜索为准）

| 文件 | 位置 | 改法 |
|---|---|---|
| `constant/BrewConstants.ets` | 89 | 删 `BREW_API_BASE` |
| `service/BrewService.ets` | 330 / 336 / 488 | 单条 doc、探针 URL 用 `activeBaseUrl()` |
| `service/BrewService.ets` | 882 | `BREW_CATALOG_SOURCES.slice()` → `catalogSources()` |
| `service/BrewMetaSync.ets` | 525 / 608 | 全量包、单条 desc 校验用 `activeBaseUrl()` |
| `service/BrewCatalogAlgo.ets` | 49 | 常量数组 → 函数 |

---

## 7. 激活流程

```
源列表点某条
  → 已是激活源？是则无操作
  → ① 探测（BrewSourceProbe.check）
       失败 → 硬阻断：展示原因 + 「重试 / 取消」
       成功 → ② 确认弹窗
  → ③ 用户点「切换并重启」→ 不可逆序列
```

### 7.1 探测

`features/brewcommon/src/main/ets/service/BrewSourceProbe.ets`

- 请求：`GET ${baseUrl}/formula/wget.json`，超时 **8s**（单条文档 ~5KB；`wget` 是长期存在且稳定的 token）。
- 校验链：HTTP 200 → `JSON.parse` 成功 → 形状检查（含 `name` 或 `versions.stable`）。
- 返回结构化结果：

```ts
export class BrewProbeResult {
  ok: boolean;
  reason: string;     // 见下表
  httpCode: number;   // 0 表示未拿到响应
  tookMs: number;
  detail: string;     // 给日志与弹窗的补充信息（截断）
}
```

| reason | 触发条件 | 弹窗文案要点 |
|---|---|---|
| `invalid-url` | 格式校验未通过（非 http(s) / 无 host / 带 query 或 fragment） | 地址不合法 |
| `dns` | 域名解析失败 | 域名无法解析 |
| `timeout` | 连接或读取超时 | 连接超时 |
| `tls` | 证书 / TLS 失败 | 证书校验失败 |
| `http-404` | 404 / 410 | 该地址没有 `/api` 数据 |
| `http-4xx` | 其他 4xx | 服务拒绝（附状态码） |
| `http-5xx` | 5xx | 服务端错误（附状态码） |
| `not-json` | 200 但 `JSON.parse` 失败 | 返回的不是 JSON |
| `html-body` | 200 且 body 以 `<` 开头（镜像常见的 HTML 错误页） | 返回的是网页而非数据 |
| `shape-mismatch` | 200 + JSON 但缺少 `name` / `versions.stable` | 地址不是 Homebrew API |
| `network-unknown` | 其他网络异常 | 网络错误（附 code/msg） |

**失败 = 硬阻断**：只给「重试 / 取消」，不提供强制激活 —— 避免把 App 切到已确认不可用的源上。

### 7.2 确认弹窗

> 将切换到「<name>」（<baseUrl>）。切换会**重启应用**；当前源的缓存不会被删除。

按钮：「切换并重启」/「取消」。取消则**不改任何状态**。

### 7.3 不可逆序列（顺序固定）

1. 写注册表 `activeId` 并**先落盘**（主 store，`PreferenceManager` 同步写）。
2. `UIAbilityContext.restartApp(want)`，`want = { bundleName: 'com.huawei.hmos.sample', abilityName: 'PcAbility' }`。
   - 已核对的约束：**仅主线程**、**应用需获焦**、**3 秒内不可重复调用**；**保留窗口**（无桌面闪现）。
   - 重启过程**不触发** `onDestroy`。
3. 兜底链：`UIAbilityContext.restartApp` 抛错 → `ApplicationContext.restartApp(want)`（API 12+，不保留窗口）
   → 再失败 → `ProcessUtil.exitApp()` + 提示用户手动重开。每一级都打日志。
4. **不清任何内存缓存、不删任何 cache**：进程即将重启，重启后 store 名不同，天然不串。

### 7.4 新增 / 编辑源

- 保存时**只做格式校验**（§8.1），**不探测** —— 新增不改 App 行为，不该为「加个源看看」付 8 秒。
- 列表项提供独立的**「测试连接」**按钮（手动触发探测并展示结果），状态显示「未验证」。
- **编辑 URL 后清空该源 cache**：调 §9 的 `clear(id)`；若改的是激活源，同时重置内存态。
- 删除源与编辑源都要二次确认。

---

## 8. URL 归一化与校验

### 8.1 规则（`BrewSourceUrl`）

```
normalize(raw):
  trim 空白
  去掉所有尾部 '/'
validate(normalized):
  必须是 http:// 或 https://
  必须含 host（且 host 非空、不含空格）
  不得含 query（'?'）或 fragment（'#'）
  长度 ≤ 256
```

非法输入在**保存时**就拒绝（不写注册表），错误提示指向具体哪一条不满足。

---

## 9. 缓存维护

### 9.1 `BrewCacheAdmin`

`features/brewcommon/src/main/ets/service/BrewCacheAdmin.ets`

```ts
class BrewSourceCacheStats {
  sourceId: string;
  keys: number;          // 该 store 的键数
  entries: number;       // 结构化条目总数（见下）
  approxBytes: number;   // sum(JSON.stringify(value).length)
  updatedAt: number;     // 由缓存内容里的 ts 字段取，取不到则 0
}

class BrewCacheAdmin {
  static stats(sourceId: string): Promise<BrewSourceCacheStats>;
  static clear(sourceId: string): Promise<void>;
  static drop(sourceId: string): Promise<void>;
}
```

- `entries` 的口径：`brew_live_data` 的 doc 条数 + `brew_meta_index` 的 token 数 + `brew_catalog` 的
  token 数 + `brew_detail_page_data` 的子键数。
- **成本**：单源一次约 2.8MB 的 `JSON.stringify`，属设置页一次性开销（点「查看」才触发，不在列表里预取）。

### 9.2 `clear(id)`

1. 若 `id` 是当前会话激活源：**先重置 brewcommon 的内存态**（§9.3），再清 store。
2. `clearSync()`。⚠ **GSKV 下这才清到内存缓存页 —— 必须再调 `persistNow()`**，
   否则进程被杀后缓存会整份回来（实施时实测到的 D8，见 §15.1）。
3. **在途写入不得回填**：清空 / 删除会使缓存世代号 `BREW_CACHE_EPOCH` 递增；所有**长时间运行**的
   写入口（`BrewService.saveCatalog`、`BrewService.flushCache`、`BrewService.rememberStamp`、
   `BrewMetaSync.persistIndex`、`BrewMetaSync.rememberStamp`）在操作开始时捕获世代号，
   不匹配则**丢弃结果**（既不写盘也不更新内存）。没有这道守卫时，「后台同步 / 目录刷新正在进行」
   会把刚清掉的缓存立刻写回去 —— 表现为「清了但没清掉」。

### 9.3 `resetMemoryCaches()` 的字段清单

`BrewService`（全部为 static）：

| 字段 | 重置为 |
|---|---|
| `liveCache` / `datasetStamps` / `catalog` | `undefined` |
| `cacheDirty` / `stampsDirty` | `false` |
| `catalogLoaded` | `false` |
| `probeCache` / `missCache` / `inFlight` | `clear()` |
| `degradedWarned` | `{}` |
| `stats` | 重新赋初值 |
| `catalogInFlight` | `undefined` |
| `formulaPageInFlight` / `caskPageInFlight` | `undefined`，并把对应 `…Id` 自增（作废在途序号） |
| `activeHydrates` | **不强制清零**（有在途批次）；靠世代号守卫阻止回填 |

`BrewMetaSync`：`index = undefined`、`stamps = undefined`。
**`started` 保持不动** —— 清缓存不应触发一次 5.29MB 的全量重下；索引留空，下次进程启动自然重同步。

### 9.4 删除源 `drop(id)`

- 拒绝 `builtin`（官方源）。
- **拒绝当前会话激活源**，提示「请先切换到其他源」（切走即重启，重启后再删）。
- `removePreferencesFromCacheSync()` → `deletePreferences()`，串行执行。
- 非激活源没有在途写入者（只有激活源会被读写），因此不存在回填竞态。

### 9.5 运行期健康记录（「部分可用」的来源）

不做预探测。`BrewSourceStore` 维护 `brew_source_health`（主 store）：

```ts
class BrewSourceHealthRecord {
  lastProbeOk: boolean;
  lastProbeReason: string;
  lastProbeAt: number;
  lastErrorKind: string;    // 'catalog' | 'meta' | 'hydrate'
  lastErrorMessage: string;
  lastErrorAt: number;
  catalogOkAt: number;
  metaIndexTokensAt: number;
}
```

写入点：`BrewService.getCatalog` 的失败分支、`BrewMetaSync` 的失败分支、hydrate 批量失败率超阈值。
判定：**单条文档 OK（探测通过）但 `catalog` / 全量包持续失败** → `PARTIAL`。

### 9.6 设置页 UI

新增 `features/mine/src/main/ets/view/BrewSourceSettingView.ets`
（`features/mine` 已有 `routerMap` 且已依赖 `@ohos/brewcommon`；`brewcommon` 自身**没有** routerMap），
配套 `viewmodel/BrewSourceSettingVM.ets` + `BrewSourceSettingState.ets`。

```
Mine > 设置 > 数据源
┌───────────────────────────────────────────────┐
│ 官方源                    [使用中] [内置]      │
│   https://formulae.brew.sh/api                │
│                            [查看缓存][清空缓存]│
├───────────────────────────────────────────────┤
│ 清华镜像                  [未验证]             │
│   https://mirrors.example.com/homebrew/api    │
│   [激活][编辑][测试连接][查看缓存][清空缓存][删除]│
└───────────────────────────────────────────────┘
                              [ + 新增数据源 ]
```

- 官方源恒在第 0 项并标注「内置」。
- 状态：使用中 / 未验证 / 正常 / 部分可用 / 失败原因。
- 激活 / 删除 / 清空 / 编辑 URL 都要二次确认（激活与编辑 URL 会重启或清缓存）。
- 入口：`MineSettingView.ets` 现有 `List` 里增加一项「数据源」；`mine` 的 `router_map.json` 增加一条路由。

---

## 10. 错误处理

### 10.1 本轮做

- `BrewSourceProbe` 的 11 类错误分类（§7.1）与用户可见原因。
- URL 归一化与格式校验（§8.1）。
- 运行期健康记录（§9.5）。

### 10.2 后期（本轮只登记，不改代码）

审查现状时定位到的具体问题，附当前行号：

| # | 位置 | 问题 | 为什么值得改 |
|---|---|---|---|
| 1 | `BrewService.fetchCatalog` | 4 个探针用 `Promise.all`，**任一 reject 即整批失败**，无逐端点隔离 | 镜像只要缺一个 analytics 端点，每次刷新都失败 |
| 2 | `BrewService.buildCatalog` | `JSON.parse(one.text)` 无 try/catch | 镜像返 HTML 200 时抛出的错误与真实原因无关 |
| 3 | `BrewMetaSync.syncKind` | `getJson` 只判 200，不校验 JSON 形状；大文件解析失败整批丢弃 | 5.29MB 白下 |
| 4 | `BrewService.conditionalFetch` | `JSON.parse(res.text)` 未包裹 | 行为可接受，但日志无区分度 |
| 5 | `BrewHttp.getJson` | 304 / 404 / 非 200 一律 `unexpected status N` | 调用方分不清「上游没有」与「这次不行」 |
| 6 | 全局 | 无重试 / 退避：5xx、429、超时一视同仁 | 瞬时抖动被当成永久失败 |
| 7 | 全局 | 无每源熔断：持续失败仍每轮重试（仅 404 有负缓存） | 多源下失败源的代价会被放大 |

---

## 11. 改动面清单

### 新增（`features/brewcommon/src/main/ets/`）

| 文件 | 职责 |
|---|---|
| `constant/BrewSourceConstants.ets` | 官方源常量、store 名前缀、探测超时、世代号 |
| `model/BrewSourceModels.ets` | `BrewSource` / `BrewSourceRegistry` / `BrewSourceHealth` / `BrewProbeResult` / `BrewSourceCacheStats` |
| `service/BrewSourceUrl.ets` | 归一化与格式校验（纯函数） |
| `service/BrewSourceStore.ets` | 注册表读写、不变量、会话冻结、`activeBaseUrl()`、健康记录 |
| `service/BrewSourcePrefs.ets` | 每源 store 的 get/set/keys/stats/clear/drop |
| `service/BrewSourceProbe.ets` | 单端点探测与错误分类 |
| `service/BrewCacheAdmin.ets` | 维护入口：stats / clear / drop + 内存重置 + 世代号 |
| `util/objkeys.ts` | `Object.keys(Object)` 的 ArkTS 包装 |

### 新增（`features/mine/src/main/ets/`）

`view/BrewSourceSettingView.ets`、`viewmodel/BrewSourceSettingVM.ets`、`viewmodel/BrewSourceSettingState.ets`。

### 修改

| 文件 | 改动 |
|---|---|
| `BrewConstants.ets` | 删 `BREW_API_BASE`；`BrewDataSource`→`BrewDataMode`、`BREW_DATA_SOURCE`→`BREW_DATA_MODE` |
| `BrewService.ets` | URL 取 `activeBaseUrl()`；`catalogSources()`；缓存读写走 `BrewSourcePrefs`（含 1482-1500 的详情页组键读写改 `getSubValue`/`setSubValue`）；新增 `resetMemoryCaches()`；世代号守卫；`BREW_DATA_MODE` 改名 |
| `BrewMetaSync.ets` | 同上（URL / 缓存读写 / `resetMemoryIndex()` / 世代号守卫） |
| `BrewCatalogAlgo.ets` | `BREW_CATALOG_SOURCES` → `catalogSources()` |
| `BrewRepository.ets` | 仅 `BREW_DATA_MODE` 改名 |
| `BrewApiMapper.ets` | 仅注释里的常量名 |
| `brewcommon/Index.ets` | 导出新符号（`BrewSourceStore` 等），供 `mine` 使用 |
| `mine/.../MineSettingView.ets` | 增加「数据源」入口 |
| `mine/.../router_map.json` | 增加 `BrewSourceSettingView` 路由 |
| `common/src/main/resources/.../string.json`（brew 侧资源在 brewcommon / mine） | 新增文案；中英各一份 |

---

## 12. 验证方案

**不做** Node 测试、**不做** `ohosTest`（handover §9.3：HAR 的 `ohosTest` 不能用 `devecocli build` 跑）。
验证 = **编译 + 真机日志打点**。

### 12.1 编译验证

```bash
devecocli build            # 期望 BUILD SUCCESSFUL, 0 error
```

并按 handover §9.5.1 每轮必查两项：

```bash
ABC=products/pc/build/default/intermediates/loader_out/default/ets/modules.abc
grep -c BrewSourceSettingView "$ABC"     # 应为正数（不加 ^$ 锚点）
python3 -c "import json;print([r['name'] for r in json.load(open(\
  'products/pc/build/default/intermediates/router_map/default/router_map.json'))['routerMap']])"
# 期望含 BrewSourceSettingView
```

### 12.2 判据日志（新增打点）

| 日志行 | 位置 | 说明 |
|---|---|---|
| `[BrewSource] registry loaded, n=…, active=…` | `BrewSourceStore` 首次读注册表 | 注册表是否生效 |
| `[BrewSource] session active frozen, id=…, base=…` | 会话冻结 | 「本会话用的是哪个源」的唯一权威 |
| `[BrewSource] official missing, recreated` | 不变量 1 触发 | 数据损坏自愈 |
| `[BrewSource] activeId=… not found, fallback to official` | 不变量 3 触发 | 同上 |
| `[BrewSource] store open, id=…, mode=gskv, ok=…` | `BrewSourcePrefs` 首次开 store | GSKV 是否真的用上 |
| `[BrewSourceProbe] <base> ok=true code=200 reason=ok ms=…` | 探测成功 | G6 |
| `[BrewSourceProbe] <base> ok=false code=… reason=… ms=… detail=…` | 探测失败 | G6 |
| `[BrewSource] activate id=…, restart via UIAbilityContext.restartApp` | 激活序列 | G2 |
| `[BrewSource] restart fallback=ApplicationContext, err=…` | 兜底链 | 重启是否降级 |
| `[BrewCache] stats id=… keys=… entries=… bytes=… ms=…` | 维护页查看 | G5 |
| `[BrewCache] clear id=… active=… epoch=…→…` | 清空 | G5 |
| `[BrewCache] epoch mismatch, dropped write key=…` | 世代号守卫命中 | 「清了又被写回」的反证 |
| `[BrewCache] drop id=… ok=…` | 删源 | G4 |
| `[BrewSource] health id=… → partial, reason=…` | 健康记录 | G3 / 部分可用 |

**「走的是哪个 base URL」不需要新增打点**：`BrewHttp` 已经打印完整 URL
（`[BrewHttp] GET 200, 123ms, 5123B, https://…`），这就是 G2 的证据。

### 12.3 真机功能验证清单

| # | 步骤 | 期望 |
|---|---|---|
| V1 | 冷启动 | `session active frozen, id=official`；`store open, mode=gskv` |
| V2 | 新增源（合法 URL）→ 测试连接 | 列表出现该项、状态从「未验证」变「正常」 |
| V3 | 新增源（非法 URL：无 scheme / 带 query） | 保存被拒，提示具体原因 |
| V4 | 激活一个**不可达**源 | 硬阻断 + 具体 reason；**activeId 未改变** |
| V5 | 激活一个可用源 → 确认 → 重启 | 重启后 `session active frozen` 是新 id；`[BrewHttp]` 的 URL 是新 base |
| V6 | 查看某源缓存 | `[BrewCache] stats` 有值；清空后**立即杀进程再重启**，缓存仍为空（验证 `persistNow` 真的把缓存页写盘，见 §15.1） |
| V7 | 清空**激活源**缓存 | 条目数归零；页面回落空态；`epoch mismatch` 守卫在「清空时后台同步在跑」的情况下命中 |
| V8 | 删除**非激活**源 | `drop ok=true`；重启后该源 store 不再出现 |
| V9 | 删除激活源 / 官方源 | 被拒并给出原因 |
| V10 | 编辑激活源的 URL | 该源缓存被清空；重启后走新 base |
| V11 | 重启 API 失败分支 | 未获焦、3 秒内重复各一次，确认兜底链生效 |

---

## 13. 风险与回滚

| 风险 | 影响 | 处置 |
|---|---|---|
| **GSKV 不做探测、不设计回退** | 若设备不支持 GSKV，store 创建失败 → 缓存全失效（页面空态/降级），但**不崩溃** | `store open, ok=false` 会明确打出来；处置见 V1。若真机确认不支持，再单独讨论回退 |
| `UIAbilityContext.restartApp` 需获焦、3 秒内不可重复 | 极端情况下重启失败 | 三级兜底链；每级打日志；最差退到 `exitApp` + 提示手动重开 |
| 清空缓存被在途写入回填 | 「清了没清掉」 | 世代号守卫（§9.2）+ 反证日志 |
| 导入期 `UIContext` 未就绪 | base URL 为空 → 请求全失败 | URL 改为运行时解析（§6.2），彻底消除导入期求值 |
| 改名 `BREW_DATA_SOURCE` 的churn | 14 处引用 | 机械替换；编译器保证不漏 |
| `getAllSync` 的 2.8MB stringify 在主线程 | 维护页卡顿 | 只在点「查看」时触发；在 spec 与本表登记为已知代价 |

**回滚**：本轮不改动既有缓存键名与数据形状，只改「键落在哪个 store」。回滚 = 还原代码；
被放弃的 `brew_src_*` store 是新增文件，不会污染主 store（主 store 只多了 `brew_sources` /
`brew_source_health` 两条小键）。

---

## 14. 附录：UI 状态机

```
BrewSourceSettingState
  sources: BrewSource[]
  activeId: string
  health: Record<string, BrewSourceHealthRecord>
  editing: BrewSource | undefined        // 正在编辑/新增的表单
  probe: { sourceId, running, result }   // 探测中 / 结果
  cacheView: { sourceId, stats, loading } | undefined
  confirm: { kind: 'activate'|'delete'|'clear'|'edit-url', sourceId } | undefined
```

⚠ 卡片上的**状态区最多两行**（§15.11 修订，推翻本节原先的「一行、三种状态互斥」）：
上行 `BrewSourceReach`（连通性，探测）、下行 `BrewSourceHealth`（数据就绪，运行期；仅会话激活源）——
**下行当前由 `SHOW_SOURCE_DATA_LINE = false` 关着**。
`health` 记录里同时住着这两条轴的字段，但**不再参与同一个状态判定**。

激活弹窗的文案与按钮必须与 §7.2 一致；探测失败弹窗只给「重试 / 取消」。

---

## 15. 实施记录与 spec 修正（2026-09-24）

本节是**实施完成后回写的偏差记录**。前面各节是设计意图，**与本节冲突时以本节为准**。
实施过程共 15 个提交，逐项真机验证了 G1–G7；其中 7 个缺陷（D1–D8）是验证过程中发现的，
一条 Critical（C1）是整分支终审发现的。下面只记**与设计不一致、或设计本身错了**的地方。

### 15.1 §2 的 GSKV 前提是**错的**（最重要的一条）

§2 写「GSKV：二进制、**实时落盘、无需 flush**」。**这句直接引用了文档的概述，但与文档自己的建议相矛盾。**
（原文所在的两处内联注释已在 §5.3 与 §9.2 就地标注，此处保留对偏差的记录。）

实测（同一份代码，三次启动）：目录写入后进程若在 ~25s 内被杀 → 下次启动 `reason=missing`；
存活 130s 以上 → 下次 `reason=pref age=130s`。官方文档原话是
「若使用 GSKV 存储模式，推荐在进程退出时手动调用一次 `removePreferencesFromCache`，
**此操作会将数据缓存页写入磁盘**」。而 App 从不优雅退出（进程被系统回收、被覆盖安装杀掉）。

**后果最严重的一处不是「多下一次」**：`clear()` 只清了内存缓存页，进程被杀后**缓存整份回来** ——
「清了没清掉」。而 `BrewCacheEpoch` 只覆盖同一会话内的在途写入，跨不了进程。

**实施**：新增 `BrewSourcePrefs.persistNow()`（`removePreferencesFromCacheSync` + 作废已失效句柄），
挂在 4 个必须持久化的点：`clear` / `saveCatalog` / `flushCache` / `persistIndex`。
真机实测 `evictMs=5~10ms`，代价可忽略；清空后 3 秒内杀进程，重启后四个缓存键均为 `missing`。

### 15.2 §9.2 的世代号语义要写得**更死**（C1）

§9.2 说「在**操作开始时**捕获世代号，不匹配则丢弃结果」是对的，但实施时把它写成了
「不匹配时把 epoch 改成当前值再 return」—— 等于**只保护 bump 后的第一次写入**。
而 `BrewMetaSync.epoch` 是 `rememberStamp` 与 `persistIndex` **共用的同一个 static**，
`applyKindResult` 先调前者再调后者 → 那一次配额被几十字节的 `brew_meta_stamp` 用掉 →
**1MB 的 `brew_meta_index` 照写不误**，且日志只留一条 `dropped write key=brew_meta_stamp`，
看起来守卫是生效的。**G5 就此被击穿**（整分支终审判 BLOCK 的唯一原因）。

**修正后的硬规**（已写进 `BrewCacheEpoch` 类注释）：

| 规则 | 内容 |
|---|---|
| 捕获点 | **只能在操作入口**：`BrewService.hydrate` / `conditionalFetch` / `getCatalog`、`BrewMetaSync.sync` |
| 禁止 | **任何 drop 分支里不得改写 epoch** |
| 语义 | 清空**之后**新发起的操作 → 捕获到新值 → 正常写盘；清空**之前**已在跑的操作 → 它的**全部**写入都被丢弃 |

真机复验（利用上游当日极慢、`formula.json` 下载 198s 把窗口拉到 3 分钟）：清空发生于 10:24:33，
迟到落盘于 10:27:33，日志为两条 `epoch mismatch, dropped write key=brew_meta_stamp` +
**`brew_meta_index`**，且**无任何 `meta index persisted`**。

### 15.3 §9.5 的第三个写入点：已实现（带具体阈值）

`hydrate` 失败率超阈值时写健康记录，阈值为 **`failed * 2 > unique.length`**，kind 用 `'hydrate'`；
`healthState` 的 PARTIAL 判定扩为三值（`catalog` / `meta` / `hydrate`）。
`noteError` 现在**只接受这三个 kind**（其它 kind warn + return）—— 它是单槽语义，
任何无关 kind 都会冲掉「当前站着的是哪个错误」；探测失败由 `noteProbe` 单独表达。

### 15.4 §9.6 的「失败原因」已实现；`updatedAt` 不展示

- 列表每行在状态标签**下方**补一行具体原因（`lastErrorMessage` 优先，否则 `lastProbeReason`），
  原始字符串、不翻译 —— 它是诊断信息，与 `probeResultText()` 的本地化文案分工不同
  （一行是**刚刚这次探测的结论**，一行是**列表上持久化的状态摘要**）。
- `BrewSourceCacheStats.updatedAt` **仍计算但不展示**（目前只对 `brew_catalog` / `brew_meta_index` 两键有值）。
- 未做**行级 loading**：`busyText` 字段已删。理由：它不含源 id，无法驱动按行 loading；
  要做需另加 `busyId` 并配套 set/clear，那是新功能（spec/plan 都没要求），
  而清空/删除已有二次确认 + `BrewCacheAdmin` 串行队列，实测延迟可忽略。

### 15.5 §8.1 的「指向具体哪一条」已实现（8 个码）

`BrewSourceSettingVM.saveErrorText()` 把 `name-empty` / `url-empty` / `url-scheme` / `url-host` /
`url-query` / `url-fragment` / `url-too-long` / `save-failed` 映射到各自文案。
**这条与 `normalize("https://")` 的修复是绑定的**：在文案被丢弃时，后者「对用户零影响」；
一旦按原因提示，`https://` 若被误报成 `scheme`，用户会看到「地址必须以 http:// 或 https:// 开头」
—— 而他确实写对了协议。`normalize` 已改为**只剥 `://` 之后的尾斜杠**，`https://` / `http://` 正确落到 `host`。

### 15.6 §7.1 / §7.2 / §14：**实施与设计不同，以实施为准**

| 项 | spec 原文 | 实施 |
|---|---|---|
| 失败反馈 | §7.1/§14「失败只给『重试 / 取消』弹窗」 | **不弹窗**，把原因内联显示在卡片上（信息量更大、少一步交互）。§7.1/§14 的该句作废 |
| 激活顺序 | §7「① 探测 → ② 确认弹窗」 | **先确认再探测**（确认后探测失败则硬阻断、不写 activeId、不重启）。效果等价，且用户能在失败时看到原因 |
| 页面状态 | §14 的 `confirm` / `cacheView` 等状态机 | state 是**扁平的**（`rows` / `editing*` / `creating` / `probeResult*` / `cachePanel*`），弹窗由 View 直接用 `showAlertDialog` 持有 |

另外 §14 的 `editingId === ''` 曾被同时用来表示「新增中」与「没在编辑」，导致**新增表单从未被渲染**
（`editingId === row.source.id` 对新源永不可能成立）—— 已用独立的 `creating` 标志修掉。

### 15.7 §12.2 判据日志：与实际的对应关系

| §12.2 写的 | 实际 |
|---|---|
| `[BrewSourceProbe] <base> ok=… reason=…` | ✅ 已带 base（成功/失败两行都有） |
| `[BrewSource] activate id=…` | 由 `[BrewSource] activeId written, id=…` 承担（同一事件的唯一权威行），不另立一行 |
| `[BrewSource] health id=… → partial, reason=…` | **不存在**。状态用两种方式观察：写入口的 `catalog ok noted` / `meta ok noted` / `noteError`，以及 UI 列表的状态与明细行 |
| `[BrewCache] epoch mismatch, dropped write key=…` | ✅ 存在，且 C1 修复后**同一批操作的多个键会各打一行**（不再只打第一条） |

**一条待改的日志语义重载**：`persistIndex` 被丢弃时目前用 `BrewLoadLog.warn(…, 'sync-failed', …)`，
与真正的同步失败共用一个 reason。建议在 `BrewLoadLog` 的 reason 词表里加一行 `epoch-dropped`，
这样 `grep 'reason=epoch-dropped'` 就能直接统计「清空与同步撞车」的发生频率。（属于 deferred）

### 15.8 自检（`BREW_SOURCE_VERIFY`）必须用**精确断言**

D4 曾从自检里溜过去，原因是断言写的是 `ok = !check.ok` —— 它对**任何**拒绝理由都成立，
所以 `https://` 被误报成 `scheme` 时照样打 `ok=true`。**「只打印 reason」不构成判据。**
现已改为 `expectReject(raw, expectedReason)` / `expectNormalized(raw, expectedValue)`。

真机 25 条断言全部 `ok=true`（含 `https://`/`http://` → `host`、三条归一化正向用例、
健康状态机 `allOk=true`、缓存 stats/clear/drop/同名重加、四类探测 reason）。

### 15.9 §13 风险表要补一条

**`UIAbilityContext.restartApp()`（API 22+，spec §7.3 的首选）在本设备上不被支持** ——
真机返回 `errCode=801, errMsg=Capability not support`，自动兜底到 `ApplicationContext.restartApp()` 并成功重启。
即三级兜底链在这台设备上是**有效路径**而非「保险」，代价是重启时有桌面闪现（不保留窗口）。
**不要因为首选 API 存在就删掉后两级。**

### 15.10 其余已裁定为 deferred 的项

体现在 §12.2 的判据行字段、`updatedAt` 不展示（§15.4）、`reason=epoch-dropped`（§15.7）、
以及「注册表自愈是否落盘」（已在实施中改为落盘）。
完整清单与逐条裁定见实施计划的 ledger（`.superpowers/sdd/2026-09-23-brew-multi-source/progress.md`）。

### 15.11 §9.5 / §9.6 的状态是**两个正交维度**（2026-09-25 修订，推翻了 §9.5 的单一 `healthState`）

§9.5 只定义了「一个」状态值，§9.6 也把它当成一个徽标渲染。实施后真机上暴露了它的语义缺陷：

- 该值把**连通性**（`lastProbeOk`，只在点「测试连接 / 激活」时写）与**取数进度**（`lastErrorKind`，
  由目录 / 全量包 / 单条文档三条**懒触发**通道写）合成一个值。于是卡片上的结论取决于用户
  刚才点过什么、进过哪些页面 —— 「点测试连接说可用、列表说部分可用」看起来像自相矛盾。
- 取数通道的成功与失败**不对称**：`noteCatalogOk` 只清 `catalog`、`noteMetaOk` 只清 `meta`，
  而 `hydrate` 失败**没有任何成功路径能清**；`meta` 的清除又只能在**另一次进程启动**里发生
  （`BrewMetaSync.started` 保证一进程只同步一次）。结果是徽标看起来像「下载进度条」：
  要等到把数据（重新）下载完才转正常。
- 更早一层：`lastProbeAt === 0 → UNKNOWN`，「没记录到错误 → OK」意味着**全新安装、一页数据
  都没有时也可能显示正常**（只要用户点过一次成功的测试连接）。

修订（以实施为准）：

1. **拆成两条轴**（§14 的状态机改为「上行探测 / 下行数据」，见下）：
   - `BrewSourceReach`（连通性轴，`reachState()`）：`UNKNOWN` / `OK` / `FAILING`，**只**由
     `noteProbe` 决定；上行文案就是「未验证 / 连接正常 / 连接失败：<原因>」。
   - `BrewSourceHealth`（数据轴，`healthState()`）：`UNKNOWN` / `OK` / `PARTIAL`，**不看**
     `lastProbe*`；`FAILING` 成员删除（它只是被探测借用的）。`OK` 的判据从「没有错误」改为
     「目录与全量包都成功过至少一次」，所以未就绪不再冒充正常。
2. 数据轴只有**会话激活源**渲染：取数都发往它，其它源从没被请求过，渲染出来只会是误导。
3. 删除 `FAILING` / `health_detail_prefix` / `health_ok` / `health_partial` / `health_failing` /
   `health_unknown` 文案，新增 `brew_source_reach_unknown` 与 `brew_source_data_{prefix,ready,no_catalog,no_index}`。
   ⚠ 数据行的渲染**当前由 `BrewSourceSettingView.SHOW_SOURCE_DATA_LINE = false` 关着**（只关显示，
   判定 / 清空路径 / 自检都在位），因为两行同时出现时卡片明显变高、数据行的视觉层级还需再定；
   重新上屏只需把该常量改成 `true`。
4. `BrewCacheAdmin.clear/drop` 调新增的 `resetDataHealth()`：数据轴记录随缓存作废
   （否则「清空缓存了，列表还写着部分可用」），**探测记录保留** —— 它描述远端地址，与本地缓存无关。
5. `BrewSourceSettingVM` 的探测 `.catch` 分支原先调 `noteError(id, 'probe', …)`，而 `noteError`
   只收 `catalog`/`meta`/`hydrate`，**被静默丢弃** → 改为 `noteProbe(id, false, 'network-unknown')`，
   否则「测试连接抛异常」时列表仍显示上一次的结论。
6. `probeReasonTextOf(reason)` 成为原因码映射的**唯一**入口（刚测的传 `state.probeReason`、上次的传
   `row.reachReason`），避免两份分支表。

回归证据：`BrewSourceDiagnostics.cacheCases()` 的 `verify health axisSplit` 行断言两条轴互不影响
（探测失败后数据轴不变、`resetDataHealth` 后数据轴回 `UNKNOWN` 而连通性保留）。

**已知遗留（本轮不改）**：数据轴的 `OK` 依赖「目录与全量包都成功过」。若用户从不进 Discover
（它是冷启动默认页并被 `preloadItems` 预建，正常情况下必然执行一次 `getCatalog`），目录永远取不到，
则浏览页为空态、数据轴停在「目录未获取」。这**比改动前诚实**（旧实现会显示正常），
但浏览页「从不自己拉目录」本身是 §12.3 之后的独立议题。

---

## 16. Harmonybrew 的目录口径

Harmonybrew 不提供 Homebrew 官方的 `/api/analytics/*` 聚合端点；其目录由 AtomGit 发布的逐日
`stats/stats-YYYYMMDD.json` 合成。以下口径只适用于 Harmonybrew，官方源仍沿用自己的 analytics 口径。

### 16.1 指标、窗口与 `prior`

- 指标是 **AtomGit 下载量**，不是 Homebrew 官方的 `install-on-request` **安装量**。因此
  Harmonybrew 的目录量值不能与官方安装量视为同一指标。
  详情页也因此只有一个数字可用：`installs30d` 取目录的 `v30`（与 Discover 榜单同一份），
  `installs90d` / `installs365d` 留 0、不渲染。`mergeFormula` 在方言不带 `analytics` 时
  **不覆盖**这两个以外的安装量字段，否则会把骨架里的目录数字清零。
- 当前窗口取最近 **30 天**，基线窗口取其之前的 **60 天**；合成 `30d` 文档时只累计当前窗口，
  合成 `365d` 形状的文档时累计两者，所以一次目录刷新合计读取 **90 个日文件**。
- 趋势基线 `prior` 必须以 `60 / 30.4`（约 `1.974`）为除数，将 60 天折算为月均。官方仍使用
  **`11.0`**：这是官方 335 天窗口折月均后的标定值（`335 / 30.4 ≈ 11.02`，取 `11.0`），不是
  Harmonybrew 的 60 天窗口除数。

这三点都是**刻意偏离官方口径**：日文件源只能提供下载量；将基线限制为 60 天，是为了避免为延长
趋势基线而把首次请求量从 90 个翻到接近全部可用历史，且实测继续延长基线对趋势榜的收益很小；
相应地必须参数化 `prior` 除数，否则 60 天基线会被错误地当作约 11 个月，规模将系统性缩小。
调整这些值会改变 Harmonybrew 的榜单含义，不能静默套用官方常量。

### 16.2 按日永久缓存

每个 `YYYYMMDD.json` 发布后不可变，因此按天永久缓存于
`filesDir/brew_src/<sourceId>/stats/YYYYMMDD.json`：已缓存的日期不再请求，窗口滑动时只淘汰窗口外
文件。首次刷新需取得 90 个日文件；进入稳态后，每天只请求新发布的一个日文件。

这同样是**刻意偏离官方刷新方式**：官方聚合端点可能变化，刷新时仍需请求并依赖条件请求判断是否
更新；Harmonybrew 的已发布日期可永久复用。日文件尚未发布时，候选最新日先取 UTC 今天减一天，
若 404 再回退到今天减两天。
