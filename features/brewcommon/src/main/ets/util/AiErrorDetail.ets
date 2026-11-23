/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { AiError } from '../model/AiTypes';

/**
 * E4/E5 错误的「细节后缀」解析（spec §8 排查记录：诊断信息直达 UI）。
 *
 * AiError.message 的约定格式：`d1 reason=truncated` / `http status=401 body=...`。
 * 本类把 message 翻成 UI 可拼的资源：E4 按 reason 分四种文案（fence/truncated/schema/
 * nonjson），E5 用「请求被拒绝（body 摘要）」。**Key 已在 AiClient.sanitize 脱敏过**，
 * 这里不再出现明文。
 */
export class AiErrorDetail {
  /** 从 AiError.message 抽取 reason= 值；E5 抽 body= 值；都没有返回空串。 */
  public static of(error: AiError): string {
    const message: string = error.message;
    const reasonIdx: number = message.indexOf('reason=');
    if (reasonIdx >= 0) {
      const rest: string = message.substring(reasonIdx + 'reason='.length);
      const space: number = rest.indexOf(' ');
      return space >= 0 ? rest.substring(0, space) : rest;
    }
    const bodyIdx: number = message.indexOf('body=');
    if (bodyIdx >= 0) {
      const rest: string = message.substring(bodyIdx + 'body='.length);
      const space: number = rest.indexOf(' ');
      return space >= 0 ? rest.substring(0, space) : rest;
    }
    return '';
  }

  /** E4 的文案：按 reason 资源化；未知 reason 回落到笼统文案。 */
  public static e4Text(reason: string): ResourceStr {
    if (reason === 'truncated') {
      return $r('app.string.ai_error_e4_detail_truncated');
    }
    if (reason === 'nonjson') {
      return $r('app.string.ai_error_e4_detail_nonjson');
    }
    if (reason === 'fence') {
      return $r('app.string.ai_error_e4_detail_fence');
    }
    if (reason === 'schema') {
      return $r('app.string.ai_error_e4_detail_schema');
    }
    return $r('app.string.ai_error_e4');
  }

  /** E5 的文案：带脱敏后的响应体摘要（很多「格式异常」其实是 401/404 的 HTML 页）。 */
  public static e5Text(bodyHead: string): ResourceStr {
    if (bodyHead.length === 0) {
      return $r('app.string.ai_error_e5');
    }
    return $r('app.string.ai_error_e5_detail', bodyHead);
  }
}
