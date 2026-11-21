# 在应用自己的进程里做实验

> 2026-11-21 实测。想看「应用真的跑起来之后，它看到的环境是什么样」时用这套办法。

## 为什么不能在终端里猜

应用进程的环境变量、身份、权限和宿主终端不是一回事。举两个真实差别：

- `XDG_CACHE_HOME`：应用没有，HiShell 有 → `brew --cache` 给出不同答案
- `PWD`：应用是 `/data/storage/el2/base`（`ShellConstants` 里的默认工作目录），
  而 `cd /` 之后跑 brew 会直接被判「工作目录不可读」而退出

这类差别只能实测。日志（`hilog`）也不是好出口：`devecocli log --keyword` 与
`hdc shell "hilog -x | grep"` 都可能在应用刚开始跑时取不到东西（环形缓冲里没有、
或过滤方式对不上），白等半天。

## 做法

用临时探针，**把结果写进沙箱文件**，再用 `hdc shell` 把文件捞出来。

### 1. 写一个临时类

放在 `features/pcnative/src/main/ets/util/` 下（这个模块已经有 `ShellUtils` 与 `@ohos/common` 的依赖，
不用改任何 `oh-package.json5`）：

```ets
export class TempEnvProbe {
  public static run(): void {
    // 延迟几秒：Ability 刚起来时 JS 线程被界面初始化占着
    setTimeout(() => { TempEnvProbe.cases().then(); }, 3000);
  }

  private static async cases(): Promise<void> {
    // 每条用例都用 ShellUtils.run，把 stdout/stderr 追加进报告文件
  }
}
```

要点：

- **报告文件放 `/data/storage/el2/base/files/`**（应用自己的 `filesDir`）。这个目录应用可写；
  `/data/storage/el2/base` 根目录应用也能写，但不该往那儿扔东西。
- 写文件用 `printf '%s' '<escaped>' >> "$FILE"`，或者干脆每条用例只 `echo` 一行结论 ——
  在 ArkTS 里拼 shell 引号容易翻车。
- 每条用例都要写一行 header（`===== case xxx ok=... exit=... errorCode=...`），
  失败时才知道是哪条没跑。
- 最后一条写个 marker（`echo finished >> "$FILE"`）。报告没出现 marker 就说明进程在中间挂了
  或者探针没被调用。

### 2. 挂到 Ability 上

`products/pc_acl/src/main/ets/pcability/PcAbility.ets` 的 `onCreate` 里加一行
`TempEnvProbe.run();`，并在 `features/pcnative/Index.ets` 里 `export` 它。

### 3. 跑

```bash
devecocli run --product default --module pc_acl     # 必须带 --module，否则只报可用模块
```

### 4. 取报告

```bash
hdc shell "cat /data/app/el2/100/base/top.handwer.brewlibrary/files/app-env.txt"
```

**注意路径要换成宿主视角的 `/data/app/el2/<userId>/base/<bundle>/files/`**。
`/data/storage/el2/base/...` 这个写法在应用里成立，但 `hdc shell` 里
`ls /data/storage/el2/base/files/` 是 `Permission denied`（那是 HiShell 自己的沙箱）。
应用的沙箱宿主侧路径带 userId 与 bundleName，直接用 `bm dump -n <bundle>` 或上文那条即可。

### 5. 收尾

- 删掉 `TempEnvProbe.ets`、`Index.ets` 的 export、`PcAbility` 的调用
- `hdc shell "rm -f <报告文件>"`

`git status` 确认干净。**不要把它提交进去** —— 这种探针一旦进了仓库，下次有人
`devecocli run` 就会莫名其妙多跑一堆命令。

## 实测过的环境（供对照）

应用进程（`pc_acl`、debug 包、uid 20020259）的完整 `env`，26 项：

```
AppSpawnCheckUnexpectedExitCall=1271
DOWNLOAD_CACHE=/data/cache
HAP_DEBUGGABLE=true
HNP_PRIVATE_HOME=/data/app
HNP_PUBLIC_HOME=/data/service/hnp
HOME=/storage/Users/currentUser
LANG=en_US.UTF-8
MALI_REPORT_MEM_USAGE=1
OHOS_SOCKET_AppSpawn=14
OLDPWD=/
PATH=/data/app/bin:/data/service/hnp/bin:/data/app/bin:/data/service/hnp/bin:/usr/local/bin:/bin:/usr/bin:/system/bin:/vendor/bin
PROCESS_START_TIME=104464626
PWD=/data/storage/el2/base
SHELL=/bin/sh
SHLVL=1
TERM=ansi
TMPDIR=/data/storage/el2/base/cache
UBSAN_OPTIONS=print_stacktrace=1:print_module_map=2:log_exe_name=1
USER=100
_=/bin/env
__LIBACE_ENTRY_POINT=5a9220d594
hwasanEnabled=0
tsanEnabled=0
ubsanEnabled=0
```

几件值得记住的：

- **没有任何 `XDG_*`**，也没有任何 `HOMEBREW_*`（`BrewCli` 把需要的都内联进命令行了）
- `HOME` 指向真实用户目录，不是沙箱 —— 所以 brew 的缓存落到 `~/.cache/Homebrew`
- `PATH` 里没有 `/storage/Users/currentUser/.harmonybrew/bin`，brew 只能按绝对路径调
- `id` 输出：`uid=20020259(handwer) gid=20020259(handwer_a20259) groups=...,1006(file_manager),...`，
  上下文 `u:r:develop_tools_debug_hap:s0`
- `pwd`（`ShellUtils` 默认工作目录）是 `/data/storage/el2/base`，对应用可读 —— brew 的
  `$PWD` 可读性检查能过。但 `BrewCli` 还是显式把 `cwd` 设成 prefix，见 `BrewCli.workingDirectory()`
