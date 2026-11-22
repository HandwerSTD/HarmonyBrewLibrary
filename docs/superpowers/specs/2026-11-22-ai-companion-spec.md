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

- **AI infra 依赖（需求方指定）**：模型调用基础设施使用 `ohpm install @hmkit/ai`（ohpm 三方库，经 `oh-package.json5` 声明依赖）；AiClient 封装该库，不手写 HTTP 调用 OpenAI 兼容端点。BYOK 的 baseURL / Key / model 仍按 §3.1 设置与存储；`@hmkit/ai` 的初始化参数与能力边界（response_format 支持、流式、错误结构）编码第一天以最小样例核对，结论写回本节。
  - **核对结论（2026-11-22，@hmkit/ai 2.0.0，ohpm 注册表可安装）**：
    - 初始化：`HmAIProviders.deepSeek(model)` / `HmAIProviders.custom(baseUrl, model)` → `HmAIProviderConfig` → `createChatClient()` 得 `OpenAICompatibleClient`；自定义端点直接 `new OpenAICompatibleClientOptions(baseUrl, model)`（BYOK 三元组均可注入）；
    - response_format：支持，`HmAIResponseFormat.jsonObject()`（`json_schema` 也有）；端点不支持时服务端忽略该字段，落到「prompt 要求 JSON + 解析校验 E4」兜底；
    - 调用形态：库只有流式入口 `client.createStream(request).start(): Promise<HmAIChatResult>`，非流式语义 = 取最终 result、忽略 onDelta；
    - 错误结构：`HmAIError { code: HmAIErrorCode, statusCode?, responseBody? }`，code ∈ network / timeout / http / protocol / cancelled / invalid_argument / internal / tool*——与本 spec E2/E3/E4/E6 一一映射；HTTP 4xx/5xx 走 `http` 码 + `statusCode`（内容安全按 E5）；
    - 其它：`connectTimeoutMs` / `readTimeoutMs` 可设（取 15s）；`HmAIUsage`（promptTokens/completionTokens）随 `includeUsage=true` 返回；Key 在库的 `options.apiKey` 上设置，不落日志。
    - 已知边界：库不做非流式接口、不做端点能力探测（本 spec 也不做探测，E4 兜底）。
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

- **入口**：详情页「AI 讲解」按钮（描述分区之后、用法示例之前；显式触发，不自动消耗）。
- **输入（grounding 严格限定）**：`token`、`desc`、`caveats`、`dependencies`（全部来自既有详情数据）；可选注入 tldr 说明段。总长超限先截 caveats。
- **输出 JSON**：`{定位一句话, 适用场景[≤3], 注意与坑[≤3]（caveats 中文化 + 风险点）, 上手三步[3]}`。
- **prompt 约束**：system 声明——中文、仅基于提供的字段、不得虚构版本号 / 命令 / 功能、无法判断就直说。
- **渲染**：结构化卡（标题 + 四段），底部「AI 生成 · 仅供参考」角标 + 重新生成按钮；缓存命中直接渲染（G3）。
- **失败**：E1 → 引导进 AI 设置；E2/E3/E4 → 卡内重试按钮；任何失败不阻塞详情页其它分区。

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
- **实现登记（2026-11-22）**：阶段二未实现。接口方向——`AiClient.complete / AiTasks.*` 均为无 UI 依赖的静态入口（Context 经 `AppStorage[UI_CONTEXT]` 惰性获取），Skill 入口可直接复用；缓存目录与 promptVersion 机制与入口无关。

---

## 8. 失败态分级（AiError，全任务共用）

| 级 | 场景 | D1 行为 | D2 行为 | D3 行为 |
|---|---|---|---|---|
| E1 | 未配置 Key | 按钮位变「配置 AI Key」引导 | 自动切词表模式（G6） | 按钮不出现 |
| E2 | 网络失败 | 卡内重试按钮 | 自动切词表模式 + 提示 | 按钮不出现 |
| E3 | 超时（15s） | 同 E2 | 同 E2 | 同 E2 |
| E4 | 响应格式不符 / Schema 校验失败 | 错误态 + 重试（G11） | 错误态 + 重试 | 错误态 + 重试 |
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
| `features/brewcommon` | 新增 `service/AiClient.ets`、`service/AiSettingsStore.ets`（Asset Store 封装）、`service/AiTasks.ets`（三任务的 prompt/解析/缓存/过滤编排）、`service/AiCache.ets`（盘上缓存）、`model/AiTypes.ets`（D1/D2/D3 的请求 / 响应 / 错误类型）、`constant/AiConstants.ets`（promptVersion / TTL / 截断常量）、`util/AiTaskWords.ets`（28 词表加载与匹配）、`component/BrewAiFailureCard.ets`（D3 卡，随执行 Sheet 分发） |
| `features/brewdetail` | AI 讲解卡组件 `BrewAiExplainCard.ets` + 装配（描述分区之后、tldr 之前） |
| `features/brewsearch` | 「AI 帮我找工具」入口（`BrewAiFindCard`，挂未提交态历史/发现区之前）+ `model/AiCatalogIndex.ets`（目录成员判定）+ 结果列表 + 词表降级（`AiFindVM`） |
| `features/mine` | AI 设置页（provider / baseURL / Key / model / 测试连接；路由 `MineAiSettingsView`） |
| 执行 Sheet | 失败终态（FAILED / TIMEOUT）新增 D3 入口与结果卡（不动执行链路；入口随 `BREW_CLI_ENABLED` 门控） |
| `hmosword-build` | 新增 `brew-ai/check_taskwords.py`（词表结构 / token 存在性校验，走 generate.py 体系） |
| `resources` | §10 文案（zh/en/base 三套，落在 `features/brewcommon`——全项目字符串的既有归属地）；关于页隐私披露 |
| `rawfile/ai/taskwords.json` | 28 策展表（首批 ≥20 条高频中文任务词；随 `features/brewcommon` HAR 打包） |
| 根 `oh-package.json5` | `@hmkit/ai@^2.0.0`；`parameterFile` 参数化移除（ohpm 6.0.1 拒绝在含 parameterFile 的工程执行 `ohpm install <pkg>`，@param 引用就地内联，行为不变） |

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
| Asset Store Kit API 可用性与并发限制 | 编码第一天最小样例验证；不可用则回退加密偏好（方案 B，需评审）。**实测（2026-11-22）：Asset Store Kit（@kit.AssetStoreKit，API 23 SDK）可用，`addSync` / `querySync` / `removeSync` 已接入**；不可用时的兜底为「进程内存」（不落盘版本），重启后需重填，设置页有提示。加密偏好方案 B 未启用、无需评审。 |
| 小艺 Work Skill 触发口径未知 | 阶段二独立实测；本 spec 不依赖其结论 |
| pc_normal 的 AI 体验完整性 | D3 / 系统级不出现属预期；D1 / D2 / I 完整可用 |
