# 头脑风暴 Round 1 · 鸿蒙 PC + Harmonybrew 还能做什么

> 日期：2026-11-21。状态：已整理归档，供评审 / 立项参考。
> 本文档是第一轮头脑风暴的**收敛记录**：一轮初始提案 → 需求方逐条修正 → 保留集。
> 后续轮次写入同目录 `round2.md`、`round3.md`…，否决项在 §3 累积，防止重提。
> 口径约定：事实以代码与实测笔记为准（引用处标路径）；外部事实标注来源链接。

---

## 1. 背景与可复用资产

### 1.1 项目现状（一句话）

BrewLibrary 是鸿蒙生态首个 Homebrew 客户端：上游全量目录（16,356 包）浏览、设备端现算榜单、
离线搜索、直连 brew 的本机包管理与命令执行、upstream / Harmonybrew 双方言多源。

### 1.2 本轮创新点要踩的地基

| 资产 | 位置 | 对创新点的意义 |
|---|---|---|
| 本机命令执行通道 | `features/pcnative`（NAPI + Shell）、`BrewCli` / `BrewCommandRunner` | 批量安装队列、Doctor / vulns GUI、AI 报错诊断的执行底座 |
| Harmonybrew 日下载量 | `HarmonybrewStats`（`/stats/stats-YYYYMMDD.json`，30+60=90 天窗口，逐日落盘） | 榜单已在用；趋势线 / 新适配速递的免费数据源 |
| 双方言目录 | 上游 fullsync 索引（`brew_meta_index`，token → desc）+ Harmonybrew `catalog.tsv`（JWS，ETag 条件请求可靠） | 适配状态引擎 join 的两端 |
| 本机已装包数据 | `BrewInstalledLoader`（`brew info --json=v2 --installed`） | 迁移工作台的导出侧 |
| 端侧搜索引擎 | `BrewSearchEngine`（16k token + desc 全量索引，零依赖纯函数） | 自然语言找包的排序兜底 |
| 分类词表 | `BrewTaxonomy`（lexicon + tokens 策展） | AI 讲解 / 推荐的 grounding 素材 |

---

## 2. 事实修正（本轮 brainstorm 的前提）

第一轮初始提案里有几处事实错误，修正后才有方向。**后续轮次不要再基于旧事实提案。**

### 2.1 Harmonybrew 有 analytics（`HarmonybrewStats`）

`harmonybrew.atomgit.com` 在站点根 `/stats/` 下发布**按日下载量文件**
（`/stats/stats-YYYYMMDD.json`——不在 `/api` 下、文件名带 `stats-` 前缀，
拼 URL 必须用 originJoin，见 `HarmonybrewStats.statsUrl` 的注释）。
`HarmonybrewStats` 取 30+60=90 个日历日窗口（逐日缓存于
`filesDir/brew_src/<sourceId>/stats/<YYYYMMDD>.json`），合成 30d / 365d 两份
analytics doc 喂给现有榜单算法（`365d` 桶实为 90 天累计，口径见 `sumWindows`）。

**推论：「鸿蒙热度榜」已经存在**——Harmonybrew 源激活时 Discover 六张榜跑的就是
鸿蒙真实下载量。它不是待做创新，是已实现能力（第一轮曾误判为待做项）。

### 2.2 沙箱 brew 与系统 brew 是两个环境（实测）

见 `docs/knowledge/2026-11-21-brew-tap-trust.md`（brew 7.0.9_7 实测）：
HiShell 的 `trust.json` 在 `/data/storage/el2/base/...`；应用进程 26 项 `env` 里
一个 `XDG_*` 都没有 → 走 else 分支读 `/storage/Users/currentUser/.homebrew/trust.json`
（空 store）；跨沙箱读 HiShell 那份被 MAC 拦（EPERM，`hmmac=genfs`）。
**两边的 tap 与 trust 互不相通。** 应用自写 trust.json（name + URL 两条）的通路已实测打通，
但只配作执行链路的内部细节，不构成独立功能。

### 2.3 Harmonybrew 生态处于早期

- core 规模：2026-09-24 实测 4,761 formula（cask 为空）；会增长，引用时标口径。
- **基本不接受外部贡献** → 「催适配 / 生态贡献闭环」类提案不成立。
- 第三方 tap 数量少（如 social4hyq/core）→ 「Tap 市场」缺内容基础。

### 2.4 Homebrew 7.0（2026-09-13）发布官方 GUI「BrewUI」

- SwiftUI 原生，**仅 macOS 26+**，当前 v0.4.1；功能面 = 发现 / 已装 / 卸载 / 监控 /
  依赖查看 / Doctor 集成；
- 同版本新增 `brew vulns` 漏洞扫描（可查已装 formula、单条 formula 或 Brewfile 依赖树），
  配套 **OSV 格式的 Homebrew advisory 数据库、CC0 许可**；
- 来源：[brew.sh 7.0.0 公告](https://brew.sh/2026/09/13/homebrew-7.0.0/)、
  [heise 报道](https://www.heise.de/en/news/Homebrew-7-for-macOS-released-Catalina-support-gone-Intel-to-follow-11452780.html)。

**生态位推论**：官方 GUI 不存在于鸿蒙。BrewLibrary 是该平台上的对位物——功能面可以对齐
（Doctor / 依赖树 / vulns），且拥有 BrewUI 没有也不需要有的鸿蒙独有物（适配引擎、迁移工作台）。

---

## 3. 已否决方向（不要再提）

| # | 方向 | 否决理由 | 备注 |
|---|---|---|---|
| 1 | 催适配 / 生态贡献闭环（一键提 issue / PR、催上游适配） | Harmonybrew 早期基本不接受外部贡献（需求方） | 「新进了什么」可作只读展示，见 C1 |
| 2 | Tap 市场 + `brew trust` GUI 化 | 沙箱 brew 与系统 brew 双环境不通（§2.2 实测）；当前 tap 数量少，属伪命题（需求方） | — |
| 3 | brew services 服务面板 | 没有用户把鸿蒙 PC 当家庭服务器（需求方） | `serviceSupported` 字段维持详情页现状 |
| 4 | 跨端到手机（手机浏览、安装到 PC） | 有意义但不大：「谁会在手机上查看 homebrew」（需求方） | — |
| 5 | 「鸿蒙热度榜」作为新功能 | 已实现（§2.1），不是待做项 | 后续只做体验增量（C2 / C3） |

---

## 4. 保留的创新点

### 4.1 A · 适配状态引擎（鸿蒙独有问题域，主推）

**一句话**：回答「这个包我的鸿蒙 PC 装得上吗」，把 App 从「上游目录浏览器」变成「鸿蒙包目录」。

- **双目录 join**：上游 fullsync 索引（`brew_meta_index`，token → desc）× Harmonybrew
  `catalog.tsv`，端侧 set join 得适配态：✅ core 已适配 / ❌ 未适配 / ⚠️ 上游 deprecated·disabled。
- **设计点**：适配态是**元数据**，不是浏览源——与「会话冻结单源」解耦。Harmonybrew 目录
  作为独立参考数据集后台同步（它本就是内置源、ETag 条件请求可靠），无论当前浏览哪个源都可查。
- **依赖缺口求解（进阶）**：未适配包点「查可装性」→ 拉上游 per-token 详情 → 依赖闭包逐个查
  Harmonybrew 目录 → 输出「依赖 12 个，11 个已适配，缺 `xyz`」。懒加载、按 token 缓存，
  不做全量预算（索引里只有 desc，依赖字段必须走单条详情）。
- **展示**：列表行 / 详情页适配徽章 + 「只看鸿蒙可装」筛选 chip。
- **风险**：Harmonybrew core 规模持续增长（4,761 是 2026-09 口径），join 结果要带数据日期戳。

### 4.2 B · Mac → 鸿蒙迁移工作台（依赖 A，主推）

**一句话**：「把你的 Mac 工具链搬到鸿蒙 PC」——只有这个平台存在、也只有这个 App 能做的场景
（需要双目录 join + 执行通道，两者都有）。

- **导入**：粘贴 Mac `brew bundle dump` 输出 → 解析 `brew "..."` / `cask "..."` 行（纯文本，
  零依赖）→ 适配态逐条标注（用 A）→ 勾选进**批量安装队列**（现有执行 Sheet 从单命令升级为
  队列：逐个执行、进度、失败续跑）。
- **导出**：`brew info --json=v2 --installed` 数据已在手（`BrewInstalledLoader`），反向生成
  Brewfile 写入应用认领的 `Download/<bundleName>/`——备份、分享、团队标准化
  （新人拿一份 Brewfile 复现环境）。

### 4.3 C · Discover 打磨（应用重点，真增量）

| # | 点子 | 数据来源 | 成本 |
|---|---|---|---|
| C1 | **新适配速递**：连续两次 Harmonybrew 目录同步做 token 集合 diff，「本周 core 新进了什么」 | 纯端侧，零额外请求（只存上一版 token 集，几千字符串） | 低 |
| C2 | **90 天趋势线**：详情页热度区加「近 90 天鸿蒙下载走势」sparkline | `stats/` 日文件已在盘上缓存，当前只被 sum 成窗口，没人逐日读它 | 低 |
| C3 | **双榜对比**（可选，低优先）：全球榜 vs 鸿蒙榜差集，「鸿蒙用户在装什么 vs Mac 用户」 | 受会话冻结单源限制，需跨源读缓存 | 中 |
| C4 | **AI 编程工具策展榜**：claude-code / opencode / zcode 等当下最热 formula 的真实下载量榜 | Harmonybrew stats（已有） | 低 |

### 4.4 D · AI 热点（需求方点名方向）

| # | 点子 | 关键设计 | 实现路径 |
|---|---|---|---|
| D1 | **AI 讲解包**：详情页中文讲解「这是干嘛的、装完怎么用、适不适合你、caveats 有什么坑」（吸收第一轮「装后引导」） | grounding 严格限定包元数据（desc / caveats / dependencies / homepage）；标注「AI 生成」；按 token 缓存（沿用 `brew_live_data` 的 TTL 模式） | 系统小艺 / 云侧 LLM（走现有 `BrewHttp`） |
| D2 | **自然语言找包**：「我想批量压缩图片」→ imagemagick / ffmpeg | **AI 出候选、词表出排序**：LLM 只做意图 → token 候选，交给现有 `BrewSearchEngine` 打分，幻觉被引擎兜住 | 同上；语料（16k token + desc）已在端上 |
| D3 | **AI 报错诊断**：执行 Sheet 失败时把 brew stderr 原文交给 AI 解读成用户语言 | 在现有失败态处理之上加一层「AI 解读」入口，不替代失败分类 | 同上；失败输出已在执行链路里 |

### 4.5 E · BrewUI 生态位对标（叙事 + 两个可落地功能）

- **叙事**（答辩 / 评审用）：「BrewUI 只存在于 macOS 26+；鸿蒙上的对位物是 BrewLibrary」——
  功能面对齐清单 + 鸿蒙独有物（A / B）。
- **Doctor GUI**：`brew doctor` 输出结构化成「问题-影响-修复动作」卡片，每卡带一键修复
  （经 `BrewCli` 执行）——对齐 BrewUI 的 Doctor 集成。
- **vulns 安全面板**：Homebrew 7.0 的 advisory 数据库是 **OSV 格式、CC0 许可**，可直接消费做
  「已装包漏洞提示」；设备 brew 实测为 7.0.9（`brew vulns` 自 7.0.0 起存在），也可经 `BrewCli`
  执行后 GUI 化渲染。
- ⚠️ **待验证**：advisory 库跟踪的是上游 formula 版本，Harmonybrew bottle 版本是否被覆盖
  需真机实测（按「实测先行」的规矩，验证前不进实施计划）。

---

## 5. 优先级建议

| 创新点 | 强度 | 成本 | 依赖 / 备注 |
|---|---|---|---|
| A 适配状态引擎 | ★★★★★ | 中 | 地基；依赖缺口求解做懒加载 |
| B 迁移工作台 | ★★★★★ | 中 | 依赖 A；批量队列是执行 Sheet 的自然升级 |
| D1 AI 讲解包 | ★★★★ | 低-中 | AI 热点里最稳的，grounding 好做 |
| C1 新适配速递 | ★★★★ | 低 | 纯端侧 diff，性价比最高 |
| D2 自然语言找包 | ★★★★ | 中 | AI 候选 + 现有引擎排序 |
| C2 90 天趋势线 | ★★★ | 低 | 数据已在盘上 |
| E Doctor / vulns 面板 | ★★★ | 中 | CC0 数据源 + 对标 BrewUI；vulns 覆盖度先实测 |
| C4 AI 工具策展榜 | ★★★ | 低 | 真实数据蹭 AI 热点 |
| D3 AI 报错诊断 | ★★★ | 低-中 | 执行闭环纵深 |
| C3 双榜对比 | ★★ | 中 | 低优先级 |

**推荐组合**：A + B 打包做主菜（鸿蒙独有问题域）；C1 + D1 做快赢（一个纯端侧零请求、
一个蹭 AI 热点）；E 做叙事（官方 GUI 只在 macOS 26+，鸿蒙上的对位物是我们）。

---

## 6. 下一步与遗留

1. 任一方向可展开为正式 spec（`docs/superpowers/specs/` 格式：数据流、失败态分级、验证判据）；
   A / B 建议合并为一份（迁移工作台消费适配引擎的输出）。
2. E 的 vulns 覆盖度实测可先行——设备上一条命令的事，结论直接决定是否立项。
3. 第一轮提出、本轮未展开讨论的：**深链安装协议**（`brewlibrary://install/<token>`，
   社区教程一键安装）——留待后续轮次表态。
4. 后续轮次写入本目录，否决项沿用 §3 表格累积；本文档 §2 的事实修正对后续轮次长期有效。
