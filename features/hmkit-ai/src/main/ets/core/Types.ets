import { HmAIError } from './Errors';
import { HmAIMessage, HmAIToolCall } from './Message';

export enum HmAIToolChoice {
  NONE = 'none',
  AUTO = 'auto',
  REQUIRED = 'required'
}

export enum HmAIResponseFormatType {
  TEXT = 'text',
  JSON_OBJECT = 'json_object',
  JSON_SCHEMA = 'json_schema'
}

export class HmAIToolDefinition {
  readonly name: string;
  readonly description: string;
  readonly parametersJsonSchema: string;
  readonly strict: boolean;

  constructor(name: string, description: string, parametersJsonSchema: string, strict: boolean = false) {
    this.name = name;
    this.description = description;
    this.parametersJsonSchema = parametersJsonSchema;
    this.strict = strict;
  }
}

export class HmAIResponseFormat {
  readonly type: HmAIResponseFormatType;
  readonly name: string;
  readonly description: string;
  readonly jsonSchema: string;
  readonly strict: boolean;

  private constructor(type: HmAIResponseFormatType, name: string = '', description: string = '',
    jsonSchema: string = '', strict: boolean = true) {
    this.type = type;
    this.name = name;
    this.description = description;
    this.jsonSchema = jsonSchema;
    this.strict = strict;
  }

  static text(): HmAIResponseFormat {
    return new HmAIResponseFormat(HmAIResponseFormatType.TEXT);
  }

  static jsonObject(): HmAIResponseFormat {
    return new HmAIResponseFormat(HmAIResponseFormatType.JSON_OBJECT);
  }

  static jsonSchema(name: string, schema: string, description: string = '', strict: boolean = true): HmAIResponseFormat {
    return new HmAIResponseFormat(HmAIResponseFormatType.JSON_SCHEMA, name, description, schema, strict);
  }
}

export class HmAIToolResult {
  readonly toolCallId: string;
  readonly content: string;
  readonly name?: string;

  constructor(toolCallId: string, content: string, name?: string) {
    this.toolCallId = toolCallId;
    this.content = content;
    this.name = name;
  }
}

export class HmAIUsage {
  promptTokens: number = 0;
  completionTokens: number = 0;
  totalTokens: number = 0;
}

export class HmAIStreamDelta {
  readonly content: string;
  readonly toolCalls: HmAIToolCall[];

  constructor(content: string = '', toolCalls: HmAIToolCall[] = []) {
    this.content = content;
    this.toolCalls = toolCalls.map((call: HmAIToolCall): HmAIToolCall => call.copy());
  }
}

export class HmAIChatResult {
  readonly content: string;
  readonly model: string;
  readonly finishReason: string;
  readonly usage?: HmAIUsage;
  readonly toolCalls: HmAIToolCall[];

  constructor(content: string, model: string = '', finishReason: string = '', usage?: HmAIUsage,
    toolCalls: HmAIToolCall[] = []) {
    this.content = content;
    this.model = model;
    this.finishReason = finishReason;
    this.usage = usage;
    this.toolCalls = toolCalls.map((call: HmAIToolCall): HmAIToolCall => call.copy());
  }
}

export class HmAIChatRequest {
  readonly messages: HmAIMessage[];
  model?: string;
  temperature?: number;
  topP?: number;
  maxTokens?: number;
  tools: HmAIToolDefinition[] = [];
  toolChoice?: HmAIToolChoice;
  parallelToolCalls?: boolean;
  responseFormat?: HmAIResponseFormat;
  includeUsage: boolean = false;

  constructor(messages: HmAIMessage[]) {
    this.messages = messages.map((message: HmAIMessage): HmAIMessage => message.copy());
  }
}

export class HmAIStreamObserver {
  readonly onDelta: (delta: HmAIStreamDelta) => void;
  readonly onComplete: (result: HmAIChatResult) => void;
  readonly onError: (error: HmAIError) => void;

  constructor(
    onDelta: (delta: HmAIStreamDelta) => void = (_delta: HmAIStreamDelta): void => {},
    onComplete: (result: HmAIChatResult) => void = (_result: HmAIChatResult): void => {},
    onError: (error: HmAIError) => void = (_error: HmAIError): void => {}
  ) {
    this.onDelta = onDelta;
    this.onComplete = onComplete;
    this.onError = onError;
  }
}

export interface HmAIStreamTask {
  start(): Promise<HmAIChatResult>;
  cancel(): void;
  isCancelled(): boolean;
}

export interface HmAIChatModel {
  createStream(request: HmAIChatRequest, observer?: HmAIStreamObserver): HmAIStreamTask;
}
