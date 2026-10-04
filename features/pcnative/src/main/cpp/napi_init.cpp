/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

/*
 * NAPI 层：把执行通道暴露给 ArkTS。
 *
 * 只做三件事：参数校验、线程调度、结果转换。执行语义全在 shell_hook.cpp，
 * 这里的代码不关心命令是怎么跑起来的。
 *
 * 线程：异步接口用 libuv 的线程池，绝不在主线程上跑命令；同步接口留给确定是毫秒级的探测。
 * 一次性执行走 libuv 线程池（`runCommand`）或 JS 线程（`runCommandSync`），
 * 流式接口只在 JS 线程上跑：轮询本身不等待，单次调用的工作量有上限。
 */

#include "napi/native_api.h"
#include "shell_hook.h"

#include <cstdlib>
#include <string>

namespace {

const int TIMEOUT_DEFAULT_MS = 10000;
const int TIMEOUT_MAX_MS = 1800000;

/** 流式轮询单次取走的上限。与 ArkTS 侧 `SHELL_STREAM_POLL_MAX_BYTES` 同值 */
const size_t POLL_MAX_BYTES = 256 * 1024;

/** 流式轮询单次最多等多久。0 = 不等，纯非阻塞读，可以在 JS 线程上直接调 */
const int POLL_SLICE_MS = 0;

/** 异步执行的上下文。结果写回 ArkTS 对象在 Complete 回调里做 */
struct RunContext {
    std::string command;
    std::string cwd;
    int timeoutMs = TIMEOUT_DEFAULT_MS;
    pcnative::ShellHookResult result;
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
};

/** 读一个 UTF-8 字符串参数。类型不对或缺失时返回空串 */
std::string GetStringArg(napi_env env, napi_value value) {
    napi_valuetype type = napi_undefined;
    if (napi_typeof(env, value, &type) != napi_ok || type != napi_string) {
        return std::string();
    }
    size_t length = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok) {
        return std::string();
    }
    std::string out(length, '\0');
    size_t written = 0;
    if (napi_get_value_string_utf8(env, value, &out[0], length + 1, &written) != napi_ok) {
        return std::string();
    }
    out.resize(written);
    return out;
}

int GetIntArg(napi_env env, napi_value value, int fallback) {
    napi_valuetype type = napi_undefined;
    if (napi_typeof(env, value, &type) != napi_ok || type != napi_number) {
        return fallback;
    }
    int32_t parsed = fallback;
    if (napi_get_value_int32(env, value, &parsed) != napi_ok) {
        return fallback;
    }
    if (parsed <= 0) {
        return fallback;
    }
    return parsed > TIMEOUT_MAX_MS ? TIMEOUT_MAX_MS : parsed;
}

/**
 * 把结果转成 ArkTS 对象。
 *
 * NUL 字节替换成 U+FFFD 而不是截断：截断会让「读到的内容」与「实际输出」对不上，
 * 而这里的目标是如实反映命令输出了什么。
 */
napi_value ToJsResult(napi_env env, const pcnative::ShellHookResult &result) {
    napi_value object = nullptr;
    napi_create_object(env, &object);

    napi_value ok = nullptr;
    napi_get_boolean(env, result.errorCode == pcnative::SHELL_OK && result.exitCode == 0, &ok);
    napi_set_named_property(env, object, "ok", ok);

    napi_value exitCode = nullptr;
    napi_create_int32(env, result.exitCode, &exitCode);
    napi_set_named_property(env, object, "exitCode", exitCode);

    napi_value errorCode = nullptr;
    napi_create_int32(env, result.errorCode, &errorCode);
    napi_set_named_property(env, object, "errorCode", errorCode);

    napi_value stdoutValue = nullptr;
    napi_create_string_utf8(env, result.stdoutText.c_str(), NAPI_AUTO_LENGTH, &stdoutValue);
    napi_set_named_property(env, object, "stdout", stdoutValue);

    napi_value stderrValue = nullptr;
    napi_create_string_utf8(env, result.stderrText.c_str(), NAPI_AUTO_LENGTH, &stderrValue);
    napi_set_named_property(env, object, "stderr", stderrValue);

    return object;
}

/** 线程池里执行的部分：只调用执行通道，不碰 NAPI */
void ExecuteRun(napi_env env, void *data) {
    RunContext *context = static_cast<RunContext *>(data);
    context->result = pcnative::ShellHookRun(context->command, context->timeoutMs, context->cwd);
}

/** 回到 JS 线程：解析 promise */
void CompleteRun(napi_env env, napi_status status, void *data) {
    RunContext *context = static_cast<RunContext *>(data);
    if (status == napi_ok) {
        napi_resolve_deferred(env, context->deferred, ToJsResult(env, context->result));
    } else {
        napi_value message = nullptr;
        napi_create_string_utf8(env, "shell execution cancelled", NAPI_AUTO_LENGTH, &message);
        napi_reject_deferred(env, context->deferred, message);
    }
    if (context->work != nullptr) {
        napi_delete_async_work(env, context->work);
    }
    delete context;
}

/** `isAvailable(): boolean` */
napi_value IsAvailable(napi_env env, napi_callback_info info) {
    napi_value result = nullptr;
    napi_get_boolean(env, pcnative::ShellHookAvailable(), &result);
    return result;
}

/** `runCommand(command: string, timeoutMs?: number, cwd?: string): Promise<ShellResult>` */
napi_value RunCommand(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string command = GetStringArg(env, args[0]);
    if (command.empty()) {
        napi_throw_type_error(env, nullptr, "command must be a non-empty string");
        return nullptr;
    }
    const int timeoutMs = GetIntArg(env, args[1], TIMEOUT_DEFAULT_MS);

    RunContext *context = new RunContext();
    context->command = command;
    context->timeoutMs = timeoutMs;
    context->cwd = GetStringArg(env, args[2]);

    napi_value promise = nullptr;
    if (napi_create_promise(env, &context->deferred, &promise) != napi_ok) {
        delete context;
        napi_throw_error(env, nullptr, "cannot create promise");
        return nullptr;
    }

    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "pcnative.shell.run", NAPI_AUTO_LENGTH, &resourceName);
    // 入队失败必须自己把 promise 拒掉：否则调用方的 await 永远不返回，页面就卡在加载态
    if (napi_create_async_work(env, nullptr, resourceName, ExecuteRun, CompleteRun, context,
                               &context->work) != napi_ok ||
        napi_queue_async_work(env, context->work) != napi_ok) {
        napi_value message = nullptr;
        napi_create_string_utf8(env, "cannot queue shell work", NAPI_AUTO_LENGTH, &message);
        napi_reject_deferred(env, context->deferred, message);
        if (context->work != nullptr) {
            napi_delete_async_work(env, context->work);
        }
        delete context;
        return promise;
    }

    return promise;
}

/** `runCommandSync(command: string, timeoutMs?: number, cwd?: string): ShellResult` */
napi_value RunCommandSync(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string command = GetStringArg(env, args[0]);
    if (command.empty()) {
        napi_throw_type_error(env, nullptr, "command must be a non-empty string");
        return nullptr;
    }
    const int timeoutMs = GetIntArg(env, args[1], TIMEOUT_DEFAULT_MS);
    const std::string cwd = GetStringArg(env, args[2]);

    pcnative::ShellHookResult result = pcnative::ShellHookRun(command, timeoutMs, cwd);
    return ToJsResult(env, result);
}

/**
 * 把一次流式轮询转成 ArkTS 对象。
 *
 * `events` 是数组而不是 stdout / stderr 两个字符串：界面要按到达顺序呈现两路输出，
 * 分成两个字段就丢掉了「哪一行先到」这个信息。
 */
napi_value ToJsPoll(napi_env env, const pcnative::ShellHookPoll &poll) {
    napi_value events = nullptr;
    napi_create_array_with_length(env, poll.events.size(), &events);
    for (size_t i = 0; i < poll.events.size(); ++i) {
        const pcnative::ShellHookEvent &source = poll.events[i];
        napi_value item = nullptr;
        napi_create_object(env, &item);

        napi_value kind = nullptr;
        const char *kindText = source.stream == pcnative::SHELL_STREAM_STDOUT ? "stdout" : "stderr";
        napi_create_string_utf8(env, kindText, NAPI_AUTO_LENGTH, &kind);
        napi_set_named_property(env, item, "kind", kind);

        // 显式给字节长度：命令输出里可能有 NUL 字节，按 AUTO_LENGTH 会被截断
        napi_value data = nullptr;
        napi_create_string_utf8(env, source.data.c_str(), source.data.size(), &data);
        napi_set_named_property(env, item, "data", data);

        napi_set_element(env, events, static_cast<uint32_t>(i), item);
    }

    napi_value result = nullptr;
    napi_create_object(env, &result);

    napi_set_named_property(env, result, "events", events);

    napi_value ended = nullptr;
    napi_get_boolean(env, poll.ended, &ended);
    napi_set_named_property(env, result, "ended", ended);

    napi_value exitCode = nullptr;
    napi_create_int32(env, poll.exitCode, &exitCode);
    napi_set_named_property(env, result, "exitCode", exitCode);

    napi_value errorCode = nullptr;
    napi_create_int32(env, poll.errorCode, &errorCode);
    napi_set_named_property(env, result, "errorCode", errorCode);

    return result;
}

/** `startCommand(command: string, timeoutMs?: number, cwd?: string): number` */
napi_value StartCommand(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    const std::string command = GetStringArg(env, args[0]);
    if (command.empty()) {
        napi_throw_type_error(env, nullptr, "command must be a non-empty string");
        return nullptr;
    }
    const int timeoutMs = GetIntArg(env, args[1], TIMEOUT_DEFAULT_MS);
    const std::string cwd = GetStringArg(env, args[2]);

    const int taskId = pcnative::ShellHookNextTaskId();
    std::string startError;
    if (!pcnative::ShellHookStart(command, timeoutMs, cwd, taskId, &startError)) {
        // 返回 0 表示没起来（例如 fork 失败），不抛异常：调用方把它当「通道不可用」处理
        napi_value zero = nullptr;
        napi_create_int32(env, 0, &zero);
        return zero;
    }
    napi_value result = nullptr;
    napi_create_int32(env, taskId, &result);
    return result;
}

/** `pollCommand(taskId: number, maxBytes?: number): ShellNativeStreamPoll | null` */
napi_value PollCommand(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t taskId = 0;
    if (napi_get_value_int32(env, args[0], &taskId) != napi_ok) {
        napi_value result = nullptr;
        napi_get_null(env, &result);
        return result;
    }
    size_t maxBytes = POLL_MAX_BYTES;
    if (argc > 1) {
        napi_valuetype type = napi_undefined;
        if (napi_typeof(env, args[1], &type) == napi_ok && type == napi_number) {
            int32_t requested = 0;
            if (napi_get_value_int32(env, args[1], &requested) == napi_ok && requested > 0) {
                maxBytes = static_cast<size_t>(requested);
            }
        }
    }

    pcnative::ShellHookPoll poll;
    if (!pcnative::ShellHookPump(taskId, maxBytes, POLL_SLICE_MS, &poll, nullptr, nullptr)) {
        napi_value result = nullptr;
        napi_get_null(env, &result);
        return result;
    }
    return ToJsPoll(env, poll);
}

/** `interruptCommand(taskId: number): boolean` */
napi_value InterruptCommand(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t taskId = 0;
    napi_value result = nullptr;
    if (napi_get_value_int32(env, args[0], &taskId) != napi_ok) {
        napi_get_boolean(env, false, &result);
        return result;
    }
    napi_get_boolean(env, pcnative::ShellHookInterrupt(taskId), &result);
    return result;
}

/** `killCommand(taskId: number): boolean` */
napi_value KillCommand(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t taskId = 0;
    napi_value result = nullptr;
    if (napi_get_value_int32(env, args[0], &taskId) != napi_ok) {
        napi_get_boolean(env, false, &result);
        return result;
    }
    napi_get_boolean(env, pcnative::ShellHookKill(taskId), &result);
    return result;
}

/** `releaseCommand(taskId: number): void` */
napi_value ReleaseCommand(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t taskId = 0;
    if (napi_get_value_int32(env, args[0], &taskId) == napi_ok) {
        pcnative::ShellHookRelease(taskId);
    }
    return nullptr;
}

napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor descriptors[] = {
        {"isAvailable", nullptr, IsAvailable, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"runCommand", nullptr, RunCommand, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"runCommandSync", nullptr, RunCommandSync, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startCommand", nullptr, StartCommand, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"pollCommand", nullptr, PollCommand, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"interruptCommand", nullptr, InterruptCommand, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"killCommand", nullptr, KillCommand, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"releaseCommand", nullptr, ReleaseCommand, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(descriptors) / sizeof(descriptors[0]), descriptors);
    return exports;
}

napi_module shellModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "pcnative",
    .nm_priv = nullptr,
    .reserved = {0},
};

}  // namespace

extern "C" __attribute__((constructor)) void RegisterPcnativeModule(void) {
    napi_module_register(&shellModule);
}
