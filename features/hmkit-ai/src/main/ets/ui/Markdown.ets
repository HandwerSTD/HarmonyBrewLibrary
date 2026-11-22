export enum HmAIMarkdownBlockType {
  PARAGRAPH = 'paragraph',
  HEADING = 'heading',
  BULLET = 'bullet',
  NUMBERED = 'numbered',
  QUOTE = 'quote',
  CODE = 'code',
  DIVIDER = 'divider',
  TABLE = 'table',
  FORMULA = 'formula'
}

export class HmAIMarkdownBlock {
  readonly key: string;
  readonly type: HmAIMarkdownBlockType;
  readonly text: string;
  readonly level: number;
  readonly language: string;
  readonly marker: string;
  readonly rows: string[][];

  constructor(key: string, type: HmAIMarkdownBlockType, text: string, level: number = 0,
    language: string = '', marker: string = '', rows: string[][] = []) {
    this.key = key;
    this.type = type;
    this.text = text;
    this.level = level;
    this.language = language;
    this.marker = marker;
    this.rows = rows;
  }
}

export class HmAIMarkdownParser {
  static parse(source: string): HmAIMarkdownBlock[] {
    const normalized: string = source.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
    const lines: string[] = normalized.split('\n');
    const blocks: HmAIMarkdownBlock[] = [];
    let paragraph: string[] = [];
    let code: string[] = [];
    let codeLanguage: string = '';
    let inCode: boolean = false;

    const flushParagraph = (): void => {
      if (paragraph.length === 0) return;
      blocks.push(new HmAIMarkdownBlock(`block_${blocks.length}`, HmAIMarkdownBlockType.PARAGRAPH,
        paragraph.join('\n')));
      paragraph = [];
    };
    const flushCode = (): void => {
      blocks.push(new HmAIMarkdownBlock(`block_${blocks.length}`, HmAIMarkdownBlockType.CODE,
        code.join('\n'), 0, codeLanguage));
      code = [];
      codeLanguage = '';
    };

    for (let index: number = 0; index < lines.length; index++) {
      const line: string = lines[index];
      if (line.startsWith('```')) {
        if (inCode) {
          flushCode();
          inCode = false;
        } else {
          flushParagraph();
          codeLanguage = line.substring(3).trim();
          inCode = true;
        }
        continue;
      }
      if (inCode) {
        code.push(line);
        continue;
      }
      if (line.trim().length === 0) {
        flushParagraph();
        continue;
      }
      if (line.trim().startsWith('$$')) {
        flushParagraph();
        let formula: string = line.trim().substring(2);
        if (formula.endsWith('$$')) formula = formula.substring(0, formula.length - 2);
        else {
          index++;
          while (index < lines.length && !lines[index].trim().endsWith('$$')) {
            formula += `${formula.length > 0 ? '\n' : ''}${lines[index]}`; index++;
          }
          if (index < lines.length) formula += `${formula.length > 0 ? '\n' : ''}${lines[index].trim().replace(/\$\$$/, '')}`;
        }
        blocks.push(new HmAIMarkdownBlock(`block_${blocks.length}`, HmAIMarkdownBlockType.FORMULA,
          formula.trim()));
        continue;
      }
      if (line.includes('|') && index + 1 < lines.length && HmAIMarkdownParser.isTableSeparator(lines[index + 1])) {
        flushParagraph();
        const rows: string[][] = [HmAIMarkdownParser.tableCells(line)];
        index += 2;
        while (index < lines.length && lines[index].includes('|') && lines[index].trim().length > 0) {
          rows.push(HmAIMarkdownParser.tableCells(lines[index])); index++;
        }
        index--;
        blocks.push(new HmAIMarkdownBlock(`block_${blocks.length}`, HmAIMarkdownBlockType.TABLE, '', 0, '', '', rows));
        continue;
      }
      const headingLevel: number = HmAIMarkdownParser.headingLevel(line);
      if (headingLevel > 0) {
        flushParagraph();
        blocks.push(new HmAIMarkdownBlock(`block_${blocks.length}`, HmAIMarkdownBlockType.HEADING,
          line.substring(headingLevel + 1), headingLevel));
        continue;
      }
      if (line === '---' || line === '***' || line === '___') {
        flushParagraph();
        blocks.push(new HmAIMarkdownBlock(`block_${blocks.length}`, HmAIMarkdownBlockType.DIVIDER, ''));
        continue;
      }
      if (line.startsWith('> ')) {
        flushParagraph();
        blocks.push(new HmAIMarkdownBlock(`block_${blocks.length}`, HmAIMarkdownBlockType.QUOTE,
          line.substring(2)));
        continue;
      }
      if (line.startsWith('- ') || line.startsWith('* ') || line.startsWith('+ ')) {
        flushParagraph();
        blocks.push(new HmAIMarkdownBlock(`block_${blocks.length}`, HmAIMarkdownBlockType.BULLET,
          line.substring(2), 0, '', '•'));
        continue;
      }
      const numberedMarker: string = HmAIMarkdownParser.numberedMarker(line);
      if (numberedMarker.length > 0) {
        flushParagraph();
        blocks.push(new HmAIMarkdownBlock(`block_${blocks.length}`, HmAIMarkdownBlockType.NUMBERED,
          line.substring(numberedMarker.length + 1), 0, '', numberedMarker));
        continue;
      }
      paragraph.push(line);
    }
    flushParagraph();
    if (inCode) flushCode();
    return blocks;
  }

  private static headingLevel(line: string): number {
    let level: number = 0;
    while (level < line.length && level < 6 && line.charAt(level) === '#') level++;
    return level > 0 && line.charAt(level) === ' ' ? level : 0;
  }

  private static numberedMarker(line: string): string {
    let index: number = 0;
    while (index < line.length && line.charAt(index) >= '0' && line.charAt(index) <= '9') index++;
    if (index === 0 || index + 1 >= line.length) return '';
    const separator: string = line.charAt(index);
    if ((separator === '.' || separator === ')') && line.charAt(index + 1) === ' ') {
      return line.substring(0, index + 1);
    }
    return '';
  }

  private static isTableSeparator(line: string): boolean {
    const cells: string[] = HmAIMarkdownParser.tableCells(line);
    return cells.length > 0 && cells.every((cell: string): boolean => /^:?-{3,}:?$/.test(cell.trim()));
  }

  private static tableCells(line: string): string[] {
    let value: string = line.trim();
    if (value.startsWith('|')) value = value.substring(1);
    if (value.endsWith('|')) value = value.substring(0, value.length - 1);
    return value.split('|').map((cell: string): string => cell.trim());
  }
}
