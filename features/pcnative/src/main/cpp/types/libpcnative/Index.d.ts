/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

/**
 * `libpcnative.so` 的类型声明。
 *
 * 字段与 `napi_init.cpp` 里构造的对象一一对应；错误码取值见
 * `src/main/ets/constant/ShellConstants.ets`。ArkTS 侧不直接使用本文件，
 * 统一经 `ShellUtils` 调用。
 */
export interface ShellNativeResult {
  ok: boolean;
  exitCode: number;
  stdout: string;
  stderr: string;
  errorCode: number;
}

/** 平台执行能力是否可用。不执行命令 */
export const isAvailable: () => boolean;

/** 异步执行一条命令行。`timeoutMs` 缺省 10000，上限 600000；`cwd` 是子进程的工作目录，空串时用 `/` */
export const runCommand: (command: string, timeoutMs?: number, cwd?: string) => Promise<ShellNativeResult>;

/** 同步执行。会阻塞调用线程，只在确定是毫秒级的场景使用 */
export const runCommandSync: (command: string, timeoutMs?: number, cwd?: string) => ShellNativeResult;
