/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

/** 一条 brew 写命令的生命周期阶段 */
export enum BrewCommandStatus {
  /** 从未执行过命令 */
  IDLE,
  /** 执行中 */
  RUNNING,
  /** 以退出码 0 结束 */
  DONE,
  /** 被本应用发出的中断或终止请求结束 */
  INTERRUPTED,
  /** 非零退出、启动失败等 */
  FAILED,
  /** 超过执行超时被通道终止 */
  TIMEOUT,
}

/**
 * `BrewCommandRunner.start()` 的结果。
 *
 * 调用方据此决定弹哪条提示，所以把「为什么没启动」分成四类而不是一个布尔值：
 * 忙、通道不可用、参数不合法，三者的用户动作完全不同（等一下 / 换设备 / 换包）。
 */
export enum BrewCommandStartResult {
  /** 已启动 */
  STARTED = 'started',
  /** 已有写命令在执行 */
  BUSY = 'busy',
  /** 能力开关关闭，或执行通道 / brew 路径不可用 */
  UNAVAILABLE = 'unavailable',
  /** 参数为空或不合法 */
  BAD_ARGS = 'bad_args',
}

/** 日志区的一行。`stderr` 决定行的颜色 */
export class BrewCommandLine {
  public text: string;
  public stderr: boolean;

  public constructor(text: string, stderr: boolean) {
    this.text = text;
    this.stderr = stderr;
  }
}

/**
 * 当前（或最近一条）命令的状态。
 *
 * 用 `@Observed` 而不是整体替换：日志每 200ms 增一批行，页面用 `@State` 持有同一个实例、
 * Sheet 用 `@ObjectLink` 接收，改一级属性就只更新受影响的渲染节点。
 * 不用 `@Prop` 的原因是它对对象做深拷贝，1000 行日志每 200ms 复制一次不可接受。
 *
 * 页面要靠 `args` 判断本页按钮是否显示「执行中…」，所以它必须与真正发出去的参数逐字相同。
 */
@Observed
export class BrewCommandState {
  /** 页面给的标题（更新全部 / 安装 `<token>` / 升级 `<token>`） */
  public title: ResourceStr;
  /** 用户可读的命令行（如 `brew upgrade --formula`） */
  public command: string;
  /** 传给 brew 的参数部分，页面靠它判断本页按钮是否在忙 */
  public args: string;
  public lines: BrewCommandLine[];
  /** 因超出上限被丢弃的行数 */
  public omittedLines: number;
  public status: BrewCommandStatus;
  public exitCode: number;
  /** `SHELL_ERR_*` */
  public errorCode: number;
  public startedAt: number;
  public endedAt: number;
  /** 中断发出的时刻，0 表示还没发过 */
  public interruptSentAt: number;
  /** 是否已发送过强制终止 */
  public killSent: boolean;
  /**
   * 宽限期已过、可以发强制终止。
   *
   * 由 runner 在宽限期到点的定时回调里置真：按钮的可见性必须挂在一个可观察的一级属性上，
   * 只靠「距发出多久」在渲染时现算，命令静默（没有新行落地）时界面不会重渲染，按钮就切不过去。
   */
  public forceKillReady: boolean;

  public constructor() {
    this.title = '';
    this.command = '';
    this.args = '';
    this.lines = [];
    this.omittedLines = 0;
    this.status = BrewCommandStatus.IDLE;
    this.exitCode = -1;
    this.errorCode = 0;
    this.startedAt = 0;
    this.endedAt = 0;
    this.interruptSentAt = 0;
    this.killSent = false;
    this.forceKillReady = false;
  }
}

/** 一次启动请求。`args` 必须由 `BrewCommandGenerator` 的参数级方法产出 */
export class BrewCommandRequest {
  public title: ResourceStr;
  public command: string;
  /** 传给 brew 的参数部分 */
  public args: string;

  public constructor(title: ResourceStr, command: string, args: string) {
    this.title = title;
    this.command = command;
    this.args = args;
  }
}