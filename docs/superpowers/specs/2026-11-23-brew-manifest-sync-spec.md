# W′ 工具清单分布式同步 spec（BrewManifestSync）

> 日期：2026-11-23。状态：**已立项**（需求方当日裁定：W′ 以分布式同步实现，取代本日早些
> 时候的 v0 文件流方案；`round4.md` 与 `rejected.md` 已同步修订）。
> 范围：分布式键值数据库（distributedKVStore）承载的工具清单与 AI 模型配置跨设备同步、
> 侧边栏新增入口 + 半模态 Sheet、设置常驻页、批量安装队列、pc_normal 隐藏测试能力。
> 叙事定位：主线四「工具链跟着人走」——多台鸿蒙 PC 组网互见工具清单，换机一键复制、
> 双机互见跟装（`relatedwork.md` 主线四；brainstorm 轮次定义见 `round5.md` §2）。
>
> 相关文档：
> - `docs/spec/2026-11-21-brainstorm/round5.md` §2（W′ 收窄口径：只同步主动安装）
> - `docs/spec/2026-11-21-brainstorm/rejected.md` §1 第 14 条修订、§2 第 3 条重写（本 spec 的裁定记录）
> - `docs/superpowers/specs/2026-10-04-brew-installed-packages-spec.md`（installedOnRequest 口径）
> - `docs/superpowers/specs/2026-10-05-brew-detail-action-bar-spec.md`（pc_normal 行为闸 G10 模式）
> - worktree `feature/brew-manifest-sync`（`D:\HarmonyOS\Projects\Local\Worktrees\brew-sync-spec`）上
>   2026-11-23 的文件流版 spec：**机制已废弃**（本 spec 取代），其批量安装队列、导入预览
>   diff UX、loading 分档、文案表设计被本 spec 回收。
> - 参考工程 UX：CloudPurePlay `blocking-loading-ux-design.md`（loading 分档 T0–T3 规范）。

---

## 1. 目标与成功判据

| # | 判据 | 可观测证据 |
|---|---|---|
| G1 | 组网（同账号、可信设备）的两台 2in1 上，A 机新装一个包后，B 机侧边栏底部出现「清单同步」入口 | B 机日志 `[sync] pending new=1 from=<deviceId>`；侧边栏 Shell 入口上方出现入口行 |
| G2 | 入口**仅在存在未消费的新增时显示**；点开 Sheet 即视为已消费，入口消失；再有远端新增则重新出现 | 入口可见性 = `pendingNewCount > 0`；`onWillAppear` 触发 ack（G6）；日志 `[sync] ack device=<id> at=<updatedAt>` |
| G3 | 同步库为**加密 + 最高安全等级 S4**：`encrypt: true`、`securityLevel: SecurityLevel.S4` | 代码常量断言；日志 `[sync] kv open store=brew_manifest_sync encrypt=true sl=S4 ok=true` |
| G4 | AI 模型配置（provider / baseUrl / model）跨设备同步；**API Key 永不进同步库**（每设备各自持有 Asset Store Key） | A 机改配置 → B 机设置页刷新出新值；同步库内 `ai/config` 值无 key 字段；日志 `[sync] ai config applied provider=… model=…` |
| G5 | 清单口径 = **只同步主动安装**（formula 取 installedOnRequest，cask 视为主动），含各包 tap；依赖包不同步 | 复用 `BrewInstalledParser` 投影（§2）；日志 `[sync] publish device=<id> packages=N taps=M ms=N` |
| G6 | 已读语义同命令 Sheet 的 `resultViewed`：Sheet 打开即 ack 当前各设备 manifest 的 `updatedAt` | ack 落本地 preferences `brew_sync_state`（不进同步库）；入口随 ack 消失 |
| G7 | 常驻界面 =「我的 → 设置 → 工具清单同步」二级页（全功能、无新增也可见） | `MineSettingView` 新行 push `BrewManifestSyncPage`；页内可见设备卡 / AI 配置同步状态 |
| G8 | 新增包可勾选并**批量安装**：队列逐条 `brew install`、失败域隔离、进度续看（复用命令 Sheet） | `install_queue.json` 落盘；逐条日志 `[queue] start/ok/fail token=…`；中途关 Sheet 重开续看 |
| G9 | pc_normal（无执行通道）：同步查看、AI 配置应用照常；**安装动作不出现**（同 G10 行为闸） | `BrewCli.isEnabled() === false` 时无勾选框与批量安装条 |
| G10 | 隐藏测试能力：**仅 pc_normal**，设置-关于页 app 图标 4 连点 → 向同步库写入 3 个测试包（`python@3.12`、`deepseek-harness`、`reasonix`，来源设备名「分布式测试」） | 4 次点击后 Toast + 日志 `[sync] easter egg written packages=3`；侧边栏入口随即出现（本地写读链路，无需组网） |
| G11 | 权限 `ohos.permission.DISTRIBUTED_DATASYNC` 双 product 声明，常驻页首次打开时动态申请；拒绝不崩溃，视图内引导授权 | module.json5 声明 + 日志 `[sync] permission grant=true`；拒绝态显示引导行 |
| G12 | 双 product 构建绿 | `devecocli build --product default`、`devecocli build --product pc_normal` 均无错误 |
| G13 | 关键链路全部打点 | §3.6 打点表 |

范围外（明确不做）：
- **云端账号同步**——数据不出设备信任圈，无服务端、无用户协议负担（`rejected.md` §2 第 3 条重写后的边界）。
- **依赖包同步**、全量 Brewfile——主动清单才是「我的工具链」（round5 §2 口径）。
- **后台自动安装**——跟装必须经过 Sheet 勾选确认，同步只负责「看见」。
- B′ 工作台的粘贴 / 拖拽导入路径与三色画布（B′② 的另两条输入路径，另立 spec）。
- 跨端任务接续 / 应用接续 / 分布式流转（`rejected.md` §1 第 14 条：否决理由已修订，但流转本体仍否决）。

---

## 2. 现状（落点 × 已有事实）

| 位置 | 现状 |
|---|---|
| `features/brewcommon/src/main/ets/service/BrewInstalledLoader.ets` | 静态类；`snapshot()` / `loadSets()` / `subscribe(fn)` / `invalidate()`；写命令结束自动失效刷新；盘上缓存 installed 集合。**清单发布的数据源** |
| `features/brewcommon/src/main/ets/util/BrewInstalledParser.ets:78-86` | formula 取 newest keg 的 `installed_on_request === true`；cask 投影无此字段按主动安装处理（caskOf 恒 true）。**G5 口径直接复用** |
| `features/brewcommon/src/main/ets/model/BrewModels.ets:269-283` | `BrewInstalledPackage { name; fullName; …; installedOnRequest; …; kind }`——token 取 `name`，tap 从 `fullName` 剥前缀派生 |
| `features/brewcommon/src/main/ets/service/BrewCommandRunner.ets` | 单命令执行（单飞 BUSY / interrupt / 超时）；`openSheet()/closeSheet()/markViewed()` 管理 Sheet 生命周期。**队列的执行底座，但当前无队列概念** |
| `features/brewcommon/src/main/ets/model/BrewCommandModels.ets` | `BrewCommandState` @Observed（含 `sheetShown`、`resultViewed`）——同步服务状态类同构仿写 |
| `features/brewcommon/src/main/ets/component/BrewCommandSheet.ets` | 命令执行 Sheet 组件；宿主 `PcMainPage`。**BrewManifestSyncView 的样板** |
| `features/brewcommon/src/main/ets/service/AiSettingsStore.ets:38` | BYOK 存储：Key 只进 Asset Store（`AI_ASSET_ALIAS_API_KEY`）；provider/baseUrl/model 存 GSKV 偏好（store `AI_PREFS_STORE`，key `AI_PREFS_KEY_CONFIG`）；`saveConfig`/`loadConfig`/`snapshot`。**AI 同步的本地真源** |
| `features/brewcommon/src/main/ets/model/AiTypes.ets:47` | `AiProviderConfig { provider; baseUrl; model }`——同步的恰好是不含密钥的三个字段 |
| `features/pcui/src/main/ets/component/CustomSideBar.ets:45,157` | `shellEntryVisible()` = 命令状态离开 IDLE 即常显；`if` 块 = Divider + ShellEntryBuilder 压在 `Blank()` 之后。**同步入口插在它上面，同构** |
| `features/pcui/src/main/ets/view/PcMainPage.ets:240` | 命令 Sheet 的 bindSheet 绑在 `HdsNavDestination` 上。**同一节点多绑 bindSheet 不可靠**（官方 FAQ：多半模态应绑不同组件）——同步 Sheet 绑在内层 `HdsSideBar` 节点 |
| `features/mine/src/main/ets/view/MineSettingView.ets` | 导航型列表（`HmosListItem` + pushPath）；已有 `isLocalPackagesEnabled()` 条目模式（sentinel 行）。**常驻入口行的落点** |
| `features/mine/src/main/resources/base/profile/router_map.json` | mine 页面路由注册表（`MinePackagesView` / `AboutView` 等）。新页在此登记 |
| `features/mine/src/main/ets/view/AboutView.ets:67` | `Image(this.drawableDescriptor)` app 图标，`draggable(false)`——**4 连点彩蛋目标** |
| `products/pc_normal/src/main/ets/pcability/PcAbility.ets:16` | `BREW_CLI_ENABLED=false` 注入（pc_acl=true）。**彩蛋的 product 判据**（取反） |
| `products/pc_acl/src/main/module.json5:71`、`products/pc_normal/src/main/module.json5:39` | requestPermissions 现无 `DISTRIBUTED_DATASYNC`，需双 product 补声明 |
| 工程依赖 | 全工程**零** distributedKVStore / deviceManager 先例；无任何分布式代码——本 spec 是第一块 |

---

## 3. 数据流与数据模型

### 3.1 同步库（唯一分布式 KV 库）

```
import { distributedKVStore } from '@kit.ArkData';
import { deviceManager } from '@kit.DeviceManagerKit';

storeId  = 'brew_manifest_sync'          // 两端一致；不一致 getKVStore 报 15100002
options  = {
  createIfMissing: true,
  encrypt: true,                          // 数据库加密（G3）
  securityLevel: distributedKVStore.SecurityLevel.S4,   // 最高等级（G3）
  kvStoreType: distributedKVStore.KVStoreType.SINGLE_VERSION,
  autoSync: true,                         // put/delete 后自动同步（辅助路径）
  backup: true,
}
```

- **SINGLE_VERSION 而非 DEVICE_COLLABORATION**：清单 Key 按设备前缀隔离（每设备只写自己的
  Key，天然无同 Key 冲突）；`ai/config` 是唯一多端共写 Key，按 KV 层「最后写入生效」
  （LWW）解决——SINGLE_VERSION 的既定语义，不自建冲突策略。
- **一个库装两类数据**（`device:*/manifest` + `ai/config`）：S4/加密对全库生效，开一个库
  代价最小（app 同时最多 16 库的限制从此不构成压力）。
- **S4 风险即接受**：数据安全标签不得高于对端设备安全等级，否则**静默不同步**（不报错）。
  需求方明确裁定 S4；PC/2in1 一般为 SL4。真机核对步骤见 §9、风险见 §10。

### 3.2 Key 设计与 Value Schema

| Key | 写者 | Value（JSON，< 4MB；清单实际 KB 级） |
|---|---|---|
| `device:<deviceId>/manifest` | 该设备（仅 `BrewCli.isEnabled()` 时发布） | `BrewSyncManifestDoc` |
| `ai/config` | 任意设备（保存 AI 设置时） | `BrewSyncAiConfigDoc` |

```jsonc
// BrewSyncManifestDoc（schema 字段做向前校验：非 1 拒收）
{
  "schema": 1,
  "deviceId": "…",                  // deviceManager.getLocalDeviceSync().deviceId
  "deviceName": "Handwer-PC",       // 同源；设备自报，读取端直接展示
  "updatedAt": 1763892345678,       // 发布时刻 epoch ms——「新增判定」的时间轴
  "packages": [
    { "token": "wget",   "kind": "formula", "tap": "" },
    { "token": "python@3.12", "kind": "formula", "tap": "" },
    { "token": "gh",     "kind": "formula", "tap": "user/repo" }
  ],
  "taps": ["user/repo"]             // packages 的 tap 去重集（安装即 `brew install tap/token`，tap 自动克隆）
}

// BrewSyncAiConfigDoc
{ "schema": 1, "updatedAt": 1763892345678,
  "provider": "deepseek",           // AI_PROVIDER_DEEPSEEK | AI_PROVIDER_CUSTOM
  "baseUrl": "https://api.deepseek.com",
  "model": "deepseek-chat" }        // 与 AiProviderConfig 三字段一一对应；无 Key 字段（G4）
```

- 包投影（G5）：`BrewInstalledLoader.snapshot().sets.installed` 过滤 `installedOnRequest === true`
  → `token = name`、`kind`、`tap = fullName 含 '/' ? 前缀 : ''`；`brew info --json=v2 --installed`
  的既有口径零改动。
- **ack 状态不进同步库**（进库会被同步污染对端）：落本地 GSKV 偏好 store `brew_sync_state`，
  key `ack`，value JSON `{ "<deviceId>": <ackUpdatedAt> }`。

### 3.3 发布链（本机清单 → KV）

```
BrewManifestSyncService.init(context)            // PcAbility.onCreate（双 product）
  → createKVManager / getKVStore / 订阅（§3.4）/ 首次 sync()
  → 若 BrewCli.isEnabled()：BrewInstalledLoader.subscribe(publishListener)

publishListener(snapshot 变化)：
  manifest = 投影(snapshot)                        // §3.2 包投影
  old      = kvStore.get(`device:<myId>/manifest`)
  if (manifest.packages 集合 ≠ old.packages 集合)：
    put(`device:<myId>/manifest`, {…, updatedAt: now})     // autoSync 辅助推送
    显式 sync(deviceIds, PUSH_PULL)（§3.5）
  else：跳过（防 updatedAt 漂移——集合不变不写）
```

- 发布闸：`BrewCli.isEnabled() === false`（pc_normal）**永不发布**——pc_normal 的角色是
  接收端 + 彩蛋写入端，避免无 brew 设备发布空清单噪音。
- 触发面：service init（读缓存快照即比对一次）+ `BrewInstalledLoader.subscribe`（每次
  装载/写命令后失效刷新都会走一遍，集合不变则零写入）。

### 3.4 接收链（远端变更 → 新增 → 入口）

```
kvStore.on('dataChange', SUBSCRIBE_TYPE_REMOTE, listener)
  → service.refresh()
  → 遍历 kvStore 前缀 `device:` 的全部条目（getEntries）
  → 对每个远端 manifest：updatedAt > ack[deviceId] ？ → pendingNew +=（包 − 本机已装集合）
  → 本机 manifest（deviceId === self）不计入 pendingNew
  → 更新 BrewManifestSyncState（@Observed）：devices[] / pendingNew[] / pendingNewCount
  → 侧边栏入口可见性 = pendingNewCount > 0（G2）

冷启动无事件：service.init() 里同样跑一次 refresh()（读盘上的同步库数据即可判新增，
不依赖运行中收到通知）。
```

- 「新增」的完整判定 = **远端 manifest 有未 ack 的更新** ∧ **包含本机未安装的包**；
  Sheet 新装区显示后者（互见句 + 勾选安装都面向它），设备卡展开显示前者全部清单（只读）。
- 本机已装集合：`BrewInstalledLoader.snapshot()`（null 时按空集处理，pc_normal 恒空集）。

### 3.5 同步触发时机（autoSync 之外的四次显式 sync）

| 时机 | 模式 | 说明 |
|---|---|---|
| `PcAbility.onCreate` → service.init | PUSH_PULL | 冷启动对齐 |
| 同步视图打开（Sheet `onWillAppear` / 常驻页 `aboutToAppear`） | PUSH_PULL | 进门先同步 |
| 「立即同步」按钮 | PUSH_PULL | 手动兜底（含授权后首同步） |
| 本机清单 put 之后 | PUSH_ONLY | 发布即推 |

- `deviceIds` = `deviceManager.getAvailableDeviceListSync().map(d => d.deviceId)`（可信设备表；
  空表 = 未组网，sync 记日志 no-op）。
- `kvStore.on('syncComplete')`：核对各设备同步结果，更新 `lastSyncAt` / 失败计数（失败
  有限次数指数退避，最多 3 次——对齐论坛增量对账建议：本地先落库、同步结果单独跟踪）。

### 3.6 AI 模型配置同步（G4）

```
本地改：AiSettingVM.save()
  → AiSettingsStore.saveConfig(config)               // 现状不动（prefs 是渲染真源）
  → BrewManifestSyncService.publishAiConfig(config)  // put('ai/config', {…, updatedAt: now}) + sync(PUSH)

远端来：dataChange 里 Key === 'ai/config' 的条目
  → AiSettingsStore.saveConfig(远端三字段)           // 只改 prefs，绝不回写 KV（防回环）
  → service 通知已注册的 AiSettingVM.refresh()      （VM aboutToAppear 注册 / aboutToDisappear 注销）
  → AiClient 下次请求读 loadConfig() 自然生效
```

- 冲突：两台设备并发改 → KV 层 LWW；本地 prefs 只是渲染缓存，接受「最后写入生效」。
- `autoExplain` 开关与 **API Key 均不同步**：Key 是每设备各自的 Asset Store 私有物
  （BYOK 哲学，G1 无折中档——同步库里出现密钥等于把密钥广播到信任圈全部设备）。

### 3.7 批量安装队列（G8，回收 v1 文件流 spec 的设计）

`features/brewcommon/src/main/ets/service/BrewInstallQueue.ets`（新单例）：

- **落盘为数据而非内存态**：`filesDir/brew_state/install_queue.json`
  `[{ token, kind, tap, status: PENDING|RUNNING|DONE|FAILED, queuedAt, finishedAt }]`。
  不属 CacheAdmin 管辖（brew-cache-ownership.md 的归属口径）；这同时兑现
  `rejected.md` §2 第 2 条「手机遥控」留的门：未来任何前端触发同一队列零架构改动。
- 入队：Sheet 勾选 → 「安装所选 (N)」→ `enqueue(items)` → 落盘 → kick。
- 驱动：事件驱动复用 `BrewCommandRunner`——queue subscribe 命令终态：终态时置当前条
  DONE/FAILED、落盘、kick 下一条（RUNNER 单飞语义不变；BUSY 时不抢，等当前命令自然结束）。
- 命令拼装：`BrewCommandGenerator.installArgs(kind, token, tap)` + `isSafeName` 安全闸
  （不合法 token 入队前即拒，Toast 提示）。
- 失败域隔离：单条失败不停队，条目置 FAILED 供单条重试；用户可清空队列。
- 进度续看：条目状态渲染在同步视图 + 命令 Sheet（执行明细照旧由命令 Sheet 承载——
  宏观（队列条目）与微观（命令输出）分工，同 v1 spec）。

### 3.8 隐藏测试能力（G10，仅 pc_normal）

```
AboutView 图标 onClick（draggable(false) 的 app 图标）：
  if (BREW_CLI_ENABLED === true) return          // pc_acl 点了无反应——彩蛋只在 pc_normal
  计数器 +1；相邻两次间隔 > 800ms 则清零
  第 4 次：
    put(`device:dz-test/manifest`, {
      schema: 1, deviceId: 'dz-test', deviceName: '分布式测试', updatedAt: now,
      packages: [
        { token: 'python@3.12',      kind: 'formula', tap: '' },
        { token: 'deepseek-harness', kind: 'formula', tap: '' },
        { token: 'reasonix',         kind: 'formula', tap: '' } ],
      taps: [] })
    service.refresh()                            // 本地写读链路：无 dataChange 事件，主动刷
    Toast「已写入 3 个分布式测试包」；计数器清零（可重复触发）
```

- 为什么 put 后 refresh 能看到：可见性来自**读路径**（getEntries + ack diff），不依赖
  REMOTE 事件——彩蛋在单机无组网时也能完整验证入口出现 → Sheet 展示 → 3 包只读
  （pc_normal 无安装按钮，G9）的整条 UX。
- 彩蛋写的是**伪设备 Key**（`dz-test`），不污染本机 manifest；`ack` 后入口消失，重触发
  （updatedAt 更新）再出现。

### 3.9 打点表（G13）

| 行 | 时机 |
|---|---|
| `[sync] kv open store=brew_manifest_sync encrypt=true sl=S4 ok=<bool>` | init |
| `[sync] publish device=<id> packages=<N> taps=<M> ms=<N>` | 本机清单 put |
| `[sync] remote change keys=<N>` | dataChange REMOTE |
| `[sync] pending new=<N> from=<deviceId>` | refresh 判定出新增 |
| `[sync] ack device=<id> at=<updatedAt>` | Sheet 打开 ack |
| `[sync] sync complete devices=<N> failed=<N> ms=<N>` | syncComplete |
| `[sync] ai config applied provider=<p> model=<m>` | 远端 AI 配置应用 |
| `[sync] easter egg written packages=3` | 彩蛋触发 |
| `[queue] start/ok/fail token=<t> remain=<N>` | 队列条目流转 |
| `[sync] permission grant=<bool>` | 动态授权结果 |

---

## 4. 交互与视觉

### 4.1 侧边栏入口（Shell 上方，有新增才显示）

`CustomSideBar.ets`——完整仿 `ShellEntryBuilder` 同构，插在 Shell 块**上面**：

```
Blank()
if (this.syncEntryVisible()) {                    // pendingNewCount > 0（G2）
  Divider()
  this.SyncEntryBuilder()                          // Row：SymbolGlyph(arrow_2_circlepath) + 「清单同步」 + 尾部 +N
}
if (this.shellEntryVisible()) { Divider()  this.ShellEntryBuilder() }   // 现状不动
```

- 入口行尺寸 / 圆角 / hover / 高度全部复用 Shell 行样式（`side_bar_height`、
  `corner_radius_level4`、`interactive_hover`）；尾部 `+N` 用 `interactive_active` 色
  （Body_L 同行字号），是「新增未消费」的唯一视觉信号——不引入红点徽章（侧边栏
  底部安静区域，克制）。
- **常驻性对仗**：Shell 入口「执行过一次就常显」；同步入口「有新增才显示、看完即隐」
  ——两个底部入口一个记过程、一个记增量，互不打扰。`@State syncState =
  BrewManifestSyncService.getInstance().getState()`（与命令状态同款的 @Observed 单例模式）。
- 点击：`BrewManifestSyncService.getInstance().openSheet()`（与 Shell 入口
  `openSheet()` 同构——入口只改状态，不各自弹提示）。

### 4.2 同步 Sheet（BrewManifestSyncView 的形态一）

宿主：`PcMainPage.ets` 的 `HdsSideBar` 子节点上绑第二个 bindSheet（命令 Sheet 绑在
`HdsNavDestination`——**同一节点双 bindSheet 不可靠**，官方 FAQ 的多半模态口径是
「不同组件各绑一个」）。材质 / 尺寸口径与命令 Sheet 完全一致：
`MaterialUtil.getMaterialOptions<SheetOptions>` + `CustomImmersiveStyle.ULTRA_THICK`、
XL 高度比 `SHEET_HEIGHT_RATIO_XL` / 宽 `SHEET_WIDTH_XL`、SM 底部 BOTTOM 其余 CENTER、
`showClose: false`（视图内自带关闭）。

```
BrewManifestSyncSheet 内容（自上而下）：
① 标题行「工具清单同步」+ 关闭按钮（sheetMode 才渲染；页模式标题由 NavDestination 出）
② 互见句（pendingNew > 0 时）：
   「你的 <设备名> 新装了 <N> 个包」——round5 双机互见场景的原句落地；
   N = 0 时此区不渲染（空态见 ⑤）
③ 新装列表：勾选框（仅 pc_acl）+ token（等宽字体）+ kind chip + tap 副文本 + 来源设备名
   行右侧状态 chip：待装 / 已入队 / 安装中 / 已完成 / 失败（重试）
④ 批量安装条（pc_acl 且勾选数 > 0）：「安装所选 (N)」强调按钮 → enqueue → 队列跑起来
   后按钮变「查看进度」拉起命令 Sheet（微观明细归命令 Sheet）
⑤ 设备区：每设备一张卡（设备名 / 更新时间 / 包数 / 本机标记），点开展开该设备完整
   清单（只读行）；pc_normal 也渲染（接收端视角）
⑥ AI 配置同步卡：当前 provider / model + 上次同步时间 + 「去设置」链接（push AiSettingView）
⑦ 底部行：「立即同步」（执行中转圈）+ 「上次同步 14:32」；未授权时替换为授权引导行
```

- **ack 时机**：Sheet `onWillAppear` → `markViewed()`（ack 各远端 manifest 当前 updatedAt，
  G6）——与命令 Sheet `onWillAppear → markViewed()` 同一生命周期钩子、同一语义。
- Sheet 关闭登记在 `onDisappear`（官方约束：onWillDisappear 不允许改状态变量）——
  与命令 Sheet 现有写法一致。

### 4.3 常驻页（形态二，G7）

`features/mine/src/main/ets/view/BrewManifestSyncPage.ets`（薄壳）：
`NavDestination`（标题「工具清单同步」）+ 内容 = **同一个** `BrewManifestSyncView`
（`sheetMode: false`：不渲染标题行、无关闭按钮、底部动作区常驻）。

- 路由：`router_map.json` 登记 `BrewManifestSyncPage`；`MineSettingView` 列表在
  「AI 设置」行下方新增行「工具清单同步」（`sys.symbol.arrow_2_circlepath`，
  **不挂** `isLocalPackagesEnabled()`——同步查看与 AI 配置应用在 pc_normal 也是真功能，
  只有安装动作受 G9 闸；行常显 = 常驻语义）。
- `PageEnum` 加 `BREW_MANIFEST_SYNC_VIEW`。
- 首次打开触发动态授权（G11）：`aboutToAppear` → 若未授权 →
  `requestPermissionsFromUser(['ohos.permission.DISTRIBUTED_DATASYNC'])` →
  授权后自动跑一次 sync + refresh。

### 4.4 权限申请（G11）

- 双 product `module.json5` 声明 `ohos.permission.DISTRIBUTED_DATASYNC`（reason string
  `distributed_datasync_reason`）。**本地 put / get / 彩蛋不依赖该权限**（只影响跨设备
  sync）；因此 pc_normal 未授权时彩蛋链路依然完整可用。
- 申请时机锚在**常驻页首次打开**（用户带着意图进功能时弹，不在冷启动打扰）；
  拒绝 → 视图底部授权引导行（「需要授权才能与组网设备同步」+ 去设置按钮），
  「立即同步」时再按需提示。

### 4.5 loading 分档（对齐 CloudPurePlay 规范）

同步视图的数据全在内存（service state），渲染零等待（T0 静默）；「立即同步」按钮
执行中按钮内转圈（T1 页内 busy，禁用防重入）；sync 慢 / 设备不可达不是错误态而是
`lastSyncAt` 与失败计数的行内表达——**全程无阻塞遮罩**（T3 不出现）。

### 4.6 双 product 行为矩阵

| 能力 | pc_acl | pc_normal |
|---|---|---|
| 清单发布（put 本机 manifest） | ✅ | ❌（无 brew，永不发布） |
| 接收 / 新增入口 / Sheet 查看 | ✅ | ✅ |
| AI 配置同步（双向） | ✅ | ✅ |
| 勾选 + 批量安装 | ✅ | ❌（G9：不渲染勾选框与安装条） |
| 关于图标 4 连点彩蛋 | ❌（点了无反应） | ✅（G10） |
| 常驻入口行（设置） | ✅ | ✅ |

---

## 5. 失败态分级

| # | 失败 | 现象 | 处置 | 文案（zh） |
|---|---|---|---|---|
| F1 | KV 库打开失败（15100002 选项不匹配 / 文件损坏） | init 日志 ok=false | 服务降级：入口不出现、常驻页显示失败行；损坏走系统自动重建 | 「同步库不可用，重启应用重试」 |
| F2 | put 失败 | 发布链 catch | 记日志，下次 snapshot 变化重试（发布幂等） | 不打扰 |
| F3 | sync 失败 / 设备不可达 | syncComplete failed>0 | 行内表达（「上次同步失败 · 14:32」+ 重试按钮）；指数退避 ≤3 次 | 见文案表 |
| F4 | 权限拒绝 | 未授权 | 常驻页授权引导行 + 按需提示（G11） | 「需要授权才能与组网设备同步」 |
| F5 | S4 静默不同步（对端设备等级 < S4） | 现象 = 永远收不到远端数据 | 无法在应用内检测——§9 真机核对步骤前置；风险登记 §10 | —（对用户不可见） |
| F6 | 远端数据 schema 不符（未来版本） | 解析拒收该 manifest | 跳过该设备条目 + 日志；其它设备不受影响 | 该设备卡显示「清单版本过新，请升级应用」 |
| F7 | 队列条目安装失败 | FAILED chip | 单条重试按钮；不停队（G8 隔离） | 「安装失败，点击重试」 |
| F8 | deviceManager 不可用（getLocalDeviceSync 抛） | 发布链 deviceId 缺失 | 本机不发布（只做接收端）+ 日志；不崩溃 | 不打扰 |

---

## 6. 安全与合规

- **库级**：`encrypt: true` + `SecurityLevel.S4`——组网传输与落盘均处最高标签；数据不出
  设备信任圈（无云端、零服务端性格不变）。
- **密钥边界（G4，红线）**：API Key 只存在于各设备 Asset Store（`AiSettingsStore` 既有
  纪律：不进偏好、不进日志、不进缓存文件——本 spec 增加第四条：**不进同步库**）。
  同步库 Value schema 里没有 Key 字段；`publishAiConfig` 入参类型即 `AiProviderConfig`
  （类型上装不下 Key，与 `saveConfig` 同款保险）。
- **数据最小化**：只同步主动安装包名 + tap（KB 级），不含版本、安装时间、使用痕迹。
- **日志纪律**：打点表全部字段不含 Key 值、不列完整清单（计数 + deviceId 级）。
- **彩蛋**：pc_normal 专属 + 4 连点隐匿触发，不进任何菜单与文档可见入口；写入的伪设备
  manifest 与真实链路同构，不产生越权数据。

---

## 7. 文案表（zh）

| key | 文案 |
|---|---|
| tab_manifest_sync | 清单同步 |
| sync_sheet_title | 工具清单同步 |
| sync_mutual_seen | 你的{device}新装了{count}个包 |
| sync_empty_no_pending | 设备清单已是最新 |
| sync_empty_no_devices | 暂无组网设备——在系统设置中添加可信设备后，这里会显示它们的工具清单 |
| sync_install_selected | 安装所选 ({count}) |
| sync_view_progress | 查看进度 |
| sync_sync_now | 立即同步 |
| sync_last_at | 上次同步 {time} |
| sync_last_failed | 上次同步失败 · {time} |
| sync_permission_row | 需要授权才能与组网设备同步 |
| sync_permission_go | 去授权 |
| sync_ai_config_card | AI 模型配置已随清单同步 |
| sync_go_ai_setting | 去设置 |
| sync_device_self | 本机 |
| sync_pkg_kind_formula / _cask | 命令行工具 / 图形应用 |
| sync_pkg_status_pending/_queued/_running/_done/_failed | 待装 / 已入队 / 安装中 / 已完成 / 失败 |
| sync_retry | 重试 |
| sync_kv_unavailable | 同步库不可用，重启应用重试 |
| sync_schema_too_new | 清单版本过新，请升级应用 |
| sync_queue_fail_toast | 安装失败，点击重试 |
| sync_easter_egg_toast | 已写入 3 个分布式测试包 |
| distributed_datasync_reason | 用于在您的可信设备间同步工具清单与模型配置 |
| mine_setting_manifest_sync | 工具清单同步 |

---

## 8. 改动清单

| 模块 | 文件 | 动作 |
|---|---|---|
| brewcommon | `src/main/ets/model/BrewSyncModels.ets` | 新增：`BrewSyncPackage` / `BrewSyncManifestDoc` / `BrewSyncAiConfigDoc` / `BrewSyncDeviceView` / `BrewSyncNewItem` + schema 校验 |
| brewcommon | `src/main/ets/service/BrewManifestSyncService.ets` | 新增：单例；KV open / 订阅 / refresh / 发布 / ack / syncNow / openSheet / closeSheet / markViewed / `BrewManifestSyncState` @Observed / AI 配置发布与应用 / 彩蛋写入 API |
| brewcommon | `src/main/ets/service/BrewInstallQueue.ets` | 新增：§3.7 队列（落盘 + 事件驱动） |
| brewcommon | `src/main/ets/component/BrewManifestSyncView.ets` | 新增：§4.2/§4.3 双形态视图组件（`sheetMode` prop） |
| brewcommon | `src/main/ets/service/AiSettingsStore.ets` | 微改：暴露供 service 应用的入口（saveConfig 复用即可，预计零改动或仅加注释） |
| brewcommon | `Index.ets` | 导出上述类型 / 服务 / 组件 |
| pcui | `src/main/ets/component/CustomSideBar.ets` | 修改：§4.1 同步入口（Shell 上方） |
| pcui | `src/main/ets/view/PcMainPage.ets` | 修改：`HdsSideBar` 节点绑定同步 Sheet（§4.2） |
| mine | `src/main/ets/view/BrewManifestSyncPage.ets` | 新增：常驻页薄壳（§4.3） |
| mine | `src/main/resources/base/profile/router_map.json` | 登记 `BrewManifestSyncPage` |
| mine | `src/main/ets/view/MineSettingView.ets` | 修改：新增「工具清单同步」行（常显，§4.3） |
| mine | `src/main/ets/view/AboutView.ets` | 修改：图标 4 连点彩蛋（§3.8，pc_normal 闸） |
| mine | `src/main/ets/viewmodel/AiSettingVM.ets` | 修改：save 后 `publishAiConfig`；注册远端应用回调刷新 |
| common | `src/main/ets/model/PageEnum.ets` | 加 `BREW_MANIFEST_SYNC_VIEW` |
| common | `src/main/ets/constant/StorageKey.ets` | 预留 `SYNC_*` 键（如需要） |
| products | `pc_acl/src/main/module.json5`、`pc_normal/src/main/module.json5` | 补 `DISTRIBUTED_DATASYNC` 声明 + reason string |
| products | `pc_acl/…/pcability/PcAbility.ets`、`pc_normal/…/pcability/PcAbility.ets` | onCreate 尾部 `BrewManifestSyncService.getInstance().init(this.context)` |
| 资源 | `features/*/resources/base/element/string.json` | §7 文案 |

---

## 9. 验证

构建（G12）：`devecocli build --product default` 与 `devecocli build --product pc_normal`
双绿（新增分布式代码在双 product 编译路径上对称）。

单机链路（无组网，pc_normal 即可走通）：
1. 安装 pc_normal → 设置 → 关于 → 图标 4 连点 → Toast「已写入 3 个分布式测试包」→
   日志 `[sync] easter egg written packages=3`；
2. 侧边栏底部 Shell 上方出现「清单同步 +3」→ 点击拉起 Sheet → 互见句「你的分布式测试
   新装了 3 个包」→ 3 行只读（无勾选框，G9）→ 关闭 Sheet → 入口消失（ack 生效）；
3. 再连点 4 次 → 入口重新出现（updatedAt 前移）。

双机链路（真机组网，同账号可信设备，模拟器不支持端端同步）：
1. `hidumper -s 3511` 两端核对设备安全等级 ≥ S4（S4 标签静默门槛前置排查，F5）；
2. A 机（pc_acl）`brew install <pkg>` → 刷新已装 → 日志 `[sync] publish device=<A> packages=N`；
3. B 机（pc_acl）侧边栏出现「清单同步 +N」→ Sheet 勾选 → 「安装所选」→ 队列逐条执行
   （命令 Sheet 明细可关可重开续看）→ 完成后 `install_queue.json` 条目全部 DONE；
4. B 机设置 → AI 设置改 provider/model → A 机设置页（保持打开或重进）显示新值 +
   日志 `[sync] ai config applied …`；确认同步库中无 Key 值；
5. 断连重连场景：A 机离线期间装 2 个包 → 重连后 B 机 syncComplete 日志
   `devices=1 failed=0` → 入口出现（增量同步不退化为全量）。

---

## 10. 风险与未决

| 风险 | 处置 |
|---|---|
| S4 静默不同步（F5）：组网中任一设备等级 < S4 则整库不同步且无报错 | 需求方明确裁定 S4 不降级；§9 前置 hidumper 核对；论坛来源（华为开发者问答 0203230805818336547）已确认该行为 |
| `autoSync` 语义分歧：论坛一说法称仅「跨设备 Call 多端协同」场景生效 | 不依赖 autoSync：§3.5 四次显式 sync() 为主，autoSync=true 仅作辅助（无害） |
| `deviceManager.getLocalDeviceSync()` 未在本工程验证过 | F8 降级路径兜底（拿不到 deviceId → 不发布，只接收）；真机首轮核对 |
| 同节点双 bindSheet 不可靠 | 已规避：同步 Sheet 绑 `HdsSideBar`、命令 Sheet 绑 `HdsNavDestination`（官方 FAQ 口径） |
| `DISTRIBUTED_DATASYNC` 授权方式（system_grant / user_grant 说法不一） | 双保险：module.json5 声明 + 常驻页首次打开动态申请（已授权时 request 为 no-op）；拒绝态有引导行兜底 |
| 常驻页与 Sheet 双形态组件状态同步 | 共享 service 单例 state（@Observed），形态只是宿主差异 |
| decisions.md / round5.md §2 仍留「v0 文件流 / v1 云同步」旧口径 | 需求方仅指示修订 round4 与 rejected（已完成）；其余文档的口径统一待后续裁定（本 spec 为实现权威） |
| v1 文件流 spec 残留在 worktree 分支 `feature/brew-manifest-sync` | 分支不合并、可择机删除；队列设计已被本 spec §3.7 回收 |
