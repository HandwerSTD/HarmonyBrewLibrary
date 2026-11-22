/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { BrewTextSegment } from '../util/BrewAnsi';

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

/**
 * 日志区的一行。
 *
 * 一行可能由多段不同样式的文本组成（brew 自己会输出 ANSI 颜色），所以带着切好的
 * `segments` 而不是一整串文本：渲染层逐段出一个 `Span`，不用再解析一遍。
 * `text` 是去掉转义序列之后的纯文本，只用于日志打点与占位判断。
 */
export class BrewCommandLine {
  public text: string;
  public stderr: boolean;
  /** 切好的样式段，按顺序拼起来就是这一行 */
  public segments: BrewTextSegment[];

  public constructor(text: string, stderr: boolean, segments: BrewTextSegment[]) {
    this.text = text;
    this.stderr = stderr;
    this.segments = segments;
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
  /** 执行 Sheet 当前是否展示。由全局宿主的 bindSheet 绑定，页面按钮与侧边栏入口通过 runner 请求开关 */
  public sheetShown: boolean;
  /**
   * 当前命令的终态结果是否已经在 Sheet 里展示过。
   * 只在两个时刻置真：命令结束时 Sheet 正展示着；或者 Sheet 在命令结束之后被打开。
   * 命令执行中途打开 Sheet 不入账 —— 那时看到的只是过程。
   */
  public resultViewed: boolean;

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
    this.sheetShown = false;
    this.resultViewed = true;
  }
}

/**
 * 状态行的文案。Sheet 的文本尾部与两个页面的结束提示共用同一套写法。
 *
 * 终态写成方括号里的短句，像 shell 打完一条命令之后回显的状态行：完成与失败带上退出码，
 * 中断与超时本身已经说明是谁结束了命令，再挂一个退出码只会让人以为命令是自己退出的。
 * 从未执行过命令时返回空字符串。
 */
export function brewCommandStatusText(state: BrewCommandState): ResourceStr {
  if (state.status === BrewCommandStatus.RUNNING) {
    return state.interruptSentAt > 0 ?
      $r('app.string.brew_cmd_status_interrupting') : $r('app.string.brew_cmd_status_running');
  }
  if (state.status === BrewCommandStatus.DONE) {
    return $r('app.string.brew_cmd_status_done', state.exitCode);
  }
  if (state.status === BrewCommandStatus.INTERRUPTED) {
    return $r('app.string.brew_cmd_status_interrupted');
  }
  if (state.status === BrewCommandStatus.TIMEOUT) {
    return $r('app.string.brew_cmd_status_timeout');
  }
  if (state.status === BrewCommandStatus.FAILED) {
    // 退出码为负数表示通道没给出退出码（任务记录中途消失），这种情况不编一个退出码出来
    return state.exitCode >= 0 ?
      $r('app.string.brew_cmd_status_failed', state.exitCode) :
      $r('app.string.brew_cmd_status_failed_unknown');
  }
  return '';
}

/** 命令是否已经进入终态：DONE / INTERRUPTED / FAILED / TIMEOUT 为真，IDLE / RUNNING 为假 */
export function isBrewCommandEnded(status: BrewCommandStatus): boolean {
  return status === BrewCommandStatus.DONE || status === BrewCommandStatus.INTERRUPTED ||
    status === BrewCommandStatus.FAILED || status === BrewCommandStatus.TIMEOUT;
}

/** 一次启动请求。`args` 必须由 `BrewCommandGenerator` 的参数级方法产出 */
export class BrewCommandRequest {
  public title: ResourceStr;
  public command: string;
  /** 传给 brew 的参数部分 */
  public args: string;
  /**
   * 原始命令模式：非空时 `BrewCommandRunner.start()` 把它**原样**交给执行通道
   * （tldr 示例原文一键执行，spec 2026-11-22 §4.1），不再拼 brew 前缀、不走包名校验，
   * 安全闸改为 `TldrParser.isExecutable`（无占位符）。
   *
   * 为空时行为与原先完全一致 —— 走 `BrewCli.commandLine(args)`。
   * `command` / `args` 在原始模式下同放命令原文：Sheet 首行显示原文，
   * `state.args` 参与忙闲判定（`isRunningArgs`）。
   */
  public rawCommand: string = '';

  public constructor(title: ResourceStr, command: string, args: string) {
    this.title = title;
    this.command = command;
    this.args = args;
  }
}