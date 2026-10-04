/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { Logger } from '@ohos/common';
import {
  SHELL_BREW_PATH_CANDIDATES,
  SHELL_ERR_TIMEOUT,
  SHELL_VERIFY,
  ShellProbeCase,
} from '../constant/ShellConstants';
import type { ShellResult } from '../constant/ShellConstants';
import { ShellUtils } from './ShellUtils';

const TAG: string = '[pcnative]';

/** 超时用例的预算。上界取 3 秒：通道的终止动作可能滞后，这个区间足以区分「按时终止」与「压根没终止」 */
const TIMEOUT_CASE_BUDGET_MS: number = 1500;
const TIMEOUT_CASE_MAX_MS: number = 3000;

/** 整轮自检的汇总 */
export class ShellProbeReport {
  /** 平台执行能力是否可用 */
  public available: boolean = false;
  /** 探测到的 brew 路径，空串表示没找到 */
  public brewPath: string = '';
  public cases: ShellProbeCase[] = [];

  public passed(): boolean {
    return this.cases.length > 0 && this.cases.filter((one: ShellProbeCase) => !one.ok).length === 0;
  }

  public failedNames(): string {
    return this.cases.filter((one: ShellProbeCase) => !one.ok)
      .map((one: ShellProbeCase) => one.name).join(',');
  }
}

/**
 * 执行通道自检。
 *
 * 与 `BrewSourceDiagnostics` 同一模式：一条常量开关（`SHELL_VERIFY`）加一组固定格式的判据行，
 * 不用 ohosTest。每行格式为 `[pcnative] verify <用例名> ok=<bool> ms=<耗时> <明细>`，
 * `grep '\[pcnative\] verify' | grep 'ok=false'` 即可对账。
 *
 * 用例之间有依赖：`available` 与 `echo` 失败即中止整轮 —— 后面的用例都要先能执行命令。
 * 其余用例互相独立，一条失败不影响其它条继续验证。
 *
 * 探针不改变任何页面状态，只打日志与返回报告。
 */
export class ShellProbe {
  /**
   * 跑一轮自检。`prefix` 为空时按候选列表自己找 brew 路径。
   *
   * 返回值给需要程序化判定的调用方（例如后续的 brew 自检），日志给人工对账。
   */
  public static async run(prefix?: string): Promise<ShellProbeReport> {
    const report: ShellProbeReport = new ShellProbeReport();
    report.available = ShellUtils.available();
    ShellProbe.record(report, 'available', report.available, `channel=${report.available}`);
    if (!report.available) {
      Logger.warn(TAG, `verify summary passed=false reason=channel-unavailable`);
      return report;
    }

    // C1：能执行命令、能拿到 stdout
    const echo: ShellResult = await ShellProbe.runCase('echo', 'echo probe-ok', 5000);
    const echoOk: boolean = echo.ok && echo.stdout.trim() === 'probe-ok';
    ShellProbe.record(report, 'echo', echoOk,
      `code=${echo.exitCode} out="${ShellProbe.trimForLog(echo.stdout)}" err="${ShellProbe.trimForLog(echo.stderr)}"`);
    if (!echoOk) {
      Logger.warn(TAG, `verify summary passed=false reason=echo-failed`);
      return report;
    }

    // C1：命令行交给 shell 解释（管道）
    const pipe: ShellResult = await ShellProbe.runCase('pipe', 'echo a b c | wc -w', 5000);
    ShellProbe.record(report, 'pipe', pipe.ok && pipe.stdout.trim() === '3',
      `code=${pipe.exitCode} out="${pipe.stdout.trim()}"`);

    // C2：非零退出码要能拿到，且不能被当成「没跑完」
    const exitCase: ShellResult = await ShellProbe.runCase('exit-code', 'exit 7', 5000);
    ShellProbe.record(report, 'exit-code',
      !exitCase.ok && exitCase.exitCode === 7,
      `code=${exitCase.exitCode} error=${exitCase.errorCode}`);

    // C3：stdout 与 stderr 分路
    const streams: ShellResult = await ShellProbe.runCase('stderr', 'echo out-ok; echo err-ok 1>&2', 5000);
    const streamsOk: boolean = streams.stdout.trim() === 'out-ok' && streams.stderr.trim() === 'err-ok';
    ShellProbe.record(report, 'stderr', streamsOk,
      `out="${ShellProbe.trimForLog(streams.stdout)}" err="${ShellProbe.trimForLog(streams.stderr)}"`);

    // C4：环境变量能传进子进程
    const env: ShellResult = await ShellProbe.runCase('env',
      `SHELL_PROBE_VAR=probe-env sh -c 'printf %s "$SHELL_PROBE_VAR"'`, 5000);
    ShellProbe.record(report, 'env', env.ok && env.stdout.trim() === 'probe-env',
      `code=${env.exitCode} out="${env.stdout.trim()}"`);

    // C2：超时后进程被终止。耗时落在预算与上界之间才算「按时终止」
    const timeoutStartedAt: number = Date.now();
    const timeout: ShellResult = await ShellProbe.runCase('timeout', 'sleep 30', TIMEOUT_CASE_BUDGET_MS);
    const timeoutTookMs: number = Date.now() - timeoutStartedAt;
    ShellProbe.record(report, 'timeout',
      timeout.errorCode === SHELL_ERR_TIMEOUT &&
      timeoutTookMs >= TIMEOUT_CASE_BUDGET_MS && timeoutTookMs <= TIMEOUT_CASE_MAX_MS,
      `error=${timeout.errorCode} took=${timeoutTookMs} budget=${TIMEOUT_CASE_BUDGET_MS}`, timeoutTookMs);

    // 外部可执行文件（C6）与沙箱外文件读取（C7）都依赖 brew 路径
    const brewPath: string = prefix && prefix.length > 0 ? prefix : ShellProbe.findBrewPrefix();
    report.brewPath = brewPath;
    if (brewPath.length === 0) {
      ShellProbe.record(report, 'external', false, 'reason=brew-not-found');
      ShellProbe.record(report, 'read-outside', false, 'reason=brew-not-found');
    } else {
      await ShellProbe.externalCases(report, brewPath);
    }

    const summary: string = report.passed() ?
      `passed=true cases=${report.cases.length} brew=${brewPath}` :
      `passed=false cases=${report.cases.length} failed=${report.failedNames()} brew=${brewPath}`;
    if (report.passed()) {
      Logger.info(TAG, `verify summary ${summary}`);
    } else {
      Logger.warn(TAG, `verify summary ${summary}`);
    }
    return report;
  }

  /** 按 `SHELL_VERIFY` 开关决定是否自检。供启动路径调用，开关关闭时立即返回 */
  public static async runIfEnabled(prefix?: string): Promise<ShellProbeReport | null> {
    if (!SHELL_VERIFY) {
      return null;
    }
    return ShellProbe.run(prefix);
  }

  /** C6：能执行给定绝对路径的可执行文件；C7：能读沙箱外的文件 */
  private static async externalCases(report: ShellProbeReport, prefix: string): Promise<void> {
    const brew: ShellResult = await ShellProbe.runCase('external', `${prefix}/bin/brew --version`, 20000);
    ShellProbe.record(report, 'external', brew.ok,
      `code=${brew.exitCode} error=${brew.errorCode} out="${ShellProbe.trimForLog(brew.stdout)}"`);

    // 取 Cellar 下第一个包目录，读它的安装记录。用 head 而不是 cat：这条用例只验证「读得到」
    const listing: ShellResult = await ShellProbe.runCase('read-outside',
      `ls "${prefix}/Cellar" | head -1`, 5000);
    const token: string = listing.stdout.trim();
    if (token.length === 0) {
      ShellProbe.record(report, 'read-outside', false, `reason=cellar-empty or unreadable code=${listing.exitCode}`);
      return;
    }
    const receipt: ShellResult = await ShellProbe.runCase('read-outside',
      `head -c 4 "${prefix}/Cellar/${token}"/*/INSTALL_RECEIPT.json`, 5000);
    ShellProbe.record(report, 'read-outside', receipt.ok && receipt.stdout.trim().startsWith('{'),
      `token=${token} code=${receipt.exitCode} out="${ShellProbe.trimForLog(receipt.stdout)}"`);
  }

  /** 执行一条用例命令并记耗时。判据由调用方在 `record` 里写，这里只管执行与计时 */
  private static async runCase(name: string,
    command: string, timeoutMs: number): Promise<ShellResult> {
    const startedAt: number = Date.now();
    const result: ShellResult = await ShellUtils.run(command, timeoutMs);
    ShellProbe.lastTookMs = Date.now() - startedAt;
    return result;
  }

  /**
   * 记录一条用例。`tookMs` 不传时用最近一次 `runCase` 的耗时。
   *
   * 显式传值只在「调用方自己也要算这段耗时」时使用（`timeout` 用例），
   * 否则连续的 `runCase` 会把前一次的耗时覆盖掉。
   */
  private static record(report: ShellProbeReport, name: string, ok: boolean,
    detail: string, tookMs?: number): void {
    const elapsed: number = tookMs === undefined ? ShellProbe.lastTookMs : tookMs;
    report.cases.push(new ShellProbeCase(name, ok, detail, elapsed));
    const line: string = `verify ${name} ok=${ok} ms=${elapsed} ${detail}`;
    if (ok) {
      Logger.info(TAG, line);
    } else {
      Logger.warn(TAG, line);
    }
  }

  /**
   * 按候选列表找 brew 的 prefix。
   *
   * 与 `BrewInstalledLoader` 用同一份候选表（`SHELL_BREW_PATH_CANDIDATES`）：
   * 探针在 brew 层之前跑，不能反向依赖它。
   */
  private static findBrewPrefix(): string {
    for (const candidate of SHELL_BREW_PATH_CANDIDATES) {
      const check: ShellResult = ShellUtils.runSync(`test -x "${candidate}" && echo yes`, 5000);
      if (check.ok && check.stdout.trim() === 'yes') {
        // `bin/brew` 的上一级目录就是 prefix
        return candidate.substring(0, candidate.length - '/bin/brew'.length);
      }
    }
    return '';
  }

  /** 日志明细里的单行化：换行会打断「一行一条判据」的格式 */
  private static trimForLog(raw: string): string {
    const oneLine: string = raw.replace(/\r?\n/g, '\\n');
    return oneLine.length > 200 ? `${oneLine.substring(0, 200)}…` : oneLine;
  }

  /** 最近一条用例的耗时。`record` 不传 `tookMs` 时用它 */
  private static lastTookMs: number = 0;
}
