import { HmAIError, HmAIErrorCode } from './Errors';
import { HmAIToolCall } from './Message';
import { HmAIToolDefinition, HmAIToolResult } from './Types';

export type HmAIToolHandler = (argumentsJson: string) => Promise<string>;

class HmAIToolRegistration {
  readonly definition: HmAIToolDefinition;
  readonly handler: HmAIToolHandler;

  constructor(definition: HmAIToolDefinition, handler: HmAIToolHandler) {
    this.definition = definition;
    this.handler = handler;
  }
}

export class HmAIToolRegistry {
  private registrations: HmAIToolRegistration[] = [];

  register(definition: HmAIToolDefinition, handler: HmAIToolHandler): HmAIToolRegistry {
    this.validateDefinition(definition);
    if (this.find(definition.name) !== undefined) {
      throw new HmAIError(HmAIErrorCode.INVALID_ARGUMENT, `工具名称重复：${definition.name}`);
    }
    this.registrations.push(new HmAIToolRegistration(definition, handler));
    return this;
  }

  getDefinitions(): HmAIToolDefinition[] {
    return this.registrations.map((registration: HmAIToolRegistration): HmAIToolDefinition => registration.definition);
  }

  async execute(call: HmAIToolCall): Promise<HmAIToolResult> {
    const registration: HmAIToolRegistration | undefined = this.find(call.name);
    if (registration === undefined) {
      throw new HmAIError(HmAIErrorCode.INVALID_ARGUMENT, `未注册模型请求的工具：${call.name}`);
    }
    try {
      JSON.parse(call.argumentsJson.length > 0 ? call.argumentsJson : '{}');
    } catch (_error) {
      throw new HmAIError(HmAIErrorCode.PROTOCOL, `工具 ${call.name} 的参数不是有效 JSON`);
    }
    const content: string = await registration.handler(call.argumentsJson);
    return new HmAIToolResult(call.id, content, call.name);
  }

  async executeAll(calls: HmAIToolCall[]): Promise<HmAIToolResult[]> {
    const results: HmAIToolResult[] = [];
    for (let index: number = 0; index < calls.length; index++) {
      results.push(await this.execute(calls[index]));
    }
    return results;
  }

  private find(name: string): HmAIToolRegistration | undefined {
    return this.registrations.find((registration: HmAIToolRegistration): boolean => registration.definition.name === name);
  }

  private validateDefinition(definition: HmAIToolDefinition): void {
    if (!/^[A-Za-z0-9_-]{1,64}$/.test(definition.name)) {
      throw new HmAIError(HmAIErrorCode.INVALID_ARGUMENT, '工具名称只能包含字母、数字、下划线或连字符，长度 1-64');
    }
    try {
      JSON.parse(definition.parametersJsonSchema);
    } catch (_error) {
      throw new HmAIError(HmAIErrorCode.INVALID_ARGUMENT, `工具 ${definition.name} 的 JSON Schema 无效`);
    }
  }
}
