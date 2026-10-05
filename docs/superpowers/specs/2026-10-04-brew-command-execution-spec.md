# brew 命令执行（更新全部 / 安装 / 升级）与已安装列表缓存 · 设计

> 日期：2026-10-04。状态：待评审。评审通过后由 `writing-plans` 产出实施计划。
> 范围：`features/pcnative` 增加流式执行与中断能力；`features/brewcommon` 增加 brew 命令层与已安装列表快照；
> `features/mine` 的「我的 - 待更新」页增加「更新全部」按钮；`features/brewdetail` 的包详情页增加「安装 / 升级」按钮；
> 执行 Sheet 由顶层页面统一承载（流式显示 stdout 与 stderr、可中断）；同一时刻只执行一条写命令（没有等待队列），只读读取可以与写命令并发执行。
> 相关文档：[`2026-10-04-brew-installed-packages-spec.md`](2026-10-04-brew-installed-packages-spec.md)（本机包读取与执行通道）、
> [`2026-10-04-brew-mine-package-detail-spec.md`](2026-10-04-brew-mine-package-detail-spec.md)（本机包进入详情页）、
> [`2026-10-04-pc-dual-variant-entry-spec.md`](2026-10-04-pc-dual-variant-entry-spec.md)（`BREW_CLI_ENABLED` 开关）、
> [`../../brew-api-design.md`](../../brew-api-design.md) §4.3 / §5.3、[`../../brew-handover.md`](../../brew-handover.md)。
> Sheet 的绑定位置、结束提示归属与侧边栏 Shell 入口见 [`2026-10-04-brew-shell-sidebar-entry-spec.md`](2026-10-04-brew-shell-sidebar-entry-spec.md)。

---

## 1. 目标与成功判据

本轮把应用从「只读设备上的 brew」推进到「通过设备上的 brew 执行安装与升级」。执行过程对用户完全可见：
命令的输出实时进入一个 Sheet，用户可以在 Sheet 里发送中断，也可以在命令跑着的时候关掉 Sheet 去做别的事。

| # | 判据 | 可观测证据 |
| --- | --- | --- |
| G1 | 「我的 - 待更新」页底部出现「更新全部」按钮，执行的命令跟随筛选 chips：全部 → `brew upgrade`；Formulae → `brew upgrade --formula`；Casks → `brew upgrade --cask` | Sheet 顶部显示的命令行；`[brew-cmd] start args=…` |
| G2 | 当前筛选下列表为空时不显示按钮；正在执行的命令与本次将要发出的参数相同时按钮显示「执行中…」，点击重新打开 Sheet | 真机 |
| G3 | 包详情页：未安装显示「安装」；已安装且有新版本显示「升级」；已安装且最新显示「已安装」且不可点击 | 真机与设备上 `brew list --versions` 对照 |
| G4 | Sheet 按到达顺序流式显示 stdout 与 stderr，stderr 行使用不同颜色 | 真机；`[brew-cmd] poll out=… err=…` |
| G5 | Sheet 的「中断」发送 SIGINT（与终端 Ctrl+C 相同），命令在 3 秒内结束并显示「已中断」 | `[brew-cmd] interrupt sig=int`、`[brew-cmd] exit error=1005` |
| G6 | 中断后 5 秒仍未退出时按钮变为「强制终止」，点击后进程组被 SIGTERM / SIGKILL 终止 | 真机；`[brew-cmd] kill` |
| G7 | Sheet 关闭后命令继续执行；重新进入页面时按钮显示进行中，点击可重新打开 Sheet 并看到完整输出 | 真机 |
| G8 | 命令结束后已安装列表自动刷新：升级成功的包从「待更新」列表消失 | 真机；`[BrewInstalled] load ok installed=… outdated=…` |
| G9 | 冷启动进入「我的」页时用上一次的快照立刻显示数量，不等待 brew 命令 | `[BrewInstalled] snapshot pref age=…`；页面不出现转圈 |
| G10 | 新鲜窗口内的重复进入页面不执行 brew 命令 | `[BrewInstalled] skip fresh age=…` 的条数 |
| G11 | 执行通道自检（`SHELL_STREAM_VERIFY`）全部用例 `ok=true` | `[pcnative] verify` 日志 |
| G12 | 两个产品构建都通过 | `devecocli build --product default` 与 `--product pc_normal` 输出 `BUILD SUCCESSFUL`，`ERROR` 计数为 0 |
| G13 | 关闭本机包能力的版本（pc_normal）不显示「更新全部」与「安装 / 升级」按钮 | 真机 |
| G14 | 同一时刻只有一条写命令：写命令执行期间再发起写命令被拒绝并提示「已有命令在执行」，设备上不会出现两条 brew 写命令并行 | 真机；`[brew-cmd] busy args=…` |
| G15 | 只读读取与写命令并发时的错误处理：并发期间取得的读取结果不写入快照；读取失败保留旧快照；写命令结束后自动刷新到稳定状态 | `[BrewInstalled] concurrent read`、`[BrewInstalled] load ok` |

---

## 2. 现状

| 位置 | 现状 |
| --- | --- |
| `features/pcnative/src/main/ets/util/ShellUtils.ets` | 只有一次性执行：`run()` 与 `runSync()` 都要等命令结束才返回，输出整份返回，中途拿不到任何内容，也没有中断入口 |
| `features/pcnative/src/main/cpp/shell_hook.cpp` | `ShellHookRun` 用 select 循环把 stdout / stderr 攒进两个字符串（各 8 MB 上限），超时或超限时终止整个进程组；子进程 `setpgid(0, 0)` 自成进程组 |
| `features/pcnative/src/main/ets/constant/ShellConstants.ets` | 错误码 0 / −1 / 1001–1004；`SHELL_TIMEOUT_MAX_MS = 600000` |
| `features/brewcommon/src/main/ets/service/BrewInstalledLoader.ets` | 进程内缓存 60 秒（`BREW_INSTALLED_TTL_MS`）+ 在途请求合并；每次重读都要跑一次 `brew info --json=v2 --installed`（首次 2–3 秒）；不保存到磁盘；`isBrewCliEnabled()` 读 `StorageKey.BREW_CLI_ENABLED` |
| `features/brewcommon/src/main/ets/service/BrewInstalledLoader.ets:190` | `discoverBrewPath()` 与 `commandOf()` 把环境前缀（`HOMEBREW_NO_AUTO_UPDATE=1` 等）与 brew 路径拼进命令行，只有本机包读取在用 |
| `features/brewcommon/src/main/ets/util/BrewCommandGenerator.ets` | 已有 `baseCommand` / `upgradeCommand` / `uninstallCommand` / `installCommandOf`，只用于展示与复制，没有执行入口 |
| `features/brewcommon/src/main/ets/model/BrewDetailViewData.ets:90` | `BrewInfoPageData.installed` 恒为 `false`，注释写明「接 brew info --json 后才有值」；页面没有消费点 |
| `features/mine/src/main/ets/view/MinePackagesView.ets` | 已安装 / 待更新 / 已更新三个模式共用一个页面；内容是一整张卡片列表；没有页面级操作按钮 |
| `features/mine/src/main/ets/viewmodel/MinePageVM.ets:53` | `isLocalPackagesEnabled()` 读 `StorageKey.BREW_CLI_ENABLED`，控制本机包三块的显隐与取数 |
| `features/brewdetail/src/main/ets/component/BrewInfoSectionView.ets` | `BrewInstallCommandCard` 只有命令文本与「复制」按钮 |
| `features/brewcommon/src/main/resources/*/element/string.json` | `brew_action_install`（安装）、`brew_action_upgrade`（升级）、`brew_state_installed`（已安装）三条文案已存在但没有使用点 |

---

## 3. 交互与视觉

### 3.1 「我的 - 待更新」页的「更新全部」

**位置**：页面内容区底部固定一行。页面结构由「一个 Scroll」改成「Column { Scroll(列表).layoutWeight(1); 操作行 }」。

放在底部的原因：这个按钮的操作对象是整张列表，列表可能很长（设备上实测 8 个待更新包，但接口不保证这个量级），放在内容顶部会随列表滚走；底部固定行让它始终可点。

**显示条件**（三个都满足才渲染）：

1. `packagesState.mode === PackageListMode.OUTDATED`；
2. `packagesState.filteredPackages.length > 0`（当前筛选下确实有可更新的包）；
3. `BrewCli.isEnabled()`（`BREW_CLI_ENABLED` 为真，即 pc_acl 版本）。

**按钮**：靠右的主操作胶囊按钮，样式与 `BrewSourceSettingView.CapsuleButton` 相同（高度 32vp、`comp_background_tertiary` 底色、`corner_radius_level4`／侧边栏布局、文字 `Body_M` + Medium）。

**命令跟随筛选**：

| 筛选 chips | 执行的参数 |
| --- | --- |
| 全部（下标 0） | `upgrade` |
| Formulae（下标 1） | `upgrade --formula` |
| Casks（下标 2） | `upgrade --cask` |

**执行中的表现**：`BrewCommandRunner.isRunningArgs(本次将要发出的参数)` 为真时按钮文案改为「执行中…」，点击打开 Sheet；其它命令正在执行时按钮保持原文案，点击弹「已有命令在执行」。

**列表底部让位**：有操作行时列表内层 `Column` 的 `margin.bottom` 用 `SPACE_16`，操作行自己承担底部内边距（`naviIndicatorHeight + SPACE_12`）；没有操作行（已安装 / 已更新两个模式）时保持现状 `naviIndicatorHeight + SPACE_24`。

### 3.2 包详情页的「安装 / 升级 / 已安装」

**位置**：页面底部的悬浮操作栏（2026-10-05 起）—— 叠在内容区之上，背板是一层白色渐变半透明遮罩（不做模糊），按钮宽度占内容区 60%（上限 448vp）。
`BrewInstallCommandCard` 里只剩命令文本与「复制」按钮。取值、结构、方法与内容让位见
[`2026-10-05-brew-detail-action-bar-spec.md`](./2026-10-05-brew-detail-action-bar-spec.md)；
下面的文案表与点击行为不受位置变化影响。

**状态与动作**：

| 快照状态 | 按钮文案 | 点击动作 |
| --- | --- | --- |
| 未安装，或快照还不知道 | 安装 | `brew install <name>` |
| 已安装且有新版本 | 升级 | `brew upgrade <name>` |
| 已安装且版本已是最新 | 已安装（`enabled(false)`） | —— |

`<name>` 是 `BrewCommandGenerator.qualifiedName(token, tap)` 的结果（第三方 tap 补 `tap/token` 前缀）。

**数据来源**：`BrewInstalledLoader.installedOf(token)` 读已安装快照（内存优先，其次磁盘）。快照未知时先按「安装」渲染，同时后台触发一次读取，读回后按上表更新；详情页自己的网络取数不受影响，也不等快照。

**渲染条件**：

- `BrewCli.isEnabled()` 为假（pc_normal）时整块按钮不渲染；
- `BrewCommandGenerator.isSafeName(token)` 与 `isSafeName(tap)` 任一不通过时不渲染按钮，并打一条 warn 日志（数据源里的包名不该进命令行）。

**执行中的表现**：`BrewCommandRunner.isRunningArgs(本包本次将要发出的参数)` 为真时按钮文案改为「执行中…」，点击打开 Sheet；其它命令正在执行时按钮保持「安装」/「升级」，点击弹「已有命令在执行」。

### 3.3 执行 Sheet

**绑定位置**：只有一份，绑在 `features/pcui` 的顶层页面 `PcMainPage` 的 `HdsNavDestination` 上。

```ets
.bindSheet(this.commandState.sheetShown, this.CommandSheetBuilder(), SheetOptions)
```

绑在顶层容器上的原因：应用从启动到退出的顶层容器只有一个，五个页签内容与所有二级页都在它的内容区里，这一个宿主的浮层因此覆盖全部界面；绑两份会出现两层叠加的半模态。

打开由 `BrewCommandRunner.openSheet()` 请求（页面按钮与侧边栏 Shell 入口都只调它），开关状态是 `BrewCommandState.sheetShown`。

`SheetOptions` 沿用 `MineView` 里登录 Sheet 的写法：`MaterialUtil.getMaterialOptions<SheetOptions>`（`CustomImmersiveStyle.ULTRA_THICK` + 透明底色），`preferType` 窄屏 `SheetType.BOTTOM` / 宽屏 `SheetType.CENTER`，`height` 宽屏按 `CommonConstants.SHEET_HEIGHT_RATIO_XL`、其余 `SheetSize.LARGE`，`width` 宽屏 `CommonConstants.SHEET_WIDTH_XL`，`showClose: false`（关闭入口在标题栏菜单里）。

回调两个：`onWillAppear` 调 `BrewCommandRunner.markViewed()`（登记终态结果已经被看过），`onDisappear` 调 `BrewCommandRunner.closeSheet()`。关闭登记放在 `onDisappear`（退场动画结束后触发）：官方文档写明 `onWillDisappear` 里不允许修改状态变量；把「Sheet 已关闭」的登记推迟到动画结束，侧边栏 Shell 入口就不会在退场动画期间出现，用户不会遇到「点了入口却没有反应」（半模态的退场动画不支持打断）。

**内容**（`BrewCommandSheet`，放在 `features/brewcommon`）。标题栏与「我的 - 设置」同源：`Navigation`（`titleMode(Mini)` + `hideBackButton(true)`）给标题栏，`Navigation.title()` 给标题（这次执行在做什么），`Navigation.menus()` 给两个操作：

| 位置 | 内容 |
| --- | --- |
| 标题栏菜单 | trash（`sys.symbol.trash`）结束命令：第一次点击发 SIGINT，宽限期之后再点发 SIGTERM / SIGKILL；命令没在跑、或正处在宽限期内时不可点。xmark（`sys.symbol.xmark`）关闭 Sheet |
| 内容区 | 一整块等宽文本：第一行是 `$ <命令>`（空一行接输出），后面每行一个 `Span`；黑底（`Color.Black`）、白字（`Color.White`）、字体 `JetBrains Mono NL`、行高 1.5 倍；stderr 行用 `sys.color.warning`；最多保留 1000 行，超出时命令行之后显示「已省略前 N 行」；命令结束之后在文本末尾追加状态行，写法是方括号里的短句：`[运行中]` / `[正在中断…]` / `[已完成 退出码 %d]` / `[已中断]` / `[执行超时]` / `[执行失败 退出码 %d]`（通道没给出退出码时是 `[执行失败]`） |

组件入参：`@ObjectLink state: BrewCommandState`（`@Prop` 会深拷贝整个对象，1000 行日志每 200ms 复制一次不可接受），加上 `onInterrupt` / `onForceKill` / `onClose` 三个回调，由顶层宿主接到 `BrewCommandRunner` 上（中断与强制终止同样都调 `interrupt()`，升级成 SIGTERM / SIGKILL 由命令层按时机处理）。

**自动滚动**：日志文本放在 `Scroll` 里（`Scroller`），新行落地时滚到底；用户上滑离开底部后停止跟随（用 `Scroller.isAtEnd()` 判定），滚回底部后恢复跟随。一批日志只安排一次滚动：一次轮询可能落地上百行，逐行排定时器会把滚动任务堆起来。

**行处理**：

- 按 `\n` 分行，最后一段不完整的行留到下一次轮询再拼接；
- 行内出现 `\r` 时只保留最后一个 `\r` 之后的内容（brew 的下载进度用 `\r` 重绘同一行，逐条追加会把进度碎片铺满整个日志区）；
- 剥离 ANSI 转义序列（`ESC [ … 字母`）。

**关闭行为**：Sheet 可随时关闭（下滑、点遮罩、返回键，或标题栏菜单里的 xmark）。关闭不影响命令：任务状态在单例里，输出继续被收进行缓冲；页面按钮显示「执行中…」，点击重新打开 Sheet 并看到完整输出，命令结束后没看过终态结果时侧边栏底部的 Shell 入口一直也在（命令在后台执行、终态结果还没被看过时入口常驻，判据见 [`2026-10-04-brew-shell-sidebar-entry-spec.md`](2026-10-04-brew-shell-sidebar-entry-spec.md)）。

**结束提示**：命令结束时如果 Sheet 没有打开，由顶层页面 `PcMainPage` 弹一条 Toast（它订阅 `BrewCommandRunner`，命令进入终态且 Sheet 关着时弹一次），文案与 Sheet 文本末尾的状态行同源（`brewCommandStatusText(state)`，如 `[已完成 退出码 0]`）。顶层宿主从应用启动到退出一直存在，结束提示不依赖哪个页面还活着。

### 3.4 中断与强制终止

- 「中断」= `ShellUtils.interruptStream(taskId)` → `kill(-pgid, SIGINT)`。与终端 Ctrl+C 相同：整个进程组一起收到 SIGINT，brew 与它拉起的子进程都能收到。
- 宽限期 `BREW_COMMAND_INTERRUPT_GRACE_MS = 5000`：中断发出后 5 秒内按钮禁用、状态标签显示「正在中断…」；5 秒后仍在运行时按钮改为「强制终止」（切换由 `BrewCommandState.forceKillReady` 驱动，见 §5.3 第 7 点），点击后 `ShellUtils.killStream(taskId)` → `SIGTERM`，2 秒后 `SIGKILL`。
- 命令因我们发出的信号结束时，`errorCode = 1005`（`SHELL_ERR_INTERRUPTED`），页面显示「已中断」。

---

## 4. 执行通道（`features/pcnative`）

### 4.1 ArkTS 接口

`ShellUtils` 增加五个方法，`pcnative/Index.ets` 同步导出新类型：

```ts
/** 一次轮询里的一段增量输出。相邻的同类片段在原生侧已经合并 */
export class ShellStreamEvent {
  /** 'stdout' | 'stderr' */
  public kind: string;
  public data: string;
}

/** 一次轮询的结果 */
export class ShellStreamPoll {
  /** 按到达顺序排列 */
  public events: ShellStreamEvent[];
  /** 命令已结束，且管道里的剩余内容已经全部取走；调用方一直轮到它为真为止即可 */
  public ended: boolean;
  public exitCode: number;
  public errorCode: number;
}

export class ShellUtils {
  /** 启动一条命令并立刻返回任务标识；0 表示没有起来 */
  public static startStream(command: string, timeoutMs: number, cwd: string): number;
  /** 取走新增输出。maxBytes 是本次读取上限（缺省 256KB）。任务不存在返回 null */
  public static pollStream(taskId: number, maxBytes?: number): ShellStreamPoll | null;
  /** 向进程组发送 SIGINT（等同终端 Ctrl+C）。返回是否送达 */
  public static interruptStream(taskId: number): boolean;
  /** 终止：SIGTERM，宽限 2 秒后 SIGKILL。返回是否送达 */
  public static killStream(taskId: number): boolean;
  /** 释放任务。命令结束后调用一次 */
  public static releaseStream(taskId: number): void;
}
```

`features/pcnative/src/main/cpp/types/libpcnative/Index.d.ts` 与 `napi_init.cpp` 同步增加 `startCommand` / `pollCommand` / `interruptCommand` / `killCommand` / `releaseCommand` 五个函数，返回值形状与上面两个类对应（`napi_init.cpp` 里构造数组与对象；ArkTS 侧照 `toShellResult` 的现有做法转成类实例）。

### 4.2 原生实现（`shell_hook.cpp`）

现有的一次性执行逻辑（fork + execve + 两条管道 + 进程组 + 超时终止）抽成「任务」：

| 函数 | 职责 |
| --- | --- |
| `ShellHookStart(command, timeoutMs, cwd, taskId)` | 建管道、`fork`、子进程 `setpgid(0,0)` + `chdir` + `execve /bin/sh -c`；父进程记下 pid、两个读端、截止时刻 |
| `ShellHookPump(task, maxBytes, sliceMs)` | 非阻塞 `select` + `read` + `waitpid(WNOHANG)`；把读到的内容按到达顺序追加进任务的事件队列（相邻同类合并）；到截止时刻就终止进程组并标记超时 |
| `ShellHookInterrupt(task)` | `kill(-pgid, SIGINT)`，并记下本任务收到过中断请求 |
| `ShellHookKill(task)` | `kill(-pgid, SIGTERM)`，宽限期过后再 `SIGKILL`（由下一次 `Pump` 触发） |
| `ShellHookRelease(task)` | 关闭两个读端、释放缓冲、从任务表移除；任务还在跑时先 `SIGKILL` 并 `waitpid` 回收，避免留下孤儿进程与僵尸进程 |
| `ShellHookNextTaskId()` | 由原生侧统一分配任务标识，一次性执行与流式执行共用同一个自增计数器 |

约定：

1. **一次性执行改为建立在任务之上**：`ShellHookRun` = 启动 + 循环 `Pump(20ms)` 直到结束 + 收尾。对外行为不变（超时 1003、超限 1004、退出码与信号处理同现状），内部只剩一套 fork / 管道实现。
2. **流式路径不再累计输出**：每次轮询最多取走 `maxBytes`（缺省 256KB），任务里的队列只保留还没被取走的部分。队列有 8 MB 上限，达到上限后本轮不再读管道，子进程写满管道时自己阻塞，与终端里命令被回显速度限制的行为相同。
3. **子进程退出后先读完管道里的剩余内容，再报告 `ended`**：否则最后几行（往往是错误信息）会丢。`ended` 的含义因此是「命令已结束且管道已排空」，调用方不需要额外的「还有没有剩余」字段。管道写端可能被命令自己再起的子进程继承，父进程先退出时管道不会立即关闭，所以回收子进程之后最多再等 1 秒读管道。
4. **`pollStream` 不做任何等待**：非阻塞读 + `WNOHANG` 等待，单次调用的工作量有上限，可以在 JS 线程上调用。
5. **任务表用互斥量保护**：一次性执行走 libuv 线程池（`runCommand`）或 JS 线程（`runCommandSync`），与流式轮询可能同时访问任务表。
6. **新增错误码 `SHELL_ERR_INTERRUPTED = 1005`**：本任务收到过中断或终止请求、命令因此结束时使用。判定只看「收到过请求」，不要求 `WIFSIGNALED`：实测 `/bin/sh -c "sleep 30"` 收到 SIGINT 之后会以退出码 0 结束，只按信号判定会把「已中断」报成「已完成」。错误码优先级：超时 `1003` > 输出超限 `1004` > 收到过请求 `1005` > 正常退出 `0`（`exitCode` 有效）> 未收到请求却被信号结束 `1002`（并追加 `terminated by signal N`）。

### 4.3 超时

`SHELL_TIMEOUT_MAX_MS` 由 10 分钟改为 30 分钟（`30 * 60 * 1000`），命令层用 `BREW_COMMAND_TIMEOUT_MS = SHELL_TIMEOUT_MAX_MS`。

为什么放宽：一次升级要下载与安装多个包，设备上还有从源码构建的可能；超时在这里的作用是「进程完全没有进展时的兜底」，而流式执行有可见的输出与「中断」按钮，用户随时能结束它。其余调用方（本机包读取传 30 秒）不受影响。

---

## 5. 命令层（`features/brewcommon`）

### 5.1 `BrewCli`：设备上的 brew 调用口径

新增 `features/brewcommon/src/main/ets/service/BrewCli.ets`，把「怎么调用设备上的 brew」收在一处（现在散在 `BrewInstalledLoader` 里）：

```ts
export class BrewCli {
  /** entry 注入的能力开关（`StorageKey.BREW_CLI_ENABLED`），未注入为 false */
  public static isEnabled(): boolean;
  /** 能力开关打开、执行通道可用、且找到 brew 可执行文件 */
  public static isReady(): boolean;
  /** 进程内缓存的 brew 路径发现结果（原 `discoverBrewPath()` 的实现搬过来） */
  public static brewPath(): string;
  /** `bin/brew` 的上一级目录 */
  public static prefix(): string;
  /** 子进程工作目录：brew 的 prefix，取不到时用 `SHELL_DEFAULT_WORKING_DIRECTORY` */
  public static workingDirectory(): string;
  /** 完整命令行：环境前缀 + brew 路径 + args。args 为空串时返回空串 */
  public static commandLine(args: string): string;
}
```

环境前缀与现状完全相同（`HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1 NONINTERACTIVE=1`，加 `HOMEBREW_PREFIX`）。

`HOMEBREW_NO_AUTO_UPDATE=1` 保留的理由：页面上的「待更新」是按设备本地 tap 状态算出来的（`brew info --json=v2 --installed` 的 `outdated` 字段），升级命令用同一份状态才能做到「页面说升哪些就升哪些」；`brew update` 是另一件事（要联网、要 git、可能几分钟），不在本功能范围内。数据源里有、设备 tap 里没有的包会安装失败，brew 的原始错误会显示在 Sheet 里。

`BrewInstalledLoader` 的读取命令改用 `BrewCli.commandLine('info --json=v2 --installed')`，删除重复的环境拼装。

### 5.2 命令构造与包名校验

`BrewCommandGenerator` 增加参数级构造方法，并让展示方法建立在它们之上（展示与执行共用同一份参数拼装）：

```ts
/** 安装 / 升级的参数部分（不含 brew 本身） */
public static installArgs(kind: string, token: string, tap: string): string;   // install [--cask] <name>
public static upgradeArgs(kind: string, token: string, tap: string): string;   // upgrade [--cask] <name>
/** 全部升级的参数：0 全部 / 1 Formulae / 2 Casks */
public static upgradeAllArgs(filterIndex: number): string;
/** 包名与 tap 的字符集校验 */
public static isSafeName(value: string): boolean;
```

`baseCommand` / `upgradeCommand` / `uninstallCommand` 改为 `'brew ' + <对应 Args>(…)`，输出与现状逐字相同（`brew install ripgrep`、`brew install --cask raycast`、`brew upgrade ripgrep` 等）。

`isSafeName` 的规则：长度 1–128；首字符必须是字母或数字；其余允许字母、数字与 `@ + . _ - /`。首字符不允许 `-`，避免参数被 brew 当成选项。校验只做一件事：把数据源来的包名挡在命令行之外；校验不通过的包不渲染按钮、不启动命令，并打 warn 日志。

### 5.3 `BrewCommandRunner`：单飞、轮询、行缓冲

新增 `features/brewcommon/src/main/ets/service/BrewCommandRunner.ets`（单例）与
`features/brewcommon/src/main/ets/model/BrewCommandModels.ets`（状态类型）。

```ts
export enum BrewCommandStatus { IDLE, RUNNING, DONE, INTERRUPTED, FAILED, TIMEOUT }

/** start() 的结果，调用方据此决定弹哪条提示 */
export enum BrewCommandStartResult {
  /** 已启动 */
  STARTED = 'started',
  /** 已有写命令在执行 */
  BUSY = 'busy',
  /** 能力开关关闭，或执行通道 / brew 路径不可用 */
  UNAVAILABLE = 'unavailable',
  /** 参数为空或不合法 */
  BAD_ARGS = 'bad_args',
}

export class BrewCommandLine {
  public text: string;
  public stderr: boolean;
}

export class BrewCommandState {
  public title: ResourceStr;
  /** 用户可读的命令行（如 `brew upgrade --formula`） */
  public command: string;
  /** 传给 brew 的参数部分，页面靠它判断本页按钮是否在忙 */
  public args: string;
  public lines: BrewCommandLine[];
  /** 因超出上限被丢弃的行数 */
  public omittedLines: number;
  public status: BrewCommandStatus;
  public exitCode: number;
  public errorCode: number;
  public startedAt: number;
  public endedAt: number;
  /** 中断发出的时刻，0 表示还没发过 */
  public interruptSentAt: number;
  /** 是否已发送过强制终止 */
  public killSent: boolean;
  /** 宽限期已过、可以发强制终止；由 runner 在宽限期到点的定时回调里置真 */
  public forceKillReady: boolean;
}

export class BrewCommandRequest {
  public title: ResourceStr;
  public command: string;
  /** 传给 brew 的参数部分，由 5.2 的构造方法产出 */
  public args: string;
}

export class BrewCommandRunner {
  public static getInstance(): BrewCommandRunner;
  /** 启动。返回值决定调用方弹哪条提示 */
  public start(request: BrewCommandRequest): BrewCommandStartResult;
  /** 当前命令的状态；没有命令在执行时是最近一条已结束命令的状态，从未执行过时是 IDLE */
  public getState(): BrewCommandState;
  /** 当前有命令在执行 */
  public isRunning(): boolean;
  /** 正在执行的命令参数是否与给定参数相同 */
  public isRunningArgs(args: string): boolean;
  /** 第一次发送 SIGINT；宽限期过后再调用则发送 SIGTERM / SIGKILL。只作用于当前命令 */
  public interrupt(): void;
  public subscribe(listener: () => void): void;
  public unsubscribe(listener: () => void): void;
  /** 请求展示执行 Sheet。已展示时什么都不做 */
  public openSheet(): void;
  /** 请求关闭执行 Sheet。宿主在 Sheet 退场动画结束后调用 */
  public closeSheet(): void;
  /** 登记「终态结果已经被看过」。宿主在 Sheet 开始展示时调用；命令还在执行时什么都不做 */
  public markViewed(): void;
}
```

要点：

1. **单飞**：同一时刻只有一条写命令在执行，没有等待队列。`start()` 在空闲时立即启动并返回 `STARTED`；已有命令在执行时返回 `BUSY`，调用方弹「已有命令在执行」。
2. **不做排队**：被拒绝的请求直接结束，用户看到提示后可以自己再点一次；按钮在忙碌期间保持可点，不进入禁用态。
3. **轮询周期 `BREW_COMMAND_POLL_MS = 200`**：定时器里调用 `ShellUtils.pollStream(taskId, SHELL_STREAM_POLL_MAX_BYTES)`，把事件按 3.3 的行处理规则转成行，追加进 `lines`（上限 `BREW_COMMAND_LOG_MAX_LINES = 1000`，超出丢弃最旧的行并累加 `omittedLines`）。200ms 的批量正好和界面刷新节奏一致，也避免每一小段输出都触发一次渲染。`pollStream` 返回 `null`（任务已不存在）时按失败收尾，终态 `FAILED`，并打一条 warn。
4. **状态对象带 `@Observed`，就地改一级属性**：`lines` 每次赋一个新数组（ForEach 的键用 `omittedLines + index`：裁剪之后同一个下标会指向不同内容，直接用下标会让 ArkUI 复用旧节点），`status` / `omittedLines` 等直接赋值。页面用 `@State` 持有同一个实例，Sheet 用 `@ObjectLink` 接收。选 `@Observed` + `@ObjectLink` 的原因：`@Prop` 对对象做深拷贝（官方文档），1000 行日志每 200ms 复制一次不可接受。
   通知订阅者仍然保留：顶层宿主要用它弹结束提示，页面要用它刷新按钮文案。
5. **结束处理**（顺序固定）：`releaseStream(taskId)` → 清定时器 → 计算最终状态（`1005` → `INTERRUPTED`，`1003` → `TIMEOUT`，`exitCode === 0` → `DONE`，其余 → `FAILED`）→ `BrewInstalledLoader.invalidate()`（触发一次后台刷新）→ 通知订阅者。
6. **日志**：`[brew-cmd] start args=…`、`[brew-cmd] busy args=…`、`[brew-cmd] poll out=… err=…`（只在有增量时打）、`[brew-cmd] interrupt sig=int`、`[brew-cmd] kill sig=kill`、`[brew-cmd] exit code=… error=… ms=…`。
7. **中断后的定时回调**：发送中断时安排一次「宽限期到点」的定时回调，回调里把 `forceKillReady` 置真再通知订阅者。只调通知不够：Sheet 用 `@ObjectLink` 观察一级属性，命令静默（没有新行落地）时不会重渲染，按钮就切不到「强制终止」。
8. **Sheet 与结果的可见性放在状态对象上**：`BrewCommandState` 增加 `sheetShown`（执行 Sheet 是否展示，宿主的 `bindSheet` 绑定它）与 `resultViewed`（终态结果是否已经在 Sheet 里展示过；命令启动时复位，命令结束时 Sheet 正展示、或命令结束后 Sheet 被打开时置真）。`begin()` 复位 `resultViewed`，`finish()` 在 Sheet 正展示时置真，`openSheet()` / `closeSheet()` 改 `sheetShown`，`markViewed()` 在命令已进终态时置 `resultViewed`。这三个方法只改状态对象的一级属性，观察这些属性的组件自己重渲染。

### 5.4 启动前的检查

`start()` 依次检查，返回对应的 `BrewCommandStartResult`，调用方据此弹提示并打日志：

| 检查 | 返回值 | 调用方提示 |
| --- | --- | --- |
| `BrewCli.isEnabled()`（pc_normal 版本不渲染按钮，这里是兜底）与 `BrewCli.isReady()`（通道 + brew 路径） | `UNAVAILABLE` | 设备上找不到可用的 brew |
| `args` 非空，且按空格切分之后每个词要么是 `--cask` / `--formula`，要么通过 `isSafeName` | `BAD_ARGS` | 包名不合法（同时打 warn） |
| `isRunning()` | `BUSY` | 已有命令在执行 |
| `BrewCli.commandLine(args)` 为空串，或 `startStream` 返回 0 | `UNAVAILABLE` | 设备上找不到可用的 brew（日志 `start rejected reason=start_failed`） |
| 当前空闲 | `STARTED` | ——（Sheet 打开，直接看到命令开始） |

---

## 6. 已安装列表缓存

### 6.1 问题

`brew info --json=v2 --installed` 每次都要拉起 vendored Ruby，首次 2–3 秒。现状的 60 秒窗口太短：
来回切换「我的」与它的子页面、每打开一个包详情页，都可能触发一次读取；进程重启后缓存清零，
冷启动进「我的」页必须等一次命令。加上本轮之后，包详情页也要读同一份数据，读取次数只会更多。

### 6.2 快照与新鲜窗口

| 层 | 内容 | 生命周期 |
| --- | --- | --- |
| 内存快照 | `BrewInstalledSets` + `readAt` | 进程内一份 |
| 磁盘快照 | `{ version: 1, readAt, packages: BrewInstalledPackage[] }` | `PreferenceManager` 的 `brew_installed_snapshot` 键 |

磁盘快照只保存 `installed` 一个集合，`outdated` 与 `updated` 在读取时用现有的 `buildSets()` 派生 ——
两个派生集合各有自己的排序口径，存两份迟早会出现「盘上是旧的、内存里是新的」这种不一致。

放在全局 store 的理由：本机包是设备状态，不属于任何数据源，
清空某个源的缓存不应该把它一起删掉。

新鲜窗口：`BREW_INSTALLED_FRESH_MS = 10 * 60 * 1000`（替换现在的 60 秒 `BREW_INSTALLED_TTL_MS`）。
取 10 分钟的依据是「读取一次的代价」与「数据变化的来源」：数据只在有人安装 / 升级 / 卸载时变化，
其中由本应用发起的变化在执行结束后会主动让快照失效，剩下的只有用户在终端里直接操作 brew 这一种，
10 分钟的陈旧窗口对它是可以接受的。

`loadSets(force = false)` 的三种结局：

| 情况 | 行为 |
| --- | --- |
| 有快照且未超出新鲜窗口 | 立刻返回快照，不执行命令 |
| 有快照且已超出新鲜窗口 | 立刻返回旧快照，同时在后台执行一次刷新（在途请求合并）；成功后写内存与磁盘并通知订阅者，失败只记日志 |
| 没有任何快照 | 执行一次命令并等待；成功写快照并返回，失败抛出异常（页面走失败态） |
| `force = true`（显式刷新） | 执行一次命令并等待，有快照时也不先返回旧数据；成功写快照，失败抛出异常 |

配套接口：

```ts
/** 同步取当前可用的快照（内存优先，其次磁盘懒加载）。不执行命令 */
public static snapshot(): BrewInstalledSnapshot | null;
/** 快照里按包名找一条。name 是不带 tap 前缀的包名 */
public static installedOf(token: string): BrewInstalledPackage | null;
/** 把快照标记为过期（数据保留）并触发一次后台刷新（在途请求合并） */
public static invalidate(): void;
/** 快照更新通知（后台刷新成功、命令结束后的刷新） */
public static subscribe(listener: () => void): void;
public static unsubscribe(listener: () => void): void;
```

规则：

1. **读失败不覆盖快照**：快照里只保留成功读取的结果；失败既不写内存也不写磁盘，也不推进新鲜窗口的判定，下一次访问会重新执行命令。现状的 `cache` / `cacheAt` 会把失败的 `BrewInstalledOutcome` 一起存下（`loadOnce` 先写缓存再抛异常），新设计不再保存失败结果，内存快照就是「最近一次成功读取」。
2. **磁盘快照的读取是懒加载**：进程内第一次用到时读一次，读失败按「没有快照」处理。
3. **磁盘写入放在成功读取之后**，并且只在内存快照真正更新时写（`invalidate()` 触发的刷新也走这条路径）。
4. **快照更新通知在写完内存之后发出**，订阅者读到的是新数据。
5. **写命令执行期间的读取不写快照**：读取开始时如果 `BrewCommandRunner.isRunning()` 为真，本次结果只返回给调用方用于当前显示，不写内存与磁盘快照、不推进新鲜窗口的判定，日志打 `[BrewInstalled] concurrent read skip-save`。理由：写命令执行期间 Cellar 处于中间状态（旧 keg 已移除、新 keg 还没链接完成），这时读到的列表可能少包或缺字段，把这种结果固化下来会让下次冷启动显示错误数据。
6. **写命令期间的读取失败只记日志**：超时、非零退出、输出解析失败都按现有规则处理（不写快照）；有旧快照时页面继续用旧数据，不进入失败态。
7. **写命令结束后一定刷新一次**：`BrewCommandRunner` 结束时调用 `invalidate()`；此时写命令已经结束，这一次读取得到的是稳定状态，会写进快照并通知订阅者。
8. **读与写不互相等待**：没有锁，两者各自独立执行。读取可能在写命令的任何阶段返回，页面按第 5、6 条处理结果。

### 6.3 读写并发的场景确认

| 场景 | 读取（`brew info --json=v2 --installed`） | 写命令 | 页面表现 |
| --- | --- | --- | --- |
| 冷启动，无快照，无写命令 | 执行，写快照 | —— | 首次进入显示加载态，读到后显示列表 |
| 冷启动，无快照，写命令在执行 | 执行（与写命令并发），结果不写快照 | 执行 | 列表显示本次读到的内容（可能是中间状态），写结束后刷新纠正 |
| 有新鲜快照，无写命令 | 不执行 | —— | 立刻显示快照 |
| 有陈旧快照，无写命令 | 后台刷新，写快照 | —— | 先显示旧数据，刷新后更新 |
| 有陈旧快照，写命令在执行 | 后台刷新发起，结果不写快照 | 执行 | 列表保持旧数据，写结束后刷新 |
| 读命令在执行，用户点写命令 | 继续执行，两者互不等待 | 立即启动 | Sheet 立刻出现输出 |
| 写命令在执行，用户点另一个写命令 | —— | 拒绝，返回 `BUSY` | 按钮保持原文案，Toast「已有命令在执行」 |
| 写命令在执行，用户点同一个写命令 | —— | 按钮已显示「执行中…」，点击打开 Sheet | 不重复执行 |
| 写命令结束 | 触发一次刷新，写快照 | 结束，状态更新 | 待更新列表去掉已升级的包；详情页按钮变为「已安装」 |
| 写命令期间读超时（30 秒） | 失败，保留旧快照 | 不受影响 | 页面用旧数据；写结束后刷新 |
| 写命令期间读到中间状态（少包或缺字段） | 结果不写快照 | —— | 页面短暂少一个包，写结束后刷新纠正 |
| 写命令被中断 | 触发一次刷新，写快照 | 结束，状态「已中断」 | 列表回到设备上的实际状态 |
| pc_normal（能力关闭） | 不执行 | 不出现按钮 | 没有本机包三块 |

### 6.4 页面接入

| 页面 | 改动 |
| --- | --- |
| `MinePageVM.loadLocalPackages()` | 有快照时先用快照赋值（`packagesLoading = false`），再调 `loadSets()`（新鲜窗口内立刻返回，超窗时后台刷新）；订阅快照更新后重新赋值 |
| `MinePackagesVM.load(mode)` | 有快照时直接置 `SUCCESS` 并按模式 `pick`（不闪加载态）；没有快照时保持现在的 `LOADING` 流程；订阅快照更新后重新 `pick` |
| `BrewDetailViewModel.load()` | 按 `installedOf(token)` 同步算一次安装状态，再调 `loadSets()` 后重算；页面订阅快照更新后重算 |

所有赋值都写 `state` 的一级属性（`installedCount` / `outdatedPackages` / `updatedPackages` / `filteredPackages`），
与现有写法一致。

### 6.5 详情页的安装状态

`BrewDetailState` 增加一个字段，取值来自快照：

```ts
export enum BrewInstallState {
  /** 还没有快照（冷启动首次读取中），或读取失败 */
  UNKNOWN = 'unknown',
  NOT_INSTALLED = 'not_installed',
  INSTALLED = 'installed',
  OUTDATED = 'outdated',
}
```

- 匹配口径：`BrewInstalledPackage.name === params.token`（本机包的 `name` 是不带 tap 前缀的包名，
  与详情页路由参数里的 token 相同；`fullName` 不参与匹配）。
- `OUTDATED` 直接取快照里的 `outdated` 字段，不做版本比较。
- `UNKNOWN` 与 `NOT_INSTALLED` 的按钮文案都是「安装」：此时点击执行 `brew install`，包已安装时 brew 会打印
  `Warning: … is already installed`，结果同样进入 Sheet，不会造成损坏。

---

## 7. 文案

`features/brewcommon/src/main/resources/{base,en_US,zh_CN}/element/string.json` 增加：

| 资源名 | base / en_US | zh_CN |
| --- | --- | --- |
| `brew_action_upgrade_all` | Upgrade all | 更新全部 |
| `brew_action_running` | Running… | 执行中… |
| `brew_action_interrupt` | Interrupt | 中断 |
| `brew_action_force_kill` | Force stop | 强制终止 |
| `brew_action_close` | Close | 关闭 |
| `brew_cmd_status_running` | Running | 运行中 |
| `brew_cmd_status_interrupting` | Interrupting… | 正在中断… |
| `brew_cmd_status_done` | Finished | 已完成 |
| `brew_cmd_status_interrupted` | Interrupted | 已中断 |
| `brew_cmd_status_failed` | Failed | 执行失败 |
| `brew_cmd_status_timeout` | Timed out | 执行超时 |
| `brew_cmd_omitted_lines` | %d earlier lines omitted | 已省略前 %d 行 |
| `brew_cmd_busy` | Another command is running | 已有命令在执行 |
| `brew_cmd_title_install` | Install %s | 安装 %s |
| `brew_cmd_title_upgrade` | Upgrade %s | 升级 %s |
| `brew_cmd_unavailable` | brew is not available on this device | 设备上找不到可用的 brew |
| `brew_cmd_bad_name` | Package name is not valid | 包名不合法 |

复用已有文案：`brew_action_install`（安装）、`brew_action_upgrade`（升级）、`brew_state_installed`（已安装）、`brew_action_copy`（复制）。

---

## 8. 改动清单

### 8.1 新增

| 文件 | 内容 |
| --- | --- |
| `docs/superpowers/specs/2026-10-04-brew-command-execution-spec.md` | 本文件 |
| `features/pcnative/src/main/ets/util/ShellStreamProbe.ets` | 执行通道自检（流式 / 中断 / 超时 / 退出码） |
| `features/brewcommon/src/main/ets/service/BrewCli.ets` | brew 路径发现、环境前缀、命令行拼装、能力开关 |
| `features/brewcommon/src/main/ets/service/BrewCommandRunner.ets` | 写命令单飞、`isRunningArgs`、轮询、行缓冲、中断与终止、订阅 |
| `features/brewcommon/src/main/ets/model/BrewCommandModels.ets` | `BrewCommandStatus` / `BrewCommandStartResult` / `BrewCommandLine` / `BrewCommandState` / `BrewCommandRequest` |
| `features/brewcommon/src/main/ets/component/BrewCommandSheet.ets` | 执行 Sheet 的内容组件 |

### 8.2 修改

| 文件 | 改动 |
| --- | --- |
| `features/pcnative/src/main/ets/constant/ShellConstants.ets` | 增加 `SHELL_ERR_INTERRUPTED = 1005`、`SHELL_STREAM_POLL_MAX_BYTES`、`SHELL_STREAM_VERIFY`；`SHELL_TIMEOUT_MAX_MS` 改为 30 分钟；`ShellStreamEvent` / `ShellStreamPoll` 两个类 |
| `features/pcnative/src/main/ets/util/ShellUtils.ets` | 增加 `startStream` / `pollStream` / `interruptStream` / `killStream` / `releaseStream` |
| `features/pcnative/src/main/cpp/shell_hook.h` | 任务化接口与新增错误码的约定 |
| `features/pcnative/src/main/cpp/shell_hook.cpp` | 抽出任务结构；一次性执行改为建立在任务之上；中断与终止 |
| `features/pcnative/src/main/cpp/napi_init.cpp` | 五个新函数与数组 / 对象构造 |
| `features/pcnative/src/main/cpp/types/libpcnative/Index.d.ts` | 五个新函数的类型声明 |
| `features/pcnative/Index.ets` | 导出 `SHELL_ERR_INTERRUPTED`、`SHELL_DEFAULT_WORKING_DIRECTORY`、`ShellStreamEvent` / `ShellStreamPoll`、`ShellStreamProbe` |
| `products/pc_acl/src/main/ets/pcability/PcAbility.ets`、`products/pc_normal/src/main/ets/pcability/PcAbility.ets` | `onCreate` 里调用一次 `ShellStreamProbe.run()`（开关默认关） |
| `products/pc_acl/oh-package.json5`、`products/pc_normal/oh-package.json5` | dependencies 各加一行 `"@ohos/pcnative": "file:../../features/pcnative"`：`PcAbility.ets` 要 import 探针，而 ohpm 只把直接依赖软链进模块自己的 `oh_modules` |
| `features/brewcommon/src/main/ets/service/BrewInstalledLoader.ets` | 快照（内存 + 磁盘，只存成功读取）、新鲜窗口、订阅、`invalidate`、`installedOf`、`snapshot`；写命令期间的读取不写快照；读取命令改用 `BrewCli` |
| `features/brewcommon/src/main/ets/constant/BrewConstants.ets` | `BREW_INSTALLED_FRESH_MS`（替换 `BREW_INSTALLED_TTL_MS`）、`BREW_COMMAND_POLL_MS`、`BREW_COMMAND_LOG_MAX_LINES`、`BREW_COMMAND_INTERRUPT_GRACE_MS`、`BREW_COMMAND_TIMEOUT_MS`、快照键名 |
| `features/brewcommon/src/main/ets/util/BrewCommandGenerator.ets` | `installArgs` / `upgradeArgs` / `upgradeAllArgs` / `isSafeName`；展示方法建立在其上 |
| `features/brewcommon/src/main/ets/model/BrewCommandModels.ets` | `BrewCommandState` 增加 `sheetShown` / `resultViewed`；新增 `isBrewCommandEnded()` |
| `features/brewcommon/src/main/ets/model/BrewDetailViewData.ets` | `BrewInfoPageData` 增加 `tap` |
| `features/brewcommon/src/main/ets/util/BrewDetailNormalizer.ets` | 写入 `tap` |
| `features/brewcommon/Index.ets` | 导出 `BrewCli`、`BrewCommandRunner`、命令状态类型、Sheet 组件、`isBrewCommandEnded` |
| `features/brewcommon/src/main/resources/{base,en_US,zh_CN}/element/string.json` | §7 的文案 |
| `features/mine/src/main/ets/view/MinePackagesView.ets` | 底部操作行、订阅命令状态与快照；交出 Sheet，打开动作改为 `openSheet()` |
| `features/mine/src/main/ets/viewmodel/MinePackagesVM.ets` | 快照优先的加载流程、命令启动入口；删除 `interruptCommand()` / `forceKillCommand()` |
| `features/mine/src/main/ets/viewmodel/MinePageVM.ets` | `loadLocalPackages()` 接入快照与订阅 |
| `features/brewdetail/src/main/ets/component/BrewInfoSectionView.ets` | `BrewInstallCommandCard` 标题行增加按钮 |
| `features/brewdetail/src/main/ets/view/BrewDetailView.ets` | 命令启动、快照订阅；交出 Sheet，打开动作改为 `openSheet()` |
| `features/brewdetail/src/main/ets/viewmodel/BrewDetailViewModel.ets`、`viewmodel/BrewDetailState.ets` | `installState` 的计算与更新；`BrewDetailViewModel` 删除 `interruptCommand()` / `forceKillCommand()` |
| `features/brewcommon/src/main/ets/service/BrewCommandRunner.ets` | `openSheet()` / `closeSheet()` / `markViewed()`；`begin()` 复位 `resultViewed`；`finish()` 在 Sheet 展示时置真；删除 `claimEndNotice()` 与 `claimedEndNoticeAt` |
| `features/pcui/src/main/ets/view/PcMainPage.ets` | 全局 Sheet 宿主、结束提示订阅 |
| `features/pcui/src/main/ets/component/CustomSideBar.ets` | 底部 Shell 入口与显示判据 |
| `features/pcui/src/main/resources/{base,en_US,zh_CN}/element/string.json` | `tab_shell` |

### 8.3 不动

- `BrewInstalledParser` 的解析口径、`buildSets()` 的三个集合口径：本轮不碰。
- `MinePackageCard`、`BrewLocalPackageRow`、「我的」首页的三块布局：本轮不碰。
- 生命周期（deprecated / disabled）与安装按钮的联动：不在本轮范围，disabled 的包由 brew 自己在 Sheet 里报错。
- `BrewService` 的详情取数、缓存与回退：本轮不碰。

---

## 9. 验证

```bash
# ① 构建（两个产品都要过）
devecocli build --product default
devecocli build --product pc_normal

# ② 符号进字节码（增量构建会跳过未被引用的文件）
ABC=products/pc_acl/build/default/intermediates/loader_out/default/ets/modules.abc
strings "$ABC" | grep -c BrewCommandSheet
strings "$ABC" | grep -c BrewCommandRunner
strings "$ABC" | grep -c BrewCli
```

执行通道自检（`SHELL_STREAM_VERIFY = true` 后安装运行；探针在启动 5 秒后才开跑，避开界面初始化占用 JS 线程的窗口）：

```bash
devecocli run --device 127.0.0.1:42021 --product default --module pc_acl
devecocli log --device 127.0.0.1:42021 --keyword pcnative --tail 200
```

| 用例 | 命令 | 判据 |
| --- | --- | --- |
| `stream-order` | `for i in 1 2 3; do echo out-$i; echo err-$i 1>&2; sleep 0.2; done` | 事件顺序为 out-1 / err-1 / out-2 / err-2 / out-3 / err-3；`ended=true`；`exitCode=0` |
| `stream-exit-code` | `exit 7` | `ended=true`；`exitCode=7`；`errorCode=0`（既有约定：非零退出用 `exitCode` 表达，`errorCode` 只在通道层失败时有值；`SHELL_ERR_EXIT = -1` 在原生侧没有使用点） |
| `stream-timeout` | `sleep 30`，超时 2000ms | `ended=true`；`errorCode=1003` |
| `stream-interrupt` | `sleep 30`，启动 1 秒后中断 | `ended=true`；`errorCode=1005`；从发出到结束不超过 3 秒 |
| `stream-kill` | `sleep 30`，启动 1 秒后终止 | `ended=true`；`errorCode=1005`；从发出到结束不超过 3 秒 |

真机判据（需要需求方在设备上操作；本轮不做自动界面测试）：

| 步骤 | 期望 | 日志 |
| --- | --- | --- |
| 进「我的 - 待更新」 | 底部出现「更新全部」；筛选切到 Formulae / Casks 时按钮仍在（列表非空时） | —— |
| 点「更新全部」 | Sheet 拉起，命令行为 `brew upgrade --formula`（按筛选）；输出逐行出现 | `[brew-cmd] start args=upgrade --formula` |
| 点「中断」 | 命令在 3 秒内结束，状态显示「已中断」 | `[brew-cmd] interrupt sig=int`、`[brew-cmd] exit error=1005` |
| 关掉 Sheet 再点按钮 | Sheet 重新打开，之前的输出还在 | —— |
| 待更新页 | 升级成功的包从列表消失 | `[BrewInstalled] load ok installed=… outdated=…` |
| 打开一个未安装包的详情页 | 按钮显示「安装」 | `[BrewInstalled] snapshot pref age=…` |
| 打开一个已安装且最新的包的详情页 | 按钮显示「已安装」且点不动 | —— |
| 冷启动直接进「我的」 | 数量立刻显示，不出现转圈 | `[BrewInstalled] snapshot pref age=…` |
| 连点两次「更新全部」 | 第二次时按钮已显示「执行中…」，点击只打开 Sheet，不重复执行 | —— |
| 「更新全部」跑着时在某个包详情页点「安装」 | 弹「已有命令在执行」；设备上不会出现第二条命令 | `[brew-cmd] busy args=install …` |
| 写命令跑着时进入「我的」页 | 列表立刻显示旧快照，不出现新的读取命令 | `[BrewInstalled] snapshot age=…` |
| 写命令跑着时进入没有快照的页面 | 读取与写命令并发执行；列表可能短暂少包；写结束后自动刷新纠正 | `[BrewInstalled] concurrent read skip-save`、`[BrewInstalled] load ok` |
| 写命令期间读取超时 | 页面继续显示旧数据，不出现失败态 | `[BrewInstalled] load failed reason=timeout` |
| 反复进出「我的」与二级页 | 10 分钟内不再出现新的 brew 命令 | `[BrewInstalled] skip fresh age=…` |
| 用 pc_normal 版本重复上述两条 | 待更新页没有按钮；详情页没有安装按钮 | —— |

---

## 10. 风险与兼容

| 项 | 说明 |
| --- | --- |
| 中断的清理动作 | SIGINT 到整个进程组，brew 的 Ruby 层可能先做清理（删除半成品）再退出；宽限期内不强制终止，避免把清理动作打断 |
| 应用进程退出时的命令 | 输出管道随进程关闭，子进程在下次写输出时收到管道错误而结束；本轮不额外做进程清理，验证时确认一次 |
| 30 分钟超时 | 一次升级可能很长；超时后命令被终止，用户可再次执行。实测若接近上限，调整 `SHELL_TIMEOUT_MAX_MS` |
| 不执行 `brew update` | 数据源里有、设备 tap 里没有的包会安装失败，错误原文显示在 Sheet 里；要让命令自动更新 tap 需要另立功能 |
| 磁盘快照的陈旧数据 | 冷启动先显示上一次的列表，后台刷新成功后更新；刷新失败时旧数据继续显示，`readAt` 可供后续加「数据时间」提示 |
| 快照写入全局 Preference store | 一次读取写一次，量级 20–40KB，整份 XML 重写；与搜索历史、数据源注册表同库 |
| `pollStream` 在 JS 线程执行 | 单次上限 256KB、非阻塞读、不做等待；不做这一步就得在原生侧引入线程与跨线程回调 |
| Sheet 的 1000 行上限 | 超出丢弃最旧的行，日志里累计省略数；升级场景实测远低于这个量级 |
| 读取与写命令并发读到中间状态 | 结果不写快照，只用于当前显示；写命令结束后刷新纠正。极端情况下列表会短暂少一个包，详情页按钮短暂显示「安装」 |
| 读取与写命令并发的资源竞争 | 两条 brew 进程各自拉起 Ruby，设备在升级（可能从源码构建）期间还要承担一次读取；读的 30 秒超时可能不够，失败时保留旧快照 |
| 没有等待队列 | 写命令执行期间发起的写请求被拒绝，用户需要等当前命令结束后再点一次 |
| 界面自动化测试 | 本轮不做；界面判据由需求方在真机上确认，命令层与通道层用自检日志覆盖 |
