import { common } from '@kit.AbilityKit';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { HmAIError, HmAIErrorCode } from '../core/Errors';
import { HmAIContentPart } from '../core/Content';

let nextAttachmentId: number = 0;

export class HmAIAttachment {
  readonly id: string;
  readonly uri: string;
  readonly name: string;
  readonly mimeType: string;
  readonly size: number;
  readonly base64Data: string;

  constructor(uri: string, name: string, mimeType: string, size: number, base64Data: string) {
    nextAttachmentId++;
    this.id = `hm_attachment_${Date.now()}_${nextAttachmentId}`;
    this.uri = uri;
    this.name = name;
    this.mimeType = mimeType;
    this.size = size;
    this.base64Data = base64Data;
  }

  toContentPart(): HmAIContentPart {
    if (this.mimeType.startsWith('image/')) {
      return HmAIContentPart.imageBase64(this.base64Data, this.mimeType);
    }
    if (this.mimeType.startsWith('audio/')) {
      return HmAIContentPart.audioBase64(this.base64Data, this.mimeType);
    }
    return HmAIContentPart.fileBase64(this.base64Data, this.name, this.mimeType);
  }
}

export class HmAIAttachmentOptions {
  maxFiles: number = 5;
  maxBytesPerFile: number = 10 * 1024 * 1024;
  allowedSuffixes: string[] = [];
}

export class HmAIAttachmentPicker {
  static async pickDocuments(context: common.UIAbilityContext,
    options: HmAIAttachmentOptions = new HmAIAttachmentOptions()): Promise<HmAIAttachment[]> {
    const selectOptions: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    selectOptions.maxSelectNumber = options.maxFiles;
    const uris: string[] = await new picker.DocumentViewPicker(context).select(selectOptions);
    const attachments: HmAIAttachment[] = [];
    for (let index: number = 0; index < uris.length; index++) {
      attachments.push(HmAIAttachmentReader.read(uris[index], options));
    }
    return attachments;
  }
}

export class HmAIAttachmentReader {
  static read(uri: string, options: HmAIAttachmentOptions = new HmAIAttachmentOptions()): HmAIAttachment {
    const name: string = HmAIAttachmentReader.fileName(uri);
    if (options.allowedSuffixes.length > 0) {
      const suffix: string = HmAIAttachmentReader.suffix(name);
      if (!options.allowedSuffixes.includes(suffix)) {
        throw new HmAIError(HmAIErrorCode.INVALID_ARGUMENT, `不支持附件类型：${suffix}`);
      }
    }
    let file: fs.File | undefined;
    try {
      file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      const size: number = fs.statSync(file.fd).size;
      if (size > options.maxBytesPerFile) {
        throw new HmAIError(HmAIErrorCode.INVALID_ARGUMENT,
          `附件 ${name} 超过 ${options.maxBytesPerFile} 字节限制`);
      }
      const bytes: ArrayBuffer = new ArrayBuffer(size);
      const read: number = fs.readSync(file.fd, bytes);
      const encoded: string = new util.Base64Helper().encodeToStringSync(new Uint8Array(bytes, 0, read));
      return new HmAIAttachment(uri, name, HmAIAttachmentReader.mimeType(name), read, encoded);
    } catch (error) {
      if (error instanceof HmAIError) throw error;
      throw new HmAIError(HmAIErrorCode.INTERNAL,
        error instanceof Error ? `无法读取附件：${error.message}` : '无法读取附件');
    } finally {
      if (file !== undefined) {
        try { fs.closeSync(file); } catch (_error) {}
      }
    }
  }

  private static fileName(uri: string): string {
    const clean: string = uri.split('?')[0];
    const index: number = clean.lastIndexOf('/');
    return decodeURIComponent(index >= 0 ? clean.substring(index + 1) : clean) || 'attachment';
  }

  private static suffix(name: string): string {
    const index: number = name.lastIndexOf('.');
    return index >= 0 ? name.substring(index).toLowerCase() : '';
  }

  private static mimeType(name: string): string {
    const suffix: string = HmAIAttachmentReader.suffix(name);
    if (suffix === '.png') return 'image/png';
    if (suffix === '.jpg' || suffix === '.jpeg') return 'image/jpeg';
    if (suffix === '.webp') return 'image/webp';
    if (suffix === '.gif') return 'image/gif';
    if (suffix === '.pdf') return 'application/pdf';
    if (suffix === '.txt' || suffix === '.md') return 'text/plain';
    if (suffix === '.json') return 'application/json';
    if (suffix === '.wav') return 'audio/wav';
    if (suffix === '.mp3') return 'audio/mpeg';
    if (suffix === '.m4a') return 'audio/mp4';
    return 'application/octet-stream';
  }
}
