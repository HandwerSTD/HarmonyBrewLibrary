/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

/**
 * 执行通道的常量与结果形状。
 *
 * 错误码分段是调用方的判据来源：`0` 与 `-1` 是「命令跑完了」（看退出码），
 * `1001`–`1004` 是「命令没跑完」（看错误码）。上层不要把两者混成一个布尔值判断。
 */

/** 命令正常退出 */
export const SHELL_ERR_NONE: number = 0;
/** 命令非零退出。`ShellResult.exitCode` 里有真实退出码 */
export const SHELL_ERR_EXIT: number = -1;
/** 平台执行能力不可用 */
export const SHELL_ERR_UNAVAILABLE: number = 1001;
/** 启动失败（可执行文件不存在、权限不足等） */
export const SHELL_ERR_START: number = 1002;
/** 超时，进程已被终止 */
export const SHELL_ERR_TIMEOUT: number = 1003;
/** 输出超过上限，进程已被终止 */
export const SHELL_ERR_OUTPUT_LIMIT: number = 1004;

/** 默认超时：10 秒 */
export const SHELL_TIMEOUT_DEFAULT_MS: number = 10000;
/** 超时上限：10 分钟。防止调用方传一个过大的值把进程挂死 */
export const SHELL_TIMEOUT_MAX_MS: number = 600000;
/** 单路输出上限：8 MB */
export const SHELL_OUTPUT_LIMIT_BYTES: number = 8 * 1024 * 1024;

/**
 * 命令的默认工作目录。
 *
 * 应用进程的当前目录是 `/`，而应用用户对 `/` 没有读权限。被测命令里凡有
 * 「检查当前目录可读性」的启动逻辑（brew 就是一个），在当前目录里跑都会直接失败，
 * 且失败信息与真正的权限问题无关。应用自己的数据目录始终可读，拿它当默认值。
 */
export const SHELL_DEFAULT_WORKING_DIRECTORY: string = '/data/storage/el2/base';

/**
 * brew 可执行文件的候选路径。
 *
 * 放在这里而不是 brew 层：发现入口与执行通道同层，`BrewInstalledLoader` 按这份列表发现 brew，
 * 两层口径一致。列表按设备上最可能的位置排序，命中第一个可执行的即停。
 */
export const SHELL_BREW_PATH_CANDIDATES: string[] = [
  '/storage/Users/currentUser/.harmonybrew/bin/brew',
  '/opt/homebrew/bin/brew',
  '/usr/local/bin/brew',
];

/** 一次执行的返回值。字段与 NAPI 侧构造的对象一一对应 */
export class ShellResult {
  /** 命令是否以退出码 0 结束 */
  public ok: boolean;
  /** 正常退出时的退出码；未跑完时为 -1 */
  public exitCode: number;
  public stdout: string;
  public stderr: string;
  /** `SHELL_ERR_*` */
  public errorCode: number;

  public constructor(ok: boolean, exitCode: number, stdout: string, stderr: string, errorCode: number) {
    this.ok = ok;
    this.exitCode = exitCode;
    this.stdout = stdout;
    this.stderr = stderr;
    this.errorCode = errorCode;
  }

  /** 「命令没跑完」的结果，供 ArkTS 侧在 NAPI 返回空时兜底 */
  public static failure(errorCode: number): ShellResult {
    return new ShellResult(false, -1, '', '', errorCode);
  }
}
