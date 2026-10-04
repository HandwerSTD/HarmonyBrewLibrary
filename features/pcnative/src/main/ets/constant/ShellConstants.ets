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
/**
 * 进程被本应用发出的中断或终止请求结束。
 *
 * 只有「调用方主动要停它」才用这个码：命令行执行 Sheet 靠它区分「已中断」
 * 与「命令自己失败」。没有主动请求就被信号打死时仍然是 `SHELL_ERR_START`。
 */
export const SHELL_ERR_INTERRUPTED: number = 1005;

/** 默认超时：10 秒 */
export const SHELL_TIMEOUT_DEFAULT_MS: number = 10000;
/**
 * 超时上限：30 分钟。防止调用方传一个过大的值把进程挂死
 *
 * 从 10 分钟放宽到 30 分钟：一次安装 / 升级要下载并装上多个包，设备上还可能从源码构建。
 * 超时在这里是「进程完全没有进展」的兜底，不是执行时长限制；流式执行有可见输出与中断入口。
 */
export const SHELL_TIMEOUT_MAX_MS: number = 30 * 60 * 1000;
/** 单路输出上限：8 MB */
export const SHELL_OUTPUT_LIMIT_BYTES: number = 8 * 1024 * 1024;

/**
 * 流式执行单次轮询取走的字节上限。
 *
 * 一次 `pollStream` 最多搬这么多数据，任务里没被取走的部分留在原生侧队列。
 * 取 256KB 是为了与界面的刷新节奏匹配：200ms 一次轮询，一次搬太多会让每帧的构造开销变大。
 */
export const SHELL_STREAM_POLL_MAX_BYTES: number = 256 * 1024;

/**
 * 执行通道启动自检开关。默认关闭，打开后应用启动时跑一遍流式执行探针
 *
 * 探针会真的起子进程（最长约十几秒），只在需要验证执行通道时临时打开。
 */
export const SHELL_STREAM_VERIFY: boolean = false;

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

/**
 * 一次轮询里的一段增量输出。相邻的同类片段在原生侧已经合并
 *
 * 用 `kind` 而不是两个数组：stdout 与 stderr 必须按到达顺序呈现给用户，
 * 分成两个字段就丢掉了「哪一行先到」这个信息。
 */
export class ShellStreamEvent {
  /** `'stdout'` | `'stderr'` */
  public kind: string;
  public data: string;

  public constructor(kind: string, data: string) {
    this.kind = kind;
    this.data = data;
  }
}

/** 一次轮询的结果。字段与 NAPI 侧构造的对象一一对应 */
export class ShellStreamPoll {
  /** 按到达顺序排列 */
  public events: ShellStreamEvent[];
  /**
   * 任务已结束，且管道里的剩余内容已全部取走
   *
   * 「取走」也算在这个条件里：`maxBytes` 把输出截断时，即使进程已经退出，
   * `ended` 也还是假的，调用方据此继续轮询就不会丢掉最后一批输出。
   */
  public ended: boolean;
  /** 结束时的退出码；还没结束时为 -1 */
  public exitCode: number;
  /** `ended` 为真时是 `SHELL_ERR_*`；还没结束时为 `SHELL_ERR_NONE` */
  public errorCode: number;

  public constructor(events: ShellStreamEvent[], ended: boolean, exitCode: number, errorCode: number) {
    this.events = events;
    this.ended = ended;
    this.exitCode = exitCode;
    this.errorCode = errorCode;
  }
}
