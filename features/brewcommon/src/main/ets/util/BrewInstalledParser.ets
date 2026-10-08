/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { JSON } from '@kit.ArkTS';
import { BrewKind } from '../model/BrewModels';
import type { BrewInstalledPackage } from '../model/BrewModels';
import type {
  BrewCaskDoc,
  BrewFormulaDoc,
  BrewInstalledDoc,
  BrewInstalledKegDoc,
} from '../model/BrewInstalledDoc';

/**
 * `brew info --json=v2 --installed` 的输出 -> `BrewInstalledPackage[]`。
 *
 * 纯函数，不碰 shell、不碰存储：输入的合法性由 `BrewInstalledLoader` 负责判定，
 * 这里只在字段缺失时做回落，不抛异常。
 *
 * `formulae` 与 `casks` 两个数组都进模型：一条命令同时返回两者（`cmd/info.rb` 的
 * `print_json` 在 `--installed` 下把 `casks ||= Cask::Caskroom.casks`），本机包列表因此
 * 天然包含已安装的 cask，筛选 chips 的「Casks」与「更新全部 - Casks」都有数据。
 */
export class BrewInstalledParser {
  /**
   * 解析命令输出。
   *
   * 抛出的只有 `JSON.parse` 的语法错误；两个数组都缺失或都不是数组时返回空数组，
   * 由调用方按「条数为 0」判定，不在这里区分「形状错」与「真的一个都没装」。
   */
  public static parse(output: string): BrewInstalledPackage[] {
    const doc: BrewInstalledDoc = JSON.parse(output) as BrewInstalledDoc;
    const out: BrewInstalledPackage[] = [];
    const formulae: BrewFormulaDoc[] | undefined = doc?.formulae;
    if (formulae && Array.isArray(formulae)) {
      for (const formula of formulae) {
        const item: BrewInstalledPackage | null = BrewInstalledParser.formulaOf(formula);
        if (item !== null) {
          out.push(item);
        }
      }
    }
    const casks: BrewCaskDoc[] | undefined = doc?.casks;
    if (casks && Array.isArray(casks)) {
      for (const cask of casks) {
        const item: BrewInstalledPackage | null = BrewInstalledParser.caskOf(cask);
        if (item !== null) {
          out.push(item);
        }
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
   * 一个 cask -> 一个本机包。没有 token、或没有已安装版本时返回 `null`（跳过，不算失败）。
   *
   * `installed_on_request` 在 cask 的 JSON 投影里不存在（`Cask#to_h` 不产出这个字段，
   * 只有 `Cask::Tab` 的 receipt 文件里有），按「主动安装」处理：cask 的依赖关系由
   * `depends_on` 表达，投影里读不到「作为依赖装上」这种状态，按主动安装可以让它们在
   * 「隐藏依赖包」筛选下仍然可见。
   *
   * `pouredFromBottle` 没有对应字段：cask 的产物一律是从源地址下载好的构件，没有从
   * 源码构建的形式，因此恒为真。
   */
  private static caskOf(cask: BrewCaskDoc): BrewInstalledPackage | null {
    const token: string = cask?.token ?? '';
    if (token.length === 0) {
      return null;
    }
    const installedVersion: string = cask.installed ?? '';
    if (installedVersion.length === 0) {
      return null;
    }
    return {
      name: token,
      fullName: cask.full_token && cask.full_token.length > 0 ? cask.full_token : token,
      version: installedVersion,
      latestVersion: cask.version ?? '',
      installedOnRequest: true,
      installedAsDependency: false,
      pouredFromBottle: true,
      installedAt: BrewInstalledParser.installedAtOf(cask.installed_time),
      // 与 formula 不同，cask 的投影里有这个字段：`auto_updates true` 的应用会自己更新
      // 自己，`brew upgrade` 默认跳过它
      autoUpdates: cask.auto_updates === true,
      outdated: cask.outdated === true,
      kind: BrewKind.CASK,
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
