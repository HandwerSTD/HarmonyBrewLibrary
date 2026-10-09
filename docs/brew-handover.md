# Homebrew 应用市场改造 · 交接说明

> 这份文档是**入口**：告诉接手的人"东西在哪、怎么跑、为什么这么做、还剩什么"。
> 细节不在这里重复，按下面的分工去查对应文档。

## 0. 文档分工

| 文档 | 管什么 |
|---|---|
| **本文 `brew-handover.md`** | 交接入口：代码地图、怎么跑、决策索引、踩坑索引、待办 |
| `brew-marketplace-content-plan.md` | **产品/内容口径**：侧边栏结构、分类体系、各页内容规划、素材策略 |
| `brew-api-design.md` | **实现与验证**：端点设计、模块内部结构、`§9` 验证方法、`§10` 踩坑、`§11` 待办、`§12` 我的页、`§13` Discover |
| `brew-discover-algo.md` | **Discover 推荐算法（现网口径，唯一权威）**；`hmosword-build/brew-mockgen/check_algo.py` 是它的可执行形式 |
| `hds-titlebar-blur.md` | **HDS 标题栏模糊的通用指南**（不限于 brew）：模糊类型/材质/区间、逐场景正确用法、让位三写法对照、踩坑清单、验证方法 |
| **`brew-catalog-fullsync-spec.md`** | **待评审的 spec + plan**：去掉「浏览集前 100」硬裁切 —— 启动后**后台同步全量元数据**（`formula.json`/`cask.json`，gzip 5.29/2.05 MB，2 次请求）抽 `token → desc`，让分类不再依赖逐条现拉，列表随现网自动同步（无需发版）。**前提：只针对 `pc`（2in1），假定常驻 WLAN → 不做任何流量控制；性能（内存/耗时/帧率）不简化**，也不做分页（改为全量列表 + `LazyForEach` 虚拟滚动） |

五份文档有明确边界：**算法口径只在 `brew-discover-algo.md`**，
**版式归 `content-plan`**，**实现细节与踩坑归 `brew-api-design.md`**，
**标题栏模糊（含非 brew 页）归 `hds-titlebar-blur.md`**。
改任何一处时留意其余几处有没有需要同步的表述（这一点已经踩过坑，见 §5）。

---

## 1. 背景与交付状态

把 HarmonyOS 样例工程 `sample_in_harmonyos` 改造成**基于 Homebrew 生态的应用市场**：
侧边栏新增 Discover / Formulae / Casks / Mine 四个入口（前三者联网探索、Mine 读本机软件包）。

**只跑 PC**（`deviceTypes: ["2in1"]`）。原有【组件 / 样例 / 实践】三个入口**保留作对照**，
开发收尾时置 `LEGACY_TABS_ENABLED = false` 下线（见 §8）。

| 页面 | 状态 |
|---|---|
| **Formulae** | ✅ 完成：8 张分类卡（卡内预览 5 条）+ 「查看全部」分类二级页 + 详情 |
| **Casks** | ✅ 完成：同 Formulae 的两层形态（分类卡 + 分类二级页）+ 详情 |
| **Mine** | ✅ 完成：账号 / 调研 / 公告 / 已安装 / 待更新 / 已更新 / 设置 |
| **包详情页** | ✅ 完成：formula / cask 共用路由，11 个分区 |
| **Discover** | ✅ 完成：5 张单 App 大图卡 + 6 张榜卡（2 栏瀑布流）+ 榜单二级页 |
| 搜索 | ✅ 完成：本地全量索引匹配 + 结果页 + 历史/发现（`features/brewsearch`）。**2026-09-24 修订**：历史 = 用户真搜过的词（落盘）、发现 = 设备端目录真实热门、搜索改显式触发（回车 / 点「搜索」） |

**当前分支 `dev`（HEAD `87c8e0c`），从未推送到远端**（`origin/dev` 不存在；
上游官方仓库是 `gitcode.com/HarmonyOS_Samples/sample_in_harmonyos`，按约定不推）。

---

## 2. 怎么跑起来

### 2.1 环境

| 项 | 值 |
|---|---|
| 真机 | `HUAWEI MateBook Pro` / `127.0.0.1:42021` / 2in1 |
| 构建 | `devecocli build --product default`（出 `pc_acl`）/ `devecocli build --product pc_normal`（出 `pc_normal`）；产物日志习惯放 `.brewgen/build*.log` |
| 装机+启动 | `devecocli run --device 127.0.0.1:42021` |
| 崩溃日志 | `devecocli log --device 127.0.0.1:42021 --crash --from 5m --tail 30` |
| 看版面 | `devecocli ui layout --device <id> --window <windowId>` |
| 看画面 | `devecocli ui screenshot --device <id> --path <png>`（**截图可以用 read 工具直接看**） |
| 窗口列表 | `devecocli ui window list --device <id>` |

设备**有时会掉线**（`device list` 报 "No active devices"），等它恢复即可；
`ui layout` 偶发返回 `[0,0,0,0]`（窗口最小化/未渲染），此时先让 App 到前台或改用截图。
**`ui click` 用的是屏幕坐标**：窗口不在前台时点击会被别的窗口吃掉，App 里什么都不会发生、
也不报错 —— 所以「点了没反应」先确认前台（`ui window list` 看 `Focused`、或看 `ui layout` 是不是 `[0,0,0,0]`），
否则会把「点歪了」当成「控件点不动」（本人据此误判过「我的-本机包」的 chips，见 §7.3）。

### 2.2 改数据后必须做的两件事

```bash
# 1) 校验策展清单（会联网拉 formulae.brew.sh；命中 .brewgen/cache 时零请求）
python3 hmosword-build/brew-mockgen/generate.py          # 结构校验 + 逐个 token 问上游
python3 hmosword-build/brew-mockgen/generate.py --refresh # 忽略缓存，全量重拉
python3 hmosword-build/brew-mockgen/generate.py --local   # 只做结构校验，完全不联网

# 2) 榜单算法不变量
python3 hmosword-build/brew-mockgen/check_algo.py --fetch --data .brewgen/analytics
```

> 2026-10 起**没有「重新产出数据」这一步**：应用不内置任何 brew 数据快照，
> 数据只来自设备端目录（聚合端点）与现网单条（见 §4.1）。`generate.py` 已从
> 「生成 4 份 JSON」收敛为「校验 `tokens.json` 策展清单」，`check_types.py` 随 mock 一并删除。

### 2.3 每轮必查的两项（`BUILD SUCCESSFUL` 不够）

```bash
# ① 符号是否真进了字节码
ABC=products/pc_acl/build/default/intermediates/loader_out/default/ets/modules.abc
strings "$ABC" | grep -c BrewDiscoverHomeView      # 应为正数
# 注意：**不要加 ^...$ 锚点** —— 加了连早就跑通的符号也会是 0（踩过，见 §9.5.1）

# ② HAR 的 routerMap 是否合并进了 HAP
python3 -c "import json;print(len(json.load(open('products/pc_acl/build/default/intermediates/router_map/default/router_map.json'))['routerMap']))"
# 当前 24 条；不能用"各模块 router_map 条数相加"替代
```

**验证纯图标控件（圆钮、只有 `SymbolGlyph` 的按钮）必须用 `ui layout --mode full`** ——
默认的 simplified 模式不列"没有文字的 Button"（踩过，见 §9.5.1）。

---

## 3. 代码地图

### 3.1 模块（`build-profile.json5` 的 `modules[]`，共 13 个 + 2 个 product）

| 模块 | 性质 | 职责 |
|---|---|---|
| `products/pc_acl` `products/pc_normal` | 两个 entry 模块 | 各只保留四个文件：`pcability/PcAbility.ets`、`page/SplashPage.ets`、`page/PcMainPage.ets`、`pcbackupability/PcBackupAbility.ets`。**2026-10 起 entry 一分为二**：product `default` 出 `pc_acl`（申请 `CUSTOM_SANDBOX` 与 `READ_WRITE_USER_FILE`，`PcAbility` 注入 `BREW_CLI_ENABLED = true`，「我的」页展示本机包三块）；product `pc_normal` 出 `pc_normal`（不申请这两个权限，注入 `BREW_CLI_ENABLED = false`，「我的」页不展示本机包入口，取数静默返回空集合） |
| `pcui` | **新增** | PC 业务 UI：`HomeView` / `PcMainPage` / `PcSplashPage` / `CustomSideBar`、`TabBarModel` / `SplashModel` / `SplashView` / `SplashViewModel`、`BaseAbilityHelper`、`InitCenter` / `ContextConfig` 与 PC 相关资源 |
| `common` | 原有 | Preference / 路由 / 账号 / 事件。**2026-10 起不再有请求层**（`MockRequest` / `TriggerEnums` 已删） |
| `commonbusiness` | 原有 | `BaseHomeView` / `BaseHomeViewModel`（模糊标题栏、section、返回键都在这里） |
| `mine` | 原有 | 「我的」页。**就地改造** |
| `brewcommon` | **新增** | Homebrew 共享层：模型 / 常量 / 服务 / 仓库 / **共享 UI 原子**。多源与按源缓存按其职责拆成：`constant/BrewSourceConstants.ets`、`model/BrewSourceModels.ets`、`service/BrewSourceUrl|Store|Prefs|Probe|Restart|CacheEpoch|CacheAdmin|Diagnostics.ets`、`util/objkeys.ts`（见 `brew-api-design.md` §7.5.1） |
| `brewformulae` | **新增** | Formulae 页签 |
| `brewcasks` | **新增** | Casks 页签 |
| `brewdetail` | **新增** | 包详情页（formula / cask 共用路由） |
| `brewdiscover` | **新增** | Discover 页签 + 榜单二级页 |

卡片链路已从工程移除：两个 entry 的 `module.json5` 都没有 `extensionAbilities`，工程内没有 `form_config.json`、`pcformability` 与 `widget/pages` 目录。

新增模块的规模（`src/main/ets` 下的 `.ets`）：

| 模块 | 文件 | 行数 |
|---|---|---|
| `brewcommon` | 12 | 2057 |
| `brewdiscover` | 15 | 1803 |
| `brewformulae` | 8 | 739 |
| `brewdetail` | 6 | 728 |
| `brewcasks` | 7 | 712 |

**新建模块必须照抄一份模块级 `.gitignore`（首行 `/oh_modules`）** ——
漏了会把依赖符号链接 `git add` 进来（`brewdiscover` 踩过）。

### 3.2 `brewcommon` 为什么连 UI 也放

它是"共享层"而不是纯数据模块。理由：① 避免页签之间互相依赖（否则 `brewcasks` 要依赖
`brewformulae` 才能复用行组件，依赖方向没有语义）；② 避免复制漂移。
共享 UI 原子：`BrewMonogram` / `BrewPackageRow` / `BrewLocalPackageRow` / `BrewChipBar` /
`BrewFormat` / `brewPageContentLeft|Right` / `brewTitleBarTotalHeight`。
详见 `brew-api-design.md` §10.1。

### 3.3 路由与页面栈

- 每个页签模块**自己持有一个 `PageContext`**（`StorageKey.BREW_*_PAGE_CONTEXT`）。
  **不要共用** —— 共用会让两个页签的页面栈串起来。
- 二级页（详情 / 榜单列表 / 本机包列表）通过 `routerMap` 注册；HAR 的 `routerMap`
  本身就是编译入口（`brewdetail` 没有任何模块 import 它，但页面确实被编进了字节码，见 §9.2.1）。
- 页面栈参数只传**简单标识**（`BrewDetailParams` / `BrewDiscoverBoardParams`），
  页面自己去仓库取数据（已命中缓存）。

---

## 4. 数据层

### 4.1 mock 数据（`common/src/main/resources/rawfile/mockdata/`）

> **2026-10：整个目录已删除，连同整条 Mock 请求链路**（`common/constant/TriggerEnums.ets`、
> `common/storagemanager/MockRequest.ets`、两处导出）。应用不再内置任何 brew 数据，
> 数据只来自**设备端目录（聚合端点）**与**现网单条**。下面的表保留为历史记录（~~删除线~~ = 已删）。

| 文件 | 内容 |
|---|---|
| ~~`brew-formula-page.json` / `brew-cask-page.json`~~ | **已删除（2026-09 C 档）**。首页分类卡改由设备端用**目录 + 词表**现算（`BrewBrowseBuilder` + `BrewTaxonomy`），成员不再锁死在内置 240 个包里。**代价：无网时两个页签是空态（没有回落快照）** |
| ~~`brew-formula-details.json` / `brew-cask-details.json`~~ | **已删除（2026-09）**。详情页骨架改为从**首页条目的那 14 个字段**合成（`BrewApiMapper.formulaBaseOf` / `caskBaseOf`），其余字段全部由现网单条覆盖。删掉的是 **443.6 KB**，代价是现网失败时详情页降级（只剩骨架字段，其余段落不渲染） |
| ~~`brew-formula-banner.json` / `brew-cask-banner.json`~~ | **已删除（2026-09）**。两个端点从来没有 UI 调用点（两个首页的 `bannerHeight` 被固定为 0，Homebrew 也没有横幅素材），属死路径 |
| ~~`brew-discover-page.json`~~ | **已删除（2026-10）**。它是 Discover 的**回落快照**：目录拿不到时当成员用，目录可用时被目录成员覆盖。回落一并删掉后，六张榜的**骨架改为代码构造**（`BrewRepository.emptyDiscoverPage`，`id = sequence = 1..6` 与旧快照逐字一致，二级页路由不受影响），成员唯一来源 = 设备端目录；目录拿不到 → **空榜**（`loadDiscover` 过滤空榜后页面走空态）。榜算法口径的权威实现在 `check_algo.py` + `brew-discover-algo.md` |
| ~~`brew-local-formulae.json` / `brew-local-casks.json` / `brew-local-outdated.json`~~ | **已删除（2026-10）**。这三份内置 mock 随快照链路一并删除。本机包现在的数据源是设备上的 brew 命令（`BrewInstalledLoader`：`brew info --json=v2 --installed`），`MinePackagesUtil.loadSets()` 从「返回空集」改为转调它；签名与全部 UI 结构未变 |
| ~~`brew-local-overview.json` / `brew-local-taps.json` / `brew-local-services.json`~~ | **已删除（2026-09）**。`BrewLocalModel.getOverview/getTaps/getServices` 在 UI 侧**没有任何调用点**，整条链路（Repository → Service → rawfile）一并删除，`TriggerEnums.BREW_LOCAL_OVERVIEW/_TAPS/_SERVICES` 同时移除；`generate.py` 也已停止产出 |
| ~~`intent-framework-pages-list.json`（含 2in1/phone/tablet 三份）~~、~~`vision-sample-list.json`~~、~~`wearable-sample-list.json`~~ | **已删除（2026-09）**。`TriggerEnums.INTENT_FRAMEWORK_PAGE_LIST` / `VERSION_SAMPLE_TRIGGER` / `WEARABLE_SAMPLE_TRIGGER` 从未被任何代码引用（也无 insightIntent 声明），`rawfile/{main_pages_list,router_config,insight_intent_page_type}.json` 与 `pcui/rawfile/InsightIntentDecoratorJSON.json` 同批删除 |
| ~~`phone/**`、`tablet/**`~~ | **已删除（2026-09）**。两个 entry 模块（`products/pc_acl` / `products/pc_normal`）的 `deviceTypes` 只有 `2in1`，而 `MockRequest` 只拼 `mockdata/<deviceType>/<trigger>.json`（无回落）—— 这两个目录永远不会被解析。仅保留 `2in1/sample-*.json` 与 `2in1/new-contents.json` |

规模：brew mock **已于 2026-10 归零**（最后 4 个文件、约 44 KB 同批删除，整个 `rawfile/` 目录已不存在）。
前一轮（2026-09）先删除 **21 个 mock 文件、约 786 KB**（intent / 设备目录 / 本地状态三类），
并同步移除了 `TriggerEnums` 里 17 个无调用点的成员与 `BrewService` 的 8 个死方法；
本轮再删除最后 4 个 brew 文件，并删掉 `TriggerEnums` / `MockRequest` 两个文件本身
（brew 是它们的唯一调用方）与 `BrewDataMode` / `BREW_DATA_MODE` / `BREW_CATALOG_MEMBERSHIP` 三个开关。
分类体系（8+8）与词表在代码里（`BrewTaxonomy.ets`，由 `gen_taxonomy.py` 从 `lexicon.json` / `tokens.json` 生成；
`categories.json` 是分类定义）。

**所有 brew 端点的口径统一在 `brewcommon/service/BrewService.ets`**，读的是**真实网络**（`BrewHttp`）
而不是 trigger 名；`TriggerEnums` 这层间接已经不存在了。

### 4.2 生成器（`hmosword-build/brew-mockgen/`）

| 文件 | 作用 |
|---|---|
| `generate.py` | **已停产（2026-10）**，现在只做**策展清单校验**（结构合法 + 逐个 token 问上游是否还在，退出码 0/1），不再产出任何文件。`fetch()` 为它供数（落 `.brewgen/cache`）。保留 `classify()` / `subject_terms()` / `form_bucket()` 等作为分类口径的**参考实现** —— `eval_lexicon.py` 直接 import 它们，设备端 `BrewTaxonomy.ets` 也必须与它们一致 |
| `tokens.json` | **策展清单**：`token -> 分类 key`（override 层）。含 `_discover_*` 溯源键 |
| `categories.json` | 17 个分类定义（9 formula + 8 cask），含 symbol 映射。改分类要同时改 `BrewConstants` 的三张表 + 双语字串 + `BrewBrowseBuilder.CATEGORY_EN`（漏了最后一张 → 卡片英文名会显示成 key；`gen_taxonomy.py --check` 现在会报） |
| `lexicon.json` | **分类主路径**（2026-09 起）：`<kind>` 关键词 + `_subjects` 主题词；改完跑 `gen_taxonomy.py` 重生成 `.ets`，跑 `eval_lexicon.py` 看兜底率 |
| ~~`check_types.py`~~ | **已删除（2026-10）**。它扫的是 `rawfile/mockdata/`，而那个目录已经不存在了 |
| `check_algo.py` | Discover 算法的**参考实现 + 不变量自检**（榜单口径的唯一权威）。自带 `--fetch`，数据管道独立于生成器。设备端有一份移植（`BrewCatalogAlgo.ets`），**两边必须同步改** |

**生成器是确定性的**：同一份输入重复运行，产物字节级一致。
这条性质曾被当作正确性判据用（"重产出只改了受影响的文件"），当时靠的是 Discover 产物用
`snapshotDate`（数据窗口结束日）而不是墙钟时间。**2026-10 起已无产物**，这条性质随产物一同退场；
`check_algo.py` 的自检（`--fetch --data .brewgen/analytics`）取代了它成为榜单口径的验证手段。

### 4.3 Discover 算法（要点，细节看 `brew-discover-algo.md`）

- **口径全程统一**：Formula 用 `install-on-request`，Cask 用 `cask-install`。
  **不要用 `install`** —— 实测被动安装占比可达 95%+，会得到一张"依赖包榜"。
- 三个基础量：`vol = 30d`、`prior = (365d − 30d)/11`、`vel = vol/prior`（**分母不加 `max(1,·)`**）。
- **family 去重**（`token.split('@')[0]`）是一级规则，否则 `python@3.1x` / `go@1.2x` 会一起上榜。
- 三张榜：趋势（`vol ≥ VOL_FLOOR ∧ prior ≥ MIN_PRIOR`，按 `log1p(vel)×log1p(vol)`）、
  历史（`365d` 降序）、新星（`vol ≥ NEW_FLOOR ∧ prior < MIN_PRIOR`）。
- 门槛由**分位数**标定并落盘，每次刷新重算（设备端现算实际分位并打日志，**不自动改门槛**：漂移要人看一眼）。
- **排序永不 cap**（初稿的 `cap 5.0` 会把候选全压平，实测 `vel` Top50 全部 > 5）。
- 算法有**两份实现**：`check_algo.py`（参照 + 自检）与 `BrewCatalogAlgo.ets`（设备端，设备上现算成员）。
  **改一处必须同步另一处**；对账看 `catalog top <kind>/<boardKey>` 与 `check_algo.py --print-top 10` 是否逐名一致。
- **分类也在设备端**（C 档）：`BrewTaxonomy.ets`（`lexicon.json` + `tokens.json` 的移植）。
  判别顺序 = 策展覆盖 → 关键词（desc 前 3 词 3 分、其余 1 分，top≥2 且领先≥2）→ 兜底
  （formula `system` / cask `systemtool`）。浏览集 = 目录里按 30d 安装量降序的**前 100**
  （`BREW_BROWSE_LIMIT`，硬裁切，分页待做）；分类只能看 `desc`，所以这 100 条的现网单条
  是**构页输入**而不是可选刷新（见 §5.3 那条踩坑）。

---

## 5. 关键决策（含被推翻的）

### 5.1 仍然有效的决策

| 决策 | 理由 |
|---|---|
| 只保留 `default` 一个 product，`deviceTypes` 仅 2in1 | 需求：只跑 PC |
| formula / cask **共用详情路由** `BREW_DETAIL_VIEW`，`kind` 由路由参数分流 | 一套渲染，字段差异在 `BrewDetailNormalizer` 里摊平 |
| 详情页**不复用**组件库的详情页四契约引擎 | 按典型应用市场布局单开页面 |
| 热度表达 = **近 30 天安装量 + 分类内排名**，不做星级/热度条 | Homebrew 没有评分数据 |
| 安装命令区**只展示基础命令** | 已移除自造的安装选项面板 |
| 包描述**英文原文 + 中文 UI**（中文只在 `string.json`） | 描述是上游数据，翻译质量不可控 |
| 共享 UI 原子/常量放 `brewcommon` | 并列页签的样式与数值必须同源，否则必然漂移 |
| 「我的」页**就地改造** `features/mine` | 需求方明确要求 |
| Discover 版式 = **复用 Formulae 首页那套 `WaterFlow + 大卡`**，一张卡 = 一张榜，共 6 张 | 需求："前三个页签复用现有首页 UX" |
| Discover **不吃 Preference 缓存** | 榜单是"某个时间点的冻结快照"，走缓存会让新数据静默不生效（踩过） |
| 「每页实例」的状态**不能放共享单例** | 详情页因此出现过"返回键失效 / 返回后内容不变"（§10.4.1） |

### 5.2 被推翻/纠正的决策（**不要再改回去**）

| 曾经的决策 | 为什么被推翻 |
|---|---|
| Discover 算法用 `install` 口径算趋势 | 会得到依赖包榜（实测被动占比 95%+） |
| `Velocity ≈ 1` = 常态 | 真实中位数 0.50、只有 16.8% > 1，会把大多数稳定包判成衰退 |
| `cap 到 5.0` | 实测 p99=10、max=22637，候选 Top50 全部 > 5，会把整张榜压平 |
| `TodayScore = α×Velocity + β×normalized(recent)` | 只归一化了 recent，β 项完全被无界的 Velocity 盖过（实测 Top50 重合 50/50） |
| 用"发布日期"判断新包 / 用 GitHub commit 判断活跃度 | API 没有发布日期字段；未认证 GitHub 配额 60/h |
| `appcasks` 提供 Cask 图标/分类 | **理由已更正（2026-09-21）**：不是"源不存在" —— 已 archive 的那个空 Fork 模板是 `appfair/appcasks`，而 **`App-Fair/appcasks` 未归档且带 `cask-<token>/AppIcon.png`**（详见 `brew-discover-algo.md` §1.2）。本轮不接入是**需求方决定**，不是实测否决。**别再拿 "404" 当理由** |
| Discover 用 `styleType 1/2/4` 分组（探索页那套） | 探索页不在当前侧边栏里；版式改为复用组件页首页骨架 |
| 大图卡底部做成"居中巨字母 + 三行文字" | 与组件页 `CodeLabCard` **结构**不符（缺底部 item 行） |
| 大图卡左上角挂来源徽章 | 需求方明确：来源徽章放**小字行**（原包名那行），左上留空 |
| 榜卡行 secondary 放度量数字 | 需求方要求改成应用的 `desc` |

### 5.3 数字类结论（实测得出，写代码时别猜）

| 结论 | 数值 |
|---|---|
| `Body_L` = HDS 列表项标题行高 | 36 px（`Title_S` 是 45，比它大 25%） |
| 组件页 `CodeLabCard` | 400vp 高 × 400vp 宽 = **1:1**（`codelab_card_height`） |
| 组件页多栏断点 | `{sm:1, md:2, lg:3}`；**本机跑在 md 档**（所以是 2 栏） |
| 横纵换算比例**不同** | 纵向 ≈ **1.9 px/vp**（行高 64vp=122px）；横向 ≈ **3.8 px/vp**（`level6`=22px） |
| 聚合端点的容量（实测） | raw **1.9 MB** / gzip **358 KB**（4 个文件：formula 83+127 KB、cask 61+96 KB） |
| ~~聚合端点条件请求命中率~~ | ~~**3/4**（不是 4/4）：4 个端点落在不同 CDN 节点上，节点持有两代副本~~ —— **2026-09-23 作废**，见下面两行 |
| ⚠ **聚合端点的真实代价（2026-09-23 实测，推翻“探针只花几百毫秒”）** | 4 个端点**并行**探针（**不是 HEAD**，是带 IMS 的完整 GET）设备实测 `catalog_fetch ms=17437`，宿主机同批 **5.2s**。**304 也可能花 24.06s**（TTFB 22.5s、0 字节）—— 因为边缘 `Cache-Control: max-age=600` 只有 10 分钟，而目录窗口是小时级，探针必然打在过期的边缘副本上 → 回源（`X-Cache: MISS`）。同 URL 相隔几秒 TTFB 在 **0.90s ↔ 22.49s** 之间跳。结论：**探针就是那段等待，不是廉价的前置检查** |
| ⚠ **analytics 内容的重新生成频率** | 4 个文件的 `Last-Modified` 实测 **5 分钟内**从 `00:58:15` 变到 `01:38:38` → **小时级的 IMS 基准几乎永远对不上**，条件请求在小时级窗口下基本无效 |
| 目录新鲜窗口（2026-09-23 起） | **6h**（原 1h）。依据见 `docs/superpowers/specs/2026-09-22-brew-fetch-toast-design.md` §13 |
| Discover 整页（隔夜后首次，全缓存过期） | **21.7s** = `getCatalogMs 17611`（探针）+ `hydrateMs 4103`（23 条 live）。`[notice]` 实测只在第 17.2 秒才弹 —— 已修（通知挪到探针前） |
| 目录全量规模（2026-09-18 窗口） | formula raw **7,916** token → **7,721** family（候选 799）；cask **5,863** → **5,659**（候选 563） |
| Discover 成员的 join 命中率 | **10/10**（六张榜的前 N 名全部能落到内置详情；`skipped 0`） |
| 单条详情文件 gzip 后的传输量 | 约 **1.1~2.1 KB**（raw 3~6 KB）—— 240 条合计约 **292 KB** |
| 浏览页冷启动代价 | ~~100 条单条 × 1.2 KB，实测 2.7~7.4s~~ → **2026-09-22 实测 17.7s / 18.8s**（两轮），其中 **16.5s（96%）** 花在 93 个**必然 404** 的逐条 hydrate 上（`dl=0`，一条也没上屏）。根因与修法见 `docs/superpowers/specs/2026-09-22-brew-coldstart-design.md` §2 / §5；修法的判据是 `BREW_INDEX_MIN_TRUST` 闸门 |
| 主线程 `JSON.parse` 的代价（易被高估） | 索引 1 MB = **17ms**、目录 550 KB = **19~22ms**、7500 条分类 = **396~420ms**。所以"瓶颈在 I/O"这个直觉是错的 —— 别再从"换存储/加硬盘缓存"入手 |
| 浏览页的分类分布（2026-09 实测） | formula 8 卡 99 条：terminal 7 / devtools 18 / network 2 / data 7 / cloudnative 7 / media 3 / ai 5 / 兜底+system 50；cask 8 分类 100 条 |
| **元数据同步的真实耗时（2026-09-22 实测，上游慢时）** | `meta sync [formula]` **578s** + `[cask]` **221s** = `total=798998ms`（**13.3 分钟**）；同一时段宿主 `curl -I /api/formula.json` 要 **21.95s**，完整 GET >60s。快时是 **21.7s**。所以这个数字**完全由上游决定**，跨度 21.7s ~ 13.3min |
| 索引落盘耗时（与下载无关） | `pref write=17ms`（索引约 1MB）—— 写盘从来不是瓶颈，别再从“写盘慢”入手 |
| 上游是否支持条件请求 | **支持**（基准确实被读出并落盘：实测 `brew_meta_stamp` 从 `12:36:46` 自更新到 `12:59:30`） |
| ⚠ **全量包的实际重新生成频率（2026-09-22 实测，推翻文档旧说法）** | `cask.json` 的 `Last-Modified` 在 **53 分钟内换了三代**（`12:36:46` → `12:59:30` → `13:30:01`）。**文档原先写的“源站每天重新生成一次 / 数据按天生成”是错的**。后果：`If-Modified-Since` 的命中率远低于设计假设，它的价值从“几乎总是 0 字节”降为“同一代窗口内 0 字节” |
| 删掉 details/banner 省下的包体 | **443.6 KB（details）+ 2.4 KB（banner）**；剩余 9 个 brew mock 文件合计约 247 KB |

### 5.4 Harmonybrew 方言机制与本地目录

多源注册表在 `BrewSource` 上冻结 `dialect`（`upstream` / `harmonybrew`）和 Harmonybrew bottle tag。
新增或编辑源时，探测链先试上游、失败再试 Harmonybrew 的 JWS Range 探测；保存路径是探测结果的
唯一写者。运行期索引和详情取数才按**会话冻结源**的 dialect 分派到 `BrewSourceAdapter`：
上游保持 per-token 端点，Harmonybrew 归一化单文件目录。

Harmonybrew 详情不请求网络。目录正文路径是
`filesDir/brew_src/<sourceId>/catalog.tsv`，每行格式为 `token\t<doc JSON>\n`；约 50 KB 的字节偏移表
在对应 `brew_src_<sourceId>` Preferences 的 `brew_catalog_offsets`，键 `brew_catalog_offsets` 是新增的，
原六条缓存键不变。`BrewCacheAdmin.clear/drop` 必须连带调用 `BrewCatalogFile.delete`，否则会留下约
3.4 MB 正文或偏移表。同步写入顺序是“完整目录与偏移表先落盘，ETag 后记”；只有索引和目录都存在才
发送 ETag。Harmonybrew 的 IMS 不生效而 ETag 会返回 304，不要把上游的 Last-Modified 规则套过来。

详细端点、响应头、JWS 形状、映射表与五个固定样本见 `brew-api-design.md` §7.5.2。

---

## 6. 四个页面的现状

### 6.1 Formulae / Casks

**数据来源**：设备端用目录 + 词表现算 —— 成员 = 按 30d 安装量降序的**目录 ∩ 元数据索引**
（2026-09-22 起不再等于目录全量，也不再是“前 100”），分类 = `BrewTaxonomy`。
所以**包名会随现网安装量变化**（不再是冻结的 240 个），无网时是空态（内置 page 快照已删）。
判据（**新格式**）：`browse formula built, 7299/7392 tokens ready (catalog 7392, index 7299, dropped 93, hydrate 0, trusted=true), 9 cards, …`
> 历史格式（2026-09-18，`BREW_BROWSE_LIMIT` 还在时）：`browse formula built, 99/100 tokens ready, 8 cards, 99 entries, 5049ms | terminal=7 devtools=18 …`
> —— **`99/100` 这种写法再也不会出现**（分母已改成目录全量），别拿它去 grep 新日志。字段读法见 `brew-api-design.md` 与 spec §7。

`BaseHomeView` + `WaterFlow` + `LazyForEach` + 分类大卡，与组件页首页同构。
分类卡的头部是"信息头"（分类 symbol + 中英文名 + 包数），**不是图片**（Homebrew 无素材）。
卡内只预览 `BREW_CATEGORY_PREVIEW_COUNT`（5）条，装不下就在卡底给一行「查看全部」。

**两个页签现在同一形态（各两层）**：首页 = 全部分类的卡片瀑布流（点整卡/「查看全部」进二级页）；
分类二级页 = 标题栏里的 chips（选分类）+ 该分类的**全部**成员卡片。
二级页用 `BrewCaskCategoryView` / `BrewFormulaCategoryView`，标题固定是页签名，分类身份由 chips 表达。
分类 chips 在**标题栏的 `bottomBuilder`** 里（纯文字胶囊，与样例页一致）。

### 6.2 包详情页（`brewdetail`）

11 个分区，formula / cask 共用。`BrewDetailNormalizer` 把两种包的字段差异摊平成
统一的「行 + 分区」，UI 里只有一处 `kind` 分支。`BrewDetailViewModel` 是**无状态**的，
`BrewDetailState` 由页面自己 `new`。

**取数与回退（2026-10 口径）**：`BrewRepository.getFormulaDetail/getCaskDetail` 按 token 取现网单条，
合并到 `BrewApiMapper.formulaBase/caskBase` 给出的底座上；本地才有的 `id`
（`BrewBrowseBuilder.tokenId(token)`）与 `categoryKey`（`BrewTaxonomy`，输入是目录描述）由设备端算。
三条结局：单条 404 / 410 → `BrewDocAbsentError` → 详情页显示「未找到」（自定义 tap 的本机包就是这种）；
其余失败 → 上一次成功归一过的详情；没有历史详情 → 失败态（可重试）。
判据：`getCaskDetail live ok, token=cursor, v=3.21.9,...`；`fallback to cache` 表示用了历史详情；
`load absent, kind=formula token=X status=404` 表示「未找到」。

### 6.3 Mine（`features/mine`，就地改造）

顺序：华为账号 / 激活本机包提示卡（`pc_normal`）/ 内容上新&最新公告 / **已安装** / **待更新** / **已更新** / 设置。
三个包集合口径统一在 `MinePackagesUtil.loadSets()`，命令输出的 formula 与 cask 都进这三个集合：
`installed`（全部已安装）/ `outdated`（有新版本）/ `updated`（= installed − outdated，按 `installedAt` 倒序）。
三个集合都由 `installed` 派生，盘上快照只存它一份；条数是设备实际值，不在文档里写常量。
三个入口**共用二级页** `MinePackagesView`，靠路由参数 `mode` 区分。
本机包行（两张卡片的预览行与二级页的行）都能点进包详情页，路由参数由
`MinePackagesUtil.detailParamsOf(pkg)` 统一给出（`id` 传 0，取数层按 token 派生）。

三个二级页的标题栏末尾各有一个「隐藏依赖」chip（`BrewChip`，筛选 chips 的外观与它同源），
选中后按 `installedAsDependency` 去掉作为依赖安装的包：`MinePackagesUtil.visible()` 是这条过滤的
唯一实现，与筛选 chips 串在同一条链上。三个页面共用 `MinePackagePrefs` 的 `mine_hide_dependency`
一个键（默认显示全部，开关状态重启后保持），「我的」页的已安装数量与两张预览卡不受它影响。
设备实测：全部 85 个里 74 个是作为依赖装的，待更新的 7 个里有 2 个（cairo / gmp）。

隐藏开启时，待更新页的「更新全部」先弹一次确认框：`brew upgrade` 不看 `installed_on_request`
（`cmd/upgrade.rb:399`），设备上全部过时的包都会被升级，包含被隐藏的依赖包。
「更新全部」是一条底部悬浮操作栏（单页签 `HdsTabs` 的页签栏承载，白色渐变遮罩 + 强调色长条按钮），
取值与包详情页的安装操作栏共用 `BrewActionBar`；不满足「待更新 + 当前筛选下有包 + brew 可用」时
整条栏不渲染，页面与改动前一致。
`brew update` 只更新 Homebrew 自身与各 tap，不安装也不升级任何包；应用的命令行前缀固定带
`HOMEBREW_NO_AUTO_UPDATE=1`，所以「待更新」列表与「更新全部」看的是同一份本机 tap 状态。

「我的」页与「本机包」二级页的标题栏各有一个刷新按钮（`sys.symbol.arrow_clockwise`）：点击后
按 `BrewInstalledLoader.loadSets(force = true)` 跳过十分钟新鲜窗口、立即重跑一次
`brew info --json=v2 --installed`，刷新期间按钮置灰。成功按当前 chips 与隐藏 chip 重算列表
（不重置筛选），失败保留页面上已有数据并弹一条「读不到本机包」。两个页面的按钮都在
本机包能力不可用时（`pc_normal`，或设备上找不到 brew）不渲染。

### 6.4 Discover（`brewdiscover`）

```
BrewDiscoverHomeView（壳，自己的 PageContext）
 └─ BrewDiscoverListView（目的地：模糊标题栏 + 随滚动隐藏 + 返回键交基类）
     └─ BrewDiscoverBaseView（BaseHomeView + WaterFlow 单 section + LazyForEach）
         ├─ BrewDiscoverFeaturedCard ×5   单 App 大图卡（1:1，= 组件页 CodeLabCard 结构）
         └─ BrewDiscoverBoardCard ×6      榜卡（hero + 5 行 + 查看全部）
             └─ BrewDiscoverBoardView     榜单二级页
```

- 瀑布流数据源装的是 **`BrewDiscoverFeedItem`**（带 `feedType` 判别的联合项），
  单 App 卡在前、榜卡在后 —— 用两个 section 的话交界处会多一段 margin。
- **单 App 大图卡**：右上增速徽章、小字行来源徽章、大字加粗 `desc`（2 行截断）、
  item 行 = 48vp 图标 + **市场名** + **下载量** + `>` 圆钮（`CircleArrow` 同款）。
- **榜卡行**：48vp 主题色图标 + 包名 + **`desc`** + `查看` 按钮。
  **名次与度量数字目前都不在行里**（名次由顺序表达，度量随 secondary 改 desc 退出）。
- 主题色：趋势=暖橙红、新星=绿、历史=蓝（`brewdiscover/resources/base/element/color.json`），
  与来源榜同色。视觉层是**代码画的渐变**（`CodeLabCard` 那层 `ImageComponent` 的替代），
  因为 Homebrew 没有任何可用图标/截图素材。

**成员来源（2026-09 已变，C 档后又变一次）**：页面加载时取设备端目录（4 个聚合端点 →
`BrewCatalogAlgo` 现算六张榜），`id` 用 token 的稳定哈希，`name`/`desc`/`categoryKey` 由随后的
现网 hydrate 覆盖（分类要看 desc）。**不再按白名单过滤** —— 榜现在是真·全球前 N，
不在内置清单里的包也能点进详情（详情页只用现网单条 + 词表渲染）。
目录彻底拿不到时**没有回落**（内置快照已于 2026-10 删除）：六张榜保持骨架但成员为空，
`loadDiscover` 过滤掉空榜后页面走空态（与 Formulae / Casks 的 C 档行为一致），
日志判据变为 `discover empty (catalog unavailable)`。
正常路径的判据：`catalog members applied, 47 entries on screen, window=2026-09-18`。

---

## 7. 踩坑索引（按类别）

细节都在 `brew-api-design.md`，这里只做索引，方便按症状查。

### 7.1 "编译全绿、运行期才崩"

| 症状 | 章节 | 一句话 |
|---|---|---|
| `class constructor cannot called without 'new'` | §9.8 | 组件内联在 `CustomBuilder` 的箭头里 → 必须经 `@Builder` 方法调用 |
| 返回键第一次有效、之后失效；返回后内容不变 | §10.4.1 | 「每页实例」的状态放进了共享单例 |
| 数据更新了页面却没变 | §13.7 | Preference 缓存挡新数据（编译过、装机成功、无异常、无日志） |

### 7.2 属性覆盖 / 内缩来源（静默失效，无报错）

| 症状 | 章节 | 一句话 |
|---|---|---|
| 左右边距突然没了 | §9.9 | 同一节点两次 `.padding()` 后者覆盖前者 |
| Formulae 页完全没有边距 | §9.10 | 并列页签只写了其中一个的边距 → 提到 `brewcommon` 共用 |
| 右侧边距消失 | §13.4.1 坑3 | 抄 builder 漏了外层包装；**改容器内缩时要逐方向确认还有谁在提供内缩** |
| 二级页顶部多一条空白 / 底部贴边 | §13.9 | 顶部让位用了 `brewTitleBarTotalHeight()`（含 chips 行），**而该页标题栏里没有 chips** |

### 7.3 静态查不出来的东西

| 症状 | 章节 | 一句话 |
|---|---|---|
| `sys.symbol.*` 名字不存在 | §10.6 | 资源名只有写成 `$r()` 字面量才会被编译校验；**只能实测** |
| ~~JSON 形状与 ArkTS 声明不符~~ | §8 | 已随 mock 一并退场（2026-10）：JSON 不再入库，编译器只看声明与代码 |
| 版面"就是不像" | §9.11 | **用 `ui layout` 量，不靠猜**；判断依据是"两边量出来是否一样" |
| 符号检查误判为"没编进去" | §9.5.1 | `strings` 的 grep **不要加 `^...$` 锚点** |
| 纯图标控件"没渲染" | §9.5.1 | simplified 模式不列无文字的 Button → 用 `--mode full` |
| 行/卡片点不动 | §13.9 | 回调链路齐全但 `build()` 里根本没挂 `.onClick` —— 有回调 ≠ 接了线 |
| 「点了没反应」（chips/按钮），但日志显示回调执行了 | §10.5.2 | 两种成因：① `ui click` 打在**非前台窗口**上（无报错，`ui layout` 会返回 `[0,0,0,0]`）；② 真的没重渲染（把选中态放在 state 对象上由 VM 赋值时踩过）。先分清是哪一种 |
| 详情页失败态 / 「未找到」态内容区空白，日志里状态已经变了 | §10.4.2 | ArkUI V1 的 `@State` **只观察第一层属性**：写 `state.loadingModel.loadingStatus` 不触发重渲染。加载状态要整体替换 `loadingModel` |
| 标题栏模糊「先空行程、后猛增」 | `hds-titlebar-blur.md` §5 坑1/坑2（速查 §9.12） | HDS 的偏移量取值 [0,+∞)、越界**静默**按默认值处理（负数 = 0）；而 `contentStartOffset` 会把滚动坐标系左移 C（静止时自报 −C）→ 起点永远够不到。让位要写进**内容**（占位块 / 内层 margin），区间恒为 `[0,104]` |
| 标题栏不模糊（其它页面有） | `hds-titlebar-blur.md` §5 坑3/坑5 | 容器 `padding` 把内容裁剪了 → 让位改用**内容里的占位**；无 banner 的页套基类的 banner 公式还会算出反向区间 |
| 标题栏「一滚就全糊」、没有渐变 | `hds-titlebar-blur.md` §5 坑4 | 只写了材质/类型、没写区间 → HDS 默认区间只有 8vp |
| 列表里的安装量/名次是旧的 | §7.4 | 骨架（分类/成员/榜单成员）**只能**内置——官方 API 无分类字段、榜单阈值是全球分位；能刷成现网的是包自身属性，hydrate 在 Repository 返回前完成 |
| “现网数据”上线后列表内容没变 | §7.1 | 别去缓存整页：整页缓存会把现网值挡在外面（就是 §13.7 那个坑的翻版），缓存粒度必须是单个 token |
| 榜单名次自己会变 | `brew-discover-algo.md` §7 | **有意为之**：“谁上榜”是快照，“多少”是现网；不要把它当 bug 修回快照值 |
| 同一个 URL 请求了好几次 | §9.13 | 缓存只在响应回来后才写入 → 必须再做一层**在途去重**（`inFlight` map）；页面加载被触发两次、页签并发批次有交集各占一半 |
| 过期后要不要重下 / 怎么判断“变没变” | §7.7 | **主动 probe**：1 次 HEAD（`If-Modified-Since`）代表整批；CDN 的 **ETag 跨节点不一致**（实测命中仅 1/5）→ IMS 优先、ETag 兜底 |

### 7.4 流程类

| 症状 | 章节 | 一句话 |
|---|---|---|
| HAR 没被任何模块 import 却被编译了 | §9.2.1 | `module.json5` 的 `routerMap` 本身就是编译入口 |
| 设备突然消失（`devecocli device list` 为空） | §8.1 | **别在本机跑 `hdc kill`**：它杀的是同一个 hdc server，`devecocli` 靠它连设备；目前的恢复办法是重新插拨/重连 |
| 把"版式"整段划归别处，规则丢了 | `brew-discover-algo.md` §6.1 | 划归时要**逐条清点**里面的规则（那张字段表其实是数据契约） |
| "撤销 X、去掉 Y"理解成两个删除 | §13.4.1 | 可能是在描述**一次移动**（X 移到 Y 腾出的位置） |

---

## 8. 交接注意事项

### 8.1 收尾时要做的事

1. **下线对照入口**：`features/pcui/src/main/ets/model/TabBarModel.ets` 里
   `LEGACY_TABS_ENABLED` 置 `false`（当前 `true`）。之后 `TABS_LIST` 只剩四个市场页签。
2. **清理死代码**：`features/brewformulae/.../BrewMarketPlaceholderView.ets` 与
   `brew_placeholder_*` 文案已无引用（两个占位页都被真实页面替换了）。
3. **数据署名**：使用 `formulae.brew.sh` 数据需注明来源与许可。
4. **删除对照资源**：~~（可选）`mockdata/` 下 `component-*` / `sample-*` / `discovery-*` 等
   与对照入口绑定的文件~~ —— **已完成（2026-10）**：`rawfile/mockdata/` 整个目录已不存在。

### 8.2 待办（合并 `§11` 与后续新增）

#### Harmonybrew 收尾未决项（实施计划 §6）

以下不阻塞当前适配，但上线前应由产品/服务端明确，不能在实现任务里顺手决定：

1. **Cask 与 Discover 的产品取舍**：Harmonybrew 的 casks 与 analytics 都为空；当前保证不崩、显示“不提供”，是否隐藏整个 Discover 入口待产品决定。
2. **是否翻默认源**：本轮保留内置 upstream 为默认源。若要改变，还要处理 builtin/baseUrl 不变量、AtomGit 第三方域名的可用性与合规风险，以及是否保留上游兜底。
3. **服务端是否补上游形状端点**：若对方发布 `formula.json`、`formula/<token>.json` 等端点，可整体下线本方言适配；建议同步向 Harmonybrew 提议。
4. **未转义 `packages.<tag>.json` 是否恢复发布**：即便恢复也不能依赖它；当前实测旧文件陈旧 86 天。
5. **bottle tag 的长期来源**：当前由探测响应写回。若服务端同时发布多个 tag，需改为按设备 ABI 选择。
6. **`bottle_rebuild > 0` 的 bottle URL**：应用当前不消费 URL；若详情页以后增加下载链接，再按公式 revision/rebuild 规则合成。

| 项 | 说明 |
|---|---|
| **搜索** | **已实现**（`features/brewsearch`；spec `docs/superpowers/specs/2026-09-21-brew-search-design.md`）。**2026-09-24 修订**：历史改为用户真实搜索记录并落盘（`brew_search_history`）、发现改为设备端目录真实热门（`BrewSearchModel.hotTokens`，宁空不摆假词）、搜索改为显式触发（回车 / 点「搜索」，不再输入即搜）。仍不做：搜索联想 / 拼音纠错（无数据源）、结果分页（一次取前 `BREW_SEARCH_LIMIT` = 50） |
| **浏览分页** | 现在是硬裁切前 100（`BREW_BROWSE_LIMIT`）。分页要做的是"每页条数 + 向下翻"，语义不变（分类与名次始终在**取到的这一批**内计算）。**已另立 spec：`brew-catalog-fullsync-spec.md`**（先把"分类依赖现拉 desc"这个根因去掉，cap 的技术限制随之消失） |
| **无网时三个页签都是空态** | 内置快照已于 2026-10 全部删除（page / details / discover / local），所以无网时 Formulae、Casks、Discover 都走空态，Mine 恒显示 0 个包。这是**已知取舍**（用户已接受）：失去「断网评审演示」能力，换来「屏幕上每个数字都是真的」。要留离线演示得重新产一份很瘦的回落，并**连同 `MockRequest` / `TriggerEnums` 一起回来** |
| **词表对"库/工具链"覆盖不足** | 实测顶部 100 个包里约一半落进兜底（`openssl@3` / `protobuf` / `neovim` / `poppler` / `pipx` … 关键词确实判不出来）。这些包在界面上会出现在 `系统与运维`/`系统工具`。要改善就补 `lexicon.json` 的关键词（改完要重新生成 `BrewTaxonomy.ets`） |
| ~~本机包行不可点~~ | **已实现（2026-10）**：「我的」页两张卡片的预览行与「本机包」二级页的行都能点进详情页。路由参数 `id` 传 0，取数层用 `tokenId(token)` 派生；数据源目录里没有这个 token 时详情页显示「未找到」 |
| **本机状态徽标** | `installed` / `outdated` / `pinned` 已建模但未使用（需接 `brew info --json`） |
| ~~Mine 的 taps / services~~ | **已处理（2026-09 删除）**：`brew-local-taps.json` / `brew-local-services.json` 与 `overview` 一样从未被 UI 调用，三个文件 + `BrewLocalModel` 的三个方法 + `TriggerEnums` 成员已一并删除 |
| **Cask 图标/截图** | **本轮暂不接入（2026-09-21 需求方决定）**，维持代码画的视觉。⚠️ "无可用来源（`appcasks` 实测 404）"**是错的**：候选源 `App-Fair/appcasks` 未归档、带 `cask-<token>/AppIcon.png`，只是**覆盖率没量化**。重启时第 1 步是全量 7,745 个 cask 对账（详见 `brew-discover-algo.md` §1.2/§8） |
| ~~两个 banner 端点未使用~~ | **已处理（2026-09 删除）**：端点、mock 文件、`BrewBanner` 模型、Repository 里的 hydrate 逻辑一并删掉 —— 它们从来没有 UI 调用点 |
| ~~详情文件整份加载~~ | **已处理（2026-09 删除）**：详情页骨架改从首页条目合成（`formulaBaseOf`/`caskBaseOf`），`brew-*-details.json` 两个文件（443.6 KB）不再产出也不再读 |
| **Discover 度量数字** | 已从榜卡行退出。若要挪回界面（icon 角落 / 按钮左侧），四个 `brew_discover_metric_*` 模板仍在资源里；**恢复时必须一并恢复 `velocity <= 0` 的判断**（那是"新包无历史"，不是"0 倍"） |
| **新星榜稳定性** | 绝对量小（本次 306~2050），窗口滚动一天就会换人。`NEW_FLOOR` 仍是绝对值，建议改成按快照分位标定 |
| **`lexicon.json` 未被使用** | `tokens.json` 的 override 覆盖了全部包；扩量时才需要收敛关键词与阈值 |
| **现网 hydrate 的请求量** | 一页 100 个条目 = 100 次单条请求（TTL 6h，首屏约 2s）。要降下来只能自建服务端把聚合结果压小，或改成“只 hydrate 首屏可见卡片” |
| ~~目录的 304 只省不了一半~~ | **2026-09-23 修正**：原判据（“实测 3/4 命中 304”）已被推翻 —— 探针是完整 GET、304 也可能花 24s、内容每 5~10 分钟换代所以小时级基准几乎不命中。**真正的杠杆不是算法而是频率**：`BREW_CATALOG_FRESH_MS` 已 1h → 6h。若还要再降，“把摊平后的 counts 落盘（~400KB Preference）”仍然有效，但优先级下降 |
| **目录不覆盖“非白名单包”** | 榜上前 N 名目前恰好都能落到内置详情（实测 10/10），所以不可点的条目被直接筛掉（`skipped`）不会造成可观察损失；但若换成“全球前十”的语义就会，那时必须先把详情页改成能单独用现网单条渲染 |
| **全量目录的用途** | 1.3 万 token 已在内存，现在服务于榜单 + **搜索**（搜索页直接吃全量目录 + `token → desc` 索引）；而**浏览**仍只在前 100（`BREW_BROWSE_LIMIT`）。“全量目录只用于榜单”这句已不再成立 |
| **现网路径未在设备上实测** | 接线当天设备连接掉了（见 §8.4），**编译通过、但 TTL/并发/回落逻辑未经真机验证**。恢复设备后先看 hilog 的 `[BrewHttp] GET ok` 与 `[BrewService] hydrate done, n/m` |
| **Formulae 的 section margin 与视图 padding 同值** | 两处写了同一组内缩值，看起来是双份。属已验收页面，未动；Discover 只保留一处（section margin） |
| **`brew-discover` 仓库地址待补** | 用于后期替换分类定义 |
| **分类结果落盘** | 每次构页主线程分类 7500 条 = 420ms。要再压就得把 `token → categoryKey` 并进元数据索引，代价是需要**词表版本失效机制**（`BrewTaxonomy` 随版本走）。**触发条件**：首屏进 1100ms 以内后还想再压 |
| **数据源请求的错误处理（后期）** | 多源特性只做了「激活前单端点探测」（`BrewSourceProbe`）；**冷启请求失败逻辑本轮未动**。spec §10.2 登记了 7 项待改：`fetchCatalog` 的 `Promise.all` 无逐端点隔离（镜像缺一个 analytics 就整批失败）、`buildCatalog` / `conditionalFetch` 的 `JSON.parse` 无 try/catch（镜像返 HTML 200 时报无关错误）、`BrewMetaSync.syncKind` 不校验 JSON 形状、`BrewHttp.getJson` 不区分 304/404/其他非 200、无重试退避、无每源熔断。**触发条件**：用户反馈某个镜像「时好时坏」或要长期使用非官方源 |
| **`BrewLoadLog` 补 `reason=epoch-dropped`** | `persistIndex` 被世代号丢弃时目前用 `reason=sync-failed`，与真正的同步失败共用一个 reason（判据行语义重载）。在 `BrewLoadLog` 的 reason 词表里加一行即可，之后 `grep 'reason=epoch-dropped'` 就能直接统计「清空缓存与后台同步撞车」的发生频率。**触发条件**：想量化这个撞车场景时 |
| **源列表缺行级 loading** | 清空/删除没有按行的「进行中」反馈（`busyText` 字段已删：它不含源 id，无法驱动按行 loading；要做需另加 `busyId` 并配套 set/clear）。目前靠二次确认弹窗 + `BrewCacheAdmin` 串行队列，实测延迟可忽略（`persistNow evictMs=5~10ms`）。**触发条件**：若以后清空/删除变慢（例如某个源的数据量大幅增长） |
| **`BrewSourceCacheStats.updatedAt` 不展示** | 该字段仍计算，但目前只对 `brew_catalog` / `brew_meta_index` 两个键有值，UI 未显示。要么在缓存面板里展示，要么把它从 spec §9.1 的字段表里去掉 |
| **`brew_live_data` 的大 blob 拆细** | ⚠ 注意：**GSKV 并非“实时落盘”** —— 它先写内存缓存页，只有 `removePreferencesFromCache` 才保证写盘（实测：写入后 ~25s 内被杀会丢）。所以每批 hydrate 结束后都显式调了 `persistNow()`（实测 `evictMs=5~10ms`）。在此前提下，当前仍把全部 doc 当一个键整写（~1.2MB/批），且 `JSON.stringify`/`parse` 是主线程开销的主因。改成每 token 一键才能真正吃到增量写优势。**触发条件**：hydrate 的落盘耗时进入首屏预算 |
| **`import lazy` / 桶文件收敛** | `brewcommon/Index.ets` 24 条 export（含 1163 行的 `BrewService`），`SplashViewModel` 从它取符号 → 闪屏拉起整个 brew 数据层。**这是官方点名的冷启动项，但本轮未量到耗时，不凭"官方说重要"改结构**。触发条件：用 DevEco 的 AppAnalyzer 量出未使用 import 的实际耗时 |
| ~~元数据同步加 HEAD 探针~~ | **已处理（2026-09-22）**：改成带 `If-Modified-Since` 的**条件请求**（未变 304 / 0 字节），基准存 `brew_meta_stamp`。同时修了一个更严重的结构缺陷：原先两个 kind 串行 `await` 完才写一次索引，实测 `total=798998ms`（13.3 分钟）期间 `brew_meta_index` **一个字都没落盘** → 浏览页永久降级。现在每个 kind 各自落盘（“迟到落盘”：预算 90s 只控节奏、不丢结果）。证据与修法见 `brew-catalog-fullsync-spec.md` §4.7 |

### 8.3 死代码清单（已扫描，不用再扫）

用脚本扫过全部 562 个 `.ets`：**没有未引用的导出符号**
（`*Builder` 是被 `router_map.json` 引用的、图标组件是同文件内使用，都属误报）。

已清理：`BrewMarketPlaceholderView.ets`（两个占位页都被真实页面替换）+ `Index.ets` 的导出
+ `brew_placeholder_discover` / `_casks` / `_hint` 三条文案。

`brewcommon` 的 `string.json` 里还剩 **48 条未被 `.ets` 引用**的文案，分两类：

| 类别 | 条数 | 例子 | 建议 |
|---|---|---|---|
| **确认死掉**（功能被取代或从未接线） | 37 | `brew_tab_mine` + `brew_tab_legacy_*`（5，侧边栏实际用 `pcui` 自己的 `tab_*`）；`brew_artifact_app/binary/pkg/font/other`（5，详情页展示的是原始 `artifactType`）；`brew_mine_*`（13，原 Mine 规划被需求方的新布局取代）；`brew_label_required_by/install_options/caveats/deprecated/disabled/replacement/deprecation_reason`（7）；`brew_state_installed/not_installed/upgradable/bottle/source`（5）；`brew_section_hot/new/top10/related`（4）；`brew_action_install/uninstall/upgrade`（3） | 可删（git 里有）。**但 `brew_mine_*` 与 `content-plan §8` 描述的那套 Mine 布局是配套的**，删文案前先把 §8 一并更新，否则文档会指向不存在的键 |
| **预备未用**（有对应待办，故意留着） | 11 | `brew_search_placeholder` / `brew_search_coming_soon`（搜索待办）；`brew_discover_metric_trending/_alltime/_fresh/_no_history`（Discover 度量待办）；`brew_state_*` 部分 | 留着，待办落地时直接用 |

> 这类"预备但未用"的文案很容易被误当成死代码删掉。判断依据不是"有没有被引用"，
> 而是**"有没有对应的、还没做的待办"** —— 所以清单要跟 §8.2 的待办表一起看。

### 8.4 提交序列（本次改造，`dev` 分支）

```
deaf95c 数据底座 + 工程收敛为 PC 单入口
fb4ca67 按决策移除自造的安装选项 props，补齐真实字段与分类排名
666d392 新建 Formulae 页签，接入侧边栏与详情路由
7e5511b Casks 页签（分类 chips + 卡片），共享 UI 原子上移到 brewcommon
0617f17 Casks chips 逐项对齐样例页
b6c6b9b 分类 chips 移入标题栏 bottomBuilder
03d1508 包详情页（formula / cask 共用）+ 修两处既有的数据形状错误
e16cdd5 修返回键失效与同类包返回后内容不变
f47a9b1 「我的」页按新布局改造，接入本机包数据
f852c7e 修卡片内边距 / 二级页面无左右边距 / Formulae 页完全没有边距
9ff25a4 「我的」卡片标题改用 HmosListItem 渲染头部
4271755 重写 Discover 推荐算法为现网口径（含实测修正与自检脚本）
a9887d6 更正"窗口数"与"现有数据缺窗口"两处说法
9e2171e 产出 Discover 三张榜数据（每榜 Top10）+ 补入榜上新包
123dc1f Discover 页签（三张榜）+ 复用组件页首页骨架
df9643a 补模块级 .gitignore
cc43616 多栏瀑布流照抄组件页配置（md 档写错成 1 栏）
d6d0d08 补回「单 App 大图卡」+ 修 Preference 缓存挡新数据
cf46f54 单 App 大图卡改成与组件页同尺寸（1:1）
b78a1eb 大图卡三行文案归位 + 补行首图标与行尾 > 圆钮
b827ad4 大图卡最终排版（来源徽章入小字行 / 右侧内缩 / 去名次角标）
87c8e0c 榜卡行 secondary 改成应用的 description
acd38a0 Discover 成员与数字改成设备端现算（接入聚合端点）
cfe173a 下掉 details/banner 两类 mock（-446 KB），详情骨架改由首页条目合成
496bfea 数据层接 formulae.brew.sh 现网（UI 零改动）
4c593b6 在途去重：同一 URL 的并发请求合并成一份
9a514a8 过期判定改成主动 probe（数据集探针 + 条件请求）
```

每个提交的 message 里都写了**改动理由与实测验证结果**，比 diff 更有信息量 ——
接手时建议先读 `git log` 的正文，而不是只看 diff。

### 8.5 一条方法论

这个项目里**绝大多数返工都源于"看起来对"而不是"量出来对"**。
涉及资源名、版面数值、跨模块引用这类"字符串/数字即契约"的东西，
必须有独立的验证手段：`check_algo.py` / `generate.py`（策展清单校验）/ `ui layout` / `ui screenshot`。
`§9` 整节都在讲这件事，值得先读一遍再动手。

### 8.6 设备连接的坑（本次踩到）

`devecocli run --device 127.0.0.1:42021` 里的设备串是 `hdc` 的一个 TCP 目标；
**本机就是那台 HarmonyOS 设备**（`uname -a` = `HarmonyOS ... HongMeng Kernel ... aarch64`）。

本次接线后为了试探网络，跑了一步 `hdc kill && hdc start && hdc list targets` ——
结果 `devecocli device list` 从此为空（`Connect server failed` / `No active devices`）：
**`hdc kill` 杀的就是 `devecocli` 依赖的那个 hdc server**（`hdc -m -s ::ffff:127.0.0.1:8710`），
而设备侧需要重新注册连接（`hdc tconn 127.0.0.1:42021` 也连不上）。

教训：**在本机调试 App 时不要动 `hdc`**。要看网络状态就在 App 里打日志（本项目已这么做），
或者用 `devecocli ui` / `devecocli log` 这类不碰 server 的命令。
恢复方式：重新插拨设备 / 重启 hdc 服务（需用户侧操作，Agent 当前权限做不到）。
