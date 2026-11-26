import { formBindingData, FormExtensionAbility, formInfo } from '@kit.FormKit';
import type { Want } from '@kit.AbilityKit';
import { Logger } from '@ohos/common';
import { BrewSentinelService, SENTINEL_DIMENSION_2_2, SENTINEL_DIMENSION_2_4, SENTINEL_DIMENSION_4_4,
  SENTINEL_FORM_NAME } from '@ohos/brewcommon';

const TAG: string = '[sentinel]';

/**
 * DIMENSION_KEY → 规格字符串（二期 spec §6.3 双通道的「binding 主通道」入口）。
 *
 * SDK 事实（@ohos.app.form.formInfo.d.ts 实测）：`FormParam.DIMENSION_KEY`
 * （'ohos.extra.param.key.form_dimension'）的取值是 **FormDimension 数字枚举**
 * （Dimension_2_2=2 / Dimension_2_4=3 / Dimension_4_4=4），不是字符串——而登记表与
 * 卡片数据里规格统一用字符串口径（SENTINEL_DIMENSION_*），这里做枚举→字符串的翻译。
 *
 * 返回 null 表示「want 里没有可靠的规格信息」：调用方必须**跳过**登记刷新，
 * 绝不能拿默认规格顶上——否则 4*4 卡会被一次不带规格的定时刷新悄悄降级成 2*2。
 * 意外的枚举值/字符串口径（'2*2'）返回空串或原样透传，由服务侧 normalizeDimension
 * 白名单统一收口兜底。
 */
function dimensionOfParams(params?: Record<string, Object>): string | null {
  const raw: Object | undefined = params?.[formInfo.FormParam.DIMENSION_KEY];
  if (typeof raw === 'number') {
    switch (raw) {
      case formInfo.FormDimension.Dimension_2_2:
        return SENTINEL_DIMENSION_2_2;
      case formInfo.FormDimension.Dimension_2_4:
        return SENTINEL_DIMENSION_2_4;
      case formInfo.FormDimension.Dimension_4_4:
        return SENTINEL_DIMENSION_4_4;
      default:
        Logger.warn(TAG, `unknown form dimension enum value=${raw}, fallback to default`);
        return '';
    }
  }
  if (typeof raw === 'string' && (raw as string).indexOf('*') >= 0) {
    // 字符串口径兜底：不同版本系统可能直接给 '2*2' 形态，服务侧统一归一
    return raw as string;
  }
  return null;
}

/**
 * NAME_KEY → 卡种（F 线双卡）。`FormParam.NAME_KEY`
 * （'ohos.extra.param.key.form_name'）的值是 form_config.json 里本卡片的 name
 * （BrewSentinelCard / BrewFollowCard）。取不到（null）时调用方兜底原哨兵卡：
 * F 线前登记表里只有一种卡，want 缺 name 的场合只可能是存量卡/异常路径。
 */
function nameOfParams(params?: Record<string, Object>): string | null {
  const raw: Object | undefined = params?.[formInfo.FormParam.NAME_KEY];
  if (typeof raw === 'string' && (raw as string).length > 0) {
    return raw as string;
  }
  return null;
}

/**
 * 更新哨兵的卡片提供方（FormExtensionAbility，spec §8；F 线起同时服务两张卡）。
 *
 * 四个回调对应 P2 档的触发面：
 *   - onAddForm：按卡种登记 formId + 规格 + name（F 线 v3 登记表）+ 返回对应口径的首渲染数据；
 *   - onUpdateForm：系统定时刷新（form_config 的 updateDuration）→ 走 evaluateAndPush，
 *     与宿主前台路径（P3）共用同一份代码，评估对登记表里的**所有**卡（两卡种）生效；
 *     resize/系统携带规格的刷新先幂等刷新登记（同 id 同规格同卡种不动，变化覆写——
 *     同 onAddForm 收敛在一个方法里）；
 *   - onRemoveForm：注销登记（G13：移除后快照仍归应用所有，重添加立即按盘上镜像渲染）；
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
    const dimension: string | null = dimensionOfParams(want.parameters);
    // 卡种：取不到（异常路径）兜底原哨兵卡——F 线前登记表里只有它
    const name: string = nameOfParams(want.parameters) ?? SENTINEL_FORM_NAME;
    Logger.info(TAG, `onAddForm formId=${formId} dimension=${dimension === null ? 'unknown' : dimension} name=${name}`);
    const service: BrewSentinelService = BrewSentinelService.getInstance();
    // null（无规格信息）时传空串：服务侧 normalizeDimension 兜底默认规格 2*2
    service.onFormAdded(this.context, formId, dimension === null ? '' : dimension, name);
    // 首渲染（按卡种读对应镜像）。扩展进程读不到盘上快照时服务会返回引导态数据
    // （G1：不给 0 假数据）；宿主下次前台评估时会把真实数据推过来。
    return service.buildInitialBindingData(this.context, formId, dimension === null ? '' : dimension, name);
  }

  onUpdateForm(formId: string, wantParams?: Record<string, Object>): void {
    // P2 档的定时触发点（updateEnabled + updateDuration）。评估对登记表里的**所有**卡生效，
    // 不只是本 formId——多张卡片（两卡种）天然共享同一份快照派生结果。
    // 系统带规格的刷新（resize 等）先幂等刷新登记再评估；不带规格的刷新**不动登记**，
    // 防止已有规格被默认值覆写（见 dimensionOfParams 的 null 语义）。
    const dimension: string | null = dimensionOfParams(wantParams);
    const name: string | null = nameOfParams(wantParams);
    Logger.info(TAG, `onUpdateForm formId=${formId} dimension=${dimension === null ? 'absent' : dimension} name=${name === null ? 'absent' : name}`);
    const service: BrewSentinelService = BrewSentinelService.getInstance();
    if (dimension !== null || name !== null) {
      // 带规格/卡种的刷新才动登记；缺哪一项就传哪一项的既有语义值（规格缺省传空串走
      // 归一兜底不影响已登记值——onFormAdded 对「同 id 同规格同卡种」是幂等 no-op）
      service.onFormAdded(this.context, formId, dimension === null ? '' : dimension,
        name === null ? SENTINEL_FORM_NAME : name);
    }
    service.evaluateAndPush(this.context);
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
