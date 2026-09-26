/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { common, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger, ProcessUtil } from '@ohos/common';

const TAG: string = '[BrewSource]';

/**
 * 应用重启（切换数据源后的生效手段）。
 *
 * ## 三级兜底，顺序有理由
 *
 * 1. **`UIAbilityContext.restartApp(want)`**（API 22+，**保留窗口**）：用户视野停留在应用内，
 *    没有桌面闪现。已核对的约束：**仅主线程**、**应用需获焦**、**3 秒内不可重复调用**。
 * 2. **`ApplicationContext.restartApp(want)`**（API 12+，不保留窗口）：会露一下桌面，
 *    但约束更少（同样是主线程 + 获焦 + 3 秒）。
 * 3. **`ProcessUtil.exitApp()`**：最差情况退到「直接退进程」，由用户手动重开。
 *    到这一步说明前两级都不可用，继续等下去只会让用户以为按钮坏了。
 *
 * ## 为什么不使用 `appRecovery.restartApp()`
 *
 * 它有「两次重启的间隔应大于一分钟」的约束 —— 一分钟内重复调用**只退出、不重启**。
 * 用户连续切换两次源就会踩到，表现为「App 自己关了」。
 */
export class BrewSourceRestart {
  private static readonly BUNDLE_NAME: string = 'top.handwer.brewlibrary';
  private static readonly ABILITY_NAME: string = 'PcAbility';

  public static async restart(context: common.UIAbilityContext): Promise<boolean> {
    const want: Want = { bundleName: BrewSourceRestart.BUNDLE_NAME, abilityName: BrewSourceRestart.ABILITY_NAME };
    // 1) 保留窗口的重启
    try {
      await context.restartApp(want);
      Logger.info(TAG, 'activate restart via UIAbilityContext.restartApp, ok=true');
      return true;
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.error(TAG, `activate restart fallback=ApplicationContext, errCode=${e?.code}, errMsg=${e?.message}`);
    }
    // 2) 不保留窗口的重启
    try {
      const appContext: common.ApplicationContext = context.getApplicationContext();
      appContext.restartApp(want);
      Logger.info(TAG, 'activate restart via ApplicationContext.restartApp, ok=true');
      return true;
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.error(TAG, `activate restart fallback=exitApp, errCode=${e?.code}, errMsg=${e?.message}`);
    }
    // 3) 退进程，由用户手动重开
    ProcessUtil.exitApp();
    Logger.info(TAG, 'activate restart via ProcessUtil.exitApp, ok=true');
    return false;
  }
}
