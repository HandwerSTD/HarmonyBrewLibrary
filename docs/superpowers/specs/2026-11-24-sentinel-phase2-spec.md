# 更新哨兵二期（通知移除 + 桌面卡片 iOS 风格重设计）· 设计

> 日期：2026-11-24。状态：待评审。
> 动因：用户反馈（m00001）——「通知提醒功能移除，这东西没意义」；同时要求桌面卡片按
> Apple iOS 小组件的审美标准重做，提供 2\*2 / 2\*4 / 4\*4 三种规格。
> （用户口中的「更新守卫」即本仓 H 线「更新哨兵」，本文沿用仓内命名。）
> 前序：[`2026-11-22-sentinel-update-spec.md`](2026-11-22-sentinel-update-spec.md)（一期，已实现）；
> 探针文档：[`../../knowledge/2026-11-22-sentinel-probe.md`](../../knowledge/2026-11-22-sentinel-probe.md)（二期扩展见 §10）。
> 范围：`products/pc_acl`（卡片页重写、form_config、PcAbility 瘦身）；`features/brewcommon`
> （哨兵服务删通知链路、镜像契约 v2）；`features/mine`（哨兵设置入口整体下线）；
> `features/pcui`、`common`（dismiss 消费链路清理）；`hmosword-build`（审计脚本规则扩展）。

---

## 1. 目标与成功判据

两条主线：**N = 通知移除**，**W = 卡片重设计**。

| # | 判据 | 可观测证据 |
| --- | --- | --- |
| N1 | 触达点零通知残留：sentinel 目录与 `BrewSentinelService` 中无任何 `notificationManager` / `wantAgent` / `requestEnableNotification` 引用 | grep 计数 0；审计脚本新规则全绿 |
| N2 | 哨兵设置入口整体下线：`SentinelSettingView` 删除，router_map / PageEnum / `MineSettingView` 行 / mine 文案 ×3 locale 全清 | `grep -i sentinel features/mine` = 0 |
| N3 | 卡片点击路由链路原样保留：postCardAction router → `PcAbility.captureSentinelWant`（route 分支）→ `MineHomeView` 消费 → `MinePackagesView` | 真机 |
| N4 | 通知相关旧 preferences 键（last_set / last_notify_date / reminded_set / notify_refused / frequency）不再被任何代码读写；盘上残留无害，不做迁移清理 | grep；真机不崩 |
| N5 | `evaluateAndPush(context)` 签名收敛：`mayRequestAuthorization` 参数删除；宿主/扩展两条路径职责只剩「写镜像 + 推卡」 | 代码 diff |
| W1 | form_config：`supportDimensions: ["2*2","2*4","4*4"]`、`defaultDimension: "2*2"`、`resizable: true`（探针 Q1 二轮按真机可见性回改，G12 机制沿用） | form_config.json + 真机 |
| W2 | 三规格三布局：添加器里三种规格可见且各自渲染 Small / Wide / Large 布局，不串版 | 真机 |
| W3 | 四态齐备：引导（无快照）/ 零更新（count=0，绿 ✓ + 「全部为最新版本」，不再显示「0 个软件包可升级」）/ 陈旧（>24h 降显）/ 正常 | 真机 |
| W4 | 内容容量：2\*2 = top3 包名单行；2\*4 = 前 3 行版本对（`旧 → 新`）；4\*4 = 前 6 行版本对 + 「等 N-6 个」 | 真机 |
| W5 | 深浅色自适应：`colorMode: auto`；全部颜色走 sys token 或 `sentinel_accent` / `sentinel_success` 双色资源 | 真机切深色 |
| W6 | 零执行红线不变：触达点零命令符号，审计全绿（含 §8 新增的通知残留规则） | `node hmosword-build/brew-sentinel/audit_no_brew_in_touchpoints.mjs` |
| W7 | 数据诚实口径保留：「截至 HH:mm」常驻；快照 >24h 降显「打开应用刷新」，不假装实时 | 真机 |
| W8 | 双 product 构建通过：pc_normal 不含哨兵代码路径 | `devecocli build --product default` 与 `--product pc_normal`，ERROR 0 |
| W9 | 镜像契约 v2 向后兼容：旧格式镜像（有 topNames 无 items）按 miss 处理 → 引导态，不崩；宿主一次评估后自愈 | 真机；`[sentinel]` 日志 |
| W10 | 拖拽切换规格（resize）后按新规格正确渲染；系统回调不可用则降级 `resizable: false`（用户删卡重加） | 真机（探针 Q1+） |

### 一期 G 门处置表

| 一期门 | 处置 |
| --- | --- |
| G1 卡片可添加 / G2 点卡片直达 | 保留，升级为 W1–W3 / N3 |
| G3 通知到达 / G4 通知按钮 / G6 集合去重 / G7 频控 / G8 未授权降级 | **废止**（通知功能移除）；G4 的「不执行命令」红线并入 W6 |
| G5 触达点零执行审计 | 保留（W6），规则扩展见 §8 |
| G9 数据诚实 / G10 双 product / G13 移除重添加 | 保留（W7 / W8 / W9） |
| G11/G12 探针落盘与档位回改 | 保留；探针文档二期扩展（§10） |

---

## 2. 现状盘点

### 2.1 通知链路触达点（全部待删）

| 位置 | 内容 |
| --- | --- |
| `features/brewcommon/src/main/ets/service/BrewSentinelService.ets` | `evaluateAndPush` 的通知分支（stale/count/频控/集合哈希/授权五道闸）、`publishAsync`、`dismissCurrent`、`agentInfo`、`setKeyOf`、`frequencyOf/getFrequency/setFrequency`、`frequencyAllows`、`dateStamp`、`ERR_NOTIFICATION_REFUSED`、`WANT_REQUEST_*`；`notificationManager` / `wantAgent` import |
| `features/mine/src/main/ets/view/SentinelSettingView.ets` | 整文件（频控行 + 授权行两行的子页） |
| `features/mine/src/main/ets/view/MineSettingView.ets:62-78` | 「更新哨兵」行（`if (isLocalPackagesEnabled())` 块内仅此一项，整块删） |
| `features/mine/src/main/resources/base/profile/router_map.json` | `SentinelSettingView` 路由条目 |
| `common/src/main/ets/model/PageEnum.ets` | `SENTINEL_SETTING_VIEW` 枚举项 |
| `common/src/main/ets/constant/CommonEnums.ets` | `StorageKey.SENTINEL_PENDING_DISMISS`（`SENTINEL_PENDING_ROUTE` 保留） |
| `features/pcui/src/main/ets/view/PcMainPage.ets` | `sentinelPendingDismiss` StorageProp + `consumeSentinelDismiss` + `BrewSentinelService` import（route 消费保留） |
| `products/pc_acl/src/main/ets/pcability/PcAbility.ets` | `SENTINEL_DISMISS_VALUE` 常量 + `captureSentinelWant` 的 dismiss 分支（route 分支保留） |
| `features/brewcommon/src/main/ets/constant/SentinelConstants.ets` | `SENTINEL_KEY_LAST_SET` / `_LAST_NOTIFY_DATE` / `_REMINDED_SET` / `_NOTIFY_REFUSED` / `_FREQUENCY`、`SENTINEL_NOTIFICATION_ID`、`SENTINEL_FREQUENCY_*`、`SENTINEL_WEEKLY_MIN_MS`、`SENTINEL_WANT_KEY_DISMISS` |
| 文案 | pc_acl ×3 locale：`sentinel_notify_*` 5 键；mine ×3 locale：`sentinel_setting_row` / `_frequency` / `sentinel_freq_off/_daily/_weekly` / `sentinel_setting_auth` / `_on` / `_go` 9 键 |
| `hmosword-build/brew-sentinel/audit_no_brew_in_touchpoints.mjs` | 描述与用例仍提「发通知」（§8 更新） |

### 2.2 保留清单（通知移除不动的部分）

- **卡片链路全量**：form_config、`BrewFormAbility`、`BrewSentinelCard`、`SentinelBootstrap`（P3 恒开）、`BrewWorkSchedulerExtension`（P1 休眠，价值从「保活推卡 + 通知」收敛为「保活推卡」）、GSKV 镜像、formId 登记表。
- **路由链路**：`SENTINEL_WANT_KEY_ROUTE`、`PcAbility` 的 route 分支、`StorageKey.SENTINEL_PENDING_ROUTE`、`MineHomeView` / `PcMainPage` 的 route 消费。
- `selfBundleName()`（workScheduler 登记仍用）、`sentinel_form_name` / `sentinel_form_desc` 文案。
- 三档调度语义不变（P1 休眠 / P2 开 / P3 恒开），所有触发源收敛到「只推卡」。

---

## 3. 通知移除设计

### 3.1 移除的安全性

通知与卡片共享同一数据源（`BrewInstalledLoader` 盘上快照 + GSKV 镜像），通知只是快照的**第二消费者**。删通知不动数据链路的一行代码；P1/P2/P3 的触发面原样保留，只是 `evaluateAndPush` 里不再有通知分支。一期「brew 第一次主动说话」的叙事由卡片独自承担——卡片常驻桌面，本身就是持续在说；系统通知是重复喊话，与 PC（2in1）桌面形态重叠，移除合理。

### 3.2 `evaluateAndPush` 瘦身后

```
BrewInstalledLoader（既有，不变）
        │ 快照变化回调（SentinelBootstrap 订阅，P3）
        ▼
BrewSentinelService.evaluateAndPush(context)
        ├─ 宿主路径（有快照）：写镜像 v2 → pushToForms
        └─ 扩展路径（P1/P2，无快照）：读镜像命中 → pushToForms；miss → 不动
（通知分支整体删除：频控 / 集合哈希去重 / 授权 / publish / dismiss 全删）
```

- stale 判定保留但只服务卡片降显（stale 仍推卡，W7）。
- 扩展路径「镜像命中只推卡、miss 不动卡片」的既有语义不变（不把引导态盖到宿主数据上）。

---

## 4. 卡片重设计 · 设计语言（iOS 小组件审美转译）

五条原则，全部可追溯到 iOS 小组件的既有语言：

1. **数据即主角**：待升级数是唯一的第一层级，56–64fp Bold 大数字压阵；其余元素全部退后。iOS 小组件从不让装饰抢过数据。
2. **单一强调色**：中性底 + 一支 iOS system orange（更新语义）；绿色只出现在「全部为最新版本」的零更新态。不搞多彩堆砌。
3. **字阶即层级**：大（hero）/ 中（说明、包名）/ 小（版本号、元信息）三级字阶靠字号字重区分，不靠颜色加码。
4. **柔和几何**：大圆角由系统裁剪，卡片内部只用 hairline 分隔与 8vp 圆角小徽章；无描边、无投影、无分割线框。
5. **诚实元信息**：「截至 HH:mm」常驻页脚，数据从不假装实时——与一期 G9 同一口径。

### 4.1 设计令牌

| 令牌 | 值（浅色 / 深色） | 用途 |
| --- | --- | --- |
| 卡片底 | sys `comp_background_primary`（白 / 近黑，iOS 白 与 #1C1C1E 的对应物） | 根背景；圆角由系统裁剪，卡片页不自绘外框 |
| `sentinel_accent` | `#FF9500` / `#FF9F0A` | iOS system orange：徽章底、hero 数字（count>0）、新版本号 |
| `sentinel_success` | `#34C759` / `#30D158` | iOS system green：零更新态对勾徽章 |
| hero 字阶 | 2\*2 / 2\*4：56fp Bold；4\*4：64fp Bold | 待升级数；count>0 用 accent，count=0 走零更新态 |
| title 字阶 | 16fp Medium，`font_secondary` | 「更新哨兵」标题（4\*4 头部） |
| body 字阶 | 14fp Regular，`font_secondary` | 「个软件包可升级」说明 |
| list 字阶 | 包名 14fp Medium `font_primary`；旧版本 12fp Regular `font_tertiary`；箭头 12fp `font_tertiary`；新版本 12fp Medium `sentinel_accent` | 版本对行 |
| caption 字阶 | 11fp Regular，`font_tertiary` | 「截至 HH:mm」「等 N 个」「点按查看升级队列」 |
| 图标徽章 | 32×32vp，圆角 8vp，`sentinel_accent` 底 + 白色 ↑ 字形 16fp | 身份标识（iOS 小组件左上角 app 图标的对应物） |
| 间距 | 外边距 20vp；hero 区上留白 ≥12vp；列表行高 36vp、行间距 8vp；hairline 用 sys `comp_divider` | 全规格统一 |

实现备注：徽章用 `Text('↑')` + 背景色 + 圆角实现（卡片能力子集内最稳）；`linearGradient` / `SymbolGlyph` 在 ArkTS 卡片的支持度未验，探针 Q1+ 顺带验证，可用则升级为渐变底，不可用保持纯色（纯色本身就是 iOS 语言）。

---

## 5. 三规格布局（ASCII Art）

> 块字符数字仅为示意（实际渲染为系统字体 Bold）；徽章内 `░▒▓` 示意渐变/纯色底。

### 5.1 2\*2（Small）· 正常态

```
╭────────────────────────────────────────────────╮
│                                                │
│  ╭────────╮                                    │
│  │ ░▒↑▓▒░ │                                    │
│  ╰────────╯                                    │
│                                                │
│      ██  ██████████                            │
│     ███          ██                            │
│      ██  ████████   个软件包可升级             │
│      ██  ██                                    │
│    ████ ██████████                             │
│                                                │
│  jq、ripgrep、wget 等 9 个                     │
│                                                │
│  截至 14:32                                    │
│                                                │
╰────────────────────────────────────────────────╯
```

| 标注 | 元素 | 规格 |
| --- | --- | --- |
| ① | 图标徽章 | 32×32vp 圆角 8vp，accent 底白 ↑，左上角 |
| ② | hero 数字（12） | 56fp Bold，`sentinel_accent`，左对齐，视觉重心 |
| ③ | 说明 | 「个软件包可升级」14fp `font_secondary`，与 hero 垂直居中对齐 |
| ④ | top3 包名 | 「jq、ripgrep、wget 等 9 个」13fp；包名 `font_secondary`，「等 N 个」`font_tertiary`，单行截断 |
| ⑤ | 截至 | 「截至 14:32」11fp `font_tertiary`，底部对齐 |

### 5.2 2\*2 · 零更新态与引导态

```
╭────────────────────────────────────────────────╮   ╭────────────────────────────────────────────────╮
│                                                │   │                                                │
│  ╭────────╮                                    │   │  ╭────────╮                                    │
│  │   ✓    │                                    │   │  │ ░▒↑▓▒░ │                                    │
│  ╰────────╯                                    │   │  ╰────────╯                                    │
│                                                │   │                                                │
│  全部为最新版本                                │   │  添加后自动跟踪软件包更新                      │
│                                                │   │                                                │
│  截至 14:32                                    │   │  打开应用完成首次读取                          │
│                                                │   │                                                │
╰────────────────────────────────────────────────╯   ╰────────────────────────────────────────────────╯
     （零更新：success 绿 ✓ 徽章 + 16fp 文案）                    （引导态：一期文案沿用）
```

### 5.3 2\*4（Wide）· 正常态

```
╭──────────────────────────────────────────────────────────────╮
│                                                              │
│  ╭────────╮              ┊ jq           1.7.1 → 1.8.0        │
│  │ ░▒↑▓▒░ │              ┊ ripgrep     14.1.0 → 14.2.0       │
│  ╰────────╯              ┊ wget        1.24.0 → 1.25.0       │
│                          ┊                                   │
│      ██  ██████████      ┊                                   │
│     ███          ██      ┊                                   │
│      ██  ████████        ┊                                   │
│      ██  ██              ┊ ────────────────────────────      │
│    ████ ██████████       ┊ 等 9 个，点按查看升级队列         │
│  12 个软件包可升级       ┊                                   │
│  截至 14:32              ┊                                   │
│                                                              │
╰──────────────────────────────────────────────────────────────╯
```

| 标注 | 元素 | 规格 |
| --- | --- | --- |
| ① | 左栏 | 徽章 + hero（56fp Bold accent）+ 说明 + 截至，垂直排布，占宽约 40% |
| ② | 竖向 hairline | sys `comp_divider`，1vp，两栏之间（iOS medium 小组件的双栏语言） |
| ③ | 版本对行 ×3 | 包名 14fp Medium `font_primary` 左对齐；旧版本 12fp `font_tertiary` 右对齐；`→` `font_tertiary`；新版本 12fp Medium `sentinel_accent` 右对齐；行高 36vp |
| ④ | 提示条 | hairline 之上留白，「等 9 个，点按查看升级队列」11fp `font_tertiary`，右栏底部 |

### 5.4 4\*4（Large）· 正常态

```
╭────────────────────────────────────────────────────╮
│                                                    │
│  ╭────────╮    更新哨兵                截至 14:32  │
│  │ ░▒↑▓▒░ │                                        │
│  ╰────────╯                                        │
│                                                    │
│      ██  ██████████                                │
│     ███          ██                                │
│      ██  ████████   个软件包可升级                 │
│      ██  ██                                        │
│    ████ ██████████                                 │
│                                                    │
│  ────────────────────────────────────────────      │
│  jq               1.7.1  →  1.8.0                  │
│  ripgrep         14.1.0  →  14.2.0                 │
│  wget            1.24.0  →  1.25.0                 │
│  node           22.11.0  →  23.3.0                 │
│  gh              2.63.0  →  2.64.0                 │
│  ffmpeg           7.1.0  →  8.0.0                  │
│                                                    │
│  等 6 个，点按查看升级队列                         │
│                                                    │
╰────────────────────────────────────────────────────╯
```

| 标注 | 元素 | 规格 |
| --- | --- | --- |
| ① | 头部 | 徽章 + 「更新哨兵」16fp Medium `font_secondary`；「截至 14:32」11fp `font_tertiary` 右对齐（iOS large 小组件头部语言） |
| ② | hero（64fp Bold accent）+ 说明 | 与 2\*2 同构，字号升到 64fp |
| ③ | hairline | hero 区与列表之间，sys `comp_divider` |
| ④ | 版本对行 ×6 | 同 2\*4 行规格；超出 6 条不渲染，由 ⑤ 收口 |
| ⑤ | 页脚 | 「等 6 个，点按查看升级队列」11fp `font_tertiary`，底部对齐 |

### 5.5 状态 × 规格矩阵

| 状态（判据） | 2\*2 | 2\*4 | 4\*4 |
| --- | --- | --- | --- |
| 引导（无快照且无镜像） | 徽章 + 引导文案（§5.2 右图） | 同左，单栏居中 | 徽章 + 标题 + 引导文案 |
| 零更新（count=0） | 绿 ✓ 徽章 + 「全部为最新版本」（§5.2 左图） | 同左 | ✓ 徽章 + 文案 + 截至 |
| 陈旧（>24h） | 数字保留；「截至」替换为「打开应用刷新」 | 同左；列表保留 | 列表保留；页脚替换为降显文案 |
| 正常 | §5.1 | §5.3 | §5.4 |

---

## 6. 数据契约与规格感知

### 6.1 镜像 v2（GSKV `sentinel_last_card`）

```json
{
  "readAt": 1764234000000,
  "count": 12,
  "items": [
    { "name": "jq", "version": "1.7.1", "latestVersion": "1.8.0" },
    { "name": "ripgrep", "version": "14.1.0", "latestVersion": "14.2.0" }
  ]
}
```

- `items` 上限 6（新常量 `SENTINEL_CARD_ITEMS_LIMIT`），字段取自 `BrewInstalledPackage` 的 `name` / `version` / `latestVersion`（已存在于快照，零新增命令）。
- `topNames` 字段废弃：卡片侧从 `items[0..2]` 派生 top3 单行（`SENTINEL_TOP_NAMES_LIMIT` 保留）。
- `loadBase` 防御同步升级：`readAt>0`、`count>=0`、`items` 为数组且每项 `name` 为 string；**旧格式（有 topNames 无 items）按 miss 处理 → 引导态**（W9），宿主下次评估写 v2 后自愈。

### 6.2 登记表 v2（GSKV `sentinel_form_ids`）

`["formId1","formId2"]` → `[{"id":"formId1","dimension":"2*2"},{"id":"formId2","4*4"...}]`（`{"id","dimension"}` 对象数组）。旧格式防御解析为全 `2*2`。`onFormAdded(context, formId, dimension)` 增加 dimension 入参；`onRemoveForm` 按 id 注销不变。

### 6.3 规格感知（dimension）双通道

- **主通道（binding 数据）**：`onAddForm` 从 `want.parameters[formInfo.FormParam.DIMENSION_KEY]` 取规格，经 `normalizeDimension()` 归一（实测值格式可能是 `"2*2"` 串或数值枚举，探针 Q1+ 确认，未知值兜底 `2*2`），写进登记表并随 `cardData` 下发新键 `sentinelDimension`；`onUpdateForm` 的 `wantParams` 若携带 dimension 则先更新登记再推全量。
- **兜底通道（onAreaChange）**：卡片页根组件按实际渲染宽度阈值切换布局——binding 通道覆盖不了 resize 不回调的边界。探针 Q1+ 实测后保留单通道并记录（G12 同款机制）。
- 两通道都不可用（resize 后既无回调又无 onAreaChange）：`resizable: false` 降级，用户删卡重加（W10）。

### 6.4 FormBindingData 键（卡片页 LocalStorageProp 一一对应）

`sentinelFormId` / `sentinelDimension`（新）/ `sentinelHasSnapshot` / `sentinelCount` / `sentinelItems`（新，JSON 串）/ `sentinelAsOfText` / `sentinelStale`；`sentinelTopNames` 键删除。卡片页按 `sentinelDimension` 条件渲染 Small / Wide / Large 三个 `@Builder`，四态在每个布局内各自成立。

---

## 7. 交互与文案

- **整卡可点**：沿用一期 postCardAction router 事件直达 `MinePackagesView`（N3）；卡片内不放任何按钮（卡片能力子集与一期口径一致）。「点按查看升级队列」页脚承担可点暗示。
- **零执行红线**：卡片页、FormAbility、服务、回调不 import 任何命令生成/执行符号（W6，审计脚本把关）。

文案变更（base / zh_CN / en_US 三 locale 同步）：

| 键 | 处置 | zh | en |
| --- | --- | --- | --- |
| `sentinel_card_count` / `_more` / `_asof` / `_empty` / `_stale` | 保留 | （一期原文） | （一期原文） |
| `sentinel_card_zero` | 新增 | 全部为最新版本 | All Packages Up to Date |
| `sentinel_card_hint` | 新增 | 点按查看升级队列 | Tap to view upgrade queue |
| `sentinel_notify_*` ×5（pc_acl） | 删除 | — | — |
| `sentinel_setting_*` / `sentinel_freq_*` ×9（mine） | 删除 | — | — |

---

## 8. 改动清单

| 文件 | 改动 |
| --- | --- |
| `products/pc_acl/src/main/resources/base/profile/form_config.json` | `supportDimensions: ["2*2","2*4","4*4"]`、`defaultDimension: "2*2"`、`resizable: true`（探针后回改，W1） |
| `products/pc_acl/src/main/ets/sentinel/pages/BrewSentinelCard.ets` | 重写：三规格布局 + 四态 + `sentinelDimension`/`sentinelItems` 消费 + onAreaChange 兜底（§5–§6） |
| `products/pc_acl/src/main/ets/sentinel/BrewFormAbility.ets` | `onAddForm` 读 `DIMENSION_KEY` 传 dimension；`onUpdateForm` 透传 wantParams；注释去通知化 |
| `products/pc_acl/src/main/ets/sentinel/SentinelBootstrap.ets` | `evaluateAndPush(context)` 签名跟进；注释去通知化（P1/P3 语义不变） |
| `products/pc_acl/src/main/ets/sentinel/BrewWorkSchedulerExtension.ets` | 注释去通知化（P1 休眠不变） |
| `products/pc_acl/src/main/ets/pcability/PcAbility.ets` | `captureSentinelWant` 删 dismiss 分支与 `SENTINEL_DISMISS_VALUE` |
| `features/brewcommon/src/main/ets/service/BrewSentinelService.ets` | 删通知全链路（§2.1 第一行）；登记表 v2；镜像 v2；`cardData` 增 dimension/items；`evaluateAndPush` 签名收敛 |
| `features/brewcommon/src/main/ets/constant/SentinelConstants.ets` | 删 §2.1 所列通知常量；增 `SENTINEL_DATA_DIMENSION` / `SENTINEL_DATA_ITEMS` / `SENTINEL_CARD_ITEMS_LIMIT` / `SENTINEL_DIMENSION_*` |
| `features/brewcommon/Index.ets` | 导出清单同步（`SENTINEL_FREQUENCY_*` 等不再导出） |
| `features/mine/src/main/ets/view/SentinelSettingView.ets` | **删除文件** |
| `features/mine/src/main/ets/view/MineSettingView.ets` | 删哨兵行整块（62-78） |
| `features/mine/src/main/resources/base/profile/router_map.json` | 删 `SentinelSettingView` 条目 |
| `common/src/main/ets/model/PageEnum.ets` | 删 `SENTINEL_SETTING_VIEW` |
| `common/src/main/ets/constant/CommonEnums.ets` | 删 `SENTINEL_PENDING_DISMISS` |
| `features/pcui/src/main/ets/view/PcMainPage.ets` | 删 dismiss 消费与 `BrewSentinelService` import |
| `products/pc_acl/src/main/resources/{base,zh_CN,en_US}/element/string.json` | 删 `sentinel_notify_*`；增 `sentinel_card_zero` / `sentinel_card_hint` |
| `products/pc_acl/src/main/resources/base(element)/color.json` + `dark(element)/color.json` | 增 `sentinel_accent` / `sentinel_success`（§4.1 双色值） |
| `features/mine/src/main/resources/{base,zh_CN,en_US}/element/string.json` | 删 `sentinel_setting_*` / `sentinel_freq_*` 9 键 |
| `hmosword-build/brew-sentinel/audit_no_brew_in_touchpoints.mjs` | 新规则：触达点出现 `notificationManager` / `wantAgent` 即 FAIL（通知已移除，残留即漂移）；描述与正负用例同步更新 |
| `docs/knowledge/2026-11-22-sentinel-probe.md` | G3/G4/G6/G7/G8 验证行标「二期废止」；Q1 扩展见 §10 |

---

## 9. 验证

1. **静态**：`node hmosword-build/brew-sentinel/audit_no_brew_in_touchpoints.mjs` 全绿（含通知残留新规则）；`grep -i "notificationManager\|wantAgent" products/pc_acl/src/main/ets/sentinel features/brewcommon/src/main/ets/service/BrewSentinelService.ets` = 0（N1）；`grep -i sentinel features/mine` = 0（N2）。
2. **构建**：`devecocli build --product default` / `--product pc_normal` 均 `BUILD SUCCESSFUL`、ERROR 0（W8）。
3. **真机（用户执行）**：W1–W5、W7、W10、N3 逐条过。关键路径：三规格各添加一张 → 验证三布局不串版 → 装一个已知有新版本的包（如 jq）→ 应用内刷新 → 三张卡同步更新且版本对正确 → 拖拽 2\*2 到 4\*4 验证 resize → 全部升级后验证零更新态 → 快照放旧验证降显 → 移除/重添加验证 W9。
4. **日志**：`[sentinel]` 前缀保留登记/注销/推卡/镜像评估；频控与通知类日志（`notify skip` / `notify published`）随代码删除。

---

## 10. 风险与未决

- **4\*4 在 2in1 桌面的可见性未验**：一期探针 Q1 候选只有 1\*2 / 2\*2 / 2\*4。`supportDimensions` 先按需求声明三规格，探针 Q1 二轮实测回改（不可见则裁剪，但三套布局代码保留——规格是配置，布局是资产）。
- **resize 回调边界未知**：拖拽换规格后系统是否重放 `onAddForm` / 是否在 `onUpdateForm` wantParams 带 dimension / 卡片页 `onAreaChange` 是否可用，全部交给探针 Q1+；三通道都不成立则 `resizable: false` 降级（W10 阶梯）。
- **卡片能力子集**：`linearGradient` / `SymbolGlyph` / `onAreaChange` 在 ArkTS 卡片的支持度未验——`Text` + 纯色徽章是兜底底线，探针顺带记录，可用则升级渐变。
- **formBindingData 体积**：items 6 条 JSON ≈ 400B，距卡片数据上限（约 2KB 量级）余量充足；若探针发现更紧的上限，先降 `SENTINEL_CARD_ITEMS_LIMIT`。
- **镜像 v2 是破坏性变更**：升级安装后首次卡片刷新会短暂回到引导态（旧镜像按 miss），宿主一次前台评估即自愈——可接受，不做格式迁移。
- **并行编辑**：与 D 线（AI companion）同文件（`MineSettingView`、mine `string.json` ×3、`router_map.json`）。开工前确认 D 线合入状态（一期同款风险，tldr 线的返工教训）。
- 探针文档同步：Q1 扩展项（4\*4 可见性、resize 回调、`DIMENSION_KEY` 值格式、onAreaChange 支持度、三规格实际渲染宽高——宽度阈值标定用）随二期实现一并落 `2026-11-22-sentinel-probe.md`。
