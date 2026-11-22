import { HmAIError, HmAIErrorCode } from '../core/Errors';
import { HmAIToolCall } from '../core/Message';
import { HmAIChatResult, HmAIStreamDelta, HmAIStreamObserver, HmAIUsage } from '../core/Types';
import { HmAISSEDecoder } from './SSEDecoder';

class OpenAIFunctionCallDelta {
  name?: string;
  arguments?: string;
}

class OpenAIToolCallDelta {
  index?: number;
  id?: string;
  type?: string;
  function?: OpenAIFunctionCallDelta;
}

class OpenAIDeltaPayload {
  content?: string;
  tool_calls?: OpenAIToolCallDelta[];
}

class OpenAIStreamChoice {
  delta?: OpenAIDeltaPayload;
  finish_reason?: string;
}

class OpenAIStreamUsage {
  prompt_tokens?: number;
  completion_tokens?: number;
  total_tokens?: number;
}

class OpenAIStreamChunk {
  model?: string;
  choices?: OpenAIStreamChoice[];
  usage?: OpenAIStreamUsage;
}

export class OpenAICompatibleStreamDecoder {
  private readonly sse: HmAISSEDecoder;
  private readonly observer: HmAIStreamObserver;
  private content: string = '';
  private model: string = '';
  private finishReason: string = '';
  private usage?: HmAIUsage;
  private toolCalls: HmAIToolCall[] = [];
  private completed: boolean = false;
  private failed: boolean = false;

  constructor(observer: HmAIStreamObserver) {
    this.observer = observer;
    this.sse = new HmAISSEDecoder((data: string): void => this.consumeEvent(data));
  }

  push(text: string): void {
    if (this.completed || this.failed) return;
    this.sse.push(text);
  }

  finish(): HmAIChatResult | undefined {
    if (this.failed) return undefined;
    if (!this.completed) {
      this.sse.finish();
      if (!this.completed && !this.failed) this.complete();
    }
    if (this.failed) return undefined;
    return this.result();
  }

  private consumeEvent(data: string): void {
    if (data.trim() === '[DONE]') {
      this.complete();
      return;
    }
    try {
      const chunk: OpenAIStreamChunk = JSON.parse(data) as OpenAIStreamChunk;
      if (chunk.model !== undefined) this.model = chunk.model;
      if (chunk.usage !== undefined) this.consumeUsage(chunk.usage);
      if (chunk.choices === undefined) return;
      for (let index: number = 0; index < chunk.choices.length; index++) {
        const choice: OpenAIStreamChoice = chunk.choices[index];
        this.consumeDelta(choice.delta);
        if (choice.finish_reason !== undefined && choice.finish_reason !== null) {
          this.finishReason = choice.finish_reason;
        }
      }
    } catch (error) {
      this.failed = true;
      const detail: string = error instanceof Error ? error.message : '未知解析错误';
      this.observer.onError(new HmAIError(HmAIErrorCode.PROTOCOL, `无法解析模型流式响应：${detail}`));
    }
  }

  private consumeUsage(source: OpenAIStreamUsage): void {
    const usage: HmAIUsage = new HmAIUsage();
    usage.promptTokens = source.prompt_tokens ?? 0;
    usage.completionTokens = source.completion_tokens ?? 0;
    usage.totalTokens = source.total_tokens ?? 0;
    this.usage = usage;
  }

  private consumeDelta(delta: OpenAIDeltaPayload | undefined): void {
    if (delta === undefined) return;
    let contentDelta: string = '';
    if (delta.content !== undefined && delta.content !== null && delta.content.length > 0) {
      contentDelta = delta.content;
      this.content += contentDelta;
    }
    const toolDeltas: HmAIToolCall[] = [];
    if (delta.tool_calls !== undefined) {
      for (let index: number = 0; index < delta.tool_calls.length; index++) {
        toolDeltas.push(this.consumeToolDelta(delta.tool_calls[index], index));
      }
    }
    if (contentDelta.length > 0 || toolDeltas.length > 0) {
      this.observer.onDelta(new HmAIStreamDelta(contentDelta, toolDeltas));
    }
  }

  private consumeToolDelta(delta: OpenAIToolCallDelta, fallbackIndex: number): HmAIToolCall {
    const callIndex: number = delta.index ?? fallbackIndex;
    let call: HmAIToolCall | undefined = this.toolCalls.find(
      (candidate: HmAIToolCall): boolean => candidate.index === callIndex);
    if (call === undefined) {
      call = new HmAIToolCall('', '', '', callIndex);
      this.toolCalls.push(call);
      this.toolCalls.sort((left: HmAIToolCall, right: HmAIToolCall): number => left.index - right.index);
    }
    const idFragment: string = delta.id ?? '';
    const nameFragment: string = delta.function?.name ?? '';
    const argumentsFragment: string = delta.function?.arguments ?? '';
    call.id += idFragment;
    call.name += nameFragment;
    call.argumentsJson += argumentsFragment;
    return new HmAIToolCall(idFragment, nameFragment, argumentsFragment, callIndex);
  }

  private result(): HmAIChatResult {
    return new HmAIChatResult(this.content, this.model, this.finishReason, this.usage, this.toolCalls);
  }

  private complete(): void {
    if (this.completed || this.failed) return;
    this.completed = true;
    this.observer.onComplete(this.result());
  }
}
