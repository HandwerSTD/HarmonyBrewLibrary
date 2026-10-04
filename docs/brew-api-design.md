> **接手请先读 `docs/brew-handover.md`**（交接入口：代码地图 / 怎么跑 / 决策与踩坑索引 / 待办）。本文是它的细节文档之一。

# Homebrew 应用市场 · API 设计

> 数据底座实现说明。内容规划见 [`brew-marketplace-content-plan.md`](./brew-marketplace-content-plan.md)。
> 配套代码：`features/brewcommon/`；mock 生成器：`hmosword-build/brew-mockgen/`。

---

## 1. 设计目标与三条原则

| 原则 | 落地方式 |
|---|---|
| **未来接真实 API 时解析层零改动** | 字段命名保留 Homebrew 原生语义（`token` / `tap` / `bottle` / `artifacts` / `dependsOn` / `kegOnly` / `installs30d`） |
| **最大化复用共享骨架，但不复用组件演练场引擎** | 首页/列表复用 `commonbusiness` 的 `BaseHomeView`/`BaseHomeViewModel` + 卡片展示槽位；**详情页另起一个页面**，按典型应用市场布局用官方组件实现（见 §5） |
| **中文文案不落进数据层** | mock JSON 只存英文；中文集中在 `features/brewcommon/src/main/resources/{base,zh_CN}/element/string.json`，代码侧用资源映射表按 `categoryKey` 查 |

---

## 2. 端点设计

> **2026-10：整条 Mock 端点层已删除。** brew 不再有任何 `rawfile/mockdata/<trigger>.json`
> 端点，`common/storagemanager/MockRequest.ets` 与 `common/constant/TriggerEnums.ets` 两个文件
> 也一并删除（brew 是它们最后的调用方）。数据只来自**设备端目录（聚合端点）**与**现网单条**。
> 下表保留为历史记录（~~删除线~~ = 已删），活的端点表见 §7.5.1 的多源部分与 `BrewService`。

所有端点曾经 `common/storagemanager/MockRequest`（在 `common/Index.ets` 里别名为 `HmosRequest`）读取
`rawfile/mockdata/<trigger>.json`。trigger 常量集中在 `common/src/main/ets/constant/TriggerEnums.ets`。

| trigger | 方法 | 返回类型 | 说明 |
|---|---|---|---|
| ~~`brew-formula-page`~~ / ~~`brew-cask-page`~~ | ~~`getFormulaPage()`~~ | ~~`BrewPageData<…>`~~ | **已删除（C 档）**：分类与成员改由设备端用目录 + 词表现算（`BrewBrowseBuilder` + `BrewTaxonomy`），不再有内置的首页快照 |
| ~~`brew-formula-details`~~ / ~~`brew-cask-details`~~ | ~~`getFormulaDetail(id)`~~ | ~~`BrewFormulaDetail`~~ | **已删除**：详情页骨架改从首页条目合成（`BrewApiMapper.formulaBaseOf/caskBaseOf`），不再有按 `id` 的单条快照查询 |
| ~~`brew-formula-banner`~~ / ~~`brew-cask-banner`~~ | ~~`getFormulaBanner()`~~ | ~~`BrewBanner[]`~~ | **已删除**：从来没有 UI 调用点 |
| ~~`brew-discover-page`~~ | ~~`getDiscoverPage()`~~ | ~~`BrewDiscoverPageData`~~ | **已删除（2026-10）**。它是 Discover 的**回落快照**：目录拿不到时当成员用，目录可用时被目录成员覆盖。回落删除后六张榜的骨架改为**代码构造**（`BrewRepository.emptyDiscoverPage`，`id = sequence = 1..6` 与旧快照逐字一致 → 二级页路由零影响），成员唯一来源 = 设备端目录；目录拿不到 → **空榜**，`loadDiscover` 过滤空榜后页面走空态 |
| ~~`brew-local-formulae`~~ / ~~`brew-local-casks`~~ / ~~`brew-local-outdated`~~ | ~~`getInstalledFormulae()` / `getInstalledCasks()` / `getOutdated()`~~ | ~~`BrewInstalledPackage[]`~~ | **已删除（2026-10）**。那三份内置 mock 随快照链路一并删除。本机包现在的数据源是设备上的 brew 命令（`BrewInstalledLoader`，见 §12.1.1）：`MinePackagesUtil.loadSets()` 的签名未变，UI 结构未变 |
| ~~`brew-local-overview`~~ / ~~`brew-local-taps`~~ / ~~`brew-local-services`~~ | ~~`getLocalOverview()` / `getTaps()` / `getLocalServices()`~~ | —— | **已删除（2026-09）**：从未有 UI 调用点 |

**BREW_DATA_MODE**：原 §7.5 的「REMOTE / SNAPSHOT」开关**已于 2026-10 随内置快照一并删除**
（`BrewDataMode` / `BREW_DATA_MODE` / `BREW_CATALOG_MEMBERSHIP` 三个常量均已移除）。
现在只有一条通道：取数失败 → **空态**，而不是切换到另一份数据。「用哪个源」是
`BrewSource*` 的事（§7.5.1），不再与「走不走网络」混在同一个开关里。

---

## 3. 分页信封与单条查询

复用现有 `PageData<T>` 形状（见 `common/src/main/ets/model/ResponseData.ets` 与 `component-page.json`）：

```jsonc
// brew-formula-page.json
{ "success": true, "code": "0000", "msg": "success",
  "body": {
    "currentPage": 1, "pageSize": 50, "totalPage": 1, "totalSize": 8,
    "data": { "cardData": [ /* BrewCategoryCard[] */ ] }
  }
}
```

~~`MockRequest` 的三个分支（`common/src/main/ets/storagemanager/MockRequest.ets`）：~~（2026-10：整个文件已删除）

| 入参 | 行为 |
|---|---|
| 带 `singleId` | `jsonContent.body.find(item => item.id === singleId)`，命中后返回该对象 |
| 带 `supportDevice` + `apiVersion` | 读 `mockdata/<supportDevice>/<trigger>.json`，并按 `cardId` / `categoryId` / `type` 二次筛选 |
| 其他 | 直接返回 `jsonContent.body` |

brew 数据曾**不使用** `supportDevice` 子目录（只面向 2in1），因此文件位于 `mockdata/` 根下。

---

## 4. 字段映射：Homebrew API → 本项目模型

### 4.1 卡片条目 `BrewPackageItem`

为复用现有卡片渲染器，条目同时携带 brew 语义字段与 `BaseData` 展示槽位：

| 本项目字段 | Homebrew 来源 | 展示位置 |
|---|---|---|
| `subTitle` | `token`（如 `ripgrep`） | 卡片**主**文案（primaryText） |
| `title` | `desc`（英文原文） | 卡片**副**文案（secondaryText），1 行省略 |
| `stableVersion` | `versions.stable`（formula）/ `version`（cask） | 版本 |
| `installs30d` | `analytics.install_on_request.30d[token]` / `analytics.install.30d[token]` | 热度 |
| `kegOnly` / `autoUpdates` / `deprecated` / `disabled` | 同名顶层字段 | 徽标 / 警示 |
| `license` | `license` | 详情 |
| `categoryKey` | 自建（见 §5） | 分类 |

> 注意 formula 与 cask 的分析字段不同：formula 用 `install_on_request`，cask 只有 `install`。

### 4.2 详情 `BrewFormulaDetail` / `BrewCaskDetail`

直接透传的 Homebrew 字段：`token` `fullToken` `tap` `name` `desc` `homepage` `license` `stableVersion`
`headVersion` `kegOnly` `serviceSupported` `caveats` `bottleAvailable` `bottleTags` `bottleRebuild`
`dependencies` `buildDependencies` `optionalDependencies` `recommendedDependencies` `usesFromMacos`
`conflictsWith` `versionedFormulae` `aliases`；cask 侧为 `version` `autoUpdates` `artifacts` `dependsOn`。

派生字段（生成器计算，官方 API 没有现成的）：

| 字段 | 计算方式 |
|---|---|
| `installs30d` / `installs90d` / `installs365d` | 三个时间桶各取一次，含 `"<token> --HEAD"` 变体求和取大 |
| `bottleTags` | `bottle.stable.files` 的 key 排序 |
| `artifacts[].artifactType` / `path` | 把 `artifacts` 数组归一化，只保留真正的安装产物类型（app/pkg/binary/font/…），过滤 `uninstall` / `zap` / `target` |
| `zapPathCount` | 统计 `zap` 里的清理路径条数（UI 展示「可清理残留项 N 个」） |
| `installCommand` | `brew install [--cask] <qualified-name>`，第三方 tap 补 `tap/token` |
| ~~`recommendList`~~ / ~~`contentType`~~ | **已删字段**：实测详情页与 `BrewDetailNormalizer` 对它们零引用（同类包走的是首页快照，不是这个字段） |

### 4.3 生命周期三态

Homebrew 的废弃不是布尔值，而是**三态**：正常 → `deprecated`（可装但警告）→ `disabled`（不可装）。
模型用 `BrewLifecycleInfo` 统一承载：

```
deprecated / deprecationDate / deprecationReason / deprecationReplacementFormula / deprecationReplacementCask
disabled   / disableDate     / disableReason
```

UI 要求：`deprecated` 显示警示条 + 替代品跳转；`disabled` 显示不可安装态并禁用安装按钮。
当前 mock 里有 **6 个真实 deprecated/disabled 包**，正好覆盖这条路径的测试。

---

## 5. 详情页方案（决策变更记录）

### 5.1 原方案：复用组件演练场引擎（已废弃）

最初规划是把 `componentlibrary` 的「属性调试 + 代码生成」引擎直接改造成 brew 命令生成器：
详情里的 `props` 与 `component-details.json` 的 `props` 同构，靠 `AttributeChangeArea` 属性面板
交互，`CommonCodeGenerator` 改成输出 shell。

**该方案已废弃，原因有两条：**

| 原因 | 依据 |
|---|---|
| 官方 API 的 `options` 字段实测**恒为空** | 抽查 `ripgrep` / `redis` / `postgresql@16` / `kubernetes-cli` / `openjdk` / `node`，`options` 全部为 `[]` —— 现代 Homebrew 已移除绝大多数 formula options。原方案里的 `props` 是我自行构造的，没有真实数据支撑 |
| 引擎的核心槽位在 brew 场景无对应物 | `ConfigInterface.previewComponentBuilder` 与 `descriptor` 都是**必填**字段，设计前提是「有一个可实时预览的组件」。brew 的产物是命令字符串，没有可渲染的组件 |

因此原方案里的 `props` 已从模型与 mock 数据中**移除**（详情文件因此变小：formula 271.8 → 212.1 KB，cask 226.8 → 161.4 KB）。

### 5.2 现方案：另起一个市场风格详情页

- **不复用** `componentlibrary` 的详情页与其四契约引擎，也不再改它的共享文件（满足「现有入口全保留作对照」的约束）
- 详情页用**官方/一方组件**实现：`@kit.UIDesignKit`（HDS）已在本项目验证可用的 27 个符号 +
  ArkUI 官方基础组件，样式全部走 `$r('sys.color.*')` / `$r('sys.float.*')` / `$r('sys.symbol.*')` token
- 首页/列表**仍复用** `commonbusiness` 的 `BaseHomeView` / `BaseHomeViewModel` / `BaseHomeState`，
  卡片条目保留 `BaseData` 展示槽位（`subTitle` = token，`title` = 英文 desc）

### 5.3 详情页分区与数据来源

| # | 分区 | 数据来源 | 条件 |
|---|---|---|---|
| 1 | Hero：图标 + 名称 + `desc` + tap 来源 + 安装状态徽标 | `name` `desc` `tap` `installed` | 恒显 |
| 2 | 主操作：`brew install` 命令 + 复制按钮 | `installCommand` | 恒显 |
| 3 | 元信息：版本 / 许可 / 近 30 天安装量 / 分类排名 | `stableVersion`(或 cask `version`) `license` `installs30d` `categoryRank`+`categorySize` | 恒显 |
| 4 | **提供的命令**（formula）｜ **安装内容**（cask） | `executables` ｜ `artifacts[]` | 非空时 |
| 5 | 兼容性与要求 | `bottleTags` / `dependsOn.macos` → `macosRequirement` / `requirements` | 非空时 |
| 6 | 依赖（依赖 / 可选 / from macOS） | `dependencies` `optionalDependencies` `usesFromMacos` | 非空时 |
| 7 | 后台服务 | `serviceSupported` `serviceRun` `serviceRunType` | `serviceSupported` |
| 8 | 安装提示与 keg-only 说明 | `caveats` `kegOnly` `kegOnlyReason` | 非空时 |
| 9 | 生命周期警示条 + 替代品 | `deprecated*` / `disable*` | deprecated/disabled |
| 10 | 相关推荐 | `recommendList`（待补）+ 同分类包 | 恒显 |
| 11 | 来源与主页 | `tap` `homepage` | 恒显 |

**修正**：上表第 11 行原写作「源码与主页 / `urls.stable`」，但实测两个详情 JSON 里都**没有**源码仓库地址
（只有 `homepage` 与 `tap`），`urls.stable` 这个字段并不存在于当前模型。已改为「来源与主页 = `tap` + `homepage`」。
这类"文档写了、数据没有"的字段是最容易在实现时才发现的问题，实现前先核对一遍数据能省一次返工。

**没有的模块**（Homebrew 无数据源，不要设计）：评分/星级、用户评论、应用截图、包体积、
更新时间、changelog / What's New、"支持语言"（cask `languages` 实测全为空）。

### 5.4 热度表达（决策）

Homebrew 唯一的热度信号是安装量分析数据。约定：

- **近 30 天安装量** + **分类内排名**（`categoryRank` / `categorySize`，如 `3 / 14`）
- 不做"星级/热度条"这类推算表达，避免与真实用户评价混淆
- 榜单（Discover 的三张榜）取全局 `installs30d` Top N —— 早期产出在 `brew-*-banner.json`（**该产物与端点已删除**），然后是 `brew-discover-page.json`（**也已删除，2026-10**），现在只有**设备端现算的目录**，见 §7.4.1 与 `docs/brew-discover-algo.md`

### 5.5 `BrewCommandGenerator` 收敛后的职责

```typescript
BrewCommandGenerator.qualifiedName(token, tap)      // 第三方 tap 补 tap/token 前缀
BrewCommandGenerator.baseCommand(kind, token, tap)  // brew install [--cask] <name>
BrewCommandGenerator.installCommandOf(detail, kind) // 优先取数据里的 installCommand，缺失则回退计算
BrewCommandGenerator.uninstallCommand(kind, token, tap)
BrewCommandGenerator.upgradeCommand(kind, token, tap)
```

原方案里的 `argumentOf` / `generate(detail, kind, values)` / `defaultValues`（安装选项机制）已随决策移除。

## 6. 缓存与分层

对齐现有 `componentlibrary` 的三层结构：

```
UI (view/viewmodel)  →  BrewFormulaModel / BrewCaskModel / BrewSearchModel  (model/BrewRepository.ets, 单例)
                     →  BrewService                                          (service/BrewService.ets)
                     →  BrewHttp  →  聚合端点（目录/榜）+ 现网单条            +  Preference 缓存
```

> 2026-10：`HmosRequest = MockRequest → rawfile/mockdata/*.json` 这一层已删除。
> `BrewLocalModel` 也删了（它的替代品是 `BrewInstalledLoader`，见 §12.1.1）。

缓存策略（沿用 `ComponentListModel` 范式）：

```
先读 Preference 缓存 → 命中即返回
                    → 未命中走服务 → 成功后回写 Preference
详情：先走服务（保证新鲜）→ 失败回退 Preference
```

Preference 分组键：`brew_main_page_data` / `brew_detail_page_data` / `brew_local_data`，
子键形如 `formula_1_50`、`cask_2025`。

---

## 7. 现网数据源（已接入）

本节是 2026-09 接现网后的现状。上一版的“未来切真实数据的改动面”兑现了一半：
**签名与返回类型零改动**这条成立，**只改 Service 内部**这条不成立 —— 见下。

### 7.1 数据分两层，职责不同

| 层 | 来源 | 内容 | 能不能联网 |
|---|---|---|---|
| **骨架** | 内置 rawfile 快照 | 分类 / 成员 / 卡片版面 / 图标 / 本地 id / 榜单成员 | **不能**。官方 API 没有分类字段（§1.2），榜单成员靠全球分布算（discover-algo §3~§5） |
| **包自身属性** | 现网单条请求 | 版本 / 描述 / 依赖 / bottle / artifacts / 生命周期 / 许可 / 主页 / 安装量 | 能，且应该 |

因此**不存在“缓存整页”这种方案**：整页缓存会把现网值挡在外面（Discover 页吃过这个亏，见 BrewDiscoverModel 的注释）。
现网值的缓存粒度是**单个 token**（`brew_live_data` + `BREW_LIVE_TTL_MS` = 6h）。

### 7.2 改动面

| 文件 | 作用 |
|---|---|
| `service/BrewHttp.ets` | `@ohos.net.http` 的 GET JSON 封装（超时、状态码、字符串解码） |
| `service/BrewApiMapper.ets` | 官方 JSON → 应用模型；**`generate.py` 的 ArkTS 移植** |
| `service/BrewService.ets` | 单条拉取 + TTL 缓存 + 并发受限的批量 hydrate |
| `model/BrewRepository.ets` | hydrate 的**调用点**：返回给上层之前就把现网值填好 |
| `constant/BrewConstants.ets` | `BREW_DATA_MODE` 开关、并发/超时/TTL（API base 已移到 `BrewSourceStore`，见 §7.5.1） |

**为什么 hydrate 放在 Repository 而不是 VM/UI**：官方字段填完后模型形状不变，
VM 与组件一行都不用改（这就是当初说的“改动面小”）；
放在 UI 里还要额外解决 LazyForEach 的刷新问题（嵌套数组的字段变更不会触发重渲染）。

#### hydrate 的全部触发点（2026-09-22 清点）

| 层 | 调用点 | 触发条件 |
|---|---|---|
| 批量 | `BrewService.buildFormulaPage` / `buildCaskPage`（浏览页首页 **+ 分类二级页**，二级页复用 `getFormulaPage`） | **仅当索引不可信**（`covered < BREW_INDEX_MIN_TRUST`）：`missing = 前 BREW_BROWSE_HYDRATE_LIMIT 个 ∩ token ∉ 索引`，再剔除 `missCache` 幽灵 |
| 批量 | `BrewRepository.hydratePage`（Discover 首页 + 榜单二级页） | `BREW_DATA_MODE === REMOTE` 且 `page.boards` 非空 → 6 张榜的全部成员 |
| 单条 | `BrewRepository.getFormulaDetail` / `getCaskDetail` | 详情页主体，1 个 token |
| **间接** | `BrewRepository.getSameCategoryPackages`（详情页「同分类其他包」） | → `getCategoryPackages` → `getFormulaCategories` → `getFormulaPage` → **整页 hydrate**（§9.13 记过这个坑） |

**不触发 hydrate 的**：搜索（`BrewSearchEngine` 只读目录 + 索引，零请求）、Mine 的本机包（读 rawfile）、索引覆盖的浏览条目。

#### `browse … built` 行的三个新字段（读法）

```
browse formula built, 7299/7392 tokens ready (catalog 7392, index 7299, dropped 93, hydrate 0, trusted=true), …
```

| 字段 | 含义 | 什么时候该警觉 |
|---|---|---|
| `ready/catalog` | 上屏条数 / 目录全量。**分母是目录全量**（不是候选集），跨改动可比 | — |
| `index` | 索引覆盖的目录行数 | 突然变小 → 元数据同步没成功或扫描口径变了 |
| `dropped` | `catalog − index`：目录里不在索引里的 token 数。**两种成因**：上游幽灵（`formula.json` 里没有）与 cask 的 `desc: null`（落盘故意不写空串） | formula 从 ~93 持续变大 → 可能上游开始漏包；**cask ≈2645 是正常的，不要当 bug 修** |
| `hydrate` | 本次发出的单条请求数。**主路径应恒为 0** | 非 0 → 闸门没生效 |
| `trusted` | 走的是主路径（`true`）还是降级路径（`false`） | 期望恒为 `true`；`false` 且页面很慢 → 索引不可信，去看 `[BrewMetaSync] meta sync` 那几行 |

### 7.3 拉取策略与容量（实测）

| 端点 | 实测大小 | 用不用 |
|---|---|---|
| `/api/formula/<token>.json` | **~5 KB** | ✅ 详情与列表 hydrate 全走它 |
| `/api/cask/<token>.json` | ~3~5 KB | ✅ |
| `/api/formula.json` / `cask.json` | **32.4 MB / 18.9 MB**（**gzip 实测 5.29 MB / 2.05 MB**） | ❌ **严禁下发**（指**页面加载路径**）。全量列表就是靠它做不到，所以列表内容仍是内置清单里的成员。若改成**后台**同步则是另一回事 —— 见 `brew-catalog-fullsync-spec.md` §1.3 / §4.6（同一批实测数据） |
| `/api/analytics/install/30d.json` 等聚合端点 | 1.25 MB ~ 3.9 MB | ❌ App 端不用（榜单成员与门槛仍是快照） |

并发与超时（`BrewConstants`）：

| 参数 | 值 | 理由 |
|---|---|---|
| `BREW_HYDRATE_CONCURRENCY` | 6 | 官方是 GitHub Pages + Fastly，实测 6 并发不触发限流 |
| `BREW_HYDRATE_TIMEOUT_MS` | 6s | 超时**不是失败**：已拿到的值照常用，剩下的请求后台跑完写进缓存，下次秒开 |
| `BREW_LIVE_FRESH_MS` | 1h | **新鲜窗口**（不是“过期就重下”的 TTL）。过期后先探针、再条件请求，见 §7.7 |

代价必须说清楚：一页 100 个条目 = 100 次单条请求（首屏约 2s，新鲜窗口内为 0）。
这是“不下发 32 MB 全量包”的必然结果；要更快只能自建一个把聚合结果压小的服务端。

#### 两个全量包的真实形状（实测，写解析代码前必看）

| | `formula.json` | `cask.json` |
|---|---|---|
| 对象数 | **8,611** | **7,745** |
| 标识字段 | `"name":"<token>"`（就是安装用 token） | **`"token":"<token>"`**；`"name":` 是**显示名数组**（`["0 A.D."]`） |
| `desc` | 每条都有 | **2,645 条是 `null`**（上游就没描述 → 这些包在本 App 里无法分类、不会上屏，旧链路同样如此） |
| 其他 `desc` 锚点 | 无 | `variations` 里有嵌套 `desc`（如 `{"variations":{"sequoia":{"desc":…}}}`），出现在对象自身 desc **之后** |

按字段顺序取数时，锚点必须与标识字段按 kind 对应；只认 `"name":` 会让 cask 整包一条都扫不出来。

### 7.7 主动 probe：数据集探针 + 条件请求（实测定型）

原来只有“6 小时盲猜 TTL”：到期就把 240 个文件重下一遍（约 1.2 MB）。现在改成三级：

```
① ts 在新鲜窗口（1h）内        → 直接用，零请求
② 数据集探针（每个 kind 1 次）  → HEAD /api/formula.json + If-Modified-Since
     304 → 整批未变 → 全部续期（ts=now），**0 字节、不解析、不落盘**
③ 探针说“变了”（或探针失败/无基准）→ 对单个 token 发条件请求
     304 → 0 字节续期；200 → 收下全文（幂等）
```

**为什么一个 HEAD 能代表 240 个文件**：实测单条文件的 `Last-Modified` 与全量包**完全相同**
（整批一次性生成），所以“`formula.json` 变了吗”就是“整批变了吗”。

#### 关键实测：这个 CDN 的 ETag 不可靠，`Last-Modified` 才可靠

| 探测方式 | 实测命中 304 | 说明 |
|---|---|---|
| 单条 + `If-None-Match`（ETag） | **1/5** | ETag 前缀就是源文件 mtime（`6aaca79a-13c7`），**同一 URL 在不同 POP 上不一致**（差 1 秒） |
| 单条 + `If-Modified-Since` | 1/5 | 当轮基准落后一代时；基准追上后会变好 |
| **全量包 HEAD + `If-Modified-Since`** | **4/5** | “批次时间”跨节点一致性明显高于单文件 ETag |

所以实现里 **`If-Modified-Since` 优先、`If-None-Match` 兜底**（与常规 HTTP 客户端的直觉相反，
这是本项目量出来的结论）。响应头里 `Vary: Accept-Encoding` + 源站持续重新生成，
意味着“探针说变了”并不罕见——这不是错误，退到条件请求即可。

#### 判据：一行日志对账

每批 hydrate 结束后跟一行：

```
hydrate done, 119/119 (failed 0), 5ms | session hit=0 renewed=716 notModified=0 dl=0(cond=0 nocond=0) failed=0
```

| 字段 | 含义 | 怎么用 |
|---|---|---|
| `hit` | 新鲜窗口内直接命中 | 温启动应该全是它 |
| `renewed` | 探针 304 后整批续期 | 超过新鲜窗口且数据集未变时的预期形态 |
| `notModified` | 条件请求 304 | 0 字节重校 |
| `dl(cond/nocond)` | 真下载；带/不带条件头 | **`nocond>0` 说明本地没存到基准**（旧格式缓存条目会自愈）；`cond>0` 说明该副本比基准新 |

实测三态（同一份代码，只改新鲜窗口/探针基准）：

| 场景 | 结果 |
|---|---|
| 温缓存（窗口内） | `hit=1242 renewed=0 ... dl=24(nocond=24)`，4~6ms（24 是旧格式条目的自愈） |
| 窗口=0 + 数据集未变 | `renewed=716 downloaded=0`，**零字节** |
| 窗口=0 + 数据集“变过” | `notModified=401~514`（0 字节）+ 少量 `dl(cond=…)` |

### 7.4 各页面的现网化范围

| 页面 | 骨架 | 现网字段 | 备注 |
|---|---|---|---|
| Formulae / Casks 首页 | 分类卡与成员 | 每个条目的版本/描述/安装量/生命周期 | 名次按现网安装量在**本分类内**重排，与卡片上的数字自洽 |
| ~~本周热门 banner~~ | ~~Top4 的成员来自快照~~ | —— | **端点已删除**：从来没有 UI 调用点（两个首页 `bannerHeight` 固定为 0） |
| 包详情页 | **首页条目的 14 个字段**（id / 分类 / 名次 / desc / 版本 / 安装量 / 生命周期…） | 除上述外还有依赖、bottle 标签、artifacts、caveats、安装命令 | 分类名次用同分类的现网值校正，避免“安装量是新的、名次是旧的”。骨架不再是 243 KB 的 details 文件（已删）：**现网那步失败时会降级成骨架字段**（其余段落不渲染，不是错误页） |
| 榜单二级页 | 整个榜单（成员与顺序） | 同首页 | 复用同一次 hydrate |
| **Discover 三榜** | id / 分类（join 用） | **成员与数字全部现网**：聚合端点 → 设备端现算（见 §7.4.1） | 之前是“成员快照、数字现网”，现已统一 |
| **我的（本机包）** | 纯 Mock | —— | HarmonyOS 上没有 `brew` 可执行，**没有真源**；将来要么接服务端上报，要么保持演示数据 |

#### 7.4.1 设备端目录：聚合端点 + 现算三榜 + 设备端浏览页

> 算法口径的唯一权威说明在 `docs/brew-discover-algo.md`（§3/§5 公式、§7 两端实现、§7.4 对账、§7.5 join）。
> 本节只说**取数与落地**这一层。

**为什么值得单独一层**：三张榜的成员必须从**全量分布**里算（门槛是全球分位、还要 family 去重），
而不是从内置的 240 个包里选。接上 4 个聚合端点后，成员变成每次刷新现算。

| 端点 | raw | **gzip** | 用途 |
|---|---|---|---|
| `analytics/install-on-request/homebrew-core/30d.json` | 440 KB | 83 KB | Formula 趋势/新星 |
| `analytics/install-on-request/homebrew-core/365d.json` | 664 KB | 127 KB | Formula 历史 + prior |
| `analytics/cask-install/homebrew-cask/30d.json` | 317 KB | 61 KB | Cask 趋势/新星 |
| `analytics/cask-install/homebrew-cask/365d.json` | 478 KB | 96 KB | Cask 历史 + prior |
| **合计** | **1.9 MB** | **358 KB** | 覆盖**全量** 7,916 formula + 5,863 cask token |

对照：本层现有的单条 hydrate（240 条 × 单条 gzip 约 1.2 KB）合计约 **292 KB**，只覆盖白名单。
即“多花 66 KB，从 240 个包变成 1.3 万个包”，顺带拿到全量 token 名单（搜索的前提）。

**取数策略（粒度是「整批」）**：

```
① ts 在新鲜窗口（1h）内 → 直接用，零请求
② 4 个端点并发带 If-Modified-Since 探一下
     4/4 都是 304 → 沿用已算好的榜单，**0 字节**
③ 否则 → 没带回响应体的那几个无条件补取 → 重算 → 落盘
```

- **为什么不做逐端点增量合并**：只重取变了的那一个时，另一个窗口的计数拿不到，
  而三张榜依赖的是**完整分布**（分位数、family 去重都建立在全量上）。
- **实测命中率 3/4**（不是 4/4）：4 个端点落在不同 CDN 节点上，节点持有两代副本的现象
  在聚合端点上也存在（见 §7.7 那张表：`Last-Modified` 跨 POP 差 1 秒）——一个节点返回 200，
  其余三个 304 的被补取，所以这一轮花的是 358 KB 而不是 0。
  数据本身没变（窗口与 `total_count` 与上一轮完全相同），所以正确性不受影响。
  想把这一轮也降到接近 0 字节，需要把**摊平后的 counts 一并落盘**（约 400 KB Preference），
  这样 304 的那几个就不必补取 —— 暂不做，因为频率是“每小时最多一次”。

**落盘**：`BREW_CATALOG_STORAGE_KEY`（`brew_catalog`），内容 = 六张榜（每榜留 `BREW_CATALOG_KEEP`=40 条）
+ **按 30d 安装量降序的 token 表**（每 kind 目录全量，不裁切 —— `BREW_BROWSE_KEEP` 已随 fullsync 阶段 2 删除）
+ 每 kind 的窗口/规模/门槛实测值 + 4 个端点的 `Last-Modified` 基准。

**浏览页（两个页签的首页都走它）**：

```
目录.topTokens[kind]（按 30d 安装量降序，目录全量、不裁切）
  → 索引可信？ covered >= BREW_INDEX_MIN_TRUST（=100）
      是 → candidates = 目录 ∩ 索引，**不发任何单条请求**            ← 2026-09-22 起的主路径
      否 → candidates = covered > 0 ? 目录全量 : 前 BREW_BROWSE_HYDRATE_LIMIT 个
           → 只为缺失的 token 拉现网单条（并发 6，预算 BREW_BROWSE_HYDRATE_MS = 15s）  ← 降级路径
  → ready = candidates 中有非空 desc 的（宁缺不错：desc 是分类的输入）
  → 分类：BrewTaxonomy（策展覆盖 → 关键词(desc) → 主题词 → 兜底）
  → 组装分类卡（styleType 按 STYLE_CYCLE、名次在分类内按 30d 重排）
```

`BREW_BROWSE_LIMIT`（硬裁切 100）已随 `brew-catalog-fullsync-spec.md` 阶段 2 删除；
浏览集从“能否拿到 desc”的预算问题变成了“索引里有没有它”的存在性问题 ——
详见 `docs/superpowers/specs/2026-09-22-brew-coldstart-design.md`。

- **为什么 desc 是构页输入而不是可选刷新**：官方 API 没有分类字段，分类只能看 `desc` 算，
  而 `desc` 只在单条响应里。实测 6s 预算只拉到 53/100 条，剩下的 `desc` 为空 → 关键词判不出来
  → 全被塞进兜底分类 —— 页面看起来正常但**分类是错的**。所以：用 15s 独立预算，且
  **没拿到 doc 的条目不上屏**（宁缺不错），下次进页面它们已在 TTL 缓存里。
- **id 用哈希**：`token_id(token)`（FNV-1a 32 位，生成器与设备端**同一个函数**），
  只当路由参数与 Preference 缓存键；详情页按 token 查，所以碰撞也无害。
- **兜底档与真实分类共用 key**（formula `system` / cask `systemtool`）——与 `generate.py` 一致，
  所以日志里 `system=50` 是"真实 system 分类 + 判不出关键词的包"之和，不是异常。
- **无网时的行为**：内置 page 快照已删除，所以两个页签是**空列表**（不是错误页、也不是旧数据）。

**开关与回落**：`BREW_CATALOG_MEMBERSHIP`（默认开）关掉即退回快照成员；
目录取数失败（`catalogFailed` 计数可查）时打印 `catalog unavailable, discover members stay from snapshot`
并继续用快照 —— **不把 Discover 页变成错误态**。

**一个必须知道的副作用**：成员来自目录后，榜单数字**不再**用单条文档的 `analytics` 覆盖
（那是另一个时间窗口的数据，混用会让“名次与数字”出现跨窗口的不自洽）。
单条 hydrate 仍会跑，但只用于取 `desc` / `name`，并顺带把详情页要用的文档预热进缓存。

### 7.5 开关

**2026-10：`BREW_DATA_MODE` 已删除**（原名 `BREW_DATA_SOURCE`，2026-09-23 改名 ——「数据源」一词已让给多源特性）。
它原本是三态里的两态开关：

- ~~`REMOTE`（默认）：现网字段 + 内置骨架，请求失败静默回落快照值~~
- ~~`SNAPSHOT`：一个请求都不发，完全用内置快照~~

两份内置数据（骨架快照与整包）都不存在之后，这个开关只剩「关掉整个数据层」这一个作用，
而那不如直接把数据源从注册表里删掉（§7.5.1 做不到，但那时是真故障，不是可切换的展示形态）。
现在唯一的口径是：**取数失败 → 空态**（Formulae / Casks 空页、Discover 空榜、Mine 空列表），
`BREW_CATALOG_MEMBERSHIP`（「关掉就退回快照成员」）同理由一并删除。

### 7.5.1 多数据源与按源缓存（2026-09-23 实现）

`BREW_API_BASE` 常量已删除，base URL 改为运行期从**会话冻结的 active 源**解析
（`BrewSourceStore.activeBaseUrl()`）。用户可在 Mine > 设置 > 数据源 里维护多个镜像地址。

| 概念 | 实现 | 说明 |
|---|---|---|
| 源注册表 | 主 store 的 `brew_sources`（`BrewSourceStore`） | 官方源恒在第 0 项、`builtin`、不可删、baseUrl 固定 |
| 每源缓存 | 独立 store `brew_src_<id>`（GSKV，`BrewSourcePrefs`） | 六条缓存键名不变，隔离由 store 承担 |
| 会话冻结 | `BrewSourceStore.sessionActive()` | 写 `activeId` 对当前进程零影响 → **切换必须重启** |
| 激活 | `BrewSourceProbe` 单端点探测 → 确认弹窗 → `setActiveId` → `BrewSourceRestart` | 探测失败**硬阻断**；重启三级兜底 |
| 维护 | `BrewCacheAdmin` stats / clear / drop | 清空激活源会重置内存态；`BrewCacheEpoch` 守卫防在途回填 |
| 健康 | 主 store 的 `brew_source_health` | 「部分可用」= 单条文档 OK 但目录/全量包持续失败 |
| 自检 | `BrewSourceDiagnostics` + `BREW_SOURCE_VERIFY`（默认关） | 本项目不用 ohosTest 的一次性验证通道 |

**为什么每源一个 store 而不是「共享 store + 键前缀」**：Preferences 是「一个文件一个实例、整份加载、
整份落盘」，共享 store 下加载/flush/删除的成本随**源数量**线性增长（3 个源时每次 flush 要重写 8MB+）；
而独立 store 只加载/只重写当前激活源，「删源」退化成删文件，且**漏改调用点会编译不过**（不会静默串源）。

**不搬走的**：`brew_search_history` 仍在主 store（用户资产，不是源缓存，不参与查看/清空/删源连带）。

**两条容易写错的硬规（都踩过）：**

1. **GSKV 不是「实时落盘」**。它先写内存缓存页，只有 `removePreferencesFromCache` 才保证写盘 ——
   App 从不优雅退出（进程被系统回收 / 被覆盖安装杀掉），所以**每个必须跨进程生效的写入后都要
   显式 `BrewSourcePrefs.persistNow()`**（`clear` / `saveCatalog` / `flushCache` / `persistIndex` 四处）。
   真机实测：不调它时，写入后 ~25s 内被杀 → 下次启动缓存丢失；最严重的后果是**清空缓存不持久**。
2. **世代号守卫只能是「入口捕获 + 写前比对」，严禁在 drop 分支里改写 epoch**。
   曾经的写法是「不匹配就把 epoch 改成当前值再 return」= 只保护 bump 后的第一次写入；
   而 `BrewMetaSync.epoch` 是 `rememberStamp` 与 `persistIndex` 共用的一个 static、且前者先执行，
   于是那一次配额被几十字节的 `brew_meta_stamp` 用掉，**1MB 的 `brew_meta_index` 照写不误**
   —— 「清了没清掉」而日志看起来守卫生效了。捕获点只能是：`hydrate` / `conditionalFetch` /
   `getCatalog` / `BrewMetaSync.sync`。

设计全文、实施记录与全部偏差：
`docs/superpowers/specs/2026-09-23-brew-multi-source-design.md`（尤其 §15）；
计划：`docs/superpowers/plans/2026-09-23-brew-multi-source.md`。

### 7.5.2 Harmonybrew 方言适配（2026-09-24 实测）

Harmonybrew 分支 `https://harmonybrew.atomgit.com/api` 不是 formulae.brew.sh 的镜像：它只发布一份
按 bottle tag 分区的 JWS 目录，没有 per-token 端点、cask 或 analytics。应用在 transport 边界用
`BrewSourceAdapter` 分派方言，并把它归一化成既有的 `LiveFormulaDoc`；缓存、TTL、在途去重和
世代号守卫仍走原链路。`BrewSource.dialect` 为 `upstream`（内置源及存量源）或 `harmonybrew`。

#### 端点与实测形状

| 用途 | 上游请求 | Harmonybrew 实测 |
|---|---|---|
| 探测 | `GET /formula/wget.json` | `GET /internal/packages.<tag>.jws.json`，`Range: bytes=0-1023` |
| 全量目录 | `GET /formula.json` / `cask.json` | 同一个 JWS 文件；2026-09-24 实测 3,973,524 B，解包后 3,659,172 B |
| 单条详情 | `GET /formula/<token>.json` | 不存在；同步时按公式行写入本地目录，详情随机读对应切片 |
| analytics | 4 个 30d/365d 聚合端点 | 不存在，`supportsAnalytics=false` |
| cask | `cask.json` / `cask/<token>.json` | `casks={}`，`supportsCasks=false` |

外层是 JWS 信封，目录是 `payload` 字段中的**转义 JSON 字符串**：

```text
{"payload":"{\"metadata\":{\"bottle_tag\":\"arm64_ohos\",…},\"formulae\":{\"wget\":{…}},\"casks\":{}}","signature":"…"}
```

`payload` 必须显式校验为字符串；内层 `formulae` 是以 token 为键的字典，值里没有 `token/name`。
2026-09-24 实测 `formulae=4761`、`casks=0`，单条归一化 doc 中位数约 703 B、最大 5,663 B。
`BrewJsonScan` 按字符串、转义和嵌套深度找每个第一层 formula 对象边界，不靠 `indexOf`，避免 token
在 `desc` 文本中出现时串行。

服务端发布的无签名旧文件 `packages.arm64_ohos.json` 已陈旧 86 天，**不能使用**；当前目录必须取
`packages.arm64_ohos.jws.json`。端点中的 tag 来自 payload 的 `metadata.bottle_tag`，应用先用默认
`arm64_ohos` 探测，识别后把真实 tag 写回源配置。

#### 响应头条件（与上游相反）

| 能力 | Harmonybrew 实测 | 实现约束 |
|---|---|---|
| `HEAD` | 200，带 `Content-Length`、`ETag`、`Last-Modified` | 可用但目录同步仍走 GET |
| `Range` | 206 | 首 1 KB 同时验信封、content type 与 bottle tag |
| `If-None-Match` | **304，可靠** | ETag 是目录同步的条件请求基准 |
| `If-Modified-Since` | **不生效，仍回 200 + 全量 body** | 不可拿 IMS 当新鲜度基准 |
| `Accept-Encoding: gzip` | 不支持，无 `Content-Encoding` | 每次约 3.97 MB 明文 |
| `Content-Type` | `application/json` | 探测必须校验 |

#### 字段映射

唯一实现位于 `HarmonybrewMap.formulaToLive`。普通字段按同名映射；不能直接改名的 DSL 调用参数按下表反解：

| `LiveFormulaDoc` | Harmonybrew 原始值 |
|---|---|
| `token/name/full_name` | `formulae` 字典键 |
| `tap` | 不设；使用默认 core 即可生成 `brew install <token>` |
| `versions.stable/head/bottle` | `stable_version` / `head_url_args` 是否存在 / `bottle_checksum` 是否存在 |
| `bottle.stable.rebuild/files` | `bottle_rebuild ?? 0` / 只放响应 tag 键（应用当前不消费 bottle URL） |
| `keg_only` | 仅 `keg_only_args[0] === ':versioned_formula'` 为 true；`:provided_by_macos` / `:shadowed_by_macos` 为 false |
| `keg_only_reason` | `{reason: keg_only_args[0], explanation: keg_only_args[1] ?? ''}`，**保留前导冒号** |
| `deprecated/disabled` | 对应 args 的 `:date` 不晚于本地日期才为 true；不能只看字段存在 |
| `deprecation_reason` / `disable_reason` | args 的 `:because` **去掉前导冒号** |
| `dependencies/build_dependencies` | 拆 `stable_dependencies` 的字符串项和 `{name: ':build'}` 项 |
| `uses_from_macos` | 把 `stable_uses_from_macos` 的调用参数数组展平一层 |
| `conflicts_with` | 每项 `conflicts` 调用参数数组取 `[0]` |
| `service` | `service_run_args[0]` 数组原样放入 `{run: …}` |
| `analytics` | 无；能力开关负责阻止无效请求 |

三个实测陷阱均由 `BrewSourceDiagnostics` 固定样本覆盖：`apr` 的 provided-by-macos 不算 keg-only、
`ant@1.9` 的 versioned-formula 算 keg-only；`access` 的过期日期生效而 2999 年样本不生效；
deprecation reason 去冒号、keg-only reason 留冒号。依赖拆分与 uses-from-macos 展平分别以
`aliddns`、`apr-util` 样本断言。

同步先把完整目录落盘，再保存 ETag。只有索引和本地目录都存在时才发送 ETag；否则服务端返回 304
会让已丢失的目录永远无法重建。本地正文位于
`filesDir/brew_src/<sourceId>/catalog.tsv`（每行 `token\t<归一化 doc JSON>\n`），偏移表在对应
`brew_src_<sourceId>` Preferences 的 `brew_catalog_offsets`。清空或删除源时二者一并删除；现有六条
缓存键不变。目录全量下载、两次 `JSON.parse`、4761 次映射与约 3.4 MB stringify 当前仍在主线程，
预计有 0.5~2 秒可感知卡顿。

### 7.6 本机状态（未接）

`brew info --json=v2 --installed` / `brew outdated` / `brew services list` 的输出形状已经落到模型字段上
（`BrewInstalledPackage` 等），但 HarmonyOS 侧拿不到这些命令的输出，模型暂时由 `brew-local-*.json` 供数。

---

## 7bis. 原「未来切真实数据的改动面」（历史记录，保留供对照）

| 目标 | 改动位置 | 上层影响 |
|---|---|---|
| ~~接 formulae.brew.sh~~ | ~~仅 `BrewService` 内部实现~~ | ~~无（签名与返回类型不变）~~ |
| 拉取策略 | 单条 `/api/formula/<token>.json`、`/api/cask/<token>.json`；**严禁**下发 `formula.json` / `cask.json`（数十 MB） | 无 |
| 分类 | 真实 API 无分类字段 → 分类仍需自建。可保留生成器离线聚类，或把 `lexicon.json` + `overrides.json` 移植到服务端/ArkTS 侧 | 无（`categoryKey` 已在数据里） |
| 本机状态 | 解析 `brew info --json=v2 --installed` / `brew outdated --json=v2` / `brew services list` | 无（`BrewInstalledPackage` 等模型已按 brew 输出字段命名） |
| 搜索 | 在已加载的 `BrewPackageItem[]` 上本地过滤；无需新 trigger | 新增 `BrewSearchService`（已规划，本轮不实现） |

---

## 8. Mock 生成器

位置：`hmosword-build/brew-mockgen/`

| 文件 | 作用 |
|---|---|
| `categories.json` | 17 个分类定义（**9 formula** + 8 cask），含 `key` / `en` / `zhKey` / `symbol`。formula 的第 9 类是 `lib`「库与框架」——**只作形态兜底桶**（`lexicon.json` 的 `_forms`），不参与关键词打分 |
| `tokens.json` | 精选 200 个 token → 分类的 **override 表**（最高优先级，短路前三层） |
| `lexicon.json` | 三层词表：`<kind>` 关键词 + 阈值（打分取最优）、`_subjects` 主题词（中心名词 → 分类） |
| `generate.py` | **已停产（2026-10）**，只做**策展清单校验**（结构合法 + 逐个 token 问上游是否还在，退出码 0/1）。也是分类口径的**参考实现**（`classify()` / `subject_terms()` / `form_bucket()`）—— `eval_lexicon.py` 直接 import 它们 |
| `gen_taxonomy.py` | 由两份 JSON 生成设备端 `BrewTaxonomy.ets`（`--check` 可校验磁盘文件是否与词表一致） |
| `eval_lexicon.py` | 在现网全量上量兜底率、对比几种改法（输出 `lexicon-eval.md`）。**改词表前后都该跑** |
| `check_algo.py` | Discover 榜单算法的**参考实现 + 不变量自检**（榜单口径的唯一权威；自带 `--fetch`，数据管道独立） |

```bash
python3 generate.py            # 结构校验 + 逐个 token 问上游（命中 .brewgen/cache 时零请求）
python3 generate.py --refresh  # 忽略缓存，强制重新拉取
python3 generate.py --local    # 只做结构校验，完全不联网
```

> **2026-10：`generate.py` 不再产出任何文件。** 内置 mock 数据与整条 Mock 请求链路已删除，
> `rawfile/mockdata/` 整个目录已不存在，`check_types.py` 随之删除。`tokens.json` 仍然是
> 设备端分类的**策展层数据源**（`BrewTaxonomy.ets` 由它 + `lexicon.json` 生成），所以这份清单
> 仍然要有人看着 —— 这就是 `generate.py` 现在的职责。

产出到 `common/src/main/resources/rawfile/mockdata/`（**该目录已于 2026-10 整体删除**）：

| 文件 | 大小 | 内容 |
|---|---|---|
| ~~`brew-formula-page.json`~~ | ~~81.3 KB~~ | **已删除（C 档）**，见 §7.4.1 |
| ~~`brew-cask-page.json`~~ | ~~86.1 KB~~ | **已删除（C 档）**，见 §7.4.1 |
| ~~`brew-{formula,cask}-details.json`~~ | ~~374 KB~~ | **已删除**（详情骨架改从首页条目合成，见 §7.4 与 §10.4） |
| ~~`brew-{formula,cask}-banner.json`~~ | ~~2.4 KB~~ | **已删除**（无 UI 调用点） |
| ~~`brew-discover-page.json`~~ | ~~22.8 KB~~ | **已删除（2026-10）**，见 §2 端点表 |
| ~~`brew-local-overview.json` / `brew-local-formulae.json` / `brew-local-casks.json` / `brew-local-outdated.json` / `brew-local-taps.json` / `brew-local-services.json`~~ | ~~0.3–13.9 KB~~ | **已删除**（前三个在 2026-09 因无调用点删除，最后三个 brew 本机包文件在 2026-10 删除） |
| ~~`component-page.json` 等对照资源~~ | —— | **已删除（2026-09/10）**，`rawfile/` 目录已不存在 |

数据全部来自 formulae.brew.sh 的真实数据。
`.brewgen/` 是拉取缓存，可安全删除。

### ~~字段类型自检（`check_types.py`）~~（2026-10 随 mock 删除）

`BrewModels.ets` 里每个字段都声明了具体类型，而 JSON 是弱类型的。**JSON 的形状与声明不符时，
ArkTS 编译不会报错** —— 类型检查看的是声明，不是数据。
`check_types.py` 曾用「同一字段在不同条目里的类型是否一致」发现这类问题。
**它扫描的是 `rawfile/mockdata/`，那个目录已经不存在，所以脚本一并删除。**
JSON 不再入库之后，这条风险本身也消失了（数据只有一种来源：`BrewHttp` 的响应，
而它的形状由 `LiveFormulaDoc` / `LiveCaskDoc` 声明并在解析处收敛）。

它当初抓到并修掉的两处（记录在此，因为**同样的风险会以另一个形式回来** ——
现网某个包的字段形状与预期不符时）：

| 字段 | 声明 | 实际 | 成因 |
|---|---|---|---|
| `formula.serviceRun` | `string[]` | 98 条 list、1 条 str、1 条 dict | Homebrew 的 `service.run` 有三种形态：数组 / 单条命令 / **按平台分的字典**（`podman` 是 `{"linux": [...]}`） |
| `cask.bundleVersion` | `number` | 97 条 int、3 条 str | 它是点分版本号，Homebrew 侧类型不固定（`'15526.9.3'`、`'152.0.4191.66'`） |

两处都已在归一化层（`BrewApiMapper` / `BrewDetailNormalizer`）收敛，
`bundleVersion` 的模型类型也随之从 `number` 改为 `string`。

`BrewModels.ets` 里每个字段都声明了具体类型，而 JSON 是弱类型的。**JSON 的形状与声明不符时，
ArkTS 编译不会报错** —— 类型检查看的是声明，不是数据。运行期要么被 JS 隐式转换掩盖，
要么在比较/运算处悄悄出错。

`hmosword-build/brew-mockgen/check_types.py` 用「同一字段在不同条目里的类型是否一致」来发现这类问题：
真实数据里同一个字段出现两种类型，几乎总是意味着模型里的类型假设写错了。

```bash
cd hmosword-build/brew-mockgen && python3 check_types.py
# ✅ 12 个 mock 文件字段类型一致   （退出码 0=通过 / 1=有问题）
```

它是写详情页时才补上的，一跑就抓到两处**早就存在**的问题：

| 字段 | 声明 | 实际 | 成因 |
|---|---|---|---|
| `formula.serviceRun` | `string[]` | 98 条 list、1 条 str、1 条 dict | Homebrew 的 `service.run` 有三种形态：数组 / 单条命令 / **按平台分的字典**（`podman` 是 `{"linux": [...]}`） |
| `cask.bundleVersion` | `number` | 97 条 int、3 条 str | 它是点分版本号，Homebrew 侧类型不固定（`'15526.9.3'`、`'152.0.4191.66'`） |

两处都已在归一化层（`BrewApiMapper` / `BrewDetailNormalizer`）收敛，
`bundleVersion` 的模型类型也随之从 `number` 改为 `string`。

~~**注意生成器是确定性的**：这两处修复只改动了两个 detail 文件，其余 page / banner / local 文件字节级未变 ——
可以据此判断"重新产出"是否引入了非预期变化。~~（2026-10：已无产物，这条性质随产物一同退场）

### 分类数据分布

| Formulae | 数量 | Casks | 数量 |
|---|---|---|---|
| terminal 终端与 Shell | 14 | devide 开发与 IDE | 14 |
| devtools 开发工具链 | 16 | browser 浏览器 | 10 |
| network 网络与传输 | 12 | productivity 效率与笔记 | 12 |
| data 数据与数据库 | 12 | comm 通讯与协作 | 12 |
| cloudnative 容器与云原生 | 14 | design 设计与创意 | 12 |
| media 媒体与图像 | 10 | av 音视频 | 12 |
| ai AI 与机器学习 | 10 | systemtool 系统工具 | 14 |
| system 系统与运维 | 12 | aivm AI·虚拟机与容器 | 14 |
| **合计** | **100** | **合计** | **100** |

### token 替换记录（首次拉取时的 404 修正）

| 原 token | 实际 token | 原因 |
|---|---|---|
| `kubectl` | `kubernetes-cli` | `kubectl` 只是 alias，单条 API 不解 alias |
| `terraform` | `opentofu` | `terraform` 已移出 homebrew/core |
| `dog` | `doggo` | 原名不存在 |
| `usql` | `miller` | 原名不在 core |
| `whisper-cpp` | `whisper.cpp` | 命名带点 |
| `things` | `ticktick` | cask 已下架 |
| `pixelmator-pro` | `lunacy` | cask 已下架 |
| `handbrake` | `subtitle-edit` | cask token 变更 |
| `movist` | `movist-pro` | cask token 变更 |
| `docker` | `docker-desktop` | cask 实际叫 `docker-desktop` |

---

## 9. 构建图与验证方式（重要）

这一节记录一个容易踩的坑，它直接影响后续每一步的验证可靠性。

### 9.1 HAR 的 ArkTS 是随消费方 HAP 编译的

`brewcommon` 是独立 HAR，它**没有自己的 `CompileArkTS` 任务**。用 `devecocli build --modules brewcommon` 能看到的任务只有：

```
:brewcommon:default@PreBuild / @CreateHarBuildProfile / @MergeProfile
:brewcommon:default@ConfigureCmake / @BuildNativeWithCmake / @BuildNativeWithNinja
:brewcommon:default@ProcessLibs / @DoNativeStrip
```

真正的 ArkTS 编译发生在 `:pc:default@CompileArkTS` —— 即消费方 HAP 的编译阶段。而 ArkTS 编译是**按可达性**做的：只编译从入口出发 import 得到的模块。

### 9.2 两个由此推出的结论

| 结论 | 说明 |
|---|---|
| **`BUILD SUCCESSFUL` 不等于新模块被验证** | 如果没有任何可达代码 import 它，它的 `.ets` 一个也不会被编译，构建仍然成功。本项目第一次构建 brewcommon 时就是这样空跑了一次 |
| **`Index.ets` 的静态再导出是有效的强制编译手段** | `export { X } from './path'` 在 ESM 语义下是模块图的静态边，会连带编译目标文件。所以只 import 一个 `getCategoryNameMap`，就把 `BrewModels` / `BrewConstants` / `BrewCommandGenerator` / `BrewService` / `BrewRepository` 全部拉进了编译 |

### 9.2.1 补充实测：带 `routerMap` 的 HAR 会被编译，不需要伪造 import

上面两条结论有个重要例外，是写 `brewdetail` 时实测出来的。

`features/brewdetail` **没有任何模块 import 它** —— 它只被路由名字符串引用（`PageEnum.BREW_DETAIL_VIEW`
是个字符串常量，`pushPath` 按名字查找）。按 §9.2 的说法它的 ArkTS 应该不会被编译，但实测：

| 检查 | 结果 |
|---|---|
| `modules.abc` 中的符号 | `BrewDetailView` 104 处、`BrewDetailBuilder` 3 处、`BrewDetailViewModel` 13 处，其余组件同样存在 |
| HAP 合并路由表 | 19 条，含 `BrewDetailView -> src/main/ets/view/BrewDetailView.ets` |

**结论：`module.json5` 里的 `"routerMap": "$profile:router_map"` 本身给这个 HAR 提供了编译入口** ——
routerMap 里列出的页面会被当作入口编译，因此"只通过路由名被引用"的页面模块不需要伪造 import。

（严格说，本次同时也在 `abilitycommon/oh-package.json5` 里声明了 `@ohos/brewdetail` 依赖，
两者哪个是必要条件没有单独验证。但可以确定的是：**没有任何代码 import 它，它也照样被编译了**。）

这条对后续加页面模块有意义：新增一个只做路由落点的 HAR，不需要为了"骗过可达性分析"而写假 import。

### 9.3 HAR 的 `ohosTest` 不能用 `devecocli build` 跑

```
hvigor ERROR: 00306036 Specification Limit Violation
Hvigor task 'assembleHar' is not supported for building an 'ohosTest' target 'HAR'.
> Run 'genOnDeviceTestHap' instead.
```

`devecocli build --modules brewcommon@ohosTest` 会失败 —— HAR 的 ohosTest 需要走 `genOnDeviceTestHap` 任务，而 `devecocli` 未暴露该任务。因此 `features/brewcommon/src/ohosTest/` 下的 `BrewCommandGenerator.test.ets`（14 个用例）**目前只作为代码留存，编译到它需要另行安排**。

### 9.4 本次验证结果

验证方式：在 `features/abilitycommon/src/main/ets/util/InitCenter.ets` 临时 import `@ohos/brewcommon`，构建后删除临时引用。

| 检查 | 结果 |
|---|---|
| ArkTS 编译 | `BUILD SUCCESSFUL in 30 s 407 ms`，0 error |
| 修掉的错误 | 1 个：`Index.ets` 导出了不存在的 `BrewKinds`（`BrewConstants` 里只有 `BrewKind`） |
| 代码进入字节码 | `modules.abc` 中确认存在 `BrewCommandGenerator` / `BrewModels` / `BrewConstants` / `BrewService` / `BrewRepository` / `Index` |
| 资源无冲突 | `brew_tab_formulae` 等键合入 HAP `ResourceTable.txt` 与 `resources.index`，未与现有模块同名资源冲突（`brew_` 前缀生效） |
| 产物 | `pc-default-signed.hap`（含 `ets/modules.abc` 3,673,972 B + `resources.index` 56,576 B） |

### 9.5 已解决：brewcommon 现在进入了构建图

上面 9.1~9.2 描述的"临时引用才能验证"状态已经结束。
新建的 `features/brewformulae` 被 `abilitycommon/view/HomeView.ets` 静态 import，
形成**永久**的 import 点，`brewcommon` 随之进入 `:pc:default@CompileArkTS` 的编译范围：

```
HomeView.ets
  -> @ohos/brewformulae  (BrewFormulaHomeView / BrewMarketPlaceholderView)
       -> @ohos/brewcommon  (BrewFormulaModel / BrewCategoryCard / FORMULA_CATEGORY_NAME …)
            -> @ohos/common  (HmosRequest / PreferenceCacheHelper …)
  -> @ohos/brewcasks    (BrewCaskHomeView)
       -> @ohos/brewcommon  （同上，且共享 BrewPackageRow / BrewFormat）
```

从现在起，改 brew 侧任何代码都直接跑 `devecocli build` 就能验证，不再需要临时引用。

### 9.5.1 每轮必查的两项（`BUILD SUCCESSFUL` 不够）

因为 `BUILD SUCCESSFUL` 只说明"没有编译错误"，不说明新代码真被编进去了，所以每轮至少查这两项：

```bash
# 1. 符号是否真的进了字节码（可达性编译成立）
ABC=products/pc/build/default/intermediates/loader_out/default/ets/modules.abc
grep -c BrewCaskHomeView "$ABC"        # 应为正数

# 2. HAR 的 routerMap 是否真的合并进了 HAP
python3 -c "import json;print([r['name'] for r in json.load(open(\
  'products/pc/build/default/intermediates/router_map/default/router_map.json'))['routerMap']])"
```

注意第 2 项不能用"各模块 `router_map.json` 条数相加"来替代 —— HAR 的路由是合并进
`products/pc/build/.../router_map/default/router_map.json` 的，只有那份才是 HAP 里实际生效的。

**第 1 项的 grep 不要加 `^...$` 锚点。** 做 Discover 页时我先用 `grep -c "^BrewDiscoverHomeView$"`
检查，结果 15 个符号里只有 2 个命中，看起来像"没编进去"；换成不加锚点后全部命中且计数健康
（Home 22 / Base 42 / List 27 / Board 63 / Card 44 / Hero 28）。
对照组说明了问题在检查方式：`MinePackagesView` 这个**早就跑通**的符号，加锚点也是 0，不加是 63。
`strings` 出来的每条不一定是"整行正好等于符号名"，中间可能夹着类型描述符或路径。

**另一个坑：`ui layout` 默认的 simplified 模式不列"没有文字的 Button"。**
做 Discover 时用简化模式 `grep Button` 只看到榜卡的「查看」（有文字），
以为大图卡的 `>` 圆钮没渲染；换成 `--mode full` 就看到了
`Button [1672,1147,1748,1223]` = 76×76px = 40vp ✓。
**验证纯图标控件（圆钮、只有 SymbolGlyph 的按钮）必须用 `--mode full`。**

本轮（Casks）结果：

| 检查 | 结果 |
|---|---|
| ArkTS 编译 | `BUILD SUCCESSFUL in 20 s 909 ms`，0 error |
| brewcasks 符号进字节码 | `modules.abc` 中 `BrewCaskHomeView` / `BrewCategoryChipBar` / `BrewCaskCardView` / `BrewCaskHomeViewModel` / `BrewCaskState` 均存在 |
| 路由合并 | HAP 路由表 **18** 条，含 `BrewCaskListView`（上轮为 17 条） |
| 数据校验 | 8 个 cask 分类 key 在 `CASK_CATEGORY_SYMBOL` / `CASK_CATEGORY_NAME` 中无缺失；100 个 `caskContents[].id`、8 个 `caskCards[].id` 全局唯一；每个条目的 `categoryKey` 与其父分类一致 |

### 9.6 本机有可运行的真机，验证不必停在"编译通过"

```
$ devecocli device list
Name                 Serial           Kind    Device Type
HUAWEI MateBook Pro  127.0.0.1:42021  device  2in1        <- 正是本项目唯一 target
```

并且 `devecocli` 提供了一整套 UI 自动化命令：

| 命令 | 用途 |
|---|---|
| `devecocli run` | 构建 + 安装 + 拉起，可直接在真机上跑 |
| `devecocli ui layout` | 导出屏幕上的 UI 节点树（可断言文案/结构真的渲染出来了） |
| `devecocli ui screenshot` | 截图，用于核对视觉效果 |
| `devecocli ui click / swipe` | 点按与滑动，用于走通交互路径 |
| `devecocli log` | 取设备侧应用日志 |

因此 brew 侧 UI 的验收标准是**在真机上看到并点到**，而不是"编译通过"。

---

### 9.7 偶发：`PackageHap` 报资源文件读不到（重跑即过）

观察到一次（本项目 9 次连续成功构建中的第 8 次），现象：

```
Finished :pc:default@CompileArkTS...        <- ArkTS 编译成功
ERROR: Failed :pc:default@PackageHap...
[E] get real file path failed![.../resources/rawfile/image/sample/1776934456130_a20c31be.png]
[E] get real file path failed![.../resources/base/media/ic_background.png]
[E] filePath is not regular file![.../resfile/.../ManulImages/2.png]
[E] HapPackager::Process: zipWrapper AddFileOrDirectoryToZip failed!
BUILD FAILED
```

**不是真的缺文件**，三点反证：

1. 报错的 3 个文件在中间产物目录里都存在且是普通文件（957,348 / 83,245 / 60,304 字节），
   源文件也都在（`ic_background.png` 来自 `AppScope/resources/base/media/`）
2. `CompileArkTS` 是成功的 —— 失败发生在下游的打包阶段
3. 同一份代码**重跑一次即成功**，且此前 7 次同样配置的构建全过

怀疑是 `--parallel` 下资源拷贝与打包工具之间的竞争（打包工具 stat 时文件尚未就绪），
**未确认**。处理办法：直接重跑；若连续复现再清 `products/pc/build` 重试。

注意区分：这类失败与「ArkTS 编译错误」性质不同 —— 前者是环境问题，后者才是代码问题。
判断依据是看有没有 `Finished :pc:default@CompileArkTS`。**不要因为看到 BUILD FAILED 就去改代码。**

### 9.8 编译能过、运行期才崩：组件不能直接写在 `CustomBuilder` 的箭头里

做「我的」页时踩到一次，**构建完全成功、零警告，一进页面直接闪退**：

```
Error message: class constructor cannot called without 'new'
Stacktrace:
    at anonymous @ohos/brewcommon (features/brewcommon/src/main/ets/component/BrewLocalPackageRow.ets:83:9)
    at create (.../napi/hdsBaseComponent.js:1292:1)
    at anonymous @ohos/brewcommon (features/brewcommon/src/main/ets/component/BrewLocalPackageRow.ets:81:20)
```

出错的写法（`BrewLocalPackageRow`，我抽 `BrewMonogram` 成共享组件时直接内联了进去）：

```typescript
prefixItem: new PrefixCustomBuilder(() => {
  BrewMonogram({ token: this.installedPackage.name });   // ❌ 运行期崩
}),
```

能工作的写法（`BrewPackageRow` 一直是这么写的）：

```typescript
prefixItem: new PrefixCustomBuilder(() => {
  this.MonogramBuilder(this.installedPackage.name);      // ✅ 调 @Builder 方法
}),

@Builder
MonogramBuilder(token: string) {
  BrewMonogram({ token: token })
}
```

**原因**：`@Builder` 方法体（以及 `build()`、`ForEach` 的 itemGenerator）里的组件调用会被 ArkTS 编译器
改写成视图创建代码；**普通箭头函数体内的不会**，于是编译成裸的类调用 —— 运行期就是那句
`class constructor cannot called without 'new'`。

几点值得记住：

1. **这是编译期查不出来的。** 与 §10.6 的「不存在的 `sys.symbol.*`」同类：都是构建全绿、
   运行期才炸。所以真机验证不能省。
2. **抽公共组件时要连"调用方式"一起看。** 我只是把 `BrewMonogram` 从 `BrewPackageRow` 里挪了个位置，
   `BrewPackageRow` 自己没事（它调的是 `@Builder`），新写的 `BrewLocalPackageRow` 却把组件名直接内联了。
   同一个组件，两种调用方式，只有一种合法。
3. 排查时的定位方法：堆栈里的 `at anonymous @ohos/xxx (文件:行:列)` 直接给了文件与行列，
   照着看那一行即可 —— 本例中 83:9 就是那句被内联的组件调用，不需要读别的代码。

顺带一条同类经验：`PrefixCustomBuilder` 的**内容**必须是独立的 `@Component`
（原因见 `BrewMonogram.ets` 的注释，是另一个坑：测量宽度）。两条合起来就是
「前缀槽位要放独立组件，且必须经 `@Builder` 方法调用」。

### 9.9 同一节点写两次 `.padding()`：后一次覆盖前一次

真机反馈「各个二级页面没有边距」。原因是 `MinePackagesView` 里这样写：

```typescript
Scroll() { ... }
  .padding(this.contentInset())          // ❌ 左右边距
  .padding({                             // 这行把上面整个覆盖掉
    top: brewTitleBarTotalHeight(...),
    bottom: this.globalInfoModel.naviIndicatorHeight,
  })
```

**ArkUI 的属性是覆盖而不是累加**（与 CSS 的 `padding-left` 之类可叠加不同）：
第二次 `.padding()` 不是「追加」，而是整体替换，于是左右边距静默消失，内容直接贴边。

同类还有 `.margin()`、`.border()`、`.borderRadius()` 等所有「一个方法设一组值」的属性。

**判断方法**：一条属性链上同一个属性只应出现一次。要么合并成一个对象，要么分层 ——
把左右放在内层节点、上下放在外层节点。`BrewCaskBaseView` / `BrewDetailView` 就是靠分层
（内层 `Column` 给左右、外层 `Scroll` 给上下）避免了这个问题，而这两个页面当时看着是正常的，
**所以我照抄结构时以为「多个 padding 没问题」** —— 其实它们只是恰好在不同节点上。

这条与 §9.8 是同一类：编译全绿、静态检查也查不出来，必须跑起来看。

### 9.10 Formulae 页原先完全没有左右边距

同一个反馈还带出另一个问题：`BrewFormulaBaseView` 的 `WaterFlow` 只设了 `top` / `bottom`，
**一个左右边距都没有**。左右间距只有 `columnsGap` —— 那是列与列之间，与窗口边缘无关，
于是最左最右的分类卡片直接贴边。对照之下 `BrewCaskBaseView` 一直有 `contentLeft()` / `contentRight()`。

这个差异之所以一直没被发现：两个页签各自负责自己的边距，而**只有其中一个写了**。
处理办法是把左右边距提到 `brewcommon` 共用（`brewPageContentLeft` / `brewPageContentRight`），
`BrewCaskBaseView` 改为委托调用：

- 两个并列页签的边距必须一致，否则切换页签时内容左右跳动；
- 一份实现，就不会再出现「只有其中一个改了」的情况。

这与 §10.1 里 chips / 常量 / 首字母块上移是同一条纪律。

### 9.11 版面靠量，不靠猜：`devecocli ui layout` 读真实坐标

真机反馈「两个卡片的 title 大小调小」「和其他的 item 的 title 对齐」。这类问题读代码解决不了 ——
我用的 `Title_S` 到底是多少 vp、HDS 列表项标题的默认值是多少，源码里都看不到。

做法是先看设备上有哪些窗口，`sample0` 在后台也能 dump，**不需要把 APP 切到前台、也不需要点它**：

```bash
devecocli ui window list --device <deviceId>          # 找到 sample0 的窗口 id（如 2383）
devecocli ui layout --device <deviceId> --window 2383  # dump 节点树（含每个节点的坐标）
```

坐标是 `[x1,y1,x2,y2]`，于是 **`y2-y1` 就是文字的行高（可当字号用）、`x1` 就是缩进**。实测：

| 文字 | 高度 | 左边缘 x |
|---|---|---|
| 内容上新 / 最新公告 / 已安装（`HmosListItem`） | **36** | 1099 |
| `datagrip` 等包名（`HdsListItemCard` 默认字号） | **36** | — |
| `D` / `F` 首字母块（`Body_L`） | **36** | — |
| 待更新 / 已更新（我写的卡片标题，`Title_S`） | **45** | **1106** |
| `60 个包` / `8 个包` 等后缀文字（`Body_S`） | 31 | — |

三条结论都是量出来的，不是推的：

1. **`Body_L` = 36 = HDS 列表项标题的默认行高** —— 所以「和 item 标题对齐」就是换成 `Body_L`；
2. 我的标题大了 25%（45 vs 36）；
3. 左边缘多缩进 7px，恰好等于卡片的 `padding_level4`。

由此得到修法：**头部改用 `HmosListItem`**（与页面上其它 item 同一个组件），图标尺寸、标题字号、
左侧缩进、右侧数字槽位全部天然一致，一个数值都不用猜。左右内边距只加在预览区那一层、头部保持全宽，
否则头部会比其它 item 多缩一截。

**方法论**：与 §9.8 / §9.9 / §9.10 是同一类问题的两种应对 ——
那三条是「编译能过、运行期才崩」要跑起来看；这条是「运行也不崩、就是不像」要量出来看。
`ui layout` 是只读的，比重启、截图、肉眼比对都快且准。

**量出来还能防止改坏已确认的部分。** 为了对齐头部，我把卡片的左右内边距从整张卡挪到了
「预览区」这一层，顺手把它写成了 `level8` —— 而用户上一轮已经确认过 `level4` 的预览内缩量。
是重新量坐标时发现首字母块从 1087 挪到了 1102 才察觉。教训：**为满足新要求而重构版面时，
先列出这次会碰到哪些「已经确认过」的数值，逐个保持不变**；否则很容易在解决 A 的同时改坏 B，
而 A 的反馈会盖住 B。

### 9.12 标题栏模糊「先空行程、后猛增」：让位既不能用容器 `padding`，也不能用 `contentStartOffset`

> 本节是**本次排查的记录**（含实测数据与四种组合对照）。
> 若要看「所有模糊类型 / 逐场景正确用法 / 让位三种写法 / 完整坑清单」的**通用总结**，
> 看 `docs/hds-titlebar-blur.md`（不限于 brew，含非 brew 页的现状盘点）。

需求方反馈：发现页 / Formulae 两页的标题栏模糊「从开始滚动算起，先有一段空行程
（约 `contentStartOffset` 的八成），然后猛增到最大模糊（约两成）」；组件 / 我的 / Casks 三页是对的。

本机（2in1 + 侧边栏布局，`statusBarHeight = 0`，所以让位量 C = `0 + NAVIGATION_HEIGHT(56)` = **56**）
逐轮实测，四种组合的现象：

| 让位机制 | 区间配置 | 现象 |
|---|---|---|
| 容器 `.padding({ top: C })` | 基类按 banner 算出来是反向区间（起点 0 / 终点 −56）→ HDS 按**默认值**处理 | 标题栏完全不模糊 |
| `contentStartOffset(C)` | 同上（默认 `[0, 8vp]`） | 有模糊，但起步 56vp 毫无动静，之后 8vp 猛增 |
| `contentStartOffset(C)` + 把区间「左移」C | `start = −C`、`end = 104 − C` | start 被 HDS 丢成 0、end 留在 48 → 区间 `[0,48]`：仍是 56vp 空行程 + 48vp 猛增 |
| **内容里的占位**（最终方案） | `start = 0`、`end = 104` | 从「内容贴在标题栏下沿」起连续渐变，滚过 104vp 到最大模糊 ✅ |

#### 成因 1：HDS 的偏移量取值范围是 `[0, +∞)`，越界「静默」按默认值处理

官方 API 参考（`@kit.UIDesignKit` → `ScrollEffectOptions`，本机 `devecocli docs read` 可查）：

- `blurEffectiveStartOffset`：取值范围 `[0, +∞)`，**超出取值范围时按默认值处理**，默认 `vp(0)`。
  也就是说**传负数等于传 0**，不是「负的起点」；
- `blurEffectiveEndOffset`：取值范围 `[0, +∞)`，**若小于 `blurEffectiveStartOffset` 同样按默认值处理**，
  COMMON_BLUR / GRADIENT_BLUR 默认 `vp(8)`。

两条都是**静默降级**：编译过、不报错、无日志 —— 所以「把区间左移」这个想法在这套 API 里根本表达不出来。
上一轮正是这么写的（`start = −contentStartOffset`），区间悄悄变成 `[0, 48]`。

#### 成因 2：`contentStartOffset` 会把滚动坐标系整体左移 C

HDS 用的就是 **scroller 自报的偏移量**。逐档 `scrollTo` + `currentOffset()` 打点的探针实测：

```
[BrewBlurProbe], initial actual=-56.00000150580157     ← 页面静止（未滚动）时
[BrewBlurProbe], step=0 target=0 actual=0              ← scrollTo(0) 时
```

`contentStartOffset(C)` 属于**内容区**偏移，它把内容区原点挪到 +C，于是静止时自报偏移量是 **−C**；
而 HDS 的起点又不能为负 → **永远够不到「内容刚贴住标题栏下沿」那一刻**，空行程恰好 = C。
这与需求方最初的描述（空行程 ≈ 八成 C、猛增 ≈ 两成 C）完全吻合。

#### 修法：让位写进**内容**，区间恒为 `[0, 104]`

三个参考页都是这么做的，照它们办即可：

| 参考页 | 让位写法 |
|---|---|
| 组件页（WaterFlow） | 第一个 `FlowItem` 是 banner —— 内容里的占位块 |
| 我的页 `MineView`（Scroll） | 内层 `Column` 的 `margin.top`，**左右内缩也写在它身上** |
| Casks 页 `BrewCaskBaseView`（Scroll） | 内层 `Column` 的 `margin.top`（本次一并改过来） |

brew 各页对应关系：

- **Formulae / Discover（WaterFlow）**：首尾各一个空白 `FlowItem`，VM 的 `sections` 变成
  `[spacer, cards, footer]`（顺序必须与子组件顺序一致，同组件页的 `[banner, cards, footer]`）；
- **详情页 / 榜单二级页 / 我的-本机包 / Casks（Scroll）**：让位写成内层 `Column` 的 `margin`，
  容器上的 `padding` 全部去掉；左右内缩也一并挪到内层（容器 `padding` 是**一个整体**覆盖的，
  见 §9.9，而且它会裁剪内容）；
- **模糊区间**：`brewcommon/BrewTitleBar.brewBlurScrollEffect()` 统一返回 `[0, 104]`，所有页共用，
  页面不再传任何补偿量。

#### 为什么容器 `padding` 也不行（这一点确实存在）

容器 `padding` 会把内容**裁剪**在 padding 区域之外 —— 内容永远滚不到标题栏下面。
本轮改完区间后需求方实测确认：「内容区并不会到模糊层下方了，模糊效果现在形同虚设」。
所以 `padding` 与 `contentStartOffset` 都不能用来让位，**只有内容里的占位可行**。

> 一条常被误引的旧结论：早期文档写过「用 `margin` 让位会底部溢出，所以必须用 `padding`」。
> 那说的是把 margin 写在 **Scroll 容器**上（外层是精确 100% 高度的 Stack，整体下移必然溢出）。
> 写在**内层内容**上没有问题 —— 我的页/包详情页/榜单二级页/本机包页用的都是内层 margin。

#### 判据（可量）

日志里每页一行（同页同样的值只打一次）：

```
[BrewTitleBar], blur ramp: page=formulae start=0 end=104 ramp=104 material=legacy
```

`start` 必须是 **0**、`end − start` 必须是 **104**。出现负数或 `end=48` 就说明又有人往区间里塞了补偿量。

#### 自查：全部标题栏清单（同一台机器：2in1 + 侧边栏布局）

`HdsUtil.isSupportNewMaterialApi()` 在侧边栏布局下返回 **false**，所以走的是 `COMMON_BLUR` 那支：

| 页面 | 样式来源 | 让位方式 | 模糊 |
|---|---|---|---|
| 组件 / 样例 / 实践 三个首页 | `BaseHomeViewModel`（有 banner） | 瀑布流里的 banner 分组 | ✅ |
| Formulae | 覆写基类 + `brewcommon` 共用区间 | 首尾空白 `FlowItem` | ✅ **本次修好** |
| Discover（发现） | 同上 | 同上 | ✅ **本次修好** |
| Casks | 同上 | 内层 `Column.margin` | ✅ **本次一并修好** |
| 包详情页 / 榜单二级页 / 我的-本机包 | `brewTitleBarStyle()` | 内层 `Column.margin` | ✅ |
| 我的 / 公告 / 组件详情 / 代码预览 / 文章详情 | 内联 `scrollEffectOpts` | 内层 margin / 本就有 | ✅ |
| 内容上新 / 实践详情 | 内联 **`enableScrollEffect: false`**（原工程自带的口径） | — | ❌ 刻意关的，未动 |

结论：brew 页的标题栏模糊「区间长度 + 让位机制」现在只有一份实现（`brewcommon/BrewTitleBar` +
各页的「内容占位」），新增页面照上面两条做即可。

### 9.13 同一个 URL 被请求多次：缓存要等响应，所以在途必须单独去重

接现网后日志里能看到同一个 `/api/formula/<token>.json` 出现好几次。查下来是三个原因叠在一起，
**都不是“代码写错了”，而是“缓存去重不够早”**：

1. **页面加载本来就会被触发两次**（既有行为，相隔 ~130ms）。Mock 时代读两遍 rawfile 看不出来，
   接现网就是两批 100 个请求。证据就在日志里：
   ```
   [BrewFormulaHomeVM], loadFormulaPage success  09:21:56.311
   [BrewFormulaHomeVM], loadFormulaPage success  09:21:56.448   ← 同一次启动，第二次
   ```
2. **三个页签并发预加载，token 集合有交集**。实测（用 mockdata 直接算）：
   Formulae 页 ∩ Discover formula 榜 = **24** 个 token，Casks 页 ∩ Discover cask 榜 = **24** 个。
   两个批次几乎同时查缓存，都未命中 → 各发一份。
3. 详情页的 `alignCategoryRank` 与「同分类其他包」也会触发整页 hydrate；若首批还在飞，就重发。

**根因**：缓存只在响应回来后才写入，而 hydrate 当时只做了「**批内**去重」（`unique` 数组），
没做「**在途**去重」—— 第二批查缓存时第一批还在飞，于是穿过去重。

**修法**：`BrewService.inFlight: Map<cacheKey, Promise<entry>>`，第二个调用者直接复用在飞的 Promise。
两个细节不能省：

- **失败时必须把在途占位删掉**（放在 `.catch` 里），否则一次失败会被后续调用者一直“复用”，
  永远拿不到重试机会；
- 命中在途合并时打一条 `live request joined in-flight` 日志 —— 否则“到底重没重”无法验证。

**判据（可量）**

| | 修复前（最坏） | 修复后 |
|---|---|---|
| GET 总数 | 602 | **240** |
| 同一 URL 出现次数 | 最多 2 次（批次交集） | 1 次 |
| 日志里 | 同一 URL 多行 | 同一 URL 一行 + 若干 `live request joined in-flight` |

（240 = 去重后的 token 全集：Formulae 119 + Casks 121，两页与 Discover 榜的交集各 24 个已归入前者。）

> 方法论：这又是“编译过、不报错、只是发了两倍请求”的一类问题 —— 静态看代码只能看出“我写了去重”，
> **只有把日志按 URL 计数才能看出漏了哪一层**。

## 10. `features/brew*` 模块群

四个模块，职责分别是：

| 模块 | 职责 |
|---|---|
| `brewcommon` | **共享层**：数据模型 / 服务 / Repository / 命令生成 / 详情归一化 + 跨页签共用的 UI 原子 |
| `brewformulae` | Formulae 页签 |
| `brewcasks` | Casks 页签 |
| `brewdetail` | 包详情页（formula / cask 共用一个路由） |

`Discover` 目前仍是占位页，暂住在 `brewformulae` 里（`BrewMarketPlaceholderView`）。

### 10.1 `brewcommon`：为什么 UI 原子也放在这里

```
features/brewcommon/
├── Index.ets                          模型 / 常量 / 服务 / 共享 UI 的统一导出
├── oh-package.json5                   依赖 common / commonbusiness
└── src/main/
    ├── resources/base/element/
    │   ├── float.json                 brew_package_row_height 64vp / brew_monogram_size 40vp
    │   │                              brew_card_header_height 72vp / brew_card_header_icon_size 24vp
    │   └── string.json（+ en_US / zh_CN）  87 条 brew_* 文案
    └── ets/
        ├── model/BrewModels.ets       模型 + BrewDetailParams
        ├── model/BrewRepository.ets   BrewFormulaModel / BrewCaskModel / BrewSearchModel
        │                              / BrewDiscoverModel（~~BrewLocalModel 已删 2026-10~~）
        ├── constant/BrewConstants.ets 分类枚举 / 中英文名 / 分类 symbol 映射
        ├── service/BrewService.ets    目录（聚合端点）+ 现网单条 + Preference 两级缓存
        ├── util/BrewCommandGenerator.ets
        ├── util/BrewFormat.ets        安装量压缩(35.6k) / 排名 / 首字母
        └── component/
            ├── BrewMonogram.ets           包名首字母方块（两个包行组件共用）
            ├── BrewPackageRow.ets         商店里的包行：右侧是分类排名 + 近 30 天安装量
            ├── BrewLocalPackageRow.ets    本机包行：副标题是版本，尾部是安装来源
            └── BrewChipBar.ets            通用胶囊 chip 栏（+ BrewChipItem）
```

Discover 页的模块（`brewdiscover`）与它的卡片、以及生成器侧的榜单算法，见 §13。

`BrewPackageRow` / `BrewFormat` / `BrewDetailParams` 最初写在 `brewformulae` 里，做 Casks 时上移到了这里。
`BrewMonogram` / `BrewChipBar` / `BrewLocalPackageRow` 是做「我的」页时收进来的（各自的由来见下方）。
两个理由：

1. **避免页签之间互相依赖。** 如果留在 `brewformulae`，`brewcasks` 就得依赖 `brewformulae` 才能复用它 ——
   `casks -> formulae` 这种依赖方向没有语义。
2. **避免复制。** 这两块加起来约 180 行，复制出去一定会漂移（同类问题在数据模型上已经遇到过：UI 侧曾镜像一套
   类型，数据层改了、UI 侧忘改）。

代价是 `brewcommon` 不再是一个纯数据模块。它的定位从「数据底座」变成「共享层」—— 这在工程上不是问题
（它本来就依赖 `commonbusiness` 并携带资源），但描述要跟着改，否则后来人会以为往里加 UI 是破坏约定。

后三者的具体由来：

| 原子 | 从哪来 | 为什么上移 |
|---|---|---|
| `BrewMonogram` | `BrewPackageRow` 内部的私有 struct | 本机包行也要用同一个首字母方块。**它必须是独立 `@Component`**（原因见该文件注释），所以抽成独立文件比复制一份安全 |
| `BrewChipBar` | `brewcasks` 的 `BrewCategoryChipBar` 的样式部分 | 「我的」子页面的筛选 chips 是同一套样式。两个模块各写一份必然漂移，所以把**样式与渲染**提上来，`BrewCategoryChipBar` 退化成「把分类映射成 `BrewChipItem[]`」的薄包装 |
| `brewPageContentLeft/Right` | `brewcasks` 的 `contentLeft()` / `contentRight()` | 两个并列页签的左右边距必须一致，且原先**只有 Casks 有**（Formulae 一个都没有），见 §9.10 |
| `BrewLocalPackageRow` | 新增 | 与 `BrewPackageRow` **故意不合并**：右侧信息完全不同（本机数据里根本没有 `categoryRank` / `installs30d`）。硬合成一个组件只能靠开关参数，反而更难读 |

`BREW_CHIP_BAR_HEIGHT` / `brewTitleBarTotalHeight()` 同样从 `brewcasks/constant/BrewCaskConstants.ets`
移到了 `brewcommon/constant/BrewConstants.ets`，并把那个文件删掉 —— 这两个值必须与各页
`bottomBuilder.height` 同源，多一个副本就多一次「chips 盖住内容」的机会。

**未新建 `brewui` 模块的理由**：新增一个 HAR 要同时改根 `build-profile.json5` 的 `modules[]`、
各消费方的 `oh-package.json5`，并补一套脚手架；而 `brewcommon` 已经在 `modules[]` 里、也已经是
`brewformulae` 的依赖，放进去只需改一个 `Index.ets`。

### 10.2 `brewformulae`：Formulae 页签

```
features/brewformulae/
├── Index.ets                             导出 BrewFormulaHomeView / BrewMarketPlaceholderView
├── oh-package.json5                      依赖 common / commonbusiness / brewcommon
├── build-profile.json5                   仅 default target
└── src/main/
    ├── module.json5                      routerMap: $profile:router_map
    ├── resources/base/profile/router_map.json   BrewFormulaListView / BrewFormulaCategoryView
    └── ets/
        ├── viewmodel/
        │   ├── BrewFormulaState.ets      继承 BaseHomeState（卡片源 + 瀑布流 sections）
        │   ├── BrewFormulaCardSource.ets IDataSource<BrewCategoryCard>
        │   ├── BrewFormulaCategoryState.ets  分类二级页状态（每页实例一份）
        │   ├── BrewFormulaCategoryVM.ets     分类二级页 VM（无状态）
        │   └── BrewFormulaHomeViewModel.ets
        ├── component/
        │   ├── BrewCategoryCardView.ets  分类大卡（信息头 + 包行列表，预览 5 条 + 查看全部）
        │   └── BrewFormulaCategoryChipBar.ets  分类 chips（挂在标题栏 bottomBuilder 里）
        └── view/
            ├── BrewFormulaHomeView.ets   外层壳：HdsNavigation + 自己的 PageContext
            ├── BrewFormulaListView.ets   HdsNavDestination + 模糊标题栏（路由落点）
            ├── BrewFormulaBaseView.ets   BaseHomeView + WaterFlow + LazyForEach
            ├── BrewFormulaCategoryView.ets  分类二级页（chips + 该分类全部成员）
            └── BrewMarketPlaceholderView.ets  Discover 占位页
```

三层壳（Home / List / Base）不是冗余：这是既有组件页 `ComponentHomeView` / `ComponentListView` / `ComponentBaseView`
的同一结构 —— 外层持有独立 NavPathStack 以支持侧边栏布局下的页内导航，
路由落点是中间那层（`router_map.json` 指向它，因为它才带 `HdsNavDestination` 的标题栏配置）。

### 10.3 `brewcasks`：Casks 页签

```
features/brewcasks/
├── Index.ets                             导出 BrewCaskHomeView
└── src/main/
    ├── module.json5                      routerMap: $profile:router_map
    ├── resources/base/profile/router_map.json   BrewCaskListView / BrewCaskCategoryView
    └── ets/
        ├── viewmodel/
        │   ├── BrewCaskState.ets         卡片源 + 瀑布流 sections（与 BrewFormulaState 同构）
        │   ├── BrewCaskCardSource.ets     IDataSource<BrewCaskCard>
        │   ├── BrewCaskCategoryState.ets  分类二级页状态（每页实例一份）
        │   ├── BrewCaskCategoryVM.ets     分类二级页 VM（无状态）
        │   └── BrewCaskHomeViewModel.ets
        ├── component/
        │   ├── BrewCategoryChipBar.ets   分类 chips（挂在分类二级页的标题栏 bottomBuilder 里）
        │   └── BrewCaskCardView.ets      分类大卡（信息头 + 包行列表，预览 5 条 + 查看全部）
        └── view/
            ├── BrewCaskHomeView.ets      外层壳
            ├── BrewCaskListView.ets      HdsNavDestination + 模糊标题栏（路由落点）
            ├── BrewCaskBaseView.ets      BaseHomeView + WaterFlow + LazyForEach
            └── BrewCaskCategoryView.ets  分类二级页（chips + 该分类全部成员）
```

注：`BREW_CHIP_BAR_HEIGHT` / `brewTitleBarTotalHeight()` / `brewPageContentLeft/Right()`
这些常量与函数已经提到 `brewcommon`（两个页签与二级页共用一份），不在本模块里。

### 10.4 `brewdetail`：包详情页（formula / cask 共用）

```
features/brewdetail/
├── Index.ets                             导出 BrewDetailView
├── oh-package.json5                      依赖 common / commonbusiness / brewcommon
└── src/main/
    ├── module.json5                      routerMap: $profile:router_map
    ├── resources/base/
    │   ├── element/float.json            brew_detail_label_width 96vp / monogram 64vp / copy 按钮高 32vp
    │   └── profile/router_map.json       BrewDetailView -> BrewDetailBuilder
    └── ets/
        ├── viewmodel/
        │   ├── BrewDetailState.ets       展示数据 + 加载参数 + pathStack
        │   └── BrewDetailViewModel.ets
        ├── component/
        │   ├── BrewDetailHero.ets        分区 1
        │   ├── BrewInfoSectionView.ets   分区 4/5/6/7/11 通用分区 + 分区 2 安装命令卡
        │   │                             以及分区 3 的元信息条 BrewDetailMetaBar
        │   └── BrewLifecycleBanner.ets   分区 9
        └── view/BrewDetailView.ets       HdsNavDestination + Scroll
```

**formula 与 cask 共用同一个路由**（`PageEnum.BREW_DETAIL_VIEW`），包类型由路由参数里的 `kind` 决定。
原先预留的 `BREW_FORMULA_DETAIL_VIEW` / `BREW_CASK_DETAIL_VIEW` 两个常量已合并 ——
页面本来就是同一份，两个名字只会让"该跳哪个"变成一个无意义的选择。

**字段差异在 Normalizer 里摊平，不在 UI 里分支**：`BrewFormulaDetail` 与 `BrewCaskDetail` 差异很大
（license / executables / bottleTags / serviceSupported vs artifacts / supportedPlatforms /
macosRequirement / autoUpdates），而 ArkTS 没有可收窄的判别联合 —— UI 里到处写 `if (isCask)` 既啰嗦又容易漏。
所以 `BrewDetailNormalizer` 把两种包各自转成统一的「行 + 分区」结构，页面只认这一套，
全部渲染代码里只有一处 `kind` 分支（决定点击同类包时回传的 kind）。

#### 10.4.1 「每页实例」的状态不能放在共享对象上（返回键失效的成因）

详情页可以**叠在详情页上** —— 点「同分类其他包」会 `pushPath` 出一个新的详情页。
这让详情页成为本仓库唯一会「路由压在同名路由上」的地方（页签页的 chips 是原地
`SWITCH_CATEGORY`，列表页由 `BrewCaskHomeView.aboutToAppear` 以根内容压入且不再自压），
也因此暴露出一个仓库既有写法里的隐藏缺陷：**把「每页实例」的状态放进了共享对象**。

实测踩到的两个 bug，成因是同一个：

| 现象 | 成因 |
|---|---|
| **第一次能返回，之后每次进详情页返回键都失效** | 返回键防重入标志 `backPressed` 放在了单例 VM 的 state 上，**一旦置位就再不复位**。仓库里的 `PracticeDetailView` 是在 `handleOnReady` 里补一句 `ChangeBackPressed(false)` 才没暴露这个问题，我照抄时漏了这句 |
| **从同类包返回时看起来「返回没反应」** | 展示数据也在单例 state 上。压入第二个详情页后它的加载结果**覆盖了栈中旧页面的数据**，返回时旧页面渲染的是同一份数据，画面不变 |

修法不是「补一句复位」，而是**让状态归页面实例所有**：

- `BrewDetailState` 由 `BrewDetailView` 自己 `new`（`@State detailState = new BrewDetailState()`），
  不再从单例 VM 取
- `BrewDetailViewModel` 变成**无状态**的（只持有两个 model），`load(param, state)` 由调用方把 state 传进来
- 返回键防重入标志 `backPressed` 改成组件自己的 `@State`：每个 `pushPath` 都会新建一个
  `NavDestination`（即一个新的结构体实例），天然每页独立，不需要任何复位

三点值得记住：

1. **判断依据是「这个状态的生命周期属于谁」**，不是「放在哪里方便」。生命周期是「一次页面实例」的东西
   放进单例，就一定会出现「上一次的状态影响了这一次」。
2. **ArkUI 的成员初始化不要交叉引用**。`@State a = this.b.get()` 依赖 ArkUI 的成员初始化顺序，
   而这个顺序没有明确保证。上面的改法顺手消除了这个隐患 —— `@State detailState = new BrewDetailState()`
   不引用任何其他成员。
3. **照抄一个能跑的写法时，要看清它为什么能跑**。`PracticeDetailView` 的 `return true` + 手动 `pop()`
   能工作，靠的是 `handleOnReady` 里的复位；只抄 `onBackPressed` 那一段就会得到「第一次能用」的假象。

另外，`return true` 会**屏蔽系统默认出栈**（`false` = 不拦截，走默认出栈）。本仓库所有页面都
`return true` 自己 pop，没有任何一处依赖默认出栈，所以这里也保持 `return true`；
但在**拿不到 `pathStack` 时返回 `false`**，宁可退化成系统默认行为，也不要「返回键彻底失效」。

两个实现上的坑，都已在代码注释里记明：

| 坑 | 处理 |
|---|---|
| ArkUI 的 `if` 分支**不给属性表达式做联合类型收窄** | `lifecycle` 不用 `BrewLifecycleNotice \| null`，而是恒非 null + 一个 `hasLifecycle` 布尔量 |
| `@State` 只观察所持对象的**一级属性** | `siblings`（同类包）不嵌在 `data` 里，而是与 `data` 平级 —— 它是单独一个请求，晚于详情返回，嵌在里面赋值不会触发刷新 |

### 10.5 两个页签同形态（分类卡 + 「查看全部」二级页），差异只在数据形状

**2026-09 变更**：Casks 原先首页就是「chips 选分类 + 单分类卡片列表」，
现已改成与 Formulae 一致的两层结构。两个页签现在一一对应：

| | Formulae | Casks |
|---|---|---|
| 首页 | 全部分类的卡片瀑布流（`WaterFlow`，lg 断点 3 列） | 同左 |
| 卡内 | 预览 5 条（`BREW_CATEGORY_PREVIEW_COUNT`）+ 「查看全部」 | 同左 |
| 二级页 | `BrewFormulaCategoryView`（chips + 该分类全部成员） | `BrewCaskCategoryView`（同构，孪生页） |
| 二级页路由 | `BREW_FORMULA_CATEGORY_VIEW` | `BREW_CASK_CATEGORY_VIEW` |

留下来的差异全部来自 mock 的数据形状，不是刻意的 UX 差异：

| | Formulae | Casks |
|---|---|---|
| mock 结构 | `cardData[]` → `formulaContents[]`（两层） | `caskCategories[]` → `caskCards[]` → `caskContents[]`（三层） |
| 分类信息在哪 | 卡片自带 `title` / `subTitle` / `iconSymbol` / `itemCount` | **分类**带 `categoryName` / `defaultIcon` / `selectedIcon`；卡片只有一个 `title` |
| 首页怎么拿到卡 | 直接用 `cardData[]` | 先把「分类 -> 卡」摊平（`flattenCards`）—— 所以 `BrewCaskCard` 补了 `categoryKey` / `itemCount` / `hasMore`（由 `BrewBrowseBuilder.caskPage` 从所属分类复制），与 `BrewCategoryCard` 同款 |
| chips 的数据 | `BrewCategoryCard[]`（分类就是卡） | `BrewCaskCategory[]`（分类是单独一层） |

Casks 的三层结构与**样例页** `2in1/sample-page.json` 同构（`defaultIcon` / `selectedIcon` 就是分类 Tab 的
选中/未选中图标），所以它的 chips 照样例页做（挂在标题栏 `bottomBuilder`）。

两个页签共有的刻意差异：

| 差异 | 原因 |
|---|---|
| **没有 banner 区块** | Homebrew banner 接口的 `mediaUrl` 实测为空，渲染出来是一块空白。ViewModel 里把 `bannerHeight` 覆写为 0 |
| **分类卡顶部不是图片，是信息头** | 同上，Homebrew 没有包图标/横幅素材。改用「分类 symbol + 中英文分类名 + 包数」 |
| **包行前缀是首字母字母块** | `mediaUrl` 为空，无法用图片。首字母是真实信息，不是伪造的图标 |
| **分类 chips 没有任何图标** | 样例页 chip 走 `Image($rawfile(item.defaultIcon))`，而 Homebrew 的分类图标实测为空字符串；且样例页自己就是 `if (item.defaultIcon)` 守卫的，数据为空时它同样只渲染文字。所以与样例页保持一致，做成纯文字 chip（曾用 `sys.symbol.*` 自己补过图标，已按“同样例页”的要求去掉） |
| **一张卡一个分类** | mock 里每个分类就 1 张卡（`caskCards` 是列表但长度恒为 1）。首页用 `WaterFlow` 多列（与 Formulae 一致，列数随断点 1/2/3）；二级页用 `Scroll` + 单列全宽（那里只看一个分类） |

### 10.5.1 chips 挂在标题栏里，不是标题栏下方的一条固定行

样例页的分类 chips 是通过 `titleBar` 的 **`bottomBuilder`** 挂进标题栏的（与标题共用同一块模糊材质），
`bottomBuilder` 带显式高度 `CommonConstants.NAVIGATION_HEIGHT`（56vp）。两个分类二级页沿用这个做法：
chips 写在 `BrewCaskCategoryView` / `BrewFormulaCategoryView` 的
`.titleBar({ content: { bottomBuilder: … } })` 里（改造前是挂在 Casks 首页上的）。

样例页其实放了**两份** chips：内容区一份（随内容滚动）、标题栏一份（滚上去后接管），
用 `showTab` 切换，两个 `Scroller` 互相同步。分类二级页不需要这一套 ——
`showTab` 的阈值是 `bannerHeight - (statusBarHeight + NAVIGATION_HEIGHT)`，
而页签页 `bannerHeight` 被覆写为 0，阈值为负，`showTab` 恒为 true。
**也就是说在无 banner 的页面上，那套机制自己就退化成「chips 始终在标题栏里」。**

由此带来一个必须显式处理的后果：**标题栏是浮层，不会把内容顶下去。**
页签首页是靠内容里的**占位块**撑出这段空间的（`WaterFlow` 的第一个空白 `FlowItem`，
高 `statusBarHeight + NAVIGATION_HEIGHT`）；二级页没有瀑布流，改用**内层容器的 margin**
让出「标题行 + chips 行」两段高度：

```typescript
// features/brewcommon/src/main/ets/constant/BrewConstants.ets（两个页签与二级页共用一份）
export const BREW_CHIP_BAR_HEIGHT: number = CommonConstants.NAVIGATION_HEIGHT;
export function brewContentTopInset(statusBarHeight: number, hasChipsRow: boolean): number {
export function brewTitleBarTotalHeight(statusBarHeight: number): number {   // = brewContentTopInset(_, true)
  return statusBarHeight + CommonConstants.NAVIGATION_HEIGHT + BREW_CHIP_BAR_HEIGHT;
}
```

`BREW_CHIP_BAR_HEIGHT` 被两处引用 —— 标题栏的 `bottomBuilder.height`
与内容顶部让位。**两处必须同源**，否则会出现「chips 盖住第一张卡」或「内容上方多一条空白」。

chips 栏与卡片另外**各有各的横向内缩**，并不对齐：chips 用自己的
`padding_level6/12/16`（照搬样例页），卡片用 `brewPageContentLeft/Right()`。
样例页也是这么分的 —— 它的 chips 用 `level6/12/16`，卡片用 `SampleConstant.SCROLL_MARGIN_*`
+ `GridRow` 的 gutter。


### 10.5.2 「chip 点了没反应」的两种成因（别把第二种当成第一种）

分类二级页的 chip 曾经出现过「点了完全不动」。同一症状实际上有两个完全不同的成因，
**先用日志分清是哪一种，再改代码**：

| 成因 | 怎么认 | 怎么修 |
|---|---|---|
| ① 点击根本没进 App | 没有任何业务日志；`ui layout` 返回 `[0,0,0,0]`（窗口不在前台）；`ui window list` 里 App 的 `Focused` 是 false | 先让 App 到前台（或 `devecocli run` 重起），再点。**不要改代码** |
| ② 回调执行了但页面没重渲染 | hilog 打出了业务日志（如 `[BrewFormulaCategoryVM], switch category -> devtools index=1`），但 `ui layout` / `ui screenshot` 与点击前**逐帧一致** | 把能驱动 UI 的选中态改成组件自己的 `@State`（见下） |

②的实测记录（2in1，`ui click` + `ui layout`/`ui screenshot` 逐帧对照）：选中项当时放在
`@Observed` 的 state 对象上、由 VM 在 chip 回调里赋值 —— 日志证明写入发生了，但 chips 选中态与
内容一帧不变；改成页面自己的 `@State currentIndex` 后（与样例页 `PracticesView` 同款），
同样的点击立即生效。

**但具体原因没有定位到**：同样的写法（VM 写 state 的一级属性）在本仓库其它页真机验证是好的 ——
Casks 首页（`BrewCaskState.currentCards`）、「我的-本机包」（`MinePackagesState.filteredPackages`）
点 chip 都会换卡/筛选。所以这**不是**该写法的通病，也不能读成「`@Observed` 不能用」。
两个分类二级页采用的写法是「**能驱动 UI 的选中态放组件 `@State`，数据放 state 对象**」，
这个写法本身经过验证（详见 `BrewFormulaCategoryState` 顶部注释）。

顺带一条流程教训：先用 `ui layout` 确认窗口在前台（返回 `[0,0,0,0]` 就是信号），
再下「控件点不动」的结论 —— 否则很容易把成因①写成一条假 bug。

### 10.6 `sys.symbol.*` 必须实测，不能凭记忆写

`$r('sys.symbol.xxx')` 的资源名会在 `pc:default@CompileArkTS` 阶段被校验，写错直接报
`10903329 ArkTS Compiler Error: Unknown resource name 'xxx'`。这看起来是好事，但有个陷阱：

**当这些名字以普通字符串形式存在时（如 `Record<string, string>`），编译器不会校验它们。**
本项目就踩过：`BrewConstants` 里最初存的是 `'sys.symbol.terminal'` 这样的字符串，
构建通过，于是被当成"已验证"。直到为了另一个原因把类型改成 `Record<string, Resource>`
并换成 `$r()` 字面量，11 个名字一次性全部报错 —— 它们从来就不是真实资源名。

**教训：「编译通过」只证明语法与 import 成立，不证明内容正确。** 涉及资源名、枚举值映射、
外部标识符这类"字符串即契约"的东西，必须有独立的验证手段。

验证手段：一次性探针文件（把候选名字写成 `$r()` 数组并让它进入编译图），构建后
按报错行号反推哪些存在，然后删除探针。本项目用两轮探针（96 + 89 个候选）得到下表。

#### 实测有效的 symbol 名（本项目已用）

| 用途 | 名字 |
|---|---|
| terminal 分类 / Formulae 页签 | `code` |
| devtools 分类 | `hammer_fill` |
| network 分类 | `wifi` |
| data 分类 | `externaldrive` |
| cloudnative 分类 | `cloud` / `cloud_fill` |
| media 分类 | `ohos_photo` |
| ai 分类 | `lightbulb` |
| system 分类 | `gearshape` / `gearshape_fill` |
| devide 分类（cask） | `pc` |
| browser 分类 | `compass` |
| productivity 分类 | `list_checkmark` / `checkmark_circle` |
| comm 分类 | `message` |
| design 分类 | `paintbrush` / `paintpalette` |
| av 分类 | `play_circle` / `play_fill` |
| systemtool 分类 | `wrench_and_screwdriver`（线性版；实心版 `_fill` 留给左侧页签） |
| aivm 分类 | `bolt` / `bolt_fill` |
| Casks 页签 / 盒状兜底 | `archivebox_fill` / `archivebox` |
| 包行兜底 / 通用方块 | `square_grid_2x2` |
| 搜索 | `magnifyingglass` |
| Discover 页签 | `compass` |

#### 实测**不存在**的名字（避免再写）

```
terminal  laptopcomputer  safari  bubble  checklist  network  photo  sparkles  cpu
hammer  shippingbox  globe  antenna_radiowaves_left_and_right  brain  memorychip
server  cube  box  tray  browser  web  chip  server_rack  desktopcomputer
```

命名规律不统一，无法靠类推：`pc` / `compass` / `message` / `magnifyingglass` 是裸名，
`ohos_photo` 带前缀，而 `photo`、`sparkles` 根本不存在。**只能实测。**

### 10.7 侧边栏改动

`TabBarType` 追加 `DISCOVER=4 / FORMULAE=5 / CASKS=6`（**不动原 0~3 的值**，避免影响埋点与状态栏数组索引）。

`TABS_LIST` 拆成两段拼接：

```typescript
const MARKET_TABS = [DISCOVER, FORMULAE, CASKS, MINE];   // 侧边栏前三 + 我的
const LEGACY_TABS = [HOME, SAMPLE, PRACTICE];            // 保留作对照
export const LEGACY_TABS_ENABLED: boolean = true;
export const TABS_LIST = LEGACY_TABS_ENABLED ? [...MARKET_TABS, ...LEGACY_TABS] : MARKET_TABS;
```

开发收尾时把 `LEGACY_TABS_ENABLED` 置 `false` 即可下线旧入口，不需要改其他代码。
`TAB_CONTENT_STATUSES` 同步从 4 项扩到 7 项。

---

## 11. 已知限制与待办

| 项 | 说明 |
|---|---|
| **浏览集上限（前 100）** | 根因不是显示，而是**分类只能靠现拉 desc**（官方 API 无分类字段，分类 = `BrewTaxonomy` 看 desc）。**已另立 spec + plan：`docs/brew-catalog-fullsync-spec.md`** —— 后台同步全量元数据（`formula.json`/`cask.json`，gzip 5.29/2.05 MB）抽 `token → desc` 落盘，分类不再依赖逐条请求，硬裁切随之可删；列表随现网自动同步、无需发版。待评审（§6 有 6 个待决策点） |
| ~~详情文件一次性加载~~ | **已解决（2026-09）**：详情骨架改为从首页条目合成（`BrewApiMapper.formulaBaseOf/caskBaseOf`），`brew-{formula,cask}-details.json`（443.6 KB）已删除 —— 详情页现在只读首页快照（96/104 KB，且已按 id 定位）+ 一条现网单条请求 |
| ~~分类准确率~~ | **已处理（2026-09，见 `lexicon-eval.md`）**：浏览集放开到目录全量后词表成了主路径。实测兜底率 formula 70.6% → 56.7%（主题词层）→ **48.1%**（再加 `_forms` 形态桶 → `lib`）；浏览集口径 74.7% → 61.5% → **53.1%**。cask 74.6% → 67.7%（浏览集口径 54.6% → 51.0%）。剩下的长尾 desc 里没有任何领域信号，再降要换信号源（依赖 / tap），堆关键词会开始误分 |
| 图标 | 所有 `mediaUrl` 为空 → `ImageUtil.getImgResource` 回退 `$r('app.media.ic_placeholder')`。真实图标需先解决版权与来源策略 |
| `installs365d` | 已产出，但 mock 阶段 UI 只用 `installs30d` |
| ~~分类 symbol 名待核对~~ | **已解决**：全部换成实测有效的名字，见 §10.3 |
| 详情文件体积 | 移除自造 `props`、补入真实字段后为 212.1 KB（原 271.8 KB），仍是整份加载 |
| Discover 页面 | 数据底座已就绪，页面尚未实现，当前是明确标注"建设中"的占位页 |
| 详情页的本地状态徽标 | `installed` / `outdated` 字段已建模，但详情页与列表页都还没用（mock 里为空，需接 `brew info --json`） |
| ~~详情页~~ | **已实现**（§10.4）：两个页签点列表行、以及详情页内点同类包都会进入 `BrewDetailView`。11 个分区中「相关推荐」用的是**同分类其他包**（`recommendList` 在 mock 里为空） |
| 安装选项面板 | 已按决策移除（`options` 恒为空），不再列入待办 |
| 本机状态徽标 | 详情页与列表页都还没用 `installed` / `outdated` / `pinned`（mock 里为空，需接 `brew info --json` 才有值） |
| 搜索 | 本轮仅规划：入口 UI + `BrewSearchService` 空实现，不新增路由 |
| 本机包行不可点击 | 「我的 - 本机包」列表的行只展示、不可点进详情页。本机数据里只有 token，没有商店目录里的包 id，而详情页按 id 加载。要做需要先加「按 token 查 id」的仓库方法（`brew info --json` 里有 `homepage`，但目录侧没有 token 索引） |
| ~~「我的」页的 taps / services 数据~~ | **已删除（2026-09）**：`brew-local-taps.json`（5 条）与 `brew-local-services.json`（4 条）始终无 UI 调用点，已连同 `overview` 一起删除（见 `brew-handover.md` §4.1） |
| 分类二级页 chip 选中态的写法 | 选中态放组件 `@State`（不是 state 对象）—— 放在 state 对象上时出现「回调执行了但一帧不变」，**原因未定位**；同样写法在 Casks 首页、「我的-本机包」真机验证是好的（见 §10.5.2）。属于“现象已解决、机理未明”的一类，后续若再遇同类症状优先查这一条 |
| 分类卡只预览 5 条 | `BREW_CATEGORY_PREVIEW_COUNT` 同时是数据层 `hasMore` 与 UI 截断的口径（两处同源）。两个页签都是「卡内 5 条 + 查看全部」，成员 ≤ 5 的分类不显示该行 |
| ~~`brew-discover`~~ | **已调研（2026-09，`refs/brew-discover`，报告 `refs/brew-discover-categorization.md`）：不可用**。它是 173 行的关键词分类器（8 类硬编码、~296 个 Go 内联关键词、`strings.Contains` 打分、单一 `other` 兜底），**没有任何 token→分类数据**，自己也没解决长尾；且仓库无 LICENSE 文件（README 仅一行 MIT）。唯一可借鉴的是"把 token 也拼进匹配文本"，实测只值 −0.9pt，已否决 |
| 数据署名 | 使用 formulae.brew.sh 数据需注明来源与许可 |

## 12. 「我的」页改造

`features/mine` 是**原有样例页，直接就地改造**（不像 brew 页签那样新建模块）。

### 12.1 布局与数据来源

| 顺序 | 区块 | 数据 | 说明 |
|---|---|---|---|
| 1 | 华为账号 | `AccountService` | 原有 `LOGIN_ITEM`，未改动 |
| 2 | 用户体验调研 | `QuestionnaireViewBuilder` | 原有 `USER_EXPERIENCE_CARD`，未改动 |
| 3 | 内容上新 & 最新公告 | `NewContentModel` / `BulletinModel` | 原有 `CARD_ITEM` + 角标，未改动 |
| 4 | **已安装** | `BrewInstalledLoader` | 新增。**item 行入口**，右侧显示数量（`HmosListItem` 的 `desc` 槽位）。数据来自设备上的 brew 命令（见 §12.1.1） |
| 5 | **待更新** | 同上 | 新增。**大卡片**：图标 + 标题 + 数量 + 前 3 条 + 「查看全部」 |
| 6 | **已更新** | 同上 | 新增。同上 |
| 7 | 设置 & 反馈 | `MineSettingBuilder` | 原有，未改动 |

第 4-6 块的入口都进**同一个子页面** `MinePackagesView`，只靠路由参数 `mode` 区分
（`all` / `outdated` / `updated`）。三个页面各自实现会让筛选 chips、空态、加载态、返回处理各写三遍。

#### 12.1.1 本机包数据：读设备上的 brew 安装记录

数据来自一条命令：`<brew> info --json=v2 --installed`，由 `BrewInstalledLoader` 执行、
`BrewInstalledParser` 归一成 `BrewInstalledPackage[]`。

- 执行能力来自 `features/pcnative`（通用 native 能力模块，`ShellUtils` + NAPI）；
- brew 可执行文件的发现顺序：`HOMEBREW_BREW_FILE` → PATH 里的 `brew` → 固定候选路径
  （`SHELL_BREW_PATH_CANDIDATES`，与执行通道探针共用一份）；
- 结果在进程内缓存 60 秒（`BREW_INSTALLED_TTL_MS`），不落盘；
- 失败分六类（`BrewInstalledFailure`：找不到 brew / 执行能力不可用 / 超时 / 非零退出 /
  输出解析失败 / 形状不符），分类名进日志，页面走失败态。

原先读内置 mock（`brew-local-*.json`）的 `BrewLocalModel` 已随 2026-10 的快照下线一并删除，
`MinePackagesUtil.loadSets()` 从「返回空集」改为转调 `BrewInstalledLoader.loadSets()`；
`pick` / `filter` / `byName` 与全部 UI 结构未变。
`BrewInstalledPackage` 模型的每个字段到命令输出的映射见
`docs/superpowers/specs/2026-10-04-brew-installed-packages-spec.md` §6。

### 12.2 三个集合的口径定义在一处

`MinePackagesUtil.loadSets()` 是唯一的取数入口，「我的」首页的卡片预览与子页面的完整列表都用它。
两处各算一次迟早会让「预览的第一条」和「查看全部的第一条」不是同一个包。

| 集合 | 口径 | 数量 |
|---|---|---|
| `installed` | 全部已安装（Formulae + Casks），按名称 | 60 |
| `outdated` | 有新版本可升级，按名称 | 8 |
| `updated` | `installed` 里**不属于 `outdated`** 的，按 `installedAt` 倒序 | 52 |

`updated` 取补集而不是「全部已安装按 `installedAt` 倒序」，是这次实现里唯一偏离原始选择的地方：
后者与 `installed` 是同一批 60 个包，两张卡片会列出完全相同的包（只是顺序不同），一眼就能看出重复。
取补集后 8 + 52 = 60，不重不漏，同时保留「最近更新的排前面」的语义。若这不是想要的口径，改
`MinePackagesUtil.loadSets()` 一处即可。

### 12.3 「大卡片」为什么不需要新的渲染架构

原页面的内容区是数据驱动的 `ListGroup[]`，每个分组容器本身就是
「`comp_background_primary` 底 + `corner_radius_level8` 圆角 + `padding_level2`」——
这正好就是一张卡片。所以三块新内容只是新增了三个分组 + 两个新的 `BuilderEnum`
（`PACKAGE_CARD`；「已安装」行复用已有的 `CARD_ITEM`），渲染循环没有改动。

`MineItem` 上加了两个字段：`packageCardType`（这张卡片是待更新还是已更新）与
`showInstalledCount`（这一行右侧要显示已安装数量）。数量**不在 `listGroupData` 里写死** ——
它是静态字段，而数量是异步加载的，所以渲染时从 state 取。

### 12.4 版本号与安装来源的摆位

本机包行里两块辅助信息的摆位是**按长度定的**：

| 位置 | 宽度 | 放什么 |
|---|---|---|
| 副标题行 | 充裕（整行减首字母块） | 版本：`5.9.1 → 5.9.2`，已是最新则只显示 `5.9.2` |
| 尾部槽位 | 最短 | 来源：主动安装 / 作为依赖安装 |

一开始是反过来的，直到发现 cask 的版本号可以长到
`2026.2.5,262.10315.131 → 2026.2.5,262.10315.132`（45 字符）—— 放在尾部槽位必然被截成
`2026.2.5,262.10…`，等于没显示。**这是先算了数据再定版面才发现的**：待更新的 8 条按名称排序后
前三条恰好全是 cask。

---

## 13. Discover 页（三张榜）

### 13.1 视觉锚点：直接照搬组件页的两张卡

需求方指定了两个可定位的锚点，实现时按它们的规格逐项照搬，不自己发明：

| 用途 | 组件页里的卡 | 实现 | 照搬的内容 |
|---|---|---|---|
| **卡片外壳 + 榜内行** | 「常用组件 - 按钮、图片、进度条等」（`styleType=2`） | `ListCard` / `ComponentItemList` | `comp_background_primary` 底 + `corner_radius_level8` + `clip(true)`；行用 `HdsListItemCard`，同一组 `cardHeight` / `cardPrefixMargin` / `cardSuffixMargin` / `cardBorderRadius` / 透明底；分隔线 `1px` + `comp_background_tertiary` + `startMargin level36` / `endMargin level6` |
| **卡内大图区** | 「图库选择器 - PhotoPicker - 安全选择图库」（`styleType=3`） | `CodeLabCard` | `Stack` 内一层铺满的视觉层 + 底部压字；`title` = `Body_S` / `font_on_secondary` / `Medium`，`subTitle` = `Title_M` / `font_on_primary` / `Bold`，左边距 `level6` |

榜内那一行的字段映射（`BrewDiscoverRow`）：

| 槽位 | 内容 |
|---|---|
| prefix | 48vp 圆角方块 + **包图标基底 `BrewPackageIcon`**（中性实底 + 类型色 symbol + 同色描边）。**底色不再是榜色** |
| primary | **包名**（`token`，即 `brew install` 用的标识） |
| secondary | **应用的 `desc`**（英文原文） |
| suffix | `SuffixButton({ text: '查看', textColor: font_emphasize })`（固定系统强调色，不跟榜色） |

**名次与度量数字目前都不在行里**：名次角标按要求移除（名次由行的顺序表达）；
度量数字（安装量 / 增速）随 secondary 改成 `desc` 而退出界面。
四个度量文案模板（`brew_discover_metric_trending` / `_alltime` / `_fresh` / `_no_history`）
**保留在资源里未删**，若要把度量挪回界面（例如 icon 角落、或 `查看` 按钮左侧），模板可直接复用。

> 其中 `_no_history` 那条要留意：`velocity <= 0` 表示该包在 365 天窗口里没有历史（新包），
> **不能显示成「0 倍」**（会被读成"没涨"，事实是"没有可比的历史"）。
> 这条判断随 `metricText()` 一起删掉了，恢复度量显示时要一并恢复。

### 13.2 唯一替换掉的东西：那层图片

`CodeLabCard` 的视觉层是 `ImageComponent(objectFit: Cover)` + `backgroundColor(themeColor)`。
**Homebrew 官方 API 侧没有任何图片字段**：`formula.json` 里没有图标字段、
榜单数据里的 `mediaUrl` 是空串。第三方图标源 `appcasks` **本轮决定不接入**（**不是"不存在"** ——
`App-Fair/appcasks` 未归档且带 `AppIcon.png`，只是覆盖率没量化，见 `brew-discover-algo.md` §1.2/§8）。
所以这一层改成**代码画的渐变块**：

- 每个榜一套 start/end 两个色值（`brewdiscover/resources/base/element/color.json`）；
- 右上角一个 `opacity(0.16)` 的大号 `sys.symbol.*` 当水印，给纯色块一点纹理；
- **渐变末端取得足够深**，因为文字压在这一端 —— 这是「文字压在图/色块上」这个结构的硬约束，
  浅色末端会让白字不可读。

符号只用实测有效的名字（`docs §10.6` 的探针表）：`bolt_fill` / `list_checkmark` /
`plus_square_on_square`。写错会以 `Unknown resource name` 在编译期报出来，但**只有写成 `$r()` 字面量才会被校验**。

### 13.3 页面结构

```
BrewDiscoverHomeView        壳：持有自己的 PageContext（StorageKey.BREW_DISCOVER_PAGE_CONTEXT），压入列表页
 └─ BrewDiscoverListView    目的地：HdsNavDestination + 模糊标题栏 + 随滚动隐藏 + 返回键交基类
     └─ BrewDiscoverBaseView  内容：BaseHomeView(加载/失败/无网) + WaterFlow(单 section) + LazyForEach
         └─ BrewDiscoverBoardCard × 6   一张卡 = 一张榜
             ├─ BrewDiscoverHero        代码画的渐变块 + 底部压字（组件页 CodeLabCard 规格）
             ├─ BrewDiscoverRow × 5     榜内前 5 条（组件页 ListCard 行规格）
             └─ 查看全部 → BrewDiscoverBoardView（二级页，同 MinePackagesView 的写法）
```

与 Formulae 首页**完全同构**（这正是「前三个页签复用组件页首页 UX」的要求），
差别只有卡的内容：那边一张卡 = 一个分类，这边一张卡 = 一张榜。

**PageContext 必须是本模块自己的 StorageKey**：共用会与 Formulae/Casks 的页面栈串起来，
从一个页签的二级页离开会影响到另一个页签。

### 13.4 三个刻意的取舍

1. **`查看全部` 只在条目数 > 5 时出现**。新星榜常常不足 5 条（本次快照 Formulae 4 条 / Casks 4 条），
   那时这个入口会指向一个没有任何增量的页面。
2. **`velocity <= 0` 不显示成「0 倍」**。它表示该包在 365 天窗口里没有历史（新包），
   文案走 `brew_discover_metric_no_history`「暂无历史」—— 显示 0 会被读成"没涨"，
   而事实是"没有可比的历史"。
3. **section 不再叠一层 margin**。Formulae 页的 `updateFlowSection()` 给 section 设的
   left/right margin 与视图 `padding` 里的 `brewPageContentLeft/Right` 是同一组数值，
   看起来是双份内缩。Discover 只保留视图层那一处（`margin: 0`），边距只有一个来源。

### 13.4.1 单 App 大图卡（`featured`）—— 对齐组件页 `CodeLabCard` 的解剖结构

瀑布流最前面是 5 张**单 App 大图卡**（一张卡 = 一个包）。选取规则见
`docs/brew-discover-algo.md` §6.1（`FEATURED_RULE`，编辑口径写在生成器里）。

#### 组件页那张卡（「图库选择器 - PhotoPicker - 安全选择图库」）的结构

需求方明确要求"先去研究它的结构"，逐层拆开是：

```
Stack(alignContent: TopStart)
├─ TagTipLabel                          左上角 NEW 标签（margin top/left level3）
└─ Stack(alignContent: Bottom)
   ├─ ImageComponent(objectFit: Cover)   铺满整卡，backgroundColor = themeColor
   └─ Column(height = codelab_card_content_height 144vp, justifyContent: End)
      ├─ Text(title)      Body_S / font_on_secondary / Medium   margin left/level6, bottom level2
      ├─ Text(subTitle)   Title_M / font_on_primary  / Bold      margin left/level6, bottom level2
      └─ ComponentItemList(suffixType = ICON, itemHeight = codelab_content_height 72vp)
           每行 = HdsListItemCard:
             prefix  ComponentIcon  = Image 48vp(tip_image_height) + corner_radius_level5
                                      + backgroundColor(themeColor)，margin left level6 / right level8
             text    primary + secondary，ICON 类型下都是 font_on_primary（白字压图）
             suffix  CircleArrow    = Button{ chevron_right } 40vp(arrow_size)
                                      + aspectRatio(1) + backgroundColor(comp_background_primary)
整卡 .height(codelab_card_height = 400vp) + corner_radius_level8 + clip(true)
```

**"左下角 icon、右下角 `>` 按钮"就是最后一行 item 的两个槽位** ——
`ComponentIcon`（行首 48vp 方块）与 `CircleArrow`（行尾白圆底 `>` 40vp）。

#### 本卡的对应关系

| CodeLabCard | 这里 |
|---|---|
| `ImageComponent` 铺满 | 代码画的渐变铺满（Homebrew 无图标/截图素材） |
| `TagTipLabel`（左上） | **留空**（不挂东西） |
| —（右上原本没有） | **增速徽章**「↑22.0×」 |
| `title` 小字 | **来源徽章**「今日热门 · 第 1 名」（= 原先放包名的那一行） |
| `subTitle` 粗体大字 | **英文原文描述**（限 2 行、超出 ellipsis） |
| `ComponentItemList` 那一行 | 48vp 首字母图标 + **市场名** + **下载量** + `>` 圆钮 |
| `CircleArrow` | 同款重新实现（它是 `componentlibrary` 的**私有** struct，跨模块拿不到）：三属性一一对应，不发挥 |

**卡上保留的两个字符串**（需求方最终指定），以 `vorssaint` 为例：

| 字符串 | 取自 | 放在哪 |
|---|---|---|
| 市场名 `Vorssaint` | 详情的 `name` 字段（formula 通常等于 token；cask 是 `Microsoft Visual Studio Code` 这种可读名） | item 行 primary（1 行截断） |
| 描述 `Menu bar toolkit with keep-awake…` | 详情的 `desc`（英文原文） | **大字加粗（2 行截断）** |
| 来源「今日热门 · 第 1 名」 | 榜单的 `boardKey` + `rank` | 小字行（= 原先放包名的那一行） |

包名（`token`）**不放在这张卡上**（需求方明确"包名不应该放那"）。
包名在榜卡的行里仍然可见（那里 primary 就是 token）。

> **位置来回改过一次，教训**：需求方先说"撤销来源徽章、把包名去掉"，我理解成
> **删掉**来源徽章；实际是"把它从左上角**挪到**包名原来那一行"。
> 同一句话里"撤销 X、去掉 Y"可能是在描述**一次移动**（X 移到 Y 腾出的位置），
> 而不是两个独立的删除。拿不准时应当先确认再动手，代价比返工小。

底部块高度取 **176vp**（组件页 `codelab_card_content_height` 是 144vp）：
组件页那 144vp 装的是「1 行 title + 1 行 subTitle + 72vp item 行」≈ 122vp；
本卡多了一行来源徽章、且描述是 2 行，合计 ≈ 152vp，144vp 装不下 ——
而该块是 `justifyContent(End)` 固定高度，装不下会**从上方裁掉**（先丢的就是来源行）。

item 行 secondary 是「下载量 1.3k」——**不只放一个裸数字**，提示词走资源占位符
`brew_discover_installs_label`（`%s downloads` / `下载量 %s`），不硬编码。

> **一处我自己的偏差已纠正**：最初把增速徽章放在左上、把「榜别 · 名次」挤到小字行。
> 但 `CodeLabCard` 的左上角本来就是 `TagTipLabel` 槽位 —— 来源徽章该在那儿，
> 小字行还给包名。对齐结构时要连**槽位**一起对齐，不能只看有哪些元素。

尺寸：`brew_discover_featured_height` = **400vp**，与卡宽（1 栏 = 400vp）构成 **1:1**，
和组件页 `codelab_card_height` 一致。实测 761 × 760 px ✓。

#### 两个踩过的坑

1. **上一版缺的就是那一行 item**。最初把底部做成"居中的 140vp 巨字母 + 三行纯文字"，
   于是既没有行首 icon、也没有行尾 `>` 按钮 —— 与 CodeLabCard "底部一个 item 行" 的结构
   不是一回事。尺寸对了不等于结构对了，**要对齐的是结构，不是尺寸**。
2. **行首图标必须是独立 `@Component`**，不能把容器内联进 `PrefixCustomBuilder` 的箭头里：
   `HdsListItemCard` 的前缀槽位是拿 builder **根节点的测量宽度**给正文留位的，
   根节点是普通容器时量到的是里面 Text 的字宽，正文会被方块盖住
   （`BrewMonogram` 的注释里已记过一次，组件页的 `ComponentIcon` 同样是独立 `@Component`）。
3. **抄组件页的 builder 要连外面那层包装一起抄。** 组件页的右槽位 builder 叫
   `CircleArrowBuilder`：`Row { CircleArrow() }.padding({right: level4})` ——
   右内缩是**这层 Row 的 padding** 给的。我只抄了里面的 `Button`（`CircleArrow`），
   又同时去掉了底部块那一层 `padding`：左侧没问题（图标自带 `margin left level6` 顶着），
   **右侧没有任何东西补位，按钮直接贴到卡片右缘**（需求方反馈"右侧的边距消失了"）。
   **改一个容器的内缩时，要逐个方向确认还有谁在提供内缩** —— 左边有、右边不一定有。
   这与 §9.9 / §9.10 是同一类问题的第三种变体（那两次是"同一节点重复写属性"、
   "并列页面只写了一半边距"）。

### 13.5 多栏瀑布流：照抄组件页，不要自己拍列数

**踩的坑**：我最初把断点配置写成 `crossCount: {sm:1, md:1, lg:2, xl:2}` —— 想的是"我们的卡片比
组件页的大，那就少放一列"。结果这台 PC 恰好跑在 **md** 档，于是 Discover 是**单栏**、
组件页是**双栏**，一眼就不像同一个东西。需求方反馈的原话是「你没发现我一直在说组件页吗」。

**怎么确认它跑在 md 档**（不用改代码、不用点页面，用 dump 反推）：

1. 从 dump 里读两个已知量：`columnsGap` 与 `margin` 都是 `BreakpointType` 的三档值之一；
2. 用实测像素去除，看哪一档能同时对上多个量。

本次实测对账（组件页）：

| 量 | 实测像素 | 除以 **1vp≈1.9px** | 说明 |
|---|---|---|---|
| 行间距 | 122 px | 64 vp | = `brew_package_row_height`，用来**标定比例尺**（这个值是我们自己定的，最可靠） |
| 名次徽章 | 60×61 px | 32 vp | = `brew_discover_rank_badge_size`，交叉验证比例尺 ✓ |
| 卡片宽 | 761 px | 400 vp | 2 列 × 400 + 间距 + 边距 = 860vp = 内容区宽 ✓ |
| 列间距 | 23 px | 12 vp | **配置写的是 `level6`** |
| 左右内缩 | 45 / 44 px | 24 vp | **配置写的是 `level12`** |

后两项实测是配置值的 2 倍。做到大图卡时终于把这件事解释通了：

**横向的 margin / padding / gap 与纵向的尺寸，在这套环境下的 px/vp 比例不一样。**

| 量 | 配置 | 实测 px | 换算 |
|---|---|---|---|
| 行高 `brew_package_row_height` | 64vp | 122 | **1.9 px/vp** |
| 图标 `brew_discover_row_icon_size` | 48vp | 91 | 1.9 ✓ |
| 大图卡高 `brew_discover_featured_height` | 400vp | 760 | 1.9 ✓ |
| 分段内缩 `level12`（section margin） | 12vp | 45 | **3.8 px/vp** |
| 列间距 `level6`（columnsGap） | 6vp | 23 | 3.8 ✓ |
| 文字内缩 `level6`（padding） | 6vp | 22 | 3.8 ✓ |

所以**不要用同一个比例去换算横向和纵向**。踩到的具体后果：核对"描述文字与 item 图标是否左对齐"
时，我先按 1.9 算，得出"差了 6vp、需要调 margin"，差点改错 ——
按 3.8 算，两者其实都落在 1038，本来就是对齐的。

**最终判据始终是"两个页面量出来是否一样"**（组件页实测也是 45 / 44 / 23 / 761），
而不是"我按某个比例算出来该是多少"。

三档里只有 `md` 能同时满足，于是确认断点，也就确认了我该写 `md: 2` 而不是 `md: 1`。
**这个反推方法比"猜设备宽度档位"可靠，也不需要跑代码。**

**内缩机制也要照抄**：`ComponentBaseView` 的 `WaterFlow` 上**一个 `.padding()` 都没有**，
左右内缩全部来自 `componentColumnSection.margin`。Discover 原来是在视图层写 `padding`、
section margin 置 0 —— 机制不同就有两个来源的风险（§9.9 / §9.10 已经因此吃过两次亏）。
现在改成与组件页一致：**内缩只在 `updateFlowSection()` 里给 section 设 margin**，
视图层只保留 `padding.top`（本页没有 banner，必须手动避开标题栏；组件页的顶部是 banner 填满的，
所以它连这个都不需要）。

### 13.6 落定后的实测核对（Discover vs 组件页）

改完多栏配置后 dump 两个页面逐项对比，**不是"应该一致"，是量出来一致**：

| 量 | 组件页 | Discover |
|---|---|---|
| 第 1 栏 x 范围 | 1016 → 1777 | **1016 → 1777** |
| 第 2 栏 x 范围 | 1800 → 2561 | **1800 → 2561** |
| 列间距 | 23 px | **23 px** |
| 左 / 右内缩 | 45 / 44 px | **45 / 44 px** |
| 列数 | 2 | **2** |

比例尺标定：行间距 122px ÷ `brew_package_row_height`(64vp) = 1.9 px/vp，
用名次徽章 60px ÷ 32vp 交叉验证 = 1.875 ✓。

**顺带纠正我自己的一个错误结论**：改之前我按 1vp≈3.7px 反推，得出"内缩 = 12vp = 配置的
`level12`"。用行高标定后实际是 1vp≈1.9px，内缩 45px = **24vp**、间距 23px = **12vp** ——
都是配置值的 2 倍。**但这个错误不影响当时的结论**（断点仍是 md，因为列数 2 只对应 md 档），
也不影响最终目标：判断依据不是"我算出来该是多少"，而是"两个页面量出来是否一样"。

> **教训**：反推比例尺要用**自己定的、语义明确的值**（如行高、徽章尺寸），
> 不要用"某个配置值应该是多少"去反推 —— 后者会把配置本身的解析差异误当成比例尺。

### 13.7 缓存坑：数据更新了，页面却没变（历史记录，处理方式仍然有效）

**现象**：补「单 App 大图卡」后，生成器已产出 `featured`、编译装机都成功、
`modules.abc` 里符号也在，但页面上只有榜卡，没有大图卡 —— 看起来像"代码没生效"。

**原因**：`BrewDiscoverModel` 原来照抄其它 Model 的写法「先读 Preference 缓存，未命中再请求」。
缓存里是**上一版数据**（没有 `featured` 字段），于是新卡片永远不会出现。
这个故障比编译错更难查，因为它**编译过、装机成功、无异常、无日志**。

**处理**：Discover **刻意不在本层缓存整页**。现在它的数据来自 `BrewService.getCatalog()`，
那一层已经带 TTL + 条件请求缓存；若在本层再缓存一份，就会重现同样的故障
（「目录更新了、页面还显示上一次组装结果」）。
榜单是"算法在某个时间点的一次冻结"，页面的全部意义就是让人看到当前那一份。

> 这类问题与 §9.8 / §9.9 / §9.10 同一类：**编译全绿、静态查不出、只有跑起来才看得见** ——
> 而且比 UI 那几条更隐蔽，因为界面上"少了一块"很容易被当成还没做完。

### 13.8 榜单数据从哪来

**数据源 = 设备端现算的目录**（`BrewService.getCatalog()` + `BrewCatalogAlgo.ets`），
端点、容量、条件请求与 join 见 §7.4.1，算法口径的唯一权威说明见 `docs/brew-discover-algo.md`
（可执行形式：`hmosword-build/brew-mockgen/check_algo.py`）。

**没有回落了**（2026-10）：`brew-discover-page.json` 及其生成器代码已删除，
所以「哪六张榜」在代码里构造（`BrewRepository.emptyDiscoverPage`，
`id = sequence = 1..6` 与旧快照逐字一致 → 二级页 `boardId` 路由零影响），
**成员唯一来源 = 目录**。目录拿不到时六张榜保持骨架但成员为空，
`BrewDiscoverVM.loadDiscover` 过滤掉空榜 → feed 为空 → 页面走空态（SUCCESS + 0 项）。
数值不再由单条 hydrate 重算（`applyMetrics` / `sortBoard` 已删）：目录给的数字与名次就是榜的权威顺序。

`snapshotDate`（数据窗口结束日）会显示在二级页顶部，让「基于最近可用数据」这句话有据可查 ——
它取自目录的 `meta[kind].windowEnd`（当天窗口的 `end_date`），骨架里是空串。

榜单条目自带 `categoryKey`（来自白名单 join），
所以从 Discover 点进详情页时「同分类其他包」这一段是完整的 ——
不留这个字段的话，从 Discover 进来的详情页会缺一段推荐。

### 13.9 交互接线与二级页上下边距（榜内行可点 / 整卡可点）

需求方一次反馈三条，根因各不相同：

| 反馈 | 根因 | 改法 |
|---|---|---|
| 榜里的行点不进详情页 | `BrewDiscoverRow` 有 `handleItemClick` 回调，**但 `build()` 里根本没挂 `.onClick`** —— 回调从页面一路传到组件，只是没人触发它 | 行上挂 `.onClick(() => handleItemClick?.(entry))`，写法与 Formulae 已验证可用的 `BrewPackageRow({...}).onClick(...)` 同款 |
| 整张榜卡点不进「查看全部」 | 只有卡片底部那行「查看全部」可点，Hero 与卡片空白处没有入口 | 卡片根节点挂 `.onClick(() => handleViewAll?.(board))` |
| 二级页顶部空白过多、底部没有留白 | 顶部用了 `brewTitleBarTotalHeight()` —— 它把 `BREW_CHIP_BAR_HEIGHT`（整整一行 56vp）也算进去了，**而本页标题栏里只有标题、没有 chips**；底部只有 `naviIndicatorHeight`，2in1 上这个值是 0 | 改成与详情页同一个口径：顶部 `statusBarHeight + NAVIGATION_HEIGHT`、底部 `naviIndicatorHeight + SPACE_24` |

**「行可点」与「整卡可点」能并存，靠的是 ArkUI 的手势规则，不是靠挡事件**：
手势事件**不冒泡** —— 父子组件绑定同类手势时会发生竞争，最多一个胜出，默认子组件优先
（`arkts-gesture-events-binding.md`）；终止冒泡只对基础事件（onTouch 那类）有效，
且明确**不中断父组件的手势响应**（`arkts-interaction-basic-principles.md`）。
所以点行只跳详情、点 Hero/空白只跳榜单，**不需要也不应该**给行加 `hitTestBehavior(HitTestMode.Block)`
—— 那会连带挡掉行内的子节点，也会影响瀑布流自身的滚动。

> 组件里写注释时容易把这条说反：`onClick` 看起来像"点击事件、应该会冒泡"，
> 实际它是手势，按手势竞争处理。这一点写进注释，避免下一个人"顺手补个 stopPropagation"。

**`brewTitleBarTotalHeight()` 只适用于「标题行 + chips 行」的页面**（两个分类二级页、我的-本机包）。
标题栏里没有 chips 的页面（两个页签首页、包详情页、榜单二级页）必须自己写
`statusBarHeight + NAVIGATION_HEIGHT`（或用 `brewContentTopInset(h, false)`），
否则顶部白白多一条 ~56vp 的空白。这类"让位高度与实际标题栏内容不匹配"的故障没有任何报错，
只是多一条空白 —— 与 §9.9 同族：**常量/属性写对了，不代表它的来源是对的**。

顺带把榜内行的 secondary 加了 `WordBreak.BREAK_ALL`（描述是英文，长 token 默认会整词挪到下一行、
提前省略；BREAK_ALL 允许词内断开，先把整行填满再省略）。`maxLines + TextOverflow.Ellipsis`
与 BREAK_ALL 同用是官方文档写明的用法，`TextModifier` 继承 `TextAttribute`，可直接在链上调。

#### 同类页面：底部留白按「内容是不是一整张卡片」分两组

同一个 `naviIndicatorHeight` 在 2in1 上是 0，所以底部留白实际上全靠后面那项。两种结构两种来源：

| 组 | 页面 | 底部留白来源 |
|---|---|---|
| **内容是一整张卡片**（没有 section 可用） | 包详情页、榜单二级页、我的-本机包二级页 | **`naviIndicatorHeight + SPACE_24`**（视图 `padding.bottom`） |
| **WaterFlow 首页**（Formulae / Casks / Discover） | section 的 `margin.bottom` 兜底：组件页与 Discover 是 `level6`，Formulae / Casks 是 `level10`（`columnMargin`） | 视图 `padding.bottom` 保持 `naviIndicatorHeight` 即可 |

`MinePackagesView`（我的-已安装/待更新/已更新）原本只写了 `naviIndicatorHeight`，
和榜单二级页同一个毛病 —— 内容是一整张卡片，**底部真的贴到窗口下沿**，已改成 `+ SPACE_24`
（与同属“我的”的 `BulletinView` / `NewContentItem` 原有的 `SPACE_24 + naviIndicatorHeight` 同口径）。

> 三个首页页签**没动**，也不是同一个毛病：它们的底部留白由 section margin 提供
> （`ComponentListViewModel` 给组件页列的 `margin.bottom` 就是 `padding_level6`，Discover 照抄了它，
> Formulae / Casks 用的是 `columnMargin`）。它们有留白，只是数值与二级页不同 ——
> **“贴边”和“留白比别处小”是两件事，不要一起改。**

验证：BUILD SUCCESSFUL、符号在 `modules.abc` 内、HAP 路由表仍 22 条、装机启动成功；
三条行为由需求方在真机上确认。
