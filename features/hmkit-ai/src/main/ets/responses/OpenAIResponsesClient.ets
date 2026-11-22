import { BusinessError } from '@kit.BasicServicesKit';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { HmAIError, HmAIErrorCode } from '../core/Errors';
import { HmAIContentPart, HmAIContentPartType } from '../core/Content';
import { HmAIMessage, HmAIMessageRole, HmAIToolCall } from '../core/Message';
import { HmAIChatModel, HmAIChatRequest, HmAIChatResult, HmAIResponseFormat, HmAIResponseFormatType,
  HmAIStreamObserver, HmAIStreamTask, HmAIToolDefinition } from '../core/Types';
import { OpenAIResponsesStreamDecoder } from './ResponsesDecoder';
import { HmAIResponsesObserver, HmAIResponsesRequest, HmAIResponsesResult, HmAIResponsesTask } from './ResponsesTypes';

class ResponseInputContentWire {
  type: string;
  text?: string;
  image_url?: string;
  file_url?: string;
  file_data?: string;
  file_id?: string;
  filename?: string;

  constructor(part: HmAIContentPart) {
    if (part.type === HmAIContentPartType.TEXT) {
      this.type = 'input_text';
      this.text = part.text;
    } else if (part.type === HmAIContentPartType.IMAGE) {
      this.type = 'input_image';
      this.image_url = part.dataUrl();
    } else if (part.type === HmAIContentPartType.FILE) {
      this.type = 'input_file';
      if (part.fileId.length > 0) this.file_id = part.fileId;
      else if (part.url.length > 0) this.file_url = part.url;
      else this.file_data = part.dataUrl();
      if (part.fileName.length > 0) this.filename = part.fileName;
    } else {
      this.type = 'input_audio';
      this.file_data = part.dataUrl();
    }
  }
}

class ResponseMessageInputWire {
  type: string = 'message';
  role: string;
  content: ResponseInputContentWire[];

  constructor(message: HmAIMessage) {
    this.role = message.role;
    const parts: HmAIContentPart[] = message.parts.length > 0 ? message.parts : [HmAIContentPart.text(message.content)];
    this.content = parts.map((part: HmAIContentPart): ResponseInputContentWire => new ResponseInputContentWire(part));
  }
}

class ResponseFunctionCallInputWire {
  type: string = 'function_call';
  call_id: string;
  name: string;
  arguments: string;

  constructor(call: HmAIToolCall) {
    this.call_id = call.id;
    this.name = call.name;
    this.arguments = call.argumentsJson;
  }
}

class ResponseFunctionOutputInputWire {
  type: string = 'function_call_output';
  call_id: string;
  output: string;

  constructor(message: HmAIMessage) {
    this.call_id = message.toolCallId ?? '';
    this.output = message.content;
  }
}

class ResponseFunctionToolWire {
  type: string = 'function';
  name: string;
  description: string;
  parameters: Object;
  strict: boolean;

  constructor(definition: HmAIToolDefinition) {
    this.name = definition.name;
    this.description = definition.description;
    this.parameters = parseObject(definition.parametersJsonSchema, `工具 ${definition.name} JSON Schema`);
    this.strict = definition.strict;
  }
}

class ResponseTextFormatWire {
  type: string;
  name?: string;
  description?: string;
  schema?: Object;
  strict?: boolean;

  constructor(format: HmAIResponseFormat) {
    this.type = format.type;
    if (format.type === HmAIResponseFormatType.JSON_SCHEMA) {
      this.name = format.name;
      if (format.description.length > 0) this.description = format.description;
      this.schema = parseObject(format.jsonSchema, '结构化输出 JSON Schema');
      this.strict = format.strict;
    }
  }
}

class ResponseTextWire {
  format: ResponseTextFormatWire;
  constructor(format: HmAIResponseFormat) { this.format = new ResponseTextFormatWire(format); }
}

class ResponsesRequestWire {
  model: string;
  input: Object[] = [];
  stream: boolean = true;
  instructions?: string;
  previous_response_id?: string;
  store?: boolean;
  temperature?: number;
  top_p?: number;
  max_output_tokens?: number;
  tools?: ResponseFunctionToolWire[];
  tool_choice?: string;
  parallel_tool_calls?: boolean;
  text?: ResponseTextWire;
  truncation?: string;

  constructor(model: string, request: HmAIResponsesRequest) {
    this.model = model;
    this.input = encodeInput(request.input);
    if (request.instructions.length > 0) this.instructions = request.instructions;
    if (request.previousResponseId.length > 0) this.previous_response_id = request.previousResponseId;
    this.store = request.store;
    this.temperature = request.temperature;
    this.top_p = request.topP;
    this.max_output_tokens = request.maxOutputTokens;
    if (request.tools.length > 0) {
      this.tools = request.tools.map((tool: HmAIToolDefinition): ResponseFunctionToolWire =>
        new ResponseFunctionToolWire(tool));
      this.tool_choice = request.toolChoice;
      this.parallel_tool_calls = request.parallelToolCalls;
    }
    if (request.responseFormat !== undefined) this.text = new ResponseTextWire(request.responseFormat);
    if (request.truncation.length > 0) this.truncation = request.truncation;
  }
}

function encodeInput(messages: HmAIMessage[]): Object[] {
  const input: Object[] = [];
  for (let index: number = 0; index < messages.length; index++) {
    const message: HmAIMessage = messages[index];
    if (message.role === HmAIMessageRole.TOOL) {
      input.push(new ResponseFunctionOutputInputWire(message));
    } else {
      if (message.content.length > 0 || message.parts.length > 0) input.push(new ResponseMessageInputWire(message));
      for (let callIndex: number = 0; callIndex < message.toolCalls.length; callIndex++) {
        input.push(new ResponseFunctionCallInputWire(message.toolCalls[callIndex]));
      }
    }
  }
  return input;
}

function parseObject(source: string, label: string): Object {
  try { return JSON.parse(source) as Object; }
  catch (_error) { throw new HmAIError(HmAIErrorCode.INVALID_ARGUMENT, `${label} 无效`); }
}

export function encodeOpenAIResponsesRequest(model: string, request: HmAIResponsesRequest): string {
  if (model.trim().length === 0) throw new HmAIError(HmAIErrorCode.INVALID_ARGUMENT, 'model 不能为空');
  return JSON.stringify(new ResponsesRequestWire(model, request));
}

export class OpenAIResponsesClientOptions {
  readonly baseURL: string;
  readonly model: string;
  apiKey?: string;
  responsesPath: string = '/responses';
  connectTimeoutMs: number = 10000;
  readTimeoutMs: number = 120000;
  headers: Record<string, string> = {};

  constructor(baseURL: string, model: string) {
    this.baseURL = baseURL;
    this.model = model;
  }
}

export class OpenAIResponsesClient implements HmAIChatModel {
  private readonly options: OpenAIResponsesClientOptions;

  constructor(options: OpenAIResponsesClientOptions) {
    if (options.baseURL.trim().length === 0 || options.model.trim().length === 0) {
      throw new HmAIError(HmAIErrorCode.INVALID_ARGUMENT, 'baseURL 和 model 不能为空');
    }
    this.options = options;
  }

  createResponseStream(request: HmAIResponsesRequest,
    observer: HmAIResponsesObserver = new HmAIResponsesObserver()): HmAIResponsesTask {
    const model: string = request.model?.trim() || this.options.model;
    const body: string = encodeOpenAIResponsesRequest(model, request);
    return new OpenAIResponsesHttpTask(this.endpoint(), this.options, body, observer);
  }

  createStream(request: HmAIChatRequest, observer: HmAIStreamObserver = new HmAIStreamObserver()): HmAIStreamTask {
    const responseRequest: HmAIResponsesRequest = new HmAIResponsesRequest(request.messages);
    responseRequest.model = request.model;
    responseRequest.temperature = request.temperature;
    responseRequest.topP = request.topP;
    responseRequest.maxOutputTokens = request.maxTokens;
    responseRequest.tools = request.tools;
    responseRequest.toolChoice = request.toolChoice;
    responseRequest.parallelToolCalls = request.parallelToolCalls;
    responseRequest.responseFormat = request.responseFormat;
    return new ResponsesChatTaskAdapter(this.createResponseStream(responseRequest,
      new HmAIResponsesObserver(observer.onDelta)), observer);
  }

  private endpoint(): string {
    const base: string = this.options.baseURL.endsWith('/') ?
      this.options.baseURL.substring(0, this.options.baseURL.length - 1) : this.options.baseURL;
    const path: string = this.options.responsesPath.startsWith('/') ?
      this.options.responsesPath : `/${this.options.responsesPath}`;
    return `${base}${path}`;
  }
}

class ResponsesChatTaskAdapter implements HmAIStreamTask {
  private readonly task: HmAIResponsesTask;
  private readonly observer: HmAIStreamObserver;
  constructor(task: HmAIResponsesTask, observer: HmAIStreamObserver) { this.task = task; this.observer = observer; }
  async start(): Promise<HmAIChatResult> {
    try {
      const result: HmAIResponsesResult = await this.task.start();
      const chatResult: HmAIChatResult = new HmAIChatResult(result.text, result.model, result.status,
        result.usage, result.toolCalls);
      this.observer.onComplete(chatResult);
      return chatResult;
    } catch (error) {
      const mapped: HmAIError = error instanceof HmAIError ? error :
        new HmAIError(HmAIErrorCode.INTERNAL, 'Responses 请求失败');
      this.observer.onError(mapped);
      throw mapped;
    }
  }
  cancel(): void { this.task.cancel(); }
  isCancelled(): boolean { return this.task.isCancelled(); }
}

class OpenAIResponsesHttpTask implements HmAIResponsesTask {
  private readonly url: string;
  private readonly options: OpenAIResponsesClientOptions;
  private readonly body: string;
  private readonly observer: HmAIResponsesObserver;
  private request?: http.HttpRequest;
  private decoder?: OpenAIResponsesStreamDecoder;
  private textDecoder?: util.TextDecoder;
  private resolve?: (result: HmAIResponsesResult) => void;
  private reject?: (error: HmAIError) => void;
  private result?: HmAIResponsesResult;
  private statusCode: number = 0;
  private statusReady: boolean = false;
  private dataEnded: boolean = false;
  private started: boolean = false;
  private settled: boolean = false;
  private cancelled: boolean = false;
  private responseBody: string = '';
  private readonly onDataReceive: Callback<ArrayBuffer>;
  private readonly onDataEnd: Callback<void>;

  constructor(url: string, options: OpenAIResponsesClientOptions, body: string, observer: HmAIResponsesObserver) {
    this.url = url; this.options = options; this.body = body; this.observer = observer;
    this.onDataReceive = (data: ArrayBuffer): void => this.consume(data);
    this.onDataEnd = (): void => this.end();
  }

  start(): Promise<HmAIResponsesResult> {
    if (this.started) return Promise.reject(new HmAIError(HmAIErrorCode.INVALID_ARGUMENT, '任务只能启动一次'));
    this.started = true;
    if (this.cancelled) return Promise.reject(new HmAIError(HmAIErrorCode.CANCELLED, '请求已取消'));
    return new Promise<HmAIResponsesResult>((resolve: (result: HmAIResponsesResult) => void,
      reject: (error: HmAIError) => void): void => { this.resolve = resolve; this.reject = reject; this.begin(); });
  }

  cancel(): void {
    if (this.cancelled || this.settled) return;
    this.cancelled = true;
    if (this.started) this.fail(new HmAIError(HmAIErrorCode.CANCELLED, '请求已取消'));
  }
  isCancelled(): boolean { return this.cancelled; }

  private begin(): void {
    try {
      this.textDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      this.decoder = new OpenAIResponsesStreamDecoder(new HmAIResponsesObserver(
        this.observer.onDelta, (result: HmAIResponsesResult): void => { this.result = result; },
        (error: HmAIError): void => this.fail(error)));
      this.request = http.createHttp();
      this.request.on('dataReceive', this.onDataReceive);
      this.request.on('dataEnd', this.onDataEnd);
      this.request.requestInStream(this.url, this.requestOptions()).then((status: number): void => {
        if (this.settled) return;
        this.statusCode = status; this.statusReady = true;
        if (status < 200 || status >= 300) {
          this.fail(new HmAIError(HmAIErrorCode.HTTP, `Responses API 返回 HTTP ${status}`, status, this.responseBody));
        } else this.trySucceed();
      }).catch((error: BusinessError): void => this.fail(new HmAIError(HmAIErrorCode.NETWORK,
        error.message || 'Responses 网络请求失败', undefined, undefined, error.code)));
    } catch (error) {
      this.fail(new HmAIError(HmAIErrorCode.INTERNAL, error instanceof Error ? error.message : '无法启动 Responses 请求'));
    }
  }

  private requestOptions(): http.HttpRequestOptions {
    const headers: Record<string, string> = { 'Content-Type': 'application/json', 'Accept': 'text/event-stream' };
    if ((this.options.apiKey ?? '').length > 0) headers['Authorization'] = `Bearer ${this.options.apiKey}`;
    Object.keys(this.options.headers).forEach((key: string): void => { headers[key] = this.options.headers[key]; });
    return { method: http.RequestMethod.POST, header: headers, extraData: this.body,
      connectTimeout: this.options.connectTimeoutMs, readTimeout: this.options.readTimeoutMs, usingCache: false };
  }

  private consume(data: ArrayBuffer): void {
    if (this.settled || this.textDecoder === undefined || this.decoder === undefined) return;
    const text: string = this.textDecoder.decodeToString(new Uint8Array(data), { stream: true });
    if (this.responseBody.length < 8192) this.responseBody += text.substring(0, 8192 - this.responseBody.length);
    this.decoder.push(text);
  }

  private end(): void {
    if (this.settled || this.dataEnded) return;
    try {
      if (this.decoder !== undefined && this.textDecoder !== undefined) {
        this.decoder.push(this.textDecoder.decodeToString(new Uint8Array(0), { stream: false }));
        this.result = this.decoder.finish();
      }
      this.dataEnded = true; this.trySucceed();
    } catch (error) {
      this.fail(new HmAIError(HmAIErrorCode.PROTOCOL, error instanceof Error ? error.message : 'Responses 流结束失败'));
    }
  }

  private trySucceed(): void {
    if (this.settled || !this.statusReady || !this.dataEnded || this.result === undefined) return;
    this.settled = true;
    const result: HmAIResponsesResult = this.result;
    this.cleanup(); this.observer.onComplete(result); this.resolve?.(result);
  }
  private fail(error: HmAIError): void {
    if (this.settled) return;
    this.settled = true; this.cleanup(); this.observer.onError(error); this.reject?.(error);
  }
  private cleanup(): void {
    if (this.request === undefined) return;
    this.request.off('dataReceive', this.onDataReceive); this.request.off('dataEnd', this.onDataEnd);
    this.request.destroy(); this.request = undefined;
  }
}
