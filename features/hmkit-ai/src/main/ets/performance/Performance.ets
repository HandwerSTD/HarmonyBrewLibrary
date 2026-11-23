import { HmAIMessage, HmAIMessageRole } from '../core/Message';

export class HmAIContextWindowOptions {
  maxEstimatedTokens: number = 16000;
  reserveOutputTokens: number = 2000;
  keepRecentMessages: number = 8;
  summary: string = '';
}

export class HmAIContextWindow {
  static estimateTokens(text: string): number {
    let units: number = 0;
    for (let index: number = 0; index < text.length; index++) units += text.charCodeAt(index) > 127 ? 4 : 1;
    return Math.max(1, Math.ceil(units / 4));
  }

  static trim(messages: HmAIMessage[], options: HmAIContextWindowOptions = new HmAIContextWindowOptions()): HmAIMessage[] {
    const budget: number = Math.max(1, options.maxEstimatedTokens - options.reserveOutputTokens);
    const instructions: HmAIMessage[] = messages.filter((message: HmAIMessage): boolean =>
      message.role === HmAIMessageRole.SYSTEM || message.role === HmAIMessageRole.DEVELOPER);
    const conversation: HmAIMessage[] = messages.filter((message: HmAIMessage): boolean =>
      message.role !== HmAIMessageRole.SYSTEM && message.role !== HmAIMessageRole.DEVELOPER);
    const selected: HmAIMessage[] = [];
    let tokens: number = instructions.reduce((sum: number, message: HmAIMessage): number =>
      sum + HmAIContextWindow.estimateTokens(message.content), 0);
    for (let index: number = conversation.length - 1; index >= 0; index--) {
      const messageTokens: number = HmAIContextWindow.estimateTokens(conversation[index].content);
      const mustKeep: boolean = conversation.length - index <= options.keepRecentMessages;
      if (!mustKeep && tokens + messageTokens > budget) break;
      selected.unshift(conversation[index].copy()); tokens += messageTokens;
    }
    const omitted: boolean = selected.length < conversation.length;
    const output: HmAIMessage[] = instructions.map((message: HmAIMessage): HmAIMessage => message.copy());
    if (omitted && options.summary.length > 0) output.push(HmAIMessage.system(`历史摘要：${options.summary}`));
    output.push(...selected); return output;
  }
}

export class HmAIStreamBatcher {
  private readonly onFlush: (content: string) => void;
  private readonly intervalMs: number;
  private readonly maxCharacters: number;
  private buffer: string = '';
  private timer: number = -1;

  constructor(onFlush: (content: string) => void, intervalMs: number = 32, maxCharacters: number = 256) {
    this.onFlush = onFlush; this.intervalMs = Math.max(0, intervalMs); this.maxCharacters = Math.max(1, maxCharacters);
  }
  push(content: string): void {
    this.buffer += content;
    if (this.buffer.length >= this.maxCharacters || this.intervalMs === 0) this.flush();
    else if (this.timer < 0) this.timer = setTimeout((): void => this.flush(), this.intervalMs);
  }
  flush(): void {
    if (this.timer >= 0) { clearTimeout(this.timer); this.timer = -1; }
    if (this.buffer.length === 0) return;
    const content: string = this.buffer; this.buffer = ''; this.onFlush(content);
  }
  cancel(): void { if (this.timer >= 0) clearTimeout(this.timer); this.timer = -1; this.buffer = ''; }
}
