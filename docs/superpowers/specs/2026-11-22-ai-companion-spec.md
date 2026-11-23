# AI Companion（问包 / 问需求 / 问报错 + BYOK 底座）· 设计

> 日期：2026-11-22。状态：待评审。评审通过后按「构建顺序」第 3 位实施（底座先行）。
> 范围：`features/brewcommon` 新增 AI 客户端 / 设置存储 / 任务词表；`features/brewdetail` 新增 AI 讲解卡；
> `features/brewsearch` 新增「AI 帮我找工具」；`features/mine` 新增 AI 设置页；执行 Sheet 失败态新增 AI 解读入口。
> 叙事定位：motivation「主线二 · AI Companion —— 终端旁随叫随到的老手」；裁决与排序见
> [`decisions.md`](../2026-11-21-brainstorm/decisions.md) 第 7 / 8 / 9 / 28 号（重要性第 1 / 2 / 4 位）。
> 相关文档：[`2026-11-22-tldr-usage-examples-spec.md`](2026-11-22-tldr-usage-examples-spec.md)（示例即抄即用，D1 的降级层）、
> [`2026-10-04-brew-command-execution-spec.md`](2026-10-04-brew-command-execution-spec.md)（D3 的输入来源）、
> [`../../knowledge/2026-11-21-brew-cache-ownership.md`](../../knowledge/2026-11-21-brew-cache-ownership.md)。

---

## 1. 目标与成功判据

把「问老手」装进应用：问包（D1）、问需求（D2）、问报错（D3）三种提问方式共享同一套 BYOK 底座（Key 设置 / 客户端 / 缓存 / 失败分类）。**AI 是增强层不是依赖层**：没配 Key、断网时，主链路（浏览 / 搜索 / 示例）完整可用。

| # | 判据 | 可观测证据 |
| --- | --- | --- |
| G1 | 「我的」页出现「AI 设置」：预置 DeepSeek（OpenAI 兼容）+ 自定义 OpenAI 兼容端点（baseURL / Key / model）；Key 经 Asset Store Kit 存储后，偏好文件与 hilog 中均无明文 Key | 真机；`grep -r sk- <prefsDir>` 无命中 |
| G2 | 「测试连接」按钮：成功显示 model 与时延；失败按 §8 失败分级给出明确原因 | `[ai] probe ok=… latency=…` |
| G3 | 详情页出现「AI 讲解」按钮（显式触发），点击后渲染结构化讲解卡：定位一句话 / 适用场景 ≤3 / 注意与坑（caveats 中文化）/ 上手三步；**二次进入同一包秒开**（缓存命中） | `[ai] d1 cache hit token=… age=…` |
| G4 | 讲解卡内容严格 grounding：构造「包元数据中不存在的信息」提问场景，AI 回答不出现编造的版本号 / 命令 / 功能（抽查 10 包人工评审） | 真机 + 评审记录 |
| G5 | 搜索页「AI 帮我找工具」：输入「我想批量压缩图片」→ 返回**目录内**候选（imagemagick / ffmpeg 等）并按本地引擎排序；构造含幻觉包名的 mock 响应 → 目录外名字**零展示**，丢弃数进日志 | `[ai] d2 filtered dropped=… kept=…` |
| G6 | 断网且未配 Key 时，AI 找工具自动切换**中文任务词表**模式（28）且结果可用；页面顶部提示「AI 未配置，已切换离线词表」 | 真机；`[ai] d2 fallback wordlist` |
| G7 | 执行 Sheet 失败终态（非零退出 / 解析失败）出现「AI 解读失败原因」（已配 Key 时），点击后渲染三段卡：发生了什么 / 可能原因 ≤3 / 下一步 ≤3；下一步建议**只有复制、没有执行按钮** | 真机；`[ai] d3 ok` |
| G8 | 断网时 D3 按钮不出现；D1 显示可重试的失败态；搜索与示例分区照常 | 真机 |
| G9 | promptVersion 变更后旧缓存自动失效（同一包重新生成） | `[ai] cache miss reason=promptVersion` |
| G10 | 缓存 TTL 过期 → stale-while-revalidate（先旧值后刷新） | `[ai] stale-while-revalidate feature=d1` |
| G11 | AI 响应 JSON 解析失败 → 明确错误态（E4）+ 重试入口，不渲染半成品卡片 | 真机；`[ai] e4` |
| G12 | pc_normal：D1 / D2 / I 可用（纯网络功能）；D3 与系统级入口不出现（随 `BREW_CLI_ENABLED`） | 真机（pc_normal） |
| G13 | AI 生成的全部文本**不含任何一键执行入口**（含建议命令）；可执行入口仅存在于 tldr 示例与既有命令卡 | 代码评审 + 真机断言 |
| G14 | 双 product 构建通过：`devecocli build --product default` 与 `--product pc_normal` | `BUILD SUCCESSFUL`，`ERROR` 计数 0 |

---

## 2. 现状

| 位置 | 现状 |
| --- | --- |
| `features/brewcommon/src/main/ets/service/BrewHttp.ets` | 既有 HTTP 层（超时 / 失败分类）；无 OpenAI 兼容调用先例，AiClient 在其上封装或并列实现（编码时定） |
| `features/brewcommon/src/main/ets/model/BrewSearchEngine.ets` | 纯函数搜索索引（16k token + desc）——D2 的排序兜底 |
| `features/brewcommon/src/main/ets/constant/BrewTaxonomy.ets` | 词表基建（lexicon 同构）——28 任务词表的对齐样板 |
| `features/brewcommon/src/main/ets/constant/BrewConstants.ets` | `brew_live_data` TTL 活数据约定——AI 缓存目录与 TTL 对齐此模式 |
| `features/brewcommon/src/main/ets/service/BrewCacheAdmin.ets` / `BrewCacheEpoch.ets` | 缓存统一清理与源纪元；AI 缓存需登记（epoch 无关，同 tldr） |
| `features/brewcommon/src/main/ets/service/BrewCli.ets` / `BrewCommandRunner.ets` | 执行 Sheet 链路：D3 的失败输入（命令 / stderr / 六分类）来自这里 |
| `features/brewsearch/src/main/ets/view/BrewSearchHomeView.ets` | 搜索首页：AI 找工具入口的挂载点 |
| `features/brewdetail/src/main/ets/component/BrewInfoSectionView.ets` | 数据驱动分区：AI 讲解卡与 tldr 分区的装配点 |
| `features/mine/src/main/ets/view/…` | 「我的」页：AI 设置入口挂载点 |
| 双版本 | pc_normal 无执行通道：D3 / 系统级入口随 `BREW_CLI_ENABLED` 隐藏；D1 / D2 / I 照常（纯网络功能） |

---

## 3. 共享底座（先建，三件复用）

### 3.1 BYOK 设置（`features/mine` AI 设置页）

- **提供商模型**：OpenAI 兼容协议抽象（`baseURL + apiKey + model`）。预置 DeepSeek 模板；支持自定义端点（覆盖任意 OpenAI 兼容服务）。v1 不做多 provider 并存，单配置。
- **Key 存储**：Asset Store Kit（关键资产存储，编码时核对 API 与可用性）；baseURL / model / provider 存普通偏好。**Key 任何情况下不进偏好文件与日志**。
- **测试连接**：发送最小 completion（max_tokens=8），成功显示 model 与时延，失败按 §8 分级显示。
- **入口显隐**：AI 设置入口常驻「我的」（未配置时引导，已配置时显示当前 model 与修改入口）。

### 3.2 AiClient（`features/brewcommon/service/AiClient.ets`）

- **AI infra 依赖（需求方指定；2026-11-22 起改为 vendor 源码引入）**：模型调用基础设施使用
  `@hmkit/ai`（upstream `https://github.com/lxshwyan/hmkit-ai`，MIT）。原以 ohpm 包依赖引入；
  真机接自建 OpenAI 兼容端点（one-api 类网关）时暴露其流式解析缺陷（见下），需求方指示改为
  **vendor 源码引入**：`features/hmkit-ai/`（module 名 `ai`，HAR），主工程以
  `file:./features/hmkit-ai` 路径依赖，来源与全部本地改动登记在 `features/hmkit-ai/NOTICE.md`。
  AiClient 封装该库，不手写 HTTP 调用 OpenAI 兼容端点。BYOK 的 baseURL / Key / model 仍按
  §3.1 设置与存储。
- **vendor 缺陷修复（2026-11-22，真机日志定位）**：upstream 2.0.0 的
  `OpenAIStreamDecoder.consumeEvent` 只拦 `chunk.usage !== undefined`，拦不住 JSON null——
  OpenAI 流式协议允许 chunk 不带 usage（`stream_options.include_usage` 只保证最后一个 chunk
  带），one-api 类网关转发时全链路 `"usage": null`，`consumeUsage(null)` 读
  `null.prompt_tokens` 崩出 PROTOCOL → 上层误报 E4「响应格式异常」。vendor 源码修复：
  `chunk.model / chunk.usage / chunk.choices` 判空补 `!== null`，`consumeUsage` 入口
  `undefined || null` 兜底，`choices` / `tool_calls` 元素判空跳过；`ResponsesDecoder` 同款
  陷阱预防（`event.item / event.response / response.usage` 补 null）。曾实现过「兼容模式
  （非流式 POST）」绕行层，根因修复后按决策整体移除（设置页 Toggle、`AiProviderConfig`
  开关、偏好键、`AiClient` 非流式路径），不留死代码。
- **兼容性修复（2026-11-22，自建 chat completions 端点实测）**：① `AiTasks.parseJsonSafe` 解析前先剥离 markdown 代码栅栏（```json … ```）与首尾非 JSON 字符（取首个 `{` 到最后一个 `}`），自建网关 / 忽略 response_format 的端点常输出包裹文本；② `finish_reason === 'length'`（max_tokens 截断导致 JSON 不完整）显式归 E4，错误文案「输出被截断，请重试」——此前 finishReason 被忽略、截断输出只会以「schema mismatch」面目出现；③ D1 `steps` 放宽为 2–3 条（`isValid` 同步放宽），部分模型习惯输出两条步骤。
- 非流式 chat completion；超时 15s；**不自动重试**（全部显式触发场景，用户自己重试）。
- 输入截断：prompt 总长上限 8KB（超出按 §4/§6 各自的截断规则）。
- 输出约定：**所有任务要求 JSON 输出**（`response_format` 若端点支持则使用；否则靠 prompt + 解析校验），低温度（D1 0.3 / D2 0.2 / D3 0.2）。
- 解析：JSON Schema 校验 → 不符即 E4（响应格式不符）。

### 3.3 缓存与降级

- **目录**：`filesDir/brew_live/ai/<feature>/<providerModelKey>/<cacheKey>.json`；cacheKey = token（D1）/ 意图 slug（D2）。meta 记 `promptVersion`、`fetchedAt`、`model`。
- **promptVersion**：代码内常量；变更即缓存失效（G9）。
- **TTL**：D1 7 天 / D2 1 天 / D3 不缓存。过期走 stale-while-revalidate（G10）。
- **登记**：进 `BrewCacheAdmin` 统一清理；与 CacheEpoch 无关。
- **降级总则**：无 Key / 断网 → D1 入口变引导、D2 切词表（28）、D3 按钮隐藏；主链路（浏览 / 搜索 / 示例）零影响。

---

## 4. D1 · AI 讲解卡（详情页）

- **入口**：详情页「AI 讲解」按钮（**元信息条之后、各分区（首个为「提供的命令」）之前**——
  2026-11-23 定稿口径：页面顺序 Hero → 生命周期 → 安装命令卡 → 元信息条 → AI 讲解卡 →
  sections → caveats → 同分类；命令卡是刚性的、讲解是增强的。触发分显式与自动生成，见下）。
- **输入（grounding 严格限定）**：`token`、`desc`、`caveats`、`dependencies`（全部来自既有详情数据）；可选注入 tldr 说明段。总长超限先截 caveats。
- **输出 JSON**：`{定位一句话, 适用场景[≤3], 注意与坑[≤3]（caveats 中文化 + 风险点）, 上手三步[3]}`。
- **prompt 约束**：system 声明——中文、仅基于提供的字段、不得虚构版本号 / 命令 / 功能、无法判断就直说。
- **渲染**：结构化卡（标题 + 四段），底部「AI 生成 · 仅供参考」角标 + 重新生成按钮；缓存命中直接渲染（G3）。
  - **空字段不显示原则**：某数组为空则对应分区整体不渲染，**不渲染任何「暂无 / 未提供」占位**（prompt 侧同步要求模型输出 []，宁缺勿凑）；
  - **渲染基调**：像一段讲解、不是一张表——分区标题是弱化引导词（Normal 字重 + tertiary 色），要点行无符号、靠缩进表达从属；
  - 校验配套：`AiExplainCard.isValid()` 中 summary 必填，scenarios 放宽为 0–3（空字段原则下模型可输出 []），caveats ≤3、steps 2–3 不变。
- **失败**：E1 → 引导进 AI 设置；E2/E3/E4 → 卡内重试按钮；任何失败不阻塞详情页其它分区。
- **自动生成（2026-11-23，默认开）**：AI 设置页「自动生成 AI 讲解」开关
  （`ai_settings_auto_explain`，偏好键 `AI_PREFS_KEY_AUTO_EXPLAIN`，布尔单独存不进 config
  JSON；仅已配 Key 时显示该开关）。开 = 详情页装配时替用户点一次按钮——缓存命中秒开
  （G3）、stale-while-revalidate 原样复用（G10），重复进入同一包不重复调用（TTL 内走缓存）；
  **无 Key 时恒不自动请求也不显示引导**（避免每个详情页推销 AI，判据
  `AiSettingsStore.autoExplain()` 恒回 false）。**失败静默**：自动模式的请求失败不显示
  错误卡（用户没主动要求），入口按钮保持原位可手动重试；手动点击的失败照常分级展示。
  关 = 现状的显式按钮触发。

---

## 5. D2 · AI 帮我找工具（搜索页）

- **入口**：搜索首页「AI 帮我找工具」卡片（一个输入框 + 示例 chips：「我想批量压缩图片」「录屏」「查看端口占用」）。
- **流程**：
  1. 意图 → AiClient：system 要求输出 `[{token, why}]`（≤5 个、真实存在的通用 CLI 名）；
  2. **目录成员过滤**：候选 token 逐一对照本地目录索引，目录外一律丢弃（防 slopsquatting；丢弃计数进日志，G5）；
  3. **引擎排序**：存活候选交给 `BrewSearchEngine` 按相关性重排——**AI 只提名，引擎排序**；
  4. 渲染结果列表（token + why + 查看）；点进详情页后主线二的其它能力（讲解 / 示例）自然衔接。
- **空态**：过滤后为空 → 「没有找到匹配的工具」+ 改述建议；**目录外的名字零展示**。
- **28 中文任务词直查（离线降级）**：无 Key / 断网时自动切换：`rawfile/ai/taskwords.json` 策展表（「压缩图片 → [imagemagick, ffmpeg]」……）精确 / 前缀匹配意图 → 引擎排序。策展清单进 `generate.py` 校验（结构与 token 存在性）。

---

## 6. D3 · AI 报错诊断（执行 Sheet）

- **入口**：执行 Sheet 失败终态（非零退出 / 输出解析失败等用户可读失败）的「AI 解读失败原因」按钮；未配 Key 或断网时不出现（G8）。
- **输入**：命令行原文、stderr 尾部 ≤4KB、stdout 尾部 ≤2KB、失败分类标签（既有六分类之一）、token（如适用）。
- **输出 JSON**：`{发生了什么（一句话）, 可能原因[≤3], 下一步[≤3]}`。
- **渲染**：失败态下方的三段卡；「下一步」条目**只提供复制、不提供执行按钮**（G13——AI 生成的命令永不直接执行）；卡片底注「AI 解读仅供参考」。
- **pc_normal**：无执行通道 → D3 整体不出现。

---

## 7. 阶段二 · 系统级接入（32，登记不展开）

- 小艺 Work 经 ArkTS Skill 连接：对外暴露 `search / preview / install / query` 四个技能；`install` = 唤起详情页预填 + 装机预演（J）确认后执行——**AI 发起，人类点头**。
- 已确认机制：小艺 Work 为本地运行 harness（与 Intents Kit / 小艺 Agent 不同）；**前置实测**：Skill 注册与触发口径真机验证通过后单独立项细化。
- 本 spec 只保证：底座与缓存结构不阻碍阶段二（AiClient 可被 Skill 入口复用，install 流程复用预演语义）。

---

## 8. 失败态分级（AiError，全任务共用）

| 级 | 场景 | D1 行为 | D2 行为 | D3 行为 |
|---|---|---|---|---|
| E1 | 未配置 Key | 按钮位变「配置 AI Key」引导 | 自动切词表模式（G6） | 按钮不出现 |
| E2 | 网络失败 | 卡内重试按钮 | 自动切词表模式 + 提示 | 按钮不出现 |
| E3 | 超时（15s） | 同 E2 | 同 E2 | 同 E2 |
| E4 | 响应格式不符 / Schema 校验失败 | 错误态 + 重试（G11） | 错误态 + 重试 | 错误态 + 重试 |

> **排查记录（2026-11-22，用户接自建 chat completions 端点报「响应格式异常」）**：E4 有四个触发点，
> 与「自建/第三方 OpenAI 兼容端点」最相关的两个——①端点可能不支持 `response_format: json_object`
> （多数兼容网关直接报 400 或忽略后输出 markdown 包裹的 JSON）；②模型输出带 ```json 代码栅栏或前后缀
> 文本，`parseJsonSafe` 直接 `JSON.parse` 失败。③长输出被 `max_tokens` 截断（`finish_reason=length`）
> 导致 JSON 不完整——代码未读 finishReason。④Schema 校验过严（如 D1 `steps` 必须恰好 3 条）。
> 修复项（已实施，见 §3.2）：解析前剥离代码栅栏与首尾非 JSON 文本；`finish_reason=length` 归 E4 并
> 提示「输出被截断，请重试（模型输出过长）」；`steps` 放宽为 2–3 条。
>
> **排查记录二（2026-11-22 续，真机日志 `complete fail code=protocol msg=无法解析模型流式响应：
> Cannot read property prompt_tokens of null`）**：真因在 `@hmkit/ai` 2.0.0 自身——流式 chunk 的
> `"usage": null`（OpenAI 协议允许；one-api 类网关全链路如此）穿过 `!== undefined` 栅栏，
> `consumeUsage(null)` 读 `null.prompt_tokens` 崩 PROTOCOL 被误报为 E4。处置：`@hmkit/ai` 改
> **vendor 源码引入**（`features/hmkit-ai/`，NOTICE.md 登记改动），decoder 判空补 `!== null`
> 直接修根因；曾加的「兼容模式（非流式）」绕行层（设置页 Toggle + 非流式 POST 路径）随之整体
> 移除。伴随的观测增强（E4 reason 四分 fence/truncated/schema/nonjson、E5 body 前 120 字节
> 脱敏直达 UI、`complete head=` 打点）保留——本次报障能 10 分钟定位到根因，靠的就是它们。
| E5 | Provider 内容安全拒绝 | 显示「该包内容无法生成讲解」 | 显示「该意图无法处理」 | 显示「无法解读」 |
| E6 | 用户取消 | 骨架消失，无痕 | 输入保留 | 卡片收起 |

日志统一 tag `[ai]`：`feature=` / `error=` / `latency=` / `cache hit|miss|stale` / `filtered`。**Key 永不进日志。**

---

## 9. 安全与合规

- **AI 生成的命令永不一键执行**（G13）：可执行入口仅 tldr 示例（人工审校）与既有命令卡；AI 建议「只复制」。
- **prompt 注入防御**：上游 desc / caveats 视为不可信文本——system 声明 + 输出仅渲染不执行 + JSON Schema 收口。
- **Key 安全**：Asset Store Kit 存储；日志与偏好文件零明文（G1）。
- **隐私披露**：发送给 provider 的内容 = 包元数据 + 错误文本（不含用户身份 / 设备信息）；关于页补一行说明。
- **成本护栏**：显式触发（不自动跑）+ 输入截断 + 输出 max_tokens + 按 token 缓存。

---

## 10. 文案

| key | zh 值 |
|---|---|
| `ai_settings_title` | AI 设置 |
| `ai_settings_provider` | 服务商 |
| `ai_settings_key` | API Key |
| `ai_settings_test` | 测试连接 |
| `ai_settings_test_ok_detail` | 连接成功 · %s · %d ms（带参资源；**禁止模板字符串内插 `$r()`**——Resource 对象会 toString 成 `[object Object]`） |
| `ai_settings_auto_explain` | 自动生成 AI 讲解 |
| `ai_settings_auto_explain_hint` | 进入详情页时自动生成讲解；关闭后需手动点击「AI 讲解」按钮 |
| `ai_d1_button` | AI 讲解 |
| `ai_d1_badge` | AI 生成 · 仅供参考 |
| `ai_d2_entry` | AI 帮我找工具 |
| `ai_d2_fallback_notice` | AI 未配置，已切换离线词表 |
| `ai_d2_empty` | 没有找到匹配的工具 |
| `ai_d3_button` | AI 解读失败原因 |
| `ai_d3_badge` | AI 解读仅供参考 |
| `ai_error_e2` | 网络不可用，请稍后重试 |
| `ai_error_e4` | 响应格式异常，请重试 |

（en 同步出，编码时补全。）

---

## 11. 改动清单

| 模块 | 改动 |
|---|---|
| `features/brewcommon` | 新增 `service/AiClient.ets`、`service/AiSettingsStore.ets`（Asset Store 封装）、`model/AiTypes.ets`（D1/D2/D3 的请求 / 响应 / 错误类型）、`constant/AiConstants.ets`（promptVersion / TTL / 截断常量）、`util/AiTaskWords.ets`（28 词表加载与匹配） |
| `features/brewdetail` | AI 讲解卡组件 + 装配（安装命令卡之前） |
| `features/brewsearch` | 「AI 帮我找工具」入口 + 结果列表 + 词表降级 |
| `features/mine` | AI 设置页（provider / baseURL / Key / model / 测试连接） |
| 执行 Sheet | 失败终态新增 D3 入口与结果卡（不动执行链路） |
| `hmosword-build` | 新增 `brew-ai/check_taskwords.py`（词表结构 / token 存在性校验，走 generate.py 体系） |
| `resources` | §10 文案（zh/en） |
| `rawfile/ai/taskwords.json` | 28 策展表（首批 ≥20 条高频中文任务词） |

---

## 12. 验证

1. G1–G14 逐条真机验证，日志 tag `[ai]`；
2. grounding 抽检：10 个包的讲解人工评审「无编造」（G4），评审记录归档；
3. 防幻觉断言：mock 一个含幻觉包名的 provider 响应 → 目录外零展示（G5，单测覆盖过滤函数）；
4. Key 安放审计：偏好文件 / hilog / 缓存文件三处 grep 无明文 Key（G1）；
5. 降级矩阵：E1–E6 × D1/D2/D3 的行为逐格真机过（§8 表）；
6. 双 product 构建（G14）；
7. 缓存验证：promptVersion 升级失效（G9）、TTL stale-while-revalidate（G10）、CacheAdmin 清理覆盖 AI 目录。

---

## 13. 风险与未决

| 风险 | 处置 |
|---|---|
| OpenAI 兼容端点差异（response_format / 错误结构不一） | AiClient 做能力探测 + 宽松解析；E4 兜底 |
| JSON 输出不稳定 | 低温度 + Schema 校验 + E4 明确错误态（不做自动多次重试） |
| 成本失控 | 显式触发 + 缓存 + 截断 + max_tokens；设置页显示当前 model |
| Asset Store Kit API 可用性与并发限制 | 编码第一天最小样例验证；不可用则回退加密偏好（方案 B，需评审） |
| 小艺 Work Skill 触发口径未知 | 阶段二独立实测；本 spec 不依赖其结论 |
| pc_normal 的 AI 体验完整性 | D3 / 系统级不出现属预期；D1 / D2 / I 完整可用 |
