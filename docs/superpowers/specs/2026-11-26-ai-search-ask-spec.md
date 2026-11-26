# AI 搜索问答化改造 Spec（贴片退役 · Ask me anything）

- 日期：2026-11-26
- 状态：**待评审**（spec 先行，用户 m01029 指令：先写 Spec 并设计 UX）
- 作者：AI agent
- 依据：`2026-11-24-ai-search-unified-spec.md`（归档，其「删词表」意图在此落地）、`2026-11-26-ai-discover-feed-spec.md`（D4，'ai' 视觉身份与骨架/失败卡范式）

## 范围

用户需求原文（m01029）：

> 接下来，改造AI搜索，现在的AI搜索是在搜索页面的一个贴片，我想把这贴片删了加一个AI开关，如果启用AI的话，就把这个搜索框的Hint改成Ask me anything！然后提交了之后，就调用AI进行推荐包。输出的格式不再是纯文本或者是纯列表，改成文本和列表混排。比如说我搜索coding agent,他给我输出首选推荐的codex,然后介绍codex,然后然后是codex的列表项，然后第二项，比如说claude code,那就是先介绍cloud code,然后下面附一个cloud code的列表项。先写Spec并设计UX，使用高分辨率Ascii art。

一句话：**贴片（BrewAiFindCard）退役，AI 能力升格为搜索框内的模式开关；AI 模式提交后由 LLM 产出「总起段 + （介绍段 + 包行）× N + 目录召回尾行」的问答式混排答案。**

### 做

1. 删除搜索页贴片及其全部私有链路（词表模式一并退役）。
2. 搜索框内新增 AI pill 开关；开启态 hint 换为 "Ask me anything!"，身份色沿用 D4 紫。
3. AI 模式提交走新 D2 问答管线：单次 LLM 调用产出 lead + picks[{token, intro}]，本地目录校验后混排渲染。
4. 混排渲染 = 文本段 + 标准 `BrewPackageRow` 行交替；尾部「目录中相关」召回行；页脚 AI 徽章。
5. 降级矩阵：E1/E2/E3 自动转本地搜索 + 通知条；E4/E5 错误卡 + 重试 + 「用本地搜索」次按钮。

### 不做

- 不做多轮对话 / 上下文记忆（单问单答，intent 即缓存键）。
- 不做流式输出（沿用 `AiClient.complete` 非流式语义，与 D1/D2/RI 一致）。
- 不做 AI 结果的 chips 过滤（AI 模式下 chips 整行隐藏）。
- 不动普通搜索主链路（`BrewSearchEngine` / `BrewSearchVM.search` / 历史 / 建议 / 结果列表零改动）。
- 不做无 Key 时的配置引导（G6：降级不引导配 Key，E1 静默转本地）。
- 不改 `AiClient` / `AiCache` / `AiSettingsStore` 存取骨架（只加一个 prefs 键 + 开关方法）。

## 1. 判据（G1–G10）

| # | 判据 | 验证方式 |
|---|------|---------|
| G1 | 贴片彻底退役：`BrewAiFindCard.ets` 删除，全局搜 `BrewAiFindCard`/`AiFindRowSource`/`taskwords` 零残留引用 | grep + 编译 |
| G2 | AI 开关 = 搜索框内 pill；点击即切；状态经 `AiSettingsStore` 持久化（pattern 同 autoExplain），重启保持 | 手测重启 |
| G3 | hint 切换：off=「搜索内容」，on=**"Ask me anything!"**（三语同文，英文 tagline 是产品决策，见 §4.1） | 手测切语言 |
| G4 | AI 提交产出混排答案：lead 段 + 每包「AI 介绍段 + BrewPackageRow」成对出现，顺序 = LLM 叙事序（首选在前），**不经引擎重排** | 日志 + 目测 |
| G5 | 幻影防御：LLM 输出的目录外 token **不做可交互展示**（无详情路由/无安装入口）；进 `missed` 名单在答案尾部纯文本披露（m01462 修订，原口径为静默丢弃）；行 kind 只信 `AiCatalogIndex` 单一事实源 | 日志 `d2 dropped=` + 尾部披露行 |
| G6 | 降级矩阵：E1/E2/E3 → 自动本地搜索 + 顶部通知条（无配 Key 引导）；E4/E5 → 错误卡 + 重试 + 「用本地搜索」次按钮 | 断网/改 Key 手测 |
| G7 | 词表退役：`AiTaskWords.ets`、rawfile `ai/taskwords.json`、`findToolsOffline`、`AI_TASKWORDS_*` 常量全删 | grep 零残留 |
| G8 | AI off 路径零改动：普通搜索 / 建议 / 历史 / chips / 结果列表行为与改前逐字节等价 | 回归目测 |
| G9 | AI 模式 chips 行隐藏，titleBar `bottomBuilder` 高度与 `topInset()` 让位同步收缩（三处同源常量不破坏） | 断点切窗手测 |
| G10 | 缓存：同 intent 24h 内二次提交走缓存（日志 `d2 cache hit`）；`AI_PROMPT_VERSION_D2` 升 2 后旧 v1 缓存自动失效 | 日志 + 时序 |

## 2. 现状并入（哪些现有资产直接吃进来）

| 现状资产 | 本 spec 用法 |
|---------|-------------|
| `AiClient.complete` 非流式调用 | 原样复用（E1–E6 分类、超时、prompt 守卫全继承） |
| `AiCache`（feature 'd2' 目录） | 原样复用；promptVersion 升 2 → v1 旧缓存读侧自动删 |
| `AiCatalogIndex.entries()/kindOf()/has()` | 候选校验与 kind 单一事实源，原样复用 |
| `BrewPackageRow`（brewcommon） | 答案行直接复用，`hideRank=true` + 独立卡底色（见 §4.4） |
| `BrewBrowseBuilder.tokenId(token)` | 行 id（详情路由 + 缓存键同口径），原样复用 |
| `BrewSearchEngine.rank(intent, entries, 0)` | 只喂「目录中相关」尾行召回排序；**不再重排 AI picks** |
| `BrewSearchSuggestions` / 历史 / 发现 | 原样复用（pickWord 走当前模式提交） |
| D4 的 'ai' 视觉身份（#C4B5FD→#7C3AED、lightbulb） | pill on 态渐变 + hint 态搜索图标沿用，跨特性可识别 |
| D4 骨架卡范式（pulse 1.2s 呼吸、`getUIContext().animateTo`） | AI 加载骨架同款动画范式 |

### 护栏继承表（不重述，只引用）

G5（目录外零展示）/ G6（降级不引导配 Key）/ G13（AI 生成命令永无一键执行——本特性不产出命令，天然满足）/ Key 永不进日志 / prompt ≤ 8192 chars / 15s 超时不自动重试 / 缓存 promptVersion 失效语义 / stale-while-revalidate。

## 3. 数据流

```
                    ┌──────────────────────────────────────────────────────┐
                    │ 搜索页 BrewSearchResultView                          │
                    │                                                      │
   (💡 Ask me anything!▏ ✨AI▏ 搜索)  ← AI pill 切换: AiSettingsStore      │
        │                    │             .saveAiSearch(v) 持久化        │
        │ 提交(Enter/搜索)    │ 切换中触发: answer 态切回普通搜索重跑       │
        ▼                    │                                              │
   aiEnabled? ─── false ─────┤→ apply() 本地搜索链路 (现状, 零改动) ──→ 结果列表 │
        │ true               │                                              │
        ▼                    │                                              │
   applyAi(): appliedKeyword=keyword; popPageByIndex(0); recordSearch      │
        │                    │                                              │
        ▼                    │                                              │
   AiFindVM.ask(intent) ──trim 空──→ undefined (回建议态)                   │
        │                                                                   │
        ▼                                                                   │
   AiTasks.askSearch(input, AiCatalogIndex.entries())                       │
        │                                                                   │
        ├─ lookup('d2', key=slugOf(intent), v2, TTL 24h)                    │
        │     HIT ──→ parseAndAssemble(cached原文) ──────────────┐          │
        │     MISS ─→ LLM 调用: system=d2System v2 / user=intent │          │
        │              maxTokens 900 / temperature 0.3           │          │
        │              完成原文写回缓存(照常) ──────────────────→ │          │
        ▼                                                      ▼          │
   parseAndAssemble:                                              │          │
     ├ picks 逐条: trim/lower/去重/目录外 dropped++ (G5)           │          │
     ├ related = BrewSearchEngine.rank(intent) 未覆盖条目 ≤ 尾行上限│          │
     └ AiSearchAnswer{lead, picks[], related[], dropped}          │          │
        │                                                      │          │
        ▼                                                      ▼          │
   页面渲染: List[让位] + lead 文本 + (intro 文本 + BrewPackageRow)×picks │          │
             + 「目录中相关」尾行 + footer 徽章                    │          │
                                                                  │          │
   失败分支 (catch):                                               │          │
     E1/E2/E3 → 页面置通知条 + apply() 本地搜索 (G6 降级)          │          │
     E4/E5   → 错误卡(重试/用本地搜索)                             │          │
     陈旧守卫: appliedIntent !== trimmed → 丢弃结果 (沿用)          │          │
```

## 4. UX 设计（高分辨率 ASCII art）

### 4.1 搜索框两态（BrewSearchBar 改造）

布局公式（现有 Row 追加一个 pill，不破坏原有弹性）：

```
Row(高40, padding level4, comp_background_tertiary, 圆角 level4)
├─ SymbolGlyph     off: sys.symbol.magnifyingglass / on: sys.symbol.lightbulb
├─ TextInput       layoutWeight(1)  ← 唯一弹性项, 挤压安全
├─ AI pill         固定宽 (icon 无, 文本 "AI"), 高28, 圆角 FULL_PERCENT
├─ (有字时) Divider + 「搜索」
```

```
AI off:
╭────────────────────────────────────────────────────────────────────╮
│  (🔍)   搜索内容…                                          ╭─────╮  │
│         └ placeholder = brew_search_placeholder            │ AI │  │
│           (sys.italic Body_S placeholder色)                ╰─────╯  │
│                                        off 态 pill:                 │
│                                        comp_background_tertiary 底  │
│                                        icon_secondary 字            │
╰────────────────────────────────────────────────────────────────────╯
 [全部] [Formulae] [Casks]          ← chips 行照常, 让位高度照常

AI on:
╭────────────────────────────────────────────────────────────────────╮
│  (💡)   Ask me anything!                                   ╭─────╮  │
│         └ placeholder = brew_search_placeholder_ai         │ AI │  │
│           (三语同文 — 英文 tagline 是刻意的产品决策)         ╰─────╯  │
│                                        on 态 pill:                 │
│                                        linearGradient 90°          │
│                                        #C4B5FD → #7C3AED           │
│                                        白字 Bold, 字色 5.70:1      │
╰────────────────────────────────────────────────────────────────────╯
 (chips 行隐藏, titleBar 让位高度同步收缩 — 见 4.5)

AI on + 有字（提交前）:
╭────────────────────────────────────────────────────────────────────╮
│  (💡)  coding agent▏                          ╭─────╮ │ │ 搜索 │ │
│                                                │ AI │ │ │      │ │
│                                                ╰─────╯ └──────┘  │
╰────────────────────────────────────────────────────────────────────╯
   ↑ 输入框窄窗时先截断自身文本, pill/按钮宽度恒定不换行
```

### 4.2 建议态（AI on，未提交）

贴片删除后的建议态 = 「AI 提问示例」区 + 原有历史/发现（原样下沉）：

```
╭─ 建议态 (AI on) ────────────────────────────────────────────────────╮
│                                                                     │
│  试试这样问                                    (Body_S font_tertiary)│
│  ╭──────────────────────╮ ╭──────────────────────╮ ╭───────────╮  │
│  │ 帮我找个 coding agent │ │ 批量压缩图片的命令行工具│ │ 能录屏的CLI │  │
│  ╰──────────────────────╯ ╰──────────────────────╯ ╰───────────╯  │
│   └ 点击 = 填入输入框 + 立即以 AI 模式提交 (同 pickWord 语义)         │
│   └ chip: comp_background_tertiary 底 / font_secondary / 圆角 pill  │
│   └ ai_search_example_1/2/3 (三语)                                  │
│                                                                     │
│  ┄┄┄┄┄┄┄┄┄┄┄┄ 以下为现状组件原样下沉, 零改动 ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄   │
│                                                                     │
│  搜索历史                                          (折叠 chevron)   │
│  ╭─────────────────────────────────────────────────────────────╮  │
│  │ 火焰 🔥   coding agent                                       │  │
│  │ …                                                           │  │
│  ╰─────────────────────────────────────────────────────────────╯  │
│  搜索发现 …                                                          │
╰─────────────────────────────────────────────────────────────────────╯
   AI off 时示例区整体不渲染 → 与现状完全一致 (G8)
```

### 4.3 加载骨架态（AI 提交后，answer 未返回）

复用 D4 骨架范式（pulse 1.2s 呼吸, `getUIContext().animateTo`）。结构 = 答案的「影子」：

```
╭─ loading (AI on) ───────────────────────────────────────────────────╮
│                                                                     │
│   ╺╺╺╺╺╺╺╺╺╺╺╺╺╺╺╺╺╺╺╺╺╺╺╺╺╺╺╺╺╺╺  (lead 条, 高16, 宽 70%)           │
│   ╺╺╺╺╺╺╺╺╺╺╺╺╺  (lead 次条, 高14, 宽 40%)                           │
│                                                                     │
│   ╭─────────────────────────────────────────────────────────────╮  │
│   │ ┌────┐ ╺╺╺╺╺╺╺╺╺╺╺╺╺╺╺  (行骨架: icon48 + 双文字条 + 尾钮位)   │  │
│   │ │ 48 │ ╺╺╺╺╺╺╺╺╺╺╺╺╺╺╺╺╺╺╺╺╺                                  │  │
│   │ └────┘ ╺╺╺╺╺╺╺╺╺╺                                              │  │
│   ╰─────────────────────────────────────────────────────────────╯  │
│   ╺╺╺╺╺╺╺╺╺╺  (intro 条, 高14, 宽 55%)                               │
│   ╺╺╺╺╺╺╺╺╺╺╺╺╺╺╺╺  (intro 次条, 高14, 宽 38%)                       │
│   ╭─────────────────────────────────────────────────────────────╮  │
│   │ ┌────┐ ╺╺╺╺╺╺╺╺╺╺╺╺╺╺╺╺  (第二个行骨架)                        │  │
│   ╰─────────────────────────────────────────────────────────────╯  │
│   ╰ 以上一组 (intro+行) 重复 2 组, 尾部单 lead 条 — 高度≈真实答案    │
│     灰条 = font_secondary opacity 0.18; 行壳 = comp_background_list  │
╰─────────────────────────────────────────────────────────────────────╯
```

### 4.4 答案混排态（核心）

> **修订（m01422 用户反馈）**：混排改为「**一篇长文，内嵌若干包 Item**」—— 全部内容收进
> **同一张大卡**（`comp_background_list_card` 底 / level8 圆角 / clip / padding level6），文字
> 统一正文字体（Body_M，21 行高，只靠颜色深浅分主次），行**透明嵌在文流里**（不再独立成
> 卡）。读起来是 lead → 介绍段 → 行 → 介绍段 → 行 → 目录中相关 → 行… → footer 的连续文章，
> 而不是「行旁边放提示文本」。下方 4.4 原图保留为初版设计存档；间距口径以本修订为准：
> 段落紧行（intro→行 level2）、组间 level4、文字块水平缩进 level4（比行窄一档，段落感）、
> related 连续行间 1px 分隔线（pick 行之间隔着文字段不加线）、footer 上方发丝线 + 居中落款。

> **修订（m01462 用户反馈）**：目录外 token 不再静默丢弃——进 `missed` 名单在**大卡尾部**
> （related 之后、footer 之前）纯文本单列披露：「AI 还提到了，但本机目录源里没有」+ token
> 名单（顿号连接）。动机：lead 说 5 个推荐、实际只匹配 3 个会显得诡异，对不上账。安全口径
> 不变：**纯文本、不可点击、无详情路由、无任何安装入口**——G5 防的本是诱导安装不存在的包
> （slopsquatting），明示缺失恰是反诱导。`dropped` 计数与 `missed.length` 等价（日志口径不变）。

**节奏**：文本段（无底色）与行卡（有底色）交替；「介绍段→行」组内间距 level2，组间距 level8。行 = 标准 `BrewPackageRow`（hideRank=true，独立卡底 `comp_background_list_card`，圆角 level8），点击走现有 openDetail 链路。

```
╭─ AI 回答态 · applied = "coding agent" ──────────────────────────────╮
│                                                                     │
│  ╭─────────────────────────────────────────────────────────────╮  │
│  │ (💡) Ask me anything! / coding agent▏           ╭─────╮ 搜索 │  │
│  │                                                 │ AI │ │     │  │
│  │                                                 ╰─────╯ ╰─────╯ │  │
│  ╰─────────────────────────────────────────────────────────────╯  │
│   (chips 隐藏)                                                       │
│                                                                     │
│  ┌ List (滚动容器, 首末项让位占位) ─────────────────────────────┐  │
│  │                                                              │  │
│  │  ──── lead 段 (AI 总起, Body_L font_primary, maxLines 3) ──   │  │
│  │  ╭────────────────────────────────────────────────────────╮ │  │
│  │  │ 为你找到 3 个适合写代码的 coding agent，首选 codex：     │ │  │
│  │  ╰────────────────────────────────────────────────────────╯ │  │
│  │    padding 左右 level6                                          │  │
│  │                                                              │  │
│  │  ──── pick[0] = 介绍段 + 行 (组内间距 level2) ────────────   │  │
│  │  ╭────────────────────────────────────────────────────────╮ │  │
│  │  │ 首选推荐 codex —— OpenAI 官方 CLI 编程智能体，在终端里   │ │  │
│  │  │ 就能让 AI 读懂仓库并直接改代码。想在本地跑通 coding      │ │  │
│  │  │ agent 工作流，它是生态最成熟的一个。                      │ │  │
│  │  ╰── (Body_M font_secondary, maxLines 4, 左右 level6) ─────╯ │  │
│  │  ╭────────────────────────────────────────────────────────╮ │  │
│  │  │ [F] codex                        OpenAI 官方 CLI 编程    │ │  │
│  │  │     OpenAI 的官方命令行编程智能体        ↓ 12.3k     (>) │ │  │
│  │  ╰── BrewPackageRow: icon48 + token(Bold) + 目录 desc ─────╯ │  │
│  │     + installs30d + chevron; hideRank=true;                 │  │
│  │     cardBg=comp_background_list_card, radius=level8         │  │
│  │     onClick → openDetail (与普通搜索行同一链路, G4)          │  │
│  │                                                              │  │
│  │  ──── pick[1] ──────────────────────────────────────────   │  │
│  │  ╭────────────────────────────────────────────────────────╮ │  │
│  │  │ 第二个是 claude code —— Anthropic 的官方 CLI 编程智能体  │ │  │
│  │  │ …                                                        │ │  │
│  │  ╰──────────────────────────────────────────────────────────╯ │  │
│  │  ╭────────────────────────────────────────────────────────╮ │  │
│  │  │ [F] claude-code                   Anthropic 官方 CLI     │ │  │
│  │  ╰────────────────────────────────────────────────────────╯ │  │
│  │                      ⋮ (picks 依 LLM 叙事序, ≤5 组)          │  │
│  │                                                              │  │
│  │  ──── 目录中相关 (本地引擎召回, 行无介绍段) ──────────────   │  │
│  │  ╭ 目录中相关 (Body_S font_tertiary, 左右 level6) ─────────╮ │  │
│  │  │ [F] aider                                            (>) │ │  │
│  │  │ [F] gemini-cli                                       (>) │ │  │
│  │  ╰──────────────────────────────────────────────────────────╯ │  │
│  │    related = BrewSearchEngine.rank(intent) 未覆盖条目         │  │
│  │    数量 = 补足到 AI_D2_RESULT_LIMIT(8) 为止, 上限 5 行        │  │
│  │                                                              │  │
│  │  ──── footer 徽章 ───────────────────────────────────────   │  │
│  │            (💡) AI 生成 · 已由本地目录校验                    │  │
│  │    (Body_S font_tertiary 居中, 无底色, 纯声明)                │  │
│  │                                                              │  │
│  │  ┌──────────────────────────────────────────────────────┐   │  │
│  │  │ [让位占位: 底部安全区]                                 │   │  │
│  │  └──────────────────────────────────────────────────────┘   │  │
│  └──────────────────────────────────────────────────────────────┘  │
╰─────────────────────────────────────────────────────────────────────╯
```

### 4.5 降级与失败态

```
E1/E2/E3 → 降级通知条 + 自动本地搜索 (G6, 不引导配 Key):

╭─ fallback ──────────────────────────────────────────────────────────╮
│  ╭─────────────────────────────────────────────────────────────╮  │
│  │ (💡) AI 暂不可用，已用本地搜索                     (通知条)  │  │
│  │       E1 专用文案: AI 未配置，已用本地搜索                    │  │
│  ╰── Body_S font_secondary, comp_background_tertiary 底 ──────╯  │
│  ╰── 圆角 level4, 高 36, margin bottom level4, 点击可关 ─────────  │
│                                                                     │
│  ┌ 以下是普通结果列表 (apply() 本地链路原样复用) ─────────────┐    │
│  │ [F] codex      OpenAI 官方 CLI 编程智能体       ↓12.3k (>) │    │
│  │ [F] aider      AI pair programming in your term ↓ 8.1k (>) │    │
│  │ …                                                          │    │
│  └────────────────────────────────────────────────────────────┘    │
╰─────────────────────────────────────────────────────────────────────╯

E4/E5 → 错误卡 (AI 模式停留在结果区):

╭─ error ─────────────────────────────────────────────────────────────╮
│  ╭─────────────────────────────────────────────────────────────╮  │
│  │ (💡) AI 回答生成失败                              (Title_S) │  │
│  │                                                              │  │
│  │  解析失败/内容被拦截 (errorDetail, Body_S font_tertiary,     │  │
│  │  maxLines 2)                                                 │  │
│  │                                                              │  │
│  │  ╭──────────────╮   ╭────────────────────╮                   │  │
│  │  │ (↻) 重试     │   │     用本地搜索      │                   │  │
│  │  ╰──────────────╯   ╰────────────────────╯                   │  │
│  │   └ 紫渐变底白字      └ 描边次按钮:                  │  │
│  │     (brew_board 紫end)  comp_background_primary +           │  │
│  │     onClick=重发 ask   font_secondary, onClick=本地搜索      │  │
│  ╰─────────────────────────────────────────────────────────────╯  │
╰─────────────────────────────────────────────────────────────────────╯
```

### 4.6 状态机

```
                 ┌────────── toggle AI off: 若 answer 态且有 applied ──┐
                 ▼            则重跑 apply(applied) 回普通结果          │
   ┌───────── aiEnabled=false ─────────────────────────────────────────┐
   │  (现状态: 建议/普通结果, G8 零改动)          ▲                     │
   └──[提交]──→ apply() 本地搜索 ─────────────────────┤ (E1/E2/E3 降级) │
                                                   │                  │
   ┌── toggle AI on: hint 变, chips 隐藏 ────────────┘                  │
   ▼                                                                    │
 aiEnabled=true                                                          │
   │                                                                    │
   ├─ 未提交 → 建议态(含 AI 示例区)                                       │
   │                                                                     │
   └─ [提交] → loading(骨架) ──→ askSearch ─┬─→ answer(混排) ──→ done    │
                                           │                            │
                                           ├─ E1/E2/E3 → fallback       │
                                           │   (通知条+本地结果)          │
                                           │                            │
                                           ├─ E4/E5 → error 卡           │
                                           │   ├─[重试]→ loading        │
                                           │   └─[用本地搜索]→ fallback  │
                                           │                            │
                                           ├─ picks=[]→ empty 态        │
                                           │   (换问法提示卡)             │
                                           │                            │
                                           └─ 陈旧守卫: 新提交在途时     │
                                              旧结果静默丢弃 (沿用)      │
```

### 4.7 视觉规格汇总

| 元素 | 规格 |
|------|------|
| AI pill | 高 28，padding 水平 level6，文本 "AI" Body_S Bold；off=tertiary 底/icon_secondary 字；on=90° 渐变 #C4B5FD→#7C3AED/白字（对比 5.70:1，沿用 D4） |
| hint on | `brew_search_placeholder_ai` = "Ask me anything!"（base/zh_CN/en_US 三语同文） |
| 搜索图标 | off=magnifyingglass；on=lightbulb（`sys.symbol.lightbulb`，与 D4 'ai' 板/分类同源） |
| 答案大卡 | 全文收进一张卡：list_card 底、level8 圆角、clip、padding level6（m01422 修订） |
| lead 段 | Body_M font_primary，maxLines 3，21 行高，水平缩进 level4 |
| pick intro | Body_M font_secondary Regular，maxLines 4，21 行高，水平缩进 level4 |
| 行 | `BrewPackageRow(hideRank=true)`，itemHeight=brew_package_row_height，**透明底嵌入大卡**（不独立成卡） |
| 垂直节奏 | intro→行 level2；组↔组 level4；lead→首组 level4；文字块缩进 level4（比行窄一档） |
| 尾行区 | 标题「目录中相关」Body_M font_tertiary；行间 1px 分隔线（comp_background_tertiary） |
| footer | 上方发丝线 + (💡)+文案 Body_S font_tertiary 居中 |
| 骨架 | D4 范式：与答案同款大卡外壳，灰条 font_secondary@0.18、行透明嵌入，pulse 1.2s 往返 |
| 通知条 | 高 36，tertiary 底 level4 圆角，Body_S font_secondary，可点击关闭 |
| 错误卡 | list_card 底 level8 圆角 padding level8；主按钮紫渐变、次按钮描边 |

## 5. 常量与类型

### AiConstants.ets 改动

```
AI_PROMPT_VERSION_D2: 1 → 2            // schema 破坏性变更, 旧缓存自动失效
AI_MAX_TOKENS_D2:    600 → 900         // lead+5×intro 叙事需要
AI_TEMPERATURE_D2:   0.2 → 0.3         // 叙事语气略活
AI_D2_MAX_CANDIDATES: 5        // 保留 (picks 上限)
AI_D2_RESULT_LIMIT:  8        // 保留 (picks+related 合计补足目标)
AI_D2_LEAD_MAX_CHARS: 80      // 新增: lead 段字数上限
AI_D2_INTRO_MAX_CHARS: 200    // 新增: 单 pick 介绍段字数上限
AI_D2_TAIL_ROWS_MAX: 5        // 新增: related 尾行上限
AI_PREFS_KEY_AI_SEARCH = 'brew_ai_search_enabled'   // 新增: 开关持久化键
删除: AI_TASKWORDS_RAWFILE / AI_TASKWORDS_MIN_COUNT
```

### AiTypes.ets 新类型（D4 段后追加；`AiToolCandidate`/`AiToolResult` 删除）

```
export class AiSearchPick  { token: string; intro: string; }
export class AiSearchAnswer {
  lead: string;                        // 总起段, ≤80 字
  picks: AiSearchPick[];               // 叙事序, 1..5
  related: AiSearchPick[];             // 本地召回 (intro 空, 仅 token)
  dropped: number;                     // G5 幻影/重复/超限丢弃计数
}
```

## 6. 文件清单

| 文件 | 动作 | 内容 |
|------|------|------|
| `features/brewsearch/.../component/BrewAiFindCard.ets` | **删** | 贴片本体 |
| `features/brewsearch/.../viewmodel/AiFindRowSource.ets` | **删** | AiFindRow/AiFindResultSource 全删（新渲染不用 IDataSource 行源） |
| `features/brewsearch/.../viewmodel/AiFindVM.ets` | 改 | 重写为 ask(intent): Promise<AiAskOutcome>；outcome = {kind:'answer'\|'fallback'\|'error'\|'empty', answer?/reason?/error?}；删 wordlist/findOffline/rowsOf；appliedIntent 陈旧守卫保留 |
| `features/brewsearch/.../component/BrewSearchBar.ets` | 改 | +aiEnabled/@Prop、onToggleAi 回调、AI pill、icon/hint 切换 |
| `features/brewsearch/.../view/BrewSearchResultView.ets` | 改 | 删贴片挂点；+aiEnabled @State(初始化自 AiSettingsStore)；applyAi()/apply() 分流；answer/empty/error/fallback 渲染分支；chips 条件隐藏+topInset 同步；通知条；返回键 answer 态=清词回建议（沿用现有语义） |
| `features/brewsearch/.../component/BrewAiSearchAnswerView.ets` | **新** | 混排答案：lead/intro+行对/related/footer builders；props: answer, openDetail |
| `features/brewsearch/.../component/BrewAiSearchSkeleton.ets` | **新** | §4.3 骨架（D4 pulse 范式） |
| `features/brewsearch/.../component/BrewAiSearchErrorCard.ets` | **新** | §4.5 错误卡（重试/用本地搜索双按钮） |
| `features/brewsearch/.../component/BrewAiSearchExamples.ets` | **新** | §4.2 示例区（仅 aiEnabled 时渲染） |
| `features/brewsearch/src/main/resources/base/element/color.json` | **新** | pill 渐变对（#C4B5FD/#7C3AED 同 D4 值，模块内自持） |
| `features/brewcommon/.../model/AiTypes.ets` | 改 | §5 类型；删 AiToolCandidate/AiToolResult（删前 grep 全局无引用） |
| `features/brewcommon/.../constant/AiConstants.ets` | 改 | §5 常量 |
| `features/brewcommon/.../service/AiTasks.ets` | 改 | findTools→**askSearch**(input,entries): 新 D2_SYSTEM v2/schema 解析/G5 过滤/related 补足/缓存存原文 v2；删 findToolsOffline/wordlistMatch/rankCandidates(D2 段内)；D2 日志口径不变 |
| `features/brewcommon/.../service/AiTaskWords.ets` | **删** | 词表退役（先 grep：仅 AiTasks.findToolsOffline 消费） |
| `features/brewcommon/.../rawfile/ai/taskwords.json` | **删** | 同上 |
| `features/brewcommon/.../service/AiSettingsStore.ets` | 改 | +aiSearch()/saveAiSearch(v)（prefs pattern 同 autoExplain） |
| `features/brewcommon/Index.ets` | 改 | 导出更新：+AiSearchPick/AiSearchAnswer；删 AiToolCandidate/AiToolResult/AiTaskWords 相关 |
| `brewcommon string.json ×3` | 改 | 删 ai_d2_* 7 键；新增：brew_search_placeholder_ai / ai_search_example_1/2/3 / ai_search_examples_header / ai_search_fallback_notice / ai_search_fallback_no_key / ai_search_failed / ai_search_retry / ai_search_use_local / ai_search_empty / ai_search_related_header / ai_search_footer |
| `README.md` | 改 | 文档索引 +1 行（本 spec） |

不改动：`AiClient` / `AiCache` / `AiCatalogIndex` / `BrewSearchEngine` / `BrewSearchVM` / `BrewSearchState`(结构沿用, 页面 @State 扩字段) / `BrewSearchSuggestions` / `BrewPackageRow` / 结果列表主链路。

## 7. 验收

1. AI off：与改前完全一致（G8 逐项目测：建议/历史/发现/普通搜索/chips/结果行/详情跳转）。
2. 切 AI on：hint 即变 "Ask me anything!"、图标变 lightbulb、chips 隐藏、让位不跳变；重启保持 on（G2/G3/G9）。
3. 提交 "coding agent"：骨架 → 混排答案（lead + intro/行成对 + related + footer），顺序为 LLM 叙事序（G4）。
4. 行点击 → 详情页正常打开（G4）。
5. 断网提交：通知条 + 本地结果（G6）；坏 Key：E5 → 错误卡 → 重试/用本地搜索均有效（G6）。
6. 24h 内重复同问：日志 `d2 cache hit`，无第二次 LLM 调用（G10）。
7. 模型幻觉 token：不渲染为可交互行，进 `missed` 尾部披露行（纯文本、不可点击），日志 `d2 dropped=` 递增（G5）。
8. grep `BrewAiFindCard|AiTaskWords|taskwords|AiFindRowSource` 全仓零业务残留（G1/G7）。
9. pc_normal + pc_acl 双产品 CompileArkTS 通过。

## 8. 风险与对策

| 风险 | 对策 |
|------|------|
| `HdsNavDestination` titleBar bottomBuilder 高度随 @State 动态变化不生效 | 先实现条件高度；不生效则兜底=chips 保留渲染但置灰不可点（布局零变化） |
| List 内 ForEach 单 item 吐多个 ListItem（intro+行成对）不合法 | 兜底=拍平为 typed feed 数组（D4 BrewDiscoverFeedItem 同款方案），LazyForEach 按 key 渲染 |
| maxTokens 900 仍截断（5×intro+lead 超长） | finish=length → E4-truncated 已有兜底；intro 字数上限 200 由解析侧 clamp |
| "Ask me anything!" 三语同文被误当漏翻 | spec 记录为刻意决策；资源文件同值不同 key，后续要本地化只动 zh_CN 一份 |
| AiToolCandidate/AiToolResult 有未发现的消费者 | 删除前 grep 全仓（预期仅 AiTasks/AiFindVM/AiFindRowSource/Index）；有则保留类型仅删旧方法 |
| pill+搜索按钮窄窗挤压 | TextInput layoutWeight(1) 先牺牲；40 高度 bar 内 28 高 pill 已验证可容纳 |
| 空 picks 的空态冷场 | empty 卡给「换问法」示例文案，并提供示例 chip 点击即重问 |
