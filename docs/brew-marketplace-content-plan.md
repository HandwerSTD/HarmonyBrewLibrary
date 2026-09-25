> **接手请先读 `docs/brew-handover.md`**（交接入口）。本文只管产品/内容口径。

# Homebrew 应用市场 · 内容规划

> 目标：把 `sample_in_harmonyos` 改造成基于 Homebrew 生态的应用市场。
> 侧边栏：Discover / Formulae / Casks / Mine。前三个为联网探索入口（当前 Mock，未来接真实 API），
> 复用现有【组件 / 样例 / 实践】的 UX 骨架（模糊标题栏、大卡片）；Mine 复用【我的】，基本不动。

---

## 0. 决策摘要

| # | 决策项 | 结论 |
|---|---|---|
| 1 | Homebrew 分类体系 | **关键词自动聚类**（官方 API 无分类字段，必须自建）。集中到配置文件，后期可替换为 `brew-discover` 的 taxonomy |
| 2 | 现有【组件/样例/实践/我的】 | **全部保留作为对照**，开发结束时统一删除 |
| 3 | Mock 数据规模 | **精选切片，Formulae ~100 + Casks ~100** |
| 4 | Mine 本机软件包数据源 | **纯 Mock**（Service 层预留接口） |
| 5 | 包描述文案 | **英文原文 + 中文 UI**（不引入 `descZh` 字段） |
| 6 | 搜索 | **预留入口 UI + Service 接口，本轮不实现** |
| - | 待补 | `brew-discover` 仓库地址（用于后期对齐分类定义） |

---

## 1. Homebrew 领域事实与约束

### 1.1 Formulae vs Casks

| 维度 | Formulae | Casks |
|---|---|---|
| 本质 | 从源码构建的 **Formulae**（也可用预编译 bottle 分发） | **macOS GUI 应用**的二进制分发（**Casks**） |
| DSL | `class Wget < Formula`（Ruby） | `cask "google-chrome" do ... end`（Ruby） |
| 主 tap | `homebrew/core`（数千个） | `homebrew/cask`（数千个） |
| 安装 | `brew install <name>` | `brew install --cask <token>` |
| 关键字段 | `desc` `license` `homepage` `versions` `bottle` `dependencies` `keg_only` `caveats` `service` `deprecated` `disabled` `analytics` | `name` `desc` `homepage` `version` `url` `sha256` `artifacts[]` `depends_on{macos,arch,cask,formula}` `auto_updates` `zap` `deprecated` `disabled` |

### 1.2 官方数据源（`formulae.brew.sh` 静态 JSON）

| 用途 | 端点 |
|---|---|
| 全量 | `/api/formula.json`、`/api/cask.json`（**数十 MB，不可直接下发给客户端**） |
| 单条 | `/api/formula/<name>.json`、`/api/cask/<token>.json` |
| 分析 | `/api/analytics/install-on-request/30d.json`，单包 `.../30d/<name>.json` |
| 本机状态 | `brew info --json=v2 --installed`、`brew outdated --json=v2`、`brew tap` |

> 实现时需核对 analytics 端点命名（cask 系列为 `cask-install*`）。

### 1.3 三个硬约束

1. **官方 API 无"分类"字段**。formulae.brew.sh 只提供字母序与分析榜 → 分类体系必须自建。
2. **全量 API 太大**（数十 MB）→ 必须"精选切片（本地）+ 按需详情（远端）"两层。
3. `deprecated` / `disabled` 是**带日期与替代品**的正式状态（如 `python@3.9`）→ 详情页必须有警示条与替代品跳转，这是 Homebrew UX 的刚需。

### 1.4 命名相关

- 默认 tap（`homebrew/core`、`homebrew/cask`）自 Homebrew 4.0 起无需 `brew tap`，按需自动拉取
- 存在 `versioned_formulae`（如 `python@3.12`）、`aliases`、`oldnames` / `old_tokens`
- 第三方 tap 的包全名为 `tap/name`（如 `mongodb/brew/mongodb-community`）
- Bottle 自 2023 起托管在 GHCR，标签形如 `arm64_sonoma` / `sonoma` / `x86_64_linux`

---

## 2. 信息架构

关键前提：**现有三个内容 tab 跑在同一套引擎上**（`BaseHomeView` / `BaseHomeViewModel` / `BaseHomeState`，位于 `features/commonbusiness/`），因此切换内容主要是换 Service/Model + 卡片字段映射，UX 骨架原样复用。

| 侧边栏 | 复用哪个现有 tab | 复用模块 | 复用的 UX 骨架 |
|---|---|---|---|
| **Discover** 发现 | 实践 / 探索 | `exploration` | banner 运营位 + 分组大卡 → 文章详情（Web + 分享） |
| **Formulae** | 组件 | `componentlibrary` | 分类大卡 → 列表 → 详情（**属性面板 + 命令实时生成 + 代码高亮**） |
| **Casks** | 样例 | `devpractices` | 分类 → 大图卡片列表 → 详情（截图/版本/安装内容） |
| **Mine** 我的 | 我的（几乎不动） | `mine` | `ListGroup` / `MineItem` 分组列表 + 设置/关于/公告 |

复用现有卡片枚举（`features/commonbusiness/src/main/ets/model/CardData.ets`）：

```
CardStyleTypeEnum: 1=PICTURE_ABOVE_LIST  2=LIST  3=PICTURE  4=PICTURE_ABOVE_TEXT
CardTypeEnum:      COMPONENT=1  SAMPLE=2  ARTICLE=3
MediaTypeEnum:     IMAGE / VIDEO / SYMBOL
```

现有用法可直接照搬：`component-page.json` 用 1/2/3；`sample-page.json` 用 4；`discovery-page.json` 用 1/2/4。

---

## 3. 侧边栏与临时开关

开发期侧边栏为 **8 项**（4 新 + 4 旧）。用开关控制，收尾改一行即可隐藏旧入口：

```typescript
// features/abilitycommon/src/main/ets/model/TabBarModel.ets
export const LEGACY_TABS_ENABLED: boolean = true;   // 开发结束改 false → 再删模块

export const TABS_LIST: TabBarData[] = [
  { id: TabBarType.DISCOVER, icon: $r('sys.symbol.safari'),                       title: $r('app.string.tab_discover') },
  { id: TabBarType.FORMULAE, icon: $r('sys.symbol.chevron_left_slash_chevron_right'), title: $r('app.string.tab_formulae') },
  { id: TabBarType.CASKS,    icon: $r('sys.symbol.shippingbox_fill'),             title: $r('app.string.tab_casks') },
  { id: TabBarType.MINE,     icon: $r('sys.symbol.person_crop_circle_fill_1'),    title: $r('app.string.tab_mine') },
  ...(LEGACY_TABS_ENABLED ? LEGACY_TABS : []),
];
```

- `TabBarType` 需新增 `DISCOVER` / `FORMULAE` / `CASKS`
- `sys.symbol.*` 图标名需在 symbol 库核对
- 旧入口建议加后缀（如「组件（旧）」）避免与 Mine/我的 混淆
- `HomeView.ets` 需为新 tab 增加 TabContent 与 `tabController.bindScroller(...)` 绑定（现有 4 个 scroller 的模式可比照）

---

## 4. 模块划分

现有模块必须原样保留（作为对照），因此新内容放**新模块**：

```
features/
├── abilitycommon      ← 改：TABS_LIST + HomeView 增加新 TabContent + 临时开关
├── commonbusiness     ← 不动（新模块直接复用 BaseHomeView/BaseHomeViewModel）
├── common             ← 扩展：TriggerEnums 新增 trigger；mockdata 新增 brew/*
├── componentlibrary   ┐
├── devpractices       ├ 全部保留作为对照，收尾删除
├── exploration        │
├── mine               ┘
└── (新增)
    ├── brewcommon     Homebrew 领域模型 / Mock 解析 / 分类器 / brew 命令生成器
    ├── brewdiscover   Discover tab（复用 exploration UX 骨架）
    ├── brewformulae   Formulae tab（复用 componentlibrary UX 骨架）
    └── brewcasks      Casks tab（复用 devpractices UX 骨架）
```

依赖关系：

```
brewdiscover / brewformulae / brewcasks
    → brewcommon + commonbusiness + common
abilitycommon
    → brewdiscover + brewformulae + brewcasks + (legacy 四模块)
```

---

## 5. Formulae 内容规划

### 5.1 内容单元
`Formula` —— 一个 CLI 包。列表卡片字段：图标/首屏图、名称、`desc`（英文）、版本、`license`、安装量（热度）、`NEW` 标签。

### 5.2 分类体系（8 类）

| # | 分类（中文 UI 名） | 代表包 |
|---|---|---|
| 1 | 终端与 Shell 增强 | `zsh` `fish` `starship` `fzf` `ripgrep` `fd` `bat` `eza` `zoxide` `tmux` |
| 2 | 开发工具链 | `git` `gh` `node` `python@3.12` `go` `rust` `openjdk` `cmake` `uv` |
| 3 | 网络与传输 | `wget` `curl` `httpie` `aria2` `rsync` `nmap` `mtr` `speedtest-cli` |
| 4 | 数据与数据库 | `postgresql@16` `mysql` `redis` `sqlite` `duckdb` `jq` `yq` |
| 5 | 容器与云原生 | `kubectl` `helm` `k9s` `kind` `minikube` `terraform` `awscli` `azure-cli` `colima` |
| 6 | 媒体与图像 | `ffmpeg` `imagemagick` `yt-dlp` `sox` `exiftool` `gifsicle` |
| 7 | AI 与机器学习 | `ollama` `llama.cpp` `whisper-cpp` `poetry` `huggingface-cli` |
| 8 | 系统与运维 | `htop` `btop` `ncdu` `dust` `tree` `coreutils` `gnu-sed` `watch` `mas` |

外加两个非分类入口（用 `styleType 3` 纯图卡做运营位）：
- **本周热门**：按 `analytics.install_on_request.30d` 排序
- **新收录**：官方 API 无此字段，需自建 API 快照 diff 或人工维护

### 5.3 详情页结构（**复用性价比最高的一处**）

现有组件详情 = 属性面板（`AttributeChangeArea`）+ 预览（`previewComponentBuilder`）+ 代码生成（`CommonCodeGenerator`）+ 代码高亮 Web 页。映射到 Homebrew：

| 现有概念 | Formulae 对应 |
|---|---|
| `props[]`（`displayType` 驱动控件） | **安装选项** |
| `AttributeTypeEnum.TOGGLE` | `--HEAD`、`--build-from-source` |
| `AttributeTypeEnum.SELECT` | `--formula` 单选、`--cc=clang/gcc` |
| `CommonCodeGenerator.generate()` | **生成 `brew install` 命令**（把 ArkTS 换成 shell） |
| `CodePreviewView`（Web 高亮） | 高亮 shell 命令 + 一键复制 |
| `recommendList` | 同类推荐 / `deprecation_replacement_formula` 替代品 |
| `descriptor` | 依赖树可视化、bottle 可用架构表 |

> ~~结论：`componentlibrary` 的整条引擎可几乎零改动地改造成「brew 命令生成器」~~
>
> **该结论已于后续评估中推翻（见 `brew-api-design.md` §5）。** 原因：官方 API 的 `options` 字段实测恒为空，
> 没有真实数据支撑交互式安装选项面板；且引擎要求 `previewComponentBuilder` / `descriptor` 两个必填槽位，
> 而 brew 没有可实时预览的组件。**最终决定：详情页另起一个页面，按典型应用市场布局用官方组件实现，
> 安装命令区只展示基础命令 + 复制按钮。** 首页/列表仍复用 `BaseHomeView` 骨架。

详情页 Tab 建议：
`概览(desc/版本/许可/热度) | 安装命令(交互) | 依赖(依赖树+反向依赖) | 瓶子与平台 | 变更(版本历史)`
顶部按需展示 `deprecated` / `disabled` 警示条 + 替代品跳转。

---

## 6. Casks 内容规划

### 6.1 内容单元
`Cask` —— 一个 GUI 应用。卡片字段：应用图标 + 截图（`styleType 4` 大卡或 `3` 纯图卡）、名称（`name[]`）、`desc`（英文）、`version`、`auto_updates` 徽标。

### 6.2 分类体系（8 类）

| # | 分类（中文 UI 名） | 代表 cask |
|---|---|---|
| 1 | 开发与 IDE | `visual-studio-code` `cursor` `zed` `intellij-idea` `sublime-text` `android-studio` |
| 2 | 浏览器 | `google-chrome` `firefox` `arc` `brave-browser` `microsoft-edge` `zen` |
| 3 | 效率与笔记 | `raycast` `alfred` `rectangle` `obsidian` `notion` `logseq` |
| 4 | 通讯与协作 | `slack` `discord` `zoom` `telegram` `wechat` `feishu` |
| 5 | 设计与创意 | `figma` `sketch` `affinity-designer` `blender` `krita` `pixelmator-pro` |
| 6 | 音视频 | `iina` `vlc` `handbrake` `obs` `audacity` `spotify` |
| 7 | 系统工具 | `iterm2` `warp` `ghostty` `appcleaner` `stats` `keka` `balenaetcher` |
| 8 | AI·虚拟机与容器 | `chatgpt` `claude` `lm-studio` `jan` / `docker` `orbstack` `utm` `parallels` |

### 6.3 详情页结构
复用 `BaseDetailComponent` + `ImagePreview`：

`应用截图画廊 | 安装内容(artifacts: app/pkg/binary/font 分类列出) | 系统要求(depends_on.macos/arch) | 依赖的 formula/cask | 卸载与清理(zap 路径) | 命令生成`

需特别展示 Homebrew 独有的三类状态：
- `auto_updates: true` → 「应用会自我更新，brew 无法管理其版本」
- `depends_on.cask` 链（如装 `docker` 会连带 `docker-desktop`）
- `deprecated` / `disabled` + 替代品跳转

---

## 7. Discover 内容规划

> **数据口径以 `docs/brew-discover-algo.md` 为准**（现网推荐算法的唯一权威来源）。
> 本节只负责 Discover 的**内容分组与版式**；"哪些包、什么顺序、带哪些字段"由那份文档定义。
> 其中「榜单速递」的 `analytics.install_on_request.30d` 与该文档 §2 的"全程统一口径"一致。
>
> **版式已定（落地实现见 `docs/brew-api-design.md` §13）**：不做下面这套 `styleType 1/2/4` 分组，
> 改成**复用 Formulae/Casks 首页那套 `WaterFlow + 大卡`骨架**（即侧边栏"组件"页首页的 UX），
> 一张卡 = 一张榜，共 6 张（Formulae / Casks × 趋势 / 历史 / 新星），卡内预览 5 条 + 「查看全部」进二级页。
> 卡片的两个视觉锚点由需求方指定：外壳与行列表照「常用组件 - 按钮、图片、进度条等」那张卡，
> 卡内大图区照「图库选择器 - PhotoPicker - 安全选择图库」那张卡（图片换成代码画的渐变块 ——
> Homebrew 没有任何可用图标/截图素材）。
>
> 下表的分组口径仍然有效（榜单速递 / 上新与变更 / 上手教程 / 迁移与避坑），
> 但前两组的**呈现方式**改为上面这套大卡，后两组（离线 HTML 文章）本轮未做。

直接复用 `discovery-page.json` 的 `{ bannerInfos[], discoveryData[] }` 结构（`styleType 1/2/4` 分组）。内容分 4 组：

| 分组 | 内容类型 | 数据来源 | 卡片形态 |
|---|---|---|---|
| **榜单速递** | 本周热门 Formula / Cask Top 10 | `analytics.install_on_request.30d`（**现已真实接入**：设备端拉 4 个聚合端点现算，见 `brew-discover-algo.md` §7 / `brew-api-design.md` §7.4.1） | styleType 4（图+标题+排名徽标） |
| **上新与变更** | 新收录包、重要版本升级、breaking change | 自建 API 快照 diff | styleType 2（密集列表） |
| **上手教程** | 「Homebrew 快速上手」「如何写第一个 Formula/Cask」「Bottle 是什么」 | 离线 HTML，复用 `resfile/articlecols/**` | styleType 1 |
| **迁移与避坑** | 「从 iTerm2 迁移到 Ghostty」「`cask-fonts` 迁移到 `font-*`」「deprecated 包如何替换」 | 离线 HTML | styleType 1 |

顶部 `bannerInfos`（3–4 张）做运营位。
`BannerTypeEnum` 现有 `COMPONENT/SAMPLE/ARTICLE`，建议新增 `FORMULA/CASK`，让 banner 能直跳包详情。

---

## 8. Mine 内容规划（本机软件包）

现有 `MinePageState` 已是 `ListGroup[] → MineItem[]` 结构，`MineItem` 支持
`textContent / subTextContent / symbolSrc / showTotalNum / totalNumType / builder / onclick` —— 正好承载本机包视图。

```
[顶部环境卡]  可替换现有账号卡：macOS 版本 · 芯片(arm64/x86_64) · brew 版本 · brew --prefix
[组1 概览]    已安装 Formulae (N) │ 已安装 Casks (N) │ 可升级 (N) │ 占用空间
[组2 管理]    Formulae 列表 → Casks 列表 → 可升级 → Taps → Services
[组3 维护]    brew doctor 自检 │ 清理缓存 │ 自动移除孤立依赖 │ 更新索引
[组4 其他]    设置 │ 关于 │ 公告 │ 反馈        ← 完全保留现有
```

- 「可升级」徽标：复用 `showTotalNum` + `totalNumType`，`NumTypeEnum` 新增 `UPGRADABLE`
- 已装列表项：名称 + 版本 + `installed_on_request` / `installed_as_dependency` 区分 + 卸载/升级操作
- 可新增 `BuilderEnum` 值承载「依赖树」与「占用空间条形图」卡片
- 纯 Mock，Service 层预留接口

---

## 9. 关键词聚类器设计

新增于 `features/brewcommon`。

### 9.1 输入信号（按精度从高到低）

| 优先级 | 信号 | 说明 |
|---|---|---|
| 1 | **override 表**（`token → categoryId`） | 精选集里语义明确的包直接指定，短路后续逻辑 |
| 2 | **token 命名模式** | 正则，如 `^python@` / `^openjdk@?` / `^postgresql@` / `^mysql` / `^node@` |
| 3 | **`desc` 关键词加权打分** | 主信号。`desc` 为英文短语（如 `gh` = "GitHub's official command line tool"） |
| 4 | **`dependencies` 推断** | 弱信号，低权重。如依赖含 `ffmpeg` → 媒体类倾向 |
| 5 | `homepage` 域名 | 极弱，如 `jetbrains.com` → 开发 IDE |

### 9.2 打分算法

```
归一化:  小写、去标点、切词
权重:    w(k) = 3  若 k 出现在 desc 前 3 个词内   ← 英文 desc 语义重心在前部
               = 1  其他位置
打分:    score(c) = Σ w(k),  k ∈ tokens ∩ lexicon[c]
短路:    override 命中 → 直接返回；token 正则命中 → +10 后短路
判定:    top1 - top2 >= 2 且 score(top1) >= 2  →  归入 top1
         否则  →  归入「其他」并写入「人工复核队列」
```

### 9.3 分类词表草案（Formulae，判别性强的放前面）

| 分类 ID | 关键词 |
|---|---|
| terminal | shell, prompt, completion, multiplexer, fuzzy finder, pager, syntax highlight, zsh, fish, tmux, direnv |
| devtools | compiler, toolchain, version manager, sdk, jdk, build system, linter, formatter, package manager, vcs, git |
| network | download, http, proxy, ssh, ftp, torrent, dns, traceroute, port scan, bandwidth |
| data | database, sql, key-value, cache, query, etl, json processor, yaml, csv |
| cloudnative | kubernetes, container, helm, cluster, cloud, terraform, infrastructure as code, serverless |
| media | image, video, audio, codec, encode, transcode, resize, subtitle, ocr |
| ai | machine learning, neural, large language model, inference, embedding, vector, gpu |
| system | system monitor, disk usage, backup, benchmark, performance, monitoring, encryption, cleanup |

**必然冲突项（需 override 明确）**：`curl`/`wget`（网络 vs 开发）、`jq`/`yq`（数据 vs 系统）、`git`（开发 vs 版本控制）、`ollama`（AI vs 开发）、`mas`/`coreutils`（系统）、`ffmpeg`（媒体，但常作依赖）。

### 9.4 Casks 的特殊性

所有 cask 按定义都是 GUI 应用，分类维度是**应用领域**而非类型。额外可用信号（比 formula 更准）：
- `name[]`（应用显示名，可直接用于展示）
- `artifacts[].app` / `artifacts[].pkg` → 安装形态
- `auto_updates` → 自我更新徽标

### 9.5 质量保障（精选集只有 ~200，可做严）

1. 人工维护 `expected-category.json` 金标准（200 条），分类器跑批断言 → 放进 `features/brewcommon/src/ohosTest/`，随构建回归
2. 分类器输出附带 `confidence` 与 `matchedKeywords`，低置信度条目导出「复核队列」
3. `overrides.json` 与 `lexicon.json` 分离 —— **后期替换为 brew-discover 分类只需换这两个文件，不动代码**
4. `lexicon.json` 只存 `categoryId + 英文关键词`；**中文分类名放 `string.json`**（见 §12）

---

## 10. 精选包配额表

| Formulae（~100） | 数量 | Casks（~100） | 数量 |
|---|---|---|---|
| 终端与 Shell 增强 | 14 | 开发与 IDE | 14 |
| 开发工具链 | 16 | 浏览器 | 10 |
| 网络与传输 | 12 | 效率与笔记 | 12 |
| 数据与数据库 | 12 | 通讯与协作 | 12 |
| 容器与云原生 | 14 | 设计与创意 | 12 |
| 媒体与图像 | 10 | 音视频 | 12 |
| AI 与机器学习 | 10 | 系统工具 | 14 |
| 系统与运维 | 12 | AI·虚拟机与容器 | 14 |
| **合计** | **100** | **合计** | **100** |

每类 10–16 个，可撑满 `styleType 1/2/3` 三种分类卡布局，也足够测分页（`pageSize` 建议 20 → 每类一页、全量 5 页）。

---

## 11. 数据落地

### 11.1 trigger 与 mock 文件

| trigger（`TriggerEnums` 新增） | mock 文件 | 对齐现有 |
|---|---|---|

> **现状（2026-09）**：`formula/cask-page` 与 `formula/cask-details` 四组 trigger 与文件**都已删除** ——
> 分类与成员改由设备端用目录 + 词表现算，详情骨架用现网单条 + 词表（见 `brew-api-design.md` §7.4.1）。
> 下表保留初稿口径供对照。
| ~~`formula-page`~~ | ~~`brew/formula-page.json`~~ | —— |
| ~~`formula-details`~~ | ~~`brew/formula-details.json`~~ | —— |
| ~~`cask-page`~~ | ~~`brew/cask-page.json`~~ | —— |
| ~~`cask-details`~~ | ~~`brew/cask-details.json`~~ | —— |
| `brew-discovery-page` | `brew/discovery-page.json` | `discovery-page.json`（或直接复用） |
| `installed-formulae` | `brew/local-formulae.json` | `new-contents.json` |
| `installed-casks` | `brew/local-casks.json` | 同上 |
| `brew-outdated` | `brew/local-outdated.json` | 同上 |
| `brew-taps` | `brew/local-taps.json` | 同上 |
| `brew-services` | `brew/local-services.json` | 同上 |

### 11.2 详情 JSON 字段策略

**保留 Homebrew API 原生字段名**（`token` / `desc` / `homepage` / `license` / `dependencies` / `keg_only` / `bottle` / `artifacts` / `depends_on` / `deprecated` / `disabled`），
这样未来接真实 API 时**解析层零改动，只换 Service 实现**。

### 11.3 模型继承现有基类

```typescript
// 继承 BaseData → id/title/subTitle/version/sequence/contentType
export class FormulaCardData extends BaseData {
  public styleType: CardStyleTypeEnum = CardStyleTypeEnum.PICTURE_ABOVE_LIST;
  public image: string = '';                        // 图标
  public themeColor: string = '';
  public formulaContents: FormulaContent[] = [];    // 对应 componentContents
}

export class FormulaContent extends BaseData {
  public formulaCardId: number = 0;
  public token: string = '';        // brew 名，如 'ripgrep'
  public desc: string = '';         // 英文原文
  public license: string = '';
  public installs30d: number = 0;   // analytics.install_on_request.30d
  public deprecated: boolean = false;
  public tagIds: TagEnum[] = [];    // 复用 TagEnum.NEW
}
```

### 11.4 Mock 生成脚本

实测本环境网络可用（`ohpm install` 曾成功拉取远端包），因此生成脚本可**直接抓单条接口**
（`/api/formula/<name>.json`、`/api/cask/<token>.json`）——200 次单条请求，避开 `formula.json` 的数十 MB 全量包。

脚本建议位置：`hmosword-build/brew-mockgen/`（与现有 sample 注入脚本同处）。

---

## 12. 文案与 i18n 策略

**决策：英文原文 + 中文 UI。** 即 mock JSON 只存英文 `desc`，不引入 `descZh`。

需要**新增的中文文案**（全部走 `$r('app.string.*')`）：

| 类别 | 内容 |
|---|---|
| 侧边栏 | 发现 / Formulae / Casks / 我的（+ 旧入口后缀） |
| 分类名 | Formulae 8 个 + Casks 8 个 |
| 详情字段标签 | 版本 / 许可 / 主页 / 安装量 / 依赖 / 被依赖 / 安装选项 / 安装内容 / 系统要求 / 自动更新 / 可执行路径 |
| 状态词 | 已安装 / 未安装 / 可升级 / 已废弃 / 已停用 / 构建方式（bottle / 源码构建） |
| 榜单标签 | 本周热门 / 新收录 / Top 10 |
| Mine | 全部分组名与操作名（见 §8） |
| 搜索入口 | 「搜索功能开发中」 |

注意事项：
- `lexicon.json` **只放 categoryId 与英文关键词**，中文名放 `string.json`，避免中英混排失控
- 英文 `desc` 长短不一 → 卡片需 `maxLines` + ellipsis，可复用现有 `common/src/main/ets/util/TextOverflowUtil.ets`
- 无中文时**不做机器翻译**，直接展示英文原文

---

## 13. 搜索预留方案（本轮不实现）

| 层 | 预留内容 |
|---|---|
| UI | 三个 tab 首页标题栏右侧放搜索图标，点击 Toast「搜索功能开发中」 |
| Service | `brewcommon` 内定义 `BrewSearchService.search(keyword, type, page): Promise<PageData<T>>`，本轮返回空 `PageData` |
| 数据 | 无需新 trigger —— 未来本地搜索只需在已加载的 `FormulaContent[]` / `CaskContent[]` 上过滤 |
| 路由 | **不新增** `PageEnum` 常量与路由（避免死代码；HDS 未注册路由时 `pushPath` 会报错） |

---

## 14. 复用映射总表

| 新增能力 | 复用的现有实现 | 改动量 |
|---|---|---|
| 分类大卡首页 | `commonbusiness/BaseHomeView` + `BaseHomeViewModel` + `BaseHomeState` | 换 Model/Service + 卡片字段映射 |
| 包详情「属性→命令」交互 | `componentlibrary` 的 `AttributeChangeArea` + `AttributeTypeEnum` + `CommonDescriptor` | 中（CodeGenerator 输出改 shell） |
| 命令高亮展示 | `componentlibrary/view/CodePreview.ets` + `resfile/commonDist/index.html` | 小（换语法高亮语言） |
| 文章详情 / 分享 | `exploration/view/ArticleDetailView` + `common/ShareUtil` | 几乎不动 |
| 大图预览 | `devpractices/view/ImagePreview` | 几乎不动 |
| 分组设置列表 | `mine` 的 `ListGroup` / `MineItem` / `BuilderEnum` | 小（加枚举值） |
| 状态视图 | `common/view/`（Loading / LoadingFailed / NoNetwork / EmptyContent） | 不动 |
| Banner 轮播 | `commonbusiness/BannerCard` + `BannerSource` | 小（`BannerTypeEnum` 加值） |
| 图片加载与预加载 | `common/util/ImageKnifeUtil`（`@ohos/imageknife`） | 不动 |
| Mock 数据通道 | `common/storagemanager/MockRequest` + `responseData` + `PreferenceCacheHelper` | 不动 |
| 模糊标题栏 / 大卡片视觉 | `@kit.UIDesignKit`（`HdsNavDestination` / `HdsTabs` / `hdsMaterial`） | 不动 |

---

## 15. 收尾删除清单（开发结束后执行）

1. `LEGACY_TABS_ENABLED` 改 `false`
2. 删除 `features/{componentlibrary,devpractices,exploration,mine}` 四个目录
3. `TabBarModel.ets` 里删除 `LEGACY_TABS` 与开关
4. `HomeView.ets` 里删除 4 个 legacy TabContent 与 scroller 绑定
5. 删除对应 `router_map.json` 条目（16 条中删 13 条）
6. `PageEnum.ets` 清理相关常量（含已失效的 `TV_*` / `WEARABLE_*`）
7. 删除 `common/src/main/resources/rawfile/mockdata/` 中 component-* / sample-* / discovery-* 等
8. `features/abilitycommon/Index.ets` 删除对应导出
9. 扫描并清理仅被 legacy 使用的组件：`common/src/main/ets/component/`、`commonbusiness`、`widgetcommon`

---

## 16. 风险与待办

| 项 | 说明 |
|---|---|
| 分类准确率 | 关键词聚类必然有误分类；靠 `overrides.json` + 金标准断言 + 复核队列控制 |
| `desc` 语义稀疏 | Homebrew `desc` 很短（常 3–8 词），单一关键词可能命中多类 → 依赖「前 3 词加权」+ 冲突项 override |
| 全量 API 体积 | 严禁下发 `formula.json` / `cask.json`；只做单条详情请求 |
| deprecated 包处理 | 精选集应尽量避开；但需保留展示能力（Homebrew 真实存在） |
| 图标版权 | 包图标来自各自官网，正式发布前需确认授权策略 |
| 数据来源署名 | 使用 formulae.brew.sh 数据需注明来源与许可 |
| `brew-discover` 对齐 | **待补仓库地址**：拿到后只需替换 `lexicon.json` + `overrides.json` |
| HarmonyOS 上读本机 brew | Homebrew 是 macOS/Linux 工具，HarmonyOS 本机不会真的装 brew → 本轮纯 Mock，未来需明确数据来源路径 |
