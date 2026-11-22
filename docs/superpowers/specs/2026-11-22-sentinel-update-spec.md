# 更新哨兵（outdated 通知 + PC 桌面卡片）· 设计

> 日期：2026-11-22。状态：待评审。评审通过后按「构建顺序」在 AI 底座（D1–D3）合入 dev 之后实施。
> 范围：`products/pc_acl` 新增 FormExtensionAbility / 卡片页 / form_config；`features/brewcommon` 新增哨兵服务；
> `features/mine` 设置页新增通知频控行；`hmosword-build` 新增触达点零执行审计脚本。
> 叙事定位：motivation 主线三「平时」第一拍——「brew 第一次主动说话」（[`motivation.md`](../2026-11-21-brainstorm/motivation.md) 平时段）；
> 裁决与排序见 [`decisions.md`](../2026-11-21-brainstorm/decisions.md) 第 13 号（重要性第 8 位）；
> 推导见 [`round2.md`](../2026-11-21-brainstorm/round2.md) §2.3、[`round4.md`](../2026-11-21-brainstorm/round4.md)（通知带动作按钮）。
> 参考实现：`../CloudPurePlay` 的 Form 栈（`FormExtensionAbility` + `$profile:form_config` + FormManager 登记 + 卡片页三件套），按单卡片场景简化。
> 相关文档：[`2026-11-21-brew-cache-ownership.md`](../../knowledge/2026-11-21-brew-cache-ownership.md)（缓存归属）、
> [`2026-11-21-probe-inside-app.md`](../../knowledge/2026-11-21-probe-inside-app.md)（探针规矩）。

---

## 1. 目标与成功判据

brew 的世界观里「更新靠用户想起来」；本应用替它说一声：待升级集合变化时，经系统通知与 PC 桌面卡片告知「gh 有新版本可升」，点开直达既有升级队列。**升级动作永远由用户确认，绝不静默升级。**

| # | 判据 | 可观测证据 |
| --- | --- | --- |
| G1 | 卡片可添加到 2in1 桌面：显示待升级数、前 3 个包名、「数据截至 HH:mm」；无快照时显示引导态而非 0 假数据 | 真机 |
| G2 | 点卡片直达 `MinePackagesView` 升级队列（复用既有路由与路由参数，不新建页面） | 真机 |
| G3 | 待升级集合非空且频控允许时收到系统通知：待升级数 + top 包名 + 动作按钮「全部升级」「稍后」 | 真机 |
| G4 | 「全部升级」按钮直达升级队列，「稍后」撤销通知；两条路径都**不执行任何命令** | 真机 |
| G5 | 触达点零执行审计：卡片页、通知构造代码不含任何 brew 命令拼装/执行调用，审计脚本全绿 | `node hmosword-build/brew-sentinel/audit_no_brew_in_touchpoints.mjs` |
| G6 | 通知去重：同一 outdated 集合（集合哈希）只通知一次，集合变化才重新通知 | 真机；`[sentinel]` 日志 |
| G7 | 频控设置生效：关 / 每天 / 每周三档；「关」停通知不停卡片 | 真机 |
| G8 | 通知未授权：用户拒绝授权后不崩、不反复弹授权，卡片功能完好，设置页保留「去开启」引导入口 | 真机 |
| G9 | 数据诚实：无论落在哪档调度（P1/P2/P3），卡片永远标注「数据截至」；快照超过 24h 时卡片降显「打开应用刷新」，不假装实时 | 真机 |
| G10 | pc_normal 不含哨兵代码路径与 form ability；双 product 构建通过 | `devecocli build --product default` 与 `--product pc_normal`，`ERROR` 计数 0 |
| G11 | Stage 0 探针四问结论落盘 `docs/knowledge/2026-11-22-sentinel-probe.md`（见 §3） | knowledge 文档 |
| G12 | 实施档位（P1/P2/P3）按探针结论选定，代码内档位常量与 knowledge 文档结论一致 | 代码 + 文档 diff |
| G13 | `onRemoveForm` 清理登记、重复添加不串数据：移除卡片后快照仍归应用所有，重添加后立即按盘上快照渲染 | 真机 |

---

## 2. 现状

| 位置 | 现状 |
| --- | --- |
| `features/brewcommon/…/service/BrewInstalledLoader.ets` | outdated 链路已建成：`brew info --json=v2 --installed` → `outdated` 字段；快照「内存一份 + 盘上一份」（`brew_installed_snapshot` 键，10 分钟新鲜窗口），盘上快照按「可能缺失/被改」防御式读取。**任何进程都可零命令懒读盘上快照** —— 数据链路零新增的根据 |
| `features/mine/…/MinePackagesVM.ets` | 升级队列已建成：`upgradeAllArgs()` → `BrewCommandRequest` → 既有执行 Sheet（用户确认后执行，退出码回显） |
| `features/mine/src/main/resources/base/profile/router_map.json` | `MinePackagesView` 路由已注册 —— 通知/卡片直达即可，无需新页面 |
| `features/mine/…/MineSettingView.ets` | 设置页为行式列表（源设置、关于等），新增频控行的宿主 |
| `common/…/CommonEnums.ets` | `StorageKey` 枚举集中管理 AppStorage 键；哨兵的 preferences 键另立常量文件，不入此枚举（避免跨进程误用 AppStorage） |
| `products/pc_acl/src/main/module.json5` | entry 模块，仅 `abilities`，无任何 `extensionAbilities` —— H 从零搭；pc_normal 是独立 entry 模块，天然隔离 |
| 通知 / Form / 后台调度 | **项目内零残留**（已 grep 核实：无 FormExtensionAbility、无 notificationManager、无 workScheduler 引用） |
| 参考 `../CloudPurePlay` | `FormExtensionAbility`（`onAddForm` 登记 → `triggerRefreshCard`；`onFormEvent` 处理卡片消息；`onRemoveForm` 注销）+ `$profile:form_config.json`（`isDynamic` / `updateEnabled` / `updateDuration` / `supportDimensions`）+ 卡片页三件套。其 `@handwer/form_manager` 是多卡片多形态的通用层，本应用单卡片，收敛为一个轻量登记器即可 |

## 3. 数据流、调度与降级阶梯

### 3.1 数据流（零新增命令链路）

```
BrewInstalledLoader（既有，内存 + 盘上快照）
        │ 快照变化（refresh 完成或盘上快照读出后比对）
        ▼
BrewSentinelService（新）
        ├─ 写卡片：遍历登记的 formId → formProvider.updateForm（数据 = 盘上快照派生的 {count, topNames, updatedAtText}）
        └─ 发通知：频控 + 集合哈希去重 → notificationManager.publish（按钮 = wantAgent → MinePackagesView）
```

- 哨兵**永远只读盘上快照，不自己跑 brew**。刷新时机（跑命令）仍归 `BrewInstalledLoader`：应用前台打开/回到本机包管理页时按既有 10 分钟新鲜窗口刷新，刷新完成顺带触发哨兵比对。这样「卡片进程能不能跑 ShellUtils」从设计上就不成立依赖。
- 集合哈希：对 outdated 的 `fullName` 排序后拼接取哈希，存入哨兵 preferences（连同上次通知日期）。哈希不变 = 不通知（G6）。
- 卡片更新：`onAddForm` 立即按盘上快照渲染一次；此后「快照变化」与「系统定时回调」两条路径都走同一个 `pushToForms()`。

### 3.2 Stage 0 · 真机探针（实测先行，先探后定）

一次性探针构建（带调试开关的实现 build，不单独做探针 app），真机回答四问，结论落 `docs/knowledge/2026-11-22-sentinel-probe.md`：

| # | 问题 | 判定 |
| --- | --- | --- |
| Q1 | 2in1 桌面支持哪些卡片规格？`supportDimensions` 实测（候选 1\*2 / 2\*2 / 2\*4） | 决定 form_config 的 `supportDimensions` 取值 |
| Q2 | `updateEnabled + updateDuration`（30 分钟粒度）在 PC 桌面的真实触发边界：息屏/长闲置下是否触发、下限多少 | 决定 P2 是否作为常驻兜底 |
| Q3 | work scheduler 在应用退出的情况下于 2in1 的触发行为（间隔、冻结态、重启后 `isPersisted` 恢复） | 决定 P1 是否成立 |
| Q4 | 扩展进程（FormExtensionAbility / WorkSchedulerExtensionAbility）里 `ShellUtils.available()` 与 brew 路径探测结果 | 仅探明，**不作为依赖**（§3.1 已按「不跑命令」设计）；结论供后续 F/G/J 复用 |

### 3.3 调度降级阶梯（G12 按探针结论选定，代码内常量记录档位）

| 档 | 机制 | 数据新鲜度 | 成立条件 |
| --- | --- | --- | --- |
| P1 全量 | work scheduler 周期回调 → 调用方提示应用外不可刷新时**仍只读快照**；应用前台的刷新照常 | 最长 = work 间隔 | Q3 触发边界可用。注：即使 Q4 允许扩展进程跑命令，v1 也不跑——保活边界与命令耗时不可控，留给 F/G/J 复用结论再议 |
| P2 卡片自刷 | form_config `updateEnabled: true` + `updateDuration` 系统定时回调 → `pushToForms()` 读盘上快照 | 最长 = 卡片刷新间隔 | Q2 边界可用 |
| P3 纯前台（保底） | 应用每次回前台刷新 → 哨兵比对 → 写卡 + 通知；桌面卡片仅在应用存活期间更新 | 应用存活期 | 任何探针结果下都成立；三档的实现是同一份代码的三种触发配置，降级只是换触发源 |

无论哪档：卡片标注「数据截至 HH:mm」（G9）；快照 > 24h 时卡片降显「打开应用刷新」。

### 3.4 通知规则

- 首次发布前 `requestEnableNotification()`；拒绝后静默降级（G8），设置页留「去开启」入口。
- 固定 notificationId（哨兵单通道），重复发布覆盖旧通知，不堆叠。
- 频控「每天 / 每周」以**上次通知日期**为准（不是固定时刻闹钟）——哨兵是「有变化才说」，频控只是变化过于频繁时的限流。
- 「稍后」= 撤销通知，且当次集合哈希记为已提醒（本轮不再通知）。

## 4. 交互与视觉

- **卡片（1\*2 或探针定的规格）**：上「N 个软件包可升级」大数字 + 下方前 3 个包名（多则「等 N-3 个」）；底部「截至 HH:mm」小字。引导态（无快照）：中间「添加后自动跟踪软件包更新」。视觉沿用主工程卡片语言（圆角、卡片底色，参考 `BrewCategoryCardHeader` 的常量），不引入新主题。
- **通知**：标题「N 个软件包有新版本」；正文前 3 个包名 + 「点按查看升级队列」；按钮「全部升级」（wantAgent → `MinePackagesView`）与「稍后」。**按钮语义是「带我去」，不是「替我跑」**（round4 原案：闭环靠按钮直达，不靠文案，更不靠自动执行）。
- **设置**：`MineSettingView` 新增「更新哨兵」行 → 子页两行：提醒频率（关 / 每天 / 每周，默认每天）+ 通知授权引导行（已授权时显示「已开启」不可点）。
- pc_normal：无哨兵入口（pc_acl 独占），无需隐藏逻辑。

## 5. 失败态分级

| 场景 | 表现 |
| --- | --- |
| 无盘上快照（从未打开过本机包管理） | 卡片引导态；不发通知（没有集合就没有「变化」） |
| 快照 > 24h | 卡片降显「打开应用刷新」；不发通知（数据太旧不配打扰） |
| 通知未授权 | 静默跳过通知路径，卡片照常；不重试弹授权（G8） |
| `updateForm` 失败（卡片已移除但登记未清） | 清登记、记 warn 日志，下次 `onAddForm` 自然恢复（G13 兜底） |
| work scheduler / 卡片回调不可用（探针否定） | 按 §3.3 降档，属于配置切换而非代码失败 |

## 6. 安全与合规

- **绝不静默升级**：哨兵全链路（卡片页、通知构造、回调）不 import 任何命令生成/执行符号；`hmosword-build/brew-sentinel/audit_no_brew_in_touchpoints.mjs` 静态扫描触达点文件集合，命中 `BrewCommandGenerator|BrewCommandRunner|BrewCli|ShellUtils` 即失败（G5）。通知按钮与卡片点击都只做路由跳转。
- 无新增 manifest 权限：通知发布无需权限（首次 `requestEnableNotification` 引导）；work scheduler 基础使用无需权限——探针实测确认，若实测要求权限再回补本节与 G 门。
- 快照复用既有 `brew_installed_snapshot` 存储，不新增数据文件；哨兵 preferences 只存 formId 登记表、集合哈希、上次通知日期、频控档位。
- 命令由 AI 生成的部分**永不一键执行**的既有红线在此同样适用：本功能没有任何「替用户按回车」的路径。

## 7. 文案

| 键（base/zh/en 同步补） | zh |
| --- | --- |
| `sentinel_card_count` | %d 个软件包可升级 |
| `sentinel_card_more` | 等 %d 个 |
| `sentinel_card_asof` | 截至 %s |
| `sentinel_card_empty` | 添加后自动跟踪软件包更新 |
| `sentinel_card_stale` | 打开应用刷新 |
| `sentinel_notify_title` | %d 个软件包有新版本 |
| `sentinel_notify_body` | %s 等 %d 个包待升级，点按查看升级队列 |
| `sentinel_notify_action_upgrade` | 全部升级 |
| `sentinel_notify_action_later` | 稍后 |
| `sentinel_setting_row` | 更新哨兵 |
| `sentinel_setting_frequency` | 提醒频率 |
| `sentinel_freq_off` / `_daily` / `_weekly` | 关 / 每天 / 每周 |
| `sentinel_setting_auth` | 桌面通知 |
| `sentinel_setting_auth_on` | 已开启 |

## 8. 改动清单

| 文件 | 改动 |
| --- | --- |
| `products/pc_acl/src/main/module.json5` | `extensionAbilities`：FormExtensionAbility（type `form`，metadata `ohos.extension.form` → `$profile:form_config`）+ P1 时的 WorkSchedulerExtensionAbility；无新增 requestPermissions |
| `products/pc_acl/src/main/resources/base/profile/form_config.json` | 单卡片定义：`isDynamic: true`、`supportDimensions` 按探针 Q1、P2 时 `updateEnabled` + `updateDuration` |
| `products/pc_acl/src/main/ets/sentinel/BrewFormAbility.ets` | FormExtensionAbility：`onAddForm` 登记 + 首渲染、`onRemoveForm` 注销、`onFormEvent`（点击路由）、`onAcquireFormState` |
| `products/pc_acl/src/main/ets/sentinel/BrewSentinelCard.ets` | 卡片页：纯声明式读 formBindingData，零命令调用（G5 扫描对象） |
| `products/pc_acl/src/main/ets/sentinel/BrewWorkSchedulerExtension.ets` | （P1 档）周期回调 → `pushAll()` 读盘上快照 → 写卡 + 按频控通知 |
| `features/brewcommon/src/main/ets/service/BrewSentinelService.ets` | 哨兵服务：登记表、快照派生、`pushToForms()`、通知构造与去重、频控；被 pc_acl 与 `BrewInstalledLoader` 刷新完成回调两侧调用 |
| `features/brewcommon/src/main/ets/constant/SentinelConstants.ets` | notificationId、preferences 键、档位常量、24h 陈旧阈值 |
| `features/brewcommon/src/main/ets/service/BrewInstalledLoader.ets` | 仅加一行：refresh 成功后回调哨兵比对（依赖方向：Loader 不 import 哨兵，用回调注入，避免环） |
| `features/mine/src/main/ets/view/MineSettingView.ets` + `SentinelSettingView.ets` | 「更新哨兵」行 + 频率/授权子页 |
| `features/{brewcommon,mine}/src/main/resources/{base,zh_CN,en_US}/element/string.json` | §7 文案 |
| `hmosword-build/brew-sentinel/audit_no_brew_in_touchpoints.mjs` | G5 审计脚本（node，无依赖） |
| `docs/knowledge/2026-11-22-sentinel-probe.md` | G11 探针结论（真机执行后补） |

## 9. 验证

1. **探针（真机，用户执行）**：按 §3.2 四问逐项记录，落 knowledge 文档；据此定档（G11/G12）。
2. **静态**：`node hmosword-build/brew-sentinel/audit_no_brew_in_touchpoints.mjs` 全绿（G5）。
3. **构建**：`devecocli build --product default` / `--product pc_normal` 均 `BUILD SUCCESSFUL`、ERROR 0（G10）。
4. **真机（用户执行）**：G1–G9、G13 逐条过。关键路径：装一个已知有新版本的包（如 jq）→ 打开本机包管理刷新 → 观察通知与卡片 → 点「全部升级」验证只跳转不执行 → 拒授权重装验证 G8 → 移除/重添加卡片验证 G13。
5. **日志**：`[sentinel]` 前缀覆盖：登记/注销、哈希比对、频控判定、通知发布、卡片推送结果。

## 10. 风险与未决

- **保活/触发边界是唯一硬门槛**（decisions.md 预判成立）：work scheduler 与卡片定时刷新在 PC 的真实行为完全交给 Stage 0；探针否定 P1/P2 时 P3 保底可用，功能不空转但「主动说话」只剩应用存活期——这条边界要在探针文档里如实写清，不夸大哨兵的常驻性。
- 通知在 PC（2in1）通知中心的呈现样式与按钮支持度未实测——G3/G4 验证时如发现按钮不可用，回退方案是「点击通知整体直达升级队列」，频控与去重语义不变。
- **实施排期**：D 线（AI companion）尚在并行推进，与 H 同文件（`MineSettingView`、`mine/string.json`×3、`router_map.json`）。H 的实现开工定在 D 线合入 dev **之后**，避免 tldr 线经历过的并行编辑返工重演；spec 评审不受影响。
- 卡片刷新配额（系统对 `updateForm` 的频率限制）未知——超限时接受失败并降频，不做重试风暴。
- Q4 结论（扩展进程执行能力）只记录不依赖，供 F 磁盘管家、G/J 护栏线复用。
