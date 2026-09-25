# brew 应用市场 · 搜索功能设计（spec）

| 项 | 值 |
|---|---|
| 状态 | 待评审 |
| 日期 | 2026-09-21 |
| 分支 | `dev`（`606c3ba` 起） |
| 需求 | 按截图（AppGallery PC：侧边栏搜索框 + 搜索历史/搜索发现浮层）为本项目新增搜索 |
| 关联文档 | `docs/brew-handover.md`（§8.2 待办「搜索」）、`docs/brew-marketplace-content-plan.md`（§13 预留方案）、`docs/brew-api-design.md`（实现细节与踩坑）、`docs/hds-titlebar-blur.md`（标题栏模糊） |

需求方在开工前确认的三条口径：

1. **范围**：搜索框 + 浮层 + **真实搜索结果页**（不是只做版式）。
2. **历史/发现数据**：**都先写死**，不做数据源、不落盘。
3. **验收**：我装机交付，**需求方手动测试**。

> **2026-09-24 修订（口径 2 作废）**：需求方要求「搜索历史和搜索推荐都改成真的」，
> 并顺带改成**显式触发搜索**（回车 / 点「搜索」才搜，`onChange` 不再触发）。落地结果见 §8：
> 历史 = 用户真正执行过的搜索（落盘，重启后仍在）、发现 = 设备端目录里的真实热门包，
> 输入防抖随之删除（§6.5）。本次变更**不新增任何假数据回落** —— 数据没就绪时显示空态。
> 正文里与这两点冲突的段落（§1.2、§4.4、§5.4、§6.5、§11）已就地改为当前口径。

---

## 1. 目标与非目标

### 1.1 目标

| # | 目标 |
|---|---|
| G1 | 侧边栏搜索框：折叠态（灰底 + 放大镜 + 「搜索内容」）；聚焦态（白底 + 右侧分隔线与蓝字「搜索」），与截图一致 |
| G2 | 聚焦弹出浮层：`搜索历史`（chips + 清空 + 折叠）与 `搜索发现`（2×2 两列 + 换一批） |
| G3 | **真实本地搜索**：用设备端已有的全量索引匹配，结果页在内容区，行可点进现有包详情页 |
| G4 | 侧边栏常驻；退出搜索回到原页签，**页签状态不丢**（不回到首页、不丢滚动位置） |

### 1.2 非目标（本轮明确不做，避免被当成漏做）

| 不做 | 原因 |
|---|---|
| ~~历史持久化~~ | **已做（2026-09-24 修订）**：历史落盘在 Preference（`brew_search_history`），重启后仍在；原「重启后回到内置词组」的口径作废（§8）。**仍然不做**的只有「搜索联想 / 拼音纠错」（无数据源） |
| 搜索联想 / 拼音 / 纠错 / 拼写建议 | 无数据源，且超出「新增搜索框」的范围 |
| 结果分页 | 一次算完取前 50 条；全量 2.6 万条的排序本身在毫秒级 |
| 埋点 | `HomeView.reportTrackData` 的契约不扩（`MainTabEnum.UNKNOWN` 已覆盖新入口） |
| 服务端搜索 | `formulae.brew.sh` 没有搜索端点；本地索引（`BrewMetaSync`）就是唯一路径 |
| 结果页顶部第二个输入框 | 侧边栏那个框是**唯一输入点**，天然支持「边输边出结果」，也免掉一套双向同步的关键字状态 |
| 下线对照页签 | `LEGACY_TABS_ENABLED` 保持现状，与本功能无关 |

---

## 2. 已核准的事实（写代码时不用再查）

这一节是 spec 的地基：下面所有设计都建立在**已读过源码确认**的接口上，不是推测。

### 2.1 数据层（`features/brewcommon`）

| 事实 | 位置 | 对设计的含义 |
|---|---|---|
| `BrewMetaSync.descOf(kind): Record<string, string>` —— **同步、无网络**，内存有就用内存、否则读一次 Preference | `service/BrewMetaSync.ets:262` | 搜索可以做成**纯同步**计算，不必 async、不必 loading 态 |
| `BrewMetaSync.ready(): boolean` —— 索引是否已有内容 | `service/BrewMetaSync.ets:268` | 「索引未就绪」的降级判据 |
| 索引由 `SplashViewModel` 在启动时 `BrewMetaSync.start()` 拉起（不阻塞首屏） | `viewmodel/SplashViewModel.ets:97` | 冷启动后几秒内索引才就绪 → 必须能处理「用户比索引快」 |
| 索引口径：只抽 `token → desc`，约 1MB，与目录分开落盘 | `service/BrewMetaSync.ets` 文件头注释 | 搜索结果里**没有**版本/许可等字段（那些要单条 doc），但列表行不需要它们 |
| `BrewService.browseRows(catalog, kind)` → `catalog.topTokens[kind]`，**已按 30d 安装量降序、不裁切** | `service/BrewService.ets:1028` | 排序的 tie-break 直接用这个顺序，不用自己排 |
| 同函数是 `private static` | 同上 | **必须新增一个公开入口**（见 §3.3），UI 模块拿不到它 |
| `CatalogEntry = {token, vol30d, vol365d, prior, velocity, score}` | `service/BrewService.ets:120` | 权重与 tie-break 的输入 |
| `BrewTaxonomy.categoryOf(kind, token, desc): string` —— 策展覆盖 → 关键词 → 兜底 | `constant/BrewTaxonomy.ets:350` | 结果行的分类标签与详情页 `categoryKey` 参数的来源，零成本 |
| `BrewBrowseBuilder.tokenId(token): number` —— token 的稳定哈希 | `service/BrewBrowseBuilder.ets:62` | 详情页路由参数 `id` 的来源（**不能自己造**，否则详情页缓存键错位） |
| `BrewBrowseBuilder.formulaItem/caskItem(row, doc, desc, categoryKey)` 是 **`private static`** | `service/BrewBrowseBuilder.ets:214,233` | **必须新增公开包装**（见 §3.3）；`doc` 允许缺省，搜索不拉单条 |
| `BrewService` 是**用 `new` 实例化**的（`private service: BrewService = new BrewService()`） | `model/BrewRepository.ets:74` | 新的搜索取数走同一形状：Repository 持一个 service 实例 |

### 2.2 UI 层（可复用资产）

| 事实 | 位置 | 对设计的含义 |
|---|---|---|
| `BrewPackageRow` 契约 = `packageItem` + `kind` + `itemHeight` + `handleItemClick` | `component/BrewPackageRow.ets:43` | 结果行**直接复用**，不新造行组件（避免复制漂移，见 handover §3.2） |
| `BrewPackageRow` 右槽渲染 `BrewFormat.rankText(categoryRank, categorySize)`；而 `rankText(0,0)` 返回 **`"0 / 0"`**（不判 0） | `component/BrewPackageRow.ets:59`、`util/BrewFormat.ets:40` | 搜索结果没有分类语境 → 必须能给行**关掉**名次，否则每行都显示 `0 / 0`（见 §3.4） |
| `BrewPackageItem` 是 class，字段全有默认值，含 `token/title(desc)/subTitle(token)/installs30d/categoryKey/id` | `model/BrewModels.ets:56` | 结果行与详情页路由参数所需的字段都能装下 |
| `BrewPackageItemSource implements IDataSource`，换数据走 `setDataArray`（会通知重载） | `model/BrewPackageItemSource.ets:29` | 结果列表的 `LazyForEach` 数据源直接复用 |
| `BrewChipBar` = `chips: BrewChipItem[]` + `currentIndex` + `handleChipClick`，横向 Scroll、纯文字胶囊 | `component/BrewChipBar.ets` | 结果页的「全部 / Formulae / Casks」过滤 chips **直接复用** |
| `BrewChipBar` 是横向 `Scroll`，**不换行** | 同上 | 浮层里的历史 chips 要换行 → 样式照它、结构自己写（`Flex wrap`） |
| `brewTitleBarStyle(page)` / `brewContentTopInset(statusBarHeight, hasChipsRow)` / `brewTitleBarTotalHeight(statusBarHeight)` | `util/BrewTitleBar.ets:114`、`constant/BrewConstants.ets:344,365` | 结果页的标题栏模糊与内容让位**必须**走这三个（`hds-titlebar-blur.md` 的坑全在里面） |
| `MinePackagesView` = 二级页 + 标题栏 chips + `LazyForEach` 列表 + 返回键防重入 + 三种加载态 | `features/mine/src/main/ets/view/MinePackagesView.ets` | 结果页的**模板**，结构逐点对齐它 |
| `PageContext` 封装 `NavPathStack`；每个页签模块**自持**一个（`StorageKey.BREW_*_PAGE_CONTEXT`） | `common/routermanager/PageContext.ets`、`common/constant/CommonEnums.ets:79-81` | 搜索页要自己的 context，**共用会让两个栈串起来** |
| 二级页靠各模块 `module.json5` 的 `routerMap` 注册，HAR 不被任何模块 import 也会被编译 | `features/brewdetail/.../router_map.json`、handover §9.2.1 | 结果页不需要被谁 import，注册即可 |
| `BrewDetailParams = {kind, title, id, token, categoryKey}` | `model/BrewModels.ets:340` | 点结果行要凑齐这五个 |
| `CustomSideBar`（94 行）= 标题行 + `ForEach(TABS_LIST)`；外面是 `HdsSideBar.sideBarPanelBuilder` | `products/pc/.../component/CustomSideBar.ets` | 搜索框插在标题行与列表之间 |
| 内容区 = `HdsSideBar.contentPanelBuilder → GridRow → HomeView(HdsTabs)` | `products/pc/.../page/PcMainPage.ets:80` | 搜索态只需替换这一处 |
| 侧边栏既有数值：`side_bar_height=40vp`、`side_bar_title_height=56vp`、`app_icon_width=24vp`、`SIDE_BAR_WIDTH=240` | `products/pc/.../float.json`、`common/.../CommonConstants.ets:31` | 搜索框高度与内缩的取值基准（§4.1） |

### 2.3 工具与流程

| 事实 | 含义 |
|---|---|
| `DebounceUtil.debounce(func, wait)` 是**全局单例时间戳的 leading 节流**（`common/util/DebounceUtil.ets`） | **不能用于输入防抖**：它不是 trailing、还会和别处共用同一个 `lastClickTime` 互相干扰 → 自己用 `setTimeout/clearTimeout` |
| `devecocli` **没有 test 命令**（`devecocli --help` 只有 build/run/check/device/ui/log/…） | hypium 用例在本工作流跑不起来 → 不能拿「跑过单测」当证据（§7.2） |
| `AppGallery` 截图量出的比例（本次实测）：侧边栏 ≈ `240vp`（与本项目同值）、搜索框 ≈ 侧边栏内缩后满宽（≈208vp）、浮层面板宽 ≈ **搜索框的 1.9 倍**（≈400vp） | §4.1 的初始数值依据；最终以 `ui layout` 实测校正 |

---

## 3. 架构

### 3.1 分层

搜索**不引入新的数据源**：匹配跑在设备端已有的「目录（安装量）+ 元数据索引（desc）」上。三层各管一件事：

```
UI（features/brewsearch）
  BrewSideSearchBox      侧边栏搜索框 + bindPopup 浮层（一进搜索的唯一入口）
  BrewSearchHomeView     内容区壳：HdsNavigation + 自己的 PageContext
  BrewSearchResultView   结果页（栈底）：标题栏 + chips + LazyForEach
        │  只依赖 Repository，不碰 Service/BrewMetaSync
        ▼
仓库（features/brewcommon/model/BrewRepository.ets）
  BrewSearchModel        单例：new BrewService() → searchRows() → 跑引擎 → BrewPackageItem[]
        │
        ▼
服务 + 引擎（features/brewcommon）
  BrewService.searchRows(kind)   新增：公开目录全量行（包装 private browseRows）
  BrewSearchEngine               新增：纯函数 打分 + 排序（无 ArkUI / 无网络 / 无状态）
  BrewMetaSync.descOf(kind)      已有：同步读索引
  BrewTaxonomy.categoryOf(...)   已有：分类
  BrewBrowseBuilder.formulaItem/caskItem  改动：private static → public static（只改可见性）
```

**为什么引擎与取数放 `brewcommon` 而不是新模块**：`browseRows` / `formulaItem` 都是 `private static`，只有同模块能直接调；而且「搜索」本质上和「浏览」是同一套口径（同一份目录、同一套分类、同一个 `tokenId`），放一起才不会漂移。新模块 `brewsearch` 只装**只有搜索才用的东西**（侧边栏框、浮层、结果页）。

### 3.2 新模块 `features/brewsearch`

照 `brewdiscover` 那套骨架（HAR + `routerMap` + `Index.ets` 只导出入口 + 模块级 `.gitignore` 首行 `/oh_modules`）：

```
features/brewsearch/
  Index.ets                                         export BrewSearchHomeView / BrewSideSearchBox
  build-profile.json5, hvigorfile.ts, oh-package.json5, consumer-rules.txt, obfuscation-rules.txt, .gitignore
  src/main/module.json5                             har + routerMap: $profile:router_map
  src/main/resources/base/profile/router_map.json   BrewSearchResultView
  src/main/resources/base/element/float.json        brew_search_box_height 等（§4.1）
  src/main/resources/{base,zh_CN,en_US}/element/string.json
  src/main/ets/constant/BrewSearchConstants.ets     死写词组、上限、防抖、几何
  src/main/ets/viewmodel/BrewSearchState.ets        每页实例状态
  src/main/ets/viewmodel/BrewSearchVM.ets           单例：跑引擎、给数据源与 chips
  src/main/ets/component/BrewSideSearchBox.ets      侧边栏搜索框 + 浮层挂载
  src/main/ets/component/BrewSearchSuggestions.ets  历史 + 发现（浮层与结果页空态共用一份）
  src/main/ets/model/BrewSearchRowSource.ets        结果行 IDataSource（kind + item）
  src/main/ets/view/BrewSearchHomeView.ets          内容区壳
  src/main/ets/view/BrewSearchResultView.ets        结果页
```

> **引擎放哪个模块的取舍**：`BrewSearchEngine` 是纯函数、无 ArkUI 依赖，放 `brewcommon`（与 `BrewCatalogAlgo` / `BrewBrowseBuilder` 同级）能避免 `brewsearch` 为了复用而反向依赖 UI 模块。`BrewSearchConstants` 里只有死写词组与几何，留在 `brewsearch`。

### 3.3 `brewcommon` 的三处新增（公开入口）

| 新增 | 签名 | 为什么必须新增/改动而不是就地改 |
|---|---|---|
| `BrewService.searchRows` | `public searchRows(kind: string): CatalogEntry[]` | `browseRows` 是 `private static`，跨类不可见。返回 `ensureCatalog()?.topTokens[kind] ?? []`（**已按 vol30d 降序**）；拿不到目录时返回空数组，调用方回落 desc 索引 |
| `BrewBrowseBuilder.formulaItem` / `caskItem` | `private static` → **`public static`**（**只改可见性，不动实现**） | 搜索要复用它们把 `CatalogEntry` 变成 `BrewPackageItem`，但不应该再写一遍（复制漂移）。`doc` 传 `undefined` 是安全的：两个工厂内部全是 `doc?.x ?? ''` |
| `BrewPackageRow.hideRank` | `@Prop hideRank: boolean = false` | `true` = 不渲染「分类内名次」。**默认 `false` 保证现有 5 个调用点行为完全不变**（Formulae 分类页/卡、Casks 分类页/卡、详情页「同分类其他包」）（§2.2：`rankText(0,0)` 会渲染出 `"0 / 0"`） |

formula / cask 的分支放在 `BrewSearchModel` 而不是那个包装函数：`BrewKindText` 定义在 `BrewService.ets`，而 `BrewService` 已经 import 了 `BrewBrowseBuilder` —— 反向 import 会形成**循环依赖**。而 `BrewRepository` 本来就 import 了 `BrewKindText`（`:19`），分支放那里零成本。

`BrewSearchModel`（`BrewRepository.ets`，单例 + `getInstance()`，与 `BrewFormulaModel` 同款）：

```ts
public search(keyword: string): Promise<BrewSearchResult>   // 见 §6.4
```

### 3.4 为什么结果行不显示分类内名次

`BrewPackageRow` 的右槽语义是「分类内排名 + 近 30 天安装量」。搜索结果**没有分类语境**（一次搜索跨 17 个分类），名次只能是全局名次 —— 而全局名次在「全部 / Formulae / Casks」三种过滤下会变，是假信息。所以搜索结果的行为：

- 右槽：只保留 `compactCount(installs30d)` + `chevron_right`（关掉名次，见 §3.3）；
- 左槽：`BrewPackageIcon` + token + desc（`BrewPackageRow` 现状）；
- 分类信息不进行（避免与 `chips` 的过滤维度重复表达），但**要带进详情页路由参数**（`categoryKey`）。

---

## 4. 侧边栏搜索框与浮层

### 4.1 几何与视觉（初始值，装机后实测校正）

| 项 | 值 | 依据 |
|---|---|---|
| 搜索框宽 | `100%`（= 侧边栏内缩后 240 − 2×16 = **208vp**） | 与截图一致（截图量得 ≈204vp）；`padding_level8` = 16vp |
| 搜索框高 | **40vp**（`brew_search_box_height`） | 与导航行 `side_bar_height` 同高，视觉上成一组 |
| 搜索框圆角 | `corner_radius_level4` | 截图是圆角矩形（不是胶囊） |
| 折叠态底色 | `sys.color.background_tertiary` | 截图的浅灰底 |
| 展开态底色 | `sys.color.background_primary`（白） | 截图 |
| 放大镜 | `sys.symbol.magnifyingglass` | `sys.symbol.*` 名字**只有写成 `$r()` 字面量才会被编译校验**（handover §10.6），必须实测 |
| 「搜索」文字 | `sys.color.font_emphasize`，`Body_M` | 截图的蓝字 |
| 左右分隔线 | 竖直 `Divider`，`sys.color.divider_*` | 截图 |
| 浮层面板宽 | **400vp**（`brew_search_panel_width`） | 截图量得面板 ≈ 搜索框 1.9 倍；**待实测** |
| 浮层内边距 | `padding_level8`（16vp） | 截图 |

> 「初始值 + 实测校正」是刻意的：项目方法论是「版面用 `ui layout` 量，不靠猜」（handover §8.5）。spec 给出起点与**判据**（面板/搜索框 = 1.9 ± 0.1），实现阶段用 `ui layout` 收口。

### 4.2 浮层挂载：`.bindPopup()`

| 方案 | 结论 |
|---|---|
| **`.bindPopup(builder)`** ✅ | popup 渲染在**窗口 overlay 层**，不受 `HdsSideBar` 侧边栏容器裁剪，才能像截图那样横向盖到内容区上方；点击外部/Esc 关闭、层级、焦点都由系统处理 |
| `.bindContentCover` / `.bindSheet` ❌ | 覆盖**整个窗口**（连侧边栏一起盖住），与截图不符 |
| 顶层 `Stack` + `position` 绝对定位 ❌ | 能超出侧边栏，但点击外部关闭、层级、焦点全要自己写，且要在 `PcMainPage` 里再造一套与侧边栏共享的状态 |

配置：`placement: Placement.BottomLeft`、`enableArrow: false`、`mask: false`、`popupColor: $r('sys.color.background_primary')`、`radius: corner_radius_level8`、`onWillDismiss` 收外部点击/Esc。

### 4.3 状态机

```
collapsed ──(聚焦/点击)──> focused + panelOpen
focused + panelOpen ──(点任一项 / 点「搜索」/ 回车 / 点外部 / Esc)──> focused + panelClosed
focused + panelClosed ──(失焦)──> collapsed（输入框内容保留）
```

- 输入框内容**不清空**（照截图：面板收起后框里还留着词）；
- `panelOpen` 与 `keyword` 都是 `BrewSideSearchBox` 自己的 `@State`；
- 面板里的「历史/发现」项点击 = 把词写进输入框 + **立即执行一次搜索** + 关浮层。

### 4.4 浮层内容（`BrewSearchSuggestions`）

| 区块 | 结构（上→下） |
|---|---|
| 搜索历史 | 标题 `搜索历史`（`Body_L`）+ 右侧 `trash`（清空）+ `chevron_up/down`（折叠）；下方 `Flex wrap` 胶囊 chips |
| 搜索发现 | 标题 `搜索发现` + 右侧 `arrow_clockwise`（换一批）；下方 **2 列 × 2 行**，每项 `magnifyingglass` + 文字，项间横线 |

> 结果页的「未提交态」显示的是**同一块内容**（§5.4）。所以只做**一个**组件 `BrewSearchSuggestions`，用 `@Prop large: boolean` 区分两处：浮层里 `false`（紧凑，标题 `Body_L`），结果页里 `true`（大字标题、内容区满宽）。
> 两份实现一定会漂移（项目为这类事故付过代价，handover §3.2），而两处内容本来就一模一样。

- 折叠历史：把 chips 行收起来（标题行保留），chevron 图标跟着换；
- 清空历史：**真删除并落盘**（`BrewSearchHistoryStore.clear()` 删 key）→ 显示空态（一行灰字「暂无搜索历史」）→ 重启后依然是空（§8）；
- 换一批：在**真实热门池**（本机目录前 40 名）内换出另外 4 条（§8）。池空（目录还没到）时该图标不渲染 —— 按下去没反应就是死交互。

---

## 5. 搜索态与页面栈

### 5.1 内容区切换（`PcMainPage`）

```
HdsSideBar.contentPanelBuilder
  └─ GridRow
       └─ GridCol
            └─ Stack
                 ├─ HomeView(currentIndex, isShown).visibility(searchActive ? Hidden : Visible)   ← 保活
                 └─ if (searchActive) BrewSearchHomeView()                                        ← 搜索态
```

用 `Stack` + `.visibility(Visibility.Hidden)` 而**不是 `if/else`**：`if` 分支切换会**销毁** `HomeView`，页签会重建（回到首页、丢滚动位置），G4 直接不成立。`Visibility.Hidden` 不占位但仍保留组件与其状态。

**状态归属（避免两个持有者）**：关键字由**搜索框自己**持有（`@State`，唯一的编辑者），跨页面的两条信号走 `AppStorage`（项目现有的跨页惯例，如 `CURRENT_TAB` / `BREW_*_PAGE_CONTEXT`）：

| 新增 `StorageKey` | 类型 | 谁写 | 谁读 |
|---|---|---|---|
| `BREW_SEARCH_ACTIVE` | `boolean` | 搜索框（输入/提交 → `true`）、`PcMainPage.sideBarChange`（切页签 → `false`）、结果页（栈底按返回 → `false`） | `PcMainPage`（`@StorageLink`，决定内容区渲染谁） |
| `BREW_SEARCH_KEYWORD` | `string` | 搜索框（**唯一的写者**，每次变更） | `PcMainPage`（转给壳）、`BrewSearchResultView`（`@StorageProp` + `@Watch` → `popToIndex(0)` + 重算） |

为什么不用回调/`@Link` 串下去：`CustomSideBar` 是 `HdsSideBar` 的 builder 参数、结果页是 `NavPathStack` 里的 `NavDestination`，**函数没法穿过路由参数**（handover §3.3：页面栈参数只传简单标识）。`AppStorage` 是这两层之间唯一现成的通道。

> **这是本方案唯一需要专门实测的风险点**（`HdsTabs` 在 `Hidden` 下是否仍触发 `onAttach`/重建）：装机后专门验一次「进搜索 → 返回 → Formulae 是否还在原来那页」。若不成立，退路是把它换成 `HdsTabs` 的第五个 `TabContent`（方案 B），届时按「隐藏页签」处理高亮。

### 5.2 页面栈

```
BrewSearchHomeView（壳，自持 StorageKey.BREW_SEARCH_PAGE_CONTEXT）
  └─ HdsNavigation(navPathStack)
       └─ BrewSearchResultView（栈底，关键字可为空）
            └─ push BREW_DETAIL_VIEW（现有详情页，零改动复用）
```

- 结果页 `id/token/kind/categoryKey/title` 全部由结果项带过去，凑齐 `BrewDetailParams`；
- **新关键字不 push 新页面**：结果页 `@StorageProp(BREW_SEARCH_KEYWORD) @Watch` 一响就 `popToIndex(0)` 再换数据 —— 否则连输会堆一叠结果页；
- 结果页上面可以叠着详情页：此时侧边栏改关键字，结果页的 `@Watch` 照样会响（`NavDestination` 在栈里仍存活），`popToIndex(0)` 把详情弹掉回结果页 —— 用户预期就是「看新结果」。

### 5.3 退出搜索态（三条路径，都置 `BREW_SEARCH_ACTIVE = false`）

| 路径 | 处理 |
|---|---|
| 结果页是栈底时按返回键 | `pathStack.getSize() > 1` → `pop()` 并 **return true**；否则置 `BREW_SEARCH_ACTIVE = false` 并 **return true**（见下面的坑） |
| 点侧边栏任意页签 | `sideBarChange` 里先置 `BREW_SEARCH_ACTIVE = false` 再切页签 |
| 搜索框内按 Esc / 点外部 → 只关浮层 | **不退出搜索态**（浮层 ≠ 搜索态） |

> ⚠️ **栈底的返回键必须自己吞掉（return true），不能 return false 让它冒泡**。冒泡会落到 `PcMainPage` 的 `HdsNavDestination.onBackPressed`，而它实现的是「再按一次退出应用」的 Toast（`PcMainPage.ets:53`）：用户想退出搜索，看到的是「再按一次退出」——编译过、不报错、没有日志，正是本项目记录的那类**静默行为错误**（handover §7.2）。

### 5.4 结果页的内容态

| 态 | 触发 | 内容 |
|---|---|---|
| 未提交态 | 输入框里的词还没被执行（`appliedKeyword` 为空，或与 `keyword` trim 后不一致） | 大版「搜索历史」（chips 换行）+ 大版「搜索发现」（2 列） |
| 有结果 | 命中数 > 0 | 标题栏主标题 = 关键字；「共 N 个结果」；chips；`List` + `LazyForEach` + `BrewPackageRow` |
| 无命中 | 命中数 = 0 且关键字非空 | 居中「没有找到相关包」+ 关键字回显 |

「降级提示条」不是第四个内容态，而是**叠在上面三个态之上**的一条：`BrewMetaSync.ready() === false` 时在内容区顶部多一行「本地索引未就绪，当前仅按包名匹配」（未提交态不显示）。

### 5.5 chips（过滤维度）

`全部 / Formulae / Casks` 三项，复用 `BrewChipBar`（挂在标题栏 `bottomBuilder`，与 Casks / MinePackages 一致）。切换 chips **不重新算**，只在已算好的结果集上按 `kind` 过滤（引擎一次算两个 kind，见 §6.3）。

---

## 6. 匹配与排序

### 6.1 输入与输出

```ts
// brewcommon/model/BrewSearchEngine.ets —— 纯函数，无状态、无网络、无 ArkUI
export class BrewSearchHit {
  public kind: BrewKind;
  public row: CatalogEntry;     // token + vol30d（tie-break 用）
  public desc: string;
  public score: number;
  public matchedBy: string;     // 'exact' | 'prefix' | 'word' | 'substr' | 'descHead' | 'desc'，只用于日志
}

export class BrewSearchEngine {
  public static rank(keyword: string, entries: BrewSearchEntry[]): BrewSearchHit[];
}

export class BrewSearchEntry {   // 引擎的输入行（避免引擎依赖 catalog 的形状）
  public kind: BrewKind;
  public token: string;
  public desc: string;
  public vol30d: number;
  public order: number;          // 目录里的原始下标 = 「目录已按 vol30d 降序」的现成 tie-break
}
```

### 6.2 打分表

归一化：`keyword.trim().toLowerCase()`（Homebrew token 全小写）。`k` = 归一化后的关键字，`t` = token。

| 命中方式 | 分 | 例（k=`node`） |
|---|---|---|
| `t === k` | **100** | `node` |
| `t.startsWith(k)` | **80 − min(10, t.length − k.length)** | `node@20` (80−2=78) |
| 词边界：`-` 分段中任一段 === k | **70** | `node-sass`… 段 `node` |
| `t.startsWith(k) === false` 且 `t.includes(k)` | **60** | `nodenv` |
| desc 任一词的词首 === k | **40** | `… Node.js runtime` |
| desc 含 `k` | **20** | `… comfortable…`(k=`com`) |

- 取**最高**的一档（一个条目只算一次分）；
- 前缀档的「长度惩罚」让短 token 排在长 token 前（`node` 先于 `node@20`）。惩罚**上限 10 分**的作用是把前缀档的下界钉在 70：
  - 前缀档**始终高于**子串档（≥70 > 60）；
  - 前缀档下界与词边界档同分（70），两者谁前由 §6.3 的 `vol30d` 决定 —— 这是有意的（`nodejs` 与 `node-sass` 之间该看热度，不该看匹配方式）。

### 6.3 排序与截断

1. `score` 降序；
2. `vol30d` 降序；
3. `order` 升序（目录原始下标 —— 目录本身已按 vol30d 降序，所以这是「同分同量」时的稳定次序）；
4. **`kind` 只在展示时过滤，不参与排序** → chips 切换不需要重算，且「全部」与单 kind 的前后相对顺序一致。

截断：算完全部命中，**只取前 `BREW_SEARCH_LIMIT = 50`** 条上屏；命中总数单独返回（用于「共 N 个结果」）。确定性：同一份输入必得同一份输出（与生成器「同输入同输出」的判据一致），所以 tie-break 里**不允许**出现 `Date.now()` / 随机。

### 6.4 取数与耗时

```ts
BrewSearchModel.search(keyword): Promise<BrewSearchResult>
  // 1) 两个 kind 各取一次：BrewService.searchRows(kind) + BrewMetaSync.descOf(kind)
  // 2) 目录行缺失时（无网 / 目录未就绪）回落到 Object.keys(descIndex)，vol30d = 0
  // 3) BrewSearchEngine.rank(keyword, entries)
  // 4) 日志：命中数 / 耗时 / Top5 token
```

| 场景 | 规模 | 预算 |
|---|---|---|
| 正常 | 2 × ~1.3 万行 = 2.6 万次「前缀 + 子串 + desc 扫描」 | **目标 < 50ms**（输入防抖 300ms 之内完成就不掉帧）；实测超预算再挪 `taskpool`，**不提前优化** |
| 降级 | 无目录、只有 desc 索引 | 同上（用 `Object.keys`） |

**为什么目录缺失还要回落**：`descIndex` 是落盘的、**离线可用**；只按目录做搜索会让「有索引但没目录」时整页空态，而那正是最该能用的时候。

### 6.5 输入触发（2026-09-24 修订：显式触发，无防抖）

搜索**只在显式触发时执行**：回车（`EnterKeyType.Search`）、点「搜索」、点历史/发现项。
输入框的 `onChange` 只更新 `keyword`，不触发搜索。原先自实现的 trailing debounce
（`setTimeout` + `clearTimeout`，`BREW_SEARCH_DEBOUNCE_MS = 300`）因此**已删除**：
不再有「一串没人确认过的关键字被拿去跑全量匹配」这件事，防抖没有防的对象；
也没有挂起的超时（少一个「旧结果后到盖掉新结果」的来源）。

页面用两个状态区分「输入」与「已生效」：`keyword` = 输入框内容，
`appliedKeyword` = 上一次真正执行的关键字；两者不一致时内容区显示历史/发现（§5.4）。

> 历史遗留：不用 common 的 `DebounceUtil`（它是全局单例时间戳的 leading 节流，语义与作用域
> 都不对）—— 此结论仍然成立，只是现在连自实现的防抖也不需要了。

---

## 7. 数据来源与降级

### 7.1 三条降级路径

| 触发 | 行为 | 判据 |
|---|---|---|
| 索引未就绪（`ready() === false`） | 仍按 token 匹配（`desc = ''`），顶部提示条 | 结果页可见提示条；日志 `index pending` |
| 目录缺失（无网 / `SNAPSHOT`） | 回落 `Object.keys(descIndex)`，`vol30d = 0` | 日志 `rows from index only, n=…` |
| 索引与目录都缺（首次安装 + 断网） | 空态 + 提示条（**不报错**：这不是失败态） | 无命中 + 提示条 |

### 7.2 缓存

**不做任何结果缓存**：索引与目录本身已在内存，匹配是纯计算（毫秒级）。缓存只会引入「数据变了但结果不变」这类问题（Discover 吃过 Preference 缓存的亏，handover §13.7）。

---

## 8. 历史与发现的数据（2026-09-24 修订：改成真实数据）

**需求方口径（修订后）**：历史与发现都用真数据，宁可为空也不摆假词。

### 8.1 搜索历史

- **来源**：用户**真正执行过的搜索**（`BrewSearchResultView.apply()` → `BrewSearchVM.recordSearch()`），
  也就是回车 / 点「搜索」/ 点历史项 / 点发现项这四条路；打字本身不记（半截词 `nod` 不该进历史）。
- **规则**：trim → 忽略空串 → **大小写不敏感**去重（保留最新写法）→ 置顶 → 上限 10 条（`BREW_SEARCH_HISTORY_LIMIT`）。
  **0 结果也记**：历史是「我用过的词」，不是「搜到过东西的词」。
- **落盘**：`BrewSearchHistoryStore`（整个项目只有它读写 `brew_search_history`），走 `PreferenceManager`，
  与目录/索引/现网缓存同一套机制。清空 = **删 key**（不是写空数组），重启后依然是空。
- **为什么首次访问才读盘**：`PreferenceManager` 依赖 `AppStorage` 里的 `UIContext`，而 `BrewSearchVM` 是单例，
  构造时机不由我们挑；读到坏数据/读不到都返回空数组，**不抛错**（历史丢了不该让搜索页变错误态）。

### 8.2 搜索发现

- **来源**：设备端目录的真实热门 —— `BrewSearchModel.hotTokens(40)`：
  `formula` 与 `cask` 的目录行（各自已按近 30 天安装量降序）双指针归并，取前 40 个 token。
- **同步、零请求**：目录在内存里（首次访问从 Preference 读一次）。**不为它拉网络** ——
  聚合端点探针实测最长 17.4s，而发现区是搜索页的默认内容，拉网络等于让搜索页先转十几秒圈。
- **定序确定**：同量时 formula 优先（`CatalogEntry` 上没有 kind，用 `sort` 合并会依赖 sort 的稳定性）。
  同名 token（formula 与 cask 都有）只留一条 —— `ForEach` 的 key 就是词，重复 key 是运行期问题。
- **展示与交互**：一次 4 条（`BREW_SEARCH_DISCOVERY_COUNT`，2×2），「换一批」在池内 +4 取模轮换；
  点任一项 = 用该 token 执行一次搜索（真包，必出结果，同时进历史）。
- **池为空时**（首次安装 / 断网且盘上没目录）：发现区显示「暂无推荐」，
  **不回落写死的词** —— 原先那批词（`WPS Office` / `微信` / …）在 Homebrew 目录里一个都不存在，
  点下去必然是空结果，比空着更糟。
- **缓存口径**：池只在**非空**时缓存（`BrewSearchVM.hotPoolCache`）。缓存空值会让「目录后来到了」永远是空态。

### 8.3 已删除的写死数据（留档）

```ts
// 2026-09-24 之前的样子（本项目已无此代码）
export const BREW_SEARCH_HISTORY: string[] = ['qoder', '元宝', 'qq邮箱', '哔哩哔哩'];
export const BREW_SEARCH_DISCOVERY_POOL: string[] = [
  'WPS Office', '爱奇艺', '微信', '小红书',
  'QQ', '钉钉', '腾讯会议', '高德地图',
];
```

它们是「照抄截图原词」的产物（当时的非目标之一），本轮全部删除：
`qoder` / `元宝` / `qq邮箱` / `哔哩哔哩` 与发现池那 8 个词在 Homebrew 目录里**一个都不存在**，
点下去必然空结果，是「看着像功能、其实必然失败」的典型。

---

## 9. 文案与 i18n

| 键 | zh_CN | en_US |
|---|---|---|
| `brew_search_placeholder`（**已有键**，zh 值由「搜索软件包」**改为「搜索内容」**照截图） | 搜索内容 | Search packages |
| `brew_search_action` | 搜索 | Search |
| `brew_search_history` | 搜索历史 | Search history |
| `brew_search_discovery` | 搜索发现 | Discover |
| `brew_search_title` | 搜索 | Search |
| `brew_search_empty_history` | 暂无搜索历史 | No search history |
| `brew_search_no_result` | 没有找到相关包 | No packages found |
| `brew_search_result_count` | 共 %d 个结果 | %d results |
| `brew_search_index_pending` | 本地索引未就绪，当前仅按包名匹配 | Local index not ready — matching by name only |
| `brew_search_filter_all` | 全部 | All |
| `brew_search_filter_formula` | Formulae | Formulae |
| `brew_search_filter_cask` | Casks | Casks |

- 三份 `string.json`（`base` = 英文，`zh_CN`，`en_US`），与现有 brew 文案同风格；
- 共 **11 条新键**（Task 4 已落地）。**没有「清空」「换一批」的文字键**：浮层里这两处是纯图标
  （垃圾桶 / 循环箭头），加文字键会变成定义了却没人用的死文案 —— 本项目为此专门有清单（handover §8.3）；

- **删除 `brew_search_coming_soon`**：搜索落地后它才成为真死代码（handover §8.3 把它归为「预备未用」，因为当时还有对应待办）。

---

## 10. 改动清单（现有文件，逐条）

| # | 文件 | 改动 |
|---|---|---|
| 1 | `build-profile.json5` | `modules[]` 加 `{ name: 'brewsearch', srcPath: './features/brewsearch' }` |
| 2 | `products/pc/oh-package.json5` | 依赖加 `@ohos/brewsearch` |
| 3 | `products/pc/.../component/CustomSideBar.ets` | 标题行与 `ForEach` 之间插入 `BrewSideSearchBox`；`sideBarChange` 里先置 `BREW_SEARCH_ACTIVE = false`（并用 `@StorageProp` 读到它，用于浮层关闭） |
| 4 | `products/pc/.../page/PcMainPage.ets` | 内容区改 `Stack`（保活 + 搜索态）；`@StorageLink(BREW_SEARCH_ACTIVE)`；把 `BREW_SEARCH_KEYWORD` 转给壳 |
| 5 | `common/.../model/PageEnum.ets` | 加 `BREW_SEARCH_RESULT_VIEW = 'BrewSearchResultView'` |
| 6 | `common/.../constant/CommonEnums.ets` | 加三个键：`BREW_SEARCH_PAGE_CONTEXT`、`BREW_SEARCH_ACTIVE`、`BREW_SEARCH_KEYWORD` |
| 7 | `features/brewcommon/src/main/ets/service/BrewService.ets` | 加 `public searchRows(kind)` |
| 8 | `features/brewcommon/src/main/ets/service/BrewBrowseBuilder.ets` | `formulaItem` / `caskItem`：`private static` → `public static`（只改可见性） |
| 9 | `features/brewcommon/src/main/ets/component/BrewPackageRow.ets` | 加 `@Prop hideRank: boolean = false`（默认保持现状） |
| 10 | `features/brewcommon/src/main/ets/model/BrewRepository.ets` | 加 `BrewSearchModel`（单例 + `search()`） |
| 11 | `features/brewcommon/src/main/ets/model/BrewSearchEngine.ets` | **新增**（纯函数，零 import） |
| 11b | `features/brewcommon/src/main/ets/constant/BrewConstants.ets` | 加 `BREW_SEARCH_LIMIT = 50`（`BrewSearchModel` 在 brewcommon 里用它截断，放 brewsearch 会成环） |
| 11c | `hmosword-build/brew-search/check_engine.mjs` | **新增**：引擎的可执行检查（Node 把 `.ets` 原样复制成 `.mts` 后 import） |
| 12 | `features/brewcommon/Index.ets` | 导出 `BrewSearchEngine` / `BrewSearchHit` / `BrewSearchEntry` / `BrewSearchModel` / `BrewSearchResult` |
| 13 | `features/brewcommon/src/main/resources/{base,zh_CN,en_US}/element/string.json` | 删 `brew_search_coming_soon` |
| 14 | `features/brewsearch/**` | **新增模块**（§3.2：含 `BrewSearchSuggestions` / `BrewSearchRowSource` / `constant/BrewSearchConstants.ets`） |
| 15 | `docs/brew-handover.md` | §8.2 划掉搜索；§3.1 模块表加 `brewsearch`；§3.3 路由加一条；§6 加「搜索」小节 |
| 16 | `docs/brew-marketplace-content-plan.md` | §13「本轮不实现」→「已实现，见 spec」；§12 文案表删「搜索入口」行 |
| 17 | `docs/brew-api-design.md` | 加搜索小节（引擎口径、三处新增公开入口、降级路径） |

---

## 11. 边界与错误处理

| 边界 | 行为 |
|---|---|
| 空串 / 纯空格 | 保持「未提交态」；回车 / 点「搜索」也不会跑匹配、不写历史 |
| 大小写混输 | 归一化后匹配（`RipGrep` → `ripgrep`）；历史按**大小写不敏感**去重（保留最新写法） |
| 超长输入 | 不做特殊处理；`TextInput` 自身限制足够，前缀/子串匹配对长度不敏感 |
| 打字（`n`→`no`→`nod`→`node`） | **一次都不搜**：只有回车 / 点「搜索」才执行；中间态不进历史（`apply` 是唯一的写入点） |
| 索引/目录大而全 | 只取前 50 条上屏，命中总数照实报 |
| 搜索态下按返回键，栈里叠了详情页 | 先 `pop()`，不退搜索态（层级正确） |
| 搜索态下点侧边栏页签 | 退出搜索态 + 切页签（侧边栏是唯一「离开」的手势，必须响应） |
| 快速连点结果行 | 详情页自身已有 `backPressed` 防重入（handover §10.4.1 的教训），此处不重复处理 |
| 浮层打开时切页签 | 浮层先关（`panelOpen = false`），避免浮层挂在已经被替换的内容区上 |
| 未提交态与「清空历史」叠加 | 显示「暂无搜索历史」，发现区照常；发现池空（目录没到）时显示「暂无推荐」 |

---

## 12. 测试与验证

### 12.1 我会执行的（都是真机证据）

| # | 命令 / 动作 | 判据 |
|---|---|---|
| V1 | `devecocli build` | `BUILD SUCCESSFUL` |
| V2 | `strings products/pc/build/.../ets/modules.abc \| grep -c BrewSearchResultView` | **> 0**（`grep` **不加** `^…$` 锚点，handover §9.5.1） |
| V3 | 数 `router_map.json` 条数 | 24 → **25** |
| V4 | `devecocli run --device 127.0.0.1:42021` | 装机 + 启动成功 |
| V5 | `devecocli log --crash --from 5m` | 无崩溃 |
| V6 | `devecocli log --keyword BrewSearch --from 5m` | 见 `[BrewSearch]` 命中数/耗时/Top5 行 |
| V7 | **§5.1 的保活专项**：进搜索 → 返回 → 看 Formulae 是否还在原页 | 页签未被重置 |
| V8 | `devecocli ui layout --mode full` | 量搜索框高/宽、面板宽；与判据比对（面板/搜索框 = 1.9 ± 0.1） |

### 12.2 我不会声称的（诚实边界）

- **hypium 单测**：`devecocli` 无 test 命令，本机跑不起来。照 `brewcommon/src/ohosTest` 先例补一条 `BrewSearchEngine.test.ets`（需求方在 DevEco Studio 里能跑），但**它不计入我的验证证据**，报告里标「未在本机执行」。
- 因此引擎的正确性由**真机日志**（V6 的 Top5 token 是否合理）+ 需求方手动测试覆盖，而不是「跑过测试」这种说法。

### 12.3 需求方的验收步骤

1. 启动后点侧边栏搜索框 → 框变白 + 右侧出现「搜索」→ 浮层弹出（历史 4 chips + 发现 2×2）；
2. 点历史 chip → 框内回填 → 浮层收起 → 内容区出现结果页（空态见「没有找到相关包」提示，§8 的预期）；
3. 手动输入 `git` / `node` / `wget` → 边输边出结果（300ms 防抖）→ 点一行进详情页 → 返回键回到结果页；
4. 点 chips 切 Formulae / Casks → 结果按 kind 过滤、顺序与「全部」一致；
5. 结果页在栈底时按返回键（或用顶部返回）→ 回到**原来的页签**，且页签停在原来那一页；
6. 点侧边栏任意页签 → 同样退出搜索态；
7. 点垃圾桶清空历史 / 点「换一批」→ 发现项轮换；
8. 全程无崩溃（`devecocli log --crash`）。

---

## 13. 验收标准

| # | 标准 |
|---|---|
| A1 | 搜索框与浮层的**结构与截图一致**（折叠/展开两态、历史 chips、发现 2×2、两个右上角图标） |
| A2 | 真机可搜：`git`/`node`/`wget` 等常见 token 能出结果且排序合理（全等 > 前缀 > 子串 > desc） |
| A3 | 结果行可点进详情页并正确返回 |
| A4 | chips 过滤正确，且过滤前后相对顺序不变 |
| A5 | 退出搜索回到原页签且**页签状态未丢** |
| A6 | 无网/索引未就绪时**不崩、不白屏**，有明确降级提示 |
| A7 | `docs/` 三份文档已同步（§10 的 15~17 条） |
| A8 | 交付时附：构建日志、路由条数、`[BrewSearch]` 日志片段、`ui layout` 量出的几何 |

---

## 14. 已知取舍与后续

| 取舍 | 代价 | 后续 |
|---|---|---|
| 历史/发现写死 | 点下去空结果的观感（§8） | handover §8.2「发现取真实热门」 |
| 历史不落盘 | 重启即还原 | 接 `PreferenceManager` 即可（一行 setValue） |
| 只出前 50 条 | 极宽泛的词（如 `lib`）看不到全量 | 加「加载更多」或分页 |
| 无联想/纠错 | 输错一个字就空态 | 需要服务端或词表 |
| 结果页无第二个输入框 | 与 AppGallery 的细节差异 | 需求方要求再加（要一套双向同步状态） |
| 名次槽在结果页关闭 | 少一个信息位 | 若要显示，应显示**全局**安装量排名而非分类内排名 |
| 引擎在主线程 | 极端 qps 下可能掉帧 | 真实测出问题再挪 `taskpool`（§6.4） |

---

## 追加（2026-09-22，口径变更 R16）：搜索改为**页签形态**

### 变更原因（真机实测，两条都是阻断性缺陷）

1. **P0 崩溃**：`BrewSearchResultView.ets:94:56` 报 `undefined is not callable`。
   列号逐字符核对定位到 `this.pathStack.size()` —— **`NavDestinationContext` 交给页面的
   那个 `NavPathStack` 上 `size` 不是函数**（SDK `navigation.d.ts:1642` 明确声明了
   `size(): number`，所以编译期放行、只在运行期炸）。
   工作路径是 `PageContext` 持有的栈（`BaseHomeViewModel.ets:142` 已在跑它的 `size()`）。
2. **浮层拉起后输入框丢焦**：`bindPopup` 的 `focusable: true` 让浮层成为**焦点作用域**，
   显示时把焦点从输入框拿走，此后从作用域外 `focusControl.requestFocus` **抢不回来**
   （实测「延后一帧回焦」无效）→ 面板开着打字没反应。

### 新形态（本 spec 的 UI 章节以此为准）

| 项 | 口径 |
| --- | --- |
| 入口 | 侧边栏新增「搜索」页签，位置在 **CASKS 与 MINE 之间**；**不再有侧边栏搜索框** |
| 页签枚举 | `TabBarType.BREW_SEARCH = 7`（**追加末尾**）；`TAB_CONTENT_STATUSES` 同步补第 8 项（该数组按下标取） |
| 页签内容 | `BrewSearchHomeView`（与 `BrewDiscoverHomeView` 同构的壳）→ 压栈 `BrewSearchResultView` 作为**栈底页**；路由保留 |
| 输入框 | `BrewSearchBar`，挂在搜索页**标题栏的 `bottomBuilder`**（chips 之上）→ 常驻顶部不随结果滚动 |
| 页内切换 | 关键字为空 → 历史 + 发现；有字 → 结果列表 |
| 关键字 | **页面自持**（`@State keyword`）。删除 `BREW_SEARCH_ACTIVE` / `BREW_SEARCH_KEYWORD` 两个共享键 |
| 返回键 | 栈顶有详情页 → 弹它；有字 → 清空回到历史/发现并吞掉；都没有 → **不吞**，交回 `PcMainPage`（与其它页签一致） |
| 删除 | `BrewSideSearchBox`（含浮层与回焦兜底）、`brew_search_panel_width`、`PcMainPage` 保活、`CustomSideBar` 改动 |

### 版式口径（真机 `ui layout` 实测，density 1.9）

- 全页统一左右内缩 = `contentInset()`（sm 8 / md 12 / lg 16 vp… 实测该窗口为 lg 档 → 24vp = 45px），
  输入框盒、chips 首项、分区标题、发现项**同在一条竖线**上。
- **内缩必须写在父级 `padding` 上**：`width('100%')` 的元素再加 `margin` 会溢出而不是内缩；
  只包输入框行、不包 chips（`BrewChipBar` 自带 `barPadding()`，再套一层就是双份）。
- 标题栏底区高度 = `BREW_SEARCH_BAR_ROW_HEIGHT`(48) + `BREW_CHIP_BAR_HEIGHT`(56) = 104vp，
  与 `topInset()` 同源（差一个数就会出现「输入框盖住 chips」或「上方多一条空白」）。
  模糊区间不受影响：`brewBlurScrollEffect` 用的是固定 `BREW_TITLEBAR_BLUR_RAMP`（start=0）。
- 分区标题字号 `Subtitle_L`、标题行高 40vp（不复用 48vp 的可点行高）、分区之间 16vp。
