/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { Logger } from '@ohos/common';
import shellNative from 'libpcnative.so';
import type {
  ShellNativeResult,
  ShellNativeStreamEvent,
  ShellNativeStreamPoll,
} from 'libpcnative.so';
import {
  SHELL_DEFAULT_WORKING_DIRECTORY,
  SHELL_ERR_NONE,
  SHELL_ERR_START,
  SHELL_ERR_UNAVAILABLE,
  SHELL_STREAM_POLL_MAX_BYTES,
  SHELL_TIMEOUT_DEFAULT_MS,
  SHELL_TIMEOUT_MAX_MS,
  ShellResult,
  ShellStreamEvent,
  ShellStreamPoll,
} from '../constant/ShellConstants';

const TAG: string = '[pcnative]';

/**
 * 把 NAPI 的返回值转成 `ShellResult`。
 *
 * 写成显式构造而不是直接把对象当返回值：ArkTS 不允许结构化类型（`arkts-no-structural-typing`），
 * 两个形状相同但名字不同的接口之间不能直接赋值。
 */
function toShellResult(raw: ShellNativeResult): ShellResult {
  return new ShellResult(
    raw.ok,
    raw.exitCode,
    raw.stdout,
    raw.stderr,
    raw.errorCode === undefined ? SHELL_ERR_NONE : raw.errorCode,
  );
}

/**
 * 把 NAPI 的轮询返回值转成 `ShellStreamPoll`。
 *
 * 同样逐个构造实例，理由与 `toShellResult` 相同；NAPI 返回的 `events` 数组不是 ArkTS 数组实例。
 */
function toShellStreamPoll(raw: ShellNativeStreamPoll): ShellStreamPoll {
  const events: ShellStreamEvent[] = [];
  for (let index = 0; index < raw.events.length; index++) {
    const source: ShellNativeStreamEvent = raw.events[index];
    events.push(new ShellStreamEvent(source.kind, source.data));
  }
  return new ShellStreamPoll(events, raw.ended, raw.exitCode, raw.errorCode);
}

/**
 * 设备上执行命令的入口。
 *
 * 平台执行能力由 `src/main/cpp/shell_hook.cpp` 提供，能力本身不在本模块里；
 * 这里只做三件事：调用、把「能力不可用」收敛成 `SHELL_ERR_UNAVAILABLE`、
 * 把超时参数限制在合法区间。
 *
 * 命令交给系统 shell 解释，所以管道、重定向、`&&`、命令替换都能用；
 * stdout 与 stderr 分别采集；子进程继承调用方设置的环境变量。
 */
export class ShellUtils {
  /**
   * 平台执行能力是否可用。
   *
   * 判定依据是 NAPI 侧探测到的通道状态，不执行任何命令 —— 它可以在任何时机调用，
   * 包括页面构建期。不可用时所有 `run` 都会返回 `SHELL_ERR_UNAVAILABLE`。
   */
  public static available(): boolean {
    try {
      return shellNative.isAvailable();
    } catch (error) {
      Logger.error(TAG, `isAvailable threw: ${error.message}`);
      return false;
    }
  }

  /**
   * 执行一条命令并等待结果。
   *
   * 失败不抛异常，一律以 `ShellResult` 表达：调用方按 `errorCode` 分段判定，
   * 不要把「命令非零退出」与「命令没跑起来」混成一个布尔值。
   *
   * `cwd` 是子进程的工作目录，缺省用 `SHELL_DEFAULT_WORKING_DIRECTORY`。
   */
  public static async run(command: string, timeoutMs: number = SHELL_TIMEOUT_DEFAULT_MS,
    cwd: string = SHELL_DEFAULT_WORKING_DIRECTORY): Promise<ShellResult> {
    const budget: number = ShellUtils.clampTimeout(timeoutMs);
    if (command.length === 0) {
      return ShellResult.failure(SHELL_ERR_START);
    }
    try {
      const raw: ShellNativeResult = await shellNative.runCommand(command, budget, cwd);
      if (!raw) {
        return ShellResult.failure(SHELL_ERR_UNAVAILABLE);
      }
      return toShellResult(raw);
    } catch (error) {
      // NAPI 侧承诺不抛异常，走到这里说明调用本身出了问题（参数类型、模块未加载）
      Logger.error(TAG, `run failed: ${error.message}`);
      return ShellResult.failure(SHELL_ERR_START);
    }
  }

  /**
   * 同步执行。**禁止在主线程调用** —— 它会阻塞到命令结束或超时。
   * 只有子进程/任务线程或确定是毫秒级的探测才用它。
   */
  public static runSync(command: string, timeoutMs: number = SHELL_TIMEOUT_DEFAULT_MS,
    cwd: string = SHELL_DEFAULT_WORKING_DIRECTORY): ShellResult {
    const budget: number = ShellUtils.clampTimeout(timeoutMs);
    if (command.length === 0) {
      return ShellResult.failure(SHELL_ERR_START);
    }
    try {
      const raw: ShellNativeResult = shellNative.runCommandSync(command, budget, cwd);
      if (!raw) {
        return ShellResult.failure(SHELL_ERR_UNAVAILABLE);
      }
      return toShellResult(raw);
    } catch (error) {
      Logger.error(TAG, `runSync failed: ${error.message}`);
      return ShellResult.failure(SHELL_ERR_START);
    }
  }

  /** `command -v` 判定。命令存在返回真，通道不可用或不存在返回假 */
  public static exists(name: string): boolean {
    if (name.length === 0) {
      return false;
    }
    const result: ShellResult = ShellUtils.runSync(`command -v ${name}`, 5000);
    return result.ok && result.stdout.trim().length > 0;
  }

  /**
   * 启动一条命令并立刻返回，不等它结束。
   *
   * 与 `run` 的区别在输出：命令的输出不会一次返回，而是通过 `pollStream` 按到达顺序增量取走。
   * 适合输出很多、耗时很长、需要边跑边看的命令（安装、升级）。短命令仍然用 `run`。
   *
   * 返回 0 表示命令没起来，调用方不要再对它调 `interruptStream` / `releaseStream`。
   */
  public static startStream(command: string, timeoutMs: number = SHELL_TIMEOUT_DEFAULT_MS,
    cwd: string = SHELL_DEFAULT_WORKING_DIRECTORY): number {
    if (command.length === 0) {
      return 0;
    }
    try {
      const taskId: number | null = shellNative.startCommand(command, ShellUtils.clampTimeout(timeoutMs), cwd);
      if (taskId === null || taskId === undefined) {
        return 0;
      }
      return taskId;
    } catch (error) {
      Logger.error(TAG, `startStream failed: ${error.message}`);
      return 0;
    }
  }

  /**
   * 取走自上次调用之后新增的输出。
   *
   * `maxBytes` 是本次读取上限，缺省 `SHELL_STREAM_POLL_MAX_BYTES`。
   * 原生侧不累计已被取走的内容，所以高频轮询不会让内存跟着输出量涨；
   * 调用方取慢时子进程会自己阻塞在写管道上，行为与终端里命令被回显速度限制相同。
   *
   * 不做任何等待，可以直接在 UI 线程上按固定周期调用。
   * 任务不存在（已释放或标识无效）返回 `null`。
   *
   * `ended` 为真时管道里的内容已经全部取走，所以调用方可以「一直轮到 `ended` 为真为止」，
   * 不会因为 `maxBytes` 截断而丢掉尾部输出。
   */
  public static pollStream(taskId: number, maxBytes: number = SHELL_STREAM_POLL_MAX_BYTES): ShellStreamPoll | null {
    if (taskId <= 0) {
      return null;
    }
    try {
      const raw: ShellNativeStreamPoll | null = shellNative.pollCommand(taskId, maxBytes);
      if (raw === null || raw === undefined) {
        return null;
      }
      return toShellStreamPoll(raw);
    } catch (error) {
      Logger.error(TAG, `pollStream failed: ${error.message}`);
      return null;
    }
  }

  /**
   * 向整个进程组发 SIGINT，等同于终端里的 Ctrl+C。
   *
   * 信号发给进程组而不是最外层那个进程：命令会自己再起子进程（brew 就是如此），
   * 只打断最外层会让子进程留在设备上继续跑。
   */
  public static interruptStream(taskId: number): boolean {
    if (taskId <= 0) {
      return false;
    }
    try {
      return shellNative.interruptCommand(taskId);
    } catch (error) {
      Logger.error(TAG, `interruptStream failed: ${error.message}`);
      return false;
    }
  }

  /**
   * 终止：SIGTERM，宽限 2 秒后 SIGKILL。
   *
   * 给命令留一点自己收尾的时间（brew 收到信号后可能先删半成品再退），超时才强杀。
   * 返回的是信号是否送达，不是「命令是否已经结束」。
   */
  public static killStream(taskId: number): boolean {
    if (taskId <= 0) {
      return false;
    }
    try {
      return shellNative.killCommand(taskId);
    } catch (error) {
      Logger.error(TAG, `killStream failed: ${error.message}`);
      return false;
    }
  }

  /** 释放任务。命令结束后调用一次；提前释放会把还在跑的进程组清掉 */
  public static releaseStream(taskId: number): void {
    if (taskId <= 0) {
      return;
    }
    try {
      shellNative.releaseCommand(taskId);
    } catch (error) {
      Logger.error(TAG, `releaseStream failed: ${error.message}`);
    }
  }

  private static clampTimeout(timeoutMs: number): number {
    if (!timeoutMs || timeoutMs <= 0) {
      return SHELL_TIMEOUT_DEFAULT_MS;
    }
    return timeoutMs > SHELL_TIMEOUT_MAX_MS ? SHELL_TIMEOUT_MAX_MS : timeoutMs;
  }
}
