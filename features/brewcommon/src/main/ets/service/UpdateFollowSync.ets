/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { common } from '@kit.AbilityKit';
import { Logger, StorageKey } from '@ohos/common';
import { BrewSentinelService } from './BrewSentinelService';

const TAG: string = '[update-follow]';

/**
 * 关注状态变化 → 桌面卡片重推的同步器（F 线）。
 *
 * 为什么独立成类而不挂到 UpdateFollowPrefs：哨兵服务（BrewSentinelService）要 import
 * UpdateFollowPrefs 读关注表做卡片过滤；本类反过来 import 哨兵服务。放同一个文件会
 * 形成 brewcommon 内部的模块循环依赖（文件 A→B→A），拆成两个文件后依赖单向：
 * UpdateFollowSync → BrewSentinelService → UpdateFollowPrefs。
 *
 * 为什么不等下一次前台评估：关注切换发生在「待更新」列表 / 详情页，此时应用就在前台，
 * P3 档的「回前台评估」不会再触发一次；不重推的话卡片要等到快照刷新才跟上口径。
 *
 * 只在宿主进程调用（关注切换只发生在宿主 UI）。UI_CONTEXT 未写入（极早期）时静默跳过：
 * 那时也没有已注册的卡片可推，无副作用。
 */
export class UpdateFollowSync {
  public static pushCard(): void {
    const uiContext: UIContext | undefined = AppStorage.get<UIContext>(StorageKey.UI_CONTEXT);
    if (uiContext === undefined) {
      Logger.warn(TAG, 'push skip: ui context not ready');
      return;
    }
    const ctx: common.Context | undefined = uiContext.getHostContext();
    if (ctx === undefined) {
      Logger.warn(TAG, 'push skip: host context not ready');
      return;
    }
    BrewSentinelService.getInstance().evaluateAndPush(ctx);
  }
}
