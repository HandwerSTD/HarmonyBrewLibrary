/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { BaseState } from '@ohos/common';
import { AiSettingsSnapshot } from '@ohos/brewcommon';

/** AI 设置页的状态。**整个对象里没有 Key 明文**（G1）——只有 hasKey / keyMemoryOnly 标记。 */
@Observed
export class AiSettingState extends BaseState {
  /** 盘上 + Asset 的当前快照（进页面时读一次；保存后整体替换触发刷新）。 */
  public snapshot: AiSettingsSnapshot = new AiSettingsSnapshot();
  /** 表单字段：baseURL（预置 DeepSeek 时锁定为模板值）。 */
  public editingBaseUrl: string = '';
  /** 表单字段：model。 */
  public editingModel: string = '';
  /** 表单字段：provider（deepseek | custom）。 */
  public editingProvider: string = 'deepseek';
  /** Key 输入框内容。**只在内存，保存即清空**——不进 state 快照、不进任何日志。 */
  public editingKey: string = '';
  /** 表单 / 保存校验错误（空串 = 无）。 */
  public errorText: string = '';
  /** Key 是否只存在会话内存（Asset 不可用时的兜底标记，来自 AiSettingsStore）。 */
  public keyMemoryOnly: boolean = false;
  /** 「测试连接」进行中。 */
  public testing: boolean = false;
  /** 测试结果行：成功时为「model · latency」，失败时为分级原因（human-readable key）。 */
  public testOkText: string = '';
  public testErrorKind: string = '';
  /** 刚保存成功的提示（一次性）。 */
  public savedFlash: boolean = false;
}
