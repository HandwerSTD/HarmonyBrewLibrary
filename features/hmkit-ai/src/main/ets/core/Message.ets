import { HmAIContentPart } from './Content';

let nextMessageId: number = 0;

function createMessageId(): string {
  nextMessageId++;
  return `hm_ai_${Date.now()}_${nextMessageId}`;
}

export enum HmAIMessageRole {
  DEVELOPER = 'developer',
  SYSTEM = 'system',
  USER = 'user',
  ASSISTANT = 'assistant',
  TOOL = 'tool'
}

export class HmAIToolCall {
  index: number;
  id: string;
  name: string;
  argumentsJson: string;

  constructor(id: string = '', name: string = '', argumentsJson: string = '', index: number = 0) {
    this.index = index;
    this.id = id;
    this.name = name;
    this.argumentsJson = argumentsJson;
  }

  copy(): HmAIToolCall {
    return new HmAIToolCall(this.id, this.name, this.argumentsJson, this.index);
  }
}

export class HmAIMessage {
  id: string;
  role: HmAIMessageRole;
  content: string;
  name?: string;
  toolCallId?: string;
  toolCalls: HmAIToolCall[] = [];
  parts: HmAIContentPart[] = [];

  constructor(role: HmAIMessageRole, content: string, id: string = createMessageId(), name?: string) {
    this.id = id;
    this.role = role;
    this.content = content;
    this.name = name;
    if (content.length > 0) this.parts = [HmAIContentPart.text(content)];
  }

  static developer(content: string): HmAIMessage {
    return new HmAIMessage(HmAIMessageRole.DEVELOPER, content);
  }

  static system(content: string): HmAIMessage {
    return new HmAIMessage(HmAIMessageRole.SYSTEM, content);
  }

  static user(content: string): HmAIMessage {
    return new HmAIMessage(HmAIMessageRole.USER, content);
  }

  static userParts(parts: HmAIContentPart[]): HmAIMessage {
    const content: string = parts.filter((part: HmAIContentPart): boolean => part.text.length > 0)
      .map((part: HmAIContentPart): string => part.text).join('\n');
    const message: HmAIMessage = new HmAIMessage(HmAIMessageRole.USER, content);
    message.parts = parts.map((part: HmAIContentPart): HmAIContentPart => part.copy());
    return message;
  }

  static assistant(content: string = '', toolCalls: HmAIToolCall[] = []): HmAIMessage {
    const message: HmAIMessage = new HmAIMessage(HmAIMessageRole.ASSISTANT, content);
    message.toolCalls = toolCalls.map((call: HmAIToolCall): HmAIToolCall => call.copy());
    return message;
  }

  static tool(content: string, toolCallId: string, name?: string): HmAIMessage {
    const message: HmAIMessage = new HmAIMessage(HmAIMessageRole.TOOL, content, createMessageId(), name);
    message.toolCallId = toolCallId;
    return message;
  }

  copy(): HmAIMessage {
    const message: HmAIMessage = new HmAIMessage(this.role, this.content, this.id, this.name);
    message.toolCallId = this.toolCallId;
    message.toolCalls = this.toolCalls.map((call: HmAIToolCall): HmAIToolCall => call.copy());
    message.parts = this.parts.map((part: HmAIContentPart): HmAIContentPart => part.copy());
    return message;
  }
}
