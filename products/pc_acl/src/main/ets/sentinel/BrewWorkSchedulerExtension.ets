import { WorkSchedulerExtensionAbility, workScheduler } from '@kit.BackgroundTasksKit';
import { Logger } from '@ohos/common';
import { BrewSentinelService } from '@ohos/brewcommon';

const TAG: string = '[sentinel]';

/**
 * P1 档的延迟任务回调（WorkSchedulerExtensionAbility，spec §3.3 / §8）。
 *
 * **当前处于休眠**：注册与实现已就位（module.json5 type=workScheduler），但 app 侧
 * `workScheduler.startWork` 被 SentinelConstants 的 `SENTINEL_WORK_SCHEDULER_ENABLED`
 * 关死——work scheduler 在应用退出于 2in1 的真实触发边界未探明（spec §3.2 Q3），
 * 探针结论可用后翻常量即可启用，本文件不需要再改。
 *
 * 回调里与其它触发源走同一个 evaluateAndPush：只读盘上快照，不跑任何命令
 * （spec §3.1——即使探针 Q4 表明扩展进程能跑命令，v1 也不跑）。
 */
export default class BrewWorkSchedulerExtension extends WorkSchedulerExtensionAbility {
  onWorkStart(workInfo: workScheduler.WorkInfo): void {
    Logger.info(TAG, `onWorkStart workId=${workInfo.workId}`);
    BrewSentinelService.getInstance().evaluateAndPush(this.context);
  }

  onWorkStop(workInfo: workScheduler.WorkInfo): void {
    // 单次回调最长 2 分钟，超时或 stopWork 都会进这里；哨兵是只读评估，正常瞬间结束
    Logger.info(TAG, `onWorkStop workId=${workInfo.workId}`);
  }
}
