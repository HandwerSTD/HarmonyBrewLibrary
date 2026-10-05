# 包详情页底部主操作栏 · 设计

> 日期：2026-10-05。状态：待评审。评审通过后由 `writing-plans` 产出实施计划。
> 范围：`features/brewdetail` —— 把包详情页的主操作按钮（安装 / 升级 / 已安装）从「安装命令」卡片的标题行挪出来，
> 变成页面底部的一条悬浮操作栏：白色渐变模糊背板 + 宽度占内容区 60% 的强调按钮；内容区底部为它留出滚动空间。
> 相关文档：`../../brew-api-design.md` §5.3（分区清单）、`../../hds-titlebar-blur.md`（标题栏模糊与内容让位口径）、
> `2026-10-04-brew-command-execution-spec.md` §3.2（按钮文案与可点性的来源）、`../../brew-handover.md` §6.2。

---

## 1. 现状

| 位置 | 现状 |
| --- | --- |
| `features/brewdetail/src/main/ets/view/BrewDetailView.ets:202` | `BrewInstallCommandCard({ command, showAction: commandReady, actionLabel, actionEnabled, onAction })` —— 主操作按钮由这张卡片渲染 |
| `features/brewdetail/src/main/ets/component/BrewInfoSectionView.ets:111` | 卡片标题行 = 「安装命令」+ `Blank()` + 按钮；按钮是 `comp_background_tertiary` 底的次要按钮 |
| 页面容器 | 内容是一个 `Scroll`（没有 `Scroller`）；标题栏模糊由 HDS 自己识别滚动容器，页面没有 `bindToScrollable` |
| 内容让位 | 内层 `Column` 的 `margin.top` = `brewContentTopInset(...)`、`margin.bottom` = `naviIndicatorHeight + SPACE_24` |
| 按钮行为 | `installActionLabel()` / `installActionEnabled()` / `onInstallActionClick()`；三种状态与「执行中…」重开 Sheet 的逻辑本轮不动 |

参考图（AppGallery 包详情页截图）里量到的值：底板高度约 47vp、按钮约 425×38vp（占窗口宽度的 40.4%）、按钮圆角约 7vp、
底板在页面底色之上加了一层约 20% 白色的蒙层，蒙层上沿没有渐变，是一条圆角矩形的边（过渡只有 3~4 物理像素的锯齿宽度）。

---

## 2. 成功判据

| # | 判据 | 可观测证据 |
| --- | --- | --- |
| G1 | 详情页底边出现一条白色渐变模糊背板：内容压到它下面时被模糊，背板上沿是一条渐变的过渡带 | 真机截图（滚到压住操作栏） |
| G2 | 强调按钮的宽度 = 内容区宽度的 60%，且不超过 448vp；水平居中 | 真机截图；`[BrewActionBar]` 行 |
| G3 | 「安装命令」卡片里不再有按钮，命令文本与「复制」按钮保持原样 | 真机截图 |
| G4 | 按钮的四种状态（安装 / 升级 / 已安装 / 执行中…）与点击行为跟现在逐字相同 | 真机对照；`[brew-cmd] start args=…` |
| G5 | 滚到最后时，最后一张卡片完整停在操作栏上方，不被背板盖住 | 真机滚动到底 |
| G6 | 顶部标题栏的动态模糊不变 | `[BrewTitleBar], blur ramp: page=detail start=0 end=104 ramp=104 material=…` 仍在；静止时滚动容器自报偏移量为 0 |
| G7 | 设备上 brew 能力关闭（pc_normal）或包名通不过命令行校验时，页面与现在完全相同（没有操作栏、底部留白不变） | pc_normal 真机 |
| G8 | 两个产品构建通过 | `devecocli build --product default`、`devecocli build --product pc_normal` 输出 `BUILD SUCCESSFUL`，`ERROR` 计数为 0 |

---

## 3. 技术方案（调研结论）

### 3.1 `HdsNavDestination` 没有底部渐变渐隐

| 查证对象 | 结论 |
| --- | --- |
| `HdsNavDestination` 的底部能力 | 只有 `toolbarConfiguration(toolbarParam, NavigationToolbarOptions)` + `hideToolBar()`。`NavigationToolbarOptions` 的全部字段是 `backgroundColor`、`backgroundBlurStyle`、`backgroundBlurStyleOptions`、`backgroundEffect`、`barStyle`、`hideItemValue`、`moreButtonOptions` —— 只有均匀的背板模糊，没有任何随滚动变化或沿高度渐变的参数 |
| NavDestination 的工具栏能否压在内容之上 | 不能。`BarStyle` 的说明写明「标题栏或工具栏的布局样式。NavDestination 的工具栏不支持设置该属性」，即 STACK 只对 `HdsNavigation` 的工具栏有效；`HdsNavDestination` 的工具栏只能占内容区下方的一行 |
| 标题栏那套渐变有没有底部版本 | 没有。`TitleBarStyleOptions.scrollEffectOpts`（HDS）与 ArkUI 26.0.0 新增的 `NavigationTitleOptions.scrollEffectOptions` 都只作用于标题栏 |

底部渐变模糊这条能力在导航组件里不存在，按需求改用 HdsTabs 的页签栏渐变模糊。

### 3.2 用单页签 `HdsTabs` 的页签栏承载操作栏

HdsTabs 的页签栏自带渐变模糊（指南「设置页签栏的模糊样式」）。三个条件同时满足就生效：页签栏在容器底部
（`barPosition(BarPosition.End)` + `vertical(false)`）、页签栏叠加在内容之上（`barOverlap(true)`）、
页签栏自己的模糊关掉（`barBackgroundBlurStyle(BlurStyle.NONE)`）。模糊的颜色与高度由
`barBackgroundStyle({ maskColor, maskHeight })` 给出，`maskHeight` 不写时默认是页签栏高度 + 32vp（`HdsTabsBackgroundStyle` 声明里写明的默认值）。

页面结构因此改成一个只有一页的 `HdsTabs`：原来的 `Scroll` 进 `TabContent`（`barOverlap` 让内容压到页签栏下面并被模糊），
页签栏的自定义构建器就是这条操作栏：

```ets
HdsTabs({ barPosition: BarPosition.End, index: 0 }) {
  TabContent() {
    Scroll(this.scroller) { /* 原内容（内层 Column） */ }
  }
  .tabBar(this.ActionBarBuilder())          // 页签栏内容 = 唯一的主操作按钮
}
.scrollable(false)                          // 只有一个页签，不需要左右滑动
.vertical(false)
.barOverlap(true)
.barHeight(this.actionBarHeight())          // 56vp + naviIndicatorHeight
.divider({ mode: DividerMode.NONE })        // 关掉跟手渐变的分割线
.barBackgroundBlurStyle(BlurStyle.NONE)     // 关掉页签栏自带的 COMPONENT_THICK，让渐变模糊生效
.barBackgroundStyle({
  maskColor: $r('app.color.brew_action_bar_mask'),
  maskHeight: this.actionBarMaskHeight(),  // 栏高 + 32vp
})
.animationDuration(0)
.width('100%')
.height('100%')
```

每一个写法的用途：

| 写法 | 用途 |
| --- | --- |
| `index: 0` 固定、不要 controller | 只有一页，不存在切换；`scrollable(false)` 同时挡住左右滑动手势 |
| `divider({ mode: DividerMode.NONE })` | 默认的 `FOLLOW_SCROLL` 会在内容滚过页签栏时画一条分割线，与渐变背板冲突（`features/pcui` 的侧边栏页签也是这么关的） |
| `barBackgroundBlurStyle(BlurStyle.NONE)` | `barOverlap(true)` 会把页签栏的默认模糊设成 `COMPONENT_THICK`；指南写明渐变模糊要求页签栏自身的模糊为 `NONE` |
| `animationDuration(0)` | 页签栏上的点击会走一次 Tabs 的切换逻辑；单页签下这次切换没有任何可见效果，把动效时长设为 0 |
| 按钮放在 `tabBar` 的自定义构建器里 | 页签栏高度、模糊区间与按钮中线只需要一个来源（`barHeight`），不会出现「背板 56vp、按钮按另一个数字摆」的错位。FAQ `faqs-arkui-1072` 场景三写明自定义构建器里的子组件能收到自己的点击事件（点空白处才走 Tabs 自带的切换逻辑），按钮的点击不会被页签吞掉 |

`HdsTabs` 嵌进 `HdsNavDestination` 之后，标题栏的动态模糊不能再靠 HDS 自动识别滚动容器（FAQ `faqs-arkui-1095` 场景二正是这个问题），
必须显式绑定：页面新增一个 `Scroller` 交给 `Scroll`，并在 `HdsNavDestination` 上写 `.bindToScrollable([this.scroller])`。
只有一页，那篇 FAQ 里的 `onWillHide` 存档与 `onAnimationStart` 恢复滚动位置都不需要。

### 3.3 底部留白用 `Scroll.contentEndOffset`

`contentEndOffset` 与 `contentStartOffset` 定义在「滚动组件通用接口」里（API 22 起），`ScrollAttribute` 继承
`ScrollableCommonMethod`，所以 `Scroll` 可以用。它的语义是「内容末尾与显示区域边界保留指定距离」，只在内容末尾加空白。

顶部让位用内层 `Column` 的 `margin.top`，与 `hds-titlebar-blur.md` 记的口径一致：`contentStartOffset` 会把滚动坐标系原点前移
（本机实测静止时自报偏移量 −56vp），而 HDS 的模糊区间起点只能是 0，于是留下长度等于该偏移量的空行程。
`contentEndOffset` 只在末尾加空白，不移动坐标系原点，底部可以让它负责。

判据：底部留白生效（内容能多滚出留白那么多），且静止时 `scroller` 自报的偏移量仍是 0。

---

## 4. 取值与样式

### 4.1 操作栏

| 项 | 取值 | 依据 |
| --- | --- | --- |
| 栏高 | 56vp（`ACTION_BAR_HEIGHT`），设备有底部导航条时再加 `naviIndicatorHeight` | 与 `CommonConstants.NAVIGATION_HEIGHT` / `TAB_BAR_HEIGHT` 同值，和标题栏同高；按钮上下各留 8vp |
| 背板蒙层颜色 | `$r('app.color.brew_action_bar_mask')`：浅色 `#33FFFFFF`、深色 `#33000000` | 参考图实测约 20% 白色的蒙层；深色用同一档透明度的黑色 |
| 渐变长度 | 32vp（`ACTION_BAR_BLUR_RAMP`），`maskHeight` = 栏高 + 32 | HDS 渐变模糊的默认长度就是页签栏高度 + 32vp；显式写出来，让这个数字在代码里可见 |
| 栏的水平范围 | 满宽（`HdsTabs` 的宽度） | 页签栏本身满宽，与标题栏那层模糊同一口径 |

### 4.2 按钮

| 项 | 取值 | 依据 |
| --- | --- | --- |
| 宽度 | 内容区宽度的 60%（`ACTION_BUTTON_WIDTH = '60%'`），上限 448vp（`ACTION_BUTTON_MAX_WIDTH`） | 需求给定；构建器的根 `Row` 左右都用本页的 `contentLeft()`（本页左右同值，与 `Scroll` 内层 Column 的左右内缩同源），按钮的 60% 因此是内容区宽度的 60%。上限 448vp 由参考图估算：623px ↔ 328vp、851px ↔ 448vp，同一比例下按钮高度 76px ↔ 40vp |
| 高度 | 40vp（`ACTION_BUTTON_HEIGHT`） | 栏高 56vp 减上下各 8vp |
| 圆角 | 系统默认（`ButtonType.ROUNDED_RECTANGLE`，本机实测渲染约 6vp），不设 `borderRadius` | 需求给定：不用自定义圆角 |
| 文字 | `$r('sys.float.Body_L')` + `FontWeight.Medium` | 主操作按钮的字号 |
| 底色与文字色 | 可点时 `$r('sys.color.ohos_id_color_emphasize')` + `$r('sys.color.font_on_primary')`；「已安装」（不可点）时 `$r('sys.color.comp_background_tertiary')` + `$r('sys.color.font_tertiary')` | 强调蓝用项目已有的强调色 token；「已安装」表达的是状态，沿用现在的次要配色 |
| 底部内边距 | 构建器的根 `Row` 加 `padding.bottom = naviIndicatorHeight` | 有底部导航条时按钮在栏内上移，不压在导航条上 |

按钮状态（文案与可点性沿用 `2026-10-04-brew-command-execution-spec.md` §3.2，逐字不变）：

| 快照状态 | 文案 | 底色 | 可点 | 点击 |
| --- | --- | --- | --- | --- |
| 未安装 / 快照未知 | 安装 | 强调蓝 | 是 | `brew install <name>` |
| 已安装且有新版本 | 升级 | 强调蓝 | 是 | `brew upgrade <name>` |
| 已安装且已是最新 | 已安装 | 次要底 | 否 | —— |
| 本包命令正在执行 | 执行中… | 强调蓝 | 是 | 重新打开执行 Sheet |

渲染条件不变：`commandReady`（`BrewCli.isEnabled()` 且 `token` / `tap` 都通过 `BrewCommandGenerator.isSafeName`）为假时
整条操作栏不出现，页面回到现在的样子。

### 4.3 内容让位

内层 `Column` 的 `margin.bottom` 不变（仍是 `naviIndicatorHeight + SPACE_24`，它已经包含了底部导航条的让位），
`Scroll` 再补上操作栏占的那一段：

```ets
.contentEndOffset(this.detailState.commandReady ? ACTION_BAR_HEIGHT : 0)
```

两段之和即内容末尾与窗口底边的距离：有操作栏时是 24 + 56（操作栏上沿到最后一张卡片 24vp），
设备有底部导航条时，导航条那一段由操作栏自己的高度覆盖（`barHeight` 与按钮的 `padding.bottom` 都加 `naviIndicatorHeight`），不会重复计算。
没有操作栏时这一段是 0，与现在完全一致。

---

## 5. 改动位置

| 文件 | 改动 |
| --- | --- |
| `features/brewdetail/src/main/ets/component/BrewInfoSectionView.ets` | `BrewInstallCommandCard` 去掉按钮：入参只剩 `command`，标题行的 `Row` + `Blank()` + `Button` 收成一个 `Text` |
| `features/brewdetail/src/main/ets/view/BrewDetailView.ets` | 新增 `scroller`、`ActionBarBuilder()`（按钮）、`actionBarHeight()` / `actionBarMaskHeight()`；成功态按 `commandReady` 分成「`HdsTabs` 包一层 `ContentBuilder()`」与「直接放 `ContentBuilder()`」两条；`HdsNavDestination` 上补 `bindToScrollable`；新增判据日志 |
| `features/brewdetail/src/main/resources/base/element/color.json` + `dark/element/color.json` | 新增 `brew_action_bar_mask`（浅色 `#33FFFFFF`、深色 `#33000000`） |
| `docs/superpowers/specs/2026-10-04-brew-command-execution-spec.md` §3.2 | 「位置」一段改成底部操作栏（文案表与点击行为不动） |
| `docs/brew-api-design.md` §5.3 分区 2 | 「主操作：命令 + 复制」与「主操作按钮在底部操作栏」分开写 |
| `docs/hds-titlebar-blur.md` §6 | 包详情页那一行的让位说明补上底部操作栏 |

---

## 6. 判据日志

操作栏渲染时打一行（每个页面实例一行，取值直接写进格式串，不需要探针）：

```
[BrewActionBar], action bar: height=56 mask=88 ramp=32 button=60% max=448 navi=0 breakpoint=lg
```

`mask` − `height` 必须等于 `ramp`（32），`height` 必须等于 56 + `navi`；对不上说明两个高度用了不同的来源。

---

## 7. 验证

构建：

```
devecocli build --product default
devecocli build --product pc_normal
```

真机（pc_acl，设备上 brew 可用）：

| 判据 | 怎么量 |
| --- | --- |
| G1 / G2 / G3 | 打开任一 formula 详情页截图；把内容滚到压住操作栏再截一张，对比背板上沿是否有模糊拖影与渐变过渡 |
| G4 | 对未安装的包点「安装」看 Sheet 与 `[brew-cmd] start args=install …`；对已安装且有新版本的包看按钮是否为「升级」；对已是最新的包看按钮是否为「已安装」且不可点 |
| G5 | 滚到底截图，看最后一张卡片是否完整位于背板上方 |
| G6 | `devecocli log --follow --keyword "BrewTitleBar"` 看到 `page=detail start=0 end=104`；滚动时标题栏仍渐显模糊 |
| G7 | 装 pc_normal 打开同一页面：没有操作栏，底部留白与改动前一致 |

---

## 8. 范围外

- 按钮的文案、可点性、命令参数与执行 Sheet 的行为。
- 「我的 - 本机包」页的「更新全部」按钮（它在内容区底部的一行里，不是悬浮层）。
- 标题栏的模糊区间与顶部让位量。
- 详情页失败态与「未找到」态的布局。
