import { HmAIContentPart, HmAIContentPartType } from '../core/Content';
import { HmAIMessage, HmAIMessageRole, HmAIToolCall } from '../core/Message';

class ToolCallWire {
  index: number = 0;
  id: string = '';
  name: string = '';
  argumentsJson: string = '';
}

class ContentPartWire {
  type: HmAIContentPartType = HmAIContentPartType.TEXT;
  text: string = '';
  url: string = '';
  base64Data: string = '';
  mimeType: string = '';
  fileName: string = '';
  fileId: string = '';
  detail: string = 'auto';
}

class MessageWire {
  id: string = '';
  role: HmAIMessageRole = HmAIMessageRole.USER;
  content: string = '';
  name?: string;
  toolCallId?: string;
  toolCalls: ToolCallWire[] = [];
  parts: ContentPartWire[] = [];
}

export class HmAIMessageCodec {
  static encode(messages: HmAIMessage[]): string {
    return JSON.stringify(messages);
  }

  static decode(json: string): HmAIMessage[] {
    const source: MessageWire[] = JSON.parse(json) as MessageWire[];
    return source.map((wire: MessageWire): HmAIMessage => HmAIMessageCodec.decodeMessage(wire));
  }

  private static decodeMessage(wire: MessageWire): HmAIMessage {
    const message: HmAIMessage = new HmAIMessage(wire.role, wire.content, wire.id, wire.name);
    message.toolCallId = wire.toolCallId;
    message.toolCalls = (wire.toolCalls ?? []).map((call: ToolCallWire): HmAIToolCall =>
      new HmAIToolCall(call.id, call.name, call.argumentsJson, call.index));
    message.parts = (wire.parts ?? []).map((part: ContentPartWire): HmAIContentPart =>
      HmAIMessageCodec.decodePart(part));
    return message;
  }

  private static decodePart(part: ContentPartWire): HmAIContentPart {
    if (part.type === HmAIContentPartType.TEXT) return HmAIContentPart.text(part.text);
    if (part.type === HmAIContentPartType.IMAGE) {
      return part.url.length > 0 ? HmAIContentPart.imageUrl(part.url) :
        HmAIContentPart.imageBase64(part.base64Data, part.mimeType);
    }
    if (part.type === HmAIContentPartType.AUDIO) return HmAIContentPart.audioBase64(part.base64Data, part.mimeType);
    if (part.fileId.length > 0) return HmAIContentPart.fileId(part.fileId);
    return part.url.length > 0 ? HmAIContentPart.fileUrl(part.url, part.fileName, part.mimeType) :
      HmAIContentPart.fileBase64(part.base64Data, part.fileName, part.mimeType);
  }
}
