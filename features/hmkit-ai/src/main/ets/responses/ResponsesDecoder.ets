import { HmAIError, HmAIErrorCode } from '../core/Errors';
import { HmAIToolCall } from '../core/Message';
import { HmAIStreamDelta, HmAIUsage } from '../core/Types';
import { HmAISSEDecoder } from '../protocol/SSEDecoder';
import { HmAICitation, HmAIResponsesObserver, HmAIResponsesResult } from './ResponsesTypes';

class ResponsesUsageWire {
  input_tokens?: number;
  output_tokens?: number;
  total_tokens?: number;
}

class ResponsesAnnotationWire {
  type?: string;
  title?: string;
  url?: string;
  file_id?: string;
  start_index?: number;
  end_index?: number;
}

class ResponsesContentWire {
  type?: string;
  text?: string;
  annotations?: ResponsesAnnotationWire[];
}

class ResponsesOutputItemWire {
  id?: string;
  type?: string;
  name?: string;
  arguments?: string;
  call_id?: string;
  content?: ResponsesContentWire[];
}

class ResponsesCompletedWire {
  id?: string;
  model?: string;
  status?: string;
  output?: ResponsesOutputItemWire[];
  usage?: ResponsesUsageWire;
}

class ResponsesErrorWire {
  code?: string;
  message?: string;
}

class ResponsesEventWire {
  type?: string;
  delta?: string;
  output_index?: number;
  item_id?: string;
  item?: ResponsesOutputItemWire;
  response?: ResponsesCompletedWire;
  error?: ResponsesErrorWire;
}

class PendingResponseCall {
  readonly itemId: string;
  readonly index: number;
  callId: string;
  name: string;
  argumentsJson: string;

  constructor(itemId: string, index: number, callId: string = '', name: string = '', argumentsJson: string = '') {
    this.itemId = itemId;
    this.index = index;
    this.callId = callId;
    this.name = name;
    this.argumentsJson = argumentsJson;
  }
}

export class OpenAIResponsesStreamDecoder {
  private readonly sse: HmAISSEDecoder;
  private readonly observer: HmAIResponsesObserver;
  private text: string = '';
  private responseId: string = '';
  private model: string = '';
  private status: string = 'in_progress';
  private usage?: HmAIUsage;
  private calls: PendingResponseCall[] = [];
  private citations: HmAICitation[] = [];
  private completed: boolean = false;
  private failed: boolean = false;

  constructor(observer: HmAIResponsesObserver = new HmAIResponsesObserver()) {
    this.observer = observer;
    this.sse = new HmAISSEDecoder((data: string): void => this.consume(data));
  }

  push(text: string): void {
    if (!this.completed && !this.failed) this.sse.push(text);
  }

  finish(): HmAIResponsesResult | undefined {
    if (this.failed) return undefined;
    this.sse.finish();
    if (!this.completed && !this.failed) this.complete();
    return this.failed ? undefined : this.result();
  }

  private consume(data: string): void {
    if (data.trim() === '[DONE]') return;
    try {
      const event: ResponsesEventWire = JSON.parse(data) as ResponsesEventWire;
      const type: string = event.type ?? '';
      // 同款 JSON null 陷阱预防（OpenAIStreamDecoder usage=null 崩溃的姊妹路径）：
      // `!== undefined` 拦不住 JSON null，event.item / event.response 判空同加 null。
      if (type === 'response.output_text.delta') this.consumeText(event.delta ?? '');
      else if (type === 'response.output_item.added' && event.item !== undefined &&
        event.item !== null) {
        this.consumeAddedItem(event.item, event.output_index ?? 0);
      } else if (type === 'response.function_call_arguments.delta') {
        this.consumeArguments(event.item_id ?? '', event.delta ?? '', event.output_index ?? 0);
      } else if (type === 'response.output_item.done' && event.item !== undefined &&
        event.item !== null) {
        this.consumeDoneItem(event.item, event.output_index ?? 0);
      } else if (type === 'response.completed' && event.response !== undefined &&
        event.response !== null) {
        this.consumeCompleted(event.response);
        this.complete();
      } else if (type === 'response.failed' || type === 'error') {
        this.failed = true;
        const error: HmAIError = new HmAIError(HmAIErrorCode.PROTOCOL,
          event.error?.message ?? 'Responses API 返回失败事件');
        this.observer.onError(error);
      }
    } catch (error) {
      this.failed = true;
      const detail: string = error instanceof Error ? error.message : '未知解析错误';
      this.observer.onError(new HmAIError(HmAIErrorCode.PROTOCOL, `无法解析 Responses 流：${detail}`));
    }
  }

  private consumeText(delta: string): void {
    if (delta.length === 0) return;
    this.text += delta;
    this.observer.onDelta(new HmAIStreamDelta(delta));
  }

  private consumeAddedItem(item: ResponsesOutputItemWire, index: number): void {
    if (item.type !== 'function_call') return;
    this.upsertCall(item.id ?? '', index, item.call_id ?? item.id ?? '', item.name ?? '', item.arguments ?? '');
  }

  private consumeArguments(itemId: string, delta: string, index: number): void {
    const call: PendingResponseCall = this.upsertCall(itemId, index);
    call.argumentsJson += delta;
    this.observer.onDelta(new HmAIStreamDelta('', [new HmAIToolCall('', '', delta, index)]));
  }

  private consumeDoneItem(item: ResponsesOutputItemWire, index: number): void {
    if (item.type === 'function_call') {
      const call: PendingResponseCall = this.upsertCall(item.id ?? '', index);
      call.callId = item.call_id ?? call.callId;
      call.name = item.name ?? call.name;
      if ((item.arguments ?? '').length > 0) call.argumentsJson = item.arguments ?? '';
    }
    this.consumeCitations(item.content ?? []);
  }

  private consumeCompleted(response: ResponsesCompletedWire): void {
    this.responseId = response.id ?? this.responseId;
    this.model = response.model ?? this.model;
    this.status = response.status ?? 'completed';
    if (response.usage !== undefined && response.usage !== null) {
      const usage: HmAIUsage = new HmAIUsage();
      usage.promptTokens = response.usage.input_tokens ?? 0;
      usage.completionTokens = response.usage.output_tokens ?? 0;
      usage.totalTokens = response.usage.total_tokens ?? 0;
      this.usage = usage;
    }
    const output: ResponsesOutputItemWire[] = response.output ?? [];
    for (let index: number = 0; index < output.length; index++) this.consumeDoneItem(output[index], index);
  }

  private consumeCitations(content: ResponsesContentWire[]): void {
    for (let contentIndex: number = 0; contentIndex < content.length; contentIndex++) {
      const annotations: ResponsesAnnotationWire[] = content[contentIndex].annotations ?? [];
      for (let index: number = 0; index < annotations.length; index++) {
        const source: ResponsesAnnotationWire = annotations[index];
        this.citations.push(new HmAICitation(source.type ?? 'citation', source.title ?? '', source.url ?? '',
          source.file_id ?? '', source.start_index ?? 0, source.end_index ?? 0));
      }
    }
  }

  private upsertCall(itemId: string, index: number, callId: string = '', name: string = '',
    argumentsJson: string = ''): PendingResponseCall {
    let call: PendingResponseCall | undefined = this.calls.find(
      (candidate: PendingResponseCall): boolean => candidate.itemId === itemId && itemId.length > 0);
    if (call === undefined) {
      call = new PendingResponseCall(itemId, index, callId, name, argumentsJson);
      this.calls.push(call);
    }
    return call;
  }

  private result(): HmAIResponsesResult {
    const calls: HmAIToolCall[] = this.calls.map((call: PendingResponseCall): HmAIToolCall =>
      new HmAIToolCall(call.callId, call.name, call.argumentsJson, call.index));
    return new HmAIResponsesResult(this.responseId, this.text, this.model, this.status, this.usage, calls, this.citations);
  }

  private complete(): void {
    if (this.completed || this.failed) return;
    this.completed = true;
    this.observer.onComplete(this.result());
  }
}
