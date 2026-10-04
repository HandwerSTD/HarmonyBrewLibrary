/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

/*
 * 执行通道的默认实现。
 *
 * 用 POSIX 的 fork + execve 起一个 shell 跑命令行，用管道分别接住 stdout 与 stderr。
 *
 * 只有一份 fork / 管道实现：一次性执行与流式执行都跑在「任务」上。
 * 任务负责把子进程的状态与读到的输出维护成事件队列；
 * 一次性执行循环泵到结束并把事件累加进两个字符串，
 * 流式执行每次泵只取走一段，剩余的留在队列里。
 *
 * 这一层是「默认实现」：设备上若有别的执行通道，只替换本文件声明的函数即可，
 * 接口与语义见 shell_hook.h 的契约说明。
 */

#include "shell_hook.h"

#include <cerrno>
#include <csignal>
#include <cstring>
#include <ctime>
#include <deque>
#include <fcntl.h>
#include <map>
#include <mutex>
#include <string>
#include <sys/select.h>
#include <sys/wait.h>
#include <unistd.h>

/** 环境变量表。某些 libc 的 <unistd.h> 不声明它，显式声明一次 */
extern char **environ;

namespace pcnative {
namespace {

/** 单路输出的上限。与 ArkTS 侧 `SHELL_OUTPUT_LIMIT_BYTES` 同值 */
const size_t OUTPUT_LIMIT = 8 * 1024 * 1024;

/** 任务里排队等取走的输出上限。与单路上限同值，理由见 `DrainFd` */
const size_t QUEUE_LIMIT = 8 * 1024 * 1024;

/** 一次性执行泵的步长。取 20ms：既能及时读到输出，又不会把 CPU 占满 */
const int POLL_STEP_MS = 20;

/** 终止进程组后升级成 SIGKILL 之前的收尾时间 */
const long TERMINATE_GRACE_MS = 100;

/** `ShellHookKill` 发出 SIGTERM 后的宽限期。到点升级成 SIGKILL */
const long KILL_GRACE_MS = 2000;

/**
 * 子进程被回收后，还允许继续读管道多久。
 *
 * 命令自己会再起子进程，它们可能继承着管道写端。父进程先退出时这些管道不会立刻 EOF，
 * 不设上限就会一直等下去。
 */
const long DRAIN_GRACE_MS = 1000;

/** 一次执行的全部可变状态。生命周期由任务表管理 */
struct ShellHookTask {
    int taskId = 0;
    int outFd = -1;
    int errFd = -1;
    pid_t pid = -1;
    long startedAt = 0;
    /** 截止时刻。到点仍未结束就终止整个进程组 */
    long deadline = 0;
    bool stdoutOpen = true;
    bool stderrOpen = true;
    bool reaped = false;
    int status = 0;
    long reapedAt = 0;
    bool timedOut = false;
    bool limitHit = false;
    /** 收到过中断 / 终止请求。决定信号结束时用不用 `SHELL_ERR_INTERRUPTED` */
    bool stopRequested = false;
    /** 已发出终止信号、等着升级成 SIGKILL */
    bool escalationPending = false;
    long escalationDeadline = 0;
    bool ended = false;
    int exitCode = -1;
    int errorCode = SHELL_OK;
    std::deque<ShellHookEvent> queue;
    size_t queuedBytes = 0;
};

/**
 * 任务表与它的互斥量。
 *
 * 一次性执行可能在 libuv 线程池上跑，也可能在调用方自己的线程上跑，
 * 流式轮询在 JS 线程，三者会同时查表与取任务。
 */
std::mutex g_taskMutex;
std::map<int, ShellHookTask *> g_tasks;
int g_nextTaskId = 1;

long NowMs() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<long>(ts.tv_sec) * 1000L + static_cast<long>(ts.tv_nsec) / 1000000L;
}

ShellHookTask *FindTaskLocked(int taskId) {
    std::map<int, ShellHookTask *>::iterator it = g_tasks.find(taskId);
    return it == g_tasks.end() ? nullptr : it->second;
}

/** 读端设成非阻塞：收尾阶段要在不阻塞的前提下把管道读干 */
void SetNonBlocking(int fd) {
    const int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) {
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    }
}

/**
 * 把一个读端里现成的数据全部搬进事件队列。
 *
 * 返回 false 表示这一路已经 EOF。相邻同类片段就地合并，所以队列里不会出现
 * 一串只有几个字节的 stdout 片段；顺序仍然是到达顺序。
 *
 * 队列满了就停下来不再读：子进程写管道时自己阻塞住，行为与终端里命令被回显速度
 * 限制相同，也不会让内存被一个不停输出的命令撑爆。
 */
bool DrainFd(int fd, int stream, ShellHookTask &task) {
    char buffer[8192];
    while (task.queuedBytes < QUEUE_LIMIT) {
        const ssize_t got = read(fd, buffer, sizeof(buffer));
        if (got > 0) {
            if (!task.queue.empty() && task.queue.back().stream == stream) {
                task.queue.back().data.append(buffer, static_cast<size_t>(got));
            } else {
                ShellHookEvent event;
                event.stream = stream;
                event.data.assign(buffer, static_cast<size_t>(got));
                task.queue.push_back(event);
            }
            task.queuedBytes += static_cast<size_t>(got);
            continue;
        }
        if (got == 0) {
            return false;
        }
        if (errno == EINTR) {
            continue;
        }
        // EAGAIN / EWOULDBLOCK：这次没有数据，等下一轮
        break;
    }
    return true;
}

/**
 * 该发的终止信号在这里发。
 *
 * 宽限期到点把 SIGTERM 升级成 SIGKILL；到截止时刻或输出超限时主动终止整个进程组。
 * 升级成 SIGKILL 依赖有人再调一次泵 —— 流式路径由轮询驱动，一次性执行由循环驱动。
 */
void ApplyStopSignals(ShellHookTask &task, long now) {
    if (task.escalationPending && now >= task.escalationDeadline) {
        task.escalationPending = false;
        if (task.pid > 0) {
            kill(-task.pid, SIGKILL);
        }
    }
    if (task.reaped) {
        return;
    }
    const bool deadlineHit = now >= task.deadline;
    const bool limitHit = task.limitHit;
    if (deadlineHit && !task.stopRequested) {
        task.timedOut = true;
    }
    if ((deadlineHit || limitHit) && !task.escalationPending) {
        task.escalationPending = true;
        task.escalationDeadline = now + TERMINATE_GRACE_MS;
        if (task.pid > 0) {
            kill(-task.pid, SIGTERM);
        }
    }
}

/**
 * 结束判定。管道里的剩余内容读完之后才把任务标记成结束。
 *
 * 顺序反过来会丢掉最后几行输出，而那几行往往正是错误信息。
 */
void SettleIfFinished(ShellHookTask &task) {
    if (task.ended || !task.reaped) {
        return;
    }
    const bool drained = !task.stdoutOpen && !task.stderrOpen;
    const bool graceOver = task.reapedAt > 0 && NowMs() - task.reapedAt >= DRAIN_GRACE_MS;
    if (!drained && !graceOver) {
        return;
    }
    if (!drained) {
        task.stdoutOpen = false;
        task.stderrOpen = false;
    }

    if (task.timedOut) {
        task.errorCode = SHELL_ERR_TIMEOUT;
        task.exitCode = -1;
    } else if (task.limitHit) {
        task.errorCode = SHELL_ERR_OUTPUT;
        task.exitCode = -1;
    } else if (task.stopRequested) {
        // 调用方主动要停它，一律报「已中断」。
        // 不只看 WIFSIGNALED：/bin/sh 收到 SIGINT 后会先转发给子命令，
        // 子命令死了它自己以退出码 0 结束，这时按信号判定就会把「已中断」报成「已完成」
        task.errorCode = SHELL_ERR_INTERRUPTED;
        task.exitCode = -1;
    } else if (WIFEXITED(task.status)) {
        task.errorCode = SHELL_OK;
        task.exitCode = WEXITSTATUS(task.status);
    } else if (WIFSIGNALED(task.status)) {
        // 没有任何主动请求就被信号打死：沿用「没起来」，与一次性执行的现状一致
        task.errorCode = SHELL_ERR_START;
        task.exitCode = -1;
        ShellHookEvent note;
        note.stream = SHELL_STREAM_STDERR;
        note.data = std::string("\nterminated by signal ") + std::to_string(WTERMSIG(task.status));
        if (!task.queue.empty() && task.queue.back().stream == SHELL_STREAM_STDERR) {
            task.queue.back().data.append(note.data);
        } else {
            task.queue.push_back(note);
        }
        task.queuedBytes += note.data.size();
    } else {
        task.errorCode = SHELL_ERR_START;
        task.exitCode = -1;
    }
    task.ended = true;
}

void CloseReadEnds(ShellHookTask &task) {
    if (task.outFd >= 0) {
        close(task.outFd);
        task.outFd = -1;
    }
    if (task.errFd >= 0) {
        close(task.errFd);
        task.errFd = -1;
    }
}

/** 泵一次：处理信号、读管道、回收子进程、判断是否结束 */
void PumpOnce(ShellHookTask &task, int sliceMs) {
    ApplyStopSignals(task, NowMs());

    // 队列已经满了就不再读，否则每次 select 都立刻返回可读，会把线程转成忙等
    if (task.queuedBytes < QUEUE_LIMIT && (task.stdoutOpen || task.stderrOpen)) {
        fd_set readSet;
        FD_ZERO(&readSet);
        int maxFd = -1;
        if (task.stdoutOpen && task.outFd >= 0) {
            FD_SET(task.outFd, &readSet);
            maxFd = task.outFd;
        }
        if (task.stderrOpen && task.errFd >= 0) {
            FD_SET(task.errFd, &readSet);
            if (task.errFd > maxFd) {
                maxFd = task.errFd;
            }
        }

        if (maxFd >= 0) {
            struct timeval wait;
            wait.tv_sec = 0;
            wait.tv_usec = sliceMs > 0 ? sliceMs * 1000 : 0;
            const int ready = select(maxFd + 1, &readSet, nullptr, nullptr, &wait);
            if (ready > 0) {
                if (task.stdoutOpen && task.outFd >= 0 && FD_ISSET(task.outFd, &readSet)) {
                    task.stdoutOpen = DrainFd(task.outFd, SHELL_STREAM_STDOUT, task);
                }
                if (task.stderrOpen && task.errFd >= 0 && FD_ISSET(task.errFd, &readSet)) {
                    task.stderrOpen = DrainFd(task.errFd, SHELL_STREAM_STDERR, task);
                }
            }
        }
    }

    if (!task.reaped && task.pid > 0) {
        int status = 0;
        const pid_t waited = waitpid(task.pid, &status, WNOHANG);
        if (waited == task.pid) {
            task.reaped = true;
            task.status = status;
            task.reapedAt = NowMs();
        }
    }

    SettleIfFinished(task);
    if (task.ended) {
        CloseReadEnds(task);
    }
}

/**
 * 从队首取走事件，最多 `maxBytes` 字节（0 表示不限）。`sink` 非空时同时累加进去
 *
 * 返回值是队列是否已经排空。
 */
bool TakeEvents(ShellHookTask &task, size_t maxBytes, ShellHookPoll *poll, std::string *stdoutSink,
                std::string *stderrSink) {
    size_t taken = 0;
    while (!task.queue.empty()) {
        const ShellHookEvent front = task.queue.front();
        size_t slice = front.data.size();
        if (maxBytes > 0) {
            if (taken >= maxBytes) {
                break;
            }
            if (taken + slice > maxBytes) {
                slice = maxBytes - taken;
            }
        }
        ShellHookEvent piece;
        piece.stream = front.stream;
        piece.data = front.data.substr(0, slice);
        poll->events.push_back(piece);
        if (front.stream == SHELL_STREAM_STDOUT && stdoutSink != nullptr) {
            if (stdoutSink->size() + piece.data.size() > OUTPUT_LIMIT) {
                task.limitHit = true;
            } else {
                stdoutSink->append(piece.data);
            }
        }
        if (front.stream == SHELL_STREAM_STDERR && stderrSink != nullptr) {
            if (stderrSink->size() + piece.data.size() > OUTPUT_LIMIT) {
                task.limitHit = true;
            } else {
                stderrSink->append(piece.data);
            }
        }
        taken += slice;
        if (slice < front.data.size()) {
            ShellHookEvent rest;
            rest.stream = front.stream;
            rest.data = front.data.substr(slice);
            task.queue.front() = rest;
        } else {
            task.queuedBytes -= front.data.size();
            task.queue.pop_front();
        }
    }
    return task.queue.empty();
}

}  // namespace

bool ShellHookAvailable() {
    // fork + execve 在所有支持 POSIX 的设备上都能用，所以能力始终可用。
    // 换成需要外部注册的通道时，这里改成探测注册状态。
    return true;
}

int ShellHookNextTaskId() {
    std::lock_guard<std::mutex> lock(g_taskMutex);
    return g_nextTaskId++;
}

bool ShellHookStart(const std::string &command, int timeoutMs, const std::string &cwd, int taskId,
                    std::string *startError) {
    int outPipe[2] = {-1, -1};
    int errPipe[2] = {-1, -1};
    if (pipe(outPipe) != 0 || pipe(errPipe) != 0) {
        if (startError != nullptr) {
            *startError = std::string("pipe failed: ") + std::strerror(errno);
        }
        if (outPipe[0] >= 0) {
            close(outPipe[0]);
            close(outPipe[1]);
        }
        if (errPipe[0] >= 0) {
            close(errPipe[0]);
            close(errPipe[1]);
        }
        return false;
    }

    const pid_t pid = fork();
    if (pid < 0) {
        if (startError != nullptr) {
            *startError = std::string("fork failed: ") + std::strerror(errno);
        }
        close(outPipe[0]);
        close(outPipe[1]);
        close(errPipe[0]);
        close(errPipe[1]);
        return false;
    }

    if (pid == 0) {
        // 子进程：自成进程组，父进程超时时可以整组清掉（brew 会自己再起子进程）
        setpgid(0, 0);

        // 工作目录换成调用方指定的那个。应用进程的当前目录是 `/`，uid 100 对 `/` 没有读权限，
        // 而 brew 启动时会检查当前目录可读性。换目录失败就退到 `/`，让命令自己报错
        if (!cwd.empty() && chdir(cwd.c_str()) != 0) {
            const int ignored = chdir("/");
            (void)ignored;
        }

        close(outPipe[0]);
        close(errPipe[0]);
        dup2(outPipe[1], STDOUT_FILENO);
        dup2(errPipe[1], STDERR_FILENO);
        close(outPipe[1]);
        close(errPipe[1]);

        const char *shell = "/bin/sh";
        const char *argv[] = {shell, "-c", command.c_str(), nullptr};
        execve(shell, const_cast<char *const *>(argv), environ);
        // execve 返回即失败。写一行到 stderr 让上层能看到原因
        const char *message = "execve /bin/sh failed\n";
        const ssize_t ignored = write(STDERR_FILENO, message, strlen(message));
        (void)ignored;
        _exit(127);
    }

    // 父进程
    setpgid(pid, pid);
    close(outPipe[1]);
    close(errPipe[1]);
    SetNonBlocking(outPipe[0]);
    SetNonBlocking(errPipe[0]);

    std::lock_guard<std::mutex> lock(g_taskMutex);
    if (g_tasks.find(taskId) != g_tasks.end()) {
        close(outPipe[0]);
        close(errPipe[0]);
        return false;
    }

    ShellHookTask *task = new ShellHookTask();
    task->taskId = taskId;
    task->outFd = outPipe[0];
    task->errFd = errPipe[0];
    task->pid = pid;
    task->startedAt = NowMs();
    task->deadline = task->startedAt + (timeoutMs > 0 ? timeoutMs : POLL_STEP_MS);
    g_tasks[taskId] = task;
    return true;
}

bool ShellHookPump(int taskId, size_t maxBytes, int sliceMs, ShellHookPoll *poll,
                   std::string *stdoutSink, std::string *stderrSink) {
    if (poll == nullptr) {
        return false;
    }
    std::lock_guard<std::mutex> lock(g_taskMutex);
    ShellHookTask *task = FindTaskLocked(taskId);
    if (task == nullptr) {
        return false;
    }

    poll->events.clear();
    poll->ended = false;
    poll->exitCode = -1;
    poll->errorCode = SHELL_OK;

    if (!task->ended) {
        PumpOnce(*task, sliceMs);
    }

    const bool drained = TakeEvents(*task, maxBytes, poll, stdoutSink, stderrSink);
    // 队列排空且进程已退出，才对外说「结束了」：maxBytes 截断时上层会继续轮询，不会丢尾部输出
    poll->ended = task->ended && drained;
    if (task->ended) {
        poll->exitCode = task->exitCode;
        poll->errorCode = task->errorCode;
    }
    return true;
}

bool ShellHookInterrupt(int taskId) {
    std::lock_guard<std::mutex> lock(g_taskMutex);
    ShellHookTask *task = FindTaskLocked(taskId);
    if (task == nullptr) {
        return false;
    }
    task->stopRequested = true;
    if (task->pid <= 0 || task->reaped) {
        return false;
    }
    return kill(-task->pid, SIGINT) == 0;
}

bool ShellHookKill(int taskId) {
    std::lock_guard<std::mutex> lock(g_taskMutex);
    ShellHookTask *task = FindTaskLocked(taskId);
    if (task == nullptr) {
        return false;
    }
    task->stopRequested = true;
    if (task->pid <= 0 || task->reaped) {
        return false;
    }
    if (task->escalationPending) {
        // 已经在等升级成 SIGKILL 了，别把宽限期重置回去
        return kill(-task->pid, SIGTERM) == 0;
    }
    task->escalationPending = true;
    task->escalationDeadline = NowMs() + KILL_GRACE_MS;
    return kill(-task->pid, SIGTERM) == 0;
}

void ShellHookRelease(int taskId) {
    std::lock_guard<std::mutex> lock(g_taskMutex);
    ShellHookTask *task = FindTaskLocked(taskId);
    if (task == nullptr) {
        return;
    }
    // 提前释放时子进程可能还活着，回收掉并把整组清掉，不留孤儿与僵尸
    if (task->pid > 0 && !task->reaped) {
        kill(-task->pid, SIGKILL);
        int status = 0;
        while (waitpid(task->pid, &status, 0) < 0 && errno == EINTR) {
        }
    }
    CloseReadEnds(*task);
    g_tasks.erase(taskId);
    delete task;
}

ShellHookResult ShellHookRun(const std::string &command, int timeoutMs, const std::string &cwd) {
    ShellHookResult result;

    const int taskId = ShellHookNextTaskId();
    std::string startError;
    if (!ShellHookStart(command, timeoutMs, cwd, taskId, &startError)) {
        result.errorCode = SHELL_ERR_START;
        result.exitCode = -1;
        result.stderrText = startError;
        return result;
    }

    ShellHookPoll poll;
    // 事件全部被累加进两个字符串，直到任务结束且队列排空
    while (ShellHookPump(taskId, 0, POLL_STEP_MS, &poll, &result.stdoutText, &result.stderrText)) {
        if (poll.ended) {
            break;
        }
    }
    ShellHookPump(taskId, 0, 0, &poll, &result.stdoutText, &result.stderrText);

    result.errorCode = poll.ended ? poll.errorCode : SHELL_ERR_START;
    result.exitCode = poll.ended ? poll.exitCode : -1;
    ShellHookRelease(taskId);
    return result;
}

}  // namespace pcnative