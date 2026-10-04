/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { Logger } from '@ohos/common';
import {
  SHELL_DEFAULT_WORKING_DIRECTORY,
  SHELL_ERR_INTERRUPTED,
  SHELL_ERR_NONE,
  SHELL_ERR_TIMEOUT,
  SHELL_STREAM_POLL_MAX_BYTES,
  SHELL_STREAM_VERIFY,
  ShellStreamEvent,
  ShellStreamPoll,
} from '../constant/ShellConstants';
import { ShellUtils } from './ShellUtils';

const TAG: string = '[pcnative] verify';

/** 轮询间隔。与命令层的 200ms 同量级，探针不需要跟界面一样密 */
const PROBE_POLL_MS: number = 100;

/** 单个用例的等待上限。用例里的命令最多睡 30 秒，给足余量即可 */
const PROBE_CASE_BUDGET_MS: number = 20000;

/** 发中断 / 终止前先让命令跑一会儿，确认信号是发给一个还活着的进程 */
const PROBE_PREPARE_MS: number = 1000;

/** 中断 / 终止之后要求命令在这个时间内结束 */
const PROBE_STOP_BUDGET_MS: number = 3000;

/** 一个用例跑完后的采集结果 */
class ProbeOutcome {
  public ended: boolean;
  public exitCode: number;
  public errorCode: number;
  /** 两路输出的非空行，按到达顺序用逗号拼起来 */
  public order: string;
  /** 从发出中断 / 终止到任务结束的耗时。用例不涉及信号时为 0 */
  public elapsedMs: number;
  /** 任务一直没结束时为真 */
  public timedOut: boolean;

  public constructor(ended: boolean, exitCode: number, errorCode: number, order: string, elapsedMs: number,
    timedOut: boolean) {
    this.ended = ended;
    this.exitCode = exitCode;
    this.errorCode = errorCode;
    this.order = order;
    this.elapsedMs = elapsedMs;
    this.timedOut = timedOut;
  }
}

/**
 * 执行通道的启动自检。
 *
 * 这是启动自检，不是单元测试：它不起测试框架、不造假数据，就在真设备上用真实的
 * `/bin/sh` 跑几个短命令，把执行通道的五条能力（到达顺序、退出码、超时、中断、终止）
 * 各验一遍，结果打进日志。判据见 `docs/superpowers/specs/2026-10-04-brew-command-execution-spec.md` 第 9 节。
 *
 * 只在 `SHELL_STREAM_VERIFY` 为真时执行。开关默认关闭：它会真的起子进程，
 * 正常发布版本不应该跑这段。开关关闭时 `run()` 立刻返回，不起任何子进程、不写任何日志。
 *
 * 日志前缀 `[pcnative] verify`，用 `devecocli log --keyword "[pcnative] verify"` 过滤。
 */
export class ShellStreamProbe {
  /** 启动自检入口。由 Ability 的 `onCreate` 调用一次 */
  public static run(): void {
    if (!SHELL_STREAM_VERIFY) {
      return;
    }
    ShellStreamProbe.runCases().then(() => {
      Logger.info(TAG, 'verify done');
    }, () => {
      Logger.error(TAG, 'verify aborted');
    });
  }

  private static async runCases(): Promise<void> {
    if (!ShellUtils.available()) {
      Logger.error(TAG, 'verify skip reason=unavailable');
      return;
    }
    Logger.info(TAG, 'verify begin');
    await ShellStreamProbe.caseStreamOrder();
    await ShellStreamProbe.caseStreamExitCode();
    await ShellStreamProbe.caseStreamTimeout();
    await ShellStreamProbe.caseStreamInterrupt();
    await ShellStreamProbe.caseStreamKill();
  }

  /**
   * stream-order：stdout 与 stderr 必须按到达顺序交给上层，不能合并成两段。
   *
   * 命令每 200ms 交替写一行 stdout 和一行 stderr。如果通道把两路分开缓冲再拼，
   * 上层拿到的顺序就会变成 out-1,out-2,out-3,err-1,err-2,err-3。
   */
  private static async caseStreamOrder(): Promise<void> {
    const command: string = 'for i in 1 2 3; do echo out-$i; echo err-$i 1>&2; sleep 0.2; done';
    const taskId: number = ShellUtils.startStream(command, 10000, SHELL_DEFAULT_WORKING_DIRECTORY);
    if (taskId === 0) {
      Logger.error(TAG, 'case stream-order ok=false reason=start-failed');
      return;
    }
    const outcome: ProbeOutcome = await ShellStreamProbe.drain(taskId, PROBE_CASE_BUDGET_MS, 0);
    ShellUtils.releaseStream(taskId);

    const expected: string = 'out-1,err-1,out-2,err-2,out-3,err-3';
    const ok: boolean = !outcome.timedOut && outcome.ended && outcome.exitCode === 0 &&
      outcome.order === expected;
    Logger.info(TAG,
      `case stream-order ok=${ok} ended=${outcome.ended} exitCode=${outcome.exitCode} ` +
      `errorCode=${outcome.errorCode} order=${outcome.order} expected=${expected}`);
  }

  /** stream-exit-code：退出码要原样传回，命令「跑完了」由 errorCode 为 0 表示 */
  private static async caseStreamExitCode(): Promise<void> {
    const taskId: number = ShellUtils.startStream('exit 7', 10000, SHELL_DEFAULT_WORKING_DIRECTORY);
    if (taskId === 0) {
      Logger.error(TAG, 'case stream-exit-code ok=false reason=start-failed');
      return;
    }
    const outcome: ProbeOutcome = await ShellStreamProbe.drain(taskId, PROBE_CASE_BUDGET_MS, 0);
    ShellUtils.releaseStream(taskId);

    const ok: boolean = !outcome.timedOut && outcome.ended && outcome.exitCode === 7;
    Logger.info(TAG,
      `case stream-exit-code ok=${ok} ended=${outcome.ended} exitCode=${outcome.exitCode} ` +
      `errorCode=${outcome.errorCode}`);
  }

  /** stream-timeout：到截止时刻要把整个进程组终止掉，并报 1003 */
  private static async caseStreamTimeout(): Promise<void> {
    const taskId: number = ShellUtils.startStream('sleep 30', 2000, SHELL_DEFAULT_WORKING_DIRECTORY);
    if (taskId === 0) {
      Logger.error(TAG, 'case stream-timeout ok=false reason=start-failed');
      return;
    }
    const outcome: ProbeOutcome = await ShellStreamProbe.drain(taskId, PROBE_CASE_BUDGET_MS, 0);
    ShellUtils.releaseStream(taskId);

    const ok: boolean = !outcome.timedOut && outcome.ended && outcome.errorCode === SHELL_ERR_TIMEOUT;
    Logger.info(TAG,
      `case stream-timeout ok=${ok} ended=${outcome.ended} exitCode=${outcome.exitCode} ` +
      `errorCode=${outcome.errorCode} expected=${SHELL_ERR_TIMEOUT}`);
  }

  /** stream-interrupt：SIGINT 到进程组后 3 秒内结束，并报 1005 */
  private static async caseStreamInterrupt(): Promise<void> {
    const taskId: number = ShellUtils.startStream('sleep 30', 30000, SHELL_DEFAULT_WORKING_DIRECTORY);
    if (taskId === 0) {
      Logger.error(TAG, 'case stream-interrupt ok=false reason=start-failed');
      return;
    }
    await ShellStreamProbe.wait(PROBE_PREPARE_MS);
    const sent: boolean = ShellUtils.interruptStream(taskId);
    const startedAt: number = Date.now();
    const outcome: ProbeOutcome = await ShellStreamProbe.drain(taskId, PROBE_STOP_BUDGET_MS, startedAt);
    ShellUtils.releaseStream(taskId);

    const ok: boolean = sent && !outcome.timedOut && outcome.ended &&
      outcome.errorCode === SHELL_ERR_INTERRUPTED && outcome.elapsedMs <= PROBE_STOP_BUDGET_MS;
    Logger.info(TAG,
      `case stream-interrupt ok=${ok} sent=${sent} ended=${outcome.ended} exitCode=${outcome.exitCode} ` +
      `errorCode=${outcome.errorCode} elapsedMs=${outcome.elapsedMs} budgetMs=${PROBE_STOP_BUDGET_MS}`);
  }

  /** stream-kill：SIGTERM 加 2 秒宽限后升级成 SIGKILL，同样报 1005 */
  private static async caseStreamKill(): Promise<void> {
    const taskId: number = ShellUtils.startStream('sleep 30', 30000, SHELL_DEFAULT_WORKING_DIRECTORY);
    if (taskId === 0) {
      Logger.error(TAG, 'case stream-kill ok=false reason=start-failed');
      return;
    }
    await ShellStreamProbe.wait(PROBE_PREPARE_MS);
    const sent: boolean = ShellUtils.killStream(taskId);
    const startedAt: number = Date.now();
    const outcome: ProbeOutcome = await ShellStreamProbe.drain(taskId, PROBE_STOP_BUDGET_MS, startedAt);
    ShellUtils.releaseStream(taskId);

    const ok: boolean = sent && !outcome.timedOut && outcome.ended &&
      outcome.errorCode === SHELL_ERR_INTERRUPTED && outcome.elapsedMs <= PROBE_STOP_BUDGET_MS;
    Logger.info(TAG,
      `case stream-kill ok=${ok} sent=${sent} ended=${outcome.ended} exitCode=${outcome.exitCode} ` +
      `errorCode=${outcome.errorCode} elapsedMs=${outcome.elapsedMs} budgetMs=${PROBE_STOP_BUDGET_MS}`);
  }

  /**
   * 反复轮询直到任务结束，把两路输出按到达顺序记成一行。
   *
   * `sinceStartedAt` 非 0 时用它算从发出中断 / 终止到结束的耗时。
   * 超过 `budgetMs` 还没结束就返回 `timedOut` 的结果，调用方照常释放任务。
   */
  private static async drain(taskId: number, budgetMs: number, sinceStartedAt: number): Promise<ProbeOutcome> {
    const tokens: string[] = [];
    const deadline: number = Date.now() + budgetMs;
    let ended: boolean = false;
    let exitCode: number = -1;
    let errorCode: number = SHELL_ERR_NONE;
    let elapsedMs: number = 0;
    let timedOut: boolean = true;

    while (true) {
      const poll: ShellStreamPoll | null = ShellUtils.pollStream(taskId, SHELL_STREAM_POLL_MAX_BYTES);
      if (poll === null) {
        break;
      }
      for (let index = 0; index < poll.events.length; index++) {
        const event: ShellStreamEvent = poll.events[index];
        for (const line of event.data.split('\n')) {
          const trimmed: string = line.trim();
          if (trimmed.length > 0) {
            tokens.push(trimmed);
          }
        }
      }
      if (poll.ended) {
        ended = true;
        exitCode = poll.exitCode;
        errorCode = poll.errorCode;
        elapsedMs = sinceStartedAt > 0 ? Date.now() - sinceStartedAt : 0;
        timedOut = false;
        break;
      }
      if (Date.now() >= deadline) {
        break;
      }
      await ShellStreamProbe.wait(PROBE_POLL_MS);
    }

    return new ProbeOutcome(ended, exitCode, errorCode, tokens.join(','), elapsedMs, timedOut);
  }

  private static wait(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }
}