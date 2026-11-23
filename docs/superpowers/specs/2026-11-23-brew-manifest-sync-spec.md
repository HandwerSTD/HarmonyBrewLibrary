# 工具清单同步（W′ v0 · 文件流）· 设计

> 日期：2026-11-23。状态：待评审。评审通过后按「构建顺序」第 6 位实施（主线四：B′ 路径② Brewfile 导入 + W′ v0 文件流）。
> 范围：`features/brewcommon` 新增 Brewfile 解析器与批量安装队列 service；`features/mine` 新增「工具清单同步」页与「安装队列」页；
> `hmosword-build` 新增解析器检查脚本；文案（zh/en）。
> 叙事定位：motivation「主线四 · 工具链跟着人走」——「换机一键复制 CLI 环境、双机互见」。裁决与排序见
> [`decisions.md`](../../2026-11-21-brainstorm/decisions.md)（31 号 W′ v0 文件流，第一梯队；构建顺序第 6 位）。
> 机制分级是本 spec 的第一约束：**v0 只做文件流**（导出一个文件、经任何渠道自传、零云依赖）；
> v1 账号端云同步已被 [`rejected.md`](../../2026-11-21-brainstorm/rejected.md) §2 第 3 条否决（默认关、显式开启、需隐私评估），
> 本 spec 不为其预留任何后门字段。同理，系统分布式能力（流转/接续/分布式数据对象）已被 rejected.md §1 第 14 条否决
> ——brew 的一切事实都在本机，「多设备」在本 spec 中是**人的多设备**（文件跟着人走），不是设备的分布式协同。
> 相关文档：[`2026-10-04-brew-command-execution-spec.md`](2026-10-04-brew-command-execution-spec.md)（执行 Sheet / 中断 / 退出码，本 spec 的执行底座）、
> [`2026-10-04-brew-installed-packages-spec.md`](2026-10-04-brew-installed-packages-spec.md)（已装列表与 install-on-request 口径）、
> [`2026-10-05-brew-detail-action-bar-spec.md`](2026-10-05-brew-detail-action-bar-spec.md)（底部悬浮操作栏复用）、
> [`../../knowledge/2026-11-21-brew-cache-ownership.md`](../../knowledge/2026-11-21-brew-cache-ownership.md)（缓存归属——队列文件不是缓存）、
> CloudPurePlay `docs/deprecated/2025-07-30-settings-import-export-design.md`（导出/导入 UX 参考：摘要确认、错误分类、保存选择器模式）。

---

## 0. 一句话

把我主动安装的工具（`brew bundle dump` 的口径）导出成一个 Brewfile 语义的文本文件；在另一台设备上把它导入回来——
与本机已装清单做差集，逐条标注、勾选、进批量安装队列。**W′ v0 = 应用版的 `brew bundle dump` + 带 UX 的 `brew bundle install`。**

---

## 1. 目标与成功判据

| # | 判据 | 可观测证据 |
| --- | --- | --- |
| G1 | pc_acl：「我的 → 设置」出现「工具清单同步」行，点击进入同步页 | 真机 |
| G2 | 导出生成 Brewfile 语义文本：`tap` 行（仅非默认 tap）+ `brew`/`cask` 行（**仅主动安装**，依赖不同步），头部为 `#` 注释元数据 | 文件内容比对；`[BrewManifest] export items=N formula=F cask=C taps=T bytes=B` |
| G3 | 导出的文件与 brew 生态兼容：新 Mac 上 `brew bundle install --file=<该文件>` 可直接消费（注释行被 brew 忽略）；反之，Mac `brew bundle dump` 的产物可被本应用导入 | 沙盒比对（不要求真机） |
| G4 | 导入：选择文件 → 解析 → 与本机已装 diff 标注 → 勾选 → 批量安装逐条执行 → 已装列表出现新包 | 真机；`[BrewManifest] parse lines=L valid=V ignored=I`、`[BrewQueue] item token=… status=done exit=0` |
| G5 | 双机互见（文件流近似）：导入预览出现亮点行「另一台设备有 N 个你没有的工具」，且 N = 清单项 − 本机已装 | 真机 |
| G6 | 队列落盘：批量执行中途杀进程，重启应用后队列恢复（执行中条目回 `pending`），可继续 | 真机（kill 后重启）；`filesDir/brew_state/install_queue.json` 存在且状态正确 |
| G7 | 失败续跑：失败条目可单独重试；「重试失败项」批量重置 | 真机 |
| G8 | 中断语义：执行中暂停 = interrupt 当前条目（SIGINT→SIGKILL 既有链路），队列停止，剩余条目保持 `pending` 可恢复 | 真机；`[BrewQueue] pause at token=… reason=interrupt` |
| G9 | 执行 Sheet 复用：队列执行期间，全局 BrewCommandSheet 显示当前条目的流式输出，可关闭可重开（`BrewCommandState` 单例语义不变） | 真机 |
| G10 | pc_normal：设置页**不出现**「工具清单同步」行（随 `BREW_CLI_ENABLED`，同 sentinel 行模式） | 真机（pc_normal） |
| G11 | 非清单文件（无任何合法行）→ Toast「不是有效的清单文件」，无崩溃；超 1MB 文件 → 拒读 | 真机 |
| G12 | 双 product 构建通过 | `devecocli build --product default` 与 `--product pc_normal` 双绿 |
| G13 | 队列文件**不**属于缓存：CacheAdmin 一键清理后 `brew_state/install_queue.json` 仍在 | 真机；文件存在性 |
| G14 | 解析器检查脚本全绿（构造用例：注释头/tap 行/带版本 pin/cask 行/全名行/BOM/CRLF/空行/垃圾行/超限） | `node hmosword-build/brew-manifest/check_manifest_parser.mjs` |

**成功判据的总原则**：W′ 是「主线四」的证据件，且 decisions.md 已裁定它**无实测门槛**（复用既有链路）——
所以本 spec 的全部新风险集中在三处：保存选择器先例为零（§10）、队列是新的执行形态（§3.2）、导入页是新的交互（§4）。

---

## 2. 现状

| 位置 | 现状 |
| --- | --- |
| `features/brewcommon/src/main/ets/service/BrewCommandRunner.ets` | 单命令执行通道已建成：单飞（BUSY）、流式输出、超时、SIGINT→SIGKILL 中断、`BrewCommandState` 是 `@Observed` 单例（Sheet 可关可重开续看）。**当前是单命令，不是队列**——本 spec 新增的队列 service 逐条复用它 |
| `features/brewcommon/src/main/ets/service/BrewInstalledLoader.ets` | 静态类：`snapshot()` 同步取内存快照、`loadSets()` 异步合并等待、写命令结束自动 `invalidate()`。导出取数与导入 diff 都以它为唯一数据源（同构 BrewSentinelService「只读快照、绝不自己跑命令」模式） |
| `features/brewcommon/src/main/ets/util/BrewInstalledParser.ets` | `installedOnRequest`：formula 取最新 keg 的 `installed_on_request === true`；cask 恒 true（投影无此字段，按主动安装）。tap 信息在 `fullName`（`homebrew/core/wget`）/`full_token`（`tap/token`）里 |
| `features/brewcommon/src/main/ets/util/BrewCommandGenerator.ets` | `qualifiedName(token, tap)`（非默认 tap 拼 `tap/token`）、`installArgs(kind, token, tap)`、`isSafeName`（允许 `@ + . _ - /`，首字符字母数字，长 1–128）。导出是它的逆运算，安装是它的正向复用 |
| `features/pcui/src/main/ets/view/PcMainPage.ets` | BrewCommandSheet 全局宿主（bindSheet 绑 `commandState.sheetShown`）——队列执行零改动即可复用 |
| `features/mine/src/main/ets/view/MineSettingView.ets` | 设置页导航列表（HmosListItem×ListItemGroup），sentinel 行已是「`if (isLocalPackagesEnabled())` + G10 注释」的样板——同步入口行照抄此模式 |
| `features/mine/src/main/resources/base/profile/router_map.json` | 页面路由注册表；新页面需登记 name/pageSourceFile/buildFunction，并在 `common/src/main/ets/model/PageEnum.ets` 加枚举 |
| 文件选择器 | 全工程仅 `features/hmkit-ai/src/main/ets/attachment/Attachments.ets:49` 一处 `picker.DocumentViewPicker(context).select()` 先例（@kit.CoreFileKit）。**保存选择器（save）零先例**——本 spec 引入，CloudPurePlay `BackupRestoreSettings.ets`（picker→temp→save→copy→清 temp）是参考实现 |
| 缓存归属（`docs/knowledge/2026-11-21-brew-cache-ownership.md`） | `filesDir/brew_live/*` 是缓存（CacheAdmin 统一清理、CacheEpoch 切源清理）。**队列文件是用户任务状态不是缓存** → 新目录 `filesDir/brew_state/`，不进 CacheAdmin（G13） |
| B′ 工作台 | brainstorm round1 提案（粘贴/拖拽/文件导入三入口 + 三色画布 + 批量队列），**尚无 spec**。本 spec 把「文件导入路径 + 批量队列」落地为 B′② 的第一块砖；粘贴/拖拽入口与三色画布留给 B′ 工作台 spec（§范围外） |

---

## 3. 数据流与缓存

### 3.1 导出：快照 → Brewfile 文本 → 保存选择器

```
「导出清单」按钮
  → BrewInstalledLoader.loadSets()            // T2：按钮 spinner；有新鲜快照立即返回，无则后台刷新等待
  → snapshot().sets.installed
      过滤 installedOnRequest === true         // W′ 口径：只同步主动安装；cask 恒 true
  → BrewfileBuilder.build(items): string       // 纯函数
      1) 头部注释（见下）
      2) tap 行：逐包从 fullName/full_token 剥 tap 前缀（lastName 段为 token，
         其余为 tap；无 / 前缀 = 默认 tap），收集**非默认 tap** 集合
         （默认 = homebrew/core、homebrew/cask），排序去重
      3) brew 行：kind=formula 且主动安装，按 name 排序
      4) cask 行：kind=cask，按 name 排序
  → 写临时文件 filesDir/temp/manifest_<ts>.txt
  → picker.DocumentViewPicker.save(newFileNames=['Brewfile-<yyyyMMdd-HHmm>.txt'])
      // 用户选位置（默认落系统 Download）；save picker 是唯一合规写公共目录的路径
  → fs 拷贝 temp → saveUri；finally 删 temp    // CloudPurePlay 模式
  → Toast「已导出：<用户可见路径/文件名>」
  → [BrewManifest] export items=N formula=F cask=C taps=T bytes=B
```

**导出文件格式（v1，Brewfile 方言 + 注释头）：**

```
# HarmonyBrewLibrary tool manifest v1
# exported_at=2026-11-23T20:30:00+08:00
# items=12 formula=11 cask=1
tap "user/tap"
brew "gh"
brew "wget"
cask "visual-studio-code"
```

- `#` 注释行是 brew bundle 的合法语法（被其忽略），同时是应用自己的元数据（导入预览显示「导出于 …」）——**一份文件，两个消费者，零私有格式**。
- **不导出版本号**（Brewfile 支持 `brew "wget", "1.2.3"` pin）：工具链跟人走，不是复现实验环境；跨设备/跨源版本无意义，版本随源走。
- **不导出依赖包**：W′ 口径（round5 需求方裁定：全量 Brewfile 太庞大且无意义）。
- 文件后缀 `.txt`：微信/邮件/选择器三头通吃（无后缀 `Brewfile` 在部分渠道与选择器里都会遇到摩擦）；内容即 Brewfile，改名 `Brewfile` 后 `brew bundle` 照常可用（G3）。

### 3.2 批量安装队列：落盘 service + 逐条复用 Runner

**队列是落盘数据，不是内存态**——rejected.md §2 第 2 条（手机遥控否决）留的门：「批量安装队列落盘为数据，
未来任何前端触发同一队列零架构改动」。文件：`filesDir/brew_state/install_queue.json`（不属于 CacheAdmin，G13）。

```
BrewInstallQueue（单例实例，对齐 BrewCommandRunner 的单例风格）
  schema（JSON, version=1）:
  { items: [ { token, kind, tap, status: pending|running|done|failed,
               attempts, lastExitCode, lastStartedAt, lastEndedAt } ],
    createdAt }

  enqueue(items)      // 覆盖式：新导入的勾选项整体替换 pending（不与旧失败项合并——见 §4.4）
  start()             // 幂等；逐条执行循环（见下）
  retry(token)        // failed → pending
  retryAllFailed()
  pause()             // interrupt 当前条目，循环停止（G8）
  subscribe(fn)       // 状态变更通知（队列页刷新；按函数对象去重，对齐 runner listeners 的坑）
  每次条目状态变更 → 写盘（KB 级文件，全量重写）
```

**执行循环（事件驱动）：**

```
start():
  if runner.isRunning() → 拒绝 + 调用方提示「当前有命令执行中」（既有 BUSY 文案链路）
  runner.subscribe(队列监听器)                 // 完成事件驱动
  取第一条 pending → 设 running（写盘）→ runner.start(该条的 install 命令)
onRunnerFinished(state):
  if state.args === 当前条目的期望 args:       // 防串：用户自发的单命令完成不驱动队列
    status = (exit 0 → done, 其余 → failed)；写盘
    if 还有 pending 且未 pause → 下一条 start
  else: 忽略（非队列命令）
崩溃恢复：冷启动读盘，running 条目一律重置为 pending（上次死在半途）
```

- **逐条独立命令**（`brew install <qualifiedName>`，cask 加 `--cask`），不用 `brew install a b c`：
  失败域隔离、输出可读、单条可中断可重试。命令拼装完全复用 `BrewCommandGenerator.installArgs`（页面上显示什么就执行什么）。
- 每条完成时 runner 自动 `BrewInstalledLoader.invalidate()` → 已装列表逐条刷新，队列页「已装」标注同步更新。
- 中断 = `runner.interrupt()`（SIGINT→SIGKILL 既有链路），条目记 failed（`exit<0`），循环停止，pending 保留（G8）。
- 队列执行期间用户在别处点单命令 → runner 返回 BUSY → 既有提示（语义对称：谁先占执行权谁先走）。

### 3.3 导入：选择器 → 解析（纯函数）→ diff → 勾选 → enqueue

```
「选择清单文件」→ picker.DocumentViewPicker.select()   // 不设后缀过滤（见下）
  → 读文件（> 1MB 拒读，G11；读为 UTF-8 字符串）
  → BrewfileParser.parse(text): BrewManifest        // 纯函数，可脚本回归（G14）
      逐行（容忍 BOM / CRLF / 空行 / 行首尾空白）：
        `# …`              → 注释；头部 `# key=value` 提取为 meta（exported_at 等）
        `tap "user/repo"`  → taps[]
        `brew "token"[, "ver"]` → items[formula]；版本 pin 读入但**不用于安装**
        `cask "token"`     → items[cask]
        `brew "u/r/token"` → 拆 tap + token（人手写全名的防御分支）
        其余               → ignored 计数
      items+taps 全空 → 抛「不是有效的清单文件」（F1）
  → diffAgainst(snapshot().sets.installed):
      优先 name+kind 精确命中 → 已装（禁勾，默认不勾）
      次选 name 跨 kind 命中   → 已装（禁勾，行上保留导入侧 kind 角标）
      未命中                  → 新装（默认全勾——换机场景一键复制）
  → 预览态（§4.3）→ 勾选 → 「安装所选(N)」→ 轻确认 dialog → enqueue + start
  → [BrewManifest] parse lines=L valid=V ignored=I
```

- 导入**不设后缀过滤**：Mac `brew bundle dump` 的无后缀 `Brewfile`、微信改名 `.txt`、手写 `.md` 都能选进来；
  合法性由内容判定（解析是纯函数，错了给 F1 Toast）。文件大小上限兜底恶意/误选大文件。
- 导入的 `tap` 行只作**源信息标注**（预览显示、安装时拼 qualifiedName），**不自动克隆 tap**：
  Tap 由应用自己克隆管理（custom-tap spec 的体系），与设备 brew 的 tap 是两回事；
  清单里的 tap 行缺失时该条安装自然失败进 failed（用户在设备侧补 tap 后重试，G7 兜底）。

### 3.4 缓存归属登记

| 文件 | 归属 | CacheAdmin 一键清理 | CacheEpoch 切源清理 |
| --- | --- | --- | --- |
| `filesDir/brew_state/install_queue.json` | 用户任务状态 | **否**（G13） | 否 |
| `filesDir/temp/manifest_<ts>.txt` | 导出中转，finally 即删 | —（常态不存在） | — |

---

## 4. 交互与视觉（UX 专项）

> 本节是用户点名「重点考虑 UX」的落点。UX 决策的总依据有三：
> ① CloudPurePlay《blocking-loading-ux-design》分档规范——**档位由「用户是否该去做别的事」决定，不是耗时**；
> ② CloudPurePlay 备份/恢复的成熟节奏——**导入前摘要 + 二次确认 + 错误分类 Toast**；
> ③ 既有执行 Sheet 的「可关可重开、离开页面执行不停」心智——队列是长任务，绝不用阻塞遮罩看住用户。

### 4.1 入口与页面信息架构

- **入口**：「我的 → 设置 → 工具清单同步」（MineSettingView 加一行，sentinel 行同模式：`if (isLocalPackagesEnabled())`，G10）。
  理由：同步是低频动作，「我的」首页已经拥挤（登录 + promo + 三张本机包卡 + 设置），不适合再添卡；设置页是导航型列表，加行成本最低；
  pc_normal 下导出无数据（快照为 null）、导入无执行通道，整页无意义 → 入口随能力隐藏。
- **同步页（BrewManifestSyncView，新路由）单页四区块，自上而下按「你有什么 → 你可以拿什么 → 进行中的事」排列**：

```
┌ 摘要卡「我的工具链」──────────────────────┐
│ 本机主动安装 12 项工具（11 命令行 + 1 应用） │
│ [ 导出清单 ]  ← 主按钮（T2：点击后 spinner） │
└────────────────────────────────────────┘
┌ 导入卡「从其他设备导入」────────────────────┐
│ 选择另一台设备导出的清单文件，勾选要安装的工具 │
│ [ 选择清单文件 ]                             │
└────────────────────────────────────────┘
┌ 清单预览卡（选择文件后展开，见 §4.3）─────────┐
┌ 队列状态卡（有队列数据时常驻）─────────────────┐
│ 上次队列：6/7 完成 · 1 失败    [查看队列 →]   │
└────────────────────────────────────────┘
```

  - 导出在上（现状与身份）、导入在下（动作与增量）——先「我有什么」再「对面的新东西」，与双机互见的心理模型一致。
  - 队列状态卡是队列页的**回访入口**：批量安装启动后用户大概率离开页面（允许！），回来时从同步页一眼看到队列进度，不依赖任何通知。

### 4.2 loading 分档（逐动作核定）

| 动作 | 档位 | 形态 |
| --- | --- | --- |
| 进同步页读快照 | T1 页内 | 摘要卡骨架；`loadSets()` 有新鲜快照即时返回 |
| 导出 | T2 就地 | 按钮禁用 + 行内 spinner；**无遮罩**（用户该去做别的） |
| 选文件→解析 | T0 | 本地纯函数毫秒级，不设 loading |
| enqueue + start | T2 | 按钮禁用一瞬，完成后跳队列页 |
| 批量安装执行 | T1 页内 | 队列页自表达进度（§4.4）；**绝不 T3 阻塞遮罩**——长任务必须允许用户离开 |

### 4.3 清单预览（导入的核心交互）

- **展开动效**：预览卡以 300ms 淡入 + 轻微上移出现（对齐 tldr spec G15 的 `TransitionEffect.OPACITY + translate({y:12})` 模式），
  消「选完文件内容瞬间砸出来」的突兀感。
- **来源摘要行**：「来自 Brewfile-20261123.txt · 导出于 11-23 20:30 · 12 项」——文件名 + 头部 meta，让人确认「这就是那台机的清单」。
- **新装亮点行（双机互见时刻，G5）**：彩色强调行「**另一台设备有 7 个你没有的工具**」。
  这是 brainstorm 场景②（台式机看到「笔记本今天新装了 gh、jq」）在文件流下的诚实表达——不做后台监听，但「差集」本身就是那条消息。
  样式对齐「新适配速递」同类「你有新东西」提示的心理模型（强调色 + 前置符号）。
- **条目列表**：每行 = 勾选框 + token（等宽字体）+ kind 角标（命令行/应用）+ tap 源（非默认时）+ 状态标注：
  - 已装 → 行置灰、勾选框禁用（已装就是已装，升级走既有更新流程，不在同步页掺合）
  - 新装 → 默认勾选（换机场景「一键复制」就是默认全选）
  - 新装且 tap 非空 → 追加小字「需先在设备安装 tap」——把 §3.3 的「不自动 tap」从隐含失败变成前置告知
- **底部操作栏**：复用 BrewActionBar 模式（barOverlap + mask、按钮 60% 宽上限 448vp、高 40vp、抬 16vp，常量已在 brewcommon），
  「安装所选（N）」强调蓝，N=0 时禁用。长列表滚动时操作栏常驻，勾选成本不随列表长度上升。
- **轻确认 dialog**（批量写操作的最后一道闸）：「开始安装 7 项？每项单独执行，可随时暂停。」→ 确认后建队列并跳队列页。
  勾选已是强意图，但批量安装不可撤销且耗时，这道确认成本极低。

### 4.4 队列页（BrewInstallQueueView，新路由）

宏观进度页，与执行 Sheet（微观输出）成对分工——**Sheet 看单条命令的流式输出，队列页看整个批的进度**：

- **进行中**：页顶进度摘要「3/12 已完成」+ 当前条目卡（token + 行内 spinner + [查看输出]（开 Sheet，G9）+ [暂停]（G8））；
  条目列表逐行状态染色（pending 灰点 / running 蓝 spinner / done 绿勾 / failed 红叉）。
- **全部完成**：成功摘要 + 结果行；有失败时追加「重试失败项（N）」操作（G7）。
- **空态**：「没有排队中的安装任务」。
- **失败条目**：显示退出码（`brewCommandStatusText` 同款文案）+ 单条 [重试]；**不保留历史条目的流式输出**
  （BrewCommandState 单例只存最后一条，v0 明确接受，逐条输出持久化列 §范围外）。
- 离开页面执行不停（队列与 runner 都在全局单例 + 落盘里）；回来从队列状态卡或重新进队列页续看（G6 的崩溃恢复覆盖 kill 场景）。

### 4.5 空态与错误态

| 态 | 表现 |
| --- | --- |
| 本机无主动安装包（导出侧空） | 摘要卡「本机还没有可同步的工具」，导出按钮禁用 |
| 快照未就绪（首次进页） | 摘要卡「正在读取本机清单…」，导出按钮禁用（T1） |
| 非清单文件（0 合法行） | Toast「不是有效的清单文件」（F1） |
| 文件超 1MB | Toast「文件过大」（F2） |
| 读文件失败/选择器取消 | 取消=静默回预览前态；读失败 Toast「无法读取文件」（F3） |

---

## 5. 失败态分级

| 级 | 场景 | 行为 |
|---|---|---|
| F1 | 导入文件无任何合法行 | Toast「不是有效的清单文件」；`[BrewManifest] parse reject reason=no-valid-lines` |
| F2 | 导入文件 > 1MB / 读取失败 | Toast「文件过大」/「无法读取文件」；不崩溃 |
| F3 | 导出时快照不可用（brew 未 ready） | 按钮 T1 禁用态持续；不产生半成品文件 |
| F4 | save picker 用户取消 | 静默；清理临时文件 |
| F5 | 单条安装失败 | 条目 failed + 退出码；队列继续下一条（失败域隔离）；`[BrewQueue] item token=… status=failed exit=N` |
| F6 | 队列启动时执行权被占 | 提示「当前有命令执行中」，队列保持 pending 等待用户再次启动 |
| F7 | 写盘失败（队列状态无法持久化） | 队列继续在内存执行 + `[BrewQueue] persist fail` 日志；崩溃恢复降级为丢队列（可接受：安装是幂等重试型操作） |

**原则**：导入/导出是短动作，错误即时可见（Toast）；队列是长任务，错误逐条沉淀在列表里（不弹窗轰炸）。

---

## 6. 安全与合规

- **导出内容只有包名与 tap 名**：不含版本、不含路径、不含任何设备/用户标识（头部 meta 只有导出时刻）。
  清单本身无隐私敏感信息——但「装了什么工具」是行为画像，v0 文件流下它只在用户自己选择的信道里流动，应用不发起任何网络传输（零云依赖的字面兑现）。
- **执行面收敛**：队列只产生 `brew install` 命令，token 过 `BrewCommandGenerator.isSafeName` 闸（导入解析出的 token 也全走该闸，
  垃圾 token 在解析层即拒）；不接受清单文件里的任何可执行内容（Brewfile 语义天然没有命令字段——选 Brewfile 而非自定 JSON 的安全红利之一）。
- **文件大小上限 1MB**：防误选/恶意大文件（正常清单 KB 级）。
- **无新权限**：picker（save/select）是系统 UI 无需权限声明；读写均在应用沙箱与选择器授权路径内。

---

## 7. 文案

| key | zh 值 |
|---|---|
| `mine_setting_manifest_sync` | 工具清单同步 |
| `manifest_sync_title` | 工具清单同步 |
| `manifest_export_section_title` | 我的工具链 |
| `manifest_export_summary` | 本机主动安装 %d 项工具（%d 命令行 + %d 应用） |
| `manifest_export_button` | 导出清单 |
| `manifest_export_done` | 已导出：%s |
| `manifest_export_empty` | 本机还没有可同步的工具 |
| `manifest_export_loading` | 正在读取本机清单… |
| `manifest_import_section_title` | 从其他设备导入 |
| `manifest_import_hint` | 选择另一台设备导出的清单文件，勾选要安装的工具 |
| `manifest_import_button` | 选择清单文件 |
| `manifest_import_source` | 来自 %s · 导出于 %s · %d 项 |
| `manifest_import_new_highlight` | 另一台设备有 %d 个你没有的工具 |
| `manifest_import_installed` | 已安装 |
| `manifest_import_kind_formula` | 命令行 |
| `manifest_import_kind_cask` | 应用 |
| `manifest_import_tap_hint` | 需先在设备安装 tap |
| `manifest_install_selected` | 安装所选（%d） |
| `manifest_install_confirm_title` | 开始安装 %d 项？ |
| `manifest_install_confirm_body` | 每项单独执行，可随时暂停。 |
| `manifest_parse_reject` | 不是有效的清单文件 |
| `manifest_file_too_large` | 文件过大 |
| `manifest_read_fail` | 无法读取文件 |
| `manifest_runner_busy` | 当前有命令执行中 |
| `queue_title` | 安装队列 |
| `queue_progress` | %d/%d 已完成 |
| `queue_current` | 正在安装：%s |
| `queue_view_output` | 查看输出 |
| `queue_pause` | 暂停 |
| `queue_retry_failed` | 重试失败项（%d） |
| `queue_retry` | 重试 |
| `queue_empty` | 没有排队中的安装任务 |
| `queue_state_pending` | 等待中 |
| `queue_state_failed` | 失败 |
| `brew_cmd_title_install` | 安装：%s |

（en 侧编码时同步补全，对齐既有文案管理方式。）

---

## 8. 改动清单

| 模块 | 改动 |
| --- | --- |
| `features/brewcommon` | 新增 `util/BrewfileParser.ets`（纯函数：parse）、`util/BrewfileBuilder.ets`（纯函数：build）、`service/BrewInstallQueue.ets`（落盘队列单例：enqueue/start/pause/retry/subscribe + 事件驱动执行循环）、`model/BrewManifestModels.ets`（manifest/条目/队列条目模型）、`constant/BrewManifestConstants.ets`（1MB 上限、状态枚举、`[BrewManifest]`/`[BrewQueue]` tag） |
| `features/mine` | 新增 `view/BrewManifestSyncView.ets`（同步页）、`view/BrewInstallQueueView.ets`（队列页）+ 配套 viewmodel/state（对齐 mine 模块既有 VM 模式，编码时对齐 MinePackagesVM 构造方式）；`MineSettingView.ets` 加「工具清单同步」行（isLocalPackagesEnabled 闸，sentinel 行同位插入）；`router_map.json` 登记两页；文案 zh/en |
| `common` | `PageEnum.ets` 加 `BREW_MANIFEST_SYNC_VIEW` / `BREW_INSTALL_QUEUE_VIEW` 枚举 |
| `hmosword-build` | 新增 `brew-manifest/check_manifest_parser.mjs`（G14：构造用例回归，对齐 brew-tldr 检查脚本做法，接入既有自检入口） |

**明确不动**：BrewCommandRunner（只消费不修改）、BrewCommandSheet/PcMainPage（零改动复用）、BrewInstalledLoader（只读快照）、
BrewCommandGenerator（只调用）、MineView 首页（不加区块）。

---

## 9. 验证

1. G1–G14 逐条真机验证（HUAWEI MateBook Pro，pc_acl），日志 tag `[BrewManifest]` / `[BrewQueue]`；
2. **换机全链路**（核心判据）：设备 A 导出 → 文件经任意渠道 → 设备 B（或清数据后的同机）导入 → 勾选 → 队列执行 →
   已装列表出现新包、同步页 diff 归零（重导同文件 →「另一台设备有 0 个你没有的工具」）；
3. **brew 生态兼容**（G3 沙盒比对）：导出文件与 `brew bundle dump` 的行格式逐行比对（tap/brew/cask 语义一致、注释行被忽略）；
   Mac dump 产物导入本应用解析通过；
4. 崩杀恢复（G6）：队列执行第 3 条时 kill 应用 → 重启 → 队列页第 3 条回 pending、1–2 条 done 保留 → 继续；
5. 缓存归属（G13）：CacheAdmin 一键清理 → `brew_state/install_queue.json` 仍在；
6. 解析器脚本接入自检入口，与 `brew-tldr` / `brew-search` 并列；
7. 双 product 构建 + pc_normal 行为差异（G10）。

---

## 10. 风险与未决

| 风险 | 处置 |
| --- | --- |
| **保存选择器零先例**（本工程首次用 `DocumentViewPicker.save()`；PC 2in1 形态下的选择器行为未观测） | 编码第一天冒烟：save → 返回 uri → fs 写入 → 读回比对，四步一次走通；不通则降级方案 = 写 `filesDir` 内固定路径 + 提示用户路径（不理想但保交付），结果写回本节 |
| save 返回 uri 的写入方式（fs.openSync vs fileIo.copy）与 `DocumentSaveOptions` 参数确切拼写（`newFileNames`/后缀选择） | 同上冒烟核对；CloudPurePlay `BackupRestoreSettings.ets` 的 picker→temp→save→copy 模式为参考实现 |
| 队列事件驱动的防串（runner 完成事件里区分「队列命令」与「用户自发命令」） | args 逐字比对（BrewCommandState.args 与条目期望 args）；实现时若发现更稳的标识方式（如 state 挂来源标记）再收紧，但**不修改 runner 的对外契约** |
| 微信等渠道对 .txt 的编码/换行改造 | 导出 UTF-8；解析容忍 BOM/CRLF/空行（G14 用例覆盖）；渠道改坏内容 → F1 兜底 |
| 大清单（数百行）渲染 | List 懒加载天然支持；不设上限行数（1MB 上限即物理上限） |
| 队列执行中切源/清缓存 | 队列命令按 qualifiedName 已定格，切源不影响在途命令；新 enqueue 的条目按当刻源拼装 |
| B′ 工作台后续接入（粘贴/拖拽/三色画布） | 本 spec 的解析器与队列即为其地基；B′ spec 落地时只加输入路径与标注层，不重复建设管线 |

**实现第一天核对清单**（对齐 tldr spec「实测先行」传统）：
① save picker 四步冒烟；② `DocumentSelectOptions` 不设后缀过滤时的行为（能否选无后缀文件）；
③ `BrewCommandState` 完成事件的订阅时机（队列冷启动时 runner 尚空，订阅必须在首条 start 之前）。

---

## 范围外（明确不做）

- **v1 端云同步**：rejected.md 已否决（默认关、显式开启、需隐私评估）——本 spec 不留后门字段。
- **B′ 工作台的粘贴/拖拽输入路径与三色画布**（可装/缺依赖/弃用的完整适配标注）：留给 B′ 工作台 spec，
  落地时直接复用本 spec 的解析器与队列；本 spec 的导入标注只有「已装/新装」二态 + tap 前置提示。
- **导入时的源内存在性预判**（清单项在当前源有没有）：不查搜索引擎索引——「新装可勾」已满足换机场景，
  源内没有的包在执行时自然进 failed（退出码 + 重试）。预判层归 B′ 三色画布。
- **系统分布式能力**（流转/接续/分布式数据对象）：rejected.md §1 第 14 条否决，brew 场景全是单机本地事实。
- **队列历史条目的流式输出持久化**：v0 只保留最后一条命令的输出（BrewCommandState 单例语义）。
- **v1 通知态**（「你的笔记本今天新装了…」卡片）：文件流下无对端事实来源；`SENTINEL_PENDING_ROUTE` 的
  want 直达模式（MineHomeView 已有）是未来接入点，本 spec 不动。
- **已装项的重装/跨 kind 勾选**：已装即禁勾。
- **清单预览的全选/反选 chip**：默认全勾已覆盖换机主场景，多选三态 chip 的复杂度不值 v0。
- **侧边栏/桌面卡片等其他队列入口**：队列回访只走同步页的队列状态卡。
