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

/** 异步执行一条命令行。`timeoutMs` 缺省 10000，上限 1800000；`cwd` 是子进程的工作目录，空串时用 `/` */
export const runCommand: (command: string, timeoutMs?: number, cwd?: string) => Promise<ShellNativeResult>;

/** 同步执行。会阻塞调用线程，只在确定是毫秒级的场景使用 */
export const runCommandSync: (command: string, timeoutMs?: number, cwd?: string) => ShellNativeResult;

/** 一次轮询里的一段增量输出 */
export interface ShellNativeStreamEvent {
  /** 'stdout' | 'stderr' */
  kind: string;
  data: string;
}

/** 一次流式轮询的结果 */
export interface ShellNativeStreamPoll {
  /** 按到达顺序排列，相邻同类已合并 */
  events: ShellNativeStreamEvent[];
  /** 任务已结束，且管道里的剩余内容已全部取走 */
  ended: boolean;
  exitCode: number;
  errorCode: number;
}

/** 启动一条命令并立刻返回任务标识，不等它结束。`null` 表示没起来 */
export const startCommand: (command: string, timeoutMs?: number, cwd?: string) => number | null;

/**
 * 取走新增输出。`maxBytes` 是本次读取上限，缺省 256KB。
 * 不做任何等待，可以直接在 JS 线程上调用；任务不存在返回 `null`
 */
export const pollCommand: (taskId: number, maxBytes?: number) => ShellNativeStreamPoll | null;

/** 向整个进程组发 SIGINT（等同终端 Ctrl+C）。返回信号是否送达 */
export const interruptCommand: (taskId: number) => boolean;

/** 终止：SIGTERM，宽限 2 秒后 SIGKILL。返回信号是否送达 */
export const killCommand: (taskId: number) => boolean;

/** 释放任务。命令结束后调用一次 */
export const releaseCommand: (taskId: number) => void;
