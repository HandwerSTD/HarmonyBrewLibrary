# brew tap trust 落在哪、两边为什么不通

> 2026-11-21 实测。brew 7.0.9_7（ORIGIN atomgit）。

## 现象

HiShell 里 `brew trust harmony/ohos` 过，应用里装同一个包仍然 `Error: Refusing to load formula harmony/ohos/jiuwenswarm from untrusted tap harmony/ohos.`

## 路径由 `HOMEBREW_USER_CONFIG_HOME` 决定

`bin/brew:164-172`：

```sh
if [[ -n "${XDG_CONFIG_HOME-}" ]]; then          HOMEBREW_USER_CONFIG_HOME="${XDG_CONFIG_HOME}/homebrew"
elif [[ -n "${HOMEBREW_XDG_CONFIG_HOME-}" ]]; then HOMEBREW_USER_CONFIG_HOME="${HOMEBREW_XDG_CONFIG_HOME}/homebrew"
else                                              HOMEBREW_USER_CONFIG_HOME="${HOME}/.homebrew"
fi
```

`Library/Homebrew/trust.rb:27-45` 的 `Trust.trust_file` 就是 `${HOMEBREW_USER_CONFIG_HOME}/trust.json`。

`brew ruby -e 'puts Homebrew::Trust.trust_file'` 两个环境实测：

| 环境 | XDG_CONFIG_HOME | 结果 |
|---|---|---|
| HiShell | `/data/storage/el2/base/haps/entry/files` | `/data/storage/el2/base/haps/entry/files/homebrew/trust.json`（存在，111 B，`drwx------ 20020096`） |
| 应用（pc_acl） | 未设置 | `/storage/Users/currentUser/.homebrew/trust.json`（目录不存在 → 空 store） |

应用进程 26 项 `env` 里一个 `XDG_*` 都没有，所以走 `else` 分支。这就是「两边独立」的全部原因。

## 只写 `harmony/ohos` 不生效

它的 remote 是 `https://gitcode.com/OpenHarmonyPCDeveloper/ohpcd-brew.git`（自定义 remote），
`Library/Homebrew/tap.rb:941-946` 的 `Tap#reference` 遇到自定义 remote 返回 **URL 而不是 name**，
`tap.rb:950-958` 的 `matches_reference?` 同理。

| `trustedtaps` 内容 | `brew install --dry-run wget` |
|---|---|
| （无配置） | `Warning: The following taps are not trusted: harmony/ohos` |
| `["harmony/ohos"]` | 仍然 `not trusted` |
| `["harmony/ohos", "https://gitcode.com/openharmonyPCDeveloper/ohpcd-brew.git"]` | ✅ `==> Would install 1 formula: wget 1.25.0_2` |

HiShell 那份 111 B 的文件两条都写了，生效的是 URL 那条。

`brew trust harmony/ohos` 自己会写 URL（`trust.rb:47-52` 传 Tap 时取 `name.reference`）。
但**不要指望用它来同步**：在精简环境里跑这条命令，180 秒没返回，只留下一个 0 B 的
`trust.json.lock`——它在做网络侧的事（拿 tap 的 remote），不是纯本地写入。

## 不能跨沙箱读 HiShell 的 trust.json

三条路都试过（在应用进程里通过 `ShellUtils.runSync` 跑，详见 `2026-11-21-probe-inside-app.md`）：

| 尝试 | 结果 | 卡在哪 |
|---|---|---|
| `/data/app/el2/100/base/com.huawei.hmos.hishell/...` | `No such file or directory` | 应用进程挂载命名空间里 `/data/app` 存在，但 **`/data/app/el2` 整层不存在** |
| `/storage/Users/currentUser/appdata/el2/base/com.huawei.hmos.hishell/...` | `Operation not permitted` | sharefs 视图能 `stat` 到 `drwx------ 20020096:20020096`、能 `cd` 进去，但 `ls` / `cat` 被 MAC 拦（`hmmac=genfs`），报 EPERM 而非 EACCES |
| `hdc` 中继 | 无输出 | 应用沙箱里没有 `hdc`，绝对路径执行也不通 |

换 spawn 方式也没用：`/bin/sh`、`/system/bin/sh`、`/usr/bin/sh` 是同一个挂载视图；
`unshare` 在 toybox 里不存在，`nsenter` 只支持长选项且 `/proc/1` 不存在
（应用进程的 `/proc` 里只有 5 个 PID，看不到 HiShell）；把 spawn 的 cwd 直接设进沙箱再走相对路径，
`pwd` 对了但 `ls .` 仍 EPERM。

## 应用自己造 trust.json 是可行的

应用能写 `/storage/Users/currentUser/`（在 `file_manager`(1006) 组，目录是 `drwxrws--x 20001006:file_manager`）。
在应用进程里：

```sh
git -C /storage/Users/currentUser/.harmonybrew/Homebrew/Library/Taps/harmony/homebrew-ohos \
  config --get remote.origin.url     # → https://gitcode.com/OpenHarmonyPCDeveloper/ohpcd-brew.git
mkdir -p /storage/Users/currentUser/.homebrew
# 把 name 与 URL 两条写进 trust.json，chmod 600
brew install --dry-run wget          # → ==> Would install 1 formula: wget 1.25.0_2
```

**注意 owner**：应用创建的文件 owner 是 `20001006:file_manager`（setgid 继承），不是应用
uid 20020259。读没问题；但如果哪天让 `brew trust` 自己写这个文件，会撞上
`trust.rb:536-546` 的 `Refusing to write insecure trust store: … is not owned by the current user.`

## 环境变量这条路（不改 trust.json）

`HOMEBREW_NO_REQUIRE_TAP_TRUST=1`（`env_config.rb:640-646`，`odeprecated: true`）让
`trust.rb:231/244/257/575` 六处一律放行。

| 包 | 不加 | 加 |
|---|---|---|
| `wget` | 只警告，仍 `==> Would install 1 formula`（其 formula 在 `harmonybrew/core`，tap 里的 `python@3.15` 只是被忽略的依赖） | 通过 |
| `jiuwenswarm`（formula 本体在 `harmony/ohos`） | `Error: Refusing to load formula …` | ✅ 通过 |

`HOMEBREW_REQUIRE_TAP_TRUST=0` **无效**——它在 `env_config.rb:694-703` 里是 `disabled_by: :HOMEBREW_NO_REQUIRE_TAP_TRUST`，只有 NO_ 那项起作用。

## 顺带两条

- `XDG_CONFIG_HOME` 不能通过 `${HOMEBREW_PREFIX}/etc/homebrew/brew.env` 注入：
  `export_homebrew_env_file` 只接受 `^(HOMEBREW_|SUDO_ASKPASS=|(all|no|ftp|https?)_proxy=)` 开头的行。
  `HOMEBREW_XDG_CONFIG_HOME` 能写进去，但它排在 `XDG_CONFIG_HOME` 之后，对 HiShell 无效。
- 想用 `HOMEBREW_XDG_CONFIG_HOME` 指路时，写的是 `<dir>`，brew 自己会拼 `/homebrew`。
  写成 `<dir>/homebrew` 反而读不到。
