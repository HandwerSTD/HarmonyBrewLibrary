# brew 到底会输出哪些 ANSI 颜色

执行 Sheet 的配色是按「brew 会输出什么」实现的，所以这里记一次实测的清单。
设计口径写在 [`../superpowers/specs/2026-10-04-brew-command-execution-spec.md`](../superpowers/specs/2026-10-04-brew-command-execution-spec.md) §3.3，
本文只记「当时测到了什么」。

设备上的 brew：`Homebrew 7.0.9_7`，ORIGIN atomgit，仓库在 `/storage/Users/currentUser/.harmonybrew/Homebrew`。

## 不加 `HOMEBREW_COLOR` 就没有任何颜色

brew 的着色判据是「输出是 tty」，不是「有没有 TERM」：

```sh
# Library/Homebrew/utils/helpers.sh
[[ -n "${HOMEBREW_COLOR}" || (-t 1 && -z "${HOMEBREW_NO_COLOR}") ]]   # stdout
[[ -n "${HOMEBREW_COLOR}" || (-t 2 && -z "${HOMEBREW_NO_COLOR}") ]]   # stderr
```

应用的输出走管道，`-t 1` / `-t 2` 都为假，于是 brew 自己降级成纯文本。实测 `brew reinstall tree`
的 stdout 与 stderr 里 SGR 计数都是 **0**；加 `HOMEBREW_COLOR=1` 之后两边各 2。

`HOMEBREW_COLOR` 的描述在 `env_config.rb`：只要求「非空」，值本身不参与判断，所以 `HOMEBREW_COLOR=1`
与 `HOMEBREW_COLOR=false` 等价 —— 要关掉只能用 `HOMEBREW_NO_COLOR`，别写 `HOMEBREW_COLOR=0`（它也算「已设置」）。

## 实测出现的 SGR 全集（加 `HOMEBREW_COLOR=1`）

| 序列 | 含义 | 出现位置（例） |
| --- | --- | --- |
| `0m` | reset | 每段末尾 |
| `1m` | bold | `jq`、`Reinstalling`、`Pouring` 这类被强调的词 |
| `4m` / `24m` | 下划线开 / 关 | `brew info` 里的 URL |
| `32m` | 绿 | `==>` 提示头、`Reinstalling ` 后面的包名 |
| `34m` | 蓝 | `==>` 与 `Pouring` 组合时的提示头 |
| `33m` | 黄 | `Warning:` |
| `39m` | 默认前景 | 包名之后恢复继承色 |

原始片段（`brew info jq`）：

```
^[[32m==>^[[0m ^[[1mjq^[[0m: stable 1.8.2 (bottled), HEAD
```

（链接那行用 `^[[4m…^[[24m` 包起来。）

`brew reinstall tree`：

```
^[[32m==>^[[0m ^[[1mReinstalling ^[[32mtree^[[39m ^[[0m
^[[34m==>^[[0m ^[[1mPouring tree-2.3.2_1.arm64_ohos.bottle.1.tar.gz^[[0m
```

没有出现过 256 色或真彩色。解析器还是按全量实现了 —— brew 的 `Tty` 支持 `256` / `truecolor`，
只是本机这条路没走到。

## `--json` 输出不会被污染

`brew list` / `brew outdated` / `brew search` / `brew info --json=v2` / `brew info --json=v2 --installed`
加 `HOMEBREW_COLOR=1` 后 SGR 计数都是 **0**。所以把 `HOMEBREW_COLOR=1` 放进 `BrewCli.commandLine()`
的公共前缀，不会破坏 `BrewInstalledLoader` 对 JSON 的解析。

## brew 自己的颜色表

`Library/Homebrew/utils/tty.rb`：

```ruby
COLOR_CODES = { red: 31, green: 32, yellow: 33, blue: 34, magenta: 35, cyan: 36, default: 39 }
STYLE_CODES = { reset: 0, bold: 1, italic: 3, underline: 4, strikethrough: 9, no_underline: 24 }
```

同一文件里的 `collapse_carriage_returns` 取的是**最后一个非空段**，不是最后一个段 ——
用空格盖掉旧内容的进度行末尾常是空段，照抄这条规则才不会把整行清空。

## 顺带一条：日志区不能用 tty

即使把子进程的 stdout 接到 pty 让 brew 自己着色，得到的是 `\r` 重绘 + 光标移动的一整屏画面，
日志区没有实现「屏幕」这一层（按行追加、只做 `\r` 折叠）。所以这里走的是「强制 brew 着色 + 自己解析
SGR、丢掉光标类序列」，不是「模拟一个终端」。
