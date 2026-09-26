/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { Logger, StorageKey } from '@ohos/common';
import { type BusinessError } from '@kit.BasicServicesKit';
import {
  HdsSnackBar,
  SnackBarIconOptions,
  SnackBarMessageOptions,
  SnackBarOperationOptions,
  SnackBarStyleOptions,
  SnackBarOperationType
} from '@kit.UIDesignKit';

const TAG: string = '[brew-notice]';

/**
 * 「正在获取 Homebrew 数据」提示的**唯一入口**（判据与 hook 点见
 * `docs/superpowers/specs/2026-09-22-brew-fetch-toast-design.md` §4/§13）。
 *
 * ## 为什么是"预测式"
 *
 * 需求方要的是「即将等待时提示」，而网络耗时只有发出去才知道，所以判定只能靠
 * **"这次会不会走网络"**这个可观测事实 —— 它已有唯一权威口径：`BrewLoadLog` 的 reason 词表
 * （`[load] kind=… reason=…`）。所以这里的 `reason` 参数**必须**是那一套词表里的值，
 * 由调用方（`BrewService` 的 hook 点）从同一批字面量传入 —— 不在这里另起一套判断，
 * 否则两套口径必然漂移。
 *
 * ## 为什么从 Toast 换成 HDS SnackBar（2026-09-23）
 *
 * 初版用 `Toast.showLongToast`（2000ms、**无 close API**）。真机实测暴露了这个形态的
 * **镜像问题**：目录探针要 **15.4s**，而 toast 只活 2s —— 提示只覆盖等待的前 13%，
 * 剩下 13 秒用户仍然是"看着转圈不知道在等什么"。
 *
 * `HdsSnackBar` 两个能力正好对上：
 *   1. `style.duration = -1` → **常驻**，不自动消失（官方指南《设置常驻通知弹窗》）；
 *   2. `dismiss()` → 数据到达时**主动撤掉**。
 * 于是"提示覆盖整个等待"和"不残留"同时成立 —— 这是 Toast 做不到的。
 *
 * 另加 `CLOSE_BUTTON_ONLY`：万一 `settle()` 因异常路径没被调到，用户能自己关掉，
 * 不会留下一个关不掉的常驻提示。
 *
 * ## 去重模型（比初版的 30s 时间窗更准）
 *
 * 初版用「`BREW_NET_NOTICE_MIN_INTERVAL_MS` 30s 窗口」合并冷启动那一簇。换成常驻 + 主动撤掉后，
 * **时间窗不再需要**：`shown` 布尔量天然表达"同一时刻只提示一件事"，
 * 而 `settle()` 之后再次 `willFetch()` 会正常重新弹 —— 语义比时间窗更贴合意图。
 */

export class BrewNetNotice {
  /**
   * 当前是否正显示着常驻提示。`true` 期间重复的 `willFetch` 不再重复弹（幂等）。
   * `settle()` 之后归 `false`，下一次 `willFetch` 会重新弹。
   *
   * 不加锁：调用点都在 UI 线程的加载路径上，读写同一线程。
   */
  private static shown: boolean = false;

  /** 复用一个实例（官方用法：构造时传 UIContext，之后只调 show/dismiss） */
  private static bar: HdsSnackBar | undefined = undefined;

  /**
   * 即将发起一批网络请求：弹一次**常驻**提示（已显示则不再重复弹）。
   *
   * `reason` 用 `BrewLoadLog` 的 reason 词表（触发它的那一条 `[load]` 的原因），
   * `detail` 是给人看的明细（进了日志，不进提示文案）。
   */
  public static willFetch(reason: string, detail: string): void {
    const already: boolean = BrewNetNotice.shown;
    if (!already) {
      BrewNetNotice.shown = BrewNetNotice.show();
    }
    // 与 `[load]` 同风格的判据行。排查「该弹没弹」看有没有这行；
    // 排查「不该弹却弹了」看 reason 是哪条判据放行的。
    Logger.info(TAG, '[notice] kind=fetch-toast action=show reason=' + reason +
      ' shown=' + BrewNetNotice.shown + ' alreadyShown=' + already +
      ' detail=' + detail + ' at=' + Date.now());
  }

  /**
   * 数据已到达（或该页加载结束）：撤掉常驻提示。
   *
   * **必须与 `willFetch` 成对**，否则提示会一直挂着（用户还能用关闭按钮自救）。
   * 目前挂在两处「构页完成」判据上：`BrewService.logPageLoad`（两个浏览页共用一个函数）
   * 与 `BrewRepository.getDiscoverPage` 的 `discover_page assembled`。
   */
  public static settle(reason: string, detail: string): void {
    const was: boolean = BrewNetNotice.shown;
    if (was) {
      BrewNetNotice.hide();
      BrewNetNotice.shown = false;
    }
    Logger.info(TAG, '[notice] kind=fetch-toast action=dismiss reason=' + reason +
      ' dismissed=' + was + ' detail=' + detail + ' at=' + Date.now());
  }

  private static show(): boolean {
    try {
      const uiContext: UIContext | undefined = AppStorage.get(StorageKey.UI_CONTEXT);
      if (!uiContext) {
        Logger.error(TAG, 'Show snackbar failed, cause uicontext is undefined');
        return false;
      }
      if (BrewNetNotice.bar === undefined) {
        BrewNetNotice.bar = new HdsSnackBar(uiContext);
      }
      const icon: SnackBarIconOptions = {
        icon: $r('sys.symbol.download')
      };
      const message: SnackBarMessageOptions = {
        content: $r('app.string.brew_fetching_data')
      };
      // 只给关闭按钮：本提示没有"操作"，只需要一个用户自救的出口
      const operation: SnackBarOperationOptions = {
        operationType: SnackBarOperationType.CLOSE_BUTTON_ONLY
      };
      // duration = -1 → 常驻（不自动消失），由 `settle()` 在数据到达时撤掉。
      // 这是本次换用 HdsSnackBar 的**全部理由**，别改成 >0 的值。
      const style: SnackBarStyleOptions = {
        duration: -1
      };
      BrewNetNotice.bar.show(icon, message, operation, style);
      return true;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      Logger.error(TAG, `Show snackbar error, the code is ${error.code}, the message is ${error.message}`);
      return false;
    }
  }

  private static hide(): void {
    if (BrewNetNotice.bar === undefined) {
      return;
    }
    try {
      BrewNetNotice.bar.dismiss();
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      Logger.error(TAG, `Dismiss snackbar error, the code is ${error.code}, the message is ${error.message}`);
    }
  }
}
