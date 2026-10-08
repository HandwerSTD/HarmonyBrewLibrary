# 本机包隐藏「作为依赖安装」的包 · 设计

> 日期：2026-10-05。状态：待评审。评审通过后由 `writing-plans` 产出实施计划。
> 范围：`features/brewcommon` 把 chip 外观抽成可复用组件；`features/mine` 在三个本机包列表页的标题栏加一个 chip，
> 按记住的值隐藏作为依赖安装的包；待更新页「更新全部」的一次依赖提醒；设备上 brew 的更新语义调研。
> 相关文档：[`2026-10-04-brew-installed-packages-spec.md`](2026-10-04-brew-installed-packages-spec.md)（本机包读取与
> `installedAsDependency` 的来源）、[`2026-10-04-brew-command-execution-spec.md`](2026-10-04-brew-command-execution-spec.md)
> （「更新全部」与执行 Sheet）、[`2026-10-04-pc-dual-variant-entry-spec.md`](2026-10-04-pc-dual-variant-entry-spec.md)
> （`BREW_CLI_ENABLED` 开关）、[`../../brew-handover.md`](../../brew-handover.md)。

---

## 1. 目标与成功判据

设备上 85 个已安装 formula 里有 74 个是作为依赖装进来的，三个本机包列表被这些包填满。本轮在三个列表页的
标题栏各加一个 chip，把作为依赖安装的包从当前列表里去掉；三个页面共用一个记住的值。

| # | 判据 | 可观测证据 |
| --- | --- | --- |
| G1 | 已安装 / 待更新 / 已更新三个列表页的标题栏里，三个筛选 chip 的右侧出现「隐藏依赖」chip，靠页面右边缘 | 真机 |
| G2 | chip 选中时列表只显示主动安装的包，未选中时恢复全部 | 真机；设备上三个集合的数量从 85 / 7 / 78 变成 11 / 5 / 6 |
| G3 | 三个页面共用一个值：任一页面打开 chip，另外两个页面进来就是选中状态 | 真机；`[MinePrefs] hide-dependency=true` |
| G4 | 值写进设置存储，应用关闭再打开后保持 | `mine_hide_dependency` 键有值 |
| G5 | 三个集合的不重不漏关系在过滤之后依然成立：已更新 = 已安装 − 待更新 | 11 = 5 + 6 |
| G6 | 「我的」页的已安装数量与两张预览卡不受影响，始终是 85 / 7 / 78 | 真机 |
| G7 | 隐藏打开且提醒还没确认过时，待更新页点击「更新全部」先弹确认框，正文写明会一并更新依赖包 | 真机 |
| G8 | 确认之后命令照常执行（`brew upgrade` / `--formula` / `--cask`），提醒不再出现 | `[brew-cmd] start args=upgrade`；再次点击直接启动 |
| G9 | 两个产品构建通过 | `devecocli build --product default`、`devecocli build --product pc_normal` 输出 `BUILD SUCCESSFUL`，`ERROR` 计数为 0 |

---

## 2. 现状

| 位置 | 现状 |
| --- | --- |
| `features/mine/src/main/ets/view/MinePackagesView.ets` | 三个模式共用这一个页面；chips 行挂在标题栏 `bottomBuilder`（`height: BREW_CHIP_BAR_HEIGHT`，56vp），内容是 `BrewChipBar` 一条横向滚动的 Scroll；`onUpgradeAllClick()` 直接调 `viewModel.startUpgradeAll()`，由 `BrewCommandRunner` 执行 `brew upgrade` 系列参数 |
| `features/brewcommon/src/main/ets/component/BrewChipBar.ets` | chip 栏：`Scroll` + `Row(space)` + `ForEach`。单个 chip 的外观（`MaterialUtil` 修饰器、字号、内边距、圆角、选中配色）写在组件内部的 `ChipBuilder` 里，Formulae / Casks / 本机包三处共用这条栏 |
| `features/brewcommon/src/main/ets/util/BrewInstalledParser.ets:71` | 已经算出 `installedAsDependency`（该 keg 的 `installed_on_request` 取反），`BrewLocalPackageRow` 用它渲染行右侧的「主动安装 / 作为依赖安装」 |
| `features/mine/src/main/ets/util/MinePackagesUtil.ets` | `filter()` 只按 kind（筛选 chips）过滤；`pick()` 按模式选集合 |
| `features/mine/src/main/ets/viewmodel/MinePackagesVM.ets` | `load(mode)` 把 chips 复位到「全部」，`applySets()` 与 `setFilter()` 都调用 `filter()` |
| `features/mine/src/main/ets/viewmodel/MinePageVM.ets` | `applyLocalSets()` 把三个集合的长度与内容直接写进 state，供「我的」页的已安装数量与两张预览卡使用 |

---

## 3. 数据口径

`installedAsDependency` 是现成字段，来源是 `brew info --json=v2 --installed` 输出里最新 keg 的 `installed_on_request`
（见 2026-10-04 本机包读取 spec §6）。本轮不新增字段、不改解析。

cask 条目不受这条过滤影响：cask 的 JSON 投影里没有 `installed_on_request`，解析层把它归为主动安装
（`installedAsDependency = false`），所以隐藏依赖包时 cask 一律保留。

2026-10-05 真机读数（`brew info --json=v2 --installed`）：

| 集合 | 全部 | 主动安装 | 作为依赖安装 |
| --- | --- | --- | --- |
| 已安装 | 85 | 11 | 74 |
| 待更新 | 7 | 5（fd / maven / pandoc / python@3.14 / ripgrep） | 2（cairo / gmp） |
| 已更新 | 78 | 6（bash / bzip2 / git / llvm-gcc-compat / node / tomcat@9） | 72 |

上面这份数不含 cask（当时解析层丢弃 cask 条目）：加上 cask 之后三个集合的条数与该日期的
值不再相等，集合的口径本身没有变化。

过滤规则只有一条：保留 `!installedAsDependency` 的包。不按包名判定，不为三个集合各写一份。

过滤之后「已更新 = 已安装 − 待更新」依然成立：谓词逐条判定，集合的补集关系不变。

---

## 4. 交互与视觉

### 4.1 标题栏右侧的 chip

**结构**：标题栏 `bottomBuilder` 的 builder 由「一条 chip 栏」改成一层 `Row`：

```
Row {
  BrewChipBar({ chips, currentIndex, handleChipClick }).layoutWeight(1)
  Row { BrewChip({ label, selected, onClick }) }
}
```

三个筛选 chip 在左段里横向滚动（宽度不够时它们自己滚），隐藏 chip 常驻右端。

**位置**：靠页面右边缘，右内缩与筛选 chips 的左右留白同源（`brewChipBarHorizontalInset()`，
sm / md / lg 三档是 `padding_level6` / `padding_level12` / `padding_level16`）。标题栏 `bottomBuilder`
的底区是整宽的，这档内缩必须由 chip 自己带 —— 不补它，chip 会贴到窗口右边缘。
页面窄的时候筛选 chips 缩短并滚动，隐藏 chip 的位置不变。

**外观**：与筛选 chip 完全同一套取值 —— 字号 `sys.float.Body_M` + `Medium`，左右内边距 `sys.float.padding_level8`、
上下 `sys.float.padding_level4`，圆角在侧边栏布局用 `sys.float.corner_radius_level4`、其余用 `'50%'`；
选中态 `emphasize` 底 + `font_on_primary` 文字，未选中态 `button_normal` 底 + `font_tertiary` 文字，
两块底色都走 `MaterialUtil.getMaterialModifier` 的 `ULTRA_THIN`（与 `BrewChipBar` 现有实现一致）。

这套取值从 `BrewChipBar` 的 `ChipBuilder` 抽成一个 `BrewChip` 组件，chip 栏内部的每一项与页面右侧这一个
用的都是它 —— 两处的外观只在一处定义，改一处两边同时生效。

**文案**：「隐藏依赖」，不随选中状态变化；当前状态由选中样式表达（与筛选 chips 同一个表达方式）。

**垂直位置**：与筛选 chips 在同一条水平线上。外层 `Row` 的容器给与 chip 栏相同的上下内边距
（top `sys.float.padding_level8`、bottom `sys.float.padding_level5`）再垂直居中。

**与筛选 chips 的间隔**：随断点的 chip 间距（sm `CommonConstants.SPACE_10`、md / lg `SPACE_12`，
与 chip 栏内部的 `chipSpace()` 同值），叠加在 chip 栏自己的右内边距之上。

**点击**：切换选中状态，不弹二次确认。

本机包的三个入口本身受 `BREW_CLI_ENABLED` 控制，pc_normal 下这些页面进不来，chip 随之不出现。

### 4.2 三个页面的状态

| 项 | 取值 |
| --- | --- |
| 状态字段 | `MinePackagesState.hideDependencies: boolean` |
| 进入页面 | `MinePackagesVM.load()` 调 `MinePackagePrefs.hideDependency()` 写入状态，再按它算一次列表 |
| 点击 chip | `MinePackagesVM.setHideDependencies(value)`：写回设置存储、更新状态、重算 `filteredPackages` |
| 过滤点 | `MinePackagesUtil.visible(list, hideDependencies)`，在筛选 chips 之前先过一次依赖过滤；`applySets()` 与 `setFilter()` 都走同一条链 |
| 三页共用 | 只有 `mine_hide_dependency` 一个键：任一页面切换，另外两个页面下一次进来就是同一状态 |
| 空态 | 沿用 `mine_packages_empty`（「本机暂无可显示的包」）：它表达的就是「当前没有可显示的包」，过滤之后同样成立 |

选中之后列表里剩下的都是主动安装的包，`BrewLocalPackageRow` 右侧的「作为依赖安装」在这些行里不会出现。

「更新全部」按钮的显示条件（`filteredPackages.length > 0`）跟着过滤结果走：某个筛选下过滤之后没有包时按钮不出现。

### 4.3 「我的」页不受影响

「我的」页没有这个 chip，`MinePageVM` 与 `MinePageState` 不动：已安装数量、待更新与已更新两张预览卡
始终按全部包计算（85 / 7 / 78）。

隐藏在列表页打开时，列表页的数量会比「我的」页的预览少 —— 这是三个列表页各自带筛选条件、而「我的」页
是总览的直接结果。用户随时可以在列表页把 chip 关掉回到全集。

### 4.4 待更新页的依赖提醒

**判据**：`hideDependency()` 为真且提醒还没有确认过。满足时点击「更新全部」先弹确认框，不直接启动命令。

| 项 | 取值 |
| --- | --- |
| 标题 | 「更新全部」（复用 `app.string.brew_action_upgrade_all`） |
| 正文 | 「已隐藏作为依赖安装的包。更新会一并升级本机全部过时的包，包含这些依赖包。」（`app.string.mine_dep_upgrade_notice`） |
| 左侧按钮 | 「取消」（复用同模块确认框已有的 `app.string.brew_source_cancel`），不做任何事 |
| 右侧按钮 | 「继续更新」（`app.string.mine_dep_upgrade_notice_continue`）：记录提醒已确认，然后走原来的 `startUpgradeAll()` |

**只出现一次**：确认之后写进设置存储，之后点击直接启动命令。chip 关掉再打开也不重复 —— 用户已经知道这条规则。

**记录时机**选在确认按钮的点击上，不在命令启动成功之后：用户确认的是「这条命令会升级哪些包」这件事，
与命令有没有真的跑起来无关。

**「更新全部」执行的命令不变**（`brew upgrade` / `brew upgrade --formula` / `brew upgrade --cask`），
理由见 §6.4。

---

## 5. 设置项的存取

新增 `features/mine/src/main/ets/util/MinePackagePrefs.ets`，两个键走 `PreferenceManager`（单份存储，
与 `brew_installed_snapshot` 同一个 store）：

| 键 | 类型 | 默认 | 含义 |
| --- | --- | --- | --- |
| `mine_hide_dependency` | boolean | false | 三个列表页是否隐藏作为依赖安装的包 |
| `mine_dep_upgrade_notice` | boolean | false | 「更新全部」的依赖提醒是否已确认 |

读写全部经过这个类：`hideDependency()` / `setHideDependency(value)` / `upgradeNoticeAcknowledged()` /
`acknowledgeUpgradeNotice()`。读取失败（存储没有打开、键缺失、JSON 解析失败）一律按默认值处理，
与 `PreferenceManager` 的容错语义一致。

每次写操作打一行日志（`[MinePrefs] hide-dependency=true`、`[MinePrefs] upgrade-notice=true`），
供 §8 对账。

---

## 6. brew 的更新语义（调研）

对象：设备上的 `/storage/Users/currentUser/.harmonybrew`（Homebrew 7.0.6_3，提交 `4ea68b9dc8`）。

### 6.1 `brew update` 不安装也不升级任何包

`Library/Homebrew/cmd/update.sh` 的 `homebrew-update()` 只做三件事：更新 Homebrew 自身与各 tap 的仓库、
下载 API 数据、执行 `brew update-report`（`cmd/update-report.rb`，做仓库迁移与「新增 / 过时」清单的提示）。

函数里唯一与升级有关的位置是第 543 行：带位置参数的 `brew update <name>` 会打印
「Use `brew upgrade <name>` to upgrade formulae; running it instead.」并 `exec brew upgrade <name>`。
无参数的 `brew update` 不进入这个分支。

迁移也不会顺手升级：`Library/Homebrew/migrator.rb:237` 的 `migrate()` 只做目录与链接的更名，
发现迁移后的包过时只打印「as soon as possible please run: brew upgrade」（第 248–256 行）。

### 6.2 `brew upgrade` 会升级作为依赖安装的包

`Library/Homebrew/cmd/upgrade.rb:399`：没有位置参数时
`outdated = Formula.installed.select { |f| formula_outdated?(f) }`；`formula_outdated?`（第 942 行）
只看 `formula.outdated?`。`installed_on_request` 决定的是 `brew autoremove` 能不能删这个包
（`utils/autoremove.rb:98`），以及 `brew reinstall` 与 `brew bundle` 的重装要不要保留原标记
（`reinstall/reinstall.rb:46`、`bundle.rb:109`）；升级清单不按它筛。

真机证据（`HOMEBREW_NO_AUTO_UPDATE=1 brew upgrade --dry-run --formula`，2026-10-05）：

```
==> Would upgrade 7 outdated packages
python@3.14  3.14.7_7 -> 3.14.7_8
cairo        1.18.4_1 -> 1.18.6
maven        3.9.16   -> 3.9.16_1
gmp          6.3.0    -> 6.3.0_1
pandoc       3.11     -> 3.11_1
fd           10.5.0   -> 10.5.0_1
ripgrep      15.2.0   -> 15.2.0_1
```

cairo 与 gmp 是作为依赖安装的，与主动安装的 5 个一起出现在待升级清单里。

安装或升级单个包时，它过时的依赖会被连带升级：`Library/Homebrew/formula_installer.rb:952` 按
`dep_formula.outdated?` 选动作，过时时打印「Upgrading <formula> dependency: <dep>」。

### 6.3 自动更新在应用里是关掉的

`Library/Homebrew/utils/auto-update.sh:21`：`HOMEBREW_NO_AUTO_UPDATE` 非空时 `auto-update()` 直接返回；
`setup-auto-update()` 把 `upgrade` 列入会触发自动更新的命令（第 146–152 行）。应用固定的命令行前缀里有
`HOMEBREW_NO_AUTO_UPDATE=1`（`features/brewcommon/src/main/ets/service/BrewCli.ets` 的 `commandLine()`），
于是：

- 「待更新」列表与「更新全部」看向同一份本机 tap 状态，页面说升哪些就升哪些；
- 不会出现「点一下更新，brew 先联网更新仓库，实际升级的包比列表里多」的情况。

### 6.4 对本轮的影响

隐藏是显示层的过滤，命令不变。打开隐藏之后点「更新全部」，设备上全部过时的包都会被升级，
包含被隐藏的依赖包 —— 这正是 §4.4 那条提醒要提前说明的事。

带包名的 `brew upgrade <name> ...` 不作为「更新全部」的实现：升级这些可见包时，它们的过时依赖仍会被连带升级
（§6.2 第三段），命令变长了却挡不住连带升级，同时失去 brew 自身的 pinned 判定与依赖顺序。

---

## 7. 改动清单

### 7.1 新增

- `features/brewcommon/src/main/ets/component/BrewChip.ets`：单个 chip（文案 + 选中态 + 点击），外观取值从
  `BrewChipBar.ChipBuilder` 原样搬过来。
- `features/mine/src/main/ets/util/MinePackagePrefs.ets`：两个设置项的读写与日志。

### 7.2 修改

- `features/brewcommon/src/main/ets/component/BrewChipBar.ets`：内部每一项改用 `BrewChip`；左右内缩改用
  `brewChipBarHorizontalInset()`；chip 间距不动。
- `features/brewcommon/src/main/ets/constant/BrewConstants.ets`：新增 `brewChipBarHorizontalInset()`
  （chip 栏左右内缩的唯一来源，栏内 chips 与栏右侧的常驻 chip 共用）。
- `features/brewcommon/Index.ets`：导出 `BrewChip` 与 `brewChipBarHorizontalInset`。
- `features/mine/src/main/ets/util/MinePackagesUtil.ets`：新增 `visible(list, hideDependencies)`；
  `filter()` / `pick()` 不动。
- `features/mine/src/main/ets/viewmodel/MinePackagesState.ets`：新增 `hideDependencies: boolean`。
- `features/mine/src/main/ets/viewmodel/MinePackagesVM.ets`：`load()` 读设置；新增 `setHideDependencies(value)`；
  `applySets()` 与 `setFilter()` 先过 `visible()`；新增 `needsDependencyUpgradeNotice()` 与
  `acknowledgeDependencyUpgradeNotice()`。
- `features/mine/src/main/ets/view/MinePackagesView.ets`：`ChipBarBuilder` 改成 §4.1 的 `Row` 并加隐藏 chip；
  `onUpgradeAllClick()` 按 §4.4 弹一次确认框。
- `features/mine/src/main/resources/{base,zh_CN,en_US}/element/string.json`：新增三条（见下表）。
- `README.md`、`README.en.md`、`docs/brew-handover.md`：本机包一节补 chip 与 brew 更新语义的说明。

新增文案：

| 名称 | base / en_US | zh_CN |
| --- | --- | --- |
| `mine_hide_dependency` | Hide dependencies | 隐藏依赖 |
| `mine_dep_upgrade_notice` | Packages installed as dependencies are hidden. Upgrading also upgrades every outdated package on this device, including those hidden dependencies. | 已隐藏作为依赖安装的包。更新会一并升级本机全部过时的包，包含这些依赖包。 |
| `mine_dep_upgrade_notice_continue` | Upgrade anyway | 继续更新 |

### 7.3 不动

- `MinePageVM.ets`、`MinePageState.ets`、`MinePackageCard.ets`：「我的」页的数量与预览按全部包计算（§4.3）。
- `BrewInstalledParser.ets` 与 `BrewModels.ets` 的 `installedAsDependency`：字段与来源都不变。
- `BrewCommandGenerator.upgradeAllArgs()` 与 `BrewCommandRunner`：命令与执行路径不变。
- `BrewLocalPackageRow`：行右侧仍显示「主动安装 / 作为依赖安装」。
- `MinePackagesState.filterIndex` 与 `MinePackagesUtil.filter()`：筛选 chips 的语义不变。

---

## 8. 上机验证顺序

1. 构建：`devecocli build --product default` 与 `devecocli build --product pc_normal`，`ERROR` 计数为 0。
2. chip 位置：三个列表页的标题栏里，隐藏 chip 在筛选 chips 右侧、靠页面右边缘；窄窗口下筛选 chips 滚动而它不动。
3. chip 外观：与筛选 chip 同高、同字号、同圆角；未选中是浅底，选中是强调底色。
4. 三个页面共用一个值：在已安装页打开 chip，进待更新页同样是选中状态。
5. 过滤：选中时三个页面分别是 11 / 5 / 6，未选中时是 85 / 7 / 78。
6. 不重不漏：选中时待更新 5 + 已更新 6 = 已安装 11。
7. 「我的」页：无论 chip 状态，已安装数量与两张预览卡都是 85 / 7 / 78。
8. 持久化：关闭应用重开，chip 与三个数量保持。
9. 提醒：在待更新页打开 chip 后点「更新全部」，出现确认框；点「取消」不执行任何命令；
   点「继续更新」启动 `brew upgrade`（`[brew-cmd] start args=upgrade`），Sheet 里能看到 cairo、gmp 的升级；
   再点一次不再出现确认框。
10. 设置日志：`[MinePrefs]` 行与 chip 状态一致。

---

## 9. 已知未知

| 项 | 说明 |
| --- | --- |
| 隐藏 chip 与筛选 chips 的可见间距 | 由 chip 栏自己的右内边距（随断点 level6 / level12 / level16）叠加 chip 间距得出，上机看间距是否过大，再决定要不要去掉其中一层 |
| 窄窗口下的宽度分配 | 最小窗口 1080 × 608 下，四个 chip 加起来的宽度是否够用；不够时筛选 chips 会横向滚动，隐藏 chip 的位置不变 |
