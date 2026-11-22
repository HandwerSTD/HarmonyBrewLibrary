import { HmAIError } from '../core/Errors';

export class HmAIAudioData {
  readonly base64Data: string;
  readonly mimeType: string;
  readonly fileName: string;
  constructor(base64Data: string, mimeType: string = 'audio/wav', fileName: string = 'audio.wav') {
    this.base64Data = base64Data; this.mimeType = mimeType; this.fileName = fileName;
  }
}

export class HmAITranscriptionRequest {
  readonly audio: HmAIAudioData;
  model: string = 'gpt-4o-mini-transcribe';
  language: string = '';
  prompt: string = '';
  constructor(audio: HmAIAudioData) { this.audio = audio; }
}

export class HmAITranscriptionResult {
  readonly text: string;
  readonly language: string;
  readonly durationSeconds: number;
  constructor(text: string, language: string = '', durationSeconds: number = 0) {
    this.text = text; this.language = language; this.durationSeconds = durationSeconds;
  }
}

export class HmAISpeechRequest {
  readonly input: string;
  model: string = 'gpt-4o-mini-tts';
  voice: string = 'alloy';
  instructions: string = '';
  responseFormat: string = 'pcm';
  speed: number = 1;
  constructor(input: string) { this.input = input; }
}

export class HmAIAudioStreamObserver {
  readonly onAudio: (chunk: ArrayBuffer) => void;
  readonly onComplete: () => void;
  readonly onError: (error: HmAIError) => void;
  constructor(onAudio: (chunk: ArrayBuffer) => void = (_chunk: ArrayBuffer): void => {},
    onComplete: () => void = (): void => {}, onError: (error: HmAIError) => void = (_error: HmAIError): void => {}) {
    this.onAudio = onAudio; this.onComplete = onComplete; this.onError = onError;
  }
}

export interface HmAIAudioStreamTask {
  start(): Promise<void>;
  cancel(): void;
  isCancelled(): boolean;
}

export interface HmAITranscriptionModel {
  transcribe(request: HmAITranscriptionRequest): Promise<HmAITranscriptionResult>;
}

export interface HmAISpeechModel {
  createSpeech(request: HmAISpeechRequest, observer?: HmAIAudioStreamObserver): HmAIAudioStreamTask;
}

export enum HmAIRealtimeState {
  IDLE = 'idle',
  CONNECTING = 'connecting',
  CONNECTED = 'connected',
  CLOSED = 'closed',
  ERROR = 'error'
}

export class HmAIRealtimeEvent {
  readonly type: string;
  readonly textDelta: string;
  readonly audioBase64: string;
  readonly rawJson: string;
  constructor(type: string, textDelta: string = '', audioBase64: string = '', rawJson: string = '') {
    this.type = type; this.textDelta = textDelta; this.audioBase64 = audioBase64; this.rawJson = rawJson;
  }
}

export class HmAIRealtimeObserver {
  readonly onStateChange: (state: HmAIRealtimeState) => void;
  readonly onEvent: (event: HmAIRealtimeEvent) => void;
  readonly onError: (error: HmAIError) => void;
  constructor(onStateChange: (state: HmAIRealtimeState) => void = (_state: HmAIRealtimeState): void => {},
    onEvent: (event: HmAIRealtimeEvent) => void = (_event: HmAIRealtimeEvent): void => {},
    onError: (error: HmAIError) => void = (_error: HmAIError): void => {}) {
    this.onStateChange = onStateChange; this.onEvent = onEvent; this.onError = onError;
  }
}

export interface HmAIRealtimeSession {
  connect(): Promise<void>;
  sendText(text: string): Promise<void>;
  appendAudio(base64Audio: string): Promise<void>;
  commitAudio(): Promise<void>;
  requestResponse(): Promise<void>;
  close(): Promise<void>;
}
