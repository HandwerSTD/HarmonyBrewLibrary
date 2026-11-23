import { fileIo as fs } from '@kit.CoreFileKit';
import { HmAIError, HmAIErrorCode } from '../core/Errors';
import { HmAIMessage } from '../core/Message';
import { HmAIMessageCodec } from './MessageCodec';

let nextConversationId: number = 0;

export class HmAIConversationRecord {
  readonly id: string;
  title: string;
  messages: HmAIMessage[];
  tags: string[];
  readonly createdAt: number;
  updatedAt: number;

  constructor(title: string, messages: HmAIMessage[] = [], id: string = '', createdAt: number = Date.now()) {
    nextConversationId++;
    this.id = id.length > 0 ? id : `hm_conversation_${createdAt}_${nextConversationId}`;
    this.title = title; this.messages = messages.map((message: HmAIMessage): HmAIMessage => message.copy());
    this.tags = []; this.createdAt = createdAt; this.updatedAt = createdAt;
  }

  copy(): HmAIConversationRecord {
    const record: HmAIConversationRecord = new HmAIConversationRecord(this.title, this.messages, this.id, this.createdAt);
    record.tags = [...this.tags]; record.updatedAt = this.updatedAt; return record;
  }
}

export interface HmAIConversationStore {
  save(record: HmAIConversationRecord): Promise<void>;
  get(id: string): Promise<HmAIConversationRecord | undefined>;
  list(): Promise<HmAIConversationRecord[]>;
  search(query: string): Promise<HmAIConversationRecord[]>;
  delete(id: string): Promise<void>;
  clear(): Promise<void>;
  exportJson(): Promise<string>;
  importJson(json: string, replace?: boolean): Promise<number>;
}

export class HmAIMemoryConversationStore implements HmAIConversationStore {
  protected records: HmAIConversationRecord[] = [];

  async save(record: HmAIConversationRecord): Promise<void> {
    const copy: HmAIConversationRecord = record.copy(); copy.updatedAt = Date.now();
    this.records = this.records.filter((item: HmAIConversationRecord): boolean => item.id !== copy.id);
    this.records.push(copy);
  }
  async get(id: string): Promise<HmAIConversationRecord | undefined> {
    return this.records.find((record: HmAIConversationRecord): boolean => record.id === id)?.copy();
  }
  async list(): Promise<HmAIConversationRecord[]> {
    return [...this.records].sort((left: HmAIConversationRecord, right: HmAIConversationRecord): number =>
      right.updatedAt - left.updatedAt).map((record: HmAIConversationRecord): HmAIConversationRecord => record.copy());
  }
  async search(query: string): Promise<HmAIConversationRecord[]> {
    const keyword: string = query.trim().toLowerCase();
    if (keyword.length === 0) return this.list();
    return this.records.filter((record: HmAIConversationRecord): boolean => {
      if (record.title.toLowerCase().includes(keyword) || record.tags.join(' ').toLowerCase().includes(keyword)) return true;
      return record.messages.some((message: HmAIMessage): boolean => message.content.toLowerCase().includes(keyword));
    }).map((record: HmAIConversationRecord): HmAIConversationRecord => record.copy());
  }
  async delete(id: string): Promise<void> {
    this.records = this.records.filter((record: HmAIConversationRecord): boolean => record.id !== id);
  }
  async clear(): Promise<void> { this.records = []; }
  async exportJson(): Promise<string> {
    const wires: ConversationWire[] = this.records.map((record: HmAIConversationRecord): ConversationWire =>
      ConversationWire.fromRecord(record));
    return JSON.stringify(wires);
  }
  async importJson(json: string, replace: boolean = false): Promise<number> {
    const wires: ConversationWire[] = JSON.parse(json) as ConversationWire[];
    if (replace) this.records = [];
    for (let index: number = 0; index < wires.length; index++) await this.save(ConversationWire.toRecord(wires[index]));
    return wires.length;
  }
}

class ConversationWire {
  id: string = '';
  title: string = '';
  messagesJson: string = '[]';
  tags: string[] = [];
  createdAt: number = 0;
  updatedAt: number = 0;

  static fromRecord(record: HmAIConversationRecord): ConversationWire {
    const wire: ConversationWire = new ConversationWire();
    wire.id = record.id; wire.title = record.title; wire.messagesJson = HmAIMessageCodec.encode(record.messages);
    wire.tags = [...record.tags]; wire.createdAt = record.createdAt; wire.updatedAt = record.updatedAt; return wire;
  }
  static toRecord(wire: ConversationWire): HmAIConversationRecord {
    const record: HmAIConversationRecord = new HmAIConversationRecord(wire.title,
      HmAIMessageCodec.decode(wire.messagesJson), wire.id, wire.createdAt);
    record.tags = [...(wire.tags ?? [])]; record.updatedAt = wire.updatedAt; return record;
  }
}

export class HmAIFileConversationStore extends HmAIMemoryConversationStore {
  private readonly filePath: string;
  private loaded: boolean = false;

  constructor(directory: string, fileName: string = 'hmkit-ai-conversations.json') {
    super();
    if (directory.trim().length === 0) throw new HmAIError(HmAIErrorCode.INVALID_ARGUMENT, '存储目录不能为空');
    const base: string = directory.endsWith('/') ? directory.substring(0, directory.length - 1) : directory;
    this.filePath = `${base}/${fileName}`;
  }

  async save(record: HmAIConversationRecord): Promise<void> { await this.ensureLoaded(); await super.save(record); this.flush(); }
  async get(id: string): Promise<HmAIConversationRecord | undefined> { await this.ensureLoaded(); return super.get(id); }
  async list(): Promise<HmAIConversationRecord[]> { await this.ensureLoaded(); return super.list(); }
  async search(query: string): Promise<HmAIConversationRecord[]> { await this.ensureLoaded(); return super.search(query); }
  async delete(id: string): Promise<void> { await this.ensureLoaded(); await super.delete(id); this.flush(); }
  async clear(): Promise<void> { await this.ensureLoaded(); await super.clear(); this.flush(); }
  async exportJson(): Promise<string> { await this.ensureLoaded(); return super.exportJson(); }
  async importJson(json: string, replace: boolean = false): Promise<number> {
    await this.ensureLoaded(); const count: number = await super.importJson(json, replace); this.flush(); return count;
  }

  private async ensureLoaded(): Promise<void> {
    if (this.loaded) return;
    this.loaded = true;
    try {
      if (!fs.accessSync(this.filePath)) return;
      const content: string = fs.readTextSync(this.filePath);
      if (content.trim().length > 0) await super.importJson(content, true);
    } catch (error) {
      throw new HmAIError(HmAIErrorCode.INTERNAL,
        error instanceof Error ? `无法读取会话存储：${error.message}` : '无法读取会话存储');
    }
  }

  private flush(): void {
    const wires: ConversationWire[] = this.records.map((record: HmAIConversationRecord): ConversationWire =>
      ConversationWire.fromRecord(record));
    let file: fs.File | undefined;
    try {
      file = fs.openSync(this.filePath, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, JSON.stringify(wires));
    } catch (error) {
      throw new HmAIError(HmAIErrorCode.INTERNAL,
        error instanceof Error ? `无法写入会话存储：${error.message}` : '无法写入会话存储');
    } finally {
      if (file !== undefined) { try { fs.closeSync(file); } catch (_error) {} }
    }
  }
}
