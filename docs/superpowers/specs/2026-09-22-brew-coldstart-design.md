# brew 应用市场 · Formulae/Casks 冷启动优化（spec）

| 项 | 值 |
|---|---|
| 状态 | 待评审 |
| 日期 | 2026-09-22 |
| 分支 | `refactor/datasource`（`953ab15` + 本次 mock 清理两条提交之上） |
| 需求 | 「我希望做一下 formulae 和 casks 的冷启动加载速度优化，如果有必要的话可以考虑硬盘缓存」 |
| 关联文档 | `brew-catalog-fullsync-spec.md`（元数据索引的来源，§4.4 的「补位」语义本 spec 要收紧）、`brew-api-design.md`（§9.13 在途去重、§10.4.1 每页实例状态）、`brew-handover.md`（§5.3 实测数字、§8.5 方法论）、官方 `最佳实践/…/bpta-application-cold-start-optimization` |

需求方在开工前确认的四条口径 + 一条授权：

1. **范围**：App 冷启动 → Formulae/Casks **首屏可见**（不是「点页签 → 列表可见」，所以可以把开销挪到后台）。
2. **成功标准**：**先量基线再定**（本文 §2 已量，§1.1 的门槛待评审）。
3. **接受 stale-while-revalidate**：「数据按天变不急」。
4. **无网 / 首次安装保持空态**，不做内置回落快照（与 C 档删除 page 快照的现状一致）。
5. **授权**：可以改首屏页签展示路径，并打日志测速。

---

## 1. 目标与非目标

### 1.1 目标

| # | 目标 | 可验证形式 |
|---|---|---|
| G1 | 冷启动首屏不劣于门槛。**基线已量：17.7–18.8 s**（§2.2）；官方口径 **>1100 ms 判为启动缓慢**，故门槛取 **≤ 1100 ms**（评审可改） | `[BrewService] browse formula built … (…ms)` 的 ms 值 + `stateSet ts` − `ability onCreate ts` |
| G2 | 首屏**零请求**（索引可信时） | `browse … built` 行里 `hydrate 0`；`statsLine()` 的 `dl=0` 与 `failed` 增量均为 0 |
| G3 | **输出不变**：卡片集合、顺序、分类计数、分类内名次逐字节一致 | §2.2 的 `dist` 字段（`terminal=837 devtools=838 …`）在改动前后一致 |
| G4 | 不新增落盘 key、不做页面级缓存 | 代码无新增 `PreferenceManager.setValue` 调用点 |

### 1.2 非目标（本轮明确不做，避免被当成漏做）

| 不做 | 原因 |
|---|---|
| **「硬盘缓存」本身** | 实测下来它答错了题 —— 需要的数据**已经在硬盘上**，而且读它只要 17–22 ms（§2.3）。详见 §4.3 |
| 持久化分类结果（`token → categoryKey`） | 实测分类只占 **420 ms**，不值得为它引入一套"词表版本失效"机制。列为后续（§13） |
| 持久化 404 负缓存 | 本方案下主路径**不发**那批必然 404 的请求，负缓存失去适用场景。详见 §4.4 |
| `import lazy` / 桶文件收敛 | 官方点名的冷启动项（`brewcommon/Index.ets` 24 条 export，`SplashViewModel` 拉起整个 brew 数据层），但**本次未量到它的耗时**，不能凭"官方说它重要"就改结构。列为后续（§13） |
| 每次启动 51 MB 元数据同步加 HEAD 探针 | 它是**后台**任务，不在首屏 await 链上。本次未量到它抢 CPU/网络的量级。列为后续（§13） |
| 改详情页 / Discover / 搜索 / Mine 的 hydrate | 它们各有必须整份 doc 的理由（详情页要依赖/bottle/artifacts；榜单成员来自目录现算）。本 spec 只动浏览页首屏 |
| 首次安装的内置回落快照 | 需求方口径 4 |
| 结构性双构建的**结构**修复 | 能省一半分类开销，但它是**照抄参考实现**（`ComponentHomeView` 同款，组件页也双载）。改结构会动到 `HdsNavigation` 的根内容语义，风险与收益不成比例 → 只做**去重**，不做重构（§5.4） |

---

## 2. 实测基线（真机，两轮可复现）

### 2.1 口径与探针

口径 = **`PcAbility.onCreate` → 卡片数据进 VM state**。为了量它，本次加了 5 处临时探针（全部带 `[perf-probe]` 标记，见 §12 的收尾项），并**临时把 `DEFAULT_TAB` 从 `DISCOVER` 改成 `FORMULAE`**（否则冷启动落在发现页，量不到目标页签）。

| 探针 | 位置 | 打什么 |
|---|---|---|
| `ability onCreate ts` / `windowStageCreate ts` | `products/pc/.../pcability/PcAbility.ets` | 绝对 epoch ms 锚点 |
| `meta index pref read+parse` | `BrewMetaSync.ensureIndex()` | 主线程 `getSync` + `JSON.parse` 的 ms |
| `catalog pref read+parse` | `BrewService.ensureCatalog()` | 同上 |
| `formulaPage rows/groupMs/cardMs` | `BrewBrowseBuilder.formulaPage()` | 逐条分类+建 item / 建卡 分开计时 |
| `browse formula built … [perf-probe …]` | `BrewService.buildFormulaPage()` | 四段分解 + 绝对 `tStart` |
| `stateSet ts` | `BrewFormulaHomeViewModel.loadFormulaPage()` | 数据进 state |

`buildFormulaPage` 原先的计时**从 Preference 读完之后才开始**（`startAt` 在 `ensureCatalog`/`descOf` 之后），所以历史日志里的 ms 一直是低估值；本次把 `tStart` 提到函数第一行。

### 2.2 时间线

**Run 1**（锚点 `ts=1790064235987`）：

| 事件 | 绝对 ts | 相对锚点 |
|---|---|---|
| `ability onCreate` | 1790064235987 | 0 |
| `windowStageCreate` | 1790064236034 | +47 ms |
| `meta index` 读+解析（8613+5103 条，**readMs=17**） | 1790064236402 | +415 ms |
| `meta sync: start, cached formula=8613 cask=5103` | 1790064236423 | +436 ms |
| `catalog` 读+解析（7392+5440 条，**readMs=22**） | 1790064236710 | +723 ms |
| `live cache loaded, 416 entries` | 1790064236758 | +771 ms |
| **`browse formula built`（build #1，tStart=…236710）** | 1790064253699 | **+17 712 ms** |
| **`loadFormulaPage success`（build #2 完成）** | 1790064254113 | **+18 126 ms** |

**Run 2**（锚点 `ts=1790064290144`）：`readMs=17` / `readMs=19`；`browse formula built` **+18 343 ms**；`stateSet` **+18 759 ms**。

两轮结构完全一致，故基线取 **17.7–18.8 s**。

拆解（run 1）：

| 段 | 实测 | 占比 |
|---|---|---|
| onCreate → windowStageCreate | 47 ms | 0.3% |
| → 索引读+解析 | 368 ms（**其中解析 17 ms**） | 2.1% |
| → 目录读+解析 | 308 ms（**其中解析 22 ms**） | 1.7% |
| → `live cache loaded` | 26 ms | 0.1% |
| → **`hydrate+classify`** | **16 961 ms** | **95.8%** |
| → 进 state | 15 ms | 0.1% |
| **合计** | **17 726 ms** | |

再拆 `hydrate+classify` 内部：

```
[BrewBrowseBuilder] formulaPage rows=7299 groupMs=420 cardMs=2 cards=9
[BrewService] browse formula built, 7299/7392 tokens ready
  (catalog 7392, index 7299, hydrate 93), 9 cards, 7299 entries, 16989ms
  [tStart=1790064236710 catalogMs=22 indexMs=0 filterMs=6 hydrate+classifyMs=16961]
  | terminal=837 devtools=838 network=286 data=228 cloudnative=164 media=274
    ai=189 lib=624 system=3859
  | session hit=0 renewed=0 notModified=0 dl=0(cond=0 nocond=0) failed=138 catalogFailed=0
```

- **分类 + 建 item = 396~420 ms**（`groupMs`）
- **建卡 = 2~3 ms**
- 所以 16 961 − 420 ≈ **16.5 s 全在 `hydrate 93`（93 个 HTTP 请求）**
- `dl=0`：**成功的下载数 = 0**。`ready` 仍是 7299，与 hydrate 之前的 `covered=7299` 完全相同
- **16.5 秒换来 0 条数据**

### 2.3 被实测推翻的假设（重要：写代码时不要按这些直觉走）

| 我（和评审）的直觉 | 实测 |
|---|---|
| 1 MB 索引主线程 `JSON.parse` 是瓶颈 | **17 ms** |
| 550 KB 目录主线程 `JSON.parse` | **19–22 ms** |
| 7500 次 `BrewTaxonomy.categoryOf` 是瓶颈 | **396–420 ms** |
| 建 7500 个 `BrewPackageItem` 是瓶颈 | 含在上面 420 ms 内 |
| 「需要引入硬盘缓存」 | **需要的数据已经在硬盘上，而且读它很快** |

### 2.4 根因（三条叠加，全部有日志证据）

**① 目录里有 93 个上游不存在的 token。**
两个数据集的语义不同：

| 来源 | 语义 | 条数 |
|---|---|---|
| `brew_catalog`（analytics 4 端点） | **谁被安装过**（含已下架、含测试包） | formula 7392 |
| `brew_meta_index`（`formula.json` 全量同步） | **上游现在有哪些包** | formula 8613 |

```
[BrewService] hydrate failed, token=testball,        unexpected status 404
[BrewService] hydrate failed, token=testball1,       unexpected status 404
[BrewService] hydrate failed, token=testball_bottle, unexpected status 404
[BrewService] hydrate failed, token=plink1,          unexpected status 404
[BrewService] hydrate failed, token=terraform,       unexpected status 404
[BrewService] hydrate failed, token=sdl2,            unexpected status 404
```

`testball*` / `plink1` 是 Homebrew 自己的**测试 fixture**，`terraform` / `sdl2` / `sentry-cli` 是改名或下架的旧 token。它们必然 404。

**② 404 的负缓存只在内存里。** 代码里这道闸是通的（`BrewService:380`）：

```ts
if (res.code === 404 || res.code === 410) {
  BrewService.markMissing(cacheKey);   // ← 确实被调用了
  Logger.info(TAG, `live doc absent upstream (${res.code}), negative-cached, key=...`);
}
```

但 `markMissing` 写的是**进程内静态 `Map`**（`BrewService:475` `missCache`），进程一退就没了。**而冷启动恰恰是它唯一有用的场景** —— 于是每个新进程都要重新付一遍 16.5 s。两轮 16.99 s / 17.66 s 就是这么来的。

**③ 首屏 await 全量 hydrate，而且同一页并发构建两次。**
`buildFormulaPage` 的 Promise 链必须等 93 个请求（并发 6，约 15 轮）全部结束才返回。而 `BrewFormulaHomeView` **同时**渲染了两份 `BrewFormulaBaseView`：

```
BrewFormulaHomeView.build()
└─ HdsNavigation(this.brewPageContext.navPathStack) {
     BrewFormulaBaseView()          // ← 根内容，第 1 份
   }
   而 aboutToAppear 又 push 了 BREW_FORMULA_LIST_VIEW
     └─ BrewFormulaListView.build() { BrewFormulaBaseView() }   // ← 第 2 份
```

两份的 `aboutToAppear` 都派发 `LOAD_FORMULA_PAGE`（间隔 155 ms）。两个 build 都在任何 404 落进 `missCache` **之前**就跑完了 `splitMissing` → **93 × 2 = 186 次请求**。

> 说明：`BaseHomeView.reloadData` 只在 `LoadingStatus.FAILED` / `NO_NETWORK` 的重试按钮里被调用（`BaseHomeView.ets:39,46`），**不是**双构建的原因 —— 这条已排除，避免误改。
>
> 这个"壳 + 目的地各渲染一份同一视图"的写法是**照抄参考实现**的（`BrewFormulaHomeView` 注释自称"与 `ComponentHomeView` 同构"），组件页同样双载（日志里 `getComponentList` 5 次 / `Load data success` 4 次可印证）。所以它是**继承来的结构性重复**，不是 brew 引入的 bug。

---

## 3. 已核准的事实（写代码时不用再查）

### 3.1 hydrate 的全部触发点

**层 1：批量**（`hydrateFormulaDocs` / `hydrateCaskDocs`，`BrewService:1076,1083`）

| 调用点 | 触发条件 |
|---|---|
| `BrewService.buildFormulaPage:909` / `buildCaskPage:954`（浏览页首页 **+ 分类二级页**，二级页复用 `getFormulaPage`） | `missing = 目录行 ∩ token ∉ 索引`，取前 `BREW_BROWSE_HYDRATE_LIMIT(100)` 个、再剔除 `missCache` 里的幽灵；`missing.length > 0` 即触发。**或**索引完全不可用（`covered === 0`）→ 前 100 条全部 hydrate |
| `BrewRepository.hydratePage:598,599`（Discover 首页 + 榜单二级页） | `BREW_DATA_SOURCE === REMOTE` 且 `page.boards` 非空 → 对 6 张榜的全部成员 hydrate |
| `BrewRepository.getSameCategoryPackages`（详情页「同分类其他包」） | **间接**：→ `getCategoryPackages` → `getFormulaCategories` → `getFormulaPage` → **整页 hydrate**（`brew-api-design.md` §9.13 记过这个坑） |

**层 2：单条**（`getLiveFormulaDoc` / `getLiveCaskDoc`）

| 调用点 | 触发条件 |
|---|---|
| `BrewRepository.getFormulaDetail:124` / `getCaskDetail:273` | 详情页主体，1 个 token |

**不触发 hydrate 的**：搜索（`BrewSearchEngine` 只读目录 + 索引，零请求）、Mine 的本机包（读 rawfile）、索引覆盖的浏览条目。

**抑制条件**：TTL 缓存命中（`brew_live_data`，1 h，日志 `session hit`）、在途去重（`inFlight`）、负缓存（404/410，6 h TTL，**仅进程内**）、数据集探针 304。

### 3.2 数据层接口（本 spec 依赖的）

| 事实 | 位置 |
|---|---|
| `BrewMetaSync.descOf(kind): Record<string, string>` —— **同步、无网络**，内存有就用内存、否则读一次 Preference | `BrewMetaSync.ets:262` |
| `BrewMetaSync.ready(): boolean` —— `formula` 或 `cask` 任一非空 | `BrewMetaSync.ets:268` |
| 索引**按 kind 分表**（`BrewMetaIndex = {ts, formula, cask}`） | `BrewMetaSync.ets:60` |
| **一个 kind 的表永远是"整份文件扫完"的产物**：`syncKind()` 只在 `out.ok && out.pairs > 0` 时才返回新表，否则返回 `undefined` 让调用方保留旧表 | `BrewMetaSync.ets:322,335` |
| `BrewService.browseRows(catalog, kind)` → `catalog.topTokens[kind]`，已按 30d 安装量降序、**不裁切**；是 `private static` | `BrewService.ets:1046` |
| `CatalogEntry = {token, vol30d, vol365d, prior, velocity, score}` | `BrewService.ets:120` |
| `BrewBrowseBuilder.descOf(token, descIndex, docDesc)` —— `desc` 的**唯一**取数口径（索引优先、doc 补位） | `BrewBrowseBuilder.ets:205` |
| `BrewTaxonomy.categoryOf(kind, token, desc)` —— 策展覆盖 → 关键词 → 主题词 → 形态兜底 | `BrewTaxonomy.ets:350` |
| 目录已有 `catalogInFlight` 在途去重（**本 spec 的构建去重照抄这个模式**） | `BrewService.ets:248,623` |

### 3.3 关键推论：`covered > 0` 是**可靠**的"索引完整"判据

因为一个 kind 的表是**原子地**由"整份大文件扫描"产出的（3.2 第 4 条），不存在"写了一半的表"。所以只要某 kind 的表非空，它就是**那次全量扫描的完整结果**（只是可能来自更早的一次同步 —— 那就是需求方已接受的 staleness）。

这条推论是 §5.1 闸门可以取很松的值的原因，也是我一度想用 `covered/all ≥ 0.9` 又放弃的原因：**cask 天然覆盖率低**（`cask.json` 有 2 645 条 `desc: null`，落盘时故意不写空串，见 `brew-catalog-fullsync-spec.md` §4.6③），用比例做闸门会把 cask 误判成"索引不可信"而永远走降级路径。

---

## 4. 方案与决策

### 4.1 三个候选

| 方案 | 做法 | 首屏 | 代价 |
|---|---|---|---|
| **A. 索引即存在性权威** | `candidates = 目录 ∩ 索引`，首屏不发请求 | 17.7 s → ~0.9 s | 上游新增、索引尚未包含的包晚一次构页出现 |
| B. 持久化 404 负缓存 | `missCache` 落盘 | 首次仍 17.7 s，之后 0 | 首次体验不变；186 次请求照发 |
| C. 首屏不 await hydrate | 先渲染索引覆盖的部分，后台补完再 patch | 同 A | 二次渲染 / 名次上屏后变化 / 要避开 §10.4.1 的坑 |

### 4.2 决策：做 **A**，把 C 收敛进 A；B 不做

**为什么 C 被收敛掉（写 spec 过程中改的主意，记录在此以免评审时以为是遗漏）：**

C 的全部价值是"**不 await** 那 93 个请求"。但实测显示这 93 个在索引可信时**贡献为 0**（`dl=0`）。于是比"不 await"更彻底、且更简单的做法是 —— **根本不发**。A 直接达成了 C 想要的效果，还省掉了 C 的全部风险（二次渲染、名次漂移、每页实例状态的坑）。

所以本 spec 的最终形态是 **A + 双构建去重**。

**为什么 B 不做：** A 之后主路径不发那批请求，负缓存失去适用场景（§4.4）。

**为什么 C 的语义没丢：** 需要 hydrate "补位"的窗口（索引不可信）由 §5.3 的降级路径**原样保留** —— 那里 hydrate 依然 await、依然走现有预算与并发。也就是说 C 所保护的"新包能被补位"并没有被删掉，只是它只在**索引不可信**时生效，而那时它是有意义的（那些 token 是真包，hydrate 会成功）。

### 4.3 为什么「硬盘缓存」答错了题

需求方说"如果有必要的话可以考虑硬盘缓存"。实测表明**没必要**，理由是三条事实：

1. **需要的数据已经在硬盘上了**：目录（`brew_catalog`）与 `token → desc` 索引（`brew_meta_index`）都是 `PreferenceManager` 落的盘 —— `Preference` 就是硬盘。
2. **读它很快**：1 MB 索引 17 ms、550 KB 目录 19–22 ms。换任何别的存储形式（`fileIo`、二进制、分片）都换不来有意义的收益。
3. **真正的 16.5 s 不在 I/O，在"发了 186 个注定失败的请求，还要等它们全部结束"** —— 这是**语义问题**（把 analytics 的"装过"当成了 `formula.json` 的"存在"），不是存储问题。

顺带排除一个相邻假设：`brew_live_data`（416 条**整份 doc**，按文档记录的"单条 raw 3–6 KB"估算约 **1.3–2.5 MB**，未实测）也走主线程整份解析，但它**只在真发生 hydrate 时**才被读（`BrewService:309`），A 之后主路径不再读它。

### 4.4 为什么不需要持久化负缓存

负缓存（`missCache`）解决的问题是"**同一次会话内**别把同一个 404 打两遍"。它跨进程失效之所以致命，是因为**每个冷启动都会重新发那 93 个请求**。A 把那 93 个请求整个去掉了 —— 需要被抑制的请求不存在了，抑制器自然也就不需要落盘。

保留现状的理由还有一个：`missCache` 是**纯加速结构**，不落盘意味着它永远不会成为"数据不一致"的来源（落盘就要处理 TTL 过期、版本升级、`brew_live_data` 缓存命中与负缓存冲突这类问题）。不引入它，spec 的失效面为零。

---

## 5. 设计

### 5.1 改动点 1：索引可信度闸门

在 `buildFormulaPage` / `buildCaskPage` 里，把"候选集怎么取"这件事从**一个三元表达式**升级成**一次显式判定 + 一条日志**：

```ts
const all: CatalogEntry[] = BrewService.browseRows(catalog, kind);
const descIndex: Record<string, string> = BrewMetaSync.descOf(kind);
const covered: number = all.filter((row: CatalogEntry) => descIndex[row.token] !== undefined).length;

// 索引可信 = 该 kind 的索引非空，且覆盖量至少够一页。
// 为什么"非空即可信"：一个 kind 的表是原子地产出的（整份大文件扫完才写），不存在半张表（§3.3）。
// 为什么还要 ≥ 一页：真出现"表非空但覆盖率极低"（例如上游改了标识键导致扫出少量错配），
// 此时"前 100 条 + 逐条 hydrate"比"只显示这几十条"更有用 —— 与改动前的行为一致。
const trusted: boolean = covered >= BREW_INDEX_MIN_TRUST;
```

`BREW_INDEX_MIN_TRUST` 取 `BREW_BROWSE_HYDRATE_LIMIT`（100）同值，避免引入新的魔术数字。

### 5.2 改动点 2：主路径（索引可信）

```ts
// BEFORE
const candidates: CatalogEntry[] = covered > 0 ? all : all.slice(0, BREW_BROWSE_HYDRATE_LIMIT);
const split = BrewService.splitMissing(candidates, descIndex, kind);   // → 93 个请求
const docsPromise = split.tokens.length > 0 ? this.hydrateXxxDocs(split.tokens, BREW_BROWSE_HYDRATE_MS)
                                           : Promise.resolve({});

// AFTER（trusted）
// 索引是从 formula.json / cask.json（上游"存在性"的权威清单）抽的；
// 它没有的 token 就是上游没有的 —— 既然已经知道答案，就不该再去问一遍。
const candidates: CatalogEntry[] = all.filter((row: CatalogEntry) => descIndex[row.token] !== undefined);
const split: MissingSplit = { tokens: [], ghosts: 0 };   // ← 显式短路，missing 恒为空
const docs: Record<string, LiveFormulaDoc> = {};         // 主路径零请求
```

其余部分（`ready` 过滤、`markMissing` 空转、`BrewBrowseBuilder.formulaPage`）**一行不动** —— 这是 G3「输出不变」在代码上的保证：`ready` 的输入集合与顺序和改动前完全相同。

### 5.3 改动点 3：降级路径（索引不可信）

```ts
// AFTER（!trusted）：与改动前的代码**逐字等价**
const candidates: CatalogEntry[] = covered > 0 ? all : all.slice(0, BREW_BROWSE_HYDRATE_LIMIT);
const split = BrewService.splitMissing(candidates, descIndex, kind);
const docsPromise = split.tokens.length > 0 ? this.hydrateXxxDocs(split.tokens, BREW_BROWSE_HYDRATE_MS)
                                           : Promise.resolve({});
```

> **review 后修正（2026-09-22）**：初稿在 `!trusted` 时一律用 `all.slice(0, BREW_BROWSE_HYDRATE_LIMIT)` ——
> **这漏掉了旧代码在 `covered ∈ [1, 99]` 时用的是目录全量这一分支**（旧式是 `covered > 0 ? all : slice`）。
> 后果：索引只扫出几十条时，索引命中的条目若排名在 100 名之外就整片消失（离线时表现为空页），
> 比改动前**更差**。已改回 `covered > 0 ? all : all.slice(0, LIMIT)`。
>
> 于是 `!trusted` 与改动前**逐字等价**，唯一的行为差异只存在于 `trusted` 分支 ——
> "降级路径不改"从一句口号变成了可核对的事实（这也是 A5 的依据）。

**不简化它**：这条路径是首次安装（索引为空、但目录已有）与索引异常的兜底，它的语义是**请求预算**（`brew-catalog-fullsync-spec.md` §4.5 已写死这句话），不是展示上限。

> 首次安装时目录也是空的（`catalog === undefined` → 函数提前 `return undefined` → UI 空态），所以这条路径实际只在"目录有、索引坏或没同步成功"时命中。**保留，但不为它做优化**。

### 5.4 改动点 4：并发构建去重

在 `BrewService` 加一个与既有 `catalogInFlight`（`BrewService:248`）**同款**的在途表：

```ts
/** 在途的浏览页构建。同一页会被构建两次（§2.4③），第二个调用复用第一个的 Promise */
private static formulaPageInFlight: Promise<BrewPageData<BrewFormulaPageData> | undefined> | undefined =
  undefined;
private static formulaPageInFlightPageSize: number = 0;   // join 必须要 pageSize 也相同
private static formulaPageInFlightAt: number = 0;         // join 的时效守卫
private static formulaPageInFlightId: number = 0;         // 递增序号，见下
// cask 同款三个字段
```

**刻意用具名字段而不是 `Map<string, Promise<…>>`**：ArkTS 对泛型/`unknown` 的 `as` 转换比 TS 严，用 `Map` 就得在取出时转型，那是编译期过、运行期才暴露的那类写法。具名字段各自带完整类型，零转型。

判据与注意点：

- 复用只发生在**同一进程、同一批**内；`Promise` 完成后按序号置回 `undefined`，**不做结果缓存** —— 这是"在途去重"，不是页面缓存（`brew-handover.md` §5.1「Discover 不吃 Preference 缓存」那条决策不受影响）。
- ⚠ **`pageSize` 必须并进 join 判据。初稿写的是"两个调用点 pageSize 相同，所以复用安全" —— 这句是错的**：首页是 `BaseHomeViewModel.pageSize = 30`，而详情页 `alignCategoryRank` 与分类二级页走 `SIBLING_PAGE_SIZE = 100`（`BrewRepository.ets:54,168,209,317,354`），**两者今天就会并发**。已实现为 `InFlightPageSize === pageSize` 才 join，否则信封里的 `pageSize/totalSize` 会是错的那一份。
- ⚠ **需要时效守卫**（`BREW_PAGE_INFLIGHT_JOIN_MS`）：`hydrate` 的截止时间只在**每个 worker 取下一个 token 之前**检查，末尾却 `Promise.all` 等所有 lane —— 若某个 `BrewHttp.request` 永不 settle（平台层面），整个构建就永不 settle。没有守卫的话那个死 Promise 会永久留在字段里，之后每次构页（含重进页签、失败页的重试按钮）都 join 它 → 页面永久停在 LOADING 直到重启 App，**比改动前更糟**（改动前只是慢，重试会重新发起）。这是新增去重欠下的债，必须当场还。
- ⚠ **解析出的 page 对象是共享的**：多个调用方拿到同一个 `cards` 数组与同一批 `BrewPackageItem`（改动前每次构建都产出独立副本）。目前消费点全是只读（`setDataArray` 只存引用、仓库层只 `find/filter/slice`），所以输出不变；但**将来任何一处对 `formulaContents` 做 `sort`/`splice` 就会污染另一个视图** —— 消费者必须只读。
- 只做**去重**，不修**结构**：`BrewFormulaHomeView` 同时渲染壳与目的地两份 `BrewFormulaBaseView` 是照抄参考实现的写法（§2.4③ 说明），改它要动 `HdsNavigation` 的根内容语义，风险不成比例。

### 5.5 改动点 5：可观测性（见 §7）

---

## 6. 影响分析

### 6.1 正面

1. **首屏 17.7 s → 预计 ~0.9 s**（22 ms 目录 + 420 ms 分类 + 15 ms 进 state + 框架/首帧开销）；双构建去重后再省约 420 ms
2. **冷启动请求数 186 → 0**（G2）
3. 不再每次启动对公共源打 93 个必然 404 的请求（礼貌性）
4. **顺带修 cask**：`cask.json` 有 2 645 条 `desc: null`，落盘时故意不写空串 → 这些 token 永远在 `missing` 里。今天它们**每轮都要被 hydrate 一遍**（拿到 doc 但 desc 为空 → 才 `markMissing`）；A 之后连这一轮也省掉。**所以 cask 的收益预计比 formula 更大**（待 §9 V7 实测确认）
5. `brew_live_data`（1.5–2 MB 整份解析）主路径不再被读

### 6.2 负面与代价

| # | 代价 | 缓解 |
|---|---|---|
| N1 | **上游新增的包在首屏消失**，直到下一次元数据同步后的下一次构页 | ① 同步每次进程启动都跑（后台 ~21.7 s），而页面 0.7 s 就构建完 —— 所以"本次冷启动看不到、**重进页签能看到**"（`descOf()` 读的是内存里已被替换的新索引）；② 需求方已接受 stale-while-revalidate；③ 若这条被实测证明会造成可观察损失，回退方式是 §5.3 已有的降级路径（扩成"部分补位"） |
| N2 | 可观测性被削弱：`hydrate 93` 这个"看得见的浪费"变成了 `dropped 93` | §7 强制要求把 `dropped` 打进日志，并**在 spec 里写清它有两种成因**（幽灵 / `null desc`），避免下次有人把 cask 的 2 645 当异常 |
| N3 | 双构建只是被**去重**，结构仍在 | §1.2 已列为非目标；去重后代价从 2×420 ms 降到 420 ms |
| N4 | 降级路径仍在（保留 = 保留了一份复杂度） | 它是审计过的现有代码，本 spec 不改它，净增复杂度为 0 |

### 6.3 正确性（逐项）

**核心结论：在本次测量的数据下，A 不改变任何输出。**

```
改动前：candidates = 目录全量 7392  →  ready = filter(有 desc)  = 7299
改动后：candidates = 目录 ∩ 索引 = 7299  →  ready                = 7299
```

同一个集合、同一个顺序（都保持目录的 30d 安装量降序）→ 卡片集合、`itemCount`、`categoryRank`/`categorySize`、`styleType`、卡片数 **逐字节一致**。这就是 G3 的判据（§2.2 的 `dist` 字段应保持 `terminal=837 devtools=838 network=286 data=228 cloudnative=164 media=274 ai=189 lib=624 system=3859`）。

| 正确性维度 | 结论 | 依据 |
|---|---|---|
| 分类结果 | **不变** | `BrewTaxonomy.categoryOf(kind, token, desc)` 是**逐条独立**的，无跨条依赖；被丢掉的 93 条今天也没进 `ready`，不参与任何计数 |
| 分类内名次 / `categorySize` | **不变** | 那 93 条今天就没进 `ready`（`ready` 的输入与改动后完全相同） |
| 卡片顺序 / 版面 | **不变** | `BrewBrowseBuilder.formulaPage` 一行未改，输入集合与顺序相同 |
| 详情页名次一致性 | **不变** | 详情页 `alignCategoryRank` 读的是同一次构建的浏览集 |
| 索引的"存在性权威"是否成立 | **成立** | 索引来自 `formula.json` 全量；实测 formula **8 611/8 611、skip 0、desc 不一致 0**（整包对账）；cask 5 100 + 2 661 全是应跳过的（2 645 个 `desc: null` + 16 个 `variations` 嵌套） |
| 降级路径 | **语义不变** | §5.3 逐字保留 |
| 双构建去重 | **输出不变** | 两次调用参数相同（`currentPage`/`pageSize` 同源），结果幂等 |

**唯一的行为差异**，需要评审确认可接受：

> **"上游新增、且索引尚未包含"的包，在首屏消失，直到下一次元数据同步后的下一次构页。**

实测这类包在本次数据里是 **0 个**（93 个全部 404，`dl=0`）。

### 6.4 明确不受影响（避免评审时被当成风险）

| 项 | 为什么 |
|---|---|
| 详情页 / Discover / 搜索 / Mine / 本机包 | 本 spec 只改 `buildFormulaPage` / `buildCaskPage` 的候选集取法 + 一个在途表 |
| 元数据同步（`BrewMetaSync`） | **完全不改**：不新增 key、不改同步策略、不改扫描器 |
| 目录（`BrewCatalog`） | 不改：TTL、探针、榜单算法都不动 |
| `brew_live_data` 的 TTL 与语义 | 不改：主路径不再读它，但详情页与 Discover 照旧 |
| 落盘 key 数量 | 不增（G4） |

---

## 7. 可观测性（改动的一部分，不是可选项）

`browse formula built` / `browse cask built` 行改成：

```
browse formula built, ready=7299/7392 (catalog 7392, index 7299, dropped 93, hydrate 0,
  trusted=true), 9 cards, 7299 entries, 412ms
  [catalogMs=22 indexMs=0 filterMs=6 buildMs=420]
  | terminal=837 devtools=838 … | session hit=0 … failed=0
```

新增的三个字段与它们的**读法**（写进 `brew-api-design.md`，否则下次没人知道 93 是正常的）：

| 字段 | 含义 | 什么时候该警觉 |
|---|---|---|
| `dropped` | `catalog − covered`：目录里不在索引里的 token 数 | formula 从 ~93 持续变大 → 可能上游开始漏进 `formula.json`（N1 的假设在退化） |
| `trusted` | 走的是主路径还是降级路径 | 期望恒为 `true`；出现 `false` 说明索引没同步成功或格式变了 |
| `hydrate` | 主路径应恒为 `0` | 非 0 说明闸门逻辑没生效 |

**cask 的 `dropped` 会明显更大**（参考量级：`cask.json` 里共有 2 645 条 `desc: null`，落盘时故意不写空串 → 这类 token 只要进了目录就必然计入 `dropped`）。

> ⚠ **2 645 既不是期望值、也不是下界 —— 不要拿它当靶心。**
> `dropped = |目录| − |目录 ∩ 索引|`，它取决于两个都需实测的量：有多少条 `desc:null` 的 token **真的进了目录**
> （`cask.json` 去重后约 5.7k token，而目录只有 ~5.4k 行，所以不是全部），以及目录里的上游幽灵有多少。
> **以 V7 实测为准。** 唯一可以肯定的是这个数不应被当 bug 修。

---

## 8. 边界与错误处理

| 边界 | 行为 |
|---|---|
| 首次安装（索引空、目录空） | `catalog === undefined` → 提前 `return undefined` → UI 空态（需求方口径 4） |
| 首次安装后目录先到、索引还没同步完 | `covered = 0 < 100` → `trusted = false` → 降级路径（前 100 + hydrate）。**这是本方案下 hydrate 唯一有意义的主场景，保持不变** |
| 索引格式跨版本变化（`Object.keys(undefined)` 崩整页那次） | 不变：`ensureIndex()` 的 `stored.formula !== undefined && stored.cask !== undefined` 形状校验**不动** |
| 目录有、索引坏（扫出 0 条 → `syncKind` 返回 `undefined` → 保留旧表） | 旧表非空 → `trusted = true`（用旧数据，符合 stale-while-revalidate）；旧表也空 → 降级路径 |
| 某 kind 的索引非空但覆盖率极低 | `covered < 100` → 降级路径（§5.1 的第二个条件兜住） |
| `BREW_DATA_SOURCE = SNAPSHOT` | 不变：`buildFormulaPage` 开头就 `return undefined` → 空态 |
| 离线 + 有索引 + 有目录 | `trusted = true` → **首屏照常有内容**（这是 A 相对现状的**正面**副作用：现状下离线时 hydrate 全失败，要等 `BREW_BROWSE_HYDRATE_MS` 超时才出内容） |
| 两个 build 并发（§5.4） | 第二个复用第一个的 Promise；两者 `pageSize` 相同 → 信封一致 |
| `buildFormulaPage` 的 `Promise` reject | 不变：`BrewRepository.getFormulaPage` 的 `.catch` 与 VM 的 `.catch` 都不动 |

---

## 9. 测试与验证

### 9.1 我会执行的（都是真机证据）

| # | 动作 | 判据 |
|---|---|---|
| V1 | `devecocli build` | `BUILD SUCCESSFUL` |
| V2 | **两轮冷启动**（`devecocli log --follow > .brewgen/cold-new-N.log &` → `devecocli run --device 127.0.0.1:42021 --skip-build` → 等 45s → kill） | **必须先确认 `DEFAULT_TAB` 已临时改回 `FORMULAE`** —— 还原成 `DISCOVER` 后 App 冷启动落在发现页，**根本不会构建 Formulae**，量不到首屏。判据：`loadFormulaPage success` 与 `Ability onCreate` **两行的 hilog 时间戳之差** ≤ 1100 ms；两轮一致。⚠ `browse … built` 行尾的 `ms` **不可**与基线的 `16989ms` 直接比：`tStart` 已从"读完 Preference 之后"提到函数第一行（多计了 catalog ~22ms + index ~17ms），两个量纲不同 |
| V3 | 同一轮日志 | ① **零请求只能从 `browse … built` 行本身读**（`hydrate 0` + `trusted=true`）—— **不能**用 `statsLine()` 的 `dl=0`/`failed`：它是**会话累计**，而默认页签是 Discover 时 Discover 路径会 `getCatalog()`（目录不新鲜时拉 4 个聚合端点）+ `hydratePage()`（6 张榜成员），会把计数污染掉；② ⚠ **实测推翻了我原本的预测**：原本写"应恰好 1 条 built + 1 条 joined in-flight"，实际是 **2 条 built + 0 条 joined** —— 因为每轮构建从 17s 降到 431ms 后，第二次构建开始（约 +657ms）时第一次**已经完成**（431ms），两者不再重叠，join 分支根本不会进。去重只在**降级路径**（构建可达 15s → 必然重叠）与未来结构变化时才生效。这一条**不能**当去重生效的证据（见 §14）；③ 顺手 `grep "loadDiscover success"` 确认"只有可见页签会被构建"这条推断 |
| V4 | **G3 输出不变**（**必须在同一次目录 TTL 窗口内对比**，见下方说明） | ① **主判据（与目录无关）**：新日志的 `ready=` 数值 == 改动前日志的 `index=` 数值（本次两轮都是 **7299**），且新日志 `dropped=` == 旧日志 `catalog − index`（**93**）；② 次判据（同窗口内）：`dist` 字段逐字相同 —— `terminal=837 devtools=838 network=286 data=228 cloudnative=164 media=274 ai=189 lib=624 system=3859` |
| V5 | `devecocli log --crash --from 5m` | 无崩溃 |
| V6 | `devecocli ui screenshot`（首屏出卡片后） | 9 张分类卡渲染正常，无空白/错位 |
| V7 | **补量 cask**（把 `DEFAULT_TAB` 临时指到 CASKS 再跑一轮） | `browse cask built` 的 `dropped` / `hydrate 0` / 首屏 ms；确认 §6.1④ 的"cask 收益更大" |
| V8 | **降级路径回归**：`--uninstall` 后首次启动（索引与目录都空 → 空态），再让目录先到 | 不崩、不白屏；`trusted=false` 时仍走前 100 + hydrate |
| V9 | `devecocli ui layout --mode full` | 卡片头部（分类图标 + 中英文名 + 包数）与改动前一致 |

**V4 为什么要「同窗口」对比**

`dist` 与 `ready` 都随**目录快照**变（`BREW_CATALOG_FRESH_MS = 1 h`，且源站每天重新生成）。跨小时的两次测量本来就可能不同，那是数据变了，不是代码改了。所以：

- **主判据选与目录无关的不变量**：`ready_新 == index_旧`、`dropped_新 == catalog_旧 − index_旧`。这两个等式在**任何**目录快照下都必须成立，因为它表达的就是"改动只是把 hydrate 那批从 `ready` 里排除掉，而不是改变 `ready` 的构成"。
- 次判据（`dist` 逐字相同）只在**同一次目录 TTL 窗口内**（看 `catalog loaded, age=Ns` 的 `age` 差值 < 3600s）才有意义。

### 9.2 我不会声称的（诚实边界）

- **hypium 单测**：`devecocli` 没有 test 命令（只有 build/run/check/device/ui/log/…），本机跑不起来。`brewcommon/src/ohosTest` 里可以补一条 `BrewIndexTrust.test.ets`（需求方在 DevEco Studio 里能跑），但**它不计入我的验证证据**，报告里标"未在本机执行"。
- **Profiler Launch 拆解**：官方 `ide-insight-session-launch` 的六阶段（Create Process / Application Launching / UIAbility Launching / OnForeground / First Frame App / Render）需要 DevEco Studio 的 Profiler，`devecocli` 不暴露。我用的是**应用层打点**，所以本 spec 的"首屏"= **数据进 state**，**不等于**官方口径的"首帧渲染完成"。两者之间还差一次渲染 + `H:MarshRSTransactionData`。
- **import 加载耗时**：官方 `AppAnalyzer` 的未使用 import 报告需要 DevEco Studio。§1.2 因此把 `import lazy` 列为非目标。
- **千行级滚动的帧率 / 峰值内存**：本机没接性能采集（`brew-catalog-fullsync-spec.md` §9 阶段 3 也留了同一个缺口）。

### 9.3 需求方的验收步骤

1. 冷启动 App（或重启后第一次打开）→ **观察从图标点击到 Formulae 首屏出卡片的时间**（期望"几乎立刻"，而不再是十几秒）；
2. 首屏 9 张分类卡的**分类名、包数、卡内 5 条预览**与改动前一致；
3. 点任意分类卡的「查看全部」→ 二级页正常，chips 可切；点任意行 → 详情页正常，返回键正常；
4. 断网后重启 App → Formulae 有内容（索引在盘上），Discover 走它的内置回落快照；
5. 全程无崩溃（`devecocli log --crash`）。

---

## 10. 验收标准

| # | 标准 |
|---|---|
| A1 | 冷启动首屏（`ability onCreate` → `stateSet`）**≤ 1100 ms**，两轮一致 |
| A2 | 首屏请求数 **0**（`hydrate 0` + `failed` 增量 0） |
| A3 | 卡片集合/顺序/分类计数/名次与改动前**逐字节一致**：主判据是 `ready_新 == index_旧` 与 `dropped_新 == catalog_旧 − index_旧`（与目录快照无关的不变量）；次判据是同窗口内的 `dist` 逐字比对（§9.1 的 V4） |
| A4 | 未新增落盘 key；未引入页面级缓存 |
| A5 | 降级路径（首次安装 / 索引异常）行为与改动前一致，不崩不白屏 |
| A6 | 无崩溃 |
| A7 | 文档已同步：`brew-api-design.md`（hydrate 触发点表 + 三个新日志字段的读法）、`brew-handover.md`（§5.3 的"浏览页冷启动代价"数字、§8.2 待办）、`brew-catalog-fullsync-spec.md`（§4.4 的"补位"语义收紧为"只在索引不可信时"） |
| A8 | 交付时附：构建日志、两轮 `[perf-probe]` 日志片段、cask 那一轮的 `browse cask built` 行、`dist` 字段的前后比对 |

---

## 11. 风险与回滚

| 风险 | 说明 | 缓解 |
|---|---|---|
| N1 的假设被证伪（上游确实会漏包进 `formula.json`） | 见 §6.2 N1 | ① `dropped` 是持续监控项（§7）；② 回退面很小：把 §5.2 的 `candidates` 换成"`∩ 索引` + 对 `dropped` 的那批走 §5.3 的 hydrate"，即退化成 A+C |
| `covered ≥ 100` 这个闸门取值不当 | 若某 kind 索引只剩几十条，会误走降级路径（安全方向），或刚好过线（此时输出与改动前相同 → 无风险） | 闸门两个方向的失败都是"退化成改动前行为"，不是新故障 |
| 在途去重与 `pageSize` 不同源 | 若将来出现不同 `pageSize` 的调用点，信封会错 | §5.4 写明"必须把 `pageSize` 并进键"；本 spec 的验收含 V4 的逐字比对 |
| 双构建的结构被误当成 bug 去改 | 会动到 `HdsNavigation` 根内容语义 | §1.2 与 §2.4③ 都写明"照抄参考实现、只去重不重构" |
| **回滚** | — | 改动集中在 `buildFormulaPage`/`buildCaskPage` 的候选集取法 + 一个在途表；无需数据迁移、无新增落盘 key。回滚 = revert 提交即可，`brew_catalog` / `brew_meta_index` 的形状不变 |

---

## 12. 改动清单（现有文件，逐条）

| # | 文件 | 改动 |
|---|---|---|
| 1 | `features/brewcommon/src/main/ets/service/BrewService.ets` | `buildFormulaPage` / `buildCaskPage`：加 `trusted` 判定；主路径改成 `目录 ∩ 索引` 且零 hydrate；降级路径逐字保留；日志加 `ready=/dropped=/hydrate=/trusted=` 与新分解字段 |
| 2 | 同上 | 新增 `browseInFlight` 在途表（照 `catalogInFlight` 模式），两个 build 入口复用 |
| 3 | `features/brewcommon/src/main/ets/constant/BrewConstants.ets` | 新增 `BREW_INDEX_MIN_TRUST`（= `BREW_BROWSE_HYDRATE_LIMIT`，注释说明为什么可以取这么松、以及 cask 为何不能用比例闸门）；新增 `BREW_PERF_TRACE`（探针总开关，**默认 `false`**，注释写明"回归时改成 true 即可，不用重写探针"）；`BREW_BROWSE_HYDRATE_LIMIT` 的注释改成"**仅降级路径**的请求预算" |
| 4 | `features/abilitycommon/src/main/ets/model/TabBarModel.ets` | `DEFAULT_TAB` 还原为 `TabBarType.DISCOVER`（**必须在 V7 量完 cask 之后**） |
| 5 | **3 个**探针文件（`BrewService.ets`、`BrewMetaSync.ets`、`BrewBrowseBuilder.ets`） | `[perf]` 日志包进 `if (BREW_PERF_TRACE) { … }`，**默认关**（保留探针以便回归）。**`PcAbility.ets` 的两行改成与文件既有风格一致的生命周期日志**（`'Ability onCreate'` / `'Ability onWindowStageCreate'` —— 该文件其余四个生命周期回调都有一行，唯独这两个缺）：不为它引入 `BREW_PERF_TRACE`，否则 `products/pc` 要依赖 `@ohos/brewcommon`，把整个 brew 数据层拉进 Ability（正是 §1.2 列为后续的 import 问题）；**`BrewFormulaHomeViewModel.ets` 的探针直接撤掉** —— `loadFormulaPage success` 这行的 hilog 时间戳就是“数据进 state”的时刻 |
| 6 | `docs/brew-api-design.md` | 加「hydrate 触发点」表（§3.1）与三个新日志字段的读法（§7） |
| 7 | `docs/brew-catalog-fullsync-spec.md` | §4.4 的"回落到现有逐条 hydrate"收紧为"**仅在索引不可信时**回落"；§4.5 的降级说明同步 |
| 8 | `docs/brew-handover.md` | §5.3「浏览页冷启动代价」用本次实测数字替换（2.7~7.4 s → 17.7 s 与根因）；§8.2 待办表加"分类结果落盘 / import 收敛 / 元数据探针"三条后续 |

---

## 13. 已知取舍与后续

| 取舍 / 未做 | 代价 | 后续触发条件 |
|---|---|---|
| 上游新包晚一次构页出现（N1） | 首屏不含"上游今天刚加、索引还没同步进来"的包 | `dropped` 持续变大，或需求方要"实时新包" |
| 分类结果不落盘 | 每次构页 420 ms 主线程分类 | 首屏压到 1100 ms 以内后想再压 → 把 `token → categoryKey` 并进索引（**需要词表版本失效机制**：`BrewTaxonomy` 随版本走，得在索引里存一个 taxonomy 版本戳） |
| `import lazy` / 桶文件收敛未做 | `SplashViewModel` 拉起整个 brew 数据层（`brewcommon/Index.ets` 24 条 export，含 1163 行的 `BrewService`） | 用 DevEco 的 AppAnalyzer 量出实际耗时后再改（**不凭"官方说重要"改结构**） |
| 每次启动 51 MB 元数据同步无探针 | 2 个请求 + 21.7 s 后台 + 一次 32 MB 扫描，与首帧抢 CPU/网络 | 量出它确实影响首帧后再加 HEAD（`brew-catalog-fullsync-spec.md` §4.2 已列为可选优化） |
| 双构建的结构未修 | 多渲染一份 `BrewFormulaBaseView`（去重后只多一次渲染，不再多一次分类） | 若首屏渲染本身成为瓶颈 |
| `brew_detail_page_data` 无 TTL | 详情页回落缓存永不失效 | 与本次无关，列为后续 |
| 「首屏」口径是"数据进 state"而非"首帧渲染完成" | 与官方 Launch 口径不可直接比较 | 需要 DevEco Profiler 才能对齐 |

---

## 14. 实测结果（2026-09-22，V2–V9）

环境：`HUAWEI MateBook Pro` / `127.0.0.1:42021` / 2in1。方法：临时把 `DEFAULT_TAB` 指到目标页签（每阶段 `devecocli build` + `devecocli run --skip-build`），`devecocli log --follow` 抓 hilog；测完已还原为 `DISCOVER` 并重新构建（`git status` 干净）。
锚点 = `[PcAbility] Ability onCreate` 那行的 hilog 时间戳；终点 = `loadFormulaPage success` / `loadCaskPage success`。

### 14.1 数字

| 轮 | 页签 | 锚点 | `browse … built` | 进 state | **锚点 → 首屏** |
|---|---|---|---|---|---|
| formula-1 | FORMULAE | 17:06:29.028 | +1102ms | +1102ms | **1102 ms** |
| formula-2 | FORMULAE | 17:07:23.354 | +1080ms | +1080ms | **1080 ms** |
| cask-1 | CASKS | 17:08:57.223 | +959ms | +959ms | **959 ms** |

对照基线 **17 712 / 18 759 ms** → 降到 **1080~1102 ms**（formula）/ **959 ms**（cask），约 **1/16**。

### 14.2 逐条判据

| # | 判据 | 结果 |
|---|---|---|
| **A3 / G3（最关键）** | 输出逐字节不变 | ✅ **完全成立**。主判据 `ready_新 7299 == index_旧 7299`、`dropped_新 93 == catalog_旧 7392 − index_旧 7299`；次判据 `dist` 与基线**逐字相同**：`terminal=837 devtools=838 network=286 data=228 cloudnative=164 media=274 ai=189 lib=624 system=3859` |
| A2 / G2 | 首屏零请求 | ✅ `hydrate 0` + `trusted=true` + `failed=0` + `dl=0` |
| **A1 / G1** | 首屏 ≤ 1100 ms | 🟡 **未稳健达标**：1080 ms 过、**1102 ms 不过**（超 2ms）。两轮一过一不过，实质是卡在门槛上 |
| V7 cask | `dropped` 与收益 | 实测 `dropped=1313`（**不是 2 645**）、`hydrate 0`、`trusted=true`、`4127/5440`、8 分类、235ms、首屏 959ms。**证实了 §7 的修正**：2 645 既非期望值也非下界（`cask.json` 去重后约 5.7k token，只有一部分进了 5 440 行的目录），当初若按"≈2645"写就是错的 |
| V5 | 无崩溃 | ✅ `devecocli log --crash --from 15m` 无 `jscrash` / `faultlog` / `cppcrash` |
| V8 | 首次安装 / 索引不可信时的降级路径 | 🟡 **部分验证（`covered === 0`）**。用 `--uninstall` 擦数据 + 落地 Formulae 的实验里拿到了一条降级路径日志：`browse formula built, 99/7392 tokens ready (catalog 7392, index 0, dropped 7392, hydrate 100, trusted=false), 9 cards, 99 entries, 986ms | terminal=8 devtools=21 network=4 data=7 cloudnative=7 media=4 ai=5 lib=5 system=38 | session hit=189 dl=0 failed=1`；另有 `meta sync: start, cached formula=0 cask=0, ts=0` 证明索引确实是空的全新状态。逐条对判据：闸门生效（`trusted=false`）、请求预算生效（`hydrate 100`）、页面**可用**（9 卡 99 条）且只要 986ms（那 100 次 hydrate 全落 `brew_live_data` 缓存） |
| **V11（P1 专项）** | **`covered > 0 && !trusted` 这个区间 —— P1 修的就是它** | ✅ **验证通过。** 把闸门临时抬到 `100000`（`covered = 7299 < 闸门` 且 `> 0`）即精确落进 P1 覆盖的分支：<br>`browse formula built, 7299/7392 tokens ready (catalog 7392, index 7299, dropped 93, hydrate 93, trusted=false), 9 cards, 7299 entries, 16793ms \| terminal=837 devtools=838 network=286 data=228 cloudnative=164 media=274 ai=189 lib=624 system=3859 \| failed=57 dl=0`<br>**`ready=7299` 证明 `candidates` 取到了目录全量**（`covered > 0 ? all`）。若不修 P1（写成 `all.slice(0,100)`），同一实验会得到 `ready≈99` 且 `dist` 只剩百来条 —— **所以这条能区分修没修对**。<br>附带收益：这一轮把**改动前的病态按需复现**了出来 —— `hydrate 93 / failed 57 / dl 0 / 16793ms` 与基线的 `hydrate 93 / failed 62 / dl 0 / 16989ms` 几乎逐项一致，定量印证了 §2 的诊断（抬一次闸门，17 秒就回来了）|
| V12（新） | §5.4 担心的两个 P2 失效模式（promise 永不 settle / 在途字段被污染） | ✅ **真机未触发**。日志里 4 次 `formula browse empty (catalog unavailable)` 都紧随 `loadFormulaPage success, 0 category cards` —— promise 正常 settle 成「空态」而非卡在 LOADING。这也解释了那张截图上的"正在加载"：是一瞬的中间帧，不是卡死 |
| V10（新） | `--uninstall` 能否当"首次安装"用 | ❌ **不可靠**：同一命令在不同轮次一次报 `Check in the settings whether the current device is in developer mode` 而失败、一次成功；且它会同时擦掉 `brew_live_data` 与 `brew_catalog`，**无法构造"目录在、索引空"的精确条件**。用它做控制变量实验不可行 |
| V6 / V9 | 截图 / `ui layout` | ⬜ **未做** |

### 14.3 从中得到的新事实

**① 在途去重（§5.4）在可信路径上是死代码 —— 实测 0 次触发。**
formula-1 的两条构建完成于 `17:06:30.130`（耗时 431ms → 起于约 +671ms）与 `17:06:30.801`（耗时 445ms → 起于约 +1328ms），**间隔 657ms 且第一次已结束**。基线里两者相隔 155ms、各跑 17s，所以当时完全重叠 —— 去重是为那个场景写的。
现在它只在**降级路径**（构建可达 `BREW_BROWSE_HYDRATE_MS` = 15s → 必然重叠）与今后结构变化时生效。**保留它**（那是首次安装的路径），但不要再拿它当"双构建已解决"的证据。

**② 结构性双构建仍在，但已经不拖首屏。**
第二次构建在首屏之后约 230ms 发生（`30.801` vs `30.130`），代价是 445ms 主线程 CPU 落在首屏刚出来的时候 —— **可能表现为一次掉帧**，但不影响"多久看到内容"。所以"修结构"的收益从"省一半首屏时间"降级为"省掉首屏后的一次卡顿"，优先级下降（§13 的结论不变）。

**③ 新发现（已由实测坐实）：浏览页永远不会自己拉目录。**

`BrewService.getCatalog()`（唯一会发那 4 个聚合端点请求的入口，`BrewService.ets:664`）**全仓只有一个调用点**：`BrewRepository.ets:443`，也就是 **Discover 页**。
而 `buildFormulaPage` / `buildCaskPage` 调的是 `ensureCatalog()`（`:950` / `:1055`）—— **只同步读 Preference，拿不到就返回 undefined**，从不触发拉取。

后果：**若 App 的落地页不是 Discover（或用户不先走一趟 Discover），首次安装后浏览页会一直是空态**。本项目的 `DEFAULT_TAB = DISCOVER`（`TabBarModel.ets:106`）正好把这个洞遮住了 —— 所以它是**潜伏缺陷**，不是当前可见 bug。

**实测复现（不是推出）**：`--uninstall` 擦掉 `brew_catalog` 后，落地 `FORMULAE` 跑几分钟、重启 3 次，日志里只有
`4 × [BrewRepository] formula browse empty (catalog unavailable)` + `4 × loadFormulaPage success, 0 category cards`
—— 目录**一次都没被尝试拉取**，页面也从不自愈。要它恢复必须先加载一次 Discover。

它是**改动前就存在**的（基线代码同样是 `ensureCatalog()`），与本 spec 无关，故**不纳入本次改动**；但记在这里，因为：① 它是 §13"分类结果落盘"之外另一个会阻挡"把 Formulae 当落地页"的东西；② 真正的修法应该是在浏览页也调一次 `getCatalog()`（代价：首次安装时浏览页要多等 4 个端点）。

**④ 每次启动 51 MB 元数据同步的完成时间未测到。** 该实验窗口里 `meta sync: done` = **0**（只有 `start`）。该窗口同时混入了 2 个进程与 3 次 `Ability onCreate`（脚本只启动过 1 次）—— 说明**期间有人在手动操作 App**，日志无法归属，所以本轮不算证据。待后续在无人操作时单跑一轮量 `start → done` 与首帧的关系。

### 14.4 要达到稳健的 ≤1100 ms 还差什么

按当前拆解（`onCreate` → `meta sync: start` = +391ms；→ 构建起 ≈ +671ms；构建 = 431ms）：

| 杠杆 | 可省 | 性质 |
|---|---|---|
| **分类结果落盘**（把 `token → categoryKey` 并进索引，在 taskpool 同步时算） | ~431ms → 首屏落到 **~670ms** | §13 已列；**现在它从"想再压一压"升级为"达成 A1 的手段"**；需要词表版本失效机制 |
| 不在首屏解析整份 1MB 索引（按 kind 分片 / 异步） | ~17ms | 量太小，不值 |
| `import lazy` / 桶文件收敛（缩 `onCreate → meta sync` 那 391ms 里的模块加载） | 未知 | 仍需先用 DevEco 的 AppAnalyzer 量出实际耗时 |

**结论：G1 目前未达标，缺口主要在那 431ms 的分类上。** 按仓库惯例不擅自扩大改动面 —— 是否做"分类落盘"由需求方定（§13 已列触发条件）。

---

## 附录 A：本次探针的原始日志（run 1，节选）

```
[BrewFormulaBaseView] / [PcAbility]
09-22 16:03:55.987  I [PcAbility], [perf-probe] ability onCreate ts=1790064235987
09-22 16:03:56.034  I [PcAbility], [perf-probe] windowStageCreate ts=1790064236034
09-22 16:03:56.421  I [BrewMetaSync], [perf-probe] meta index pref read+parse ts=1790064236402 readMs=17 formula=8613 cask=5103
09-22 16:03:56.423  I [BrewMetaSync], meta sync: start, cached formula=8613 cask=5103, ts=1790061143476
09-22 16:03:56.732  I [BrewService], [perf-probe] catalog pref read+parse ts=1790064236710 readMs=22 formula=7392 cask=5440
09-22 16:03:56.732  I [BrewService], catalog loaded, age=390s, boards=165, browseKinds=2
09-22 16:03:56.758  I [BrewService], live cache loaded, 416 entries (etag=416 lastModified=416)
09-22 16:04:13.698  I [BrewBrowseBuilder], [perf-probe] formulaPage rows=7299 groupMs=420 cardMs=2 cards=9
09-22 16:04:13.699  I [BrewService], browse formula built, 7299/7392 tokens ready (catalog 7392, index 7299, hydrate 93), 9 cards, 7299 entries, 16989ms [perf-probe tStart=1790064236710 catalogMs=22 indexMs=0 filterMs=6 hydrate+classifyMs=16961] | terminal=837 devtools=838 network=286 data=228 cloudnative=164 media=274 ai=189 lib=624 system=3859 | session hit=0 renewed=0 notModified=0 dl=0(cond=0 nocond=0) failed=138 catalogFailed=0
09-22 16:04:14.112  I [BrewBrowseBuilder], [perf-probe] formulaPage rows=7299 groupMs=408 cardMs=2 cards=9
09-22 16:04:14.112  I [BrewService], browse formula built, 7299/7392 tokens ready (catalog 7392, index 7299, hydrate 93), 9 cards, 7299 entries, 17247ms [perf-probe tStart=1790064236865 catalogMs=0 indexMs=0 filterMs=7 hydrate+classifyMs=17240] | … | session hit=0 … failed=138 catalogFailed=0
09-22 16:04:14.113  I [BrewFormulaHomeVM], loadFormulaPage success, 9 category cards [perf-probe] stateSet ts=1790064254113
09-22 16:04:14.113  I [BrewFormulaHomeVM], loadFormulaPage success, 9 category cards [perf-probe] stateSet ts=1790064254113
```

（`failed=138` = 两轮 build 的 62 + 76 累加；run 2 是干净进程，对应 `failed=62`。两次 `formulaPage` / 两次 `loadFormulaPage success` 就是 §2.4③ 的双构建。）

**404 明细（run 2，去重后）**：`testball` / `testball1` / `testball_bottle` / `plink` / `plink1` / `whisper-cpp` / `uavs3e` / `twitdl` / `tflint` / `terraform` / `sentry-cli` / `sdl2` / `refine` / `pdfio` … 共 93 个。
