/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { JSON } from '@kit.ArkTS';
import { BrewKind } from '../model/BrewModels';
import type { BrewInstalledPackage } from '../model/BrewModels';
import type { BrewFormulaDoc, BrewInstalledDoc, BrewInstalledKegDoc } from '../model/BrewInstalledDoc';

/**
 * `brew info --json=v2 --installed` 的输出 -> `BrewInstalledPackage[]`。
 *
 * 纯函数，不碰 shell、不碰存储：输入的合法性由 `BrewInstalledLoader` 负责判定，
 * 这里只在字段缺失时做回落，不抛异常。
 *
 * cask 条目全部丢弃 —— 本机不支持 cask（`Caskroom` 为空），命令输出里的 `casks`
 * 数组即使非空也不进模型。
 */
export class BrewInstalledParser {
  /**
   * 解析命令输出。
   *
   * 抛出的只有 `JSON.parse` 的语法错误；形状不符（`formulae` 不是数组）返回空数组，
   * 由调用方按「条数为 0」判定，不在这里区分「形状错」与「真的一个都没装」。
   */
  public static parse(output: string): BrewInstalledPackage[] {
    const doc: BrewInstalledDoc = JSON.parse(output) as BrewInstalledDoc;
    const formulae: BrewFormulaDoc[] | undefined = doc?.formulae;
    if (!formulae || !Array.isArray(formulae)) {
      return [];
    }
    const out: BrewInstalledPackage[] = [];
    for (const formula of formulae) {
      const item: BrewInstalledPackage | null = BrewInstalledParser.formulaOf(formula);
      if (item !== null) {
        out.push(item);
      }
    }
    return out;
  }

  /**
   * 一个 formula -> 一个本机包。没有已安装版本时返回 `null`（跳过，不算失败）。
   *
   * `installed` 数组可能有多项（同一个包装了多个版本），取版本最新的那个 keg；
   * 版本比较用 Homebrew 自己的口径，见 `compareVersion`。
   */
  private static formulaOf(formula: BrewFormulaDoc): BrewInstalledPackage | null {
    const name: string = formula?.name ?? '';
    if (name.length === 0) {
      return null;
    }
    const kegs: BrewInstalledKegDoc[] | undefined = formula.installed;
    if (!kegs || kegs.length === 0) {
      return null;
    }
    let newest: BrewInstalledKegDoc = kegs[0];
    for (const keg of kegs) {
      if (BrewInstalledParser.compareVersion(keg.version ?? '', newest.version ?? '') > 0) {
        newest = keg;
      }
    }

    const installedOnRequest: boolean = newest.installed_on_request === true;
    return {
      name: name,
      fullName: formula.full_name && formula.full_name.length > 0 ? formula.full_name : name,
      version: newest.version ?? '',
      latestVersion: formula.versions?.stable ?? '',
      installedOnRequest: installedOnRequest,
      // 与行组件 `BrewLocalPackageRow` 的口径一致：只区分「主动装」与「作为依赖装」
      installedAsDependency: !installedOnRequest,
      // 顶层没有 poured_from_bottle，`installed_kegs` 的投影里只有 built_as_bottle
      pouredFromBottle: newest.built_as_bottle === true,
      installedAt: BrewInstalledParser.installedAtOf(newest.time),
      // formula 的输出里没有这个字段，UI 也没有消费点
      autoUpdates: false,
      outdated: formula.outdated === true,
      kind: BrewKind.FORMULA,
    };
  }

  /**
   * 安装时刻 -> epoch ms。
   *
   * brew 写的是 Unix 秒（实测 `libpng` 的 receipt 写 `1788920001`，与文件修改时间逐秒一致），
   * 而模型与 UI 用 epoch ms。落在合理区间之外的值一律当缺失处理，返回 0：
   * 「不知道什么时候装的」比「显示 1970 年」更接近事实。
   */
  private static installedAtOf(time: number | undefined): number {
    if (time === undefined || time === null) {
      return 0;
    }
    // 秒级时间戳的合理区间：2001-09-09 到 2096-10-02
    if (time < 1000000000 || time >= 4000000000) {
      return 0;
    }
    return time * 1000;
  }

  /**
   * 比较两个版本号，返回负数 / 0 / 正数。
   *
   * Homebrew 的版本形如 `1.6.58`、`5.3.9_1`、`2.3.3_2`：点分段，段内可能带 `_` 后缀
   * （同一版本的修订号）。这里按「点分段 -> 段内按 `_` 再分 -> 逐段比数字」处理，
   * 纯数字段按数值比，其余按字符串比。只用于从同一 formula 的多个 keg 里挑最新，
   * 不需要处理上游那些更古怪的版本号。
   */
  private static compareVersion(left: string, right: string): number {
    if (left === right) {
      return 0;
    }
    const leftParts: string[] = left.split(/[._]/);
    const rightParts: string[] = right.split(/[._]/);
    const count: number = Math.max(leftParts.length, rightParts.length);
    for (let i = 0; i < count; i++) {
      const leftPart: string = i < leftParts.length ? leftParts[i] : '0';
      const rightPart: string = i < rightParts.length ? rightParts[i] : '0';
      if (leftPart === rightPart) {
        continue;
      }
      const leftNumber: number = Number.parseInt(leftPart, 10);
      const rightNumber: number = Number.parseInt(rightPart, 10);
      if (!Number.isNaN(leftNumber) && !Number.isNaN(rightNumber)) {
        return leftNumber < rightNumber ? -1 : 1;
      }
      return leftPart < rightPart ? -1 : 1;
    }
    return 0;
  }
}
