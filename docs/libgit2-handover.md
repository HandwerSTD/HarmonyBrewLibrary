# libgit2 集成交接文档

> 面向：负责提供 libgit2（或等价 Git 能力）的一方。
> 目的：说明应用需要哪些 Git 能力、行为要对齐到什么程度、以及怎么验收。
> 日期：2026-10-10。

---

## 1. 背景

应用（HarmonyOS NEXT 上的 Homebrew 包浏览器）需要允许用户添加「自定义 Tap」，
也就是一个 Homebrew 的第三方软件包仓库。Tap 的内容就是**一个 Git 仓库**，里面是
`Formula/*.rb`（formula 定义）与 `Casks/*.rb`（cask 定义）。

所以应用需要的能力是：**把一个公开的 Git 仓库取到应用沙箱里，之后能更新到最新，能读当前提交。**

应用有两个产品版本，其中 `pc_normal` **没有命令执行能力、不依赖设备上的 git 与 brew**。
因此 Git 能力必须由原生库提供，不能靠调用外部命令。

---

## 2. 范围

### 2.1 需要

| 能力 | 说明 |
|---|---|
| 问远端而不克隆 | 建立连接，读出远端默认分支名与某个分支的提交哈希 |
| 克隆 | 把公开的 http(s) 仓库取到指定目录，只要目标分支的一份快照 |
| 更新 | 对已克隆的目录抓取远端，并让它变成远端目标分支的最新提交 |
| 读本地提交 | 读出一个已克隆目录当前指向的提交哈希 |
| 超时中止 | 三个网络操作都能被调用方给出的截止时刻中止 |
| 进度回调 | 传输过程中能告知已收字节数与已收对象数 |
| 错误可分辨 | 十类失败原因要能区分开（见 §5） |

### 2.2 不需要

推送、提交、分支创建、删除分支、合并、变基、cherry-pick、子模块、工作树管理、
暂存区操作、标签创建、历史遍历与日志、blame、diff、SSH、任何形式的凭据输入、
任何自动重试与退避、bare 仓库。

列目录与读文件这两件事**也不需要**：那是普通文件读取，应用侧自己用系统文件接口做。

---

## 3. 最终调用形态

交付物会通过 NAPI 暴露成五个 ArkTS 函数。这五个函数就是全部调用面。

```ts
/** 原生库是否加载成功。为 false 时其余函数直接返回错误码 1001，不去碰文件系统 */
TapGit.available(): boolean

/** 不克隆，只问远端：默认分支叫什么、目标分支的提交是哪个 */
TapGit.lsRemote(url: string, branch: string): Promise<TapRemoteInfo>

/** 克隆到 destDir。destDir 必须不存在或为空目录 */
TapGit.clone(url: string, branch: string, destDir: string, depth: number): Promise<TapGitResult>

/** 抓取远端，并让 destDir 的内容等于远端目标分支的最新提交 */
TapGit.update(destDir: string, branch: string): Promise<TapGitResult>

/** 读 destDir 当前指向的提交 */
TapGit.revision(destDir: string): Promise<TapGitResult>
```

```ts
export interface TapRemoteInfo {
  ok: boolean;
  errorCode: number;
  errorMessage: string;
  defaultBranch: string;  // 形如 'main'，不带 refs/heads/ 前缀
  commit: string;         // 完整 40 位；branch 为空串时取默认分支
}

export interface TapGitResult {
  ok: boolean;
  errorCode: number;
  errorMessage: string;   // 保留库给出的原始信息，不要替换成自定义文案
  commit: string;         // 成功时的完整 40 位提交哈希
  changed: boolean;       // 只有 update 有意义：更新后的提交是否与更新前不同
}
```

约定：

- `url` 只接受 `http://` 与 `https://` 开头的**公开**地址。`git@…` 形式的地址在应用侧就被拒绝，
  不会传到这里。
- `branch` 传空串表示「用远端默认分支」。
- 所有字符串参数都是 UTF-8。

---

## 4. 行为规格（以 git 命令行为参照）

下面每条都给出等价的 git 命令行与本机的实测输出。实现时把命令行当成行为规格来对齐。

**前置**：所有网络操作都要禁用交互式凭据提示（对应命令行里的 `GIT_TERMINAL_PROMPT=0`）。
本机实测：不禁用时 git 会挂起等待输入用户名。

### 4.1 `lsRemote` — 不落盘，只问远端

对应两条命令：

```sh
# (a) 远端默认分支名
git ls-remote --symref <url> HEAD

# (b) 目标分支的提交（branch 非空时）
git ls-remote --heads <url> <branch>
```

实测输出（`https://gitcode.com/handwer/HarmonyBrewCaskStore.git`）：

```
ref: refs/heads/main	HEAD
6e01b7670ca498234c9ea90be5391526bcd7a6b0	HEAD
--------------------------------------------------
6e01b7670ca498234c9ea90be5391526bcd7a6b0	refs/heads/main
```

要的分别是第一行里的 `refs/heads/main`（去掉前缀即 `main`）与第二段的提交哈希。

`branch` 传空串时先用 (a) 拿到默认分支，再问它的提交。

**必须注意**：分支不存在时 `ls-remote --heads <url> <branch>` 返回**空输出且退出码为 0**（实测）。
这种情况要上报「分支不存在」（错误码 1006），不能报成功。

### 4.2 `clone` — 克隆到指定目录

```sh
# branch 非空
git clone --depth 1 --single-branch --branch main <url> <destDir>

# branch 为空串
git clone --depth 1 <url> <destDir>
```

实测：0.92 秒完成；目录里出现 `Casks/` 与 `README.md`，`Casks/` 下是 `busybox.rb`、`fzf.rb`、
`harmonybrew-library.rb`、`yq.rb` 四个文件。

`--depth 1` 对应浅克隆。实测同一仓库全量克隆 419 KB、浅克隆 364 KB；Tap 是元数据仓库，
不需要历史，浅克隆省下的是大仓库的时间。

### 4.3 `update` — 抓取并让目录等于远端最新

在已克隆的目录里执行：

```sh
git fetch --depth 1 origin <branch>
git reset --hard origin/<branch>
```

实测输出：

```
From https://gitcode.com/handwer/HarmonyBrewCaskStore
 * branch            main       -> FETCH_HEAD
HEAD is now at 6e01b76 创建 HarmonyOS 上的 Homebrew cask 仓库
```

抓取之后 `refs/remotes/origin/<branch>` 就是远端目标提交，硬重置之后 `HEAD` 与它一致。

**两点必须注意**：

1. `fetch` 上也要带 `--depth 1`。不带这个参数对浅克隆仓库抓取会把历史补齐，抓取量显著变大。
2. 我们的实现里 `HEAD` 是**游离状态**（不对应任何本地分支，对应 libgit2 的
   `git_repository_set_head_detached`）。已实测这个状态下 `fetch` 与 `reset --hard` 都正常工作，
   重置后 `git status --porcelain` 为空（工作树干净）。

`branch` 传空串时先用本地记录的远端默认分支（`git symbolic-ref refs/remotes/origin/HEAD`，
实测返回 `refs/remotes/origin/main`），取不到就重新问远端。

**`changed` 判据**：抓取前后各读一次目标提交，两次不同则 `changed = true`。

### 4.4 `revision` — 读本地当前提交

```sh
git -C <destDir> rev-parse HEAD
```

实测输出：`6e01b7670ca498234c9ea90be5391526bcd7a6b0`。

**必须注意**：空仓库的克隆里这条命令会失败（实测 `fatal: ambiguous argument 'HEAD': unknown
revision or path not in the working tree`）。这种情况要上报「远端为空」（1006），
不能返回空字符串当成功。

---

## 5. 错误分类

调用方按 `errorCode` 分支，所以每一类都要能区分开。`errorMessage` 请保留原始信息，
应用侧会把它原样写进日志用于排查；请勿在上游替换成自定义文案。

| errorCode | 含义 | 触发情形 |
|---|---|---|
| 0 | 成功 | — |
| 1001 | 参数非法 | 地址为空或格式不对；目标目录参数不合理；原生库未加载 |
| 1002 | 目标目录不可用 | 目录不存在、无写权限、已被占用、非空 |
| 1003 | 建连失败 | 域名解析失败、连接被拒、连接中断 |
| 1004 | 需要凭据 | 私有仓库。**不允许弹凭据输入，也不允许挂起等待**，直接返回 |
| 1005 | 仓库不存在 | 地址可达但仓库没有 |
| 1006 | 远端为空，或目标分支不存在 | 空仓库；分支名写错 |
| 1007 | 检出失败 | 抓取成功但工作树写不出来 |
| 1008 | 超时被中止 | 调用方给的截止时刻到了 |
| 1009 | 证书或 TLS 失败 | 证书校验不通过、协议不支持、握手失败 |
| 1010 | 其它 | 以上都不匹配 |

### 5.1 六种情形的实测样本

| 情形 | 期望错误码 | 命令 | 实测输出 | 退出码 |
|---|---|---|---|---|
| 仓库不存在 | 1005 | `git ls-remote https://gitcode.com/handwer/NoSuchRepo-xyz.git` | `fatal: unable to access '…': The requested URL returned error: 403` | 128 |
| 域名不存在 | 1003 | `git ls-remote https://nonexistent-host-for-test.invalid/x.git` | `fatal: unable to access '…': Could not resolve host: nonexistent-host-for-test.invalid` | 128 |
| 需要登录 | 1004 | `git ls-remote https://github.com/handwer/NoSuchPrivateRepo.git` | `fatal: could not read Username for 'https://github.com': terminal prompts disabled` | 128 |
| 分支不存在 | 1006 | `git clone --depth 1 --branch nosuchbranch <url> <dir>` | `fatal: Remote branch nosuchbranch not found in upstream origin` | 128 |
| 目标目录非空 | 1002 | `git clone <url> hasfile` | `fatal: destination path 'hasfile' already exists and is not an empty directory.` | 128 |
| 空仓库 | 1006 | `git clone --depth 1 <empty-repo> <dir>` | 成功，但只有 `.git/`，工作树为空 | **0** |

**两个最容易漏的点**：

1. **第 1 行的仓库不存在被报成 HTTP 403 而不是 404**（gitcode 的行为）。所以按 HTTP 状态码
   分类时不能只认 404。建议按 libgit2 的 `klass` 加 message 内容判定，或者把「访问被拒」与
   「需要凭据」都先归到可分辨的两类里再细分。
2. **第 6 行退出码为 0 但内容为空**。这是唯一一个「命令成功但结果无效」的情形，
   必须单独判定，不能报成功。

---

## 6. 编译与打包

| # | 项 | 要求 |
|---|---|---|
| 1 | 平台 | HarmonyOS NEXT（ohos），只需要 **arm64-v8a** 一个 ABI。设备实测 `const.product.cpu.abilist` 为 `arm64-v8a` |
| 2 | 编译器 | SDK 自带 `ohos-sdk-native/26.0.0.18/llvm/bin/aarch64-unknown-linux-ohos-clang`（clang 15.0.4）；CMake 工具链用 `ohos-sdk-native/26.0.0.18/build/cmake/ohos.toolchain.cmake` |
| 3 | 版本 | libgit2 1.9.1 或更高 |
| 4 | TLS 必须内嵌 | libgit2 自身不含 TLS；设备 SDK 的 sysroot 里既没有 OpenSSL 也没有 mbedTLS（`sysroot/usr/include/` 下无 `openssl/`，`sysroot/usr/lib/aarch64-linux-ohos/` 下无 `libssl.so` 与 `libcrypto.so`）。建议 mbedTLS 3.6.x（许可为 Apache-2.0 或 GPL-2.0-or-later 二者择一，取前者） |
| 5 | zlib | 用设备自带的：`sysroot/usr/include/zlib.h` 与 `sysroot/usr/lib/aarch64-linux-ohos/libz.so`（实测都存在）。不要重复内嵌 |
| 6 | HTTP 解析器 | 用 libgit2 自带的 `deps/llhttp`（MIT） |
| 7 | 哈希与正则 | 用内置：SHA1 碰撞检测、内置 SHA256、内置 PCRE |
| 8 | SSH | 关闭。这个需求完全用不到 |
| 9 | HTTP 代理 | libgit2 内置支持。若为减体积裁掉 NTLM 那一支，请明确告知，我们会把「部分企业代理环境下不可用」写成已知限制 |
| 10 | 体积 | 请给出编好之后的库文件大小。我们的另一个原生依赖（Ruby 语法解析器）约 2 MB，加上 libgit2 与 TLS 之后需要一个总数 |
| 11 | 产物形态 | 共享库或静态库都可以。另需一份 C 头文件目录（`include/git2/`），因为调用胶水代码由我们自己写 |

### 6.1 许可

libgit2 的 `COPYING` 是 **GPL-2.0 带链接例外**。原文写明：作者给出无限许可，允许把编译后的库
链接进其它程序，并分发这些组合而不受该文件带来的限制。所以可以链接进本应用。

请把 `COPYING` **全文**一起给过来 —— 这份文件里还包含内嵌组件的声明（zlib、PCRE、llhttp、
SHA1 碰撞检测等），我们需要一并登记。另外请给出所选 TLS 库的版本与许可全文。

---

## 7. 调用约定

1. **同一时刻只会有一个操作在跑**，不同仓库也不并发。应用侧用串行队列把操作排开。
   所以不需要为并发访问同一个目录做保护。
2. **调用发生在非 JS 线程上**（每次操作注册成 NAPI 异步任务）。若初始化必须在特定线程上做，
   请说明。
3. **不重试**。任何失败都原样返回，重试策略在应用侧（同一个 Tap 连续两次失败即停止）。
4. 每次操作的完整过程是「打开目标目录 → 操作 → 释放」，不跨调用持有任何句柄。
5. **某次操作失败后，目标目录里的仓库仍要可用**（下一次操作能打开它），不要留下半截状态。
6. 不需要在库内部做日志输出，需要的信息都在返回值里。
7. 证书校验用库的默认严格行为。**不要提供「忽略证书错误」的开关。**

---

## 8. 验收判据

| # | 判据 |
|---|---|
| V1 | `lsRemote` 对真实仓库返回默认分支与提交，且**没有在磁盘上留下任何东西** |
| V2 | `clone` 把 `https://gitcode.com/handwer/HarmonyBrewCaskStore.git` 取下来，目录里出现 `Casks/busybox.rb`、`Casks/fzf.rb`、`Casks/harmonybrew-library.rb`、`Casks/yq.rb` |
| V3 | 同一仓库，`branch` 传 `main` 与传空串（用默认分支）都能成功 |
| V4 | `clone` 之后 `revision` 返回的提交与远端一致（该仓库当前 HEAD 为 `6e01b7670ca498234c9ea90be5391526bcd7a6b0`，分支 `main`） |
| V5 | `update` 成功；远端没有新提交时 `changed` 为 false 且 `commit` 不变 |
| V6 | 错误分支各来一次：不存在的仓库归 1005；存在的仓库配不存在的分支归 1006；关掉网络归 1003；需登录的地址归 1004 且不挂起 |
| V7 | 把截止时刻设成 1 秒去取一个大仓库，操作在 1 秒左右返回并归 1008，不会一直跑到传输结束 |
| V8 | 空仓库归 1006，不报成功 |

---

## 9. 交付清单

| # | 内容 |
|---|---|
| 1 | 编译脚本或 CMake 片段：目标 `arm64-v8a`、平台 ohos、用设备的 `ohos.toolchain.cmake`、§6 的开关 |
| 2 | 产物：共享库或静态库的可链接形态 |
| 3 | `include/git2/` 头文件目录 |
| 4 | `COPYING` 全文（GPL-2.0 带链接例外） |
| 5 | 所选 TLS 库的版本、许可与许可全文 |
| 6 | 一句话确认：`deps/ntlmclient/` 保留还是裁掉（§6 第 9 项） |
| 7 | 编好之后的库文件大小 |
| 8 | 一句话确认：是否需要在特定线程上做初始化（§7 第 2 项） |
| 9 | 一句话确认：目标目录存在符号链接时，打开仓库用的是哪种方式（见 §10） |

---

## 10. 一条需要确认的细节

沙箱根目录在设备上可能包含符号链接。libgit2 的 `git_repository_open` 在路径含符号链接时
不可靠，需要用 `git_repository_open_ext` 并把沙箱根作为 `ceiling_dirs`。

请确认：**应用传给原生层的 `destDir` 若含符号链接，打开仓库的行为是稳定的。**
如果需要在胶水代码里处理，请实现为「用 realpath 归一后再打开」，并在 §9 第 9 项里说明。

---

## 附：术语

| 术语 | 含义 |
|---|---|
| Tap | Homebrew 的第三方软件包仓库，就是一个 Git 仓库 |
| formula | 命令行工具类软件包的定义文件，放在 `Formula/` 下 |
| cask | 图形界面应用类软件包的定义文件，放在 `Casks/` 下 |
| destDir | 应用沙箱里的一个目录，克隆下来的仓库就放在这里 |
| 浅克隆 | 只取目标提交的那一份快照，不带历史（`--depth 1`） |
