import { BusinessError } from '@kit.BasicServicesKit';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { HmAIError, HmAIErrorCode } from '../core/Errors';
import { HmAIMessage, HmAIToolCall } from '../core/Message';
import { HmAIContentPart, HmAIContentPartType } from '../core/Content';
import { HmAIChatModel, HmAIChatRequest, HmAIChatResult, HmAIResponseFormat, HmAIResponseFormatType,
  HmAIStreamObserver, HmAIStreamTask, HmAIToolDefinition } from '../core/Types';
import { OpenAICompatibleStreamDecoder } from '../protocol/OpenAIStreamDecoder';

class OpenAIWireMessage {
  role: string;
  content: string | OpenAIChatContentPartWire[];
  name?: string;
  tool_call_id?: string;
  tool_calls?: OpenAIToolCallWire[];

  constructor(message: HmAIMessage) {
    this.role = message.role;
    this.content = OpenAIWireMessage.content(message);
    this.name = message.name;
    this.tool_call_id = message.toolCallId;
    if (message.toolCalls.length > 0) {
      this.tool_calls = message.toolCalls.map((call: HmAIToolCall): OpenAIToolCallWire =>
        new OpenAIToolCallWire(call));
    }
  }

  private static content(message: HmAIMessage): string | OpenAIChatContentPartWire[] {
    const hasMedia: boolean = message.parts.some((part: HmAIContentPart): boolean =>
      part.type !== HmAIContentPartType.TEXT);
    if (!hasMedia) return message.content;
    return message.parts.map((part: HmAIContentPart): OpenAIChatContentPartWire =>
      new OpenAIChatContentPartWire(part));
  }
}

class OpenAIImageURLWire {
  url: string;
  detail: string;

  constructor(part: HmAIContentPart) {
    this.url = part.dataUrl();
    this.detail = part.detail;
  }
}

class OpenAIInputAudioWire {
  data: string;
  format: string;

  constructor(part: HmAIContentPart) {
    this.data = part.base64Data;
    this.format = part.mimeType.includes('wav') ? 'wav' : 'mp3';
  }
}

class OpenAIInputFileWire {
  file_data?: string;
  file_id?: string;
  filename?: string;

  constructor(part: HmAIContentPart) {
    if (part.fileId.length > 0) this.file_id = part.fileId;
    else this.file_data = part.dataUrl();
    if (part.fileName.length > 0) this.filename = part.fileName;
  }
}

class OpenAIChatContentPartWire {
  type: string;
  text?: string;
  image_url?: OpenAIImageURLWire;
  input_audio?: OpenAIInputAudioWire;
  file?: OpenAIInputFileWire;

  constructor(part: HmAIContentPart) {
    if (part.type === HmAIContentPartType.TEXT) {
      this.type = 'text';
      this.text = part.text;
    } else if (part.type === HmAIContentPartType.IMAGE) {
      this.type = 'image_url';
      this.image_url = new OpenAIImageURLWire(part);
    } else if (part.type === HmAIContentPartType.AUDIO) {
      this.type = 'input_audio';
      this.input_audio = new OpenAIInputAudioWire(part);
    } else {
      this.type = 'file';
      this.file = new OpenAIInputFileWire(part);
    }
  }
}

class OpenAIFunctionCallWire {
  name: string;
  arguments: string;

  constructor(call: HmAIToolCall) {
    this.name = call.name;
    this.arguments = call.argumentsJson;
  }
}

class OpenAIToolCallWire {
  id: string;
  type: string = 'function';
  function: OpenAIFunctionCallWire;

  constructor(call: HmAIToolCall) {
    this.id = call.id;
    this.function = new OpenAIFunctionCallWire(call);
  }
}

class OpenAIFunctionDefinitionWire {
  name: string;
  description: string;
  parameters: Object;
  strict?: boolean;

  constructor(definition: HmAIToolDefinition) {
    this.name = definition.name;
    this.description = definition.description;
    this.parameters = parseJsonObject(definition.parametersJsonSchema, `工具 ${definition.name} 的 JSON Schema`);
    if (definition.strict) this.strict = true;
  }
}

class OpenAIToolDefinitionWire {
  type: string = 'function';
  function: OpenAIFunctionDefinitionWire;

  constructor(definition: HmAIToolDefinition) {
    this.function = new OpenAIFunctionDefinitionWire(definition);
  }
}

class OpenAIStreamOptionsWire {
  include_usage: boolean = true;
}

class OpenAIJsonSchemaWire {
  name: string;
  description?: string;
  schema: Object;
  strict: boolean;

  constructor(format: HmAIResponseFormat) {
    this.name = format.name;
    if (format.description.length > 0) this.description = format.description;
    this.schema = parseJsonObject(format.jsonSchema, '结构化输出 JSON Schema');
    this.strict = format.strict;
  }
}

class OpenAIResponseFormatWire {
  type: string;
  json_schema?: OpenAIJsonSchemaWire;

  constructor(format: HmAIResponseFormat) {
    this.type = format.type;
    if (format.type === HmAIResponseFormatType.JSON_SCHEMA) {
      if (!/^[A-Za-z0-9_-]{1,64}$/.test(format.name)) {
        throw new HmAIError(HmAIErrorCode.INVALID_ARGUMENT, '结构化输出名称只能包含字母、数字、下划线或连字符，长度 1-64');
      }
      this.json_schema = new OpenAIJsonSchemaWire(format);
    }
  }
}

function parseJsonObject(source: string, label: string): Object {
  try {
    return JSON.parse(source) as Object;
  } catch (_error) {
    throw new HmAIError(HmAIErrorCode.INVALID_ARGUMENT, `${label} 无效`);
  }
}

class OpenAIRequestBody {
  model: string;
  messages: OpenAIWireMessage[];
  stream: boolean = true;
  temperature?: number;
  top_p?: number;
  max_tokens?: number;
  tools?: OpenAIToolDefinitionWire[];
  tool_choice?: string;
  parallel_tool_calls?: boolean;
  response_format?: OpenAIResponseFormatWire;
  stream_options?: OpenAIStreamOptionsWire;

  constructor(model: string, request: HmAIChatRequest) {
    this.model = model;
    this.messages = request.messages.map((message: HmAIMessage): OpenAIWireMessage => new OpenAIWireMessage(message));
    this.temperature = request.temperature;
    this.top_p = request.topP;
    this.max_tokens = request.maxTokens;
    if (request.tools.length > 0) {
      this.tools = request.tools.map((definition: HmAIToolDefinition): OpenAIToolDefinitionWire =>
        new OpenAIToolDefinitionWire(definition));
      this.tool_choice = request.toolChoice;
      this.parallel_tool_calls = request.parallelToolCalls;
    }
    if (request.responseFormat !== undefined && request.responseFormat.type !== HmAIResponseFormatType.TEXT) {
      this.response_format = new OpenAIResponseFormatWire(request.responseFormat);
    }
    if (request.includeUsage) this.stream_options = new OpenAIStreamOptionsWire();
  }
}

export function encodeOpenAICompatibleRequest(model: string, request: HmAIChatRequest): string {
  if (model.trim().length === 0) {
    throw new HmAIError(HmAIErrorCode.INVALID_ARGUMENT, 'model 不能为空');
  }
  return JSON.stringify(new OpenAIRequestBody(model, request));
}

export class OpenAICompatibleClientOptions {
  readonly baseURL: string;
  readonly model: string;
  apiKey?: string;
  chatCompletionsPath: string = '/chat/completions';
  connectTimeoutMs: number = 10000;
  readTimeoutMs: number = 120000;
  headers: Record<string, string> = {};

  constructor(baseURL: string, model: string) {
    this.baseURL = baseURL;
    this.model = model;
  }
}

export class OpenAICompatibleClient implements HmAIChatModel {
  private readonly options: OpenAICompatibleClientOptions;

  constructor(options: OpenAICompatibleClientOptions) {
    if (options.baseURL.trim().length === 0) {
      throw new HmAIError(HmAIErrorCode.INVALID_ARGUMENT, 'baseURL 不能为空');
    }
    if (options.model.trim().length === 0) {
      throw new HmAIError(HmAIErrorCode.INVALID_ARGUMENT, 'model 不能为空');
    }
    this.options = options;
  }

  createStream(request: HmAIChatRequest, observer: HmAIStreamObserver = new HmAIStreamObserver()): HmAIStreamTask {
    const model: string = request.model?.trim() || this.options.model;
    const body: string = encodeOpenAICompatibleRequest(model, request);
    return new OpenAICompatibleStreamTask(this.endpoint(), this.options, body, observer);
  }

  private endpoint(): string {
    const base: string = this.options.baseURL.endsWith('/')
      ? this.options.baseURL.substring(0, this.options.baseURL.length - 1)
      : this.options.baseURL;
    const path: string = this.options.chatCompletionsPath.startsWith('/')
      ? this.options.chatCompletionsPath
      : `/${this.options.chatCompletionsPath}`;
    return `${base}${path}`;
  }
}

class OpenAICompatibleStreamTask implements HmAIStreamTask {
  private readonly url: string;
  private readonly clientOptions: OpenAICompatibleClientOptions;
  private readonly body: string;
  private readonly observer: HmAIStreamObserver;
  private request?: http.HttpRequest;
  private decoder?: OpenAICompatibleStreamDecoder;
  private textDecoder?: util.TextDecoder;
  private resolve?: (result: HmAIChatResult) => void;
  private reject?: (error: HmAIError) => void;
  private result?: HmAIChatResult;
  private responseBody: string = '';
  private statusCode: number = 0;
  private statusReady: boolean = false;
  private dataEnded: boolean = false;
  private started: boolean = false;
  private settled: boolean = false;
  private cancelled: boolean = false;
  private readonly onDataReceive: Callback<ArrayBuffer>;
  private readonly onDataEnd: Callback<void>;

  constructor(url: string, options: OpenAICompatibleClientOptions, body: string,
    observer: HmAIStreamObserver) {
    this.url = url;
    this.clientOptions = options;
    this.body = body;
    this.observer = observer;
    this.onDataReceive = (data: ArrayBuffer): void => this.consumeBytes(data);
    this.onDataEnd = (): void => this.endData();
  }

  start(): Promise<HmAIChatResult> {
    if (this.started) {
      return Promise.reject(new HmAIError(HmAIErrorCode.INVALID_ARGUMENT, '同一个流式任务只能启动一次'));
    }
    this.started = true;
    if (this.cancelled) {
      return Promise.reject(new HmAIError(HmAIErrorCode.CANCELLED, '请求已取消'));
    }
    return new Promise<HmAIChatResult>((resolve: (result: HmAIChatResult) => void,
      reject: (error: HmAIError) => void): void => {
      this.resolve = resolve;
      this.reject = reject;
      this.beginRequest();
    });
  }

  cancel(): void {
    if (this.cancelled || this.settled) return;
    this.cancelled = true;
    if (this.started) this.fail(new HmAIError(HmAIErrorCode.CANCELLED, '请求已取消'));
  }

  isCancelled(): boolean {
    return this.cancelled;
  }

  private beginRequest(): void {
    try {
      this.textDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      this.decoder = new OpenAICompatibleStreamDecoder(new HmAIStreamObserver(
        (delta): void => this.observer.onDelta(delta),
        (result: HmAIChatResult): void => { this.result = result; },
        (error: HmAIError): void => this.fail(error)
      ));
      this.request = http.createHttp();
      this.request.on('dataReceive', this.onDataReceive);
      this.request.on('dataEnd', this.onDataEnd);
      this.request.requestInStream(this.url, this.requestOptions())
        .then((statusCode: number): void => {
          if (this.settled) return;
          this.statusCode = statusCode;
          this.statusReady = true;
          if (statusCode < 200 || statusCode >= 300) {
            this.fail(new HmAIError(HmAIErrorCode.HTTP, `模型服务返回 HTTP ${statusCode}`,
              statusCode, this.responseBody));
            return;
          }
          this.trySucceed();
        })
        .catch((error: BusinessError): void => this.fail(this.mapNetworkError(error)));
    } catch (error) {
      const detail: string = error instanceof Error ? error.message : '未知错误';
      this.fail(new HmAIError(HmAIErrorCode.INTERNAL, `无法启动模型请求：${detail}`));
    }
  }

  private requestOptions(): http.HttpRequestOptions {
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'Accept': 'text/event-stream'
    };
    if (this.clientOptions.apiKey !== undefined && this.clientOptions.apiKey.length > 0) {
      headers['Authorization'] = `Bearer ${this.clientOptions.apiKey}`;
    }
    Object.keys(this.clientOptions.headers).forEach((key: string): void => {
      headers[key] = this.clientOptions.headers[key];
    });
    return {
      method: http.RequestMethod.POST,
      header: headers,
      extraData: this.body,
      connectTimeout: this.clientOptions.connectTimeoutMs,
      readTimeout: this.clientOptions.readTimeoutMs,
      usingCache: false
    };
  }

  private consumeBytes(data: ArrayBuffer): void {
    if (this.settled || this.textDecoder === undefined || this.decoder === undefined) return;
    try {
      const text: string = this.textDecoder.decodeToString(new Uint8Array(data), { stream: true });
      if (this.responseBody.length < 8192) {
        this.responseBody += text.substring(0, 8192 - this.responseBody.length);
      }
      this.decoder.push(text);
    } catch (error) {
      const detail: string = error instanceof Error ? error.message : '未知解码错误';
      this.fail(new HmAIError(HmAIErrorCode.PROTOCOL, `无法解码模型响应：${detail}`));
    }
  }

  private endData(): void {
    if (this.settled || this.dataEnded) return;
    try {
      if (this.textDecoder !== undefined && this.decoder !== undefined) {
        const tail: string = this.textDecoder.decodeToString(new Uint8Array(0), { stream: false });
        this.decoder.push(tail);
        this.result = this.decoder.finish();
      }
      this.dataEnded = true;
      this.trySucceed();
    } catch (error) {
      const detail: string = error instanceof Error ? error.message : '未知结束错误';
      this.fail(new HmAIError(HmAIErrorCode.PROTOCOL, `模型流结束处理失败：${detail}`));
    }
  }

  private trySucceed(): void {
    if (this.settled || !this.statusReady || !this.dataEnded || this.result === undefined) return;
    this.settled = true;
    const result: HmAIChatResult = this.result;
    this.cleanup();
    this.observer.onComplete(result);
    this.resolve?.(result);
  }

  private fail(error: HmAIError): void {
    if (this.settled) return;
    this.settled = true;
    this.cleanup();
    this.observer.onError(error);
    this.reject?.(error);
  }

  private cleanup(): void {
    if (this.request === undefined) return;
    this.request.off('dataReceive', this.onDataReceive);
    this.request.off('dataEnd', this.onDataEnd);
    this.request.destroy();
    this.request = undefined;
  }

  private mapNetworkError(error: BusinessError): HmAIError {
    if (this.cancelled) return new HmAIError(HmAIErrorCode.CANCELLED, '请求已取消', undefined, undefined, error.code);
    if (error.code === 2300028) {
      return new HmAIError(HmAIErrorCode.TIMEOUT, '模型请求超时', undefined, undefined, error.code);
    }
    return new HmAIError(HmAIErrorCode.NETWORK, error.message || '模型网络请求失败',
      undefined, undefined, error.code);
  }
}
