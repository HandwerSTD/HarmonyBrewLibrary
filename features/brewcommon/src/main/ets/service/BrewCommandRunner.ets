/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { Logger } from '@ohos/common';
import {
  SHELL_ERR_INTERRUPTED,
  SHELL_ERR_TIMEOUT,
  SHELL_STREAM_POLL_MAX_BYTES,
  ShellUtils,
} from '@ohos/pcnative';
import type { ShellStreamPoll } from '@ohos/pcnative';
import {
  BREW_COMMAND_INTERRUPT_GRACE_MS,
  BREW_COMMAND_LOG_MAX_LINES,
  BREW_COMMAND_POLL_MS,
  BREW_COMMAND_TIMEOUT_MS,
} from '../constant/BrewConstants';
import {
  BrewCommandLine,
  BrewCommandRequest,
  BrewCommandStartResult,
  BrewCommandState,
  BrewCommandStatus,
  isBrewCommandEnded,
} from '../model/BrewCommandModels';
import { BrewCommandGenerator } from '../util/BrewCommandGenerator';
import { BrewAnsiParser, BrewTextSegment } from '../util/BrewAnsi';
import { BrewCli } from './BrewCli';
// 与 BrewInstalledLoader 互相 import 是有意的：读取路径要问「现在有没有写命令在执行」（spec §6.2 规则 5），
// 写命令结束要让它失效并刷新（spec §5.3 第 5 点）。两侧都只在方法体内引用对方，不在顶层求值。
import { BrewInstalledLoader } from './BrewInstalledLoader';

const TAG: string = '[brew-cmd]';

/**
 * brew 写命令的执行层：单飞、轮询、行缓冲、中断与终止。
 *
 * 状态放在单例里而不是页面的 VM 里，Sheet 因此可以随时关闭与重新打开：
 * 输出继续进同一个 `BrewCommandState`，重新打开时看到的是完整输出。
 *
 * 单飞而非排队：同一时刻只有一条写命令在执行，被拒绝的请求直接返回 `BUSY`，
 * 由调用方弹提示，用户自己决定什么时候再点一次。
 */
export class BrewCommandRunner {
  private static instance: BrewCommandRunner | null = null;

  public static getInstance(): BrewCommandRunner {
    if (BrewCommandRunner.instance === null) {
      BrewCommandRunner.instance = new BrewCommandRunner();
    }
    return BrewCommandRunner.instance;
  }

  /**
   * 启动一条写命令。
   *
   * 检查顺序固定为「可用性 -> 参数 -> 忙」：可用性与参数不成立时弹的提示比「已有命令在执行」
   * 更有用，先判忙会把「这个包根本装不了」也报成忙。
   */
  public start(request: BrewCommandRequest): BrewCommandStartResult {
    if (!BrewCli.isEnabled() || !BrewCli.isReady()) {
      Logger.warn(TAG, `start rejected reason=unavailable args=${request.args}`);
      return BrewCommandStartResult.UNAVAILABLE;
    }
    if (!BrewCommandRunner.isSafeArgs(request.args)) {
      Logger.warn(TAG, `start rejected reason=bad_args args=${request.args}`);
      return BrewCommandStartResult.BAD_ARGS;
    }
    if (this.isRunning()) {
      Logger.info(TAG, `busy args=${request.args} running=${this.state.args}`);
      return BrewCommandStartResult.BUSY;
    }
    const commandLine: string = BrewCli.commandLine(request.args);
    if (commandLine.length === 0) {
      Logger.warn(TAG, `start rejected reason=unavailable args=${request.args}`);
      return BrewCommandStartResult.UNAVAILABLE;
    }
    const taskId: number = ShellUtils.startStream(
      commandLine, BREW_COMMAND_TIMEOUT_MS, BrewCli.workingDirectory());
    if (taskId <= 0) {
      Logger.warn(TAG, `start rejected reason=start_failed args=${request.args}`);
      return BrewCommandStartResult.UNAVAILABLE;
    }
    this.begin(request, taskId);
    return BrewCommandStartResult.STARTED;
  }

  /** 当前命令的状态；没有命令在执行时是最近一条已结束命令的状态，从未执行过时是 IDLE */
  public getState(): BrewCommandState {
    return this.state;
  }

  public isRunning(): boolean {
    return this.taskId > 0;
  }

  /** 正在执行的命令参数是否与给定参数相同 */
  public isRunningArgs(args: string): boolean {
    return this.isRunning() && this.state.args === args;
  }

  /**
   * 中断当前命令。
   *
   * 第一次发 SIGINT（等同终端 Ctrl+C）；宽限期过后再调用则升级为 SIGTERM + SIGKILL。
   * 只作用于当前命令，没有命令在执行时什么都不做。
   */
  public interrupt(): void {
    if (this.taskId <= 0) {
      return;
    }
    if (this.state.interruptSentAt === 0) {
      const delivered: boolean = ShellUtils.interruptStream(this.taskId);
      this.state.interruptSentAt = Date.now();
      Logger.info(TAG, `interrupt sig=int delivered=${delivered}`);
      this.scheduleGraceNotify();
    } else if (!this.state.killSent) {
      const delivered: boolean = ShellUtils.killStream(this.taskId);
      this.state.killSent = true;
      Logger.info(TAG, `kill sig=kill delivered=${delivered}`);
    }
    this.notifyListeners();
  }

  /** 请求展示执行 Sheet。已展示时什么都不做 */
  public openSheet(): void {
    if (this.state.sheetShown) {
      return;
    }
    this.state.sheetShown = true;
  }

  /** 请求关闭执行 Sheet。宿主在 Sheet 退场动画结束后调用 */
  public closeSheet(): void {
    if (!this.state.sheetShown) {
      return;
    }
    this.state.sheetShown = false;
  }

  /** 登记「终态结果已经被看过」。宿主在 Sheet 开始展示时调用；命令还在执行时什么都不做 */
  public markViewed(): void {
    if (!isBrewCommandEnded(this.state.status)) {
      return;
    }
    this.state.resultViewed = true;
  }

  public subscribe(listener: () => void): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  public unsubscribe(listener: () => void): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  private constructor() {
    this.state = new BrewCommandState();
  }

  /**
   * 参数校验。
   *
   * `args` 是词（子命令 + 可选 `--cask` / `--formula` + 包名）组成的命令行片段，
   * 只有包名来自数据源，所以校验的落点是「除选项外的每个词都必须是合法包名」：
   * 选项由 `BrewCommandGenerator` 产出，包名由接口与本地 tap 产出，后者才是不可信的输入。
   */
  private static isSafeArgs(args: string): boolean {
    if (args.length === 0 || args.trim().length !== args.length) {
      return false;
    }
    const words: string[] = args.split(' ');
    for (const word of words) {
      if (word === '--cask' || word === '--formula') {
        continue;
      }
      if (!BrewCommandGenerator.isSafeName(word)) {
        return false;
      }
    }
    return words.length > 0;
  }

  private state: BrewCommandState;
  private taskId: number = 0;
  /** 轮询定时器；0 表示没有在跑 */
  private pollTimer: number = 0;
  /** 中断宽限期的到点通知；0 表示没有在等 */
  private graceTimer: number = 0;
  /** 两路输出各自的不完整尾行。分开存，因为它们是两个流，不能互相拼接 */
  private stdoutTail: string = '';
  private stderrTail: string = '';
  /** 两路各自的 ANSI 样式状态。跨行延续，与真终端一致 */
  private stdoutAnsi: BrewAnsiParser = new BrewAnsiParser(false);
  private stderrAnsi: BrewAnsiParser = new BrewAnsiParser(true);
  /** 样式段的全局序号，只在当前这条命令内递增 */
  private nextSegmentId: number = 0;
  private listeners: (() => void)[] = [];

  /** 重置状态并起轮询。就地改一级属性，页面持有的实例与 `@ObjectLink` 才继续有效 */
  private begin(request: BrewCommandRequest, taskId: number): void {
    this.taskId = taskId;
    this.stdoutTail = '';
    this.stderrTail = '';
    this.stdoutAnsi.reset();
    this.stderrAnsi.reset();
    this.nextSegmentId = 0;
    this.state.title = request.title;
    this.state.command = request.command;
    this.state.args = request.args;
    this.state.lines = [];
    this.state.omittedLines = 0;
    this.state.status = BrewCommandStatus.RUNNING;
    this.state.exitCode = -1;
    this.state.errorCode = 0;
    this.state.startedAt = Date.now();
    this.state.endedAt = 0;
    this.state.interruptSentAt = 0;
    this.state.killSent = false;
    this.state.forceKillReady = false;
    this.state.resultViewed = false;
    this.pollTimer = setInterval(() => {
      this.poll();
    }, BREW_COMMAND_POLL_MS);
    Logger.info(TAG, `start args=${request.args} command=${request.command}`);
    this.notifyListeners();
  }

  private poll(): void {
    if (this.taskId <= 0) {
      return;
    }
    const poll: ShellStreamPoll | null = ShellUtils.pollStream(this.taskId, SHELL_STREAM_POLL_MAX_BYTES);
    if (poll === null) {
      // 任务不存在：通道侧的记录已经没了，继续轮询只会空转，按失败收尾
      Logger.warn(TAG, `poll task gone args=${this.state.args}`);
      this.finish(-1, 0);
      return;
    }
    let outChars: number = 0;
    let errChars: number = 0;
    for (const event of poll.events) {
      if (event.kind === 'stderr') {
        errChars += this.append(event.data, true);
      } else {
        outChars += this.append(event.data, false);
      }
    }
    if (outChars > 0 || errChars > 0) {
      Logger.info(TAG, `poll out=${outChars} err=${errChars} lines=${this.state.lines.length}`);
    }
    if (poll.ended) {
      this.finish(poll.exitCode, poll.errorCode);
    }
  }

  /**
   * 把一段增量输出转成行，返回本次落地的纯字符数（只用于日志打点）。
   *
   * 按 `\n` 分行，最后一段不完整的留到下一次；行内 `\r` 与 ANSI 的处理交给 `buildLine`。
   */
  private append(data: string, isStderr: boolean): number {
    const tail: string = isStderr ? this.stderrTail : this.stdoutTail;
    const merged: string = tail + data;
    const breakAt: number = merged.lastIndexOf('\n');
    const complete: string = breakAt >= 0 ? merged.substring(0, breakAt) : '';
    const rest: string = breakAt >= 0 ? merged.substring(breakAt + 1) : merged;
    if (isStderr) {
      this.stderrTail = rest;
    } else {
      this.stdoutTail = rest;
    }
    if (complete.length === 0) {
      return 0;
    }
    const parts: string[] = complete.split('\n');
    let added: number = 0;
    const batch: BrewCommandLine[] = [];
    for (const part of parts) {
      const line: BrewCommandLine = this.buildLine(part, isStderr);
      batch.push(line);
      added += line.text.length;
    }
    this.pushLines(batch);
    return added;
  }

  /** 收尾时把两路剩下的尾行也落到日志里，否则最后一行不带换行的输出会丢 */
  private flushTails(): void {
    const batch: BrewCommandLine[] = [];
    if (this.stdoutTail.length > 0) {
      batch.push(this.buildLine(this.stdoutTail, false));
      this.stdoutTail = '';
    }
    if (this.stderrTail.length > 0) {
      batch.push(this.buildLine(this.stderrTail, true));
      this.stderrTail = '';
    }
    this.pushLines(batch);
  }

  /** 把一段不带换行的原文切成一行（含样式段） */
  private buildLine(raw: string, isStderr: boolean): BrewCommandLine {
    const parser: BrewAnsiParser = isStderr ? this.stderrAnsi : this.stdoutAnsi;
    const parts: string[] = raw.indexOf('\r') < 0 ? [raw] : raw.split('\r');
    let kept: number = parts.length - 1;
    while (kept > 0 && parts[kept].length === 0) {
      kept--;
    }
    // 被 `\r` 盖掉的前半段不显示，但里面的 SGR 已经把终端改成了新样式 —— 先走一遍再画后半段
    if (kept > 0) {
      parser.advance(parts.slice(0, kept).join('\r'));
    }
    const segments: BrewTextSegment[] = parser.parse(parts[kept], this.nextSegmentId);
    this.nextSegmentId += segments.length;
    let text: string = '';
    for (const segment of segments) {
      text += segment.text;
    }
    return new BrewCommandLine(text, isStderr, segments);
  }

  /**
   * 追加一批行并执行上限裁剪。超出上限时丢最旧的行并累计省略数。
   *
   * 一批只赋一次 `lines`：赋值会触发 Sheet 的 `@Watch`，一行一次会把跟随滚动的定时器排成一堆。
   */
  private pushLines(added: BrewCommandLine[]): void {
    if (added.length === 0) {
      return;
    }
    const next: BrewCommandLine[] = this.state.lines.concat(added);
    if (next.length > BREW_COMMAND_LOG_MAX_LINES) {
      const overflow: number = next.length - BREW_COMMAND_LOG_MAX_LINES;
      this.state.omittedLines += overflow;
      this.state.lines = next.slice(overflow);
      return;
    }
    this.state.lines = next;
  }

  /**
   * 结束处理。顺序固定：先释放任务与定时器，再算最终状态，最后通知订阅者 ——
   * 订阅者被叫醒时任务已经收干净，读到的状态就是终态。
   */
  private finish(exitCode: number, errorCode: number): void {
    if (this.taskId > 0) {
      ShellUtils.releaseStream(this.taskId);
    }
    this.taskId = 0;
    if (this.pollTimer !== 0) {
      clearInterval(this.pollTimer);
      this.pollTimer = 0;
    }
    if (this.graceTimer !== 0) {
      clearTimeout(this.graceTimer);
      this.graceTimer = 0;
    }
    this.flushTails();
    this.state.exitCode = exitCode;
    this.state.errorCode = errorCode;
    this.state.status = BrewCommandRunner.statusOf(exitCode, errorCode);
    this.state.endedAt = Date.now();
    Logger.info(TAG, `exit code=${exitCode} error=${errorCode} ms=${this.state.endedAt - this.state.startedAt} ` +
      `status=${this.state.status} args=${this.state.args}`);
    // 已安装列表的失效与刷新：写命令已结束，这一次读取拿到的是稳定状态
    BrewInstalledLoader.invalidate();
    if (this.state.sheetShown) {
      this.state.resultViewed = true;
    }
    this.notifyListeners();
  }

  /** 1005 → 已中断；1003 → 超时；退出码 0 → 已完成；其余 → 失败 */
  private static statusOf(exitCode: number, errorCode: number): BrewCommandStatus {
    if (errorCode === SHELL_ERR_INTERRUPTED) {
      return BrewCommandStatus.INTERRUPTED;
    }
    if (errorCode === SHELL_ERR_TIMEOUT) {
      return BrewCommandStatus.TIMEOUT;
    }
    if (exitCode === 0) {
      return BrewCommandStatus.DONE;
    }
    return BrewCommandStatus.FAILED;
  }

  /**
   * 宽限期到点。
   *
   * 没有它，命令长时间不输出时界面会一直停在「正在中断…」的旧状态，
   * 用户看不到按钮已经可以升级成强制终止。置 `forceKillReady` 是必须的：只调通知
   * 不会让 Sheet 重渲染（`@ObjectLink` 观察的是一级属性），按钮就切不过去。
   */
  private scheduleGraceNotify(): void {
    if (this.graceTimer !== 0) {
      clearTimeout(this.graceTimer);
    }
    this.graceTimer = setTimeout(() => {
      this.graceTimer = 0;
      if (this.taskId > 0) {
        this.state.forceKillReady = true;
        Logger.info(TAG, `interrupt grace elapsed, still running args=${this.state.args}`);
        this.notifyListeners();
      }
    }, BREW_COMMAND_INTERRUPT_GRACE_MS);
  }

  private notifyListeners(): void {
    const snapshot: (() => void)[] = this.listeners.slice();
    for (const listener of snapshot) {
      listener();
    }
  }
}