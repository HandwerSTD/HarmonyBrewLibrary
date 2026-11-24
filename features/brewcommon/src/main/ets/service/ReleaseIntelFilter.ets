/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { ReleaseIntelPrefs } from './ReleaseIntelPrefs';

/**
 * 哨兵侧的抑制判定（spec G6：Y 对 H 的**唯一**接入点）。
 *
 * `BrewSentinelService` 在计算通知计数与去重哈希之前，用它过滤 outdated 列表；
 * 桌面卡片展示的 TOP 名单也用过滤后的列表。哈希公式本身不变（对过滤后的输入算）。
 *
 * 独立成文件而不是直接把 BrewSentinelService 指向 ReleaseIntelPrefs：
 *   1. 哨兵是扩展进程也会跑的代码，引用面必须最小（审计脚本也钉住这一条 import）；
 *   2. 策略语义（精确版本匹配 / 暂停截止）集中在一处，卡片页与哨兵读同一份。
 *
 * 注意：本文件**不得** import BrewInstalledLoader / BrewCommandRunner / BrewCli /
 * ShellUtils（触达点零执行审计，hmosword-build/brew-sentinel）。
 */
export class ReleaseIntelFilter {
  /** 该包的「这一版」是否应从提醒中压掉。context 缺失时恒 false（宁可多提醒不漏提醒）。 */
  public static isSuppressed(token: string, offeredVersion: string): boolean {
    return ReleaseIntelPrefs.isSuppressed(token, offeredVersion);
  }
}
