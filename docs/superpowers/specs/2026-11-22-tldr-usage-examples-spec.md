# tldr 用法示例（详情页「怎么用」区块）· 设计

> 日期：2026-11-22。状态：待评审。评审通过后按「构建顺序」第 1 位实施。
> 范围：`features/brewcommon` 新增 tldr 数据服务与解析器；`features/brewdetail` 详情页新增「用法示例」分区；
> `hmosword-build` 新增解析器检查脚本；署名合规（OAT.xml / 关于页）。
> 叙事定位：motivation「主线一 · 选型信任」与「主线二 · AI Companion」的交点——「示例即抄即用」；
> 裁决与排序见 [`decisions.md`](../2026-11-21-brainstorm/decisions.md) 第 15 号（重要性第 3 位）。
> 相关文档：[`2026-10-04-brew-command-execution-spec.md`](2026-10-04-brew-command-execution-spec.md)（执行 Sheet 与一键执行链路）、
> [`../../knowledge/2026-11-21-brew-cache-ownership.md`](../../knowledge/2026-11-21-brew-cache-ownership.md)（缓存归属）、
> [`../../brew-api-design.md`](../../brew-api-design.md)。

---

## 1. 目标与成功判据

把 tldr-pages 的「人写、审校、可直接抄」用法示例接进包详情页：中文优先、离线可复用、每条示例可复制、无占位符的示例可直接送进执行 Sheet。数据源为 tldr-pages 仓库（CC BY 4.0，署名即可分发）。

| # | 判据 | 可观测证据 |
| --- | --- | --- |
| G1 | formula 详情页（如 wget / curl / jq / ffmpeg / gh / htop 等高频 token）出现「用法示例」分区，中文页优先、无中文页回落英文 | 真机；`[tldr] get token=… locale=zh ok=true channel=jsdelivr` |
| G2 | cask 详情页不出现该分区（tldr 只覆盖命令行工具） | 真机 |
| G3 | 每条示例带「复制」按钮；复制内容与渲染的命令文本逐字一致 | 真机；剪贴板比对 |
| G4 | 不含 `{{占位符}}` 的示例出现「执行」按钮，点击进入既有执行 Sheet 并显示退出码；含占位符的示例**没有**「执行」按钮（仅复制） | 真机；`[brew-cmd] start args=…` |
| G5 | 断网后，已缓存过的 token 仍显示完整示例（含署名行） | 真机（飞行开关） |
| G6 | 首次离线打开未缓存过的 token → 分区不出现，**无任何错误提示**（无数据不是错误态） | 真机 |
| G7 | jsDelivr 不可达时自动回落 GitHub raw，两渠道顺序可配置 | `[tldr] channel fallback jsdelivr→github` |
| G8 | 缓存 TTL 过期后先展示旧内容、后台刷新，新内容到达后无感替换（stale-while-revalidate） | `[tldr] refresh stale token=…` |
| G9 | 404（无此页）做 24h 负缓存，期间不再重复请求 | `[tldr] neg-cache hit token=…` |
| G10 | pc_normal：示例与复制可用，「执行」按钮不出现（随 `BREW_CLI_ENABLED` 隐藏） | 真机（pc_normal） |
| G11 | 分区底部固定署名行「示例来自 tldr-pages（CC BY 4.0）」，点击跳转 tldr-pages 仓库；OAT.xml 与关于页已登记 | 真机；OAT.xml diff |
| G12 | 解析器检查脚本 `hmosword-build/brew-tldr/check_tldr_parser.mjs` 全绿：对 tldr 仓库抽样 30 页 + 构造用例（占位符 / 多行说明 / 无示例页 / 中文页 / 候选链与命中即停）解析通过 | `node hmosword-build/brew-tldr/check_tldr_parser.mjs` |
| G13 | 双 product 构建通过：`devecocli build --product default` 与 `--product pc_normal` | `BUILD SUCCESSFUL`，`ERROR` 计数 0 |
| G15 | 异步到达的「用法示例」分区以转场出现（300ms 淡入 + 轻微上移），缓存命中与临时拉取两条路径观感一致、无闪烁 | 真机目测 |

---

## 2. 现状

| 位置 | 现状 |
| --- | --- |
| `features/brewdetail/src/main/ets/component/BrewInfoSectionView.ets` | 详情页分区是数据驱动的（吃 `BrewInfoSection`），新增分区应遵循同一模式；caveats 分区已存在（§5.3 分区体系） |
| `features/brewcommon/src/main/ets/service/BrewHttp.ets` | 既有 HTTP 层：超时、失败分类可复用；无 markdown 拉取的先例（实现时按现有错误分类接入） |
| `features/brewcommon/src/main/ets/service/BrewSourceStore.ets` / `BrewCacheAdmin.ets` / `BrewCacheEpoch.ets` | 缓存目录归属与统一清理已收敛（见 `docs/knowledge/2026-11-21-brew-cache-ownership.md`）；tldr 缓存需在此登记 |
| `features/brewcommon/src/main/ets/constant/BrewConstants.ets` | `brew_live_data` 既有 TTL 活数据常量——tldr 缓存目录/前缀与其对齐（编码时核对） |
| `features/brewcommon/src/main/ets/service/BrewCli.ets` / `BrewCommandRunner.ets` | 执行 Sheet 的命令入口（流式输出 / 中断 / 退出码）已建成，一键执行复用该链路 |
| `features/brewcommon/src/main/ets/model/BrewSearchEngine.ets` | 纯函数搜索索引（16k token + desc），本 spec 不改动它 |
| 双版本 | pc_normal 无执行通道（`BREW_CLI_ENABLED=false`）：复制可用、执行隐藏 |

---

## 3. 数据流与缓存

### 3.1 取数流水线

```
详情页(token, kind=formula, executables「提供的命令」)
  → TldrService.get(token, executables)
      0) 候选名链（命名错位修复）：
         查询候选 = [token, 剥 @version 后缀, …executables]（去重保序、全小写）
         实例：ripgrep→[ripgrep, rg]；python@3.12→[python@3.12, python]；gnupg→[gnupg, gpg]
      1) 链级内存缓存：按候选序扫内存命中 → 返回
      2) 按序逐候选走既有取数链（内存→落盘→网络，**命中即停**）：
         a. 落盘命中且未过期（TTL 14 天）→ 返回；已过期 → 先返回旧值 + 后台刷新（stale-while-revalidate）
         b. 网络抓取（双渠道顺序，可配置）：
            jsDelivr:  https://cdn.jsdelivr.net/gh/tldr-pages/tldr@main/<pages.zh|pages>/<平台>/<候选>.md
            GitHub raw: https://raw.githubusercontent.com/tldr-pages/tldr/main/<pages.zh|pages>/<平台>/<候选>.md
            中文 404 / 失败 → 英文回落：pages/common → pages/linux → pages/osx
         c. 单候选全渠道 404 → **该候选**负缓存 24h（候选粒度），继续下一候选
         d. 链上出现网络失败（非 404）→ 立即终止整链（F1），不写任何负缓存
         e. 全部候选 ALL_NOT_FOUND → 整链隐藏（chain-miss）
      3) 解析（TldrParser，纯函数）→ TldrPage{locale, command, examples: [{desc, code, hasPlaceholder}]}
         标题校验 = **任一候选**匹配（F6 放宽到链、防抓错页不松）→ 落盘（按命中页名）+ 返回
      4) 在途合并键 = 包名 token（链身份）：同一详情页的并发 get 共享同一个 Promise
```

- **路径结构实测先行**：tldr 仓库语言目录的确切命名（`pages.zh/` 下的平台子目录）与分支名（main）在编码第一天用 3 个探针请求核对（wget / curl / ffmpeg），核对结果写回本节。

- **探针记录（2026-11-22 实测，已据此校准实现）**：
  - **渠道 A（jsDelivr）可用**：`https://cdn.jsdelivr.net/gh/tldr-pages/tldr@main/pages.zh/common/wget.md` → `HTTP 200`（1380B）；`ffmpeg.md`（1762B）、`curl.md`、`yt-dlp.md`（1871B）均 200——`pages.zh/common/<token>.md` 的路径结构与 `@main` 分支名**实测成立**（`@master` 同样被 jsDelivr 解析为 200，不能据此判定默认分支；GitHub API 因限流 403，未能从仓库侧直接确认，以 `@main` 全部命中为准）。
  - **中文平台子目录不止 common**：`pages.zh/linux/apt.md`、`pages.zh/osx/open.md` 均 200。v1 取数链仍按 §3.1 的「zh/common → en/common → en/linux → en/osx」执行（zh 的 linux/osx 命中留给 v2 扩链，不在本次范围）。
  - **渠道 B（GitHub raw）本网络不可达**：`raw.githubusercontent.com` 连发 3 次均 `Connection reset by peer`（HTTP 000）；`api.github.com` 可达但匿名限流 403。**渠道 B 的成功路径与 404 行为本轮未观测**，回落代码按 spec 照常保留——它是否生效随部署网络而定，不能引用本轮结果断言其可用或不可用。
  - **404 行为（jsDelivr 实测）**：`HTTP 404` + `text/plain` 93 字节正文 `Couldn't find the requested file /pages.zh/common/<token>.md in tldr-pages/tldr.`，响应头 `Cache-Control: no-cache, no-store, must-revalidate`——**CDN 不做负缓存，24h 负缓存必须由本地自己实现**（G9 依据）。正文不含 `#` 标题，解析器标题校验（F6）构成第二道防线。
  - **页面格式与 §3.2 原假设有一处差异**：示例命令**不是 ``` 围栏代码块**，而是**独占一行的单反引号内联代码**（`` `命令` ``，上下各一空行）；`{{占位符}}` 原样保留在命令文本内，包裹占位符的引号（如 `yt-dlp "{{...}}"`）在花括号**外**、属命令原文的一部分；说明行以 `- ` 开头（可跨行）；`> ` 引用组为页首说明，其中「另请参阅 / See also」「更多信息 / More information」行按 §3.2「其他内容丢弃」。解析器按实测格式实现，并把围栏代码块作为防御性兼容分支（§3.2 已同步修正）。
  - **token↔页面名不对齐实例（佐证 v1 不做别名表）**：`ripgrep` 无中文页（404），英文 `pages/common/ripgrep.md` 亦 404——tldr 页名是 `rg`。该 token 走负缓存、分区隐藏，正是 §3.1「未命中即隐藏」的预期行为。
- **token ↔ 页面名映射（候选链，2026-11-22 实测数据后升级）**：初版 v1 精确匹配 `<token>`，20 个常见包精确命中仅 60%（ripgrep→rg、gnupg→gpg、imagemagick→magick、neovim→nvim 四例错位，`@version` 后缀全 miss）。**已按候选名链修复（规则一 + 二先行）**：查询候选 = [token, 剥 @version 后缀, …executables]，命中即停；单候选 404 负缓存保持候选粒度、不毒化整链。**规则三（策展别名表）缓**——等真机命中率数据再决定是否立项（走 `generate.py` 校验体系）。
- **目录约定**：`filesDir/brew_live/tldr/<locale>/<命中页名>.md` + `<命中页名>.meta.json`（fetchedAt / channel / locale）；负缓存标记在根目录 `<候选名>.neg.json`（候选粒度，spec 未约定其位置，属实现细节）；归属登记进 `BrewCacheAdmin`（统一清理），**不随 CacheEpoch（浏览源切换）清理**——tldr 与浏览源无关。

### 3.2 解析规则（TldrParser，纯函数）

| tldr 元素 | 处理 |
|---|---|
| `# <command>` 标题行 | 校验与 token 匹配（不匹配整页丢弃，防御抓错页） |
| `>` 引用行 | 连续引用合并为「说明段」 |
| `- <说明>：` + 紧随的代码行 | 一个示例项 `{desc, code}`。**实测（§3.1 探针）命令是独占一行的单反引号内联代码**（`` `命令` ``），解析器以它为主格式、``` 围栏代码块为防御性兼容；`code` 内 `{{...}}` 占位符原样保留并高亮样式，`hasPlaceholder = /{{.+?}}/.test(code)` |
| 其他内容（More information 链接行等） | 丢弃 |

解析器为纯函数（输入 markdown 字符串 → 输出 TldrPage | null），**可执行检查脚本** `hmosword-build/brew-tldr/check_tldr_parser.mjs` 承担回归（对齐 `brew-search` 检查脚本的做法）。

---

## 4. 交互与视觉

### 4.1 「用法示例」分区

- **位置**：详情页「提供的命令」（`brew_label_executables`）分区**正下方**（真机评审后的调整：与「它提供哪些命令」相邻，正好承接「这些命令怎么用」；该分区 formula 独有，cask 不出现，G2 在数据层即成立；沿用 round2 口径的后续调整）。
- **结构**：分区标题「用法示例」→ **命名提示行**（命中页名 ≠ 包名时：「<token> 提供的命令是 <page>」，如「ripgrep 提供的命令是 rg」——教学时刻，候选链命中后把对应关系点破）→ 说明段（可选）→ 示例卡片列表 → 署名行。
- **示例卡片**：说明行（普通字重）+ 命令块（等宽字体、占位符高亮）+ 行尾两个操作：「复制」（always）；「执行」（仅 `!hasPlaceholder && BREW_CLI_ENABLED`）。
- **「执行」**：将 `code` 原文作为命令送入既有执行 Sheet（流式输出 / 中断 / 退出码，全部复用 `2026-10-04-brew-command-execution-spec.md` 语义），**不做任何 AI 改写或参数猜测**。
- **署名行**：固定文案「示例来自 tldr-pages（CC BY 4.0）」，点击跳 `https://github.com/tldr-pages/tldr`。
- **空态**：无页面 / 解析失败 → 整个分区不渲染（G2/G6），不占位、不转圈。

### 4.2 加载时序

分区随详情页其它分区一起渲染；tldr 数据异步到达后**就地插入**（不引起整页重排跳动：预留分区最小高度或按既有 live-data 分区的处理惯例，编码时对齐）。

**插入转场（G15）**：数据落 state 时包在 `UIContext.animateTo({ duration: 300, curve: Curve.Friction })` 里（UIContext 取不到时直接赋值不动画，防御不崩）；视图侧 `BrewTldrSectionView` 挂 `TransitionEffect.OPACITY.animation({ duration: 300, curve: Curve.Friction }).combine(TransitionEffect.translate({ y: 12 }))` —— 300ms 淡入 + 12vp 上移，消掉「临时拉取后分区瞬间闪现」的突兀感；移除侧走对称默认。**缓存命中路径同样走此动画**（视觉一致性优先：用户不应能从呈现上区分「缓存命中」与「临时拉取」）。

---

## 5. 失败态分级

| 级 | 场景 | 行为 |
|---|---|---|
| F1 | 无缓存 + 全渠道网络失败 | 分区隐藏；`[tldr] fetch fail` 计数，UI 零提示 |
| F2 | 有缓存 + 刷新失败 | 继续显示旧值，UI 无感知；连续失败 3 次后本次会话停止刷新 |
| F3 | 解析异常（非预期结构） | 分区隐藏 + `[tldr] parse fail` 报告原文前 200 字节 |
| F4 | 404 无页面 | 负缓存 24h + 隐藏（G9） |
| F5 | 一键执行失败 | 走执行 Sheet 既有失败态（退出码 / 中断语义），本 spec 不新增 |
| F6 | 标题与 token 不匹配（抓错页） | 整页丢弃、按 F3 记日志 |

**原则**：tldr 是增强层。它的缺席不得产生任何错误可见性——详情页的其余分区在任何失败态下照常。

---

## 6. 安全与合规

- **许可**：tldr 内容 CC BY 4.0——署名行常驻；OAT.xml 登记 tldr-pages 来源与许可；关于页补一行。
- **执行面收敛**：可执行的命令只有两类——tldr 示例原文（无占位符）与目录内既有命令卡；AI 生成内容不在本 spec 范围（见 AI Companion spec 的「AI 生成的命令永不一键执行」）。
- **无用户数据外泄**：请求 URL 只含 token；不携带任何设备或用户信息。

---

## 7. 文案

| key | zh 值 |
|---|---|
| `brew_tldr_section_title` | 用法示例 |
| `brew_tldr_copy` | 复制 |
| `brew_tldr_copied` | 已复制 |
| `brew_tldr_run` | 执行 |
| `brew_tldr_attribution` | 示例来自 tldr-pages（CC BY 4.0） |
| `brew_tldr_command_hint` | %s 提供的命令是 %s |
| `brew_cmd_title_tldr` | 执行示例：%s |

---

## 8. 改动清单

| 模块 | 改动 |
|---|---|
| `features/brewcommon` | 新增 `service/TldrService.ets`（取数/缓存/负缓存/stale-while-revalidate）、`util/TldrParser.ets`（纯函数）、`model/TldrPage.ets`、`constant/TldrConstants.ets` |
| `features/brewdetail` | 新增 `component/BrewTldrSectionView.ets`；详情页装配与 viewdata 增量字段 |
| `hmosword-build` | 新增 `brew-tldr/check_tldr_parser.mjs`（抽样 + 构造用例） |
| `AppScope` / 关于页 | OAT.xml 登记；关于页署名行 |
| `resources` | §7 文案（zh/en） |

---

## 9. 验证

1. G1–G13 逐条真机验证（HUAWEI MateBook Pro），日志 tag `[tldr]`；
2. 高频 token 抽检清单 20 个（wget curl jq ffmpeg gh htop tree yt-dlp fd ripgrep node …）记录候选链后的 zh 命中率，作为规则三（策展别名表）的立项依据；
3. 解析器检查脚本接入既有自检入口（与 `brew-search` / `brew-mockgen` 并列）；
4. 缓存归属验证：CacheAdmin 一键清理后 tldr 缓存同步清空、CacheEpoch 切源后 tldr 缓存**不**被清空；
5. 双 product 构建与 pc_normal 行为差异（G10）。

---

## 10. 风险与未决

| 风险 | 处置 |
|---|---|
| tldr 仓库目录结构 / 分支名与假设不符 | 编码第一天 3 探针核对，写回 §3.1 |
| 镜像可达性波动（jsDelivr 在部分网络下的稳定性） | 双渠道 + 负缓存 + 静默隐藏；不阻塞详情页 |
| token ↔ 页面名不对齐导致命中率不足 | **已修（候选名链，规则一 + 二）**：20 包抽检精确命中 60% → 候选链覆盖 @version 与 executables 错位；规则三（策展别名表）待真机命中率数据再立项（走 generate.py 校验） |
| 占位符示例被用户整段复制后执行失败 | 复制内容即渲染原文；占位符高亮已提示需替换，不做自动填值（v1） |
| tldr 上游内容变更 | TTL 14 天 + stale-while-revalidate；无版本锁定需求 |
