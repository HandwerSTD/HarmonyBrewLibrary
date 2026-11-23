import { audio } from '@kit.AudioKit';
import { HmAIError, HmAIErrorCode } from '../core/Errors';

export class HmAIMicrophoneOptions {
  samplingRate: audio.AudioSamplingRate = audio.AudioSamplingRate.SAMPLE_RATE_24000;
  channels: audio.AudioChannel = audio.AudioChannel.CHANNEL_1;
  sampleFormat: audio.AudioSampleFormat = audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE;
}

export class HmAIMicrophoneCapture {
  private readonly options: HmAIMicrophoneOptions;
  private readonly onAudio: (chunk: ArrayBuffer) => void;
  private capturer?: audio.AudioCapturer;
  private capturing: boolean = false;
  private readonly onReadData: (chunk: ArrayBuffer) => void;

  constructor(onAudio: (chunk: ArrayBuffer) => void,
    options: HmAIMicrophoneOptions = new HmAIMicrophoneOptions()) {
    this.onAudio = onAudio; this.options = options;
    this.onReadData = (chunk: ArrayBuffer): void => { if (this.capturing && chunk.byteLength > 0) this.onAudio(chunk); };
  }

  async start(): Promise<void> {
    if (this.capturing) return;
    const capturerOptions: audio.AudioCapturerOptions = {
      streamInfo: { samplingRate: this.options.samplingRate, channels: this.options.channels,
        sampleFormat: this.options.sampleFormat, encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW },
      capturerInfo: { source: audio.SourceType.SOURCE_TYPE_MIC, capturerFlags: 0 }
    };
    this.capturer = await audio.createAudioCapturer(capturerOptions);
    try { this.capturer.on('readData', this.onReadData); }
    catch (error) {
      await this.capturer.release(); this.capturer = undefined;
      throw new HmAIError(HmAIErrorCode.INTERNAL,
        error instanceof Error ? `无法监听录音数据：${error.message}` : '无法监听录音数据');
    }
    this.capturing = true; await this.capturer.start();
  }

  async stop(): Promise<void> {
    if (!this.capturing || this.capturer === undefined) return;
    this.capturing = false;
    try { this.capturer.off('readData', this.onReadData); } catch (_error) {}
    await this.capturer.stop(); await this.capturer.release(); this.capturer = undefined;
  }

  isCapturing(): boolean { return this.capturing; }

}

export class HmAIPCMPlayerOptions {
  samplingRate: audio.AudioSamplingRate = audio.AudioSamplingRate.SAMPLE_RATE_24000;
  channels: audio.AudioChannel = audio.AudioChannel.CHANNEL_1;
  sampleFormat: audio.AudioSampleFormat = audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE;
}

export class HmAIPCMStreamPlayer {
  private readonly options: HmAIPCMPlayerOptions;
  private renderer?: audio.AudioRenderer;
  private queue: Uint8Array[] = [];
  private readonly onWriteData: (buffer: ArrayBuffer) => void;
  constructor(options: HmAIPCMPlayerOptions = new HmAIPCMPlayerOptions()) {
    this.options = options;
    this.onWriteData = (buffer: ArrayBuffer): void => {
      const target: Uint8Array = new Uint8Array(buffer); target.fill(0);
      if (this.queue.length === 0) return;
      const source: Uint8Array = this.queue.shift() as Uint8Array;
      target.set(source.subarray(0, Math.min(source.length, target.length)));
      if (source.length > target.length) this.queue.unshift(source.subarray(target.length));
    };
  }
  async start(): Promise<void> {
    if (this.renderer !== undefined) return;
    const rendererOptions: audio.AudioRendererOptions = {
      streamInfo: { samplingRate: this.options.samplingRate, channels: this.options.channels,
        sampleFormat: this.options.sampleFormat, encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW },
      rendererInfo: { usage: audio.StreamUsage.STREAM_USAGE_VOICE_ASSISTANT, rendererFlags: 0 }
    };
    this.renderer = await audio.createAudioRenderer(rendererOptions);
    try { this.renderer.on('writeData', this.onWriteData); }
    catch (error) {
      await this.renderer.release(); this.renderer = undefined;
      throw new HmAIError(HmAIErrorCode.INTERNAL,
        error instanceof Error ? `无法监听播放缓冲区：${error.message}` : '无法监听播放缓冲区');
    }
    await this.renderer.start();
  }
  async write(chunk: ArrayBuffer): Promise<void> {
    if (this.renderer === undefined) throw new HmAIError(HmAIErrorCode.INVALID_ARGUMENT, 'PCM 播放器尚未启动');
    this.queue.push(new Uint8Array(chunk));
  }
  async stop(): Promise<void> {
    if (this.renderer === undefined) return;
    try { this.renderer.off('writeData', this.onWriteData); } catch (_error) {}
    await this.renderer.stop(); await this.renderer.release(); this.renderer = undefined; this.queue = [];
  }
}
