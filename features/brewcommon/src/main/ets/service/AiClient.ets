/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import {
  HmAIChatRequest,
  HmAIChatResult,
  HmAIErrorCode,
  HmAIMessage,
  HmAIProviders,
  HmAIResponseFormat,
  HmAIResponseFormatType,
  OpenAICompatibleClient,
  OpenAICompatibleClientOptions,
} from '@hmkit/ai';
import { Logger } from '@ohos/common';
import {
  AI_PROMPT_MAX_CHARS,
  AI_TIMEOUT_MS,
} from '../constant/AiConstants';
import { AiError, AiErrorKind, AiProviderConfig } from '../model/AiTypes';
import { AiSettingsStore } from './AiSettingsStore';

const TAG: string = '[ai]';

/**
 * 一次 chat completion 的输出：正文 + token 用量（缓存 meta 与 G3 的判据日志都要用）。
 */
export class AiCompletion {
  public content: string = '';
  public model: string = '';
  public promptTokens: number = 0;
  public completionTokens: number = 0;
  public latencyMs: number = 0;
}

/**
 * 单任务请求描述。AiClient 是唯一的 @hmkit/ai 调用点；任务侧只给
 * system / user 文本 + 温度 + 输出上限 + 是否要求 JSON。
 */
class AiChatTask {
  public system: string = '';
  public user: string = '';
  public temperature: number = 0.2;
  public maxTokens: number = 500;
  public requireJson: boolean = true;
}

/**
 * 模型调用客户端（spec §3.2）。
 *
 * ## 与 @hmkit/ai 的关系（编码第一天最小样例核对结论，已写回 spec §3.2）
 *
 * - **初始化**：`HmAIProviders.deepSeek(model)` / `HmAIProviders.custom(baseUrl, model)`
 *   得到 `HmAIProviderConfig`，再 `createChatClient()`——库对 custom 端点的判定是
 *   `new OpenAICompatibleClientOptions(baseUrl, model)` 等价形态，BYOK 三元组
 *   （baseURL / Key / model）都能从设置页带进去；
 * - **response_format**：库有 `HmAIResponseFormat.jsonObject()`（`response_format:
 *   {"type":"json_object"}`）。DeepSeek / 大多数 OpenAI 兼容端点支持；
 *   **能力探测不做**（一次探测本身就是一次计费请求），端点不支持时服务端通常忽略该字段，
 *   落到「prompt 要求 JSON + 解析校验（E4）」这条兜底路上——spec §3.2 本来就这么定；
 * - **调用形态**：库只有流式入口 `createStream(request).start()`（返回 Promise<HmAIChatResult>），
 *   非流式语义由「拿最终 result、忽略 onDelta」实现；
 * - **错误结构**：`HmAIError { code: HmAIErrorCode, statusCode?, responseBody? }`，
 *   code ∈ network / timeout / http / protocol / cancelled / …，与本 spec 的 E2/E3/E4/E6
 *   一一映射；HTTP 4xx/5xx（含内容安全 4xx）走 `http` + `statusCode`，按 E5 处理。
 *
 * ## 其它固定口径
 *
 * - **超时 15s、不自动重试**（全部显式触发，用户自己重试）；
 * - prompt 总长超 8KB 抛 E4 之前的截断由**调用方**做（D1 截 caveats、D3 截 stderr/stdout），
 *   这里只做最后一道守卫：超限时抛 E1 语义之外的 E4（不该出现的输入是编程错误）；
 * - **Key 永不进日志**：请求头在库内部拼装，本类日志只有 ok / latency / token 数。
 */
export class AiClient {
  /**
   * 发一次 chat completion 并返回正文。
   * 内部完成：读配置与 Key → 拼消息 → 流式入口等待最终结果 → 错误分级。
   */
  public static async complete(task: AiChatTask): Promise<AiCompletion> {
    const config: AiProviderConfig = AiSettingsStore.loadConfig();
    if (!config.isComplete()) {
      throw new AiError(AiErrorKind.E1_NO_KEY, 'provider config incomplete');
    }
    const promptLength: number = task.system.length + task.user.length;
    if (promptLength > AI_PROMPT_MAX_CHARS) {
      throw new AiError(AiErrorKind.E4_BAD_FORMAT, `prompt too long, chars=${promptLength}`);
    }
    const apiKey: string = await AiSettingsStore.loadApiKey();
    if (apiKey.length === 0) {
      throw new AiError(AiErrorKind.E1_NO_KEY, 'api key missing');
    }
    const client: OpenAICompatibleClient = AiClient.clientOf(config, apiKey);
    const request: HmAIChatRequest = new HmAIChatRequest(AiClient.messagesOf(task));
    request.temperature = task.temperature;
    request.maxTokens = task.maxTokens;
    request.includeUsage = true;
    if (task.requireJson) {
      request.responseFormat = HmAIResponseFormat.jsonObject();
    }
    const startedAt: number = Date.now();
    try {
      const result: HmAIChatResult = await client.createStream(request).start();
      const latency: number = Date.now() - startedAt;
      const out: AiCompletion = new AiCompletion();
      out.content = result.content;
      out.model = result.model.length > 0 ? result.model : config.model;
      out.latencyMs = latency;
      if (result.usage !== undefined) {
        out.promptTokens = result.usage.promptTokens;
        out.completionTokens = result.usage.completionTokens;
      }
      Logger.info(TAG, `complete ok model=${out.model} latency=${latency} ` +
        `tokens=${out.promptTokens}/${out.completionTokens} chars=${out.content.length}`);
      return out;
    } catch (err) {
      throw AiClient.classify(err, Date.now() - startedAt);
    }
  }

  /**
   * 测试连接（spec G2）：最小 completion（max_tokens=8，纯文本）。
   * 成功返回 model 与时延；失败抛分好级的 AiError。
   */
  public static async probe(): Promise<AiCompletion> {
    const task: AiChatTask = new AiChatTask();
    task.system = 'You are a connection test. Reply with the single word: ok';
    task.user = 'ping';
    task.temperature = 0;
    task.maxTokens = 8;
    task.requireJson = false;
    return AiClient.complete(task);
  }

  /** HmAIErrorCode → 本 spec 的 E 分级（spec §8 的映射行）。 */
  private static classify(err: Object, latencyMs: number): AiError {
    const e: Error = err as Error;
    const name: string = e.name;
    // HmAIError 带 code 字段；asHmAIError 也能收编普通 Error
    const codeField: Object | undefined = (err as Record<string, Object>)['code'];
    const code: string = typeof codeField === 'string' ? codeField as string : name;
    Logger.error(TAG, `complete fail code=${code} latency=${latencyMs} msg=${e.message}`);
    switch (code) {
      case HmAIErrorCode.NETWORK:
        return new AiError(AiErrorKind.E2_NETWORK, e.message);
      case HmAIErrorCode.TIMEOUT:
        return new AiError(AiErrorKind.E3_TIMEOUT, e.message);
      case HmAIErrorCode.CANCELLED:
        return new AiError(AiErrorKind.E6_CANCELLED, e.message);
      case HmAIErrorCode.HTTP: {
        // 内容安全拒绝大多表现为 400 特定码或 403；没有响应体结构约定，
        // 统一按 E5（provider 拒绝）报——UI 文案对齐 spec §8 的 E5 行。
        const statusField: Object | undefined = (err as Record<string, Object>)['statusCode'];
        const status: number = typeof statusField === 'number' ? statusField as number : 0;
        return new AiError(AiErrorKind.E5_BLOCKED, `http status=${status}`);
      }
      case HmAIErrorCode.PROTOCOL:
        return new AiError(AiErrorKind.E4_BAD_FORMAT, e.message);
      default:
        // 其余（invalid_argument / internal）按网络失败归 E2：用户动作相同（重试）。
        return new AiError(AiErrorKind.E2_NETWORK, e.message);
    }
  }

  private static clientOf(config: AiProviderConfig, apiKey: string): OpenAICompatibleClient {
    let options: OpenAICompatibleClientOptions;
    if (config.isDeepSeek()) {
      options = HmAIProviders.deepSeek(config.model).createChatClient() === undefined ?
        new OpenAICompatibleClientOptions('https://api.deepseek.com', config.model) :
        HmAIProviders.deepSeek(config.model).createChatClient();
    } else {
      options = new OpenAICompatibleClientOptions(config.baseUrl, config.model);
    }
    options.apiKey = apiKey;
    options.connectTimeoutMs = AI_TIMEOUT_MS;
    options.readTimeoutMs = AI_TIMEOUT_MS;
    return new OpenAICompatibleClient(options);
  }

  private static messagesOf(task: AiChatTask): HmAIMessage[] {
    const messages: HmAIMessage[] = [HmAIMessage.system(task.system)];
    messages.push(HmAIMessage.user(task.user));
    return messages;
  }
}

export { AiChatTask };
