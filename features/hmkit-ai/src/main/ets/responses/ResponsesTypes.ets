import { HmAIMessage, HmAIToolCall } from '../core/Message';
import { HmAIError } from '../core/Errors';
import { HmAIResponseFormat, HmAIStreamDelta, HmAIToolChoice, HmAIToolDefinition, HmAIUsage } from '../core/Types';

export class HmAICitation {
  readonly type: string;
  readonly title: string;
  readonly url: string;
  readonly fileId: string;
  readonly startIndex: number;
  readonly endIndex: number;

  constructor(type: string, title: string = '', url: string = '', fileId: string = '',
    startIndex: number = 0, endIndex: number = 0) {
    this.type = type;
    this.title = title;
    this.url = url;
    this.fileId = fileId;
    this.startIndex = startIndex;
    this.endIndex = endIndex;
  }
}

export class HmAIResponsesRequest {
  readonly input: HmAIMessage[];
  model?: string;
  instructions: string = '';
  previousResponseId: string = '';
  store?: boolean;
  temperature?: number;
  topP?: number;
  maxOutputTokens?: number;
  tools: HmAIToolDefinition[] = [];
  toolChoice?: HmAIToolChoice;
  parallelToolCalls?: boolean;
  responseFormat?: HmAIResponseFormat;
  truncation: string = 'disabled';

  constructor(input: HmAIMessage[]) {
    this.input = input.map((message: HmAIMessage): HmAIMessage => message.copy());
  }
}

export class HmAIResponsesResult {
  readonly id: string;
  readonly text: string;
  readonly model: string;
  readonly status: string;
  readonly usage?: HmAIUsage;
  readonly toolCalls: HmAIToolCall[];
  readonly citations: HmAICitation[];

  constructor(id: string, text: string, model: string, status: string, usage?: HmAIUsage,
    toolCalls: HmAIToolCall[] = [], citations: HmAICitation[] = []) {
    this.id = id;
    this.text = text;
    this.model = model;
    this.status = status;
    this.usage = usage;
    this.toolCalls = toolCalls.map((call: HmAIToolCall): HmAIToolCall => call.copy());
    this.citations = citations;
  }
}

export class HmAIResponsesObserver {
  readonly onDelta: (delta: HmAIStreamDelta) => void;
  readonly onComplete: (result: HmAIResponsesResult) => void;
  readonly onError: (error: HmAIError) => void;

  constructor(onDelta: (delta: HmAIStreamDelta) => void = (_delta: HmAIStreamDelta): void => {},
    onComplete: (result: HmAIResponsesResult) => void = (_result: HmAIResponsesResult): void => {},
    onError: (error: HmAIError) => void = (_error: HmAIError): void => {}) {
    this.onDelta = onDelta;
    this.onComplete = onComplete;
    this.onError = onError;
  }
}

export interface HmAIResponsesTask {
  start(): Promise<HmAIResponsesResult>;
  cancel(): void;
  isCancelled(): boolean;
}
