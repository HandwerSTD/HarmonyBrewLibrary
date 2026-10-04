/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { JSON } from '@kit.ArkTS';
import { Logger } from '@ohos/common';
import { ShellProbe, ShellUtils } from '@ohos/pcnative';
import type { ShellResult } from '@ohos/pcnative';
import { BREW_INSTALLED_VERIFY } from '../constant/BrewConstants';
import type { BrewFormulaDoc, BrewInstalledDoc } from '../model/BrewInstalledDoc';
import { BrewInstalledFailure, BrewInstalledLoader, BrewInstalledOutcome } from './BrewInstalledLoader';

const TAG: string = '[BrewInstalled]';

/** 判据行里的明细截断。换行会打断「一行一条判据」的格式 */
const DETAIL_LIMIT: number = 200;

/**
 * 本机包读取的自检。
 *
 * 与 `BrewSourceDiagnostics` 同一模式：一条常量开关（`BREW_INSTALLED_VERIFY`）加一组
 * 固定格式的判据行，不用 ohosTest。每行格式为
 * `[BrewInstalled] verify <用例> ok=<bool> <明细>`，
 * `grep '\[BrewInstalled\] verify' | grep 'ok=false'` 即可对账。
 *
 * 执行通道本身的自检在 `@ohos/pcnative` 的 `ShellProbe`，这里只管 brew 这一层：
 * 命令能不能跑、输出能不能解析、字段对不对、三个集合的数量关系自不自洽。
 */
export class BrewInstalledProbe {
  /** 跑一轮自检。开关关闭时立即返回 */
  public static async runIfEnabled(): Promise<void> {
    if (!BREW_INSTALLED_VERIFY) {
      return;
    }
    await BrewInstalledProbe.run();
  }

  public static async run(): Promise<void> {
    // 先跑执行通道自检：本层的一切都建立在「命令能执行」之上，
    // 通道有问题时这里的判据行会被连带影响，先看清楚通道那几条再往下看
    await ShellProbe.runIfEnabled();

    // 用例 1：能发现 brew
    const brewPath: string = BrewInstalledLoader.discoverBrewPath();
    const prefix: string = BrewInstalledLoader.prefixOf(brewPath);
    BrewInstalledProbe.line('discover', brewPath.length > 0 && prefix.length > 0,
      `brew=${brewPath} prefix=${prefix}`);
    if (brewPath.length === 0) {
      return;
    }

    // 用例 2：版本号能读出来
    const version: ShellResult = await ShellUtils.run(`"${brewPath}" --version`, 20000);
    BrewInstalledProbe.line('version', version.ok, `code=${version.exitCode} out=${short(version.stdout)}`);

    // 用例 3：命令退出码 0 且 stdout 可解析
    const outcome: BrewInstalledOutcome = await BrewInstalledLoader.loadOutcome();
    const parseable: boolean = outcome.reason !== BrewInstalledFailure.BAD_OUTPUT &&
      outcome.reason !== BrewInstalledFailure.BAD_SHAPE;
    BrewInstalledProbe.line('installed', outcome.ok() || parseable,
      `reason=${outcome.reason.length > 0 ? outcome.reason : 'none'} ms=${outcome.tookMs} bytes=${outcome.stdoutBytes}`);

    // 用例 4：形状。`formulae` 是数组，条数等于 Cellar 下的目录数
    const raw: ShellResult = await ShellUtils.run(BrewInstalledLoader.commandOf(brewPath), 30000);
    const formulae: BrewFormulaDoc[] | null = BrewInstalledProbe.formulaeOf(raw.stdout);
    const formulaCount: number = formulae === null ? -1 : formulae.length;
    const cellarCount: number = BrewInstalledProbe.cellarCountOf(prefix);
    BrewInstalledProbe.line('shape', formulaCount >= 0 && formulaCount === cellarCount,
      `formulae=${formulaCount} cellar=${cellarCount} code=${raw.exitCode}`);

    // 用例 5：字段。抽第一条核对四个必读字段
    BrewInstalledProbe.line('fields', BrewInstalledProbe.fieldsOk(formulae),
      `stdout=${short(raw.stdout)}`);

    // 用例 6：三个集合的数量关系自洽
    const setsOk: boolean = outcome.sets.installed.length >= outcome.sets.outdated.length &&
      outcome.sets.updated.length === outcome.sets.installed.length - outcome.sets.outdated.length;
    BrewInstalledProbe.line('sets', setsOk,
      `installed=${outcome.sets.installed.length} outdated=${outcome.sets.outdated.length} ` +
      `updated=${outcome.sets.updated.length}`);
  }

  /** 解析 `formulae` 数组；形状不对返回 null */
  private static formulaeOf(output: string): BrewFormulaDoc[] | null {
    if (output.trim().length === 0) {
      return null;
    }
    try {
      const doc: BrewInstalledDoc = JSON.parse(output) as BrewInstalledDoc;
      const formulae: BrewFormulaDoc[] | undefined = doc?.formulae;
      if (!formulae || !Array.isArray(formulae)) {
        return null;
      }
      return formulae;
    } catch (error) {
      return null;
    }
  }

  /** `Cellar` 下的目录数。拿不到时返回 -1 */
  private static cellarCountOf(prefix: string): number {
    if (prefix.length === 0) {
      return -1;
    }
    const listing: ShellResult = ShellUtils.runSync(`ls "${prefix}/Cellar" | wc -l`, 10000);
    if (!listing.ok) {
      return -1;
    }
    const count: number = Number.parseInt(listing.stdout.trim(), 10);
    return Number.isNaN(count) ? -1 : count;
  }

  /** 抽第一条 formula，核对四个必读字段的存在与类型 */
  private static fieldsOk(formulae: BrewFormulaDoc[] | null): boolean {
    if (formulae === null || formulae.length === 0) {
      return false;
    }
    const first: BrewFormulaDoc = formulae[0];
    const stable: string | undefined = first.versions?.stable;
    const installed = first.installed;
    if (typeof first.name !== 'string' || stable === undefined || !installed || installed.length === 0) {
      return false;
    }
    const version: string | undefined = installed[0].version;
    const time: number | undefined = installed[0].time;
    return typeof version === 'string' && typeof time === 'number';
  }

  private static line(name: string, ok: boolean, detail: string): void {
    const text: string = `verify ${name} ok=${ok} ${detail}`;
    if (ok) {
      Logger.info(TAG, text);
    } else {
      Logger.warn(TAG, text);
    }
  }
}

function short(raw: string): string {
  const oneLine: string = raw.replace(/\r?\n/g, '\\n');
  return oneLine.length > DETAIL_LIMIT ? `${oneLine.substring(0, DETAIL_LIMIT)}…` : oneLine;
}
