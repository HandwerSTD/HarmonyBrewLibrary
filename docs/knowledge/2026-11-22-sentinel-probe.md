# 更新哨兵 · Stage 0 真机探针（待真机填写）

> 2026-11-22 建档（G11 文档骨架，随 H 更新哨兵实现一并交付）。实施档位当前为**默认值**：
> P1 休眠 / P2 开 / P3 恒开。真机按本文逐项探测后回填结论表，再按 §4 指引回改常量与配置（G12）。
> 探测对象：pc_acl product 的 debug build（`devecocli build --product default` 后装真机）。
> 探针规矩见 [`2026-11-21-probe-inside-app.md`](2026-11-21-probe-inside-app.md)：实测落盘，不在终端里猜。

## 0. 探测准备

1. 构建：`devecocli build --product default`（pc_acl 是唯一带哨兵代码路径的 product；pc_normal 应构建通过且无任何哨兵路径，见 G10）。
2. 安装并启动应用，先在「我的 - 本机包」完成一次成功读取（确保盘上快照 `brew_installed_snapshot` 存在）。
3. 桌面长按 → 添加卡片「更新哨兵」（2*2）。
4. 日志过滤关键字：`[sentinel]`。哨兵日志覆盖五类事件（spec §9.5）：登记/注销（`form registered` / `form unregistered`）、哈希比对（`evaluate outdated=… `）、频控判定（`notify skip: …`）、通知发布（`notify published`）、卡片推送（`push ok` / `push failed`）。

## 1. §3.2 四问

### Q1 · 2in1 桌面支持哪些卡片规格？

**探测步骤**：

1. form_config 当前只声明 `supportDimensions: ["2*2"]`。先确认 2*2 能否正常添加到桌面并渲染（G1）。
2. 临时把 `products/pc_acl/src/main/resources/base/profile/form_config.json` 的 `supportDimensions` 扩为 `["1*2","2*2","2*4"]`（`defaultDimension` 保持 `2*2`）重新构建安装，逐个添加记录：哪些规格在添加器里可见、渲染是否正常、添加后 `onAddForm` 是否回调。
3. 记录 `resizable: true` 在 2in1 上是否允许拖拽切换规格。

**结论（待真机填写）**：

| 规格 | 添加器可见 | 渲染正常 | onAddForm 回调 | 备注 |
| --- | --- | --- | --- | --- |
| 1*2 | 待填 | 待填 | 待填 | |
| 2*2 | 待填 | 待填 | 待填 | |
| 2*4 | 待填 | 待填 | 待填 | |

**回改**：最终支持的规格集合写回 `supportDimensions`（探针 Q1 结论）。若 2*2 不可用，改用可见的最小规格，并同步调整 `BrewSentinelCard.ets` 的排版。

### Q2 · `updateEnabled + updateDuration` 在 PC 桌面的真实触发边界？

**探测步骤**：

1. 当前配置：`updateEnabled: true`、`updateDuration: 1`（30 分钟）、`scheduledUpdateTime: "09:00"`。注意官方文档口径：**updateDuration 与 scheduledUpdateTime 同时配置时定时刷新（updateDuration）优先**，scheduledUpdateTime 只在 updateDuration=0 时生效——若探针发现 PC 上两者行为不同，以实测为准回填。
2. 让应用完全退出（最近任务划掉，确认 `PcAbility.onDestroy` 已打日志），放置 ≥ 2 个刷新周期，记录每次 `onUpdateForm` 的触发时刻（`[sentinel] onUpdateForm formId=…`）。
3. 变量实测：息屏 / 合盖休眠 / 长闲置（>1h）下是否还触发；应用存活（后台挂起）时是否触发。
4. 记录系统给出的真实下限：把 `updateDuration` 依次试 1（30min）/ 2（1h），对比触发间隔。

**结论（待真机填写）**：

| 场景 | 是否触发 | 实际间隔 | 备注 |
| --- | --- | --- | --- |
| 应用退出 + 正常使用 | 待填 | 待填 | |
| 息屏/休眠 | 待填 | 待填 | |
| 长闲置 | 待填 | 待填 | |

**回改**：若边界可用（≥1h 有触发），P2 维持 `updateEnabled: true`；若触发不可靠，把 `updateEnabled` 置 false（P2 降档，只剩 P3），并在此记录。

### Q3 · work scheduler 在应用退出后的触发行为？

**探测步骤**：

1. 把 `features/brewcommon/src/main/ets/constant/SentinelConstants.ets` 的 `SENTINEL_WORK_SCHEDULER_ENABLED` 临时翻成 `true`，重建安装。启动一次应用（`SentinelBootstrap.init` 会 `startWork`，日志 `work scheduled id=…`）。
2. 完全退出应用，记录 `onWorkStart`（`[sentinel] onWorkStart workId=…`）的触发时刻与间隔（当前 `repeatCycleTime = 2h`，系统可能拉高到自己的档位）。
3. 重启设备，确认 `isPersisted: true` 的任务是否恢复（重启后是否还能收到 `onWorkStart`）。
4. 记录冻结/省电策略对触发的影响。

**结论（待真机填写）**：

| 项目 | 实测 | 备注 |
| --- | --- | --- |
| 应用退出后是否触发 | 待填 | |
| 实际循环间隔 | 待填 | |
| 重启后恢复（isPersisted） | 待填 | |
| 冻结/省电影响 | 待填 | |

**回改**：触发边界可用 → `SENTINEL_WORK_SCHEDULER_ENABLED = true`（P1 启用）；不可用 → 保持 false（P1 休眠），并把实测间隔写进 `SENTINEL_WORK_INTERVAL_MS` 注释。

### Q4 · 扩展进程里 ShellUtils.available() 与 brew 路径探测？

**探测步骤**：

1. 临时探针（照 `2026-11-21-probe-inside-app.md` 的临时类做法）在 `BrewFormAbility.onUpdateForm` 里调一次 `ShellUtils.available()` 与 `BrewCli.brewPath()`，结果写进沙箱文件后 `hdc shell` 捞出。
2. 探完**立即删探针代码**。本结论只记录，**不作为哨兵依赖**（spec §3.1：v1 在扩展进程也不跑命令；结论供 F/G/J 线复用）。

**结论（待真机填写）**：

| 项目 | FormExtensionAbility 进程 | WorkScheduler 进程 |
| --- | --- | --- |
| ShellUtils.available() | 待填 | 待填 |
| brew 路径探测 | 待填 | 待填 |

## 2. 实施中发现的新问题（Q5，补充进本轮探针）

**扩展进程读不到盘上快照 → GSKV 镜像方案**：`BrewInstalledLoader.snapshot()` 先过能力开关注入项（AppStorage 按进程隔离，扩展进程不存在），盘上快照所在 store（`HMosWorldStoreWithNet`，XML 模式）官方明确**不支持多进程并发**（preferences 文档「XML模式约束限制」）。因此宿主每次评估把展示三字段（count / topNames / readAt）以 JSON 写进 GSKV `sentinel_last_card`（`SentinelCardBase` 镜像），扩展进程读镜像渲染：

- 宿主路径（P3，有快照）：写镜像 → 推卡 → 通知路径；
- 扩展路径（P1/P2 定时触发，无快照）：读镜像命中 → **只推卡**（`evaluate(extension)` 日志），不通知；miss → 不动卡片（不把引导态盖到宿主数据上）；
- `onAddForm` 首渲染 / G13 重添加：读镜像命中 → 立即按宿主上次写入的数据 + 「截至 HH:mm」渲染；miss → 引导态；
- 镜像随时间自然变陈旧：`Date.now() - readAt > 24h` 时卡片降显「打开应用刷新」（G9 诚实口径）。

**要探的**：

1. 扩展进程定时刷新（Q2/Q3 的触发源）后卡片**用镜像数据更新**——观察卡片数字变化与「截至 HH:mm」是否等于宿主上次读取时刻，日志看 `[sentinel] evaluate(extension) count=…` 与 `push ok formId=…`；
2. 扩展进程 `preferences.getPreferencesSync(getApplicationContext())` 打开 GSKV store 是否成功（`[sentinel] store opened gskv=true`；失败会有 `open store failed` warn，此时镜像链路整体失效，需回填结论）；
3. 镜像陈旧降显：把宿主快照时间人为放旧（或等 24h）后触发扩展刷新，卡片是否降显「打开应用刷新」；
4. G13：移除卡片重添加，首渲染是否直接显示镜像数据（不再先闪引导态）。

## 3. 功能验证清单（G 门 · 真机）

| 判据 | 操作 | 预期 | 结果 |
| --- | --- | --- | --- |
| G1 | 添加卡片 | 显示数量/前 3 包名/截至 HH:mm；无快照显示引导态 | 待填 |
| G2 | 点卡片 | 直达「我的-待更新」（MinePackagesView, mode=outdated） | 待填 |
| G3 | 装一个已知有新版本的包（如 jq）→ 应用内刷新 | 收到通知：数量+top 包名+两个按钮 | 待填 |
| G4 | 点「全部升级」/「稍后」 | 前者直达队列、后者撤通知；两条路径都不执行命令（审计脚本把关） | 待填 |
| G6 | 不改集合重复触发评估 | 同集合只通知一次（`notify skip: same set`） | 待填 |
| G7 | 频控切「关」 | 通知停、卡片照常更新 | 待填 |
| G8 | 拒绝通知授权 | 不崩、不反复弹窗；设置页「去开启」可再引导 | 待填 |
| G9 | 快照 >24h（改系统时间或等） | 卡片降显「打开应用刷新」 | 待填 |
| G13 | 移除卡片再重添加 | 移除后快照仍归应用；重添加立即按镜像数据渲染（宿主上次写入 + 截至 HH:mm） | 待填 |

## 4. 档位回改指引（G12）

| 探针结论 | 回改位置 | 改动 |
| --- | --- | --- |
| Q1 支持的规格集合 | `products/pc_acl/src/main/resources/base/profile/form_config.json` | `supportDimensions` / `defaultDimension` |
| Q2 卡片定时可用 | `form_config.json` | 维持 `updateEnabled: true`；`updateDuration` 按实测下限调整 |
| Q2 卡片定时不可用 | `form_config.json` | `updateEnabled: false`（P2 降档） |
| Q3 work scheduler 可用 | `features/brewcommon/…/SentinelConstants.ets` | `SENTINEL_WORK_SCHEDULER_ENABLED = true`；`SENTINEL_WORK_INTERVAL_MS` 按实测 |
| Q3 不可用 | 同上 | 保持 `false`（默认） |
| Q5 扩展进程 GSKV 失败 | `features/brewcommon/…/BrewSentinelService.ets` | 按 `openStore` 的 warn 日志定位；若 GSKV 打不开需评估 XML 降级的跨进程风险 |

改完档位后，本表「当前取值」必须与代码一致（G12 的验收就是 diff 一致性），并在此补一行「2026-XX-XX 已按 Q1/Q2/Q3 结论回改」。
