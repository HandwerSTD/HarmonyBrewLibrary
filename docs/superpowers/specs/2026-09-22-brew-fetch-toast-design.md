# brew 数据获取提示（Toast）· 设计（spec）

日期：2026-09-22 · 状态：**设计已确认**（四个决策点由需求方 2026-09-22 选定），待评审本 spec 后进入实施计划
代码基线：`efdf62e` + 未提交的 `[load]` 打点与元数据同步修复（见 §2.2）

---

## 1. 目标与非目标

### 1.1 目标

当首页三个页签（Discover / Formulae / Casks）**以及分类二级页**即将发起网络请求、用户会因此等待时，
弹一次 Toast 告知「正在获取 Homebrew 数据」，让"转圈"变成"有解释的等待"。

需求方原话：

> 在缓存过期的时候（或者是任何即将请求网络以获取首页三个 tab 数据的时候），
> 用户即将等待 10s 的时候，打个 toast「正在获取 Homebrew 数据」。

### 1.2 非目标（本轮明确不做，避免被当成漏做）

| 不做 | 理由 |
|---|---|
| 进度百分比 / 已下载字节 | 没有总字节数（聚合端点是 4 个文件的并发条件请求；单条 hydrate 是 100 个独立请求） |
| 预计剩余时间 | 同上，且实测跨度 5~15s，给不出有意义的估计 |
| 可主动撤销的浮层（`promptAction.openCustomDialog`） | 需求方选定复用现有 Toast（§3.2） |
| 改 `BaseHomeView` 已有的全屏 `LoadingView` | 它已经在了（§2.3）；本轮只补"文案"，不动它的显示条件 |
| 给后台 `BrewMetaSync` 同步加提示 | 它不阻塞首屏；且实测最坏要 13.3 分钟（§2.2），提示了也无法兑现"很快好" |
| 详情页（`brewdetail`） | 它是**用户点击后才等**的交互路径，语义与"App 自己在拉数据"不同 |
| 首次安装的引导 / 离线说明 | 与"等待提示"是两件事 |

---

## 2. 背景与已核准的事实

### 2.1 用户诉求真正要解决的问题

不是"没有等待提示"——`BaseHomeView` 在 `LoadingStatus.LOADING` 时**已经渲染全屏转圈**。
真正的问题是**这个转圈不说话**：用户看得到"在转"，但不知道在等什么、要等多久，也无法判断是卡死了还是在正常拉数据。

所以本轮的产出是**给等待加一句解释**，而不是新增一个等待指示器。

### 2.2 代码事实（写代码时不用再查）

| 事实 | 位置 |
|---|---|
| `Toast.showLongToast(msg)` = 2000ms；内部 `uiContext.getPromptAction().showToast()`，**没有 close API** | `common/src/main/ets/component/Toast.ets` |
| `Toast` 从 `@ohos/common` 根导出（`Index.ets` → `component/index.ets:32`） | 同左 |
| `BaseHomeView` 按 `loadingModel.loadingStatus` 四态渲染：`SUCCESS`→内容、`LOADING`→`LoadingView`、`FAILED`→`LoadingFailedView`、`NO_NETWORK`→`NoNetworkView` | `features/commonbusiness/src/main/ets/view/BaseHomeView.ets` |
| 已有"延迟 N ms 再显示"的模式：`DelayedLoadingView`（350/400ms 阈值，`BaseDetailComponent` 在用） | `common/src/main/ets/view/DelayedLoadingView.ets` |
| brew 字符串在 `features/brewcommon/src/main/resources/{base,zh_CN,en_US}/element/string.json`（131 条），**HAR 字符串已被跨模块引用 106 处**（例：`features/mine` 用 `$r('app.string.brew_label_packages_count')`），合并无问题 | 同左 |
| **分类二级页与首页走同一个构页函数**：`getFormulaCategories()` → `getFormulaPage(1, SIBLING_PAGE_SIZE=100)` → `buildFormulaPage(1, 100)`；cask 同构 | `BrewRepository.ets:209`、`BrewService.ets:1005` |
| `brewcommon` 是**共享层**，本就承载共享 UI 原子（`BrewPackageRow` / `BrewChipBar` / `BrewPackageIcon` …） | `docs/brew-handover.md` §3.2 |
| **`[load]` 打点**（本轮新增）就是判定"这次会不会走网络"的现成信号源，reason 是固定词表 | `features/brewcommon/src/main/ets/util/BrewLoadLog.ets` |

实测数字（都来自真机，见 `docs/brew-catalog-fullsync-spec.md` §4.7 与冷启动 spec §14）：

| 场景 | 实测 |
|---|---|
| 浏览页降级路径（索引不可信，逐条 hydrate ≤100 个） | **5~15s**（观测到 4576ms / 4201ms / 2188ms；预算上限 15s） |
| 浏览页主路径（索引可信，零请求） | **415ms**（只剩分类 7299 行） |
| Discover 整页（快照 + 目录缓存命中 + live 缓存命中） | **37ms** |
| 目录过期 → 4 个端点并行探针 | **设备实测 `catalog_fetch ms=17437`**（宿主机同批 5.2s）。⚠ 2026-09-23 修订：旧值写的“0 字节、几百毫秒、3/4 命中 304”已被实测推翻，见 §13 |
| 目录缺失（首次安装）→ 4 个聚合端点全量下载 | gzip 合计 **~358 KB** |
| `BrewMetaSync` 后台同步（上游慢时） | `total=798998ms`（**13.3 分钟**） |

### 2.3 为什么判定必须靠"会不会走网络"，而不是"等了多久"

需求方原话里的"**即将**等待 10s"在实现上不可预知：网络耗时只有发出去才知道。
所以判定只能由两个可观测的事实拼出来 —— 而需求方已选定其中一半：

| 方案 | 误报 | 漏报 |
|---|---|---|
| **纯预测式（本 spec 选定）** | 网络很快时会白闪一下 | 无 |
| 纯延迟式（发起后等 N 秒仍没完成才弹） | 几乎无误报 | 若 N 取得大，短于 N 的慢加载漏报 |
| 预测 + 延迟结合 | 几乎无误报 | 无 |

选纯预测式的代价是**误报面**，所以 §4.1 的全部工作量都在"把误报面压到最小"：
把"必然要下载"的路径与"可能快可能慢"的路径分开，后者一律不弹。

---

## 3. 方案与决策

### 3.1 被排除的选项

| 选项 | 为什么不选 |
|---|---|
| 可主动撤销的 loading 浮层（`openCustomDialog` + `close`） | 能"完成即撤"，但仓库里 `openCustomDialog` **零用例**，要新增组件 + 三页各接一次；需求方选定复用现有 Toast |
| 只给全屏 `LoadingView` 加一行文案（不弹 Toast） | 语义最诚实、改动最小，但它只在"页面还没有内容"时可见；且需求方要的是 toast |
| 纯延迟式（不看原因，超过 N 秒就弹） | 语义不精确：本地快路径（如 415ms 的分类）卡在阈值附近也会弹 |
| 只覆盖 Discover | 另外两页同样会等 5~15s（降级路径），漏掉就正好漏在用户最可能抱怨的那一页 |
| 在三个页签模块各自接一次提示 | 与 §2.2 的"分类二级页复用同一构页函数"重复；且 `brewcasks` 要依赖 `brewformulae` 才能复用（依赖方向无语义，见 handover §3.2） |

### 3.2 决策（需求方 2026-09-22 选定）

| # | 决策 | 选定值 |
|---|---|---|
| D1 | 触发判定 | **纯预测式**：判定"这次会走网络"就立即弹，不等 |
| D2 | 提示形态 | **复用现有 `Toast`**（`showLongToast`，2000ms，不可主动撤销） |
| D3 | 去重 | **整个冷启动一次**：30s 时间窗内只弹一次 |
| D4 | 覆盖范围 | 首页三 tab **+ 分类二级页** |

---

## 4. 设计

### 4.1 触发判据（核心，也是本 spec 最重要的部分）

判据一律复用 `[load]` 的 reason 词表 —— 它是"这次到底走不走网络"的**唯一权威口径**，
不另起一套判断（否则两套口径必然漂移）。

| # | 场景 | `[load]` reason | 弹？ | 理由 |
|---|---|---|---|---|
| 1 | 目录缺失（首次安装 / 数据被清） | `catalog_fetch` = `missing` | **✅** | 必然全量下载 4 个聚合端点（~358 KB gzip） |
| 2 | **目录过期（探针结果未知）** | `catalog_fetch` = `pref-stale` | **✅** | ⚠ 2026-09-23 修订：原设计在此**不弹**、留给 H2 在探针后再判。实测探针本身就是 17.4s 的等待（304 也可花 24s），所以必须在**发起前**弹。见 §13 |
| 3 | ~~目录过期但探针说没变~~ | ~~`probe-304`~~ | ~~❌~~ | **已废弃**：被 #2 吸收 —— 探针未返回前无法知道结果，而探针本身就是等待。见 §13 |
| 4 | 目录在新鲜窗口内 | `catalog_fetch` = `pref-fresh` | ❌ | 零请求 |
| 5 | 目录请求复用别人的在途请求 | `catalog_fetch` = `in-flight` | ❌ | 已经有人在拉，且已经弹过（见 §4.3） |
| 6 | 浏览页降级路径 | `formula_page`/`cask_page` = `degraded-hydrate` / `degraded-prefix` | **✅** | 最多 100 次单条请求，实测 5~15s |
| 7 | 浏览页主路径 | `formula_page`/`cask_page` = `index-trusted` | ❌ | 零请求 |
| 8 | 浏览页目录缺失 | `formula_page`/`cask_page` = `empty-catalog` | ❌ | 不会发请求（直接空态） |
| 9 | 一批单条 hydrate 有未命中的 token | `live_docs` 有 `dl>0` 的预期 | **✅** | 真要发请求 |
| 10 | 一批单条 hydrate 全部命中 live 缓存 | `live_docs` 全命中（实测 `session hit=N / dl=0`） | ❌ | 0 请求 |
| 11 | 后台元数据同步 | `meta_index_sync` | ❌ | 不阻塞首屏；且最坏 13.3 分钟，提示无法兑现 |
| 12 | 目录取数失败 | `catalog_fetch` = `fetch-failed` | ❌ | 提示发生在**发起之前**，失败是之后才知道的事；失败态由 `BaseHomeView` 的 `FAILED`/`NO_NETWORK` 承担，**不在失败后补弹** |

> **⚠ 2026-09-23 修订（原判据 #3 的“要点”已被实测推翻）**：原文说“按目录过期就弹会白闪一下，
> 因为那条路径实测 3/4 命中 304、只花几百毫秒”。真机实测推翻了这条前提 ——
> 4 个端点并行探针在设备上要 **17.4s**（宿主机同批 5.2s），而 304 也可能花 **24.06s**
> （TTFB 22.5s、0 字节，因为边缘 `Cache-Control: max-age=600` 只有 10 分钟，探针必然回源）。
> **所以“探针”不是廉价的前置检查，它就是那段等待本身。**
> 现在改为：目录一过期就弹（判据 #2），这符合 §2.3 的“**即将**等待时提示”。
> 代价是“10 分钟内重复打开”这类探针很快的场景会白闪一下 —— 而 `BREW_CATALOG_FRESH_MS`
> 已同时从 1h 调到 6h，这种场景大幅减少。完整证据见 §13。

### 4.2 hook 点（只加 3 处，页面层零改动）

新增 `features/brewcommon/src/main/ets/util/BrewNetNotice.ets`（与 `BrewLoadLog` 同目录、同风格）：

```ts
export class BrewNetNotice {
  /** 即将发起一批网络请求。第一次调用弹一次 Toast；窗口内的后续调用静默（见 §4.3）。 */
  public static willFetch(reason: string, detail: string): void
}
```

调用点：

| # | 位置 | 触发条件 | 覆盖的页面 |
|---|---|---|---|
| H1 | `BrewService.getCatalog()` → 启动 `fetchCatalog()` **之前** | 判据 #1（`missing`）与判据 #2（`pref-stale`）**两态都在这里** | Discover |
| ~~H2~~ | ~~`BrewService.fetchCatalog()` 的补取分支~~ | **已删除**（2026-09-23）：它在探针 resolve **之后**才执行，等于“等完了再说” | — |
| H3 | `BrewService.buildFormulaPage()` / `buildCaskPage()` 的降级分支 | 判据 #6（`!trusted && missing.length > 0`） | **首页 Formulae/Casks + 分类二级页**（同一个函数，见 §2.2） |
| H4 | `BrewService.hydrateFormulaDocs()` / `hydrateCaskDocs()` 入口 | 判据 #9（先数一遍 `brew_live_data` 的新鲜命中数，有未命中才通知） | Discover（45 条）+ 任何 hydrate 路径 |

`hydrate` 需要知道缓存 key 前缀（`formula_` / `cask_`）才能预测命中，所以预测放在
`hydrateFormulaDocs` / `hydrateCaskDocs` 两个**已知道 kind** 的包装函数里，
`hydrate()` 本体不动（它只拿到 `fetch` 闭包，拿不到 kind）。

**不做的事**：不在页面层（`brewdiscover` / `brewformulae` / `brewcasks`）加任何代码 ——
H1–H4 已经覆盖了四个页面（首页三 tab + 两个分类二级页），这正是把 hook 收在数据层的目的。

### 4.3 去重

```ts
const BREW_NET_NOTICE_MIN_INTERVAL_MS: number = 30000;
```

`BrewNetNotice` 内一个静态 `lastShownAt: number`：距上次**真的弹了**（`shown=true`）不足 30s 的调用一律静默。
被窗口挡下的调用**不刷新** `lastShownAt`（否则持续触发会把它无限续期）。

为什么是 30s 而不是"每进程一次"：三个页签会**并发**加载（实测同一轮里 Discover 在 +0.6s、
Formulae 在 +5.2s、Casks 在 +6.3s 各自触发），用户看到的是"App 在拉数据"这一件事，弹三次是噪声；
但若用户在 5 分钟后切到某个页签又遇到一次 15s 的降级加载，那时**应该**再提示一次。
30s 窗口把"冷启动这一簇"合并成一次，同时保留后者的提示能力。

### 4.4 形态与文案

```ts
Toast.showLongToast($r('app.string.brew_fetching_data'));
```

新增字符串（三份资源文件都要加，HAR 字符串已跨模块使用，见 §2.2）：

| 文件 | 值 |
|---|---|
| `features/brewcommon/src/main/resources/base/element/string.json` | `Fetching Homebrew data…` |
| `.../en_US/element/string.json` | `Fetching Homebrew data…` |
| `.../zh_CN/element/string.json` | `正在获取 Homebrew 数据…` |

**已知代价（必须写进代码注释）**：现有 `Toast` 基于 `promptAction.showToast`，**没有 close API**，
所以数据到达时 toast 无法立刻撤掉，最多再留 2s（`longToastTime = 2000`）。
需求方已接受这个代价（§3.2 D2）。

### 4.5 模块边界

```
数据层（brewcommon）                                  UI
BrewService.getCatalog() ─┐
BrewService.fetchCatalog()├─→ BrewNetNotice.willFetch(reason, detail)
BrewService.build*Page()  │         │
BrewService.hydrate*()  ──┘         ├─ 30s 去重窗口
                                    └─ Toast.showLongToast($r('app.string.brew_fetching_data'))
```

数据层直接调 UI 是**刻意的**：`brewcommon` 的定位就是共享层、本就放共享 UI 原子（handover §3.2），
而这样能把 hook 收敛到 4 处、页面层零改动。备选方案（发信号给 UI 层）更解耦，但要多一条通道 +
三个页面各接一次，且会与"分类二级页复用同一构页函数"这个事实重复 —— 记为 §12 的后续项。

---

## 5. 影响分析

### 5.1 正面

- 等待从"无解释"变成"有解释"，且**只在真的要下载时**出现（判据 #3/#4/#7/#10/#11/#12 全部排除）。
- 页面层零改动：新增 1 个工具类 + 4 个 hook + 3 条字符串。
- 判据复用 `[load]` 词表，`BrewLoadLog` 与 `BrewNetNotice` 不会漂移（同一批 reason 常量在同一个文件里定义）。

### 5.2 负面与代价

| 代价 | 说明 |
|---|---|
| toast 无法主动撤销 | 数据到了最多再留 2s（§4.4） |
| 数据层依赖 `Toast`（UI） | 与既有定位一致，但确实增加了一条 data → UI 的依赖（§4.5） |
| 纯预测式仍有残余误报 | 只剩"探针说变了、但重取其实很快"（罕见）；以及 hydrate 预测命中数后、实际有 token 在数完之后被写入缓存（无影响，只会多弹） |
| 每进程多一个静态状态 | `lastShownAt`，无持久化、无副作用 |

### 5.3 明确不受影响（避免评审时被当成风险）

| 项 | 为什么不受影响 |
|---|---|
| 首屏耗时 | `willFetch` 只做整数比较 + 一次 `showToast`（非阻塞），不 await 任何东西 |
| 数据正确性 | 不参与任何数据路径，纯旁路 |
| 落盘 key | 不新增、不改动任何 Preference key |
| `BaseHomeView` 的四态渲染 | 不动 |
| `BrewMetaSync` | 不接提示（判据 #11） |
| 离线 / `SNAPSHOT` 模式 | `BREW_DATA_SOURCE !== REMOTE` 时数据层直接早退，不会调到 hook |

---

## 6. 边界与错误处理

| 边界 | 行为 |
|---|---|
| `UIContext` 未就绪（`AppStorage` 里没有） | `Toast` 内部已处理：打 error 日志并直接返回，不抛错。`BrewNetNotice` 不需要额外判断 |
| `showToast` 抛错 | `Toast` 内部已 try/catch，只打日志 |
| 30s 窗口内的并发调用 | 静默；`lastShownAt` 的读写都在主线程（数据层都在 UI 线程发起），不需要锁 |
| hydrate 预测命中数与实际不符 | 只影响"弹不弹"，不影响任何数据行为 |
| 冷启动原点之前调用（`BrewMetaSync.start` 之前） | 不可能：H1–H4 都在页面加载路径上，晚于 splash |

---

## 7. 可观测性

`BrewNetNotice` 每次**决定弹**时打一行 info，与 `[load]` 同风格，便于"为什么弹/为什么不弹"可查：

```
[notice] kind=fetch-toast reason=<触发它的 [load] reason> shown=true|false detail=<...> at=<epoch>
```

- `shown=true` 是首次（真的弹了）；`shown=false` 是被 30s 窗口挡下的。
- 排查"该弹没弹"：看这行有没有出现、`reason` 是什么；没出现说明连 `willFetch` 都没被调到。
- 排查"不该弹却弹了"：`reason` 直接指出是哪条判据放行的。

---

## 8. 测试与验证

### 8.1 我会执行的（都是真机证据）

| # | 动作 | 判据 |
|---|---|---|
| V1 | 冷启动 + `brew_catalog` 缺失（首次安装态） | 弹一次；三页并发也只一次（`[notice]` 只有一行 `shown=true`）。⚠ 构造这个状态依赖 `devecocli run --uninstall`，而冷启动 spec §14.2 V10 已实测**它不可靠**（一次报开发者模式错误、一次成功）。若构造失败，以 V3（索引缺失）作为降级路径的代表证据，并**在报告里标注 V1 未取到** |
| V2 | 冷启动 + **全部命中缓存**（目录新鲜、索引可信、live 缓存热） | **一行 `shown=true` 都没有**（关键反例） |
| V3 | 冷启动 + `brew_meta_index` 缺失（降级路径） | 弹一次，且 `reason=degraded-prefix` |
| V4 | 目录过期但 304 命中 | **弹一次**（2026-09-23 修订：原为“不弹”）—— 探针本身就慢（304 实测可花 24s），必须提前提示 |
| V5 | 30s 窗口内二次触发 / 窗口外 | `shown=false` / `shown=true` |
| V6 | 分类二级页（`getFormulaCategories`，pageSize=100）在降级态下进入 | 弹一次（证明 H3 覆盖了二级页） |
| V7 | `devecocli log --crash --from 15m` | 无崩溃 |
| V8 | 截图（首屏出卡片前后） | toast 文案正确、不遮挡关键内容、2s 后消失 |

### 8.2 我不会声称的（诚实边界）

- **toast 的视觉位置/样式**：`promptAction.showToast` 是系统组件，位置由系统决定；
  我只验证"弹了/没弹/文案正确"，不声称像素级效果。
- **"用户感知到的等待是否变短"**：本改动不减少任何耗时，只改感知。没有可量的性能判据。
- **hypium 单测**：`devecocli` 没有 test 命令，本机跑不起来（与冷启动 spec §9.2 同一限制）。
  可以去重逻辑写成纯函数以便将来在 DevEco 里补测，但**不计入本轮证据**。
- **多语言实际渲染**：只验证资源三份齐全，不逐语言截图。

---

## 9. 验收标准

| # | 标准 |
|---|---|
| A1 | 判据 #1/#2/#6/#9 触发时，弹且仅弹一次（30s 窗口内） |
| A2 | 判据 #4/#5/#7/#8/#10/#11/#12 **一次都不弹**（V2 为证；原 A2 里的 #3 已被判据 #2 吸收，见 §13） |
| A3 | 覆盖首页三 tab 与两个分类二级页（V6 为证） |
| A4 | 页面层零改动：`brewdiscover`/`brewformulae`/`brewcasks` 的 diff 为空 |
| A5 | 不新增落盘 key；不改 `BaseHomeView`；不接 `BrewMetaSync` |
| A6 | 无崩溃 |
| A7 | 文档已同步：本 spec + `brew-handover.md` §5.3（数字）/§8.2（待办） |
| A8 | 交付时附：V1–V6 的 `[notice]` 与 `[load]` 原始日志片段 |

---

## 10. 风险与回滚

| 风险 | 概率 | 回滚 |
|---|---|---|
| 误报（探针很快却弹了） | **中**（2026-09-23 修订：判据 #3 的排除被撤销 —— 实测探针 17.4s 才是主要等待，而快速探针只是少数场景） | 删掉 `BrewNetNotice` 的调用点即可，无状态残留；或把 `BREW_CATALOG_FRESH_MS` 继续调大以减少触发频率 |
| 该弹没弹（判据口径写错） | 中（要靠 V1–V6 覆盖） | 同上；`[notice]` 日志能定位是哪条判据没放行 |
| 用户觉得 toast 吵 | 低 | 把 `BREW_NET_NOTICE_MIN_INTERVAL_MS` 调大，或只保留判据 #6（最慢的那条） |
| 整体回滚 | —— | 删除 `BrewNetNotice.ets` + 4 个调用点 + 3 条字符串；不涉及数据层与落盘，回滚面为零 |

---

## 11. 改动清单

| # | 文件 | 改动 | 性质 |
|---|---|---|---|
| 1 | `features/brewcommon/src/main/ets/util/BrewNetNotice.ets` | **新增**：`willFetch()` + 30s 去重 + `[notice]` 打点 | 新增 |
| 2 | `features/brewcommon/src/main/ets/constant/BrewConstants.ets` | 新增 `BREW_NET_NOTICE_MIN_INTERVAL_MS = 30000` | 新增常量 |
| 3 | `features/brewcommon/src/main/ets/service/BrewService.ets` | 3 个 hook（H1/H3/H4；H2 于 2026-09-23 删除） | 插入 |
| 4 | `features/brewcommon/src/main/resources/base/element/string.json` | `brew_fetching_data` | 资源 |
| 5 | `.../en_US/element/string.json` | 同上 | 资源 |
| 6 | `.../zh_CN/element/string.json` | 同上 | 资源 |
| 7 | `docs/brew-handover.md` | §5.3 数字、§8.2 待办 | 文档 |
| 8 | `features/brewcommon/src/main/ets/constant/BrewConstants.ets` | **2026-09-23**：`BREW_CATALOG_FRESH_MS` 1h → **6h**（并改正注释里被推翻的两条描述） | 改值 |

**不改**：`brewdiscover` / `brewformulae` / `brewcasks` / `abilitycommon` 的任何文件；`BaseHomeView`；
`BrewMetaSync`；`features/brewcommon/Index.ets`（本轮 UI 层不需要这个符号，不做投机性导出）；任何 Preference key。

---

## 12. 已知取舍与后续

| 取舍 | 现状 | 触发条件 |
|---|---|---|
| 数据层直接调 UI | 与 `brewcommon` 既有定位一致；hook 收敛到 4 处、页面层零改动 | 若将来 UI 层要自己控制提示形态（如换成可撤销浮层），改成"发信号 + UI 层消费" |
| toast 不可撤销 | 复用现有 `Toast` 的必然代价 | 若"数据到了 toast 还在"被反馈为问题，改 `openCustomDialog` |
| 纯预测式有残余误报 | 2026-09-23 修订：撤销判据 #3 的排除后，误报面比原设计大（探针快时会白闪） | 若被反馈误报，改成“预测 + 延迟 1.5s”（§2.3 第三行），代价是要引入计时器 |
| 不提示 `BrewMetaSync` | 它不阻塞首屏 | 若将来把索引同步挪到首屏 await 链上（当前明确不是），则必须提示 |

---

## 13. 修订（2026-09-23）：判据 #2/#3 反转 + TTL 1h → 6h

### 13.1 触发这次修订的现象

需求方在隔夜后的一次真实冷启动里观察到：

> **先转圈好几秒，然后才 toast，然后又转圈几秒（较短）就显示了。**

即 toast 落在了两段等待**中间**，哪一段都没解释到。设备日志（Discover 整页 **21.7s**）：

```
09:26:23.0   ← 冷启动，目录过期(pref-stale) → 发起 4 个端点并行探针
   ─── 17.2 秒纯转圈，一行日志都没有 ───
09:26:40.231 [notice] net-200 shown=true      ← toast 才弹（在探针的第 17.2 秒）
09:26:40.486 [load] kind=catalog_fetch ms=17437 notModified=0/4
09:26:40.498 [load] kind=live_data reason=pref fresh=0     ← 224 条 live 缓存全过期
   ─── 又转 4.1 秒 ───
09:26:44.603 [load] kind=discover_page assembled ms=21714 getCatalogMs=17611 hydrateMs=4103
09:26:44.6   ← 内容显示
```

同窗口内的 `[notice]` 全貌（唯一 `shown=true` 的是第 1 行）：

```
40.231 net-200   shown=true     ← 弹了，但在第 17.2 秒
40.498 live_docs shown=false    ← 被 30s 窗口挡下
40.500 live_docs shown=false
43.280 live_docs shown=false
43.282 live_docs shown=false
```

### 13.2 根因（四层，前两层是设计错，后两层是事实错）

| # | 根因 | 说明 |
|---|---|---|
| RC1 | **hook 位置错了** | H2 放在 `Promise.all(probes)` **之后**。可是**探针本身就是那段等待**（不是 HEAD，是带 `If-Modified-Since` 的完整 GET，4 个并行）。所以 toast 报的是"已经等完的那一段"，只解释了后面 0.25s 的 `buildCatalog`。这违反 §2.3 自己定的"**即将**等待时提示" |
| RC2 | **spec 的前提被实测推翻** | §2.2/判据 #3 写"目录过期但 304 是 0 字节、几百毫秒"，因此排除不弹。实测：4 个并行探针设备上 **17.4s**；且 304 也可能花 **24.06s**（TTFB 22.5s、0 字节）。更糟的是代码在 `notModified === probed.length` 时**提前 `return stored`，一行 notice 都不打** —— 若那天 4 个端点全 304，用户会转 24 秒圈、**全程零提示** |
| RC3 | **30s 窗口锚点错** | 窗口本身没错，错在第一个 toast 来得太晚：它把第二段（4.1s 的 live hydrate，**确实触发了 H4**）吞掉了。RC1 修好后窗口才会正确工作（t≈0 一次 toast 覆盖整轮） |
| RC4 | **底下的性能问题** | 4 个并行完整 GET 共 ~360KB，宿主机 5.2s，**设备 17.4s**。且 `BREW_CATALOG_FRESH_MS = 1h` 意味着隔夜后第一次打开必然吃这 21.7s |

### 13.3 实测数据（2026-09-23，宿主机；设备值见上）

4 个 `BREW_CATALOG_SOURCES` 端点（**全是 analytics**，不是 `formula.json`）：

| 端点 | 完整 GET | 带 `If-Modified-Since` |
|---|---|---|
| `install-on-request/homebrew-core/30d.json` | 200, 78.7KB, 2.92s | 304, 0B, **0.83s** |
| `install-on-request/homebrew-core/365d.json` | 200, 126.6KB, 5.23s | 304, 0B, **24.06s** |
| `cask-install/homebrew-cask/30d.json` | 200, 58.6KB, 2.71s | 304, 0B, **0.79s** |
| `cask-install/homebrew-cask/365d.json` | 200, 96.3KB, 2.89s | 304, 0B, **5.07s** |

**为什么 304（无 body）也能花 24 秒**：它的时间全是 **TTFB**，即"服务器花多久才决定没改"。
同一 URL、同一边缘节点、相隔几秒实测 TTFB 在 **0.90s ↔ 22.49s** 之间跳（25 倍）。
响应头给出了机制：

```
Server: GitHub.com   Via: 1.1 varnish   Cache-Control: max-age=600
core/365d   X-Cache: MISS   Age: 0     ← 边缘没副本 → 回源
```

**两条连带结论（都推翻了旧描述）**：

1. **边缘只缓存 10 分钟**（`max-age=600`），而本模块窗口是小时级 → 探针必然打在**过期的边缘副本**上 → 回源 → 慢。
2. **内容每 ~5~10 分钟重生成一代**（`Last-Modified` 在 5 分钟内从 `00:58:15` 变到 `01:38:38`）→ 小时级的 `If-Modified-Since` 基准**几乎永远对不上** → 条件请求在小时级窗口下**基本无效**。
   （保留它仍划算：未命中只多一个被忽略的头，命中时省 358KB。）

### 13.4 本次改动

| # | 改动 | 文件 |
|---|---|---|
| 1 | **通知挪到探针之前**：`getCatalog` 里 `missing` 与 `pref-stale` 两态都在启动 `fetchCatalog()` **之前**通知 | `BrewService.ets` |
| 2 | **删除 H2**（探针之后的那个通知点） | `BrewService.ets` |
| 3 | **`BREW_CATALOG_FRESH_MS` 1h → 6h** + 改正注释里被推翻的两条描述 | `BrewConstants.ets` |

选 6h 的理由：探针的成本是用户实打实等的 17 秒，而榜单最多旧 6 小时的代价用户感知不到 ——
它本来就每 10 分钟在变。6h 的含义是"隔夜后第一次打开不再吃这个等待"。

### 13.5 本次修订的诚实边界

- 上述端点耗时是**宿主机**测的（设备网络可能不同）；但模式一致（设备 17.4s vs 宿主机同批 5.2s），
  都落在同一条"高方差、边缘冷"的路上。**未在设备上逐端点计时**（探针没有 per-endpoint 打点）。
- **RC1 已在真机验证（2026-09-23）**：把 `BREW_CATALOG_FRESH_MS` 临时压到 60s 造出 stale 态后冷启动，
  实测 `[notice] reason=pref-stale shown=true` 在 `10:11:19.601`，而探针到 `10:11:35.277` 才完成
  （`catalog_fetch ms=15359`）—— **toast 比数据早 15.7 秒**，不再是“等完了才弹”。
  同窗口还顺带验证了判据 #5：第二个调用者命中 `reason=in-flight`（19.694），**没有产生第二行 notice**。
  注：压 TTL 只为造状态，判据位置与 TTL 取值无关；验证后已还原 6h。
- **“目录过期”的真实体感仍未在 6h 边界上验证**：需要真的隔 6 小时未打开后冷启动一次。
  上面是用压 TTL 造的状态，逻辑等价，但**未经真实时间流逝的确认**。
- 6h 是需求方拍板的值，不是推导出来的最优值；依据是"榜单实时性对用户无感知"这一判断，非测量。

---

### 13.6 换用 HDS SnackBar（2026-09-23，需求方提议）

§13.5 记的「toast 2000ms 而等待 15.4s」是「Toast 无 close API」的**镜像问题**：
原担心"数据到了 toast 还在"，实际是"**数据没到 toast 就没了**"。
需求方提议换成 HDS SnackBar，实测它把两个问题一起解掉：

| | Toast（旧） | HdsSnackBar（新） |
|---|---|---|
| 提示存活 | 固定 **2000ms** | **与等待等长**（实测 30.2s） |
| 覆盖等待比例 | 6.6%（2/30.2） | **100%** |
| 主动撤销 | ❌ 无 API | ✅ `dismiss()` |
| 用户自救 | — | ✅ `CLOSE_BUTTON_ONLY` 关闭按钮 |
| 系统侧渲染证据 | 无 | `SnackBarDialog: Monitor SnackBar appear/disAppear` |

关键 API（`@kit.UIDesignKit`，`@since 6.0.0(20)`；本项目 `compatibleSdkVersion = 6.1.0(23)` ✓）：

- `new HdsSnackBar(uiContext)` → `show(icon, message, operation, style)`
- **`style.duration = -1` → 常驻**（官方指南《设置常驻通知弹窗》`ui-design-snackbar-resident-notification`）
- `dismiss()`

**去重模型随之改变**：**删掉 `BREW_NET_NOTICE_MIN_INTERVAL_MS`（30s 时间窗）**，改用 `shown` 布尔量
—— "同一时刻只提示一件事"，`settle()` 之后再次 `willFetch()` 会正常重弹。
语义比时间窗更贴合意图（时间窗是当时为了压 Toast 噪声才引入的权宜设计）。

新增 `settle()` 与 `willFetch()` **成对**，挂在两处「数据到达」判据上：

- `BrewService.logPageLoad()`（两个浏览页共用这一个函数）
- `BrewRepository.getDiscoverPage()` 的 `discover_page assembled`

**只在整页组装完才 settle** —— 在 `fetchCatalog` 那一步就撤，会把后面的 live hydrate 漏在提示之外。

真机验证（设备侧）：

```
10:42:31.554  [notice] action=show reason=pref-stale shown=true
10:42:31.623  SnackBarDialog: Monitor SnackBar appear start     ← 系统侧，非我方打点
10:42:32.157  SnackBarDialog: Monitor SnackBar appear end
   ─── 29.5s 等待（getCatalogMs=30172，本次上游更慢）───
10:43:01.724  [notice] action=dismiss reason=discover_page dismissed=true
10:43:01.725  SnackBarDialog: Monitor SnackBar disAppear start
10:43:02.035  SnackBarDialog: Monitor SnackBar disAppear end
```

（第二行 `dismissed=false` 是 Discover 页双构建的第二次调用，幂等正确。）

**诚实边界**：仍**没有像素级截图** —— 截图时设备停在屏保（黑屏大时钟），
所以系统侧的 `SnackBarDialog` 生命周期日志是"对话框确实被创建并显示"的证据，
**不等于**"人眼在应用窗口里看到它"。

**回滚**：删掉 `settle()` 的两个调用点即可退回"只弹不撤"；把 `duration` 改成 `>0`
即可退回定时形态。`BrewNetNotice` 的对外接口（`willFetch`）未变，回滚面很小。

---

### 13.7 已知缺陷：拖动窗口时提示会闪现（2026-09-23，需求方发现；**根因已定位**）

**现象**（需求方原话）：*"在我尝试移动窗口的时候，snack 会消失然后闪现出来"*。

#### 根因：在 HDS 侧，不在我们的代码

拖动窗口时，HDS 自己的 `SnackBarWindowSize` 模块对**每一次窗口位置变化**都执行"先撤掉再重弹"：

```
A03900/com.huawei.hmos.sample/SnackBarWindowSize: Monitor changes in window width: 2090, window height: 1394
A03900/com.huawei.hmos.sample/SnackBarWindowSize: updateDialogOffset: dismiss and re-show dialog
```

- 一次拖动中 `updateDialogOffset: dismiss and re-show dialog` 出现 **205 次**，间隔 **~74ms**（13.5 次/秒）；
- 而**窗口尺寸每次都是 2090×1394、没有变** —— 所以驱动它的是**位置（offset）变化**，即拖动本身；
- 同一时段 `SnackBarDialog: appear/disAppear` 共 156 次（7.8 次/秒），与之对应。

**我们只弹一次，HDS 在拖动期间把它撤了又弹 205 次** —— 用户看到的就是"消失然后闪现"。

#### 已排除①：不是「新建了多个 SnackBar 实例」

需求方提出这个怀疑后，加了临时计数器实测（`ctorCount` + `show()` 计数）：

```
11:22:37.876 INSTR new HdsSnackBar(), ctorCount=1 uiContextId=present
11:22:37.876 INSTR show() call #1 ctorCount=1
11:22:37.876 [notice] action=show reason=pref-stale shown=true alreadyShown=false
```

**`ctorCount=1`、`show()` 只被调用 1 次。** 代码上也是明确的：

```ts
private static bar: HdsSnackBar | undefined = undefined;
if (BrewNetNotice.bar === undefined) { BrewNetNotice.bar = new HdsSnackBar(uiContext); }
```

静态缓存的单实例，且 `willFetch()` 有 `shown` 守卫。**只有一个对话框，是 HDS 在反复撤/弹它。**

#### 已排除②：不是「模糊策略切换」

原假设是 `blurStrategy` 默认的 `ADAPTIVE`（官方定义"根据系统策略调整，三档：精美/轻柔/流畅"）
在拖动时降档导致重建。实测**不支持**：

| 变体 | 拖动期间 churn 速率 |
|---|---|
| `BlurStrategy.ENABLE` | ~12.8 事件/秒 |
| 默认 `ADAPTIVE` | ~7.8 事件/秒 |

同一量级（差异可由拖动强度解释），且根因日志 `updateDialogOffset` 与模糊无关。
所以 `blurStrategy` **保持平台默认**，不做改动。

⚠ **过程记录（一个方法学教训）**：这两次计数的**原始对比曾经是无效的** —— 第一次报的
"拖动时 5 次 appear" 来自 `tail -40` 的**截断输出**，不是全量计数。改成
**全量计数 + 速率（事件/秒）**（速率与拖动时长无关，才可跨变体比较）之后才站得住。
同一教训也适用于我第一次的误判：我把需求方的一次拖动读成了"启动时的 churn"。

#### 结论与现状

- **不修**：这是 HDS 在窗口移动时的内部实现选择（`dismiss and re-show`），
  应用侧无法通过 `HdsSnackBar` 的公开 API 关闭它。
- **影响面很小**：只发生在用户主动拖动窗口期间；提示本身是瞬时通知。
  已验证的对照：**不拖动窗口时 `appear` 恰好 1 次、churn 0 次。**
- **取舍**：若要彻底避免，只能放弃"对话框"形态的提示（退回 `Toast`），
  但那样就失去"常驻 + 可撤销"，即 §13.6 的全部收益。
  **本设计选择：接受拖动时的闪烁，换取提示覆盖整个 15~30s 等待。**
