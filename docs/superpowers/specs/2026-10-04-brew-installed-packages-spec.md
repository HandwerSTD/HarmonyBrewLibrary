# brew 本机包读取方案

> 日期：2026-10-04。状态：待实施。
> 范围：新增通用 native 能力模块 `features/pcnative`（含执行通道探针）；在 `features/brewcommon`
> 增加本机包读取层；`features/mine` 的 UI 与状态机已经接好，本次只改数据来源。
> 本机不支持 cask，方案与验证都以 formula 为对象。

---

## 1. 目标与背景

「我的」页的本机包三块（已安装入口 + 待更新卡片 + 已更新卡片）与「本机包」二级页在 2026-10 的
mock 下线提交里转成了空态保壳：`MinePackagesUtil.loadSets()` 恒返回空集合。本次接上真实设备。

设备侧已经有一个可用的 Homebrew 安装（harmonybrew 移植版）：

```
/storage/Users/currentUser/.harmonybrew/
├── Homebrew/                      Homebrew 源码仓库（Ruby）
│   ├── bin/brew                   zsh 脚本，brew 命令入口
│   └── Library/Homebrew/          命令实现 + vendor/portable-ruby-arm64-ohos
├── Cellar/<name>/<version>/       85 个 formula，141 个已安装版本目录
├── Caskroom/                      空，本机不支持 cask
├── bin/                           符号链接到 Cellar 各包的 bin
├── opt/ include/ lib/ share/ etc/ sbin/ var/
```

`bin/brew` 是指向 `Homebrew/bin/brew` 的符号链接；按脚本自身的规则，`HOMEBREW_PREFIX` 就是
符号链接所在目录的上一级，即 `/storage/Users/currentUser/.harmonybrew`。

UI 侧现状（已经写好、只等数据）：

| 位置 | 现状 |
| --- | --- |
| `MineView.ets:74` | 发 `MineEventType.LOAD_LOCAL_PACKAGES` 事件 |
| `MinePageVM.ets:245` | `loadLocalPackages()` 调 `MinePackagesUtil.loadSets()`，三个集合写进 state |
| `MinePageVM.ets:48` | `MINE_SHOW_LOCAL_PACKAGES = false`，整块不渲染 |
| `MinePackagesVM.ets:66` | 二级页 `load(mode)` 同样调 `loadSets()` + `pick()` |

---

## 2. 取数方式

用 `brew info --json=v2 --installed` 一条命令取回全部本机包。依据都从设备上的 Homebrew 源码读出：

1. `Library/Homebrew/cmd/info.rb:124`：`--json` 走 `print_json`；`:v2` 分支在 `--installed` 下返回
   `{"formulae": [...], "casks": [...]}`，来源是 `Formula.installed` 与 `Cask::Caskroom.casks`。
2. `formula.rb:3170`：每个 formula 的 `installed` 数组由 `installed_kegs` 生成，字段为
   `version` / `used_options` / `built_as_bottle` / `poured_from_bottle` / `time` /
   `runtime_dependencies` / `installed_on_request`。
3. formula 条目顶层还带 `outdated` / `pinned` / `linked_keg` / `versions.stable`，
   所以**不需要**再跑一条 `brew outdated`，待更新集合直接从这一份结果派生。

`brew list --json` 不使用：`list.rb:95` 要求必须配 `--versions`、不接受具名参数，只由 fast Bash
路径提供并依赖 `jq`，信息还比 `info --json=v2` 少。

---

## 3. 新模块 `features/pcnative`

通用 native 能力模块，与 brew 无关，任何 feature 都能依赖。brew 语义不进来。

```
features/pcnative/
├── Index.ets                                  对外导出
├── oh-package.json5                           @ohos/pcnative
├── build-profile.json5                        externalNativeOptions 指向 CMakeLists
├── hvigorfile.ts
├── src/main/module.json5                      HAR 模块声明
├── src/main/ets/util/ShellUtils.ets           ArkTS 侧唯一入口（NAPI 调用）
├── src/main/ets/util/ShellProbe.ets           执行通道自检（见 §4）
└── src/main/cpp/
    ├── CMakeLists.txt
    ├── napi_init.cpp                          NAPI 模块注册与参数校验
    ├── shell_runner.cpp                       执行封装：超时、输出采集、错误映射
    └── shell_hook.cpp                         调用平台侧执行能力的唯一位置
```

构建配置：`build-profile.json5` 的 `buildOption.externalNativeOptions.path` 指向
`./src/main/cpp/CMakeLists.txt`；`CMakeLists.txt` 里 `add_library(pcnative SHARED ...)` 并链接
`libace_napi.z.so`；根 `build-profile.json5` 的 `modules` 数组新增
`{"name": "pcnative", "srcPath": "./features/pcnative"}`。

### 3.1 ArkTS 接口

```ts
export interface ShellResult {
  ok: boolean;        // 命令是否正常退出
  exitCode: number;   // 正常退出时的退出码，异常时为 -1
  stdout: string;
  stderr: string;
  errorCode: number;  // 0 = 无错误
}

export class ShellUtils {
  /** 同步执行。禁止在主线程调用 */
  static runSync(command: string, timeoutMs: number): ShellResult;

  /** 异步执行。页面路径用这一个 */
  static run(command: string, timeoutMs: number): Promise<ShellResult>;

  /** `command -v <name>` 判定，供探测用 */
  static exists(name: string): boolean;

  /** 平台执行能力是否可用 */
  static available(): boolean;
}
```

错误码分段，调用方按段判定：

| 值 | 含义 |
| --- | --- |
| `0` | 成功 |
| `-1` | 命令非零退出（`exitCode` 里有真实退出码） |
| `1001` | 平台执行能力不可用 |
| `1002` | 启动失败 |
| `1003` | 超时，进程已终止 |
| `1004` | 输出超过上限（默认 8 MB），进程已终止 |

### 3.2 C++ 侧

- `napi_init.cpp` 注册模块与四个函数，参数用 `napi_get_value_string_utf8` 读取，返回值构造为 JS
  对象；参数非法时 `napi_throw_type_error`。
- `shell_runner.cpp` 负责异步执行（`napi_create_async_work`）、超时终止、stdout / stderr 分别
  采集与上限截断。所有失败都收敛成 `ShellResult`，不向 ArkTS 抛异常。
- `shell_hook.cpp` 是平台执行能力的唯一调用点，函数签名为
  `int run_command(const std::string &cmd, int timeout_ms, std::string &out, std::string &err, int &exit_code)`。
  实现依赖设备侧提供的执行通道，这一层的代码不进入版本库的其余部分。

### 3.3 执行通道的契约

探针与 brew 层都按这份契约写，通道实现方按同一份契约提供能力。

| 编号 | 契约 |
| --- | --- |
| C1 | 接受一整条命令行字符串，交给系统的 shell 解释，因此管道、重定向、`&&`、命令替换都可用 |
| C2 | 返回值区分三种结局：正常退出（带退出码）、启动失败、超时；超时后进程被终止 |
| C3 | stdout 与 stderr 分别采集，不混流 |
| C4 | 子进程继承调用方设置的环境变量 |
| C5 | 输出总量有上限，超过则终止并报错，不做无上限缓冲 |
| C6 | 可以执行给定绝对路径的可执行文件（不要求它在 PATH 里） |
| C7 | 可以读取设备上应用沙箱之外的文件（`.harmonybrew` 在用户目录下） |

C6 与 C7 是这套方案成立的前提：C6 不成立则 brew 起不来，C7 不成立则 brew 即使起来也读不到
`Cellar`。两者都由探针验证，见 §4。

---

## 4. 执行通道探针

探针是实施的第一步：它通过之后才写 brew 层。全部用例都遵循 `BrewSourceDiagnostics` 的做法 ——
一条常量开关 + 一组固定格式的判据行，不用 ohosTest。

- 开关：`SHELL_VERIFY: boolean`（`features/pcnative/src/main/ets/constant/ShellConstants.ets`），
  默认 `false`。
- 输出：`Logger.info` 打一行，tag `[pcnative]`，格式
  `verify <用例名> ok=<bool> <明细>`。`grep '\[pcnative\] verify' | grep 'ok=false'` 即可对账。
- 用例之间有依赖：C1 失败即中止整轮（后面的用例都要先能执行命令），其余用例互相独立。
- 探针失败不改变任何页面状态，只打日志。

### 4.1 用例

| 用例 | 命令 | 期望 | 验证的契约 |
| --- | --- | --- | --- |
| `available` | —— | `ShellUtils.available()` 为真 | 通道存在 |
| `echo` | `echo probe-ok` | 退出码 0，stdout 去空白后为 `probe-ok` | C1 |
| `pipe` | `echo a b c \| wc -w` | stdout 去空白后为 `3` | C1 |
| `exit-code` | `exit 7` | `ok=false`，`exitCode=7` | C2 |
| `stderr` | `echo out-ok; echo err-ok 1>&2` | stdout 只含 `out-ok`，stderr 只含 `err-ok` | C3 |
| `env` | `SHELL_PROBE_VAR=probe-env sh -c 'printf %s "$SHELL_PROBE_VAR"'` | stdout 为 `probe-env` | C4 |
| `timeout` | `sleep 30`，超时 1500ms | `errorCode=1003`，耗时落在 1.5~3 秒 | C2 |
| `external` | `<prefix>/bin/brew --version` | 退出码 0，stdout 含版本号 | C6 |
| `read-outside` | `head -c 4 <prefix>/Cellar/<首个包>/<版本>/INSTALL_RECEIPT.json` | stdout 为 `{` 加一个换行或空白 | C7 |

`timeout` 的耗时上界取 3 秒：通道的终止动作可能滞后，这个区间足以区分「按时终止」与「压根没终止」。

### 4.2 通道能力不足时的回落

| 缺失 | 影响 | 回落 |
| --- | --- | --- |
| C3（stderr 不分离） | brew 的 stderr 会混进 stdout | 解析前先定位第一个 `{` 再截取到最后一个 `}`，然后解析 |
| C4（环境变量不继承） | `HOMEBREW_PREFIX` 等设置无效 | 把变量内联进命令行：`HOMEBREW_NO_AUTO_UPDATE=1 <brew> info ...` |
| C5（无输出上限） | 极端情况下内存增长 | brew 的输出量已知量级（几十到几百 KB），不构成风险 |
| C6 或 C7 不成立 | brew 起不来或读不到 `Cellar` | 方案不成立，改用直接读安装记录文件的路径 |

### 4.3 探针验收

| 判据 | 期望 |
| --- | --- |
| 构建 | `devecocli build` 通过，`ERROR` 计数为 0 |
| 用例 | §4.1 九条全部 `ok=true`；若某条失败，按 §4.2 记录回落并复测 |
| 耗时 | `echo` 与 `external` 两条的耗时记录在日志里，作为后续超时取值的依据 |

---

## 5. `features/brewcommon` 的读取层

### 5.1 文件

```
features/brewcommon/src/main/ets/service/BrewInstalledLoader.ets   发现 brew、执行命令、内存缓存、失败分类
features/brewcommon/src/main/ets/service/BrewInstalledProbe.ets    brew 命令与输出的自检用例
features/brewcommon/src/main/ets/model/BrewInstalledDoc.ets        brew 输出的解析形状
features/brewcommon/src/main/ets/util/BrewInstalledParser.ets      解析成 BrewInstalledPackage
```

`BrewInstalledLoader` 依赖 `@ohos/pcnative`，所以 `features/brewcommon/oh-package.json5` 的
`dependencies` 增加 `"@ohos/pcnative": "file:../pcnative"`。`features/mine` 不改依赖。

### 5.2 brew 可执行文件的发现

按顺序探测，命中即停：

1. 环境变量 `HOMEBREW_BREW_FILE`；
2. `ShellUtils.exists('brew')`（PATH 里有就直接用）；
3. 固定候选路径，逐个判存在：`/storage/Users/currentUser/.harmonybrew/bin/brew`、
   `/opt/homebrew/bin/brew`、`/usr/local/bin/brew`、`$HOME/.harmonybrew/bin/brew`。

找到后记下 `prefix`（`bin/brew` 的上一级目录）。发现结果在进程内缓存，不落盘。

### 5.3 命令与环境

```
<brew> info --json=v2 --installed
```

执行环境：

| 变量 | 值 | 作用 |
| --- | --- | --- |
| `HOMEBREW_PREFIX` | 探测到的 prefix | 跳过脚本里的路径推导 |
| `HOMEBREW_NO_AUTO_UPDATE` | `1` | 本机包查询是只读操作，不触发自更新 |
| `HOMEBREW_NO_ANALYTICS` | `1` | 不发送统计 |
| `HOMEBREW_NO_ENV_HINTS` | `1` | 不输出环境提示 |
| `NONINTERACTIVE` | `1` | 保证不会卡在交互提示 |
| `PATH` | `<prefix>/bin` 前置 | brew 内部调用 `git` / `curl` 等 |

超时 30 秒：brew 启动要拉起 vendored Ruby，首跑可能到秒级。

### 5.4 内存缓存

进程内缓存一份结果，TTL 60 秒。理由：「我的」页与「本机包」二级页在一次操作里会各取一次，
两次之间数据不可能变，而每次 brew 调用都要付 Ruby 启动成本。不做落盘缓存：本机包集合是设备上
随时可读的现状数据，没有离线可用的意义，落盘会引入失效判定。

### 5.5 失败分类

| 情况 | 判定 | 结果 |
| --- | --- | --- |
| 找不到 brew | 三条探测都落空 | `BREW_NOT_FOUND` |
| 执行能力不可用 | `ShellUtils.available()` 为假 | `SHELL_UNAVAILABLE` |
| 命令超时 | `errorCode = 1003` | `TIMEOUT` |
| 非零退出 | `ok = false` | `COMMAND_FAILED`，带 stderr 前 200 字符 |
| JSON 解析失败 | `JSON.parse` 抛错 | `BAD_OUTPUT`，带 stdout 前 200 字符 |
| 形状不符 | `formulae` 不是数组 | `BAD_SHAPE` |

六种失败都对应「本机包读不到」，UI 侧统一走失败态，日志里带分类名。

### 5.6 自检开关

`BREW_INSTALLED_VERIFY: boolean = false`（`BrewConstants.ets`）。打开时按
`BrewSourceDiagnostics` 的格式打一组 `[BrewInstalled] verify … ok=<bool>` 判据行：

| 用例 | 判据 |
| --- | --- |
| `discover` | 找到的 brew 路径与 prefix 非空 |
| `version` | `brew --version` 退出码 0 |
| `installed` | `info --json=v2 --installed` 退出码 0，stdout 可解析 |
| `shape` | `formulae` 是数组，长度等于 `Cellar` 下的目录数 |
| `fields` | 抽第一条，`name` / `versions.stable` / `installed[0].version` / `installed[0].time` 四个字段都存在且类型正确 |
| `sets` | `installed.length >= outdated.length`，`updated.length === installed.length - outdated.length` |

`fields` 用例另外把原始 stdout 截断到 4 KB 打进日志，用于首次联调核对。

---

## 6. 字段映射

`BrewInstalledPackage`（`BrewModels.ets:271`）的每个字段都有来源。来源是 `formulae[i]` 与它的
`installed[j]`（取 `installed` 数组里版本最新的那个 keg）。

| 模型字段 | 来源 | 说明 |
| --- | --- | --- |
| `name` | `formulae[i].name` | |
| `fullName` | `formulae[i].full_name` | 缺失时回退 `name` |
| `version` | `installed[j].version` | 已安装版本 |
| `latestVersion` | `formulae[i].versions.stable` | |
| `installedOnRequest` | `installed[j].installed_on_request` | |
| `installedAsDependency` | `!installedOnRequest` | 与 `BrewLocalPackageRow.ets:53` 的口径一致 |
| `outdated` | `formulae[i].outdated` | |
| `kind` | 固定 `'formula'` | `BrewKind.FORMULA` |
| `installedAt` | `installed[j].time` | 实测为 Unix 秒：`libpng` 的 receipt 写 `1788920001`，对应 `2026-09-09 10:13:21`，与文件修改时间逐秒一致 |
| `pouredFromBottle` | `installed[j].built_as_bottle` | 顶层 `poured_from_bottle` 不出现在 JSON 里（`formula.rb:3170` 只投影了 `built_as_bottle`）。全仓库无 UI 消费点 |
| `autoUpdates` | 固定 `false` | formula 的 JSON 没有这个字段。全仓库无 UI 消费点 |

`installedAt` 的回落：`time` 缺失或不在 `[10^9, 4×10^9)` 区间时，取
`Cellar/<name>/<version>/` 目录的修改时间。

cask 条目全部丢弃：本机不支持 cask，`casks` 数组即使非空也不进模型。

### 6.1 三个集合

```
installed = 全部条目，按 name 排序
outdated  = installed 里 outdated 为真，按 name 排序
updated   = installed - outdated，按 installedAt 倒序
```

与 `MinePackageSets` 里已经写下的口径一致（`updated` 取补集，避免两张卡片列同一批包）。

---

## 7. 改动清单

### 7.1 新增

- `features/pcnative/` 全模块（见 §3、§4）。
- `features/brewcommon/src/main/ets/service/BrewInstalledLoader.ets`
- `features/brewcommon/src/main/ets/service/BrewInstalledProbe.ets`
- `features/brewcommon/src/main/ets/model/BrewInstalledDoc.ets`
- `features/brewcommon/src/main/ets/util/BrewInstalledParser.ets`

### 7.2 修改

- 根 `build-profile.json5`：`modules` 增加 `pcnative`。
- `features/brewcommon/oh-package.json5`：依赖增加 `@ohos/pcnative`。
- `features/brewcommon/Index.ets`：导出 `BrewInstalledLoader` 与解析类型。
- `features/brewcommon/src/main/ets/constant/BrewConstants.ets`：新增 `BREW_INSTALLED_TTL_MS`、
  `BREW_INSTALLED_TIMEOUT_MS`、`BREW_INSTALLED_VERIFY` 与 brew 路径候选表。
- `features/mine/src/main/ets/util/MinePackagesUtil.ets`：`loadSets()` 从返回空集合改为转调
  `BrewInstalledLoader.loadSets()`。`pick` / `filter` / `byName` 不动。
- `features/mine/src/main/ets/viewmodel/MinePackagesVM.ets`：`load()` 的 catch 分支按失败分类置
  `FAILED`，日志带分类名。
- `docs/brew-api-design.md`、`docs/brew-handover.md`、`README.md`、`README.en.md`：本机包一节
  改为「读设备上的 harmonybrew 安装记录」，并删掉已经不再成立的说法。

### 7.3 不动

- `MineView.ets`、`MinePageVM.ets`、`MinePageState.ets`、`MinePackagesState.ets`、
  `MinePackagesView.ets`、`MinePackageCard.ets`、`BrewLocalPackageRow.ets`：状态机与渲染
  已经是终态。
- `MINE_SHOW_LOCAL_PACKAGES`（`MinePageVM.ets:48`）：保持 `false`。它是按用户体验结论做的
  阶段性开关，与数据接入是两件事。
- `BrewInstalledPackage` 的字段：一个都不删。

---

## 8. 上机验证顺序

1. 构建：`devecocli build`，`ERROR` 计数为 0。
2. 执行通道探针：打开 `SHELL_VERIFY`，九条用例全绿（§4.1、§4.3）。
3. brew 自检：打开 `BREW_INSTALLED_VERIFY`，六条判据全绿（§5.6）。
4. 「我的 - 本机包」二级页三个筛选下的条目数与顺序符合 §6.1；待更新集合与设备上
   `brew outdated` 的输出一致。
5. 失败路径：把 brew 路径候选全部改成不存在的路径，页面走失败态且日志分类为 `BREW_NOT_FOUND`。

---

## 9. 已知未知

| 项 | 说明 |
| --- | --- |
| 执行通道的可用范围 | `shell_hook.cpp` 调用的能力由设备侧提供。C6（执行绝对路径的二进制）与 C7（读沙箱外文件）能否成立由第 2 步验证；不成立则按 §4.2 换路径 |
| 命令耗时 | 首次调用要拉起 vendored Ruby，实测耗时未知；30 秒超时是上限，实际值在第 3 步记录 |
| `time` 的语义 | 已用 receipt 与文件修改时间交叉验证为 Unix 秒；异常值按 §6 的区间判定回落目录修改时间 |
| cask | 本机不支持，不实现、不验证 |
