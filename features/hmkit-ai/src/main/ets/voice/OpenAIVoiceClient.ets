import { BusinessError } from '@kit.BasicServicesKit';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { HmAIError, HmAIErrorCode } from '../core/Errors';
import { HmAIAudioStreamObserver, HmAIAudioStreamTask, HmAISpeechModel, HmAISpeechRequest,
  HmAITranscriptionModel, HmAITranscriptionRequest, HmAITranscriptionResult } from './VoiceTypes';

class TranscriptionWire {
  text?: string;
  language?: string;
  duration?: number;
}

class SpeechRequestWire {
  model: string;
  input: string;
  voice: string;
  response_format: string;
  speed: number;
  instructions?: string;
  constructor(request: HmAISpeechRequest) {
    this.model = request.model; this.input = request.input; this.voice = request.voice;
    this.response_format = request.responseFormat; this.speed = request.speed;
    if (request.instructions.length > 0) this.instructions = request.instructions;
  }
}

export function encodeOpenAISpeechRequest(request: HmAISpeechRequest): string {
  if (request.input.length === 0 || request.input.length > 4096) {
    throw new HmAIError(HmAIErrorCode.INVALID_ARGUMENT, 'TTS 文本长度必须在 1 到 4096 之间');
  }
  if (request.speed < 0.25 || request.speed > 4) {
    throw new HmAIError(HmAIErrorCode.INVALID_ARGUMENT, 'TTS speed 必须在 0.25 到 4 之间');
  }
  return JSON.stringify(new SpeechRequestWire(request));
}

export class OpenAIVoiceClientOptions {
  readonly baseURL: string;
  apiKey?: string;
  transcriptionPath: string = '/audio/transcriptions';
  speechPath: string = '/audio/speech';
  timeoutMs: number = 120000;
  headers: Record<string, string> = {};
  constructor(baseURL: string = 'https://api.openai.com/v1') { this.baseURL = baseURL; }
}

export class OpenAIVoiceClient implements HmAITranscriptionModel, HmAISpeechModel {
  private readonly options: OpenAIVoiceClientOptions;
  constructor(options: OpenAIVoiceClientOptions = new OpenAIVoiceClientOptions()) { this.options = options; }

  async transcribe(request: HmAITranscriptionRequest): Promise<HmAITranscriptionResult> {
    const client: http.HttpRequest = http.createHttp();
    const bytes: Uint8Array = new util.Base64Helper().decodeSync(request.audio.base64Data);
    const forms: http.MultiFormData[] = [
      { name: 'file', contentType: request.audio.mimeType, remoteFileName: request.audio.fileName, data: bytes.buffer },
      { name: 'model', contentType: 'text/plain', data: request.model },
      { name: 'response_format', contentType: 'text/plain', data: 'json' }
    ];
    if (request.language.length > 0) forms.push({ name: 'language', contentType: 'text/plain', data: request.language });
    if (request.prompt.length > 0) forms.push({ name: 'prompt', contentType: 'text/plain', data: request.prompt });
    try {
      const response: http.HttpResponse = await client.request(this.endpoint(this.options.transcriptionPath), {
        method: http.RequestMethod.POST, header: this.headers(), multiFormDataList: forms,
        connectTimeout: this.options.timeoutMs, readTimeout: this.options.timeoutMs, usingCache: false
      });
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new HmAIError(HmAIErrorCode.HTTP, `转写服务返回 HTTP ${response.responseCode}`, response.responseCode);
      }
      const raw: string = typeof response.result === 'string' ? response.result : JSON.stringify(response.result);
      const decoded: TranscriptionWire = JSON.parse(raw) as TranscriptionWire;
      return new HmAITranscriptionResult(decoded.text ?? '', decoded.language ?? '', decoded.duration ?? 0);
    } catch (error) {
      if (error instanceof HmAIError) throw error;
      const detail: string = error instanceof Error ? error.message : '语音转写失败';
      throw new HmAIError(HmAIErrorCode.NETWORK, detail);
    } finally { client.destroy(); }
  }

  createSpeech(request: HmAISpeechRequest,
    observer: HmAIAudioStreamObserver = new HmAIAudioStreamObserver()): HmAIAudioStreamTask {
    return new OpenAISpeechTask(this.endpoint(this.options.speechPath), this.options,
      encodeOpenAISpeechRequest(request), observer);
  }

  private endpoint(path: string): string {
    const base: string = this.options.baseURL.endsWith('/') ? this.options.baseURL.slice(0, -1) : this.options.baseURL;
    return `${base}${path.startsWith('/') ? path : `/${path}`}`;
  }
  private headers(): Record<string, string> {
    const result: Record<string, string> = {};
    if ((this.options.apiKey ?? '').length > 0) result['Authorization'] = `Bearer ${this.options.apiKey}`;
    Object.keys(this.options.headers).forEach((key: string): void => { result[key] = this.options.headers[key]; });
    return result;
  }
}

class OpenAISpeechTask implements HmAIAudioStreamTask {
  private readonly url: string; private readonly options: OpenAIVoiceClientOptions;
  private readonly body: string; private readonly observer: HmAIAudioStreamObserver;
  private request?: http.HttpRequest; private started: boolean = false; private cancelled: boolean = false;
  private resolve?: () => void; private reject?: (error: HmAIError) => void;
  private readonly onData: Callback<ArrayBuffer>; private readonly onEnd: Callback<void>;
  constructor(url: string, options: OpenAIVoiceClientOptions, body: string, observer: HmAIAudioStreamObserver) {
    this.url = url; this.options = options; this.body = body; this.observer = observer;
    this.onData = (data: ArrayBuffer): void => { if (!this.cancelled) this.observer.onAudio(data); };
    this.onEnd = (): void => { this.cleanup(); this.observer.onComplete(); this.resolve?.(); };
  }
  start(): Promise<void> {
    if (this.started) return Promise.reject(new HmAIError(HmAIErrorCode.INVALID_ARGUMENT, 'TTS 任务只能启动一次'));
    this.started = true;
    return new Promise<void>((resolve: () => void, reject: (error: HmAIError) => void): void => {
      this.resolve = resolve; this.reject = reject; this.request = http.createHttp();
      this.request.on('dataReceive', this.onData); this.request.on('dataEnd', this.onEnd);
      const headers: Record<string, string> = { 'Content-Type': 'application/json', 'Accept': 'application/octet-stream' };
      if ((this.options.apiKey ?? '').length > 0) headers['Authorization'] = `Bearer ${this.options.apiKey}`;
      Object.keys(this.options.headers).forEach((key: string): void => { headers[key] = this.options.headers[key]; });
      this.request.requestInStream(this.url, { method: http.RequestMethod.POST, header: headers, extraData: this.body,
        connectTimeout: this.options.timeoutMs, readTimeout: this.options.timeoutMs, usingCache: false })
        .then((status: number): void => {
          if (status < 200 || status >= 300) this.fail(new HmAIError(HmAIErrorCode.HTTP,
            `TTS 服务返回 HTTP ${status}`, status));
        }).catch((error: BusinessError): void => this.fail(new HmAIError(HmAIErrorCode.NETWORK, error.message,
          undefined, undefined, error.code)));
    });
  }
  cancel(): void { if (this.cancelled) return; this.cancelled = true; this.fail(new HmAIError(HmAIErrorCode.CANCELLED, 'TTS 已取消')); }
  isCancelled(): boolean { return this.cancelled; }
  private fail(error: HmAIError): void { this.cleanup(); this.observer.onError(error); this.reject?.(error); }
  private cleanup(): void {
    if (this.request === undefined) return;
    this.request.off('dataReceive', this.onData); this.request.off('dataEnd', this.onEnd); this.request.destroy();
    this.request = undefined;
  }
}
