# 执行 Sheet 全局宿主与侧边栏 Shell 入口 · 设计

> 日期：2026-10-04。状态：待评审。评审通过后由 `writing-plans` 产出实施计划。
> 范围：`features/brewcommon` 的命令状态增加「Sheet 是否展示」与「终态结果是否看过」两个字段；
> 执行 Sheet 的绑定从两个页面移交给 `features/pcui` 的顶层页面；侧边栏底部按状态展示 Shell 入口，
> 入口点击拉起同一个 Sheet。
> 相关文档：[`2026-10-04-brew-command-execution-spec.md`](2026-10-04-brew-command-execution-spec.md)（执行 Sheet 的来源；
> 本文替换它的 Sheet 绑定位置、结束提示归属与改动清单）、
> [`2026-10-04-pc-dual-variant-entry-spec.md`](2026-10-04-pc-dual-variant-entry-spec.md)（pcui 与两个产品）、
> [`../../brew-handover.md`](../../brew-handover.md)。

---

## 1. 目标与成功判据

命令在后台执行时，用户需要一个与当前停留在哪个页面无关的入口，回到命令的实时输出；命令结束之后，
最后那段输出也不应该在没人看过的情况下丢掉。

| # | 判据 | 可观测证据 |
| --- | --- | --- |
| G1 | 命令在后台执行（Sheet 未展示）时，侧边栏底部出现 Shell 入口 | 真机 |
| G2 | 点击入口拉起执行 Sheet，内容与页面上打开的完全一致（同一个状态实例、同一份输出、同一个标题栏菜单） | 真机 |
| G3 | Sheet 正在展示时不出现入口 | 真机 |
| G4 | 命令在后台结束、终态结果还没有在 Sheet 里展示过时，入口继续存在 | 真机；`[brew-cmd] exit code=… error=…` 之后入口仍在 |
| G5 | 终态结果在 Sheet 里展示过之后（Sheet 关闭），入口消失，直到下一条命令启动 | 真机 |
| G6 | 整个应用只有一份执行 Sheet：从入口、包详情页按钮、「更新全部」按钮打开的都是它，不会出现两层叠加的半模态 | 真机 |
| G7 | 命令结束且 Sheet 关闭时弹一条结束提示，只弹一次，且不依赖哪个页面还活着 | 真机；`[brew-cmd] exit` |
| G8 | 两个产品构建通过 | `devecocli build --product default`、`devecocli build --product pc_normal` 输出 `BUILD SUCCESSFUL`，`ERROR` 计数为 0 |

---

## 2. 现状

| 位置 | 现状 |
| --- | --- |
| `features/pcui/src/main/ets/view/PcMainPage.ets` | 应用主页面：`HdsNavDestination` 里放 `HdsSideBar`（侧边栏 + 页签内容）。五个页签内容与所有二级页都在它的内容区里 |
| `features/pcui/src/main/ets/component/CustomSideBar.ets` | 侧边栏：应用图标行 + `ForEach(TABS_LIST)`；没有底部区域，入口表是静态的 |
| `features/brewcommon/src/main/ets/component/BrewCommandSheet.ets` | Sheet 的内容组件（标题栏菜单 + 等宽日志区 + 跟随滚动），入参 `@ObjectLink state` 与 `onInterrupt` / `onForceKill` / `onClose` 三个回调 |
| `features/mine/src/main/ets/view/MinePackagesView.ets:387` | 页面自己 `@State commandSheetShown` 并绑定 `.bindSheet(...)`；订阅命令状态弹结束提示 |
| `features/brewdetail/src/main/ets/view/BrewDetailView.ets:389` | 同上。两个页面可能同时存活，`BrewCommandRunner.claimEndNotice()` 让结束提示只弹一次 |
| `features/brewcommon/src/main/ets/service/BrewCommandRunner.ets` | 单例持有命令状态（`@Observed` 的 `BrewCommandState`）。状态放在单例里，Sheet 因此可以随时关闭与重新打开，输出继续进同一份缓冲 |
| `features/pcui/src/main/resources/base/element/string.json` | 只有五条页签文案，没有 Shell 入口的文案 |

---

## 3. 交互与视觉

### 3.1 侧边栏 Shell 入口

| 项 | 取值 |
| --- | --- |
| 位置 | 侧边栏最下方。页签列表与它之间用 `Blank()` 占住剩余空间，再放一条 `Divider`（`strokeWidth('1px')`、`color($r('sys.color.comp_divider'))`、上下各留 `sys.float.padding_level2` 的间距） |
| 结构 | `Row { SymbolGlyph($r('sys.symbol.code')) + Text($r('app.string.tab_shell')) }` |
| 图标 | `sys.symbol.code`，与「Terminal & Shell」浏览分类用的是同一个符号（`BrewConstants` 里 `'terminal'` 那一项） |
| 尺寸 | 高度 `$r('app.float.side_bar_height')`、左右内边距 `sys.float.padding_level4`、圆角 `sys.float.corner_radius_level4`，与页签项同一套取值 |
| 文字 | `sys.float.Body_L` + `FontWeight.Medium`，与页签项一致 |
| 颜色 | 图标 `sys.color.icon_secondary`、文字 `sys.color.font_tertiary`；悬停底色 `sys.color.interactive_hover`，用 `@State` 记录悬停状态（与页签项同一个做法）。入口没有选中态，页签选中态的颜色不参与 |
| 点击 | `BrewCommandRunner.getInstance().openSheet()`；不改变 `currentIndex`，不切换页签 |

入口只在显示条件成立时渲染，分隔线与它一起出现、一起消失。

### 3.2 入口的显示与消失

判据是一条公式，三个输入都来自命令状态实例：

```
入口显示 = !sheetShown && (status === RUNNING || !resultViewed)
```

| 时刻 | `status` | `sheetShown` | `resultViewed` | 入口 |
| --- | --- | --- | --- | --- |
| 从未执行过命令 | IDLE | false | true | 不显示 |
| 从页面按钮启动命令，Sheet 自动打开 | RUNNING | true | false | 不显示（Sheet 正在展示） |
| 命令执行中，用户关掉 Sheet | RUNNING | false | false | 显示 |
| 点击入口，Sheet 重新打开 | RUNNING | true | false | 不显示 |
| 命令执行中 Sheet 一直展示到结束 | DONE / FAILED / … | true | true | 不显示 |
| 命令在后台结束，结果没被看过 | DONE / FAILED / … | false | false | 显示 |
| 点击入口看过终态行之后关掉 Sheet | DONE / FAILED / … | false | true | 不显示 |
| 中途看过输出，命令仍在后台执行 | RUNNING | false | false | 显示 |
| 中途看过输出，随后命令在后台结束 | DONE / FAILED / … | false | false | 显示，直到点开看过终态 |

`resultViewed` 只在两个时刻置真：命令结束时 Sheet 正展示着（终态行就出现在用户眼前），或者 Sheet 在命令结束之后被打开。
中途打开 Sheet 只登记「过程被看过」这件事，不入终态结果的账：用户要的是那条终态行（退出码、已中断、执行超时），
终端画面从中间看一段，不等于看过命令的结局。

### 3.3 全局执行 Sheet 的宿主

绑定位置移到 `features/pcui/src/main/ets/view/PcMainPage.ets` 的 `HdsNavDestination` 上：

- 它是应用生命周期内一直存在的顶层容器：启动页用 `SplashViewModel.jumpToMainPage()` 的 `replacePage` 把
  `MainPage` 换进 `HdsNavigation`（路由名与页面入口见 `products/pc_acl/src/main/resources/base/profile/router_map.json`），
  启动页随之退出；五个页签内容与所有二级页都在 MainPage 的内容区里，这一个宿主的浮层因此覆盖全部界面；
- 应用只留一份 Sheet。两个页面不再绑定，页面按钮与侧边栏入口都只把 `sheetShown` 置真，由宿主统一响应，
  从任何地方打开的都是同一个半模态；
- Sheet 的选项沿用页面现有的取值（`MaterialUtil.getMaterialOptions<SheetOptions>` + 断点相关的
  `preferType` / `height` / `width`，`showClose: false`），不新增样式口径；
- 两个回调：`onWillAppear` 调 `BrewCommandRunner.markViewed()`（登记终态结果被看过），
  `onDisappear` 调 `BrewCommandRunner.closeSheet()`。

选用 `onDisappear`（退场动画结束后触发）：官方文档写明 `onWillDisappear` 里不允许修改状态变量；
把「Sheet 已关闭」的登记推迟到动画结束，入口也不会在退场动画期间出现，用户不会遇到「点了入口却没有反应」
（半模态的退场动画不支持打断）。下拉关闭、点击遮罩关闭、返回键关闭都会走到这个回调。

宿主的构建代码：

```ets
@State commandState: BrewCommandState = BrewCommandRunner.getInstance().getState();

@Builder
CommandSheetBuilder() {
  BrewCommandSheet({
    state: this.commandState,
    onInterrupt: () => {
      BrewCommandRunner.getInstance().interrupt();
    },
    onForceKill: () => {
      BrewCommandRunner.getInstance().interrupt();
    },
    onClose: () => {
      BrewCommandRunner.getInstance().closeSheet();
    },
  })
}
```

`onInterrupt` 与 `onForceKill` 都是 `interrupt()`：命令层内部已经实现「第一次发 SIGINT，宽限期之后再点升级成
SIGTERM / SIGKILL」，这两个按钮只是同一套时机的两个名字（现有两个页面也是这样接的）。

方案选择：宿主组件上声明式绑定。`UIContext.openBindSheet` 需要调用方自己维护 `ComponentContent` 实例，
创建、更新、销毁都要手动管理；本应用的宿主从启动到退出一直挂在树上，声明式 `bindSheet` 覆盖全部场景，
`SheetOptions` 的写法也与现有页面完全一致。

---

## 4. 状态与接口

### 4.1 `BrewCommandState` 增加两个字段

```ts
/**
 * 执行 Sheet 当前是否展示。
 *
 * 由宿主的 `bindSheet` 绑定，页面按钮与侧边栏入口通过 `BrewCommandRunner.openSheet()` 请求打开。
 * 放在状态对象上：入口的显示判据、结束提示的判断都要读它，而状态对象本来就是三处共用的那一份
 * （`@Observed` 实例，各组件分别用 `@State` / `@ObjectLink` 持有）。
 */
public sheetShown: boolean = false;

/**
 * 当前命令的终态结果是否已经在 Sheet 里展示过。
 *
 * 只在两个时刻置真：命令结束时 Sheet 正展示着；或者 Sheet 在命令结束之后被打开。
 * 命令执行中途打开 Sheet 不入账 —— 那时看到的只是过程。
 */
public resultViewed: boolean = true;
```

`resultViewed` 初始为 `true`：从未执行过命令时入口不出现。两个字段按现有写法在构造函数里赋值
（`sheetShown = false`、`resultViewed = true`）。

### 4.2 `BrewCommandRunner` 的接口变化

```ts
/** 请求展示执行 Sheet。已展示时什么都不做 */
public openSheet(): void;
/** 请求关闭执行 Sheet。宿主在 Sheet 退场动画结束后调用 */
public closeSheet(): void;
/** 登记「终态结果已经被看过」。宿主在 Sheet 开始展示时调用；命令还在执行时什么都不做 */
public markViewed(): void;
```

- `begin()`：`resultViewed = false`；`sheetShown` 保持原值（Sheet 可能正开着，内容会立刻换成新命令的输出）；
- `finish()`：算出终态之后，`if (this.state.sheetShown) { this.state.resultViewed = true; }`；
- `markViewed()`：`status` 是 `IDLE` 或 `RUNNING` 时直接返回，终态时置真；
- 删除 `claimEndNotice()` 与 `claimedEndNoticeAt` 字段。结束提示改由全局宿主弹出，同一时刻只有一个订阅者，
  不需要「领取提示权」这套机制；
- 三个新方法只改状态对象的一级属性，观察这些属性的组件（宿主、侧边栏、页面按钮）自己重渲染，
  不需要额外通知订阅者。

`BrewCommandModels.ets` 增加一个共用的判据函数（宿主与 `markViewed()` 都要用）：

```ts
/** 命令是否已经进入终态（DONE / INTERRUPTED / FAILED / TIMEOUT） */
export function isBrewCommandEnded(status: BrewCommandStatus): boolean;
```

### 4.3 为什么两个字段放在命令状态对象上

`BrewCommandState` 是唯一被三处（顶层宿主、侧边栏、页面按钮）同时持有的可观察对象，
命令起止、Sheet 开关、结果是否看过这三类变化都要让这三处跟着重渲染。放进它的一级属性，
观察规则与现有 `status` / `lines` 完全相同；另开一处全局标记（`AppStorage` 键或再来一个单例）
会多出一套需要同步的关系，而这三处的判据本来就依赖命令状态本身。

---

## 5. 接入改动

### 5.1 顶层页面（`PcMainPage`）

增加 `@State commandState`、`CommandSheetBuilder()`、`bindSheet` 绑定，以及结束提示的订阅：

```ets
@State commandState: BrewCommandState = BrewCommandRunner.getInstance().getState();
private lastCommandStatus: BrewCommandStatus = BrewCommandStatus.IDLE;
private commandListener: () => void = () => {
  this.onCommandEnded();
};

aboutToAppear(): void {
  BrewCommandRunner.getInstance().subscribe(this.commandListener);
}

aboutToDisappear(): void {
  BrewCommandRunner.getInstance().unsubscribe(this.commandListener);
}

/** 命令结束时补一条提示。Sheet 关着才弹 —— Sheet 里已经有状态行了 */
private onCommandEnded(): void {
  const status: BrewCommandStatus = this.commandState.status;
  if (status === this.lastCommandStatus) {
    return;
  }
  this.lastCommandStatus = status;
  if (!isBrewCommandEnded(status) || this.commandState.sheetShown) {
    return;
  }
  Toast.showToast(brewCommandStatusText(this.commandState));
}
```

### 5.2 两个页面交出 Sheet

| 文件 | 改动 |
| --- | --- |
| `features/mine/src/main/ets/view/MinePackagesView.ets` | 删除 `commandSheetShown`、`CommandSheetBuilder()`、`.bindSheet(...)`、`commandListener`、`lastCommandStatus`、`onCommandStateChanged()`，以及 `aboutToAppear` 里的命令状态订阅（快照订阅保留）；`onUpgradeAllClick()` 里两处 `this.commandSheetShown = true` 改成 `BrewCommandRunner.getInstance().openSheet()`；`commandState` 保留（按钮的「执行中…」文案要读它）；`BrewCommandSheet`、`MaterialUtil`、`CustomImmersiveStyle` 的引用按实际使用情况一并清理 |
| `features/brewdetail/src/main/ets/view/BrewDetailView.ets` | 同上；安装状态的快照订阅保留 |
| `features/mine/src/main/ets/viewmodel/MinePackagesVM.ets`、`features/brewdetail/src/main/ets/viewmodel/BrewDetailViewModel.ets` | 删除 `interruptCommand()` 与 `forceKillCommand()` —— 宿主直接调单例，这两个转发方法不再有调用方 |

### 5.3 结束提示的归属

从「谁还活着谁弹，抢到 `claimEndNotice()` 的那一页弹」改成「顶层宿主弹」：宿主从应用启动到退出一直存在，
在结束时看 `sheetShown` 决定弹不弹。行为上的差别只有一处：用户把启动命令的那个二级页返回掉之后仍然会看到提示
（此前由压在它下面的页面接手弹，两个页面都不在时没有人弹）。提示文案仍然是 `brewCommandStatusText(state)`，
与 Sheet 末尾的状态行同源。

---

## 6. 文案

`features/pcui/src/main/resources/{base,en_US,zh_CN}/element/string.json` 增加 `tab_shell`，三个语言都是 `Shell`。

---

## 7. 改动清单

### 7.1 新增

| 文件 | 内容 |
| --- | --- |
| `docs/superpowers/specs/2026-10-04-brew-shell-sidebar-entry-spec.md` | 本文件 |

### 7.2 修改

| 文件 | 改动 |
| --- | --- |
| `features/brewcommon/src/main/ets/model/BrewCommandModels.ets` | `BrewCommandState` 增加 `sheetShown` / `resultViewed`；新增 `isBrewCommandEnded()` |
| `features/brewcommon/src/main/ets/service/BrewCommandRunner.ets` | `openSheet()` / `closeSheet()` / `markViewed()`；`begin()` 复位 `resultViewed`；`finish()` 在 Sheet 展示时置真；删除 `claimEndNotice()` 与 `claimedEndNoticeAt` |
| `features/brewcommon/Index.ets` | 导出 `isBrewCommandEnded` |
| `features/pcui/src/main/ets/view/PcMainPage.ets` | 全局 Sheet 宿主、结束提示订阅 |
| `features/pcui/src/main/ets/component/CustomSideBar.ets` | 底部 Shell 入口与显示判据 |
| `features/pcui/src/main/resources/{base,en_US,zh_CN}/element/string.json` | `tab_shell` |
| `features/mine/src/main/ets/view/MinePackagesView.ets` | 交出 Sheet；打开动作改为 `openSheet()` |
| `features/mine/src/main/ets/viewmodel/MinePackagesVM.ets` | 删除 `interruptCommand()` / `forceKillCommand()` |
| `features/brewdetail/src/main/ets/view/BrewDetailView.ets` | 交出 Sheet；打开动作改为 `openSheet()` |
| `features/brewdetail/src/main/ets/viewmodel/BrewDetailViewModel.ets` | 删除 `interruptCommand()` / `forceKillCommand()` |
| `docs/superpowers/specs/2026-10-04-brew-command-execution-spec.md` | Sheet 绑定位置、结束提示归属、`claimEndNotice`、改动清单四节按本文更新 |

### 7.3 不动

- `BrewCommandSheet` 的组件接口与内容：标题栏菜单、等宽日志区、跟随滚动、状态行文案；
- `BrewCommandRunner` 的轮询节奏、行缓冲与裁剪、单飞、中断升级链；
- 页面按钮的显示条件与文案：「更新全部」/「执行中…」、安装 / 升级 / 已安装；
- pc_normal 版本：`BREW_CLI_ENABLED` 为假时命令无法启动，入口的显示判据永远不成立，不需要额外开关。

---

## 8. 验证

```bash
# ① 构建（两个产品都要过）
devecocli build --product default
devecocli build --product pc_normal

# ② 符号进字节码（增量构建会跳过没有被引用的文件）
ABC=products/pc_acl/build/default/intermediates/loader_out/default/ets/modules.abc
strings "$ABC" | grep -c BrewCommandSheet
strings "$ABC" | grep -c openSheet
strings "$ABC" | grep -c markViewed
strings "$ABC" | grep -c resultViewed
```

真机判据（需要需求方在设备上操作）：

| 步骤 | 期望 |
| --- | --- |
| 在某个包详情页点「安装」，Sheet 自动打开 | 侧边栏没有 Shell 入口 |
| 关掉 Sheet，命令继续执行 | 侧边栏底部出现 Shell 入口，上方有分隔线 |
| 切到别的页签（例如「发现」） | 入口仍在 |
| 点入口 | 在当前页签之上拉起同一条命令的 Sheet，输出完整 |
| 再关掉 Sheet，等命令结束 | 结束提示弹出；入口仍在 |
| 点入口看过终态行（`[已完成 退出码 0]` 之类）后关掉 Sheet | 入口消失 |
| 再点「更新全部」启动第二条命令，然后关掉 Sheet | 入口重新出现 |
| 命令执行中关掉 Sheet，随后停留在「我的 - 待更新」页 | 结束时只弹一次提示 |
| 命令执行中在包详情页点另一个「安装」 | 照旧弹「已有命令在执行」 |
| 用 pc_normal 版本重复其中两条 | 没有入口，也没有安装按钮 |

---

## 9. 风险与兼容

| 项 | 说明 |
| --- | --- |
| 宿主节点必须已经挂在树上 | 命令只能由界面操作触发，宿主从应用启动就挂在页面上，不存在「还没挂上就把 `sheetShown` 置真」的路径 |
| 退场动画期间不出现入口 | 「已关闭」的登记在 `onDisappear`，动画期间 `sheetShown` 仍为真，入口不会在这段时间被点到 |
| 命令恰好停在退场动画期间结束 | `finish()` 读到 `sheetShown` 为真，会把结果记为已看过，入口不出现，最后几行输出看不到。概率极低，接受 |
| 侧边栏高度 | 入口给侧边栏增加了约 48vp 的固定高度（图标行 56vp + 五项页签 + 入口）。窗口高度极小时页签列表会被压缩，与现状一样不给侧边栏做滚动 |
| 页面按钮与入口的状态一致性 | 两处读的是同一个 `BrewCommandState` 实例，不存在两套状态 |
| pc_normal | 命令不可用，`resultViewed` 一直是初始值，入口不出现 |
