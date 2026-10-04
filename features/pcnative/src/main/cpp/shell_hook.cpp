/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

/*
 * 执行通道的默认实现。
 *
 * 用 POSIX 的 fork + execve 起一个 shell 跑命令行，用管道分别接住 stdout 与 stderr，
 * 超时或输出超限时终止整个进程组。
 *
 * 这一层是「默认实现」：设备上若有别的执行通道，只替换本文件的两个函数即可，
 * 接口与语义见 shell_hook.h 的契约说明。
 */

#include "shell_hook.h"

#include <cerrno>
#include <csignal>
#include <cstring>
#include <ctime>
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

/** 轮询的步长。取 20ms：既能及时读到输出，又不会把 CPU 占满 */
const int POLL_STEP_MS = 20;

/** 读到文件描述符关闭时返回真。EINTR 视为「继续读」 */
bool ReadAvailable(int fd, std::string &sink, bool &limitHit) {
    char buffer[4096];
    while (true) {
        ssize_t got = read(fd, buffer, sizeof(buffer));
        if (got > 0) {
            if (sink.size() + static_cast<size_t>(got) > OUTPUT_LIMIT) {
                limitHit = true;
                return false;
            }
            sink.append(buffer, static_cast<size_t>(got));
            continue;
        }
        if (got == 0) {
            return false;
        }
        if (errno == EINTR) {
            continue;
        }
        // EAGAIN / EWOULDBLOCK：这次没有数据，等下一轮
        return true;
    }
}

long NowMs() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<long>(ts.tv_sec) * 1000L + static_cast<long>(ts.tv_nsec) / 1000000L;
}

/** 终止整个进程组。先 SIGTERM，再 SIGKILL；两次之间给一点收尾时间 */
void TerminateGroup(pid_t pid) {
    if (pid <= 0) {
        return;
    }
    kill(-pid, SIGTERM);
    struct timespec ts;
    ts.tv_sec = 0;
    ts.tv_nsec = 100L * 1000L * 1000L;
    nanosleep(&ts, nullptr);
    kill(-pid, SIGKILL);
}

}  // namespace

bool ShellHookAvailable() {
    // fork + execve 在所有支持 POSIX 的设备上都能用，所以能力始终可用。
    // 换成需要外部注册的通道时，这里改成探测注册状态。
    return true;
}

ShellHookResult ShellHookRun(const std::string &command, int timeoutMs) {
    ShellHookResult result;

    int outPipe[2] = {-1, -1};
    int errPipe[2] = {-1, -1};
    if (pipe(outPipe) != 0 || pipe(errPipe) != 0) {
        result.errorCode = SHELL_ERR_START;
        result.stderrText = std::string("pipe failed: ") + std::strerror(errno);
        if (outPipe[0] >= 0) {
            close(outPipe[0]);
            close(outPipe[1]);
        }
        return result;
    }

    pid_t pid = fork();
    if (pid < 0) {
        result.errorCode = SHELL_ERR_START;
        result.stderrText = std::string("fork failed: ") + std::strerror(errno);
        close(outPipe[0]);
        close(outPipe[1]);
        close(errPipe[0]);
        close(errPipe[1]);
        return result;
    }

    if (pid == 0) {
        // 子进程：自成进程组，父进程超时时可以整组清掉（brew 会自己再起子进程）
        setpgid(0, 0);
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
        ssize_t ignored = write(STDERR_FILENO, message, strlen(message));
        (void)ignored;
        _exit(127);
    }

    // 父进程
    setpgid(pid, pid);
    close(outPipe[1]);
    close(errPipe[1]);

    const long startedAt = NowMs();
    bool stdoutOpen = true;
    bool stderrOpen = true;
    bool limitHit = false;
    bool timedOut = false;

    while (stdoutOpen || stderrOpen) {
        if (NowMs() - startedAt >= timeoutMs) {
            timedOut = true;
            break;
        }

        fd_set readSet;
        FD_ZERO(&readSet);
        int maxFd = -1;
        if (stdoutOpen) {
            FD_SET(outPipe[0], &readSet);
            maxFd = outPipe[0];
        }
        if (stderrOpen) {
            FD_SET(errPipe[0], &readSet);
            if (errPipe[0] > maxFd) {
                maxFd = errPipe[0];
            }
        }

        struct timeval wait;
        wait.tv_sec = 0;
        wait.tv_usec = POLL_STEP_MS * 1000;
        const int ready = select(maxFd + 1, &readSet, nullptr, nullptr, &wait);
        if (ready < 0 && errno != EINTR) {
            break;
        }
        if (ready <= 0) {
            continue;
        }

        if (stdoutOpen && FD_ISSET(outPipe[0], &readSet)) {
            stdoutOpen = ReadAvailable(outPipe[0], result.stdoutText, limitHit);
        }
        if (stderrOpen && FD_ISSET(errPipe[0], &readSet)) {
            stderrOpen = ReadAvailable(errPipe[0], result.stderrText, limitHit);
        }
        if (limitHit) {
            break;
        }
    }

    if (timedOut || limitHit) {
        TerminateGroup(pid);
    }

    // 收尾：即使已经决定超时，也把进程 wait 掉，避免留下僵尸进程
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
    }

    // 把管道里剩下的内容读出来。已经读到 EOF 的一路跳过
    bool ignoredLimit = false;
    if (stdoutOpen) {
        ReadAvailable(outPipe[0], result.stdoutText, ignoredLimit);
    }
    if (stderrOpen) {
        ReadAvailable(errPipe[0], result.stderrText, ignoredLimit);
    }
    close(outPipe[0]);
    close(errPipe[0]);

    if (timedOut) {
        result.errorCode = SHELL_ERR_TIMEOUT;
        result.exitCode = -1;
        return result;
    }
    if (limitHit) {
        result.errorCode = SHELL_ERR_OUTPUT;
        result.exitCode = -1;
        return result;
    }
    if (WIFEXITED(status)) {
        result.errorCode = SHELL_OK;
        result.exitCode = WEXITSTATUS(status);
        return result;
    }
    if (WIFSIGNALED(status)) {
        // 被信号打断（例如自己发的 SIGTERM 落在还没超时的分支上）
        result.errorCode = SHELL_ERR_START;
        result.exitCode = -1;
        result.stderrText += std::string("\nterminated by signal ") + std::to_string(WTERMSIG(status));
        return result;
    }

    result.errorCode = SHELL_ERR_START;
    result.exitCode = -1;
    return result;
}

}  // namespace pcnative
