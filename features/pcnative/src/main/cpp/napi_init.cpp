/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

/*
 * NAPI 层：把 `ShellHookRun` 暴露给 ArkTS。
 *
 * 只做三件事：参数校验、线程调度、结果转换。执行语义全在 shell_hook.cpp，
 * 这里的代码不关心命令是怎么跑起来的。
 *
 * 线程：异步接口用 libuv 的线程池，绝不在主线程上跑命令；同步接口留给确定是毫秒级的探测。
 * 两个接口都只读共享的 `ShellHookRun`，自身不持有可变状态。
 */

#include "napi/native_api.h"
#include "shell_hook.h"

#include <cstdlib>
#include <string>

namespace {

const int TIMEOUT_DEFAULT_MS = 10000;
const int TIMEOUT_MAX_MS = 600000;

/** 异步执行的上下文。结果写回 ArkTS 对象在 Complete 回调里做 */
struct RunContext {
    std::string command;
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
    context->result = pcnative::ShellHookRun(context->command, context->timeoutMs);
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

/** `runCommand(command: string, timeoutMs?: number): Promise<ShellResult>` */
napi_value RunCommand(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
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

/** `runCommandSync(command: string, timeoutMs?: number): ShellResult` */
napi_value RunCommandSync(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string command = GetStringArg(env, args[0]);
    if (command.empty()) {
        napi_throw_type_error(env, nullptr, "command must be a non-empty string");
        return nullptr;
    }
    const int timeoutMs = GetIntArg(env, args[1], TIMEOUT_DEFAULT_MS);

    pcnative::ShellHookResult result = pcnative::ShellHookRun(command, timeoutMs);
    return ToJsResult(env, result);
}

napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor descriptors[] = {
        {"isAvailable", nullptr, IsAvailable, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"runCommand", nullptr, RunCommand, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"runCommandSync", nullptr, RunCommandSync, nullptr, nullptr, nullptr, napi_default, nullptr},
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
