import { OpenAICompatibleClient, OpenAICompatibleClientOptions } from '../client/OpenAICompatibleClient';
import { HmAIError, HmAIErrorCode } from '../core/Errors';
import { OpenAIResponsesClient, OpenAIResponsesClientOptions } from '../responses/OpenAIResponsesClient';

export enum HmAIProviderId {
  OPENAI = 'openai',
  DEEPSEEK = 'deepseek',
  QWEN = 'qwen',
  DOUBAO = 'doubao',
  ZHIPU = 'zhipu',
  CUSTOM = 'custom'
}

export class HmAIProviderCapabilities {
  chatCompletions: boolean = true;
  responses: boolean = false;
  imageInput: boolean = false;
  fileInput: boolean = false;
  audioInput: boolean = false;
  tools: boolean = true;
  structuredOutput: boolean = true;
  realtime: boolean = false;
}

export class HmAIProviderConfig {
  readonly id: HmAIProviderId;
  readonly displayName: string;
  readonly baseURL: string;
  readonly model: string;
  readonly chatCompletionsPath: string;
  readonly responsesPath: string;
  readonly capabilities: HmAIProviderCapabilities;
  headers: Record<string, string> = {};

  constructor(id: HmAIProviderId, displayName: string, baseURL: string, model: string,
    capabilities: HmAIProviderCapabilities, chatCompletionsPath: string = '/chat/completions',
    responsesPath: string = '/responses') {
    this.id = id;
    this.displayName = displayName;
    this.baseURL = baseURL;
    this.model = model;
    this.capabilities = capabilities;
    this.chatCompletionsPath = chatCompletionsPath;
    this.responsesPath = responsesPath;
  }

  createChatClient(apiKey?: string): OpenAICompatibleClient {
    const options: OpenAICompatibleClientOptions = new OpenAICompatibleClientOptions(this.baseURL, this.model);
    options.apiKey = apiKey;
    options.chatCompletionsPath = this.chatCompletionsPath;
    options.headers = this.headers;
    return new OpenAICompatibleClient(options);
  }

  createResponsesClient(apiKey?: string): OpenAIResponsesClient {
    if (!this.capabilities.responses) {
      throw new HmAIError(HmAIErrorCode.INVALID_ARGUMENT,
        `${this.displayName} Provider 未声明 Responses API 支持`);
    }
    const options: OpenAIResponsesClientOptions = new OpenAIResponsesClientOptions(this.baseURL, this.model);
    options.apiKey = apiKey;
    options.responsesPath = this.responsesPath;
    options.headers = this.headers;
    return new OpenAIResponsesClient(options);
  }
}

export class HmAIProviders {
  static openAI(model: string): HmAIProviderConfig {
    const capabilities: HmAIProviderCapabilities = new HmAIProviderCapabilities();
    capabilities.responses = true;
    capabilities.imageInput = true;
    capabilities.fileInput = true;
    capabilities.audioInput = true;
    capabilities.realtime = true;
    return new HmAIProviderConfig(HmAIProviderId.OPENAI, 'OpenAI', 'https://api.openai.com/v1', model, capabilities);
  }

  static deepSeek(model: string): HmAIProviderConfig {
    return new HmAIProviderConfig(HmAIProviderId.DEEPSEEK, 'DeepSeek', 'https://api.deepseek.com', model,
      new HmAIProviderCapabilities());
  }

  static qwen(model: string): HmAIProviderConfig {
    const capabilities: HmAIProviderCapabilities = new HmAIProviderCapabilities();
    capabilities.imageInput = true;
    capabilities.audioInput = true;
    return new HmAIProviderConfig(HmAIProviderId.QWEN, '通义千问',
      'https://dashscope.aliyuncs.com/compatible-mode/v1', model, capabilities);
  }

  static doubao(modelOrEndpointId: string): HmAIProviderConfig {
    const capabilities: HmAIProviderCapabilities = new HmAIProviderCapabilities();
    capabilities.responses = true;
    capabilities.imageInput = true;
    capabilities.fileInput = true;
    capabilities.audioInput = true;
    return new HmAIProviderConfig(HmAIProviderId.DOUBAO, '豆包',
      'https://ark.cn-beijing.volces.com/api/v3', modelOrEndpointId, capabilities);
  }

  static zhipu(model: string): HmAIProviderConfig {
    const capabilities: HmAIProviderCapabilities = new HmAIProviderCapabilities();
    capabilities.imageInput = true;
    return new HmAIProviderConfig(HmAIProviderId.ZHIPU, '智谱',
      'https://open.bigmodel.cn/api/paas/v4', model, capabilities);
  }

  static custom(baseURL: string, model: string,
    capabilities: HmAIProviderCapabilities = new HmAIProviderCapabilities()): HmAIProviderConfig {
    return new HmAIProviderConfig(HmAIProviderId.CUSTOM, 'Custom', baseURL, model, capabilities);
  }
}
