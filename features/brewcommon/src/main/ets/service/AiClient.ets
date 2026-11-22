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
import type { HmAIProviderConfig } from '@hmkit/ai';
import { http } from '@kit.NetworkKit';
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
  /**
   * provider 的 finish_reason 原文（stop / length / content_filter / …）。
   * `length` = max_tokens 截断——对 JSON 输出意味着正文不完整，任务层读它抛 E4(truncated)。
   */
  public finishReason: string = '';
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
    const startedAt: number = Date.now();
    // 兼容模式（非流式）：自定义端点开了开关时绕开 @hmkit/ai 的流式 decoder
    // （该 decoder 对流式 chunk 的 usage=null 不判空，见 AiConstants 的 AI_PREFS_KEY_NON_STREAMING 注）。
    if (config.nonStreaming && !config.isDeepSeek()) {
      return AiClient.completeNonStreaming(config, apiKey, task, startedAt);
    }
    const client: OpenAICompatibleClient = AiClient.clientOf(config, apiKey);
    const request: HmAIChatRequest = new HmAIChatRequest(AiClient.messagesOf(task));
    request.temperature = task.temperature;
    request.maxTokens = task.maxTokens;
    request.includeUsage = true;
    if (task.requireJson) {
      request.responseFormat = HmAIResponseFormat.jsonObject();
    }
    try {
      const result: HmAIChatResult = await client.createStream(request).start();
      const latency: number = Date.now() - startedAt;
      const out: AiCompletion = new AiCompletion();
      out.content = result.content;
      out.model = result.model.length > 0 ? result.model : config.model;
      out.latencyMs = latency;
      out.finishReason = result.finishReason;
      if (result.usage !== undefined) {
        out.promptTokens = result.usage.promptTokens;
        out.completionTokens = result.usage.completionTokens;
      }
      return AiClient.logCompletion(out, latency);
    } catch (err) {
      throw AiClient.classify(err, Date.now() - startedAt);
    }
  }

  /** 成功打点收敛（流式 / 非流式两条路径共用同一份日志格式）。 */
  private static logCompletion(out: AiCompletion, latency: number): AiCompletion {
    Logger.info(TAG, `complete ok model=${out.model} latency=${latency} ` +
      `finish=${out.finishReason} tokens=${out.promptTokens}/${out.completionTokens} ` +
      `chars=${out.content.length}`);
    // 响应头 80 字节脱敏打点（spec §8 排查记录 ④）：真机日志一眼看出端点返回了什么
    Logger.info(TAG, `complete head=${AiClient.sanitize(out.content.substring(0, 80))}`);
    return out;
  }

  /**
   * 非流式直连（兼容模式）：一次 POST {baseUrl}/chat/completions，stream=false。
   * 「拿最终 result」本来就是我们唯一用到的语义，非流式在自建端点上完全够用；
   * usage 缺省/null 时按 0 兜底（OpenAI 协议里 usage 是可选字段）。
   * Key 只进 Authorization 头（库外的拼装点；头对象不进日志）。
   */
  private static async completeNonStreaming(config: AiProviderConfig, apiKey: string,
    task: AiChatTask, startedAt: number): Promise<AiCompletion> {
    const base: string = config.baseUrl.trim().replace(/\/+$/, '');
    const url: string = `${base}/chat/completions`;
    const bodyRecord: Record<string, Object> = {
      'model': config.model,
      'stream': false,
      'temperature': task.temperature,
      'max_tokens': task.maxTokens,
    };
    const messages: Array<Object> = [];
    messages.push(AiClient.messageJson('system', task.system));
    messages.push(AiClient.messageJson('user', task.user));
    bodyRecord['messages'] = messages;
    if (task.requireJson) {
      bodyRecord['response_format'] = AiClient.jsonFormatRecord();
    }
    const client: http.HttpRequest = http.createHttp();
    try {
      const header: Record<string, string> = {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${apiKey}`,
      };
      const resp: http.HttpResponse = await client.request(url, {
        method: http.RequestMethod.POST,
        header: header,
        extraData: JSON.stringify(bodyRecord),
        connectTimeout: AI_TIMEOUT_MS,
        readTimeout: AI_TIMEOUT_MS,
        usingCache: false,
      });
      const status: number = resp.responseCode;
      const text: string = typeof resp.result === 'string' ? resp.result as string : '';
      if (status < 200 || status >= 300) {
        // 对齐流式路径的 HTTP 分级：4xx/5xx 按 E5（provider 拒绝）报，body 摘要带进细节
        Logger.error(TAG, `complete fail code=http status=${status} latency=${Date.now() - startedAt}`);
        throw new AiError(AiErrorKind.E5_BLOCKED,
          `http status=${status} body=${AiClient.sanitize(text.substring(0, 120))}`);
      }
      const out: AiCompletion = AiClient.parseNonStreaming(text, config.model);
      out.latencyMs = Date.now() - startedAt;
      return AiClient.logCompletion(out, out.latencyMs);
    } catch (err) {
      if (err instanceof AiError) {
        throw err;
      }
      throw AiClient.classify(err, Date.now() - startedAt);
    } finally {
      client.destroy();
    }
  }

  /** OpenAI 消息体的一段（非流式请求用；流式路径仍走 HmAIMessage）。 */
  private static messageJson(role: string, content: string): Record<string, Object> {
    const out: Record<string, Object> = { 'role': role, 'content': content };
    return out;
  }

  /** response_format 的 JSON 形态（与 HmAIResponseFormat.jsonObject() 等价）。 */
  private static jsonFormatRecord(): Record<string, Object> {
    const out: Record<string, Object> = { 'type': HmAIResponseFormatType.JSON_OBJECT };
    return out;
  }

  /**
   * 解析非流式响应（OpenAI chat completion 形态）：
   * `choices[0].message.content` / `finish_reason`，`usage` 判空兜底 0。
   * 结构不符抛 E4；choices 为空数组也归 E4（端点异常行为的显式化）。
   */
  private static parseNonStreaming(text: string, fallbackModel: string): AiCompletion {
    const out: AiCompletion = new AiCompletion();
    out.model = fallbackModel;
    let root: Object | null = null;
    try {
      root = JSON.parse(text) as Object;
    } catch (err) {
      throw new AiError(AiErrorKind.E4_BAD_FORMAT,
        `nonjson body=${AiClient.sanitize(text.substring(0, 120))}`);
    }
    if (root === null || root === undefined || Array.isArray(root)) {
      throw new AiError(AiErrorKind.E4_BAD_FORMAT, 'nonjson body is not an object');
    }
    const obj: Record<string, Object> = root as Record<string, Object>;
    const choicesObj: Object | undefined = obj['choices'];
    if (!Array.isArray(choicesObj)) {
      throw new AiError(AiErrorKind.E4_BAD_FORMAT, 'schema choices missing');
    }
    const choices: Array<Object> = choicesObj as Array<Object>;
    if (choices.length === 0) {
      throw new AiError(AiErrorKind.E4_BAD_FORMAT, 'schema choices empty');
    }
    const first: Object | undefined = choices[0];
    if (first === undefined || first === null) {
      throw new AiError(AiErrorKind.E4_BAD_FORMAT, 'schema choices[0] missing');
    }
    const choice: Record<string, Object> = first as Record<string, Object>;
    const messageObj: Object | undefined = choice['message'];
    if (messageObj === undefined || messageObj === null) {
      throw new AiError(AiErrorKind.E4_BAD_FORMAT, 'schema message missing');
    }
    const message: Record<string, Object> = messageObj as Record<string, Object>;
    const contentObj: Object | undefined = message['content'];
    out.content = typeof contentObj === 'string' ? contentObj as string : '';
    const finishObj: Object | undefined = choice['finish_reason'];
    out.finishReason = typeof finishObj === 'string' ? finishObj as string : '';
    const modelObj: Object | undefined = obj['model'];
    if (typeof modelObj === 'string' && (modelObj as string).length > 0) {
      out.model = modelObj as string;
    }
    const usageObj: Object | undefined = obj['usage'];
    if (typeof usageObj === 'object' && usageObj !== null && usageObj !== undefined) {
      const usage: Record<string, Object> = usageObj as Record<string, Object>;
      if (typeof usage['prompt_tokens'] === 'number') {
        out.promptTokens = usage['prompt_tokens'] as number;
      }
      if (typeof usage['completion_tokens'] === 'number') {
        out.completionTokens = usage['completion_tokens'] as number;
      }
    }
    return out;
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

  /** 任务请求描述的构造入口（AiTasks 用；不外泄 AiChatTask 的其它用法）。 */
  public static newTask(): AiChatTask {
    return new AiChatTask();
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
        // 401/404 的 HTML 错误页是「格式异常」报障的常见真因（spec §8 排查记录 ③）：
        // 响应体前 120 字节脱敏后带进 message 与 UI 细节行。
        const statusField: Object | undefined = (err as Record<string, Object>)['statusCode'];
        const status: number = typeof statusField === 'number' ? statusField as number : 0;
        const bodyField: Object | undefined = (err as Record<string, Object>)['responseBody'];
        const body: string = typeof bodyField === 'string' ? bodyField as string : '';
        return new AiError(AiErrorKind.E5_BLOCKED,
          `http status=${status} body=${AiClient.sanitize(body.substring(0, 120))}`);
      }
      case HmAIErrorCode.PROTOCOL:
        return new AiError(AiErrorKind.E4_BAD_FORMAT, e.message);
      default:
        // 其余（invalid_argument / internal）按网络失败归 E2：用户动作相同（重试）。
        return new AiError(AiErrorKind.E2_NETWORK, e.message);
    }
  }

  /**
   * 脱敏：sk- 开头的 token 段替换为 `sk-***`。响应体/打点进日志与错误细节前必过这里
   * （G1 的延伸：即便端点把 Key 回显在错误页里，也不落日志）。
   * 非流式直连路径的 Authorization 头对象整体不进日志——脱敏只是最后一道栅栏。
   */
  public static sanitize(text: string): string {
    let out: string = text;
    const idx: number = out.indexOf('sk-');
    if (idx >= 0) {
      // 从 sk- 起把连续的 token 字符段（字母数字与 - _）替换掉
      let end: number = idx + 3;
      while (end < out.length) {
        const ch: string = out.charAt(end);
        const isTokenChar: boolean = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
          (ch >= '0' && ch <= '9') || ch === '-' || ch === '_';
        if (!isTokenChar) {
          break;
        }
        end++;
      }
      out = out.substring(0, idx) + 'sk-***' + out.substring(end);
    }
    return out.replace(/[\r\n]+/g, ' ');
  }

  private static clientOf(config: AiProviderConfig, apiKey: string): OpenAICompatibleClient {
    let options: OpenAICompatibleClientOptions;
    if (config.isDeepSeek()) {
      // DeepSeek 模板：baseURL 用库内置预设（api.deepseek.com），model 用用户配置的值。
      const provider: HmAIProviderConfig = HmAIProviders.deepSeek(config.model);
      options = new OpenAICompatibleClientOptions(provider.baseURL, config.model);
      options.chatCompletionsPath = provider.chatCompletionsPath;
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

/** 任务请求描述的外部名（AiTasks 用；ArkTS 不支持跨文件引非导出类，取别名导出）。 */
export { AiChatTask as AiClientTask };
