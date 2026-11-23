export enum HmAIContentPartType {
  TEXT = 'text',
  IMAGE = 'image',
  FILE = 'file',
  AUDIO = 'audio'
}

export enum HmAIImageDetail {
  AUTO = 'auto',
  LOW = 'low',
  HIGH = 'high'
}

export class HmAIContentPart {
  readonly type: HmAIContentPartType;
  readonly text: string;
  readonly url: string;
  readonly base64Data: string;
  readonly mimeType: string;
  readonly fileName: string;
  readonly fileId: string;
  readonly detail: HmAIImageDetail;

  private constructor(type: HmAIContentPartType, text: string = '', url: string = '', base64Data: string = '',
    mimeType: string = '', fileName: string = '', fileId: string = '', detail: HmAIImageDetail = HmAIImageDetail.AUTO) {
    this.type = type;
    this.text = text;
    this.url = url;
    this.base64Data = base64Data;
    this.mimeType = mimeType;
    this.fileName = fileName;
    this.fileId = fileId;
    this.detail = detail;
  }

  static text(content: string): HmAIContentPart {
    return new HmAIContentPart(HmAIContentPartType.TEXT, content);
  }

  static imageUrl(url: string, detail: HmAIImageDetail = HmAIImageDetail.AUTO): HmAIContentPart {
    return new HmAIContentPart(HmAIContentPartType.IMAGE, '', url, '', '', '', '', detail);
  }

  static imageBase64(base64Data: string, mimeType: string = 'image/jpeg',
    detail: HmAIImageDetail = HmAIImageDetail.AUTO): HmAIContentPart {
    return new HmAIContentPart(HmAIContentPartType.IMAGE, '', '', base64Data, mimeType, '', '', detail);
  }

  static fileUrl(url: string, fileName: string = '', mimeType: string = 'application/octet-stream'): HmAIContentPart {
    return new HmAIContentPart(HmAIContentPartType.FILE, '', url, '', mimeType, fileName);
  }

  static fileBase64(base64Data: string, fileName: string, mimeType: string = 'application/octet-stream'): HmAIContentPart {
    return new HmAIContentPart(HmAIContentPartType.FILE, '', '', base64Data, mimeType, fileName);
  }

  static fileId(fileId: string): HmAIContentPart {
    return new HmAIContentPart(HmAIContentPartType.FILE, '', '', '', '', '', fileId);
  }

  static audioBase64(base64Data: string, mimeType: string = 'audio/wav'): HmAIContentPart {
    return new HmAIContentPart(HmAIContentPartType.AUDIO, '', '', base64Data, mimeType);
  }

  dataUrl(): string {
    if (this.url.length > 0) return this.url;
    if (this.base64Data.length === 0) return '';
    return `data:${this.mimeType};base64,${this.base64Data}`;
  }

  copy(): HmAIContentPart {
    return new HmAIContentPart(this.type, this.text, this.url, this.base64Data, this.mimeType,
      this.fileName, this.fileId, this.detail);
  }
}
