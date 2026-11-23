export type HmAISSEDataHandler = (data: string) => void;

export class HmAISSEDecoder {
  private buffer: string = '';
  private dataLines: string[] = [];
  private readonly onData: HmAISSEDataHandler;

  constructor(onData: HmAISSEDataHandler) {
    this.onData = onData;
  }

  push(text: string): void {
    if (text.length === 0) return;
    this.buffer += text;
    this.consumeLines(false);
  }

  finish(): void {
    this.consumeLines(true);
    if (this.dataLines.length > 0) this.dispatch();
  }

  private consumeLines(flush: boolean): void {
    while (this.buffer.length > 0) {
      const lineBreak: number = this.findLineBreak();
      if (lineBreak < 0) {
        if (flush) {
          const finalLine: string = this.buffer;
          this.buffer = '';
          this.consumeLine(finalLine);
        }
        return;
      }
      if (this.buffer.charAt(lineBreak) === '\r' && lineBreak === this.buffer.length - 1 && !flush) return;
      const line: string = this.buffer.substring(0, lineBreak);
      let consumed: number = lineBreak + 1;
      if (this.buffer.charAt(lineBreak) === '\r' && this.buffer.charAt(lineBreak + 1) === '\n') consumed++;
      this.buffer = this.buffer.substring(consumed);
      this.consumeLine(line);
    }
  }

  private findLineBreak(): number {
    for (let index: number = 0; index < this.buffer.length; index++) {
      const character: string = this.buffer.charAt(index);
      if (character === '\n' || character === '\r') return index;
    }
    return -1;
  }

  private consumeLine(line: string): void {
    if (line.length === 0) {
      if (this.dataLines.length > 0) this.dispatch();
      return;
    }
    if (line.startsWith(':') || !line.startsWith('data:')) return;
    let value: string = line.substring(5);
    if (value.startsWith(' ')) value = value.substring(1);
    this.dataLines.push(value);
  }

  private dispatch(): void {
    const data: string = this.dataLines.join('\n');
    this.dataLines = [];
    this.onData(data);
  }
}
