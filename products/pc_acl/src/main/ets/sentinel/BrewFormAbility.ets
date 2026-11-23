import { formBindingData, FormExtensionAbility, formInfo } from '@kit.FormKit';
import type { Want } from '@kit.AbilityKit';
import { Logger } from '@ohos/common';
import { BrewSentinelService } from '@ohos/brewcommon';

const TAG: string = '[sentinel]';

/**
 * 更新哨兵的卡片提供方（FormExtensionAbility，spec §8）。
 *
 * 四个回调对应 P2 档的触发面：
 *   - onAddForm：登记 formId（GSKV，扩展进程写、宿主进程读）+ 返回首渲染数据；
 *   - onUpdateForm：系统定时刷新（form_config 的 updateDuration）→ 走 evaluateAndPush，
 *     与宿主前台路径（P3）共用同一份代码；
 *   - onRemoveForm：注销登记（G13：移除后快照仍归应用所有，重添加立即按盘上快照渲染）；
 *   - onFormEvent：本卡片的唯一交互是 postCardAction 的 router 事件（直达 PcAbility），
 *     不经过这里——保留兜底日志。
 *
 * 扩展进程没有 AppStorage/UIContext，因此这里只把 this.context 交给服务，不碰任何进程态。
 */
export default class BrewFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    // want.parameters 取卡片身份。FormParam.IDENTITY_KEY 即官方文档里的
    // 'ohos.extra.param.key.form_identity'（见 faqs-local-database-management-65 示例）
    const formId: string = want.parameters?.[formInfo.FormParam.IDENTITY_KEY] as string;
    Logger.info(TAG, `onAddForm formId=${formId}`);
    const service: BrewSentinelService = BrewSentinelService.getInstance();
    service.onFormAdded(this.context, formId);
    // 首渲染。扩展进程读不到盘上快照时服务会返回引导态数据（G1：不给 0 假数据）；
    // 宿主下次前台评估时会把真实数据推过来。
    return service.buildInitialBindingData(this.context, formId);
  }

  onUpdateForm(formId: string, wantParams?: Record<string, Object>): void {
    // P2 档的定时触发点（updateEnabled + updateDuration）。评估对登记表里的**所有**卡片生效，
    // 不只是本 formId——多张卡片天然共享同一份快照派生结果。
    Logger.info(TAG, `onUpdateForm formId=${formId}`);
    BrewSentinelService.getInstance().evaluateAndPush(this.context);
  }

  onFormEvent(formId: string, message: string): void {
    // 卡片没有 message 事件按钮；postCardAction 的 router 事件由系统直接拉起 PcAbility。
    Logger.info(TAG, `onFormEvent formId=${formId} message=${message}`);
  }

  onRemoveForm(formId: string): void {
    Logger.info(TAG, `onRemoveForm formId=${formId}`);
    BrewSentinelService.getInstance().onFormRemoved(this.context, formId);
  }

  onAcquireFormState(want: Want): formInfo.FormState {
    return formInfo.FormState.READY;
  }
}
