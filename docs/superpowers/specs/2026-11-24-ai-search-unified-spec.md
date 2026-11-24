# AI 搜索二期 · 统一 AI 搜索页（Brew Lens 应用内）设计

> 日期：2026-11-24。状态：已归档（暂缓实施，方案留档待排期）。
> 范围：`features/brewsearch` 改造为统一结果页（删除 `BrewAiFindCard`，新增理解条/示例槽/骨架/状态 chip 组件与命令解析·映射纯函数层）；`features/brewcommon` 的 `BrewPackageRow` 加可选槽；`hmosword-build/brew-search` 新增解析器检查脚本。
> 不做（round8 §10 阶段 2/3）：系统分享文本、选择菜单、轻量面板、OCR；也不做问包聊天面（phase2 落点 10 未决——「问 AI」续接落在详情页 D1 讲解，`BrewAiExplainCard` 已存在）；安装预演页本体由 J 的 spec 交付，本 spec 只锁接口。
> 依据：`docs/spec/2026-11-21-brainstorm/round8.md`（Brew Lens 阶段 1 = 本 spec 范围）、`round7.md`（AB 命令翻译 → 本页命令模式）、`2026-11-22-ai-companion-spec.md`（D2 管线 / G5 / G6 / G13）、`2026-11-23-ai-companion-phase2-spec.md`（落点 6 被本 spec 吸收）。
> UX 基准：Apple macOS HIG（Clarity / Deference / Depth）。**本 spec 的重点是 UX**：第 5 节以高分辨率 ASCII 线框给出每个状态的版式、字体、颜色与交互，工程节（3/7/9/10）为 UX 服务。

---

## 1. 目标与成功判据

一个搜索框接受三种输入——关键词、自然语言、安装命令——提交后进**同一个结果页**：理解条告诉你"我看懂了什么"，统一结果行回答 round8 4.3 的四问（它是什么 / 我的设备有吗 / 我装过吗 / 接下来能做什么），本机安装状态直接长在行上。**不是第二套搜索**：关键词模式的行为与现状完全一致，AI 与命令解析是同一页面的三种理解方式。

| # | 判据 | 可观测证据 |
| --- | --- | --- |
| G1 | 一个框三种输入：关键词 / 自然语言 / 安装命令提交后进同一结果页，无第二输入框、无第二套结果 UI | 真机 |
| G2 | 首页态 chips 槽 =「试试问我」示例（点击 = 填入并提交）；结果态同一槽换装为过滤 chips；**槽高 56vp 与让位数学零改动**（`topInset()` / `bottomBuilder.height` 公式不变） | 真机 + 代码评审 |
| G3 | 关键词模式与现状一致：即时、`共 N 个结果`、chips 只过滤不重算、历史照记（0 结果也记） | 真机 |
| G4 | 意图模式：骨架 3 行 → AI 提名行（`*` + why）+ 目录补足行（无 `*`）；B3 信任脚注含"已过滤 N 个未验证候选" | 真机 |
| G5 | 命令模式：理解条（生态 / 映射数 / 忽略行 / 展开审计表）+ 改名映射行 + 未确认灰行 + 批量按钮只收确认项 | 真机 |
| G6 | 全模式行内本机状态 chip（已安装 / 可升级），与详情页按钮同口径同语言（`BrewInstalledLoader` 只读快照）；快照未就绪不渲染 chip、不阻塞行 | 真机 |
| G7 | 降级：**离线词表删除**（`AiTaskWords` / wordlist 模式 / `fallbackNotice` 全清）；E1 → 本地引擎静默（不发请求、不引导配 Key，G6 语义）；E2/E3 → 本地引擎 + 一行降级条；E4/E5 → 错误条 + 重试；E6 取消静默 | 真机 + 构建 |
| G8 | 红线：用户粘贴的原始命令永不执行；AI 生成命令无执行入口（G13）；批量出口只交 J（预演语义，确认权在人） | 代码评审 |
| G9 | 未确认不以近似包名冒充：无 token 的行不可点、无 chevron、不入批量计划（round8 4.3） | 真机 + 代码评审 |
| G10 | pc_normal：AI 静默判未配（不发请求，本地引擎照常出结果），无报错无引导；双 product 构建通过 | `devecocli build` 双 product，ERROR 0 |
| G11 | 命令解析 / 映射纯函数检查脚本全绿（`hmosword-build/brew-search/check_command_parser.mjs`，用例见 §10） | node |
| G12 | 删除 `BrewAiFindCard` 后无残留引用；`ai_d2_*` 资源能复用的复用、弃用的清理 | 构建 |

## 2. 现状与并入事实

### 2.1 三个并入对象 → 一页纸现状

| 对象 | 现状 | 并入后 |
| --- | --- | --- |
| 搜索页（`features/brewsearch/view/BrewSearchResultView.ets`） | 模糊标题栏挂输入框 + chips（`BrewSearchResultView.ets:504-510`）；显式触发；三态内容区（历史发现 / 结果 List / 无命中） | **壳全部保留**：标题栏、让位数学、滚动根、返回键三分支、历史落盘全部不动；内容区换统一结果区 |
| AI 帮我找工具（`component/BrewAiFindCard.ets` + `viewmodel/AiFindVM.ets`） | 未提交态顶部一张独立卡：自己的输入框 + 示例 chips + 结果 List + 词表降级 | **卡删除**：输入并入主框，示例进 A3 槽，结果进统一行；`AiFindVM` 降为意图模式引擎（词表分支删除，§3.2） |
| Brew Lens 阶段 1（round8 §10） | 纸面：四输入共用识别管线 | 本 spec 落"关键词 / 自然语言 / 安装命令"三输入（分享文本属阶段 2，不做） |

### 2.2 既有护栏继承（不重写，只引用）

| 护栏 | 来源 | 本页表现 |
| --- | --- | --- |
| G5 目录外零展示 | ai-companion 一期 | AI 提名经目录成员过滤，丢弃数进 B3 脚注与 `[ai]` 日志 |
| G6 降级不引导配 Key | 同上 | 语义保留、载体更换：词表已删（G7），降级 = 本地引擎；E1 静默无条，E2/E3 一行 `brew_search_strip_degraded`，无配置入口 |
| G13 AI 生成命令永无一键执行 | 同上 | 本页不渲染任何可执行命令；批量出口 = J 的预演（只读 dry-run + 人类点头） |
| 显式触发（无防抖） | 搜索页现状 | 三种输入统一走 `searchNow()`：回车 / 点「搜索」/ 点任意建议 chip |
| BYOK / 15s 超时 / prompt≤8KB / D2 缓存 TTL 1 天 | ai-companion 一期 | 意图模式整链路复用，`promptVersion` 不动（输入仍是意图文本） |

### 2.3 关键既有事实（写死，防实施时再考）

- 让位数学三处同源：`topInset()`（`BrewSearchResultView.ets:205-208`）= `brewTitleBarTotalHeight(statusBarHeight)`（= 状态栏 + 标题行 56 + chips 行 56，`BrewConstants.ets:432`）+ `BREW_SEARCH_BAR_ROW_HEIGHT`(56) + `BREW_SEARCH_CHIP_ROW_GAP`(12)；`bottomBuilder.height`（`:509`）= 56 + 56 + 12 = 124。**本设计不动其中任何一个数**。
- `brew_search_row_height` = 64vp（`features/brewsearch/src/main/resources/base/element/float.json`）；`brew_search_suggestion_height` = 48vp；`brew_search_section_header_height` = 40vp。
- 行点击必须 `.onClick()` 挂组件调用上（`BrewSearchResultView.ets:386-393` 的教训：回调参数曾被静默丢弃）。
- 底色画在 `ListItem` 子节点上、首末行圆角拼一张卡（`:399-407`）；让位只能写占位项 / 内层 margin（`:335-348`）。
- `BrewInstalledLoader.installedOf(token)` 已存在（`BrewDetailViewModel.ets:222` 在用），返回 null / {outdated}——行状态 chip 与详情页按钮（`BrewDetailView.ets:230-245`：已安装 / 升级 / 安装）同源。
- J 装机预演：UI 未落地（decisions 第一梯队）；`BrewDryRunParser` 已存在（`features/brewcommon/src/main/ets/util/BrewDryRunParser.ets`，"与 J 落地时共用同一解析器"）。本 spec 的批量出口按能力开关门控（§5.5）。

## 3. 统一模型与数据流

### 3.1 路由：确定性优先，AI 只管模糊语义（round8 4.2 的落地次序）

```
submit(q)
  ├─ BrewSearchRouter.classify(q)（新，纯函数、离线、零 AI 成本）
  │    ├─ CMD ───► BrewCommandParser.parse(q)（新，纯函数：生态方言 / 包名提取 / 忽略行）
  │    │             └─► BrewCommandMapper.map(names)（新：改名映射表 + 同名目录查找 + tldr 别名链）
  │    │                   └─► CommandPlan{ items[], ignored[] }（confidence 分级见 §3.5）
  │    ├─ KEY ───► BrewSearchVM.search(q, state)（既有引擎，零改动）
  │    └─ INTENT ► AiFindVM.find(q)（既有 D2 管线：AI 提名 → 目录过滤 G5 → 引擎排序 → 补足）
  ▼
统一行模型 BrewSearchRow（扩展字段：matchKind / why / mappingNote / unconfirmed / installState）
  └─► BrewInstalledLoader.installedOf(token)（只读快照；未就绪 = 不渲染 chip，不阻塞行）
        └─► BrewSearchRowSource（LazyForEach 数据源机制不变，`BrewSearchRowSource.ets`）
```

分类规则（`BrewSearchRouter.classify`）：

1. **命令语法**：先剥 `sudo` / `env …` 前缀，按 `;` `&&` 换行切段；任一段命中已知生态的安装动词（`apt|apt-get install`、`dnf|yum install`、`pacman -S`、`zypper install`、`brew install`、`nix-env -iA`、`choco install`、`scoop install`、`winget install`、`snap install`、`flatpak install`、`apk add`）→ **CMD**；提取出 0 个包名（如只有 `apt update`）→ 回落 **KEY**（原串当关键词，行为可预期）。
2. **单段 ASCII 词**：trim 后 ≤48 字符、仅 `[A-Za-z0-9\-_@.+]`、无空格无 CJK（`ffmpeg`、`fd-find`、`node@18`）→ **KEY**（现状）。
3. **其余**（自然语言、中英混合、多词）→ **INTENT**：`AiFindVM.isConfigured()` 为 false 直接本地引擎 rank 意图原文（不发注定失败的请求，静默无降级条）；已配则骨架 → `AiTasks.findTools`。

不做逐键 AI、不做 0 命中关键词自动升意图（空态把路指出来，选择权在人，§5.6）。

### 3.2 三条管线共用同一出口

- **KEY**：`BrewSearchVM.search` 原样；`matchKind='none'`，行 = 现状解剖 + 状态 chip。
- **INTENT**：`AiFindVM.find`（AI ≤5 提名 → 目录过滤 → 引擎排序 → 不足 8 行用意图原文补足）；提名行 `matchKind='ai'` + `why`，补足行 `matchKind='recall'`。**词表分支删除**：28 词策展表覆盖不了真实意图长尾，而 rank 意图原文本就是补足通路——E1/E2/E3 降级 = 同一 rank 通路直接跑意图原文，行 `matchKind='none'`（与关键词模式同呈现，无 `*` 无脚注），0 行 → 统一空态；零新增数据、零新增代码路径。
- **CMD**：新纯函数层（§3.5）；确认行 `matchKind='command'`（改名时带 `mappingNote`），未确认行 `unconfirmed=true`。

### 3.3 统一行模型（`model/BrewSearchRowSource.ets` 扩展）

```ts
export class BrewSearchRow {
  item: BrewPackageItem;      // 现状
  kind: BrewKind;              // 现状
  matchKind: string;           // 'none' | 'ai' | 'recall' | 'command'（默认 'none'，既有调用点零改动）
  why: string;                 // AI 提名的中文理由（仅 matchKind='ai'）
  mappingNote: string;         // 'apt: fd-find -> brew: fd'（仅改名映射行）
  unconfirmed: boolean;        // 未确认行：无 token 详情可进，不可点、无 chevron
  installState: string;        // 'installed' | 'outdated' | ''（'' = 未安装或快照未就绪 = 留白）
}
```

### 3.4 本机状态合并

只读：`BrewInstalledLoader.installedOf(token)` → `installed`（`outdated=false`）/ `outdated` / null。不发命令、不触发刷新（快照新鲜度由既有机制管理，与详情页 `refreshInstallState` 同口径）。**未安装 = 留白**：不给每行刷一个"未安装"灰 chip——沉默即答案（macOS Deference）。

### 3.5 命令解析与映射（round7 AB 的落位，成本在数据不在文案）

- `BrewCommandParser.parse(q)` → `{ ecosystem, requests: string[], ignored: string[] }`：方言识别（不机械带入平台参数）、包名提取（剥选项 / 路径 / 引号）、非安装段（`apt update`）进 `ignored`（计数展示，不静默丢弃）。
- `BrewCommandMapper.map(requests)` 逐名分级：
  1. **同名已在目录**（`ripgrep`）→ confirmed，无映射行；
  2. **改名映射表命中**（`fd-find` → `fd`）→ confirmed，行带 `apt: fd-find -> brew: fd`；
  3. **别名链命中**（`rg` → `ripgrep`，tldr 候选名链）→ confirmed，映射行加注（命令 `rg`）；
  4. **其余** → `unconfirmed`：显示源名 + 灰行说明，**不以近似包名冒充**（G9）。
- 改名映射表 = `constant/BrewCommandNames.ets` 种子表（~20 条高频改名起步：`fd-find→fd`、`python3-pip→pip`…），未命中走 1/3/4 兜底——表小是诚实的，`未确认` 是默认答案而不是失败。

## 4. UX 设计原则（macOS → 本页规则）

| macOS 原则 | 本页的落法（可评审的规则，不是口号） |
| --- | --- |
| Clarity 清晰 | 排版三级即止：行 token（现状字体）/ 行 line2 与正文（Body_S）/ 理解条·脚注·hint（Body_S tertiary）。状态用"符号 + 短词"chip，不堆色块 |
| Deference 克制 | 界面退后：理解条是一行字不是横幅；**未安装 = 留白**；AI 徽标是 `*` 前缀不是彩色角标；无渐变、无新增品牌色，全部 sys token |
| Depth 层次 | 唯一材质层 = 既有毛玻璃标题栏（`brewBlurScrollEffect`），内容从 `~` 分界下透过；行卡 `comp_background_primary` 首末圆角拼卡（现状语言） |
| Progressive disclosure 渐进展开 | 理解条收起 = 一行摘要 + 按钮，展开 = 映射审计表；映射行只在改名时出现；过滤 chips 只在结果态出现 |
| Direct manipulation 直接操作 | 示例 chip 点击 = 填入 + 提交（教"同一个框也听中文"）；历史 / 发现 chip 同路；行点击直达详情 |
| Feedback 即时反馈 | 打字时命令识别 hint（确定性正则，零 AI 成本）；AI 骨架 3 行；降级条一行字（E2/E3）；B3 脚注报过滤数 |
| Consistency 一致 | 行 = 既有 `BrewPackageRow` 解剖加槽；`已安装` chip 与详情页按钮同语言（安静灰，`BrewDetailView.ets:297-301`）；让位数学零改动 |

## 5. 界面详设（ASCII 线框）

图例（纯 ASCII，宽度按 CJK=2 列对齐）：`o` 图标位 · `*` AI/sparkles · `?` 未确认 · `x` 清除 · `>` chevron_right · `v` chevron_down · `!` 警示 · `~` 毛玻璃分界 · `=` 骨架占位条 · `[ ]` chip / 按钮。

### 5.1 图 1 · 页面解剖与关键词结果态（A = 浮动标题栏，B = 滚动内容）

```
+----------------------------------------------------------------------------------------------+
| A1  搜索                                                                                     |
|                                                                                              |
|   +----------------------------------------------------------------------------------------+ |
|   |  o  ffmpeg                                                                   x    搜索 | |
|   +----------------------------------------------------------------------------------------+ |
| A3  [ 全部 ]  [ Formulae ]  [ Casks ]                                                        |
| ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ |
|                                                                                              |
| B1  共 12 个结果                                                                             |
|                                                                                              |
|     +-------------------------------------------------------------------------------------+  |
|     | o  ffmpeg                                                       [已安装]   1.2万   >|  |
|     |    录制、转换和流处理音视频                                                         |  |
|     |-------------------------------------------------------------------------------------|  |
|     | o  handbrake                                                               8,921   >|  |
|     |    开源视频转码工具                                                                 |  |
|     |-------------------------------------------------------------------------------------|  |
|     | o  wget                                                                   12,034   >|  |
|     |    从网络下载文件的工具                                                             |  |
|     +-------------------------------------------------------------------------------------+  |
|                                                                                              |
+----------------------------------------------------------------------------------------------+
  A  = 浮动标题栏（毛玻璃）：A1 标题行 + A2 统一搜索框 + A3 槽（首页态 = 示例 chips，
       结果态 = 过滤 chips；槽高恒 56vp，bottomBuilder.height 与 topInset() 公式零改动）
  ~  = 毛玻璃分界：内容钻到标题栏底下 brewBlurScrollEffect 才有效果（让位 = 首末占位项，现状机制）
  B1 = 理解条（首个滚动项，随内容滚走——信息不占视口，macOS Deference）
  B2 = 统一结果行 64vp 白底拼卡（现状语言）；B3 = 信任脚注（仅 AI 态，见图 4）
```

规格：A1/A2/A3 全部现状机制（`brewTitleBarStyle('search')` + `TitleBarBottomBuilder`）。B1 理解条 = 现状"共 N 个结果" ListItem 的原位升级（`BrewSearchResultView.ets:367-374`），Body_S tertiary。行右槽从左到右：状态 chip · 30 天安装量（`compactCount` 现状）· chevron。

### 5.2 图 2 · 首页态（未提交：示例 / 历史 / 发现）

```
+----------------------------------------------------------------------------------------------+
| 搜索                                                                                         |
|   +----------------------------------------------------------------------------------------+ |
|   |  o  搜索包名、描述需求或粘贴安装命令                                                   | |
|   +----------------------------------------------------------------------------------------+ |
|   [ * 我想批量压缩图片 ]  [ 录屏 ]  [ 查看端口占用 ]                                         |
| ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ |
|                                                                                              |
|    搜索历史                                                                        清空  v   |
|    [ ffmpeg ]  [ node ]  [ ripgrep ]  [ wget ]  [ docker ]                                   |
|                                                                                              |
|    搜索发现                                                                        换一批    |
|    o ffmpeg                                  o wget                                          |
|    o node                                    o git                                           |
|                                                                                              |
+----------------------------------------------------------------------------------------------+
  首页态 = appliedKeyword 为空或与框内字不一致（showingSuggestions() 现状语义不变）
  A3 槽换装为「试试问我」示例 chips：点击 = 填入 + 提交（原 D2 示例行为）；每 chip 带 * 前缀
  历史 / 发现 = 现状 BrewSearchSuggestions 原样保留（真实数据、清空 / 折叠 / 换一批不变）
  BrewAiFindCard 整卡删除：它的输入 = A2，它的示例 = A3 槽，它的结果 = 统一行
```

规格：placeholder 换统一文案（§8 `brew_search_placeholder_unified`）——**这是三种输入的第一教学面**。示例 chips 沿用 D2 三例（`我想批量压缩图片 / 录屏 / 查看端口占用`）， tertiary 胶囊 + `*` sparkles 前缀（`sys.symbol.sparkles`，编译校验）。历史 chip 文案超 16 字符截断加省略号（落盘仍存全文）。

### 5.3 图 3 · 统一搜索框与输入即时反馈（zoom）

```
    <----------------------- 搜索框宽 = 内容区宽 - 2 x contentInset ----------------------->
   +------------------------------------------------------------------------------------------+
   |  o   搜索包名、描述需求或粘贴安装命令                                                    |
   +------------------------------------------------------------------------------------------+
     空态：placeholder(font_tertiary)；40vp 高；comp_background_tertiary；圆角 level4

   +------------------------------------------------------------------------------------------+
   |  o   sudo apt install ffmpeg ripgrep                                     x        搜索   |
   +------------------------------------------------------------------------------------------+
      -> 识别到 Ubuntu 安装命令，回车开始解析        <- hint：确定性正则命中才出现，零 AI 成本

   +------------------------------------------------------------------------------------------+
   |  o   我想批量压缩视频                                                    x        搜索   |
   +------------------------------------------------------------------------------------------+
     （自然语言无 hint —— 不做逐键 AI；回车后由理解条接管）
```

规格：`BrewSearchBar.ets` 两处改动——placeholder 资源替换；有字时右侧新增 `x` 清除钮（`sys.symbol.xmark`，icon_tertiary，点击只清字不提交 → 回首页态，与返回键"栈底有字清空"同语义）。`搜索` 蓝字与 Divider 现状保留。hint 行 = 首页态内容区首行（NoRowsScrollBuilder 顶部条件渲染，Body_S tertiary），命中 `BrewCommandParser` 的语法探测（不解析、只探测生态名）；关键词 / 意图输入无 hint（沉默）。

### 5.4 图 4 · 意图结果态：骨架 → AI 结果（两帧）

```
+----------------------------------------------------------------------------------------------+
| 搜索                                                                                         |
|   +----------------------------------------------------------------------------------------+ |
|   |  o  我想批量压缩视频                                                         x    搜索 | |
|   +----------------------------------------------------------------------------------------+ |
|   [ 全部 ]  [ Formulae ]  [ Casks ]                                                          |
| ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ |
|                                                                                              |
|     +-------------------------------------------------------------------------------------+  |
|     |  (o)  ===========================                                                   |  |
|     |       ============================================                                  |  |
|     |-------------------------------------------------------------------------------------|  |
|     |  (o)  ===========================                                                   |  |
|     |       ============================================                                  |  |
|     |-------------------------------------------------------------------------------------|  |
|     |  (o)  ===========================                                                   |  |
|     |       ============================================                                  |  |
|     +-------------------------------------------------------------------------------------+  |
|                                                                                              |
+----------------------------------------------------------------------------------------------+
  T+0s 骨架：3 行（=brew_search_row_height 同高），tertiary 圆角条，透明度 0.4-0.8 缓动；
  无转圈无文案 —— 安静等待（15s 超时上限与 D2 一致；E6 取消静默回首页态）

+----------------------------------------------------------------------------------------------+
| ... 标题栏同上 ...                                                                           |
| B1  * 为你找到 5 个工具                                                                      |
|     +-------------------------------------------------------------------------------------+  |
|     | o  ffmpeg                                                       [已安装]   1.2万   >|  |
|     |    * 支持批量转码、压缩与格式转换                                                   |  |
|     |-------------------------------------------------------------------------------------|  |
|     | o  handbrake                                                               8,921   >|  |
|     |    * 图形界面批量压缩，对新手友好                                                   |  |
|     |-------------------------------------------------------------------------------------|  |
|     | o  imagemagick                                                            21,345   >|  |
|     |    * 命令行批量缩放、压缩与格式转换图片                                             |  |
|     |-------------------------------------------------------------------------------------|  |
|     | o  patool                                                                  3,210   >|  |
|     |    多格式压缩包解包工具                                                             |  |
|     +-------------------------------------------------------------------------------------+  |
| B3  * AI 提名 / 本地排序 / 已过滤 2 个未验证候选                                             |
+----------------------------------------------------------------------------------------------+
  提名行 line2 = "* why"（sparkles 前缀 + AI 理由，font_secondary）；补足行 line2 = 目录 desc（无 *）
  两种行的来历由 B3 脚注一句话讲清 —— 匹配依据可见（round8 4.6），但不给每行挂彩色角标
```

规格：`AiFindVM` 管线零改动（提名 ≤5 → 目录过滤 G5 → 引擎排序 → 原文补足至 8）。B1 = `* 为你找到 %d 个工具`；B3 = 信任脚注（过滤数来自目录过滤的丢弃计数，进 `[ai]` 日志）。骨架 = 新组件 `BrewSearchSkeleton`（3 行，行高同 64vp，`=` 条 = `comp_background_tertiary` 圆角 level4）。

### 5.5 图 5 · 命令结果态：理解条（收起 / 展开）+ 映射行 + 未确认行 + 批量出口

输入：`sudo apt update; sudo apt install git fd-find ripgrep xyztool`

```
+----------------------------------------------------------------------------------------------+
| 搜索                                                                                         |
|   +----------------------------------------------------------------------------------------+ |
|   |  o  sudo apt update; sudo apt install git fd-find ripgrep xyztool            x    搜索 | |
|   +----------------------------------------------------------------------------------------+ |
|   [ 全部 ]  [ Formulae ]  [ Casks ]                                                          |
| ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ |
|     +-------------------------------------------------------------------------------------+  |
|     | * 识别到 Ubuntu 安装命令，3 个包已映射                  [ 加入安装预演 3 个包 ]     |  |
|     |   已忽略 1 行非安装命令（apt update）                              展开 v           |  |
|     +-------------------------------------------------------------------------------------+  |
|     +-------------------------------------------------------------------------------------+  |
|     | o  git                                                         [已安装]   45,678   >|  |
|     |    分布式版本控制系统                                                               |  |
|     |-------------------------------------------------------------------------------------|  |
|     | o  fd                                                                      9,821   >|  |
|     |    apt: fd-find -> brew: fd                                                         |  |
|     |-------------------------------------------------------------------------------------|  |
|     | o  ripgrep                                                                33,201   >|  |
|     |    更快的 grep，命令为 rg                                                           |  |
|     |-------------------------------------------------------------------------------------|  |
|     | ?  xyztool（apt）                                                           [未确认]|  |
|     |    未在本地目录找到可靠对应，不猜测                                                 |  |
|     +-------------------------------------------------------------------------------------+  |
+----------------------------------------------------------------------------------------------+
  理解条 = 唯一带按钮的卡片（comp_background_primary 圆角 level8）：一行摘要 + 忽略行说明
  批量按钮；点「展开 v」原地展开审计表（下行），再点收起 —— 证据按需展开（渐进展开）
```

展开态（同一张卡原地长高，spring 300ms）：

```
|     | * 识别到 Ubuntu 安装命令，3 个包已映射                  [ 加入安装预演 3 个包 ]     |  |
|     |   apt 包名           brew 包名          状态                                        |  |
|     |   git                git                [已安装]                                    |  |
|     |   fd-find            fd                 [可升级]                                    |  |
|     |   ripgrep            ripgrep            未安装（留白）                              |  |
|     |   xyztool            --                 [未确认]                                    |  |
|     |   已忽略 1 行非安装命令（apt update）                              收起 ^           |  |
```

规格：

- **批量按钮**只收确认项（计数 = confirmed 数），点击把 `CommandPlan` 交给 J 的预演入口（接口：`BrewSearchCommandPlan { items: [{ sourceEcosystem, sourceName, token, kind, confidence, installState }] }`）。J 未落地期间 `BrewInstallPreview.available()` = false → **按钮不渲染**（不置灰——不留死 UI）；J 落地即出现。**永不执行**用户粘贴的原始命令（G8/G13）。
- **映射行**只在改名 / 别名时出现（`apt: fd-find -> brew: fd`）；同名映射不显示（理解条的"3 个包已映射"即证据——沉默 = 已验证同名）。
- **未确认行**：`?` 图标 + 源名 + `[未确认]` chip + 说明行；无 chevron、不可点、不入计划（G9）。
- 生态名（Ubuntu / Debian / Arch / Fedora…）由方言推断，展示在理解条；推断不出显示"安装命令"。

### 5.6 图 6 · 空态 / 降级 / 错误态

```
+--------------------------------------------------------------------+
|                                                                    |
|                          没有找到相关包                            |
|        试试换个关键词，或描述你想完成的任务                        |
|                                                                    |
+--------------------------------------------------------------------+
  空态（关键词 0 命中）：不自动改跑 AI —— 把另一条路指出来，选择权在人
  空态（意图 0 命中，AI 返回或本地降级后）：同一份文案，不区分来源

+--------------------------------------------------------------------+
|  * AI 连接失败，已显示本地结果                                     |
|  ------------------------------------------------------------      |
|   o  handbrake      开源视频转码工具         8,921   >             |
|   o  imagemagick    命令行图片处理           21,345   >            |
+--------------------------------------------------------------------+
  降级态（E2/E3 网络 / 超时）：理解条一行降级文案（warning 色，替代计数行）；
  本地引擎直接 rank 意图原文（与 AI 管线的补足通路同一机制），结果照常可点；
  E1（未配 Key / pc_normal）：无任何条，静默出本地结果，不引导配 Key（G6）

+--------------------------------------------------------------------+
|  ! AI 暂时不可用（结果解析失败）                                   |
|     [ 重试 ]                                                       |
+--------------------------------------------------------------------+
  错误态（E4/E5）：理解条 = 错误文案 + 重试；重试 = 同词重跑意图管线；
  框就在头顶 —— 用户随时可改词重搜，不需要第二个出口
```

### 5.7 图 7 · 状态机

```
HOME（未提交态：示例 chips / 搜索历史 / 搜索发现）
  │  submit(q)：回车 / 点「搜索」/ 点示例·历史·发现 chip（显式触发，现状不变）
  ▼
ROUTER · classify(q) —— 纯确定性、离线、零 AI 成本（新：BrewSearchRouter）
  ├─ 命中安装命令语法（apt / apt-get / dnf / yum / pacman -S / zypper / brew /
  │  nix-env / choco / scoop / winget / snap / flatpak / apk …，sudo/env 前缀先剥离）
  │    ├─ 提取到 >= 1 个包名 ────────────────────────► CMD 命令模式（即时，离线可跑）
  │    └─ 提取到 0 个包名 ──────────────────────────► 回落 KEY（原串当关键词）
  ├─ 单段 ASCII 词（<=48 字符，仅 [A-Za-z0-9\-_@.+]，无空格无 CJK）──► KEY 关键词模式（=现状）
  └─ 其余（自然语言 / 中英混合 / 多词）─────────────► INTENT 意图模式
       ├─ 未配 Key（isConfigured()=false，含 pc_normal）──► LOCAL 本地引擎（即时，静默）
       └─ 已配 Key ──► 骨架 3 行 ──► AiTasks.findTools（15s 超时，E6 可取消）
            ├─ 成功 ────► AI 结果（提名行 + 目录过滤 + 补足 + 信任脚注）
            ├─ E1/E2/E3 ► LOCAL 本地引擎（E1 静默；E2/E3 一行降级条，不引导配 Key）
            └─ E4/E5 ──► ERROR 错误条 + 重试

所有结果态：框内改字即回 HOME；再次 submit 回 ROUTER；返回键三分支与现状一致
（栈顶弹详情 / 栈底有字清空回 HOME / 无字交回 PcMainPage，BrewSearchResultView.ets:521-547）
```

### 5.8 图 8 · 统一行解剖与换装表（`BrewPackageRow` 加可选槽）

```
    <---------------------- brew_search_row_height = 64vp ---------------------->
   +-------------------------------------------------------------------------------------+
   |        |   ffmpeg                                             [已安装]   1.2万   >  |
   |  icon  |   录制、转换和流处理音视频                                                 |
   |        |                                                                            |
   +-------------------------------------------------------------------------------------+
     line 1：token（现状字体不变）        右槽从左到右：状态 chip · 30 天安装量 · chevron
     line 2 按模式换装（唯一动的地方）：
       KEY      目录 desc（现状不变）
       INTENT   * why（AI 提名行） / 目录 desc（补足行，无 *）
       CMD      目录 desc（同名映射，如 ripgrep）/ apt: fd-find -> brew: fd（改名映射）
                / 未确认说明行（unconfirmed 行整行 font_tertiary、无 chevron）
     状态 chip：[已安装] checkmark_circle_fill + font_secondary（与详情页「已安装」按钮同语言）
                [可升级] warning 色短词 / 未安装 = 留白（沉默即答案）/ [未确认] font_tertiary
```

规格：`BrewPackageRow`（`features/brewcommon/src/main/ets/component/BrewPackageRow.ets`）新增可选成员，默认不渲染，既有 6 处调用点零改动：`line2Override?: string`（替换 desc）、`line2PrefixSparkle?: boolean`、`statusChip?: 'installed'|'outdated'|'unconfirmed'`、`dimmed?: boolean`。行高、图标、右槽现状不动。

## 6. 边界与交互细则

| 场景 | 行为 |
| --- | --- |
| 框内改字（未提交） | 立即回首页态（`showingSuggestions()` 现状语义）；命令 hint 随输入实时出现 / 消失 |
| 再次提交 | `apply()` 现状：`popPageByIndex(0)` 回栈底再换数据，不堆结果页 |
| 历史记录 | 三种模式都记**原文**（`recordSearch` 现状，0 结果也记）；chip 展示超 16 字符截断 |
| 索引未就绪 | KEY/CMD 照常出结果 + 既有 `IndexPendingBuilder` 提示条；索引就绪后 VM 既有刷新链路自动重算一次 |
| chips 过滤 | 三模式通用（kind 过滤只过滤已算结果不重算，现状）；未确认行不参与 kind 过滤（恒显示） |
| E6 取消 | 页面销毁 / 重搜取消在飞 AI，静默（现状） |
| 暗色模式 | 全部 sys token 自动适配，零新增色值 |
| 「问 AI」续接 | 行 → 详情页 → `BrewAiExplainCard`（D1 讲解已存在）—— 不做新聊天面（phase2 落点 10 未决） |

## 7. 失败态分级（E1–E6 → 统一页表现）

| 级 | 语义 | 统一页表现 |
| --- | --- | --- |
| E1 未配 Key | `isConfigured()`=false（含 pc_normal） | INTENT 前置判断直接本地引擎 rank 意图原文（不发注定失败的请求）；无降级条，静默不引导配 Key |
| E2 网络 / E3 超时 15s | 请求失败 / 超时 | catch → 本地引擎 + 理解条一行降级文案（`brew_search_strip_degraded`，替代计数行；结果照常，不引导配 Key，G6） |
| E4 格式 | JSON/Schema 校验失败 | 理解条 = 错误文案 + `[ 重试 ]` |
| E5 内容拒绝 | 模型拒绝 | 同 E4，文案区分（沿用 `ai_d2` 错误分级文案） |
| E6 取消 | 用户改字 / 离开 | 静默，骨架消失回首页态 |
| CMD 解析异常 | 语法命中但提取 0 包名 | 回落 KEY（原串），不报错 |
| 快照未就绪 | `BrewInstalledLoader` 无数据 | 行不渲染状态 chip（不阻塞、不占位） |

## 8. 文案表（`features/brewsearch/src/main/resources/{base,zh_CN,en_US}/element/string.json` 三份同步；带参资源用 `%d`/`%1$s`，禁止模板字符串内插 `$r()`）

| key | zh_CN | en_US |
| --- | --- | --- |
| `brew_search_placeholder_unified` | 搜索包名、描述需求或粘贴安装命令 | Search packages, describe a task, or paste an install command |
| `brew_search_hint_command` | 识别到 %s 安装命令，回车开始解析 | Detected a %s install command — press Enter to parse |
| `brew_search_strip_ai_found` | 为你找到 %d 个工具 | %d tools for you |
| `brew_search_strip_degraded` | AI 连接失败，已显示本地结果 | AI connection failed — showing local results |
| `brew_search_strip_cmd` | 识别到 %s 安装命令，%d 个包已映射 | Detected a %s install command — %d packages mapped |
| `brew_search_strip_ignored` | 已忽略 %d 行非安装命令 | Ignored %d line(s) that install nothing |
| `brew_search_cmd_expand` / `brew_search_cmd_collapse` | 展开 / 收起 | Expand / Collapse |
| `brew_search_cmd_table_source` | %s 包名 | %s package |
| `brew_search_cmd_table_brew` | brew 包名 | brew package |
| `brew_search_cmd_table_state` | 状态 | Status |
| `brew_search_cmd_batch` | 加入安装预演 · %d 个包 | Add %d package(s) to install preview |
| `brew_search_row_mapping` | %1$s: %2$s -> brew: %3$s | %1$s: %2$s -> brew: %3$s |
| `brew_search_row_unconfirmed` | 未在本地目录找到可靠对应，不猜测 | No confident match in the local catalog |
| `brew_search_state_upgradable` | 可升级 | Upgradable |
| `brew_search_state_unconfirmed` | 未确认 | Unconfirmed |
| `brew_search_trust_footer` | AI 提名 · 本地排序 · 已过滤 %d 个未验证候选 | AI-nominated · locally ranked · %d unverified candidates filtered |
| `brew_search_empty_keyword_hint` | 试试换个关键词，或描述你想完成的任务 | Try another keyword, or describe what you want to do |
| `brew_search_strip_error` | AI 暂时不可用 | AI is unavailable |
| `brew_search_retry` | 重试 | Retry |

复用不新增：`brew_search_result_count`（共 N 个结果）、`brew_search_no_result`、`ai_d2_loading`、`brew_state_installed`（已安装，与详情页同 key 同语言）。弃用清理：`ai_d2_entry`、`ai_d2_badge`、`ai_d2_empty` / `ai_d2_empty_hint`（统一空态取代，图 6）、`ai_d2_fallback_notice`（词表已删，G7）、`brew_search_placeholder`（旧 placeholder）。

## 9. 改动清单

| 文件 | 动作 |
| --- | --- |
| `features/brewsearch/src/main/ets/view/BrewSearchResultView.ets` | 内容区重构为统一结果区（理解条 / 统一行 / 骨架 / 空态 / 错误条）；A3 槽按态换装；hint 行；`apply()` 按路由分发。标题栏、让位数学、返回键不动 |
| `features/brewsearch/src/main/ets/component/BrewAiFindCard.ets` | **删除**（G12） |
| `features/brewsearch/src/main/ets/component/BrewSearchBar.ets` | placeholder 换统一文案；新增 `x` 清除钮 |
| `features/brewsearch/src/main/ets/component/BrewSearchExampleBar.ets` | 新增：A3 槽首页态示例 chips（高 56vp = `BREW_CHIP_BAR_HEIGHT` 槽高不变） |
| `features/brewsearch/src/main/ets/component/BrewSearchInterpretBar.ets` | 新增：理解条四形态（计数 / AI 摘要 / 降级 / 命令卡含展开表与批量按钮） |
| `features/brewsearch/src/main/ets/component/BrewSearchSkeleton.ets` | 新增：骨架 3 行 |
| `features/brewsearch/src/main/ets/model/BrewSearchRouter.ets` | 新增：`classify(q)` 纯函数 |
| `features/brewsearch/src/main/ets/model/BrewCommandParser.ets` | 新增：方言 / 包名 / 忽略行纯函数 |
| `features/brewsearch/src/main/ets/model/BrewCommandMapper.ets` | 新增：映射分级（§3.5） |
| `features/brewsearch/src/main/ets/constant/BrewCommandNames.ets` | 新增：改名映射种子表（~20 条起步） |
| `features/brewcommon/src/main/ets/util/AiTaskWords.ets` | **删除**（G7）：`brewcommon/Index.ets` 导出、`AiTasks.ets` 词表转发、`AiFindVM.ets` 引用一并清理 |
| `features/brewsearch/src/main/ets/model/BrewSearchRowSource.ets` | `BrewSearchRow` 扩展（§3.3，默认值兼容既有调用） |
| `features/brewsearch/src/main/ets/viewmodel/BrewSearchVM.ets` | 路由分发 + CMD/INTENT 装配 + 本机状态合并；`AiFindVM` 降为意图引擎：删 wordlist 模式与 `fallbackNotice`，E1/E2/E3 降级改本地引擎（§3.2） |
| `features/brewcommon/src/main/ets/component/BrewPackageRow.ets` | 可选槽（§5.8），默认不渲染，既有调用点零改动 |
| `features/brewsearch/src/main/resources/{base,zh_CN,en_US}/element/string.json` | §8 文案三份同步 |
| `hmosword-build/brew-search/check_command_parser.mjs` | 新增：解析 / 映射用例检查（house 惯例，同 `brew-disk`） |

## 10. 验证

1. 双 product 构建 ERROR 0（G10）。
2. `node hmosword-build/brew-search/check_command_parser.mjs` 全绿，用例至少覆盖：apt 多包 + `apt update` 忽略行；`pacman -S`；`brew install`；`sudo` / `env` 前缀；`;` `&&` 换行分隔；0 包名回落 KEY；`fd-find -> fd` 改名；同名确认；别名链（`rg`）；未确认默认。
3. 真机清单：三种输入各一条端到端（`ffmpeg` / `我想批量压缩视频` / `sudo apt install git fd-find ripgrep`）；断网降级（一行条 + 本地结果）；无 Key 静默本地结果（无条、无引导）；骨架出现与消失；状态 chip 与详情页按钮一致；批量按钮计数 = 确认项数；返回键三分支；历史 chip 长句截断；grep `AiTaskWords|wordlist|fallbackNotice` 全库零残留。
4. 代码评审：让位数学零改动（`topInset()` / `bottomBuilder.height` / `TitleBarBottomBuilder` 三处常量引用原样）；G8/G9 红线（无执行入口、未确认不入计划）。

## 11. 风险与未决

| # | 风险 / 未决 | 处置 |
| --- | --- | --- |
| 1 | J 装机预演未落地：批量出口可能暂不可见 | 能力开关门控（不渲染不置灰）；接口 `BrewSearchCommandPlan` 先行锁定，J 落地即接 |
| 2 | 改名映射表覆盖度低 | 种子表起步 + 同名 / 别名链兜底；`未确认` 是诚实默认而非失败（G9） |
| 3 | `sys.symbol.sparkles` / `checkmark_circle_fill` / `sys.color.success` 等 token 存在性 | 字面量编译校验兜底；`已安装` chip 主形态 = 安静灰（icon+font_secondary），success 着色为可选增强 |
| 4 | phase2 落点 6（搜索历史 / 空态 AI 意图提示）与本 spec 的示例 chips 撞车 | 本 spec 吸收（示例 chips 即意图教学 + 空态指路）；phase2 spec 实施前标注 |
| 5 | 「加入清单」（round8 4.4）无既有承载 | 本期不做入口；行模型 `matchKind` 已可扩展，预留 hook |
| 6 | 命令 hint 会不会打扰纯关键词用户 | 只在确定性语法命中时出现（关键词永不命中）；一行 tertiary 字，回车即被理解条接管 |
| 7 | 词表移除后，无 Key / 断网时意图命中率下降（中文长尾 0 行概率升高） | 诚实空态 + 指路文案；关键词 / 命令模式不受影响；G6「不引导」语义保留 |
