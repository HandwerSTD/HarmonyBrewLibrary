import { BusinessError } from '@kit.BasicServicesKit';
import { webSocket } from '@kit.NetworkKit';
import { HmAIError, HmAIErrorCode } from '../core/Errors';
import { HmAIRealtimeEvent, HmAIRealtimeObserver, HmAIRealtimeSession,
  HmAIRealtimeState } from './VoiceTypes';

class RealtimeEventWire {
  type?: string;
  delta?: string;
  error?: RealtimeErrorWire;
}
class RealtimeErrorWire { message?: string; }

class RealtimeSessionConfigWire {
  type: string = 'realtime';
  instructions: string;
  voice: string;
  input_audio_format: string;
  output_audio_format: string;
  output_modalities: string[] = ['audio', 'text'];
  constructor(options: OpenAIRealtimeOptions) {
    this.instructions = options.instructions; this.voice = options.voice;
    this.input_audio_format = options.inputAudioFormat; this.output_audio_format = options.outputAudioFormat;
  }
}
class RealtimeSessionUpdateWire {
  type: string = 'session.update';
  session: RealtimeSessionConfigWire;
  constructor(options: OpenAIRealtimeOptions) { this.session = new RealtimeSessionConfigWire(options); }
}
class RealtimeTextContentWire {
  type: string = 'input_text';
  text: string;
  constructor(text: string) { this.text = text; }
}
class RealtimeMessageItemWire {
  type: string = 'message';
  role: string = 'user';
  content: RealtimeTextContentWire[];
  constructor(text: string) { this.content = [new RealtimeTextContentWire(text)]; }
}
class RealtimeItemCreateWire {
  type: string = 'conversation.item.create';
  item: RealtimeMessageItemWire;
  constructor(text: string) { this.item = new RealtimeMessageItemWire(text); }
}
class RealtimeAudioAppendWire {
  type: string = 'input_audio_buffer.append';
  audio: string;
  constructor(audio: string) { this.audio = audio; }
}

export function encodeOpenAIRealtimeTextEvent(text: string): string {
  return JSON.stringify(new RealtimeItemCreateWire(text));
}

export function encodeOpenAIRealtimeAudioAppend(base64Audio: string): string {
  return JSON.stringify(new RealtimeAudioAppendWire(base64Audio));
}

export function decodeOpenAIRealtimeEvent(json: string): HmAIRealtimeEvent {
  const wire: RealtimeEventWire = JSON.parse(json) as RealtimeEventWire;
  const type: string = wire.type ?? '';
  if (type === 'error') throw new HmAIError(HmAIErrorCode.PROTOCOL,
    wire.error?.message ?? 'Realtime 返回错误');
  const isAudio: boolean = type === 'response.audio.delta' || type === 'response.output_audio.delta';
  const isText: boolean = type === 'response.output_text.delta' || type === 'response.audio_transcript.delta' ||
    type === 'response.audio.transcript.delta' || type === 'conversation.item.input_audio_transcription.delta';
  return new HmAIRealtimeEvent(type, isText ? wire.delta ?? '' : '', isAudio ? wire.delta ?? '' : '', json);
}

export class OpenAIRealtimeOptions {
  model: string = 'gpt-realtime';
  url: string = 'wss://api.openai.com/v1/realtime';
  apiKey?: string;
  voice: string = 'alloy';
  instructions: string = '';
  inputAudioFormat: string = 'pcm16';
  outputAudioFormat: string = 'pcm16';
  headers: Record<string, string> = {};
}

export class OpenAIRealtimeSession implements HmAIRealtimeSession {
  private readonly options: OpenAIRealtimeOptions;
  private readonly observer: HmAIRealtimeObserver;
  private socket?: webSocket.WebSocket;
  private state: HmAIRealtimeState = HmAIRealtimeState.IDLE;
  private readonly onMessage: (error: BusinessError, value: string | ArrayBuffer) => void;
  private readonly onError: (error: BusinessError) => void;

  constructor(options: OpenAIRealtimeOptions = new OpenAIRealtimeOptions(),
    observer: HmAIRealtimeObserver = new HmAIRealtimeObserver()) {
    this.options = options; this.observer = observer;
    this.onMessage = (error: BusinessError, value: string | ArrayBuffer): void => {
      if (error) { this.fail(new HmAIError(HmAIErrorCode.NETWORK, error.message)); return; }
      if (typeof value === 'string') this.consume(value);
    };
    this.onError = (error: BusinessError): void => this.fail(new HmAIError(HmAIErrorCode.NETWORK, error.message));
  }

  async connect(): Promise<void> {
    if (this.state === HmAIRealtimeState.CONNECTED) return;
    this.changeState(HmAIRealtimeState.CONNECTING);
    this.socket = webSocket.createWebSocket();
    this.socket.on('message', this.onMessage); this.socket.on('error', this.onError);
    const headers: Record<string, string> = {};
    if ((this.options.apiKey ?? '').length > 0) headers['Authorization'] = `Bearer ${this.options.apiKey}`;
    Object.keys(this.options.headers).forEach((key: string): void => { headers[key] = this.options.headers[key]; });
    const separator: string = this.options.url.includes('?') ? '&' : '?';
    try {
      await this.socket.connect(`${this.options.url}${separator}model=${encodeURIComponent(this.options.model)}`,
        { header: headers });
    } catch (error) {
      const mapped: HmAIError = new HmAIError(HmAIErrorCode.NETWORK,
        error instanceof Error ? error.message : 'Realtime 连接失败');
      this.fail(mapped); throw mapped;
    }
    this.changeState(HmAIRealtimeState.CONNECTED);
    await this.sendRaw(JSON.stringify(new RealtimeSessionUpdateWire(this.options)));
  }

  async sendText(text: string): Promise<void> {
    await this.sendRaw(encodeOpenAIRealtimeTextEvent(text));
  }
  async appendAudio(base64Audio: string): Promise<void> {
    await this.sendRaw(encodeOpenAIRealtimeAudioAppend(base64Audio));
  }
  async commitAudio(): Promise<void> { await this.sendRaw('{"type":"input_audio_buffer.commit"}'); }
  async requestResponse(): Promise<void> { await this.sendRaw('{"type":"response.create"}'); }
  async close(): Promise<void> {
    if (this.socket !== undefined) {
      this.socket.off('message', this.onMessage); this.socket.off('error', this.onError);
      try { await this.socket.close({ code: 1000, reason: 'client closed' }); }
      catch (error) {
        const mapped: HmAIError = new HmAIError(HmAIErrorCode.NETWORK,
          error instanceof Error ? error.message : 'Realtime 关闭失败');
        this.fail(mapped); throw mapped;
      }
      this.socket = undefined;
    }
    this.changeState(HmAIRealtimeState.CLOSED);
  }

  private async sendRaw(json: string): Promise<void> {
    if (this.socket === undefined || this.state !== HmAIRealtimeState.CONNECTED) {
      throw new HmAIError(HmAIErrorCode.INVALID_ARGUMENT, 'Realtime 会话尚未连接');
    }
    try { await this.socket.send(json); }
    catch (error) {
      const mapped: HmAIError = new HmAIError(HmAIErrorCode.NETWORK,
        error instanceof Error ? error.message : 'Realtime 发送失败');
      this.fail(mapped); throw mapped;
    }
  }
  private consume(json: string): void {
    try {
      this.observer.onEvent(decodeOpenAIRealtimeEvent(json));
    } catch (error) {
      this.fail(new HmAIError(HmAIErrorCode.PROTOCOL,
        error instanceof Error ? error.message : 'Realtime 事件解析失败'));
    }
  }
  private fail(error: HmAIError): void { this.changeState(HmAIRealtimeState.ERROR); this.observer.onError(error); }
  private changeState(state: HmAIRealtimeState): void { this.state = state; this.observer.onStateChange(state); }
}
