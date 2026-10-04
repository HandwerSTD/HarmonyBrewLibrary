/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { Logger } from '@ohos/common';
import shellNative from 'libpcnative.so';
import type { ShellNativeResult } from 'libpcnative.so';
import {
  SHELL_ERR_NONE,
  SHELL_ERR_START,
  SHELL_ERR_UNAVAILABLE,
  SHELL_TIMEOUT_DEFAULT_MS,
  SHELL_TIMEOUT_MAX_MS,
  ShellResult,
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
   */
  public static async run(command: string, timeoutMs: number = SHELL_TIMEOUT_DEFAULT_MS): Promise<ShellResult> {
    const budget: number = ShellUtils.clampTimeout(timeoutMs);
    if (command.length === 0) {
      return ShellResult.failure(SHELL_ERR_START);
    }
    try {
      const raw: ShellNativeResult = await shellNative.runCommand(command, budget);
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
  public static runSync(command: string, timeoutMs: number = SHELL_TIMEOUT_DEFAULT_MS): ShellResult {
    const budget: number = ShellUtils.clampTimeout(timeoutMs);
    if (command.length === 0) {
      return ShellResult.failure(SHELL_ERR_START);
    }
    try {
      const raw: ShellNativeResult = shellNative.runCommandSync(command, budget);
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

  private static clampTimeout(timeoutMs: number): number {
    if (!timeoutMs || timeoutMs <= 0) {
      return SHELL_TIMEOUT_DEFAULT_MS;
    }
    return timeoutMs > SHELL_TIMEOUT_MAX_MS ? SHELL_TIMEOUT_MAX_MS : timeoutMs;
  }
}
