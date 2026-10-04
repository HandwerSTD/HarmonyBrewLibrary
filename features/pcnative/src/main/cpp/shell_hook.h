/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

/*
 * 平台执行能力的唯一调用点。
 *
 * 本文件之外的所有代码都只认 `ShellHookRun` 这一层接口，不关心命令是怎么跑起来的。
 * 换成别的执行通道时只改这里，`shell_runner.cpp` 与 ArkTS 侧都不动。
 *
 * 契约（执行通道的验收口径，见 `docs/superpowers/specs/2026-10-04-brew-installed-packages-spec.md`）：
 *   C1 命令交给系统 shell 解释，管道 / 重定向 / && / 命令替换可用
 *   C2 返回退出码；超时由调用方终止，终止要连子孙进程一起清掉
 *   C3 stdout 与 stderr 分路采集
 *   C4 子进程继承本进程的环境变量
 *   C5 子进程在调用方指定的工作目录里运行，该目录不可用时退到 /
 *   C6 能执行给定绝对路径的可执行文件
 *   C7 能读应用沙箱之外的文件
 *
 * C5 为什么存在：应用进程的当前目录是 `/`，而 uid 100 对 `/` 没有读权限。
 * 被测命令里凡有「检查当前目录可读性」的启动逻辑（brew 就是一个），
 * 在当前目录里跑都会直接失败，而失败信息跟真正的权限问题毫无关系。
 *
 * 返回值（`errorCode`）：
 *   SHELL_OK           0，命令跑完，exitCode 有效
 *   SHELL_ERR_START    1002，进程没起来（可执行文件不存在、权限不足、资源不足）
 *   SHELL_ERR_TIMEOUT  1003，超时，进程已终止
 *   SHELL_ERR_OUTPUT   1004，输出超限，进程已终止
 */

#ifndef PCNATIVE_SHELL_HOOK_H
#define PCNATIVE_SHELL_HOOK_H

#include <string>

namespace pcnative {

const int SHELL_OK = 0;
const int SHELL_ERR_START = 1002;
const int SHELL_ERR_TIMEOUT = 1003;
const int SHELL_ERR_OUTPUT = 1004;

struct ShellHookResult {
    int errorCode = SHELL_OK;
    int exitCode = -1;
    std::string stdoutText;
    std::string stderrText;
};

/**
 * 执行一条命令并等到结束或超时。
 *
 * `command` 是一整条命令行字符串。`timeoutMs` 已由调用方限制在合法区间内。
 * `cwd` 是子进程的工作目录，空串时用 `/`。
 */
ShellHookResult ShellHookRun(const std::string &command, int timeoutMs, const std::string &cwd);

/** 平台执行能力是否可用。不执行命令，只探测通道本身 */
bool ShellHookAvailable();

}  // namespace pcnative

#endif  // PCNATIVE_SHELL_HOOK_H
