/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

/*
 * 平台执行能力的唯一调用点。
 *
 * 本文件之外的所有代码都只认这里声明的接口，不关心命令是怎么跑起来的。
 * 换成别的执行通道时只改这里，`napi_init.cpp` 与 ArkTS 侧都不动。
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
 * 实现只有一套 fork + 管道，两条对外路径都建立在它之上：
 *   一次性执行   ShellHookRun：启动 + 循环泵 + 收尾，结果一次性返回
 *   流式执行     ShellHookStart / ShellHookPump / ShellHookInterrupt /
 *                ShellHookKill / ShellHookRelease：输出按到达顺序增量取走
 *
 * 任务表用互斥量保护：一次性执行可能跑在 libuv 线程池上（`runCommand`）
 * 或调用方自己的线程上（`runCommandSync`），流式轮询在 JS 线程，两边会同时碰到任务表。
 *
 * 返回值（`errorCode`）：
 *   SHELL_OK           0，命令跑完，exitCode 有效
 *   SHELL_ERR_START    1002，进程没起来（可执行文件不存在、权限不足、资源不足）
 *   SHELL_ERR_TIMEOUT  1003，超时，进程已终止
 *   SHELL_ERR_OUTPUT   1004，输出超限，进程已终止
 *   SHELL_ERR_INTERRUPTED 1005，调用方主动中断 / 终止之后命令才结束
 */

#ifndef PCNATIVE_SHELL_HOOK_H
#define PCNATIVE_SHELL_HOOK_H

#include <cstddef>
#include <string>
#include <vector>

namespace pcnative {

const int SHELL_OK = 0;
const int SHELL_ERR_START = 1002;
const int SHELL_ERR_TIMEOUT = 1003;
const int SHELL_ERR_OUTPUT = 1004;
const int SHELL_ERR_INTERRUPTED = 1005;

/** 事件里的流标识。与 ArkTS 侧 `ShellStreamEvent.kind` 一一对应 */
const int SHELL_STREAM_STDOUT = 0;
const int SHELL_STREAM_STDERR = 1;

struct ShellHookResult {
    int errorCode = SHELL_OK;
    int exitCode = -1;
    std::string stdoutText;
    std::string stderrText;
};

/** 一次轮询里的一段增量输出 */
struct ShellHookEvent {
    int stream = SHELL_STREAM_STDOUT;
    std::string data;
};

/** 一次轮询的结果 */
struct ShellHookPoll {
    /** 按到达顺序排列，相邻同类已合并 */
    std::vector<ShellHookEvent> events;
    /**
     * 命令已结束，且管道里的剩余内容已全部取走。
     *
     * 「取走」也计入这个条件：`maxBytes` 把输出截断时，即使进程已经退出，
     * `ended` 也还是假的，上层据此继续轮询就不会丢掉最后一批输出。
     */
    bool ended = false;
    int exitCode = -1;
    /** `ended` 为真时是终值；还没结束时是 SHELL_OK */
    int errorCode = SHELL_OK;
};

/**
 * 执行一条命令并等到结束或超时。
 *
 * `command` 是一整条命令行字符串。`timeoutMs` 已由调用方限制在合法区间内。
 * `cwd` 是子进程的工作目录，空串时用 `/`。
 *
 * 内部就是「建任务 + 循环泵 + 收尾」，与流式执行共用同一份 fork / 管道实现。
 */
ShellHookResult ShellHookRun(const std::string &command, int timeoutMs, const std::string &cwd);

/** 平台执行能力是否可用。不执行命令，只探测通道本身 */
bool ShellHookAvailable();

/** 分配一个任务标识。标识全局唯一，流式任务与一次性执行共用同一张表 */
int ShellHookNextTaskId();

/**
 * 启动一条命令并立刻返回，不等它结束。
 *
 * `taskId` 由调用方分配并在后续接口里传回，0 表示没起来。
 * `startError` 非空时写入失败原因（管道 / fork 失败）。
 */
bool ShellHookStart(const std::string &command, int timeoutMs, const std::string &cwd, int taskId,
                    std::string *startError = nullptr);

/**
 * 读一次输出，并把新增内容交给调用方。
 *
 * `maxBytes` 是本次取走的上限，`sliceMs` 是本次最多等数据多久 —— 流式路径传 0，
 * 不做任何等待，单次调用的工作量因此有上限，可以在 JS 线程上直接调。
 * `stdoutSink` / `stderrSink` 非空时，取走的内容同时累加进去；一次性执行用它攒完整输出，
 * 流式路径传 nullptr，原生侧不累计。
 * 任务不存在返回 false。
 */
bool ShellHookPump(int taskId, size_t maxBytes, int sliceMs, ShellHookPoll *poll,
                   std::string *stdoutSink, std::string *stderrSink);

/** 向整个进程组发 SIGINT（等同终端 Ctrl+C）。返回信号是否送达 */
bool ShellHookInterrupt(int taskId);

/** 向整个进程组发 SIGTERM，宽限 2 秒后升级成 SIGKILL。返回信号是否送达 */
bool ShellHookKill(int taskId);

/** 关闭读端、释放缓冲、从任务表移除。命令结束后调用一次 */
void ShellHookRelease(int taskId);

}  // namespace pcnative

#endif  // PCNATIVE_SHELL_HOOK_H