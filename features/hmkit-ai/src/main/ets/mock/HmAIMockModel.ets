import { HmAIError, HmAIErrorCode } from '../core/Errors';
import { HmAIChatModel, HmAIChatRequest, HmAIChatResult, HmAIStreamDelta,
  HmAIStreamObserver, HmAIStreamTask } from '../core/Types';

export class HmAIMockOptions {
  response: string = '# 本地 Mock 回复\n\n这是不联网的流式演示。\n\n```ets\nconst ready: boolean = true;\n```';
  model: string = 'hmkit-mock';
  chunkSize: number = 6;
  delayMs: number = 20;
}

export class HmAIMockModel implements HmAIChatModel {
  private readonly options: HmAIMockOptions;

  constructor(options: HmAIMockOptions = new HmAIMockOptions()) {
    if (options.chunkSize < 1) throw new HmAIError(HmAIErrorCode.INVALID_ARGUMENT, 'mock chunkSize 必须大于 0');
    if (options.delayMs < 0) throw new HmAIError(HmAIErrorCode.INVALID_ARGUMENT, 'mock delayMs 不能小于 0');
    this.options = options;
  }

  createStream(_request: HmAIChatRequest, observer: HmAIStreamObserver = new HmAIStreamObserver()): HmAIStreamTask {
    return new HmAIMockStreamTask(this.options, observer);
  }
}

class HmAIMockStreamTask implements HmAIStreamTask {
  private readonly options: HmAIMockOptions;
  private readonly observer: HmAIStreamObserver;
  private started: boolean = false;
  private cancelled: boolean = false;

  constructor(options: HmAIMockOptions, observer: HmAIStreamObserver) {
    this.options = options;
    this.observer = observer;
  }

  async start(): Promise<HmAIChatResult> {
    if (this.started) throw new HmAIError(HmAIErrorCode.INVALID_ARGUMENT, '同一个 mock 任务只能启动一次');
    this.started = true;
    for (let offset: number = 0; offset < this.options.response.length; offset += this.options.chunkSize) {
      if (this.cancelled) {
        const error: HmAIError = new HmAIError(HmAIErrorCode.CANCELLED, 'Mock 请求已取消');
        this.observer.onError(error);
        throw error;
      }
      if (this.options.delayMs > 0) await this.wait(this.options.delayMs);
      if (this.cancelled) {
        const error: HmAIError = new HmAIError(HmAIErrorCode.CANCELLED, 'Mock 请求已取消');
        this.observer.onError(error);
        throw error;
      }
      const delta: string = this.options.response.substring(offset, offset + this.options.chunkSize);
      this.observer.onDelta(new HmAIStreamDelta(delta));
    }
    const result: HmAIChatResult = new HmAIChatResult(this.options.response, this.options.model, 'stop');
    this.observer.onComplete(result);
    return result;
  }

  cancel(): void {
    this.cancelled = true;
  }

  isCancelled(): boolean {
    return this.cancelled;
  }

  private wait(delayMs: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, delayMs);
    });
  }
}
