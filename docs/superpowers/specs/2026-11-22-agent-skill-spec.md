# AI 系统级接入（小艺 Work × ArkTS Skill）· 设计

> 日期：2026-11-22。状态：待评审。评审通过后 Stage 0 探针先行；实现开工定在 D 线合入 dev 之后。
> 范围：`products/pc_acl` 新增 `skills/` 目录与 `skillProfiles` 注册；`features/brewcommon` 新增 dry-run 解析器（纯函数层）；
> `hmosword-build` 新增契约一致性与零副作用审计脚本；`compatibleSdkVersion` 视探针结论升至 26。
> 叙事定位：motivation 主线二「系统级」拍——「对小艺说『装个 ffmpeg』：AI 发起，人类点头」
> （[`motivation.md`](../2026-11-21-brainstorm/motivation.md) 主线二末段）；架构定位见
> [`decisions.md`](../2026-11-21-brainstorm/decisions.md) 第 32 条与灵魂问答（round5 补记、第 69 行问答）。
> 官方依据：[基于 ArkTS 脚本的应用 Skill 开发指导](https://developer.huawei.com/consumer/cn/doc/doccenter-capabilities/arkts-skill-development-guide.md)、
> [@ohos.app.ability.scriptManager 参考](https://developer.huawei.com/consumer/cn/doc/doccenter-references/api/js-apis-app-ability-scriptmanager.md)。
> 相关文档：[`2026-11-21-brew-tap-trust.md`](../../knowledge/2026-11-21-brew-tap-trust.md)（设备 brew 支持 `--dry-run` 的事实）、
> [`2026-11-21-probe-inside-app.md`](../../knowledge/2026-11-21-probe-inside-app.md)（探针规矩）、
> [`2026-10-04-brew-command-execution-spec.md`](2026-10-04-brew-command-execution-spec.md)（执行 Sheet）。

---

## 1. 目标与成功判据

小艺 Work 是本地运行的 Agent harness，可经 ArkTS Skill 连接鸿蒙应用。**本应用的定位不是 AI 的使用者，是 AI 可调用的技能层**：Skill 端零 AI 调用（LLM 在小艺 Work），只对外提供冻结口径（目录事实）、状态（安装快照）与护栏（预演 + 人类点头）。

| # | 判据 | 可观测证据 |
| --- | --- | --- |
| G1 | Stage 0 探针四问结论落盘 `docs/knowledge/2026-11-22-agent-skill-probe.md`（见 §3.1） | knowledge 文档 |
| G2 | API 26 升版（若探针放行）后双 product 构建通过：`devecocli build --product default` / `--product pc_normal` | `BUILD SUCCESSFUL`，`ERROR` 计数 0 |
| G3 | Skill 经 AGC 测试版通道导入成功，真机小艺 Work 能看到并列出本技能 | 真机；AGC 控制台记录 |
| G4 | 「ffmpeg 装了没有」「帮我找找下载视频的工具」→ `queryPackage` / `searchPackages` 返回目录事实与盘上快照状态（版本、outdated、安装状态），与页面显示一致 | 真机；回包 JSON 与页面比对 |
| G5 | 「装个 ffmpeg」→ `requestInstall` 返回 would-install 预演清单 + `needs_confirmation` + 指路文案；**Skill 层零 UI、零执行**：预演经小艺回话呈现，「点头」是用户随后在应用详情页亲手点安装 | 真机；`[skill]` 日志 |
| G6 | 触达点零副作用审计全绿：`skills/` 脚本 import 白名单（scriptManager / Bridge / BasicServicesKit），Bridge 无任何写执行调用 | `node hmosword-build/brew-skill/audit_skill_no_exec.mjs` |
| G7 | 目录中不存在的 token 一律走 `ERR_NOT_FOUND` 分支 + suggestion 引导改用 `searchPackages`，**绝不猜包名**（slopsquatting 防线） | 真机（问一个编造的包名） |
| G8 | SKILL.md 触发边界实测生效：系统软件更新、卸载应用、问 brew 新闻等相邻话术不触发本技能 | 真机 |
| G9 | pc_normal 无 skill 注册；skillProfiles 仅存在于 pc_acl | HAP 审计 + G2 构建 |
| G10 | 契约一致：SKILL.md 的 functionName / args Schema / 返回分支与入口脚本方法逐一对应 | `node hmosword-build/brew-skill/check_skill_contract.mjs` 全绿 |
| G11 | 冷启动调起可用：应用未运行时小艺触发 Skill，search/query/preview 仍返回（目录未就绪先 `BrewTable.refresh()`，仍失败走 `ERR_INTERNAL` + 指引） | 真机；`[skill]` 日志 |
| G12 | API 升版后存量功能真机冒烟不变：tldr 区块、本机包管理、详情页、执行 Sheet 行为与升级前一致 | 真机回归清单 |

## 2. 现状与定位

| 位置 | 现状 |
| --- | --- |
| 官方机制 | Skill = 声明契约（`SKILL.md`：元数据 + 触发场景 + 能力契约）+ ArkTS 薄适配脚本（`export default class`，public async 方法名与 functionName 严格一致，首参 `ArkTSScriptInfo`，argv 按位取参）+ `module.json5` 的 `skillProfiles` 注册；结果经 `scriptManager.completeArkTSScriptInApp(context, requestCode, result)` 回包；`ExecuteResult{code, result, uris?, flags?}`，错误码 16000020 / 16000003 / 16000050 |
| **API 版本硬门槛** | scriptManager 全系 API 26.0.0 起（2in1 26.0.0+）；本项目 `compatibleSdkVersion = 6.1.0(23)`。**升版是全 product 行为**，牵动双 product 与全部存量代码——探针第一问 |
| 项目内残留 | 零（已核实无 skillProfiles / scriptManager / skills/ 引用；`StorageKey` 中 IntentFramework 注释键与意图框架无关，不可复用） |
| 搜索 | `features/brewsearch` 离线检索已建成（目录事实），Skill 端直接复用其数据层 |
| 状态 | `BrewInstalledLoader` 盘上快照（`brew_installed_snapshot`）——安装状态 / outdated / 版本的冻结口径 |
| 执行 | `BrewCommandRequest(title, cmdline, args)` → `BrewCommandSheet` 确认后执行，退出码回显——「人类点头」的既有载体 |
| 预演 | **全库零 dry-run 痕迹**：`brew install --dry-run` 的输出解析器从零写，落 `features/brewcommon` util（J 装机预演落地时直接复用） |
| 上传链路 | Skill 导入需 HAP 上传 AGC——项目已有 `agc` CLI 测试版技能链路可用 |
| 灵魂问答（decisions 69） | 「小艺 Work 直接调 brew 还要你们干什么」→ 裸调 brew 缺四样：状态（回滚锚点）、冻结口径（可溯源 vs 概率性）、护栏（预演/安全网）、防幻觉（编造包名 = slopsquatting 真实供应链攻击面）。本 spec 的四项能力就是这四样的接口化 |

## 3. Skill 契约设计

### 3.1 Stage 0 · 真机探针四问（先探后定，结论落 knowledge 文档）

| # | 问题 | 判定 |
| --- | --- | --- |
| Q1 | 真机 OS 版本与小艺 Work 可用性：OS 是否 ≥ Skill 要求的设备版本？小艺 Work 入口与 Agent 触发是否可用？ | 不满足 → 32 停在 spec，标记「平台门未过」，不排期（L 版本时光机同款规矩） |
| Q2 | 工具链：本机 DevEco/devecocli 是否有 API 26 SDK；`compatibleSdkVersion/targetSdkVersion` 升 26 后双 product 构建、存量代码是否报错 | 决定升版代价（G2/G12 的范围） |
| Q3 | Skill 脚本能否 import 跨模块包（`@ohos/brewcommon` 等）：官方示例为模块内相对路径，本项目业务全在 feature 模块 | 不可用则兜底：pc_acl 内写转发薄层 |
| Q4 | Skill 导入链路（**裁决：不上云端、无 invoke 工具注册**）：HAP 上传后设备侧的注册与「小艺可见性」如何验证；真实生产样本的三件套（SKILL.md + scripts + skillProfiles）即全部产物 | 决定验证路径 |

### 3.2 目录与注册（Q3 放行后）

```
products/pc_acl/
├── skills/
│   └── handwer-brew-library/          # org 前缀防冲突
│       ├── SKILL.md                   # 声明契约：元数据 / 触发场景 / 能力契约
│       └── scripts/
│           └── BrewSkill.ets          # 薄适配层：解析 argv → 调 Bridge → 按契约回包
└── src/main/module.json5              # skillProfiles: name / abilityName=PcAbility / srcEntries / version
```

`BrewSkill.ets` 只做三件事：按 Schema 前置校验 argv（白名单枚举二次校验）、调用 `BrewSkillBridge`（§3.4）、按契约构造 `ExecuteResult` 并经唯一的 `report()` 出口回包。**业务逻辑一律不进脚本**。

对照真实生产样本（`biandan-assistant`，2026-11-22 需求方提供）后的契约加固与裁决：
- **仅 B 通道**：本技能不上云端、不做 invoke 工具注册——样本里的 `references/tools/*.json`（云端小艺 invoke 的 deviceCommand 模板）不适用，不补。
- **argv 单 JSON 字符串约定**：SKILL.md 教 harness 先 `JSON.stringify` 再转义 `\"`，脚本端「直接解析 → 失败还原 `\"` 重试一次」双形态兼容；argv 形态错误的 errMsg 带「参数传递格式错误」锚点，SKILL.md 据此指示自动压参重试一次（业务字段缺失与 NOT_FOUND 不自动重试）。
- **跨模块编译已被样本证明**：样本脚本直接 import 多个跨模块包，探针 Q3 的风险基本排除；本技能的常量本地副本仍是刻意的保守设计（契约检查脚本核对不漂移）。

### 3.3 四项能力（SKILL.md 能力契约）

| functionName | 语义 | 业务实现 | 返回 |
| --- | --- | --- | --- |
| `searchPackages` | 关键词找包（小艺 Work 的 LLM 负责从自然语言抽词） | brewsearch 离线检索数据层 | `matchedCount` + 前 5 条 `{name, kind, summary}` |
| `queryPackage` | 包的状态与详情（装没装、什么版本、旧不旧） | 盘上快照 + 详情数据服务；快照缺失时单包 `info --json=v2`（只读） | `{installed, version, outdated, summary, caveats?}` |
| `previewInstall` | 装下去会发生什么（不动盘） | `brew install --dry-run <token>` → `BrewDryRunParser`（新，落 brewcommon） | `{wouldInstall[], totalSize?}` |
| `requestInstall` | AI 发起安装——**只预演，不执行、不碰 UI** | 与 previewInstall 同一实现（Bridge 内同一函数），区别仅在触发话术与 suggestion：预演清单交小艺回话，指引用户去应用详情页亲手安装 | `status: 'needs_confirmation'` + 预演清单 + suggestion「预演完成，请在 Harmonybrew 中打开该包详情页确认安装」 |

每个能力在 SKILL.md 内：exec-cli 调用示例（`command: ohos-arkTSScript`）+ args JSON Schema（枚举参数白名单二次校验）+ 全部返回分支示例（成功 + `ERR_INVALID_PARAMS` / `ERR_NOT_FOUND` / `ERR_INTERNAL`）+ 顶层 oneOf Schema。触发场景写全典型话术（「装个 ffmpeg」「ffmpeg 装了没有」「装 ffmpeg 会带哪些东西」）与**不调用的情况**（系统软件更新 / 卸载手机应用 / 问 brew 资讯 / 查询本应用自身设置）。

### 3.4 BrewSkillBridge（pc_acl 内薄服务层）

Skill 脚本唯一可 import 的业务出口。职责：调 brewsearch 数据层 / 盘上快照 / `BrewCli`（仅 `--dry-run` 一个只读命令）。**整层无 UI 触点**：不 import 任何 UI 符号、不写待确认记录、不拉起应用、不碰 `BrewCommandRunner` / `BrewCommandSheet`——审计脚本（G6）锁死。
裁决记录（2026-11-22，需求方裁定）：「应用侧确认卡 + 拉起 PcAbility」从本期砍除，Skill 层收敛为纯 headless（预演 + 指路）；「人类点头」落在应用详情页既有的安装按钮上，应用侧一行不改。

## 4. 数据流与确认链路

```
小艺 Work（LLM，不在本项目）
   │ 意图匹配 SKILL.md → exec-cli 调用
   ▼
BrewSkill.ets（薄适配：校验 argv）
   ▼
BrewSkillBridge（只读业务：目录检索 / 盘上快照 / dry-run；冷启动先 BrewTable.refresh()）
   ▼
ExecuteResult ── completeArkTSScriptInApp ──► 小艺回话（预演清单 / 状态 / 指路文案）
                                                │ 人类点头
                                                ▼
                              用户在 Harmonybrew 详情页亲手点安装（既有 UI，本期一行不改）
```

- **Skill 层零 UI**：不读 AppStorage、不写 preferences、不 startAbility、不 import 任何 UI 符号（G6 审计覆盖）。应用侧唯一的「确认动作」就是既有详情页安装按钮。
- 冷启动（G11）：小艺调起时应用可能未运行——bridge 先看目录是否就绪，未就绪先 `BrewTable.refresh()`，仍失败回 `ERR_INTERNAL` + 指引「先打开一次 Harmonybrew」；盘上快照的懒读在冷启动同样成立。

## 5. 失败态分级

| 场景 | 表现 |
| --- | --- |
| argv 缺失 / 枚举非法 | `ERR_INVALID_PARAMS` + suggestion「你想装哪个包？」，不进业务 |
| token 不在目录（或 dry-run 报 Not found） | `ERR_NOT_FOUND` + data 带 searchedKeywords + suggestion 引导 searchPackages（G7） |
| brew 不可用 / 执行通道未就绪（BREW_CLI_ENABLED=false 或 pc_normal） | `ERR_INTERNAL` + suggestion「请在 Harmonybrew 中先完成 brew 探测」；pc_normal 构建本身不含 skill（G9），此分支仅防运行时降级 |
| dry-run 超时 / 输出解析失败 | `ERR_INTERNAL` + errMsg 带 stderr 摘要；不回猜的清单 |
| 目录未就绪（冷启动，refresh 后仍空） | `ERR_INTERNAL` + suggestion「先打开一次 Harmonybrew，让软件包目录就绪」（G11） |
| `completeArkTSScriptInApp` 失败 | 仅打日志（唯一的 report 出口吞异常，不二次抛出） |

## 6. 安全与合规

- **零副作用红线（G6）**：有副作用的命令（install/upgrade/uninstall）只存在于「人类点头之后」的既有链路；Skill/Bridge 层静态审计锁死。与「AI 生成的命令永不一键执行」同一条红线。
- **防幻觉 / slopsquatting（G7）**：所有名字类回答都出自目录事实与命令真实输出；不存在的名字一律显式失败，不猜、不改写、不「帮用户纠正成相近包名」。这是灵魂问答的技术兑现，也是 Skill 层相对裸调 brew 的核心增值。
- **口径冻结**：search/query 返回目录与快照数据（确定性、可溯源），不做概率性生成；预演清单是 dry-run 的原文解析，不是 LLM 的预测。
- SKILL.md 的 description 与触发场景措辞收窄（只认「软件包」语境），把误触发压到最低（G8）。
- 无新增 manifest 权限（沿用既有 INTERNET 等）；`uris`/`flags` 授权字段本期不使用。

## 7. 文案

suggestion 一律中文、口语、不暴露内部错误细节（SKILL.md 示例与脚本常量同步）：

| 场景 | suggestion |
| --- | --- |
| 参数不全 | 「你想装哪个包？」 |
| 没找到 | 「软件包目录里没有「%s」，要不要说说你想做什么，我帮你找找？」 |
| 需要确认 | 「预演完成，清单在上面。请在 Harmonybrew 里打开这个包的详情页，点安装才算数。」 |
| 内部错误 | 「这次没成，%s，稍后再试试。」 |
| 执行通道未就绪 | 「先在 Harmonybrew 里把 brew 探测跑通，再让我来。」 |

## 8. 改动清单

| 文件 | 改动 |
| --- | --- |
| `products/pc_acl/skills/handwer-brew-library/SKILL.md` | 声明契约（§3.3 全文） |
| `products/pc_acl/skills/handwer-brew-library/scripts/BrewSkill.ets` | 四能力薄适配 + 唯一 report 出口 |
| `products/pc_acl/src/main/module.json5` | `skillProfiles` 注册（Q3 结论决定 srcEntries 写法）；无新增权限 |
| `products/pc_acl/src/main/ets/skill/BrewSkillBridge.ets` | 只读业务出口（headless）：目录检索 / 盘上快照 / dry-run / 冷启动目录就绪 |
| `features/brewcommon/src/main/ets/util/BrewDryRunParser.ets` | `--dry-run` 输出解析（Would install 清单 / 体积行 / Not found），纯函数 + 检查脚本用例 |
| `features/brewcommon/src/main/ets/constant/SkillConstants.ets` | pending 键、超时阈值、路由参数名 |
| `build-profile.json5` | Q2 放行后 `compatibleSdkVersion/targetSdkVersion` → 26（双 product 同步），升级说明入 decisions.md |
| `hmosword-build/brew-skill/check_skill_contract.mjs` | G11：SKILL.md ↔ 脚本方法名 / args / 返回分支一致性 |
| `hmosword-build/brew-skill/audit_skill_no_exec.mjs` | G6：scripts import 白名单 + Bridge 零写执行扫描 + BrewDryRunParser 检查用例 |
| `docs/knowledge/2026-11-22-agent-skill-probe.md` | G1 探针结论（真机执行后补） |

## 9. 验证

1. **探针（真机，用户执行）**：§3.1 四问逐项记录 → Q1 不过则停（不排期）；Q2/Q3/Q4 决定升版与兜底方案。
2. **静态**：`node hmosword-build/brew-skill/check_skill_contract.mjs` 与 `audit_skill_no_exec.mjs` 全绿（G11/G6）。
3. **构建**：升版后双 product `devecocli build` ERROR 0（G2/G9）。
4. **AGC + 真机（用户执行）**：测试版上传 → 导入 Skill → 小艺 Work 触发四话术 + 三类边界话术 + 冷启动调起（G3/G4/G5/G7/G8/G11）；`[skill]` 日志覆盖每次调用与冷启动分支。
5. **回归（真机）**：API 升版后存量冒烟清单（G12）——tldr 区块、详情页、本机包管理、执行 Sheet、（若已合入）AI 卡片与哨兵卡片。

## 10. 风险与未决

- **平台门是第一风险**：Q1 任一分叉（OS 版本不够 / 小艺 Work 不可用）→ 本 spec 停在评审态，进 decisions.md 实测门槛账，与 L 版本时光机同款处理，不强行降级实现（Skill 机制没有「部分可用」形态）。
- **API 26 升版波及全量代码**：升版可能触发存量 API 弃用告警/行为变化；G2/G12 把代价显性化。若升版代价不可控，备选路径是等 D 线与主线四收尾后再评估（32 本就排序靠后，不阻塞任何线）。
- `InApp` 同进程假设未实测：冷启动拉起的上下文差异在探针一并确认；本期 Skill 层无任何跨调用状态，即便上下文不同也不影响正确性。
- dry-run 输出格式没有官方契约（brew 版本间可能漂移）：解析器按 tap-trust 实测样本编写，J 落地时共享同一解析器与用例，漂移风险两处同源。
- SKILL.md 的检索与排序规则（哪个 skill 被小艺选中）平台侧不可控：description 措辞与触发场景边界是唯一抓手，G8 实测后按结果回改措辞。
- 与 D 线的关系：本 spec 与 D1–D3（应用内 AI）**互不依赖**——Skill 端零 AI 调用；开工排序仍按构建顺序（D 合入后），只因 build-profile 冲突面，不因功能依赖。
