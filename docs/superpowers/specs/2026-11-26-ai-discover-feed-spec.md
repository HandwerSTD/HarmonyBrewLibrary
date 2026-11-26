# AI 发现流 · 用户画像与个性化推荐（D4）设计

> 日期：2026-11-26（v2，按 m00133 反馈重写 UX：AI 推荐复用现有大图卡 + 榜卡，插进瀑布流，不再做 Hero+横滑 Rail）。状态：待评审。
> 范围：`features/brewcommon`（`AiTypes` / `AiConstants` / `AiTasks` 新增 D4 任务层）；`features/brewdiscover`（VM/State/FeedItem 扩展、`BrewBoardStyle`/`BrewDiscoverBoardCard` 小改、骨架与失败卡、字符串资源）。
> 不做：画像编辑与反馈闭环、推荐解释二级页、向量检索、服务端缓存、pc_normal 假安装数据。
> 依据：`2026-11-22-ai-companion-spec.md`（BYOK 底座 / D1–D3 / G5 / G6 / G13）、`docs/brew-discover-algo.md`（六榜与瀑布流现状）、`2026-11-24-ai-search-unified-spec.md`（D2 管线口径）。
> 需求原文（m00001）：「AI发现流，支持AI分析本地用户安装的包从而推断用户画像，然后在发现页使用AI推荐符合用户画像的包。这是一个演示用Mvp所以原理可以暴力一点，直接用Byok的LLM进行推荐生成，假定用户Token管够。但是生成缓存还是要做的。先写Spec」
> UX 反馈原文（m00133）：「哦不不我想的是有好几张卡，占在现在的推荐卡片前面，其中可以有若干的专门展示一个包的大图卡，Subtitle写工具简介，然后一个榜卡用于显示推荐的所有包列表，后面再排上现有的Stat驱动的卡」
> 定位（演示 MVP）：**一次 LLM 调用同时产出「画像 + 推荐」**；假定 Token 充足不省调用；**生成缓存必须做**。
> UX 基准（v2 修正）：**AI 推荐卡与现有卡片同一套视觉语言、同一个瀑布流 section 混排**——`AI_D4_FEATURED_COUNT(3)` 张单包大图卡（复用 `BrewDiscoverFeaturedCard`，subtitle=工具简介）+ 1 张 AI 榜卡（复用 `BrewDiscoverBoardCard`，完整推荐列表）前插在现有六榜 feed 之前。AI 身份由徽章文字承担（「AI 为你推荐」），不另起配色体系——与现有「榜的身份由文字承担，不用颜色区分」的决策同源。

---

## 1. 目标与成功判据

发现页瀑布流顶部出现「AI 为你推荐」区：3 张单包大图卡（subtitle=目录工具简介，视觉与现有大图卡完全一致）+ 1 张 AI 榜卡（Hero 显示 AI 画像 headline，行列表 = 全部推荐包，每行副文案 = 推荐理由）。画像与推荐由同一次 BYOK LLM 调用生成，结果落盘缓存。AI 是纯增强层：无 Key、无安装数据、目录未就绪、调用失败——任何一种情况 AI 区缺席或降级，**六榜主链路零影响**。

| # | 判据 | 可观测证据 |
| --- | --- | --- |
| G1 | 画像推断：输入 = 本机已安装包（token + kind + 近装标记），LLM 输出结构化画像（headline / tags / basis），按 UI 语言输出；**画像展示在 AI 榜卡 Hero 标题位** | 真机：装 git+gh+node+docker+k9s+vscode 的机器上 headline 指向开发者/CLI/容器画像，中文系统出中文 |
| G2 | 推荐生成：**同一次调用**产出 10 个 picks；**前 3 张上大图卡**（desc=目录工具简介，徽章「AI 为你推荐」），**全部 10 条进 AI 榜卡**（行副文案=why，具体贴合画像不复述功能） | 真机 |
| G3 | 目录锚定（继承 G5 红线）：候选池从 `BrewTable` 派生，LLM 输出 token 经候选池校验，目录外与已安装的 pick 一律丢弃，丢弃计数进日志、不进 UI | 日志 `[AiTasks]` dropped/droppedInstalled 计数；真机 UI 无幻影包 |
| G4 | 缓存：cacheKey = `hash(安装集 + 目录世代 + locale)`，TTL 1 天，promptVersion 变更即失效；「换一批」（AI 榜卡 Hero 右上 ↻）= force 旁路读缓存、照常写回，prompt 附 exclude 列表 | 日志第二次进入 cache hit；换一批后无重复卡 |
| G5 | UX：AI 卡**前插进现有 feed 数组**（同一 section、同一多列瀑布 sm1/md2/lg3、rowsGap 连续无断层）；现有 stat 驱动 feed 顺序 `F F B B F B F B B F B` **逐位不动** | 真机 + 代码评审 |
| G6 | 降级零干扰：无 Key（E1）静默不出现 AI 区（G6 语义）；E2–E5 → AI 失败占位卡（重试）；E6 静默；无安装数据 / 目录未就绪 → 不出现；六榜如常 | 真机各状态 |
| G7 | 安全红线：Key 永不进日志/偏好；AI 区**不渲染任何可执行命令**（G13）；上传仅 token 清单（不含路径/版本/时间戳） | 代码评审 |
| G8 | 双 product 构建：pc_normal AI 区静默缺席（安装数据恒空），`deveco build` 双 product ERROR 0 | 构建 |

## 2. 现状与并入事实

### 2.1 并入对象

| 对象 | 现状 | 并入后 |
| --- | --- | --- |
| 瀑布流 feed（`BrewDiscoverBaseView.ets:130-216` + `BrewDiscoverVM.ets`） | WaterFlow 3 sections `[spacer, feed, footer]`；feed = `BrewDiscoverFeedItem.mix(featured, boards)` 进 LazyForEach，crossCount sm1/md2/lg3，`BrewDiscoverFeedType` FEATURED/BOARD 两分支渲染；spacer/footer 是空白 FlowItem 让位（不能用容器 padding——会裁剪内容破坏标题栏模糊） | **AI 卡前插 feed 数组**：`[AI featured ×3, AI board ×1, ...mix(featured, boards)]`。骨架/失败态也是 feed item（新 feedType）。sections 数量与 crossCount 零改动，AI 卡天然参与多列瀑布 |
| 单包大图卡（`BrewDiscoverFeaturedCard.ets`） | Stack：渐变底（`BrewFeaturedArtStyle` 7 套，按 `item.id` 确定性选取）+ 裸 symbol 140vp + 底部内容块（右上徽章=增速 `↑22.0×`；desc 大字 Title_M Medium 2 行；`HdsListItemCard` 行 = icon + 市场名 + 安装量 + chevron）；卡高 400vp | **零改动复用**：AI 大图卡 = `BrewDiscoverFeatured`（`boardKey='ai'`）。徽章文案走 `BrewBoardStyle.titleOf(boardKey)` → 'ai' 映射「AI 为你推荐」；desc = 目录工具简介；id 走 `tokenId(token)` → 配色与其他卡一样从池子确定性取。可选加分项：`installedOf` 命中时右上徽章改「已安装」 |
| 榜单大卡（`BrewDiscoverBoardCard.ets`） | Hero（`BrewDiscoverHero`：kindLabel + title + symbol + 渐变，`BrewBoardStyle` 按板配色）+ 预览 5 行（`BrewDiscoverRow`）+ `entryCount > 5` 时「查看全部」行（jumpBoard 进二级页） | **AI 榜卡 = `BrewDiscoverBoard`（`boardKey='ai'`）+ 两个特判**：① 行列表**全显不截 5**（用户要求「显示推荐的所有包列表」）；② 保留「查看全部」行（boardId=0 进现有榜单二级页，数据取首页 VM 的 aiBoard）；③ Hero 标题位 = 画像 headline（动态注入），kindLabel =「AI 为你推荐」，Hero 右上角「换一批」↻ 小按钮 |
| 榜内行（`BrewDiscoverRow.ets`） | 行 = icon + 市场名 + 副文案（`entry.desc`） | **零改动**：AI 榜行的 `desc` 字段直接填 pick 的 why（推荐理由）——同一字段、不同内容源，渲染自动生效 |
| 安装数据（`BrewInstalledLoader.ets`） | `snapshot()` / `installedOf(token)` / `subscribe`；pc_normal `BrewCli.isEnabled()=false` → 静默空集 | D4 用 `snapshot()` 同步取（不执行命令）；`installedOf` 画「已安装」角标 |
| 目录（`BrewTable.ets`） | `rows(kind)` 全量 `CatalogEntry[]` 按 vol30d 降序；`descOf(kind, token)`；`state()`；epoch=`BrewCacheEpoch.current()` 世代号 | 候选池 = rows 截 top N（去已安装）；epoch 进 cacheKey；`BrewBrowseBuilder.tokenId(token)` 派生详情 id |
| AI 底座（`AiTasks`/`AiClient`/`AiCache`/`AiSettingsStore`） | D1/D2/D3 全套 + Release Intel 任务（`RELEASE_INTEL_FEATURE='release_intel'`，dev 1e996b4 新进，走同一 `AiCache`）；`parseJsonSafe`+`stripJsonWrapping`+`slugOf`；`AiClient.newTask`；缓存四段路径+原子写 | D4 = 第四个 D 系任务 `AI_FEATURE_D4='d4'`（命名无冲突），整链路复用，`AiClient`/`AiCache`/`AiSettingsStore` 零改动 |

### 2.2 既有护栏继承（只引用，不重写）

| 护栏 | 本区表现 |
| --- | --- |
| G5 目录外零展示（防 slopsquatting） | 候选池即目录子集；LLM 输出经池校验，丢弃计数进日志不进 UI |
| G6 降级不引导配 Key | E1 → AI 区整块不出现，无横幅无引导；E2/E3 → 失败占位卡 + 重试；E4/E5 → 失败占位卡（文案按 kind 资源化）；E6 静默 |
| G13 AI 生成命令永无一键执行 | AI 区不渲染任何命令文本；推荐出口只有「进详情页」 |
| Key 永不进日志/偏好 | 沿用 `AiClient.sanitize`（sk-\*\*\*）与日志纪律 |
| prompt ≤ 8KB（`AI_PROMPT_MAX_CHARS`） | 预算见 §3.2；超限截断（top 150 近装）而非报错 |
| 15s 超时不自动重试 | D4 同款；失败给重试入口（失败占位卡），不自动轮询 |

## 3. 数据流与任务层

### 3.1 装配管线（发现页进入 / 表落地时）

```
loadDiscover()（既有，不动）
  └─► loadAiSection()（新增，并行，不阻塞六榜渲染）
        ├─ 前置闸门（任一不满足 → phase='hidden'，AI 区不出现）：
        │    ① BrewInstalledLoader.snapshot() 为 null（触发一次后台 loadSets，
        │       快照落地后 installedObserver 重跑本装配）或 installed.length < AI_D4_MIN_INSTALLED(3)
        │    ② AiSettingsStore 快照无 Key（E1 静默语义，不发请求）
        │    ③ BrewTable.state() !== 'ready'（候选池无依据）→ hidden；
        │       tableObserver 落地回调里若因 ③ 隐藏则重试（BrewDiscoverVM 已订阅，复用）
        ├─ phase='loading'（feed 前插骨架卡：3 大图卡形 + 1 榜卡形灰卡）
        ├─ 组装输入：
        │    installed  = snapshot().installed 按 installedAt 降序截 AI_D4_INSTALLED_CAP(150)
        │                 → {token, kind, recent: installedAt ≥ 30 天内}
        │    candidates = BrewTable.rows(formula) top 200 + rows(cask) top 130
        │                 （按 vol30d 降序）− installed 集
        │                 → {token, kind, categoryKey}（BrewTaxonomy.categoryOf 现算）
        │    locale     = 当前 UI 语言（'zh' | 'en'）
        │    exclude    = force 时带入当前已展示 picks 的 token 列表
        ├─ AiTasks.discover(input, force)（§3.2–3.4）
        │    └─ AiCache('d4') HIT → 直接 ready；MISS/force → AiClient.complete
        │        → parseJsonSafe 逐字段校验（E4 四分：fence/truncated/schema/nonjson）
        │        → 候选池校验（G5）+ 已安装过滤 → dropped / droppedInstalled 计数
        │        → 存活 picks < AI_D4_PICKS_MIN(3) → 判失败（失败占位卡）
        │        → 渲染模型补全（§3.5）→ 写缓存 → 返回
        └─► phase='ready'（feed 前插 3 大图卡 + 1 AI 榜卡）| 'failed'（前插失败占位卡）
```

- 事件：`LOAD_AI`（进入页面 / 表落地）、`AI_RETRY`（失败占位重试）、`AI_REGENERATE`（换一批，force=true，骨架只罩榜卡位，已显示的大图卡不动——画像由安装集决定，换的是推荐不是画像）。
- `BrewInstalledLoader.subscribe` **接入**（与 tableObserver 同款成对订阅纪律）：冷启时序里进页的闸门判定常跑在第一次 `brew list` 之前，快照后落地时由 observer 重跑 `loadAiSection` 补装配。闸门发现快照缺失时还会主动触发一次后台 `loadSets()`（在途合并，不重复执行命令），用户停在发现页也能看到 AI 区自己出现。安装集变化（换批装的包）仍由 cacheKey 变化在下次装配时自然重查；页面存活期间装新包不追求实时刷新（演示无此诉求）。
- feed 重建纪律：phase 每次变化，VM 重建整个 feed 数组（AI items + `mix()` 结果）→ `cardSource.setDataArray`。AI items 的 LazyForEach key 带 phase/round（`ai_feat_${token}` / `ai_board` / `ai_skel_${i}` / `ai_failed` / `ai_skel_board`），骨架→实体切换时旧骨架 item 自然被替换；现有六榜 key（`featured_${id}` / `board_${id}`）不变，LazyForEach 复用节点不闪。

### 3.2 Prompt（单次调用，产出画像 + 推荐两个对象）

**system**（要点，实现逐句落 `AiTasks` 常量）：

```
你是 Homebrew 生态的个性化推荐引擎。根据用户已安装的包推断用户画像，
并从候选池中推荐最符合画像的包。严格输出 JSON，不要输出其他内容：
{
  "profile": {
    "headline": "≤30字画像一句话，第二人称「你」，概括技术角色与偏好",
    "tags": ["画像标签，1-4个，每个≤8字"],
    "basis": "≤40字，画像依据（引用最具代表性的已安装包）"
  },
  "picks": [
    {"token": "候选池里的包名，原样照抄", "kind": "formula|cask",
     "why": "≤40字，为什么推荐给这个画像（具体，不复述包功能）"}
  ]
}
规则：picks 恰好 10 个；token 只能取自候选池，禁止编造；不推荐已安装列表
里出现过的包；formula 与 cask 混合，比例贴合画像；全部文本用 {locale} 语言。
```

**user**（紧凑格式，预算表见下）：

```
locale: zh
installed (f=formula c=cask *=近30天):
f: git* gh* node* docker docker-compose ripgrep
c: visual-studio-code wechat
candidates (kind: token [category]):
f: ffmpeg [media]  f: ollama [ai]  …
c: raycast [productivity]  …
exclude: 上一次推荐的 token 列表（仅 force 时出现此段）
```

**字符预算**（守卫 `AI_PROMPT_MAX_CHARS=8192`）：

| 段 | 条数 | 每条约 | 小计 |
| --- | --- | --- | --- |
| installed | ≤150 | 12 chars | ≤1.8K |
| candidates | 200+130 | 17 chars | ≤5.6K |
| system + 结构 | — | — | ≈1.0K |
| exclude（force） | ≤10 | 12 chars | ≤0.12K |
| **合计** | | | **≤7.6K 常态安全**（exclude 时 7.7K） |

超限保护：installed 截 150（按 installedAt 降序，近装优先）；仍超限 → 候选池各减 20 再试一次；最终超限才 E4（守卫兜底，实际不可达）。

**调用参数**：`temperature=0.5`（推荐要多样性，高于 D2 的 0.2）、`maxTokens=1200`（10 picks × 中文 why + JSON 开销）、`requireJson=true`。

### 3.3 响应解析与校验

`parseJsonSafe` 剥栅栏 → 逐字段填充 class（`AiTypes` 新类型，与 D1 同纪律：**不把 JSON.parse 结果直接当响应对象**）：

- `AiDiscoverProfile.isValid()`：headline 非空 ≤40 字；tags 1–4 个各 ≤16 字；basis 非空 ≤60 字。
- picks：数组条数 ∈ [3, 10]（`AI_D4_PICKS_MIN`..`AI_D4_PICKS`，超 10 视为 schema 不符 → E4）；每条 token 非空、kind ∈ {formula, cask}、why 非空 ≤60 字。
- token 规范化：`toLowerCase().trim()` 后匹配（LLM 惯于首字母大写，brew token 全小写）。
- **G5 校验**：token ∈ 候选池 Set → 存活；否则丢弃计数 `dropped`（候选池即目录子集，无需再查表）。
- **已安装过滤**：token ∈ installed Set → 丢弃计数 `droppedInstalled`（LLM 违规兜底）。
- 解析失败 / schema 不符 / finish_reason=length → `AiErrorKind.E4_BAD_FORMAT`（reason 四分沿用 `AiErrorDetail`）。
- 去重：重复 token 保留首个。

### 3.4 缓存

| 项 | 值 | 理由 |
| --- | --- | --- |
| feature | `'d4'` | D1/D2/D3 之后的第四任务 |
| promptVersion | `AI_PROMPT_VERSION_D4 = 1` | prompt 改动即失效（G9 语义） |
| TTL | 1 天 | 与 D2 同款；演示一天内反复进出不重算 |
| cacheKey | `d4_{fnv1a32(installedSig)}_{epoch}_{locale}` | installedSig = 排序小写 token 逗号连接；epoch=目录世代；locale=语言。任一变 → 新 key 自动 MISS。≤64 chars 满足 `pathOf` sanitize |
| 存储内容 | `completion.content` 原文 | 与 D2 同款：读回重新 parse+校验+过滤（cacheKey 含 epoch 保证候选池未变），解析逻辑单一来源 |
| 命中语义 | HIT → 直接 ready；MISS → 生成后写回；STALE → 先展示 + 后台静默重生成写回（SWR，D1 同款） | 后台刷新失败保留旧内容不改 phase |
| 换一批（force） | 旁路读缓存直接调用；prompt 附 exclude=当前 picks tokens；**照常写回同一 key** | 重新生成语义对齐 D1；exclude 保证演示时肉眼可见换血 |

新 util：`fnv1a32(str): string`（FNV-1a 32 位 hex，brewcommon `util` 内）——安装集签名哈希，不引入 crypto 依赖。

### 3.5 渲染模型补全（零新模型，全复用既有类型）

存活 pick → **`BrewDiscoverFeatured`**（大图卡，前 3 张）与 **`BrewDiscoverBoard`**（AI 榜卡，全部 10 行），两条出口共用一套字段补全：

| 字段 | 大图卡（前 3 pick） | AI 榜行（全部 pick） |
| --- | --- | --- |
| `token` / `kind` | pick | pick |
| `id` | `BrewBrowseBuilder.tokenId(token)`（详情路由 id 口径，两入口同缓存键；点击进详情用） | 0 不可点（防御兜底；行点击走大图卡路径前先查 `BrewTable`）→ **改为同样 `tokenId(token)`**，行点击也进详情 |
| `name` | formula→token；cask→token 直显（MVP 不做市场名映射） | 同左 |
| `desc` | **目录工具简介** `BrewTable.descOf(kind, token)`（用户指定：subtitle 写工具简介） | **pick.why**（推荐理由，行副文案位自动显示——`BrewDiscoverRow` 零改动） |
| `categoryKey` | 候选池携带 | 候选池携带 |
| `installs30d` / `velocity` | 候选池 vol30d / velocity（行内「N 次安装」与右上徽章用） | 候选池携带 |
| `rank` | 存活序号 | 存活序号 |
| `boardKey` | `'ai'`（徽章文案分支） | （board 对象上）`'ai'` |
| `kind`（featured 对象上） | pick.kind | — |

- AI 榜卡：`BrewDiscoverBoard{id: 0, kind: '', boardKey: 'ai', entryCount: picks.length, entries: picks 全量}`；**id=0 且 `boardKey='ai'`** → `BrewDiscoverBoardCard` 特判全显 + Hero 标题 = profile.headline（动态注入）、kindLabel = 资源「AI 为你推荐」、Hero 渐变 = `BrewBoardStyle` 的 'ai' 映射（第八套，不与六榜重叠）、Hero 右上「换一批」↻。二级页：`BrewDiscoverBoardView` 复用，`boardId=0` 时 VM 直接取首页单例的 `aiBoard`（点进去时内容必然已生成）；行 kind 逐行取 `BrewDiscoverAiEntry.kind`（AI 榜 board.kind 恒空），标题走 `titleOf('ai')`，数据窗口行不显示。
- 画像 headline 注入：`BrewDiscoverBoard` 加一个可选 `heroTitle?: string`（默认 undefined → BoardCard 走 `BrewBoardStyle.titleOf(boardKey)` 静态表；AI 榜填 headline）。tags / basis 字段保留在 profile 里但 MVP 不渲染（headline 已承载画像主信息；后续可做画像二级页）。
- 已装角标（可选加分项）：渲染前批量 `BrewInstalledLoader.installedOf(token)`；命中 → 大图卡右上徽章位显示「已安装」（替换增速徽章），榜行尾加小角标。做不做不阻塞 G1–G8。

## 4. UX 设计（复用现有卡片，前插瀑布流）

### 4.1 版式（单 section 连续瀑布，AI 区在现有卡之前）

```
┌────────────────────────────────────────────┐
│ [顶部让位空白 FlowItem，不动]                  │
├────────────────────────────────────────────┤
│ ╔ AI 大图卡 #1 ═══════════════════════════╗  │ ← pick[0]，复用现有大图卡
│ ║            ↑22.0×（或「已安装」）           ║  │    右上徽章照旧
│ ║               ◆ symbol                   ║  │    7 套池子配色（按 id）
│ ║                                           ║  │
│ ║  工具简介（目录 desc，大字 2 行）            ║  │    ← subtitle = 工具简介
│ ║ [icon] token · 1.2k 次安装        >      ║  │
│ ╚═════════════════════════════════════════╝  │
│ ╔ AI 大图卡 #2 ╗╗ AI 大图卡 #3 ╗              │ ← md/lg 多列，同现有节奏
│ ╚═════════════╝╚═════════════╝              │
│ ╔ AI 榜卡 ═════════════════════════════════╗ │ ← 复用现有榜卡结构
│ ║ Hero: [AI 为你推荐]  专注CLI效率与云原生… [↻]║ │ ← kindLabel / 画像headline / 换一批
│ ║        （'ai' 渐变 Hero，第八套）            ║ │
│ ║ ─────────────────────────────────────── ║ │
│ ║ [icon] k9s      AI 榜行副文案=why          ║ │ ← 10 行全显
│ ║ [icon] lazygit  why（推荐理由）             ║ │    （不截 5，尾部「查看全部」进二级页）
│ ║ …（全部推荐包，每行带推荐理由）               ║ │
│ ╚═════════════════════════════════════════╝  │
├────────────────────────────────────────────┤
│ [现有 F F B B F B F B B F B，逐位不动]        │ ← stat 驱动六榜
└────────────────────────────────────────────┘
```

- **同一 section、同一 rowsGap**：AI 卡进 feed 数组，与六榜卡在同一瀑布里连续排布，交界处无断层（这正是当初 `BrewDiscoverFeedItem` 用「带类型判别字段的联合项」而不用两个 section 的原因，AI 卡只是第三个类型分支）。
- 多列：md2/lg3 下 AI 大图卡与六榜大图卡一样参与多列（3 张大图卡在 md 下 2+1 排）；AI 榜卡与六榜榜卡一样占满宽度（`CommonConstants.FULL_PERCENT`，多列瀑布里宽卡自动独占——与现状 BOARD 卡行为一致）。
- 数量：AI 大图卡 `AI_D4_FEATURED_COUNT = 3`（「若干」的落地值，评审可调；与现有 formula/trending 连排 2 张大图卡的节奏呼应）；AI 榜卡 1 张。

### 4.2 状态与骨架/失败（都是 feed item）

| phase | feed 前插内容 | 视觉 |
| --- | --- | --- |
| `hidden` | 无 | AI 区不存在，六榜从顶部开始（现状） |
| `loading`（首载） | 3 大图卡形骨架 + 1 榜卡形骨架 | 与实体卡同尺寸灰卡：渐变位→`comp_background_tertiary` 灰、文案位→灰条、`opacity 0.5→1.0` 脉冲 1.2s（App Store 形状占位，不用转圈） |
| `ready` | 3 大图卡 + 1 AI 榜卡 | §4.1 |
| `loading`（换一批） | 3 大图卡保留 + 榜卡形骨架 | 只有榜卡位回骨架；大图卡与画像不动 |
| `failed` | 1 失败占位卡 | 榜卡尺寸：'ai' 渐变 Hero（品牌位保留）+「AI 推荐暂不可用」Body_M +「重试」按钮（`AI_RETRY`）；六榜照常在后 |

- 状态机迁移：`hidden --闸门全过--> loading --成功--> ready`；`loading --失败--> failed --重试--> loading`；`ready --换一批--> loading(仅榜)--> ready'`；安装集/目录/语言变化（cacheKey 变）→ 下次进入自动 MISS → ready 新内容。
- 事件：`LOAD_AI` / `AI_RETRY` / `AI_REGENERATE`（§3.1）。
- 换一批入口 = AI 榜卡 Hero 右上 ↻ 小按钮（40vp 圆钮，同大图卡 chevron 圆钮规格）；进行中转 `LoadingProgress` 小号。

### 4.3 视觉规范（全部从现有体系派生，唯一新增 = 'ai' 映射）

| 元素 | 来源 | AI 区取值 |
| --- | --- | --- |
| 大图卡全部视觉 | `BrewDiscoverFeaturedCard` 现状 | **零改动**：渐变 7 套池子按 `tokenId` 确定性取、symbol 分类字形、底部内容块/圆钮规格全复用 |
| 大图卡右上徽章 | 现状 = 增速 `↑22.0×` | 保留增速（velocity 来自候选池）；已装角标命中时替换为「已安装」 |
| 榜卡 Hero 渐变 | `BrewBoardStyle.colorStartOf/EndOf(boardKey)` 六套 | **新增第八套 'ai' 映射**：与六榜不重叠即可（具体色值实现时按 `BrewBoardStyle` 现有六套的明度纪律选，浅深两模式各一对） |
| 榜卡 Hero symbol | `BrewBoardStyle.symbolOf` | 'ai' → sparkle/星形类 HDS symbol；不存在则复用 `sys.symbol` 通用「推荐」形，不阻塞 |
| 榜卡行 | `BrewDiscoverRow` | **零改动**（desc 位填 why 自动生效） |
| AI 身份标识 | — | 徽章/Hero 文字「AI 为你推荐」+ 'ai' Hero 渐变。**不给大图卡换色**：与「榜的身份由文字承担」决策同源，且 3 张 AI 大图卡混在池子配色里与六榜大图卡视觉连续 |

### 4.4 资源（`features/brewdiscover/.../resources/{base,zh_CN,en_US}/element/string.json`）

| key | zh | en |
| --- | --- | --- |
| `brew_discover_ai_badge` | AI 为你推荐 | AI Picks for You |
| `brew_discover_ai_regenerate` | 换一批 | Refresh Picks |
| `brew_discover_ai_failed` | AI 推荐暂不可用 | AI Picks Unavailable |
| `brew_discover_ai_retry` | 重试 | Retry |
| `brew_discover_ai_installed_badge` | 已安装 | Installed |

（base 与 zh_CN 同文；float.json 不新增——大图卡尺寸全复用现有常量。）

## 5. 常量（`AiConstants.ets` 新增）

```
AI_FEATURE_D4 = 'd4'
AI_PROMPT_VERSION_D4 = 1
AI_CACHE_TTL_D4_MS = 24h
AI_TEMPERATURE_D4 = 0.5
AI_MAX_TOKENS_D4 = 1200
AI_D4_MIN_INSTALLED = 3          // 少于 3 个包推不出画像 → hidden
AI_D4_INSTALLED_CAP = 150        // prompt 安装清单上限（installedAt 降序截）
AI_D4_POOL_FORMULA = 200         // 候选池 formula 条数（vol30d 降序）
AI_D4_POOL_CASK = 130            // 候选池 cask 条数
AI_D4_PICKS = 10                 // 期望输出 picks 数（prompt 写死）
AI_D4_PICKS_MIN = 3              // 过滤后存活下限，低于判失败
AI_D4_FEATURED_COUNT = 3         // 上大图卡的 picks 前缀数（「若干」的落地值）
AI_D4_PROFILE_TAGS_MAX = 4
AI_D4_HEADLINE_MAX_CHARS = 40
AI_D4_WHY_MAX_CHARS = 60
AI_D4_BASIS_MAX_CHARS = 60
AI_D4_RECENT_DAYS = 30           // 「近装」标记窗口
```

## 6. 文件清单与改动点

| 文件 | 动作 | 要点 |
| --- | --- | --- |
| `features/brewcommon/src/main/ets/model/AiTypes.ets` | 改 | +`AiDiscoverProfile{headline,tags[],basis,isValid()}`、`AiDiscoverPick{token,kind,why}`、`AiDiscoverResult{profile,picks,dropped,droppedInstalled}`、`AiDiscoverInput{locale,installed[],candidates[],exclude[]}`、紧凑条目 `AiInstalledBrief{token,kind,recent}` / `AiCandidate{token,kind,categoryKey,vol30d,velocity}` |
| `features/brewcommon/src/main/ets/constant/AiConstants.ets` | 改 | §5 全量 |
| `features/brewcommon/src/main/ets/service/AiTasks.ets` | 改 | +`public static async discover(input: AiDiscoverInput, force: boolean): Promise<AiDiscoverResult>`（缓存查找/写回、G5 校验、E4 四分、fnv1a32 组 cacheKey）+ prompt 组装/解析私有函数；复用 `parseJsonSafe`/`lookup` 结构 |
| `features/brewcommon/src/main/ets/util/`（新文件） | 新 | `fnv1a32(str): string` FNV-1a 32 位 hex |
| `features/brewdiscover/src/main/ets/viewmodel/BrewDiscoverState.ets` | 改 | +`aiPhase`/`aiProfile`/`aiFeatured[]`/`aiBoard`/`aiErrorKind`/`aiRound` |
| `features/brewdiscover/src/main/ets/viewmodel/BrewDiscoverVM.ets` | 改 | +`loadAiSection()`（闸门→AiTasks.discover→渲染模型补全→phase→重建 feed）；事件 `LOAD_AI`/`AI_RETRY`/`AI_REGENERATE`；feed 拼接 `[AI items, ...mix(featured, boards)]`；tableObserver 落地重试 hidden 态 |
| `features/brewdiscover/src/main/ets/model/BrewDiscoverFeedItem.ets` | 改 | `BrewDiscoverFeedType` +`AI_SKELETON_FEATURED`/`AI_SKELETON_BOARD`/`AI_FAILED`；key 分支（`ai_feat_${token}`/`ai_board`/`ai_skel_${i}`/`ai_failed`）；骨架/失败 item 的工厂方法 |
| `features/brewdiscover/src/main/ets/view/BrewDiscoverBaseView.ets` | 改 | LazyForEach 渲染分支 +3（骨架大图卡/骨架榜卡/失败卡 → 新小组件）；`jumpDetail` 对 AI 榜行/大图卡复用（kind 从 entry/board 判定同现状） |
| `features/brewdiscover/src/main/ets/component/BrewDiscoverBoardCard.ets` | 改 | `boardKey==='ai'` 特判：行全显（不 slice 5）、Hero 走 `heroTitle ?? titleOf`（board 对象新增可选字段）、「查看全部」行进 boardId=0 二级页 |
| `features/brewdiscover/src/main/ets/component/BrewDiscoverAiSkeletonFeaturedCard.ets` | 新 | 大图卡形骨架（灰卡 + 脉冲），尺寸=400vp 常量复用 |
| `features/brewdiscover/src/main/ets/component/BrewDiscoverAiSkeletonBoardCard.ets` | 新 | 榜卡形骨架（Hero 灰块 + 行灰条 ×4） |
| `features/brewdiscover/src/main/ets/component/BrewDiscoverAiFailedCard.ets` | 新 | 失败占位卡：'ai' 渐变 Hero + 文案 + 重试按钮 |
| `features/brewcommon/src/main/ets/model/BrewModels.ets` | 改 | `BrewDiscoverBoard` + 可选 `heroTitle?: string`（AI 榜注入画像 headline；现有六榜不填，行为不变） |
| `features/brewdiscover/src/main/ets/model/BrewBoardStyle.ets` | 改 | +'ai' 映射：`titleOf('ai')`（兜底「为你推荐」，AI 榜实际用 heroTitle）、'ai' Hero 渐变一对（浅/深）、symbolOf('ai') |
| `features/brewdiscover/.../resources/.../element/string.json`（×3） | 改 | §4.4 资源 |
| `README.md` 文档索引 | 改 | 本 spec 入链 |

不改动：`AiClient` / `AiCache` / `AiSettingsStore` / `BrewInstalledLoader` / `BrewTable` / `BrewDiscoverFeaturedCard` / `BrewDiscoverRow` / `BrewDiscoverHero` / 六榜生成链路 / `mix()` 本体。

## 7. 验收清单（演示脚本）

1. **成功路径**：pc_acl 模拟器，已配 DeepSeek Key，预装 ≥10 个特征鲜明的包（git/gh/node/docker/k9s/visual-studio-code/wechat…）→ 进发现页：骨架 → AI 区出现（3 大图卡 + 1 AI 榜卡），headline 贴合画像（中文系统出中文）、榜卡 10 行每行 why 具体不重复、大图卡 desc = 目录工具简介。
2. **视觉连续性**：AI 大图卡与现有大图卡同一视觉语言（池子配色/symbol/底部内容块）；AI 区与六榜在同一瀑布无断层；`F F B B F B F B B F B` 逐位排在 AI 区之后不变。
3. **详情联动**：点 AI 大图卡/榜行 → 详情页正常打开（token/kind/categoryKey 正确，「同分类其他包」可用）。
4. **缓存命中**：退出页签再进（10 分钟内）→ AI 区秒出，日志 `[AiTasks]` cache hit，无新请求。
5. **换一批**：点 AI 榜 Hero ↻ → 只有榜卡位回骨架 → 新一批与前一批无重复（exclude 生效，日志可见 exclude 列表）；大图卡与画像不动。
6. **失败与重试**：飞行模式进页面 → 失败占位卡；恢复网络点重试 → 恢复；全程六榜正常、滚动不崩。
7. **无 Key 静默**：清掉 Key → AI 区整块不出现，无引导文案，六榜如常（G6）。
8. **pc_normal**：双 product 构建 ERROR 0；AI 区永不出现（安装数据恒空）。
9. **幻影包防御**：构造 LLM 输出编造 token（临时改 prompt 注入）→ 日志 dropped 计数、UI 只显示目录内存活条目（G3）。
10. **主链路零回归**：`mix(featured, boards)` 输出数组逐位不变（AI 卡在 mix 结果之外前插，不进 mix）；六榜 LazyForEach key 不变。

## 8. 风险与开放问题

- **大图卡数「若干」= 3**：评审可调（2–5 均合理；过大则 AI 区太重压过六榜）。同理 picks=10、池 200+130 都是拍脑袋值，评审定。
- **'ai' Hero 渐变具体色值**：按 `BrewBoardStyle` 六套的明度/对比纪律选一对，实现时定；不与现有六套重叠。
- **sparkle 类 symbol 是否在 HDS 集合**：实现时确认；不存在用通用「推荐」形或分类字形兜底，不阻塞。
- **AI 榜卡行数**：10 行全显使 AI 榜卡比六榜榜卡（5+查看全部）长一截；尾部「查看全部」进 boardId=0 二级页（复用现有 `BrewDiscoverBoardView`，数据取首页 VM 的 aiBoard）。
- **已装角标**：加分项不阻塞；做的话大图卡右上徽章位替换逻辑要与增速徽章互斥（已装优先）。
- **JSON 输出稳定性**：DeepSeek jsonObject 模式 + maxTokens 1200 下 10 picks 中文输出实测预算内；截断 → E4-truncated，重试可解。
- **候选池新鲜度**：epoch 进 cacheKey，目录换代自动重算；「换一批」同 key 覆盖写（刻意：安装集没变，画像不该变）。
