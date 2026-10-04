/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { BrewKind } from '../model/BrewModels';
import type { BrewFormulaDetail, BrewCaskDetail } from '../model/BrewModels';

/**
 * brew 命令生成器。
 *
 * 设计决策：详情页的安装命令区**只展示基础命令**（`brew install <token>`）+ 复制按钮，
 * 不做交互式安装选项。原因：官方 API 的 `options` 字段实测恒为空（现代 Homebrew 已移除
 * 绝大多数 formula options），没有真实数据支撑一个交互式选项面板。
 *
 * 分两层：参数级方法（`*Args`）产出「不含 brew 本身」的命令行片段，展示方法建立在它们之上。
 * 这样展示的与执行的必然是同一份参数拼装 —— 页面显示 `brew install ripgrep` 时，
 * 发出去的就是 `install ripgrep`，不会因为两处各写一遍而漂移。
 */
export class BrewCommandGenerator {
  /** 第三方 tap 的包需要写全 qualified name（tap/token）；官方 tap 直接用 token。 */
  public static qualifiedName(token: string, tap: string): string {
    if (tap && tap !== 'homebrew/core' && tap !== 'homebrew/cask') {
      return `${tap}/${token}`;
    }
    return token;
  }

  /** 安装的参数部分：`install [--cask] <name>` */
  public static installArgs(kind: string, token: string, tap: string): string {
    const name: string = BrewCommandGenerator.qualifiedName(token, tap);
    return kind === BrewKind.CASK ? `install --cask ${name}` : `install ${name}`;
  }

  /** 升级的参数部分：`upgrade [--cask] <name>` */
  public static upgradeArgs(kind: string, token: string, tap: string): string {
    const name: string = BrewCommandGenerator.qualifiedName(token, tap);
    return kind === BrewKind.CASK ? `upgrade --cask ${name}` : `upgrade ${name}`;
  }

  /**
   * 全部升级的参数：0 全部 / 1 Formulae / 2 Casks。
   *
   * 下标与「我的 - 待更新」页筛选 chips 的下标一致，页面把 `filterIndex` 原样传进来。
   * 不加 `--formula` / `--cask` 时 brew 自己按包的类型升级，所以「全部」就是裸 `upgrade`。
   */
  public static upgradeAllArgs(filterIndex: number): string {
    if (filterIndex === 1) {
      return 'upgrade --formula';
    }
    if (filterIndex === 2) {
      return 'upgrade --cask';
    }
    return 'upgrade';
  }

  /**
   * 包名与 tap 的字符集校验。
   *
   * 规则：长度 1–128；首字符必须是字母或数字；其余允许字母、数字与 `@ + . _ - /`。
   * 首字符不允许 `-`，避免参数被 brew 当成选项而不是包名。
   *
   * 它只做一件事：把数据源来的包名挡在命令行之外，不试图成为 brew 的包名校验器。
   */
  public static isSafeName(value: string): boolean {
    if (value.length < 1 || value.length > 128) {
      return false;
    }
    const head: string = value.charAt(0);
    if (!BrewCommandGenerator.isAlphaNumeric(head)) {
      return false;
    }
    for (let index: number = 1; index < value.length; index++) {
      const one: string = value.charAt(index);
      if (!BrewCommandGenerator.isAlphaNumeric(one) && !BrewCommandGenerator.isNameSymbol(one)) {
        return false;
      }
    }
    return true;
  }

  /** 基础安装命令。区分 formula / cask。 */
  public static baseCommand(kind: string, token: string, tap: string): string {
    return `brew ${BrewCommandGenerator.installArgs(kind, token, tap)}`;
  }

  /** 卸载命令 */
  public static uninstallCommand(kind: string, token: string, tap: string): string {
    const name: string = BrewCommandGenerator.qualifiedName(token, tap);
    return kind === BrewKind.CASK ? `brew uninstall --cask ${name}` : `brew uninstall ${name}`;
  }

  /** 升级命令 */
  public static upgradeCommand(kind: string, token: string, tap: string): string {
    return `brew ${BrewCommandGenerator.upgradeArgs(kind, token, tap)}`;
  }

  /**
   * 从详情取安装命令。
   * 优先用数据里已算好的 `installCommand`（由 mock 生成器/后端产出），
   * 缺失时按 kind + token + tap 回退计算，保证 UI 侧不会拿到空串。
   */
  public static installCommandOf(detail: BrewFormulaDetail | BrewCaskDetail, kind: string): string {
    if (detail.installCommand) {
      return detail.installCommand;
    }
    return BrewCommandGenerator.baseCommand(kind, detail.token, detail.tap);
  }

  private static isAlphaNumeric(one: string): boolean {
    const code: number = one.charCodeAt(0);
    const isDigit: boolean = code >= 48 && code <= 57;
    const isLower: boolean = code >= 97 && code <= 122;
    const isUpper: boolean = code >= 65 && code <= 90;
    return isDigit || isLower || isUpper;
  }

  /** 允许出现在包名里的符号：版本后缀（`@1`）、分隔符与 tap 前缀里的 `/` */
  private static isNameSymbol(one: string): boolean {
    return one === '@' || one === '+' || one === '.' || one === '_' || one === '-' || one === '/';
  }
}
