export enum HmAIErrorCode {
  INVALID_ARGUMENT = 'invalid_argument',
  NETWORK = 'network',
  TIMEOUT = 'timeout',
  HTTP = 'http',
  PROTOCOL = 'protocol',
  TOOL = 'tool',
  TOOL_ROUND_LIMIT = 'tool_round_limit',
  CANCELLED = 'cancelled',
  INTERNAL = 'internal'
}

export class HmAIError extends Error {
  readonly code: HmAIErrorCode;
  readonly statusCode?: number;
  readonly responseBody?: string;
  readonly causeCode?: number;

  constructor(code: HmAIErrorCode, message: string, statusCode?: number, responseBody?: string, causeCode?: number) {
    super(message);
    this.name = 'HmAIError';
    this.code = code;
    this.statusCode = statusCode;
    this.responseBody = responseBody;
    this.causeCode = causeCode;
  }
}

export function asHmAIError(error: Error, fallbackMessage: string = '大模型请求失败'): HmAIError {
  if (error instanceof HmAIError) return error;
  return new HmAIError(HmAIErrorCode.INTERNAL, error.message.length > 0 ? error.message : fallbackMessage);
}
