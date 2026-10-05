/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { Logger, PreferenceManager } from '@ohos/common';

const TAG: string = '[MinePrefs]';

/**
 * 隐藏作为依赖安装的包。三个本机包列表页的标题栏 chip 共用这一个键：
 * 任一页面切换，另外两个页面下次进入就是同一状态。
 */
const HIDE_DEPENDENCY_KEY: string = 'mine_hide_dependency';

/**
 * 「更新全部」的依赖提醒是否已确认。
 *
 * 与上面那个键分开：提醒说明的是命令的语义（会一并升级全部过时的包），
 * 与当前有没有隐藏无关，确认过一次就不再出现。
 */
const UPGRADE_NOTICE_KEY: string = 'mine_dep_upgrade_notice';

/**
 * 本机包显示设置的读写。
 *
 * 走 `PreferenceManager`（与 `brew_installed_snapshot` 同一份存储）。读取失败 —— 存储还没有打开、
 * 键缺失、值解析失败 —— 一律按默认值（false）处理，与 `PreferenceManager.getValue` 的容错语义一致。
 *
 * 每次写入打一行日志，供上机时与页面状态对账。
 */
export class MinePackagePrefs {
  public static hideDependency(): boolean {
    return PreferenceManager.getInstance().getValue<boolean>(HIDE_DEPENDENCY_KEY) === true;
  }

  public static setHideDependency(value: boolean): void {
    PreferenceManager.getInstance().setValue<boolean>(HIDE_DEPENDENCY_KEY, value);
    Logger.info(TAG, `hide-dependency=${value}`);
  }

  public static upgradeNoticeAcknowledged(): boolean {
    return PreferenceManager.getInstance().getValue<boolean>(UPGRADE_NOTICE_KEY) === true;
  }

  public static acknowledgeUpgradeNotice(): void {
    PreferenceManager.getInstance().setValue<boolean>(UPGRADE_NOTICE_KEY, true);
    Logger.info(TAG, 'upgrade-notice=true');
  }
}
