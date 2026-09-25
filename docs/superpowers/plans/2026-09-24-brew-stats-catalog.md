# Harmonybrew stats → 目录（修好 Formulae 浏览页与 Discover 榜）

> 2026-09-24。承接 `2026-09-24-brew-source-dialect.md`（方言适配）。
> 该计划让 Harmonybrew 的**搜索与详情**可用，但**发现 / Formulae / Casks 三个页面全空**。
> 本计划修掉它。

## Global Constraints

- **只用 `devecocli`** 构建/部署，不要用 `hvigorw`。构建放后台（`bg_run`）。
- 设计令牌与组件沿用项目约定：`sys.float.*`、`comp_background_*`、`corner_radius_level*`、
  `HdsListItemCard`、`brewTitleBarStyle`。
- **ArkTS 限制**（踩过的坑）：
  - `throw` 只能抛 `Error`（`arkts-limited-throw`），不能 `throw someBusinessError`。
  - 对象字面量必须有显式类型（`Record<string, X>` 之类），不能裸 `{}`。
  - `Record` 索引访问可能得到 `undefined`，必须判空。
- **不要在一个 `try` 里塞多个可能失败的步骤**：共用 `catch` 会把不同失败压成同一句日志，
  排查时只能靠猜（本仓库已因此误诊过一次，见 `BrewCatalogFile.write` 的 `at=<step>` 注释）。
- **新增文件必须被引用才会被编译** —— 增量构建跳过未引用文件，
  `devecocli build` 成功**不能**证明新文件编译通过。要么让它被真实引用，要么显式验证。
- 提交信息：`type(scope): 中文描述` + 详细正文，scope 用 `brew`。**不要 push**。
- 验证证据写到**仓库外**（如 `/storage/Users/currentUser/...`），不要在仓库里留文件。

---

## §1 实测事实（2026-09-24 在宿主机实拉）

### 1.1 端点形状

`https://harmonybrew.atomgit.com/stats/stats-YYYYMMDD.json`

- **扁平** `{token: 当日次数}`，**不是**官方 analytics 的 `{formulae:{token:[{count}]}}`。
- 是**当日增量**（值逐日变化、键集逐日不同），不是累计。
- 是**下载量**（页面标题「AtomGit 下载数据统计」，响应头 `x-obs-*` / `obs-upload-script`），
  与官方的 `install-on-request`（安装量）**语义不完全等价**。
- 单文件约 7~16 KB。

### 1.2 可用范围（实测）

| 项 | 值 |
|---|---|
| 最早 | `2026-05-20`（`20260519` 及更早 404） |
| 最新 | `2026-09-23`（`20260924` 404，当天尚未发布） |
| 天数 | 127 天中**取到 125 天**（缺 `2026-08-07`、`2026-08-08`） |
| 覆盖 token | 全历史 **4798** 个（目录里是 4761 个 formulae → 基本全覆盖） |
| 发布时刻 | 文件 `Last-Modified` 为 `04:00:36 GMT` → **新的一天在 UTC 凌晨后才出现** |

页面 UI 只暴露「近 7 天 / 近 30 天 / 指定日期」，但更早的文件**都在**。

### 1.3 分布（决定官方门槛是否还可用）

按官方窗口语义（30d 求和 / 更早求和）实算：

| 窗口 | 实测 |
|---|---|
| 30d | 4448 个 token 有量；`max=2644`、`p50=2`、`p89=10` |
| 更早 95 天 | `max=13840` |
| 官方 `volFloor=500` | **65 个通过**，且全部也满足 `prior>=50` |

30d 前 5：`openssl@3` 2644、`zlib-ng-compat` 2605、`node` 2410、
`portable-ruby` 2215、`rust` 2013。

→ **官方标定门槛仍在该源的量程内**，不需要为它另做一套阈值（但见 §4 开放项 1）。

### 1.4 该源没有的东西

| 端点 | 结果 |
|---|---|
| `/api/analytics/*`（4 个聚合端点） | **404** |
| `/api/formula.json` | 404 |
| `/api/cask.jws.json` | 200 但只有 **491 B** → casks 恒空 |
| `/api/formula.jws.json` | 200，11.9 MB（未按 bottle tag 过滤，**不要用**） |
| `/api/internal/packages.arm64_ohos.jws.json` | 200，3.97 MB（已在用） |

### 1.5 三个页面为什么全空（已定位，含一个我引入的 bug）

三个页面**都只消费 `brew_catalog`**，而它唯一的来源是 4 个 `/analytics/*` 端点：

| 位置 | 行为 |
|---|---|
| `BrewCatalogAlgo.ets:62` | `supportsAnalytics=false` → `catalogSources()` 返回 **`[]`** |
| `BrewService.ets:806` | `getCatalog()` 返回**一个空的 catalog 对象**（不是 `undefined`） |

- **Formulae**：`buildFormulaPage` 读 `ensureCatalog()`（**盘上的 pref**），
  而 pref **只有 `getCatalog()` 会写**；该源下 `getCatalog()` 提前 return、**不写**
  → pref 永远填不上 → `reason=empty-catalog` → 空页。
- **Casks**：读同一个 `ensureCatalog()`，且更早短路（`supportsCasks=false` → `emptyCaskPage`）。
- **发现（Discover）**：**这是 bug，不是能力限制**。Discover 有自己的内置快照
  （rawfile，`boards=6 featured=5`），本来能显示。但 `getDiscoverPage` 用
  `catalog !== undefined` 判断「目录权威」，而空 sentinel **不是 `undefined`**：

  ```
  catalog !== undefined          → fromCatalog = true        （错判）
  applyCatalogMembers(page, {})  → board.entries = entries    （无条件覆盖）
                                 → 6 张榜全被清空 → 0 个 token 可 hydrate
  ```

  真机日志逐字吻合：`discover_page ... membersFromCatalog=true boards=6 hydrateMs=0`。
  空 sentinel 让 Discover 比「目录缺失」**更差**（缺失时至少保留快照并 hydrate）。

  **这段是 `4ba766b`（Task 8）引入的**，违反了 `getCatalog` 自己文档里的契约
  （「失败时返回 `undefined` 而不抛错：目录是更准的成员来源，**拿不到就沿用内置快照**」）。

---

## §2 架构与决策记录

### 2.1 核心洞察：`buildCatalog` 已经是源无关的

```ts
bodies.forEach(one => { counts[one.job.kind][one.job.win] = parseCounts(JSON.parse(one.text)); });
Object.keys(counts).forEach(kind => {
  const result = BrewCatalogAlgo.build(kind, windows['30d'].counts, windows['365d'].counts);
  meta[kind] = toKindMeta(...); boards[kind] = toBoards(result);
  topTokens[kind] = result.byVolume.map(...);   // ← 浏览页取这个
});
```

它只要 `counts[kind]['30d']` 与 `counts[kind]['365d']` 两份 `CatalogCounts`。
**所以最小缝是：让适配器把日文件求和、合成为两份上游形状的 `CatalogAnalyticsDoc`。**
`buildCatalog` / `parseCounts` / `toBoards` / `toKindMeta` / `byVolume` **一行都不用改**。

```
/stats/stats-YYYYMMDD.json（已发布的日期文件不可变）
        │
        ├─ 最近 30 天求和 → a30 ─┐
        └─ 更早 60 天求和 → aOld ─┴→ 合成 CatalogAnalyticsDoc ×2（win=30d / 365d）
                                        │
                        BrewCatalogAlgo.parseCounts + build   ← 完全复用
                                        │
                  brew_catalog（topTokens + boards + meta）
                                        │
              Formulae 浏览页 ✓ / Discover 榜 ✓ / Casks ✗（上游无 cask 数据）
```

### 2.2 D-1：窗口长度 —— prior = 60 天，总取 90 天

**已与需求方确认**（2026-09-24）：

| 窗口 | 天数 | 用途 |
|---|---|---|
| 当前 | 最近 **30** 天 | `a30` → `vol30d` |
| 基线 | 之前 **60** 天 | `aOld` → `prior` |

- `win='30d'` 的文档 counts = `a30`
- `win='365d'` 的文档 counts = `a30 + aOld`（**全部可用历史**，供 `alltime` 榜排序）
- **取数总量 = 90 个日文件**（首次 ~1.35 MB）

不取全部 125 天的理由：请求数翻倍，而基线窗口从 60 天加到 95 天对趋势榜的收益很小。
**这是刻意的口径偏离**（官方是 335 天），必须在日志与文档里写明。

### 2.3 D-2：`prior` 的除数必须参数化（否则趋势榜系统性偏 2 倍）

`BrewCatalogAlgo.build` 里写死：

```ts
const prior: number = (a365[token] - a30[token]) / 11.0;
```

那个 **`/11` 是把官方 335 天窗口折成月均**（335/30.4 ≈ 11.02，标定取 11）。
本源的基线只有 60 天，除数必须是 `60 / 30.4 ≈ 1.974`。

**做法**：给 `build()` 加一个 `priorDivisor` 参数。

- **上游必须继续传 `11.0`**，不要写成 `335 / 30.4`（= 11.02）——
  那会改变上游的 `prior`，进而**悄悄改变上游的榜**。
- Harmonybrew 传 `60 / 30.4`。

这个常量属于「源的标定」，所以放在适配器上（`readonly priorDivisor: number`）。

### 2.4 D-3：日文件按天永久缓存 → 稳态每天只 1 个请求

日期文件**一旦发布就不再变**（这是与官方 analytics 的本质区别：官方每次都要条件请求）。
所以：

- 每个日期文件单独存 `filesDir/brew_src/<sourceId>/stats/YYYYMMDD.json`
- **只拉缺的天**，拉到就永久保留
- 窗口滑动时淘汰窗口外的天

| | 首次 | 之后 |
|---|---|---|
| 请求 | 90 个（~1.35 MB） | **1 个/天** |

**稳态比官方路径更省**（官方 4 个端点每次都要探针，实测 17.4 s）。

### 2.5 D-4：新的一天怎么定

stats 在 UTC 凌晨 ~04:00 才发布前一天的文件。所以：

- 候选最新日 = **今天 − 1（UTC）**
- 若该日 404 → 回退 **今天 − 2**

不按「UTC 小时数」猜（那会在发布延迟时静默拿不到最新一天）。

### 2.6 D-5：空 sentinel 必须删掉，失败必须回 `undefined`

`getCatalog()` 的 `!supportsAnalytics` 分支返回空 catalog 是 bug（§1.5）。
本计划把该分支**整个删掉**：

- 该源现在**能**产出真目录（走 stats）→ 不需要 sentinel。
- stats 取数失败 → `fetchCatalog` 返回 `undefined` → `getCatalog` 返回 `undefined`
  → Discover 按文档契约**回落到内置快照**（`fromCatalog=false`，成员保留 + 正常 hydrate）。

**这一步本身就是安全网**：即使 stats 那条路将来挂了，Discover 也不会再变空。

### 2.7 D-6：`supportsAnalytics` 语义不变

`supportsAnalytics` 的含义是「**有 `/analytics/*` 端点**」，不是「能出目录」。
本源的该字段**保持 `false`**，于是 `catalogSources()` 继续返回 `[]`（正确 —— 那 4 个 URL
在它这里确实 404）。目录能力由**新增的**合成路径提供。

### 2.8 D-7：接口放叶子模块，避免循环 import

`CatalogProbeResult` 声明在 `BrewService.ets` 内且未导出，而适配器不能 import `BrewService`
（`BrewService` 已 import 适配器）。项目对这种情况有既定做法：**拆叶子文件**
（见 `BrewCacheEpoch.ets` 头部的说明）。

所以新增叶子模块 `service/source/BrewCatalogInput.ets` 声明合成结果类型，
`BrewService` 把它映射成现有 `CatalogProbeResult`（`code: 200`）后喂给 `buildCatalog`
—— `buildCatalog` 签名不变。

---

## §3 文件结构

**新增**

| 文件 | 职责 |
|---|---|
| `features/brewcommon/src/main/ets/service/source/BrewCatalogInput.ets` | 叶子类型：适配器合成出的目录输入（`kind` / `win` / `url` / `text` / `lastModified`） |
| `features/brewcommon/src/main/ets/service/source/HarmonybrewStats.ets` | 日文件取数 + 按天缓存 + 求和 + 合成两份 `CatalogAnalyticsDoc` |

**修改**

| 文件 | 改动 |
|---|---|
| `service/BrewService.ets` | 删空 sentinel；`fetchCatalog` 按 `supportsAnalytics` 分派；`buildCatalog` 把除数传给 `build` |
| `service/BrewCatalogAlgo.ets` | `build()` 加 `priorDivisor` 参数（默认语义见 §2.3） |
| `service/source/BrewSourceAdapter.ets` | 接口加 `priorDivisor` 与 `synthCatalogDocs` |
| `service/source/UpstreamAdapter.ets` | `priorDivisor = 11.0`；`synthCatalogDocs` 返回 `undefined` |
| `service/source/HarmonybrewAdapter.ets` | `priorDivisor = 60 / 30.4`；`synthCatalogDocs` 走 `HarmonybrewStats` |
| `constant/BrewSourceConstants.ets` | stats 路径模板、窗口天数、并发度 |

---

## Tasks

### Task 1 — 删掉空 sentinel（独立、先做、可单独提交）

**目标**：`getCatalog()` 恢复文档契约，Discover 至少回落到内置快照。

**改** `BrewService.getCatalog()`：把整个 `if (!adapter.supportsAnalytics) { ...空 catalog... }`
分支删掉。

**验证**：
- `getCatalog()` 全仓库**只有一个调用方**（`BrewRepository.ets:450`，Discover）。
  确认没有别的调用方依赖「非 undefined」。
- `devecocli build` 通过。
- 真机：Harmonybrew 激活时进「发现」→ **6 张榜有内容**（内置快照成员）、
  日志 `membersFromCatalog=false` 且 `hydrateMs > 0`。

**判据**：`grep -c "catalog unsupported by active source"` == 0。

---

### Task 2 — `priorDivisor` 参数化（**不得改变上游**）

**改** `BrewCatalogAlgo.build(kind, a30, a365, priorDivisor)`：

```ts
const prior: number = (a365[token] - a30[token]) / priorDivisor;
```

- 上游调用点传 **`11.0`**（逐字保持原值）。
- 在函数文档里写明：`11.0` 是官方 335 天窗口折月均的**标定值**，
  **不要**改成 `335 / 30.4`（= 11.02）—— 那会改变上游的榜。

**验证（关键）**：上游的榜必须**逐位不变**。
- 真机以 Official 为激活源构建一次目录，记录 `catalog refreshed ... | <catalogMetaLine>`
  与 `catalog boards: N entries, browse tokens: formula=NNNN cask=NNNN`；
- 与改动前对比，**必须完全相同**。

**判据**：上游 `boards` 与 `browse tokens` 数字一致；`grep "11.0"` 在调用点可见。

---

### Task 3 — 日文件取数 + 按天缓存（`HarmonybrewStats`）

**新建** `HarmonybrewStats.ets`，对外只暴露一个入口（供适配器调用）：

```ts
/** 取到窗口内所有可用的日文件，返回合成好的两份 CatalogAnalyticsDoc JSON 文本。 */
public static async synth(baseUrl: string, sourceId: string): Promise<BrewCatalogInput[] | undefined>
```

内部步骤（**每一步单独 try，日志必须带步骤名**，见 Global Constraints）：

1. **定最新日**：`today-1`（UTC）→ 404 则 `today-2`（§2.5）。
2. **定窗口**：`[最新日-89 .. 最新日]` 共 90 天（30 当前 + 60 基线）。
3. **按天缓存**：`filesDir/brew_src/<sourceId>/stats/YYYYMMDD.json`。
   - 已存在的天**不发请求**。
   - 缺的天**并发拉取**（并发度用常量，建议 6 —— 对第三方域名要克制）。
   - **单天 404 不算失败**（已知会缺天，如 `2026-08-07/08`），记一条日志继续。
   - 全部失败才返回 `undefined`。
4. **淘汰**：删除窗口外的缓存文件（避免无限增长）。
5. **求和**：`a30`（最近 30 天）、`aOld`（之前 60 天）。
6. **合成两份文档**：
   ```ts
   { category: 'harmonybrew-stats', total_items, total_count,
     start_date, end_date, formulae: { <token>: [{ formula: <token>, count: '<sum>' }] } }
   ```
   - `win='30d'` → counts = `a30`
   - `win='365d'` → counts = `a30 + aOld`
   - **注意**：`parseCounts` 用 `payload.formulae !== undefined ? 'formulae' : 'casks'`
     取键，所以**必须用 `formulae` 这个键名**（即使本源是 formula）。
   - **`a365` 必须是 `a30` 的超集** —— `build()` 里
     `shared = keys(a30).filter(t => a365[t] !== undefined)`，
     若 `a365` 漏了 `a30` 的 token，它会被**整个丢掉**（新包会从新星榜消失）。
     按 `a30 + aOld` 求和天然满足（`a30` 里 `>0` 的 token 在总和中必然存在）。
7. **日志**（可诊断性是这个仓库的硬要求）：
   ```
   [HarmonybrewStats] newest=2026-09-23 days=90 cached=88 fetched=2 missing=0
   [HarmonybrewStats] window 30d=2026-08-25..2026-09-23 tokens=4448 total=NNNN
   [HarmonybrewStats] window prior=2026-06-26..2026-08-24 days=60 tokens=NNNN total=NNNN
   ```

**判据**：第二次启动时 `fetched=1`（只拉新的一天）、`cached=89`。

---

### Task 4 — 接进 `fetchCatalog` 分派

**改** `BrewService.fetchCatalog()`：在现有 4 端点逻辑**之前**分派：

```ts
const adapter = adapterFor(BrewSourceStore.dialectOf(sourceId));
if (!adapter.supportsAnalytics) {
  return adapter.synthCatalogDocs(baseUrl)            // Task 3 的产物
    .then(inputs => inputs === undefined
      ? undefined                                     // 失败 → 契约上的 undefined（§2.6）
      : this.buildCatalog(inputs.map(toProbeResult), stored, took, 0, inputs.length));
}
```

- `toProbeResult` 把 `BrewCatalogInput` 映射成现有 `CatalogProbeResult`（`code: 200`）。
- 沿用既有的 `willFetch` / `noteError('catalog')` / `noteCatalogOk` / `BrewLoadLog` 行为，
  失败路径要打 `catalog_fetch reason=stats-failed`。

**判据**：Harmonybrew 激活时日志出现
`[BrewCatalogFile]` 之外的新行 `catalog refreshed ... browse tokens: formula=NNNN`。

---

### Task 5 — 让浏览页真的出数据

**这是本计划的最终目标，必须真机验证。**

`buildFormulaPage` 依赖 `catalog.topTokens[FORMULA]` + `BrewMetaSync.descOf()` 的分类。
Task 4 之后 `topTokens` 有 ~4400 个 token（30d 有量的），所以：

- Formulae 首页应出现分类卡（`loadFormulaPage ... N category cards`，N > 0）
- Discover 6 张榜应有成员，且**能点进详情**
- 搜索→详情本来就能用，不应回归

**注意**：`BREW_INDEX_MIN_TRUST=100` 的可信判据与 `desc` 索引无关地继续工作
（Harmonybrew 的 `formula.json` 索引是 4761 条，远超阈值）。

---

### Task 6 — 文档与提交

- 更新 `docs/superpowers/specs/2026-09-23-brew-multi-source-design.md` 或本计划旁记：
  记录「Harmonybrew 的目录口径」——**下载量**、**30d/60d 窗口**、**除数 60/30.4**、
  以及它与官方的**刻意差异**。
- 按项目约定提交（`feat(brew): ...`），**不 push**。

---

## §4 开放项（不在本计划范围，但要报给需求方）

1. **阈值未为本源重标定**。`BREW_CATALOG_CONFIG` 的 `volFloor=500` / `minPrior=50` /
   `newFloor=300` 是按**官方全球分布**标的。实测本源下 `volFloor=500` 仍有 65 个候选，
   量程够用；但 `actualVolP` / `actualPriorP` 的运行期分位数日志会显示偏差。
   **门槛漂移是需要人看一眼的信号**，不要在代码里静默自适应。
2. **指标是「下载量」不是「安装量」**。榜名与文案是否区分，属于产品口径。
   Discover 页已有「基于最近可用数据 <日期>」那行可以承载，但**尚未决定怎么表述**。
3. **Casks 依然无解** —— 上游 `casks` 恒空（`/api/cask.jws.json` 只有 491 B）。
   需要 Task 8b（统一的能力空态文案）。
4. **首次 90 个请求**对第三方域名是否可接受，没有与需求方确认过；
   若要求更克制，可把基线窗口从 60 天降到 30 天（总 60 天）。
5. 是否把 Harmonybrew 设为**默认源**（含第三方域名的可用性/合规风险），仍未决定。

---

## 完成判据

- [ ] `getCatalog()` 不再返回空 sentinel（`grep "catalog unsupported by active source"` == 0）
- [ ] **上游的榜逐位不变**（Task 2 的对照证据）
- [ ] Harmonybrew 激活时：`catalog refreshed` 出现，`browse tokens: formula` > 4000
- [ ] Formulae 首页**有分类卡**（真机截图 + `N category cards` 日志）
- [ ] Discover 6 张榜**有成员**，且**能点进详情**（真机截图 + 日志）
- [ ] 第二次启动 `fetched=1`（按天缓存生效）
- [ ] 搜索→详情无回归
- [ ] 切回 Official 后一切正常
- [ ] 证据全部在**仓库外**；仓库里只有预期改动
