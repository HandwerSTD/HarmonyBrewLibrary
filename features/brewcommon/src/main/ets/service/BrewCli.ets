/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { Logger, StorageKey } from '@ohos/common';
import {
  SHELL_BREW_PATH_CANDIDATES,
  SHELL_DEFAULT_WORKING_DIRECTORY,
  ShellUtils,
} from '@ohos/pcnative';
import type { ShellResult } from '@ohos/pcnative';

const TAG: string = '[BrewCli]';

/**
 * 设备上的 brew 调用口径。
 *
 * 「怎么找到 brew」「命令行长什么样」「在哪个目录下跑」三件事收在这一处，
 * 读命令与写命令共用同一份拼装，不再各写一份环境前缀。
 *
 * 环境变量内联进命令行而不是靠子进程继承：执行通道是否继承环境变量是探针的一条用例，
 * 内联之后这一条不成立也不影响本文件 —— `HOMEBREW_PREFIX` 由 brew 脚本自己按
 * `bin/brew` 的位置推导，其余几个只是「不要做额外的事」的开关。
 *
 * `HOMEBREW_NO_AUTO_UPDATE=1` 保留的理由：页面上的「待更新」是按设备本地 tap 状态算出来的
 * （`brew info --json=v2 --installed` 的 `outdated` 字段），升级命令用同一份状态才能做到
 * 「页面说升哪些就升哪些」；`brew update` 要联网、要 git、可能几分钟，不在本功能范围内。
 */
export class BrewCli {
  /**
   * 设备执行能力（brew cli）是否可用。
   *
   * 由 entry 的 UIAbility 在 `onCreate` 写入 `StorageKey.BREW_CLI_ENABLED`：pc_acl 注入 true、
   * pc_normal 注入 false；未注入时按 false 处理。
   */
  public static isEnabled(): boolean {
    return AppStorage.get<boolean>(StorageKey.BREW_CLI_ENABLED) ?? false;
  }

  /** 能力开关打开、执行通道可用、且找到 brew 可执行文件 */
  public static isReady(): boolean {
    if (!BrewCli.isEnabled() || !ShellUtils.available()) {
      return false;
    }
    return BrewCli.brewPath().length > 0;
  }

  /**
   * 发现 brew 可执行文件。
   *
   * 顺序：`HOMEBREW_BREW_FILE` -> 固定候选路径。候选表在 `@ohos/pcnative` 的
   * `SHELL_BREW_PATH_CANDIDATES`，与执行通道同层，避免两处各写一份漂移。
   *
   * 结果在进程内缓存：这是一次 `test -x` 的探测，而页面上每次取数都会走到这里。
   * 同步调用的代价只发生在本进程第一次调用时，所以把它量出来写进日志 ——
   * 主线程上跑命令是通道里唯一会阻塞界面的地方，其余都走线程池。
   */
  public static brewPath(): string {
    if (BrewCli.pathCache !== null) {
      return BrewCli.pathCache;
    }
    const startedAt: number = Date.now();
    const fromEnv: string = BrewCli.envBrewPath();
    if (fromEnv.length > 0) {
      BrewCli.pathCache = fromEnv;
      Logger.info(TAG, `discover brew from env, sync=${Date.now() - startedAt}ms brew=${fromEnv}`);
      return fromEnv;
    }
    for (const candidate of SHELL_BREW_PATH_CANDIDATES) {
      const check: ShellResult = ShellUtils.runSync(`test -x "${candidate}" && echo yes`, 5000);
      if (check.ok && check.stdout.trim() === 'yes') {
        BrewCli.pathCache = candidate;
        Logger.info(TAG, `discover brew from candidates, sync=${Date.now() - startedAt}ms brew=${candidate}`);
        return candidate;
      }
    }
    Logger.warn(TAG, `discover brew failed, sync=${Date.now() - startedAt}ms`);
    return '';
  }

  /** `bin/brew` 的上一级目录。找不到时返回空串 */
  public static prefix(): string {
    const brewPath: string = BrewCli.brewPath();
    const suffix: string = '/bin/brew';
    if (brewPath.length <= suffix.length || !brewPath.endsWith(suffix)) {
      return '';
    }
    return brewPath.substring(0, brewPath.length - suffix.length);
  }

  /**
   * 子进程工作目录：brew 的 prefix，取不到时用通道的默认目录。
   *
   * 用 brew 的 prefix 而不是应用进程的当前目录：后者是 `/`，而应用用户对 `/` 没有读权限，
   * brew 启动时会检查当前目录可读性，在那儿跑会直接失败，且失败信息与真正的权限问题无关。
   */
  public static workingDirectory(): string {
    const prefix: string = BrewCli.prefix();
    return prefix.length > 0 ? prefix : SHELL_DEFAULT_WORKING_DIRECTORY;
  }

  /** 完整命令行：环境前缀 + brew 路径 + args。args 为空串、或 brew 不可用时返回空串 */
  public static commandLine(args: string): string {
    if (args.length === 0) {
      return '';
    }
    const brewPath: string = BrewCli.brewPath();
    if (brewPath.length === 0) {
      return '';
    }
    const prefix: string = BrewCli.prefix();
    const env: string = 'HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1 ' +
      'HOMEBREW_NO_ENV_HINTS=1 NONINTERACTIVE=1';
    const prefixEnv: string = prefix.length > 0 ? ` HOMEBREW_PREFIX="${prefix}"` : '';
    return `${env}${prefixEnv} "${brewPath}" ${args}`;
  }

  private static envBrewPath(): string {
    // 只有存在 shell 通道时才问环境变量；通道不可用时连 `printenv` 都跑不了
    if (!ShellUtils.available()) {
      return '';
    }
    const result: ShellResult = ShellUtils.runSync('printenv HOMEBREW_BREW_FILE', 5000);
    if (!result.ok) {
      return '';
    }
    const value: string = result.stdout.trim();
    return value.length > 0 ? value : '';
  }

  private static pathCache: string | null = null;
}