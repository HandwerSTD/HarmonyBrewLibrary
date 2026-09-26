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
 * 因此这里只保留必要的命令拼装：
 *   - baseCommand / installCommandOf：安装命令（第三方 tap 需补 qualified name）
 *   - uninstallCommand / upgradeCommand：Mine 页对已装包的操作
 */
export class BrewCommandGenerator {
  /** 第三方 tap 的包需要写全 qualified name（tap/token）；官方 tap 直接用 token。 */
  public static qualifiedName(token: string, tap: string): string {
    if (tap && tap !== 'homebrew/core' && tap !== 'homebrew/cask') {
      return `${tap}/${token}`;
    }
    return token;
  }

  /** 基础安装命令。区分 formula / cask。 */
  public static baseCommand(kind: string, token: string, tap: string): string {
    const name: string = BrewCommandGenerator.qualifiedName(token, tap);
    return kind === BrewKind.CASK ? `brew install --cask ${name}` : `brew install ${name}`;
  }

  /** 卸载命令 */
  public static uninstallCommand(kind: string, token: string, tap: string): string {
    const name: string = BrewCommandGenerator.qualifiedName(token, tap);
    return kind === BrewKind.CASK ? `brew uninstall --cask ${name}` : `brew uninstall ${name}`;
  }

  /** 升级命令 */
  public static upgradeCommand(kind: string, token: string, tap: string): string {
    const name: string = BrewCommandGenerator.qualifiedName(token, tap);
    return kind === BrewKind.CASK ? `brew upgrade --cask ${name}` : `brew upgrade ${name}`;
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
}
