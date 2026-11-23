import { common } from '@kit.AbilityKit';
import { workScheduler } from '@kit.BackgroundTasksKit';
import type { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '@ohos/common';
import { BrewInstalledLoader, BrewSentinelService, SENTINEL_WORK_ID, SENTINEL_WORK_INTERVAL_MS,
  SENTINEL_WORK_SCHEDULER_ENABLED } from '@ohos/brewcommon';

const TAG: string = '[sentinel]';

/**
 * P3 档（纯前台保底，恒开）的启动接线（spec §3.3，决策 4）。
 *
 * PcAbility.onCreate 调 `init(this.context)`：
 *   - 订阅 BrewInstalledLoader 的快照更新（saveSnapshot 成功后回调）——数据链路零新增：
 *     Loader 不改一行（spec §8 说 Loader「加一行」是可优化项，用既有 subscribe 回调注入
 *     更优，依赖方向仍是 Loader 不 import 哨兵，避免环）；
 *   - 按档位常量决定要不要向系统登记 work scheduler 任务（P1，当前休眠）。
 *
 * PcAbility.onForeground 调 `onForeground(this.context)`：每次回前台评估一次，
 * 应用存活期间卡片与通知都靠它保底（无论探针结论如何，这一档恒成立）。
 */
export class SentinelBootstrap {
  /**
   * 快照更新回调。存成字段保证 subscribe / 未来可能的 unsubscribe 拿到同一个函数对象——
   * Loader 按函数对象去重，两处各造一个箭头函数会退订不掉、回调叠加。
   */
  private static snapshotListener: (() => void) | null = null;

  public static init(context: common.UIAbilityContext): void {
    const service: BrewSentinelService = BrewSentinelService.getInstance();
    if (SentinelBootstrap.snapshotListener === null) {
      SentinelBootstrap.snapshotListener = () => {
        service.evaluateAndPush(context, true);
      };
      BrewInstalledLoader.subscribe(SentinelBootstrap.snapshotListener);
      Logger.info(TAG, 'subscribed to installed snapshot updates');
    }
    if (SENTINEL_WORK_SCHEDULER_ENABLED) {
      SentinelBootstrap.scheduleWork(context);
    } else {
      Logger.info(TAG, 'P1 work scheduler dormant (probe Q3 pending)');
    }
  }

  /** 应用回到前台：评估一次快照。UI_CONTEXT 可能尚未写入（loadContent 之后才有），
   *  早期调用读不到快照会被服务静默跳过，无副作用 */
  public static onForeground(context: common.UIAbilityContext): void {
    BrewSentinelService.getInstance().evaluateAndPush(context, true);
  }

  private static scheduleWork(context: common.UIAbilityContext): void {
    const info: workScheduler.WorkInfo = {
      workId: SENTINEL_WORK_ID,
      bundleName: BrewSentinelService.selfBundleName(),
      abilityName: 'BrewWorkSchedulerExtension',
      isRepeat: true,
      isPersisted: true,
      repeatCycleTime: SENTINEL_WORK_INTERVAL_MS,
    };
    try {
      workScheduler.startWork(info);
      Logger.info(TAG, `work scheduled id=${SENTINEL_WORK_ID} interval=${SENTINEL_WORK_INTERVAL_MS}`);
    } catch (err) {
      // 登记失败不抛：P1 只是档位之一，P2/P3 不受影响（spec §5：降档是配置切换而非代码失败）
      const e: BusinessError = err as BusinessError;
      Logger.warn(TAG, `startWork failed code=${e.code} message=${e.message}`);
    }
  }
}
