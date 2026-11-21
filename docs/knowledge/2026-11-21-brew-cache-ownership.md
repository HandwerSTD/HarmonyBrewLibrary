# 设备上的两份 brew 缓存，谁用哪一份

> 2026-11-21 实测。这台设备（HUAWEI MateBook Pro，HarmonyOS PC）上的 Harmonybrew。

## 现象

同一台设备上 `brew --cache` 会给出两个不同的答案：

| 在哪儿执行 | `brew --cache` |
| --- | --- |
| 应用（`top.handwer.brewlibrary`，uid 20020259） | `/storage/Users/currentUser/.cache/Homebrew` |
| HiShell（uid 20020096，也就是 `pi` / 系统终端跑的地方） | `/data/storage/el2/base/haps/entry/files/Homebrew` |

体积差得很夸张：前者几十 MB，后者 1.6 GB。

## 原因

缓存路径只有一条链，全部在 brew 自己的脚本里：

`Library/Homebrew/utils/os.sh:78-82`

```sh
else
  CACHE_HOME="${HOMEBREW_XDG_CACHE_HOME:-${HOME}/.cache}"
  HOMEBREW_DEFAULT_CACHE="${CACHE_HOME}/Homebrew"
```

`Library/Homebrew/brew.sh:58` 随后 `HOMEBREW_CACHE="${HOMEBREW_CACHE:-${HOMEBREW_DEFAULT_CACHE}}"`。

所以优先级是：**`HOMEBREW_CACHE` → `HOMEBREW_XDG_CACHE_HOME` → `$XDG_CACHE_HOME` → `$HOME/.cache`**。

两边的差别只有 `XDG_CACHE_HOME`：

- 应用进程里没有这个变量（`env` 里 26 项，没有 `XDG_*` 中的任何一个），`HOME=/storage/Users/currentUser`
  → 落到 `/storage/Users/currentUser/.cache/Homebrew`
- HiShell 把 `XDG_CACHE_HOME` 设成了自己的沙箱 `/data/storage/el2/base/haps/entry/files`
  → 落到 `/data/storage/el2/base/haps/entry/files/Homebrew`

`bin/brew:243` 把 `XDG_CACHE_HOME` 列在 `USED_BY_HOMEBREW_VARS` 里，会在启动时转成
`HOMEBREW_XDG_CACHE_HOME` 再 export，所以走的是 os.sh 那条分支，不是 Ruby 侧另算一份。

## 共用的那一半

`prefix` / `Cellar` / 仓库是**共用**的：

```
brew --prefix  = /storage/Users/currentUser/.harmonybrew
brew --cellar  = /storage/Users/currentUser/.harmonybrew/Cellar
```

应用能写宿主目录，是因为 `/storage/Users/currentUser` 与 `.cache`、`.harmonybrew` 都是
`drwxrws--x 20001006:file_manager`（组可写 + setgid），而应用进程的组里有 `1006(file_manager)`：

```
id → uid=20020259(handwer) gid=20020259(handwer_a20259) groups=20020259(...),1006(file_manager),1076(expert),1097(netsys_socket),3099(shader_cache)
```

于是两边装出来的包装进同一个 Cellar，`brew list` 看到的是同一批。

## 怎么验证的

`INSTALL_RECEIPT.json` 里记着每个包是从哪份元数据装的（`source.path` 字段）。
扫一遍 `/storage/Users/currentUser/.harmonybrew/Cellar/*/*/INSTALL_RECEIPT.json`：

- 绝大多数指向**沙箱**那份：`/data/storage/el2/base/haps/entry/files/Homebrew/api/internal/packages.arm64_ohos.jws.json`
- 只有 4 条指向宿主 `.cache`：`gmp/6.3.0_1`、`pandoc/3.12`、`pcre2/10.49`、`ripgrep/15.2.0_1`，
  时间都是 2026-10-05 18:31–18:54

这 4 个包正是宿主 `~/.cache/Homebrew/downloads/` 里那几个 10-05 的老 bottle 文件。
其余都是 HiShell 侧装的。

## 为什么值得记一笔

服务端重打 bottle 会删掉旧文件名。应用侧带着 `HOMEBREW_NO_AUTO_UPDATE=1` 时 API 元数据
缓存永不过期（见 `docs/superpowers/specs/2026-10-04-brew-command-execution-spec.md` §5.1），
而宿主那份缓存 7 天自动刷新 —— **同一个已删除的 URL，两边会在不同时间点 404**。

排查这类问题时只要看 `/storage/Users/currentUser/.cache/Homebrew/api/internal/` 就够了，
不必再去翻沙箱里那 1.6 G（那是 HiShell 的，跟应用无关）。

## 附带一条坑

`bin/brew:18-35` 启动前会检查 `$PWD`：

```
Error: The current working directory must be readable to ${USER} to run brew.
```

所以 `cd /` 之后跑 brew 一定失败（`/` 对应用用户不可读）。`BrewCli.workingDirectory()`
用 prefix 当工作目录正是为此。

## 顺带记录：沙箱路径的两种写法

| 应用内的视角 | 宿主 `hdc shell` 的视角 |
| --- | --- |
| `/data/storage/el2/base/...` | `/data/app/el2/100/base/top.handwer.brewlibrary/...` |
| `/storage/Users/currentUser/appdata/el2/base/top.handwer.brewlibrary` | 同样的 `/data/app/el2/100/base/top.handwer.brewlibrary` |

`/storage/Users/currentUser/appdata` 是 `drwx--x--x root:root`，只有遍历权没有读权，
宿主侧 `ls` 直接 `Operation not permitted`。`hdc shell` 的 `shell` 用户在 `file_manager` 组，
能直接读 `/data/app/el2/100/base/<bundle>/files`。
