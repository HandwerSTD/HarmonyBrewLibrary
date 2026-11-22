import { util } from '@kit.ArkTS';
import { HmAIError, HmAIErrorCode } from '../core/Errors';
import { HmAIAttachment } from '../attachment/Attachments';

let nextChunkId: number = 0;

export class HmAIRAGDocument {
  readonly id: string;
  readonly title: string;
  readonly content: string;
  readonly sourceUrl: string;

  constructor(id: string, title: string, content: string, sourceUrl: string = '') {
    this.id = id; this.title = title; this.content = content; this.sourceUrl = sourceUrl;
  }
}

export class HmAIRAGChunk {
  readonly id: string;
  readonly documentId: string;
  readonly title: string;
  readonly text: string;
  readonly sourceUrl: string;
  readonly startOffset: number;
  readonly endOffset: number;
  embedding: number[] = [];

  constructor(documentId: string, title: string, text: string, sourceUrl: string,
    startOffset: number, endOffset: number, id: string = '') {
    nextChunkId++;
    this.id = id.length > 0 ? id : `hm_chunk_${Date.now()}_${nextChunkId}`;
    this.documentId = documentId; this.title = title; this.text = text; this.sourceUrl = sourceUrl;
    this.startOffset = startOffset; this.endOffset = endOffset;
  }
}

export class HmAIRAGSearchResult {
  readonly chunk: HmAIRAGChunk;
  readonly score: number;
  constructor(chunk: HmAIRAGChunk, score: number) { this.chunk = chunk; this.score = score; }
}

export interface HmAIEmbeddingModel {
  embed(texts: string[]): Promise<number[][]>;
}

export class HmAIHashEmbeddingModel implements HmAIEmbeddingModel {
  private readonly dimensions: number;
  constructor(dimensions: number = 256) {
    if (dimensions < 16 || dimensions > 4096) {
      throw new HmAIError(HmAIErrorCode.INVALID_ARGUMENT, '向量维度必须在 16 到 4096 之间');
    }
    this.dimensions = dimensions;
  }
  async embed(texts: string[]): Promise<number[][]> {
    return texts.map((text: string): number[] => this.embedOne(text));
  }
  private embedOne(text: string): number[] {
    const vector: number[] = new Array<number>(this.dimensions).fill(0);
    const normalized: string = text.toLowerCase();
    for (let index: number = 0; index < normalized.length; index++) {
      const token: string = normalized.substring(index, Math.min(index + 3, normalized.length));
      let hash: number = 2166136261;
      for (let charIndex: number = 0; charIndex < token.length; charIndex++) {
        hash ^= token.charCodeAt(charIndex); hash = Math.imul(hash, 16777619);
      }
      vector[Math.abs(hash) % this.dimensions] += 1;
    }
    return HmAIRAGMath.normalize(vector);
  }
}

export class HmAIRAGChunkOptions {
  maxCharacters: number = 800;
  overlapCharacters: number = 120;
}

export class HmAIRAGChunker {
  static chunk(document: HmAIRAGDocument,
    options: HmAIRAGChunkOptions = new HmAIRAGChunkOptions()): HmAIRAGChunk[] {
    if (options.maxCharacters < 100 || options.overlapCharacters < 0 ||
      options.overlapCharacters >= options.maxCharacters) {
      throw new HmAIError(HmAIErrorCode.INVALID_ARGUMENT, '无效的文档分块参数');
    }
    const chunks: HmAIRAGChunk[] = [];
    let start: number = 0;
    while (start < document.content.length) {
      let end: number = Math.min(start + options.maxCharacters, document.content.length);
      if (end < document.content.length) {
        const breakAt: number = document.content.lastIndexOf('\n', end);
        if (breakAt > start + Math.floor(options.maxCharacters / 2)) end = breakAt;
      }
      const text: string = document.content.substring(start, end).trim();
      if (text.length > 0) chunks.push(new HmAIRAGChunk(document.id, document.title, text,
        document.sourceUrl, start, end));
      if (end >= document.content.length) break;
      start = Math.max(start + 1, end - options.overlapCharacters);
    }
    return chunks;
  }
}

export class HmAIDocumentLoader {
  static fromTextAttachment(attachment: HmAIAttachment): HmAIRAGDocument {
    if (!(attachment.mimeType.startsWith('text/') || attachment.mimeType === 'application/json')) {
      throw new HmAIError(HmAIErrorCode.INVALID_ARGUMENT,
        `附件 ${attachment.name} 需要宿主提供文本提取器后才能导入 RAG`);
    }
    const bytes: Uint8Array = new util.Base64Helper().decodeSync(attachment.base64Data);
    const content: string = util.TextDecoder.create('utf-8', { ignoreBOM: true }).decodeToString(bytes);
    return new HmAIRAGDocument(attachment.id, attachment.name, content, attachment.uri);
  }
}

export class HmAILocalVectorIndex {
  private chunks: HmAIRAGChunk[] = [];

  add(chunks: HmAIRAGChunk[]): void {
    for (let index: number = 0; index < chunks.length; index++) {
      this.chunks = this.chunks.filter((chunk: HmAIRAGChunk): boolean => chunk.id !== chunks[index].id);
      this.chunks.push(chunks[index]);
    }
  }
  removeDocument(documentId: string): void {
    this.chunks = this.chunks.filter((chunk: HmAIRAGChunk): boolean => chunk.documentId !== documentId);
  }
  clear(): void { this.chunks = []; }
  size(): number { return this.chunks.length; }
  search(queryEmbedding: number[], limit: number = 5, minimumScore: number = 0): HmAIRAGSearchResult[] {
    return this.chunks.map((chunk: HmAIRAGChunk): HmAIRAGSearchResult =>
      new HmAIRAGSearchResult(chunk, HmAIRAGMath.cosine(queryEmbedding, chunk.embedding)))
      .filter((result: HmAIRAGSearchResult): boolean => result.score >= minimumScore)
      .sort((left: HmAIRAGSearchResult, right: HmAIRAGSearchResult): number => right.score - left.score)
      .slice(0, Math.max(0, limit));
  }
  exportJson(): string { return JSON.stringify(this.chunks); }
  importJson(json: string): void { this.chunks = JSON.parse(json) as HmAIRAGChunk[]; }
}

export class HmAIRAGEngine {
  private readonly embeddings: HmAIEmbeddingModel;
  private readonly index: HmAILocalVectorIndex;
  private readonly chunkOptions: HmAIRAGChunkOptions;

  constructor(embeddings: HmAIEmbeddingModel = new HmAIHashEmbeddingModel(),
    index: HmAILocalVectorIndex = new HmAILocalVectorIndex(),
    chunkOptions: HmAIRAGChunkOptions = new HmAIRAGChunkOptions()) {
    this.embeddings = embeddings; this.index = index; this.chunkOptions = chunkOptions;
  }

  async ingest(document: HmAIRAGDocument): Promise<number> {
    const chunks: HmAIRAGChunk[] = HmAIRAGChunker.chunk(document, this.chunkOptions);
    const vectors: number[][] = await this.embeddings.embed(
      chunks.map((chunk: HmAIRAGChunk): string => chunk.text));
    for (let index: number = 0; index < chunks.length; index++) chunks[index].embedding = vectors[index];
    this.index.removeDocument(document.id); this.index.add(chunks); return chunks.length;
  }

  async retrieve(query: string, limit: number = 5, minimumScore: number = 0): Promise<HmAIRAGSearchResult[]> {
    const vectors: number[][] = await this.embeddings.embed([query]);
    return this.index.search(vectors[0], limit, minimumScore);
  }

  async context(query: string, limit: number = 5): Promise<string> {
    const results: HmAIRAGSearchResult[] = await this.retrieve(query, limit);
    return results.map((result: HmAIRAGSearchResult, index: number): string =>
      `[${index + 1}] ${result.chunk.title}\n${result.chunk.text}`).join('\n\n');
  }

  getIndex(): HmAILocalVectorIndex { return this.index; }
}

class HmAIRAGMath {
  static normalize(vector: number[]): number[] {
    let norm: number = 0;
    for (let index: number = 0; index < vector.length; index++) norm += vector[index] * vector[index];
    norm = Math.sqrt(norm);
    return norm === 0 ? vector : vector.map((value: number): number => value / norm);
  }
  static cosine(left: number[], right: number[]): number {
    const length: number = Math.min(left.length, right.length);
    let dot: number = 0; let leftNorm: number = 0; let rightNorm: number = 0;
    for (let index: number = 0; index < length; index++) {
      dot += left[index] * right[index]; leftNorm += left[index] * left[index]; rightNorm += right[index] * right[index];
    }
    if (leftNorm === 0 || rightNorm === 0) return 0;
    return dot / (Math.sqrt(leftNorm) * Math.sqrt(rightNorm));
  }
}
