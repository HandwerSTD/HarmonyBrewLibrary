import { HmAIError, HmAIErrorCode, asHmAIError } from '../core/Errors';
import { HmAIMessage, HmAIMessageRole, HmAIToolCall } from '../core/Message';
import { HmAIToolRegistry } from '../core/Tools';
import { HmAIChatModel, HmAIChatRequest, HmAIChatResult, HmAIResponseFormat, HmAIStreamDelta,
  HmAIStreamObserver, HmAIStreamTask, HmAIToolChoice, HmAIToolDefinition, HmAIToolResult } from '../core/Types';

export enum HmAIConversationState {
  IDLE = 'idle',
  STREAMING = 'streaming',
  ERROR = 'error'
}

export class HmAIConversationOptions {
  model?: string;
  temperature?: number;
  topP?: number;
  maxTokens?: number;
  tools: HmAIToolDefinition[] = [];
  toolChoice?: HmAIToolChoice;
  parallelToolCalls?: boolean;
  responseFormat?: HmAIResponseFormat;
  includeUsage: boolean = false;
  maxToolRounds: number = 4;
}

export class HmAIConversationObserver {
  readonly onMessagesChange: (messages: HmAIMessage[]) => void;
  readonly onStateChange: (state: HmAIConversationState) => void;
  readonly onError: (error: HmAIError) => void;

  constructor(
    onMessagesChange: (messages: HmAIMessage[]) => void = (_messages: HmAIMessage[]): void => {},
    onStateChange: (state: HmAIConversationState) => void = (_state: HmAIConversationState): void => {},
    onError: (error: HmAIError) => void = (_error: HmAIError): void => {}
  ) {
    this.onMessagesChange = onMessagesChange;
    this.onStateChange = onStateChange;
    this.onError = onError;
  }
}

export class HmAIConversationController {
  private readonly model: HmAIChatModel;
  private readonly observer: HmAIConversationObserver;
  private readonly options: HmAIConversationOptions;
  private messages: HmAIMessage[] = [];
  private state: HmAIConversationState = HmAIConversationState.IDLE;
  private activeTask?: HmAIStreamTask;
  private lastError?: HmAIError;

  constructor(model: HmAIChatModel, initialMessages: HmAIMessage[] = [],
    observer: HmAIConversationObserver = new HmAIConversationObserver(),
    options: HmAIConversationOptions = new HmAIConversationOptions()) {
    this.model = model;
    this.observer = observer;
    this.options = options;
    this.messages = initialMessages.map((message: HmAIMessage): HmAIMessage => message.copy());
  }

  getMessages(): HmAIMessage[] {
    return this.messages.map((message: HmAIMessage): HmAIMessage => message.copy());
  }

  getState(): HmAIConversationState {
    return this.state;
  }

  getLastError(): HmAIError | undefined {
    return this.lastError;
  }

  async send(content: string): Promise<HmAIChatResult> {
    const prompt: string = content.trim();
    this.ensureIdle();
    if (prompt.length === 0) throw new HmAIError(HmAIErrorCode.INVALID_ARGUMENT, '消息不能为空');
    this.messages.push(HmAIMessage.user(prompt));
    return this.startAssistantTurn();
  }

  async sendMessage(message: HmAIMessage): Promise<HmAIChatResult> {
    this.ensureIdle();
    if (message.role !== HmAIMessageRole.USER) {
      throw new HmAIError(HmAIErrorCode.INVALID_ARGUMENT, 'sendMessage 只接受 user 消息');
    }
    if (message.content.trim().length === 0 && message.parts.length === 0) {
      throw new HmAIError(HmAIErrorCode.INVALID_ARGUMENT, '消息内容不能为空');
    }
    this.messages.push(message.copy());
    return this.startAssistantTurn();
  }

  async submitToolResults(results: HmAIToolResult[]): Promise<HmAIChatResult> {
    this.ensureIdle();
    const pending: HmAIToolCall[] = this.pendingToolCalls();
    if (pending.length === 0) {
      throw new HmAIError(HmAIErrorCode.INVALID_ARGUMENT, '当前没有等待回传的工具调用');
    }
    if (results.length !== pending.length) {
      throw new HmAIError(HmAIErrorCode.INVALID_ARGUMENT, '必须为每个待处理工具调用提供一个结果');
    }
    for (let index: number = 0; index < pending.length; index++) {
      const call: HmAIToolCall = pending[index];
      const result: HmAIToolResult | undefined = results.find(
        (candidate: HmAIToolResult): boolean => candidate.toolCallId === call.id);
      if (result === undefined) {
        throw new HmAIError(HmAIErrorCode.INVALID_ARGUMENT, `缺少工具调用 ${call.id} 的结果`);
      }
      this.messages.push(HmAIMessage.tool(result.content, result.toolCallId, result.name));
    }
    return this.startAssistantTurn();
  }

  async sendWithTools(content: string, registry: HmAIToolRegistry,
    maxRounds: number = this.options.maxToolRounds): Promise<HmAIChatResult> {
    if (maxRounds < 1 || maxRounds > 16) {
      throw new HmAIError(HmAIErrorCode.INVALID_ARGUMENT, 'maxRounds 必须在 1 到 16 之间');
    }
    this.options.tools = registry.getDefinitions();
    if (this.options.toolChoice === undefined) this.options.toolChoice = HmAIToolChoice.AUTO;
    let result: HmAIChatResult = await this.send(content);
    let round: number = 0;
    while (result.toolCalls.length > 0) {
      if (round >= maxRounds) {
        const error: HmAIError = new HmAIError(HmAIErrorCode.TOOL_ROUND_LIMIT,
          `工具调用超过最大轮次 ${maxRounds}`);
        this.recordError(error);
        throw error;
      }
      round++;
      try {
        const toolResults: HmAIToolResult[] = await registry.executeAll(result.toolCalls);
        result = await this.submitToolResults(toolResults);
      } catch (error) {
        const mapped: HmAIError = error instanceof Error ? asHmAIError(error, '工具执行失败') :
          new HmAIError(HmAIErrorCode.TOOL, '工具执行失败');
        this.recordError(mapped);
        throw mapped;
      }
    }
    return result;
  }

  cancel(): void {
    this.activeTask?.cancel();
  }

  retry(): Promise<HmAIChatResult> {
    this.ensureIdle();
    let lastUserIndex: number = -1;
    for (let index: number = this.messages.length - 1; index >= 0; index--) {
      if (this.messages[index].role === HmAIMessageRole.USER) {
        lastUserIndex = index;
        break;
      }
    }
    if (lastUserIndex < 0) {
      return Promise.reject(new HmAIError(HmAIErrorCode.INVALID_ARGUMENT, '没有可重新生成的用户消息'));
    }
    const content: string = this.messages[lastUserIndex].content;
    this.messages = this.messages.slice(0, lastUserIndex);
    return this.send(content);
  }

  regenerate(): Promise<HmAIChatResult> {
    return this.retry();
  }

  reset(messages: HmAIMessage[] = []): void {
    this.cancel();
    this.messages = messages.map((message: HmAIMessage): HmAIMessage => message.copy());
    this.lastError = undefined;
    this.changeState(HmAIConversationState.IDLE);
    this.notifyMessages();
  }

  dispose(): void {
    this.cancel();
  }

  private async startAssistantTurn(): Promise<HmAIChatResult> {
    const assistantMessage: HmAIMessage = HmAIMessage.assistant();
    this.messages.push(assistantMessage);
    this.lastError = undefined;
    this.changeState(HmAIConversationState.STREAMING);
    this.notifyMessages();

    const requestMessages: HmAIMessage[] = this.messages
      .filter((message: HmAIMessage): boolean => message.id !== assistantMessage.id)
      .map((message: HmAIMessage): HmAIMessage => message.copy());
    const request: HmAIChatRequest = this.createRequest(requestMessages);
    this.activeTask = this.model.createStream(request, new HmAIStreamObserver(
      (delta: HmAIStreamDelta): void => {
        assistantMessage.content += delta.content;
        this.notifyMessages();
      }
    ));

    try {
      const result: HmAIChatResult = await this.activeTask.start();
      assistantMessage.content = result.content;
      assistantMessage.toolCalls = result.toolCalls.map((call: HmAIToolCall): HmAIToolCall => call.copy());
      this.activeTask = undefined;
      this.changeState(HmAIConversationState.IDLE);
      this.notifyMessages();
      return result;
    } catch (error) {
      const mapped: HmAIError = error instanceof Error ? asHmAIError(error) :
        new HmAIError(HmAIErrorCode.INTERNAL, '模型请求失败');
      this.activeTask = undefined;
      if (mapped.code === HmAIErrorCode.CANCELLED) {
        this.changeState(HmAIConversationState.IDLE);
      } else {
        this.recordError(mapped);
      }
      this.notifyMessages();
      throw mapped;
    }
  }

  private createRequest(messages: HmAIMessage[]): HmAIChatRequest {
    const request: HmAIChatRequest = new HmAIChatRequest(messages);
    request.model = this.options.model;
    request.temperature = this.options.temperature;
    request.topP = this.options.topP;
    request.maxTokens = this.options.maxTokens;
    request.tools = this.options.tools;
    request.toolChoice = this.options.toolChoice;
    request.parallelToolCalls = this.options.parallelToolCalls;
    request.responseFormat = this.options.responseFormat;
    request.includeUsage = this.options.includeUsage;
    return request;
  }

  private pendingToolCalls(): HmAIToolCall[] {
    for (let index: number = this.messages.length - 1; index >= 0; index--) {
      const message: HmAIMessage = this.messages[index];
      if (message.role === HmAIMessageRole.ASSISTANT && message.toolCalls.length > 0) {
        return message.toolCalls.map((call: HmAIToolCall): HmAIToolCall => call.copy());
      }
      if (message.role === HmAIMessageRole.USER) break;
    }
    return [];
  }

  private ensureIdle(): void {
    if (this.state === HmAIConversationState.STREAMING) {
      throw new HmAIError(HmAIErrorCode.INVALID_ARGUMENT, '当前已有消息正在生成');
    }
  }

  private recordError(error: HmAIError): void {
    this.lastError = error;
    this.changeState(HmAIConversationState.ERROR);
    this.observer.onError(error);
  }

  private changeState(state: HmAIConversationState): void {
    this.state = state;
    this.observer.onStateChange(state);
  }

  private notifyMessages(): void {
    this.observer.onMessagesChange(this.getMessages());
  }
}
