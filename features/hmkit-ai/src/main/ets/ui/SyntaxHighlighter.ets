export enum HmAISyntaxTokenType {
  PLAIN = 'plain',
  KEYWORD = 'keyword',
  STRING = 'string',
  NUMBER = 'number',
  COMMENT = 'comment'
}

export class HmAISyntaxToken {
  readonly key: string;
  readonly type: HmAISyntaxTokenType;
  readonly text: string;
  constructor(key: string, type: HmAISyntaxTokenType, text: string) { this.key = key; this.type = type; this.text = text; }
}

export class HmAISyntaxHighlighter {
  static tokenize(source: string, language: string): HmAISyntaxToken[] {
    const keywords: string[] = HmAISyntaxHighlighter.keywords(language.toLowerCase());
    const tokens: HmAISyntaxToken[] = [];
    let index: number = 0;
    while (index < source.length) {
      const char: string = source.charAt(index);
      if ((char === '/' && source.charAt(index + 1) === '/') || char === '#') {
        const end: number = source.indexOf('\n', index);
        const stop: number = end < 0 ? source.length : end;
        tokens.push(new HmAISyntaxToken(`syntax_${tokens.length}`, HmAISyntaxTokenType.COMMENT,
          source.substring(index, stop))); index = stop; continue;
      }
      if (char === '"' || char === "'") {
        let end: number = index + 1;
        while (end < source.length) {
          if (source.charAt(end) === char && source.charAt(end - 1) !== '\\') { end++; break; }
          end++;
        }
        tokens.push(new HmAISyntaxToken(`syntax_${tokens.length}`, HmAISyntaxTokenType.STRING,
          source.substring(index, end))); index = end; continue;
      }
      if (char >= '0' && char <= '9') {
        let end: number = index + 1;
        while (end < source.length && /[0-9._]/.test(source.charAt(end))) end++;
        tokens.push(new HmAISyntaxToken(`syntax_${tokens.length}`, HmAISyntaxTokenType.NUMBER,
          source.substring(index, end))); index = end; continue;
      }
      if (/[A-Za-z_]/.test(char)) {
        let end: number = index + 1;
        while (end < source.length && /[A-Za-z0-9_]/.test(source.charAt(end))) end++;
        const word: string = source.substring(index, end);
        tokens.push(new HmAISyntaxToken(`syntax_${tokens.length}`, keywords.includes(word) ?
          HmAISyntaxTokenType.KEYWORD : HmAISyntaxTokenType.PLAIN, word)); index = end; continue;
      }
      tokens.push(new HmAISyntaxToken(`syntax_${tokens.length}`, HmAISyntaxTokenType.PLAIN, char)); index++;
    }
    return tokens;
  }

  private static keywords(language: string): string[] {
    if (language === 'python' || language === 'py') return ['def', 'class', 'if', 'else', 'elif', 'for', 'while',
      'return', 'import', 'from', 'async', 'await', 'True', 'False', 'None'];
    if (language === 'json') return ['true', 'false', 'null'];
    if (language === 'shell' || language === 'bash' || language === 'sh') return ['if', 'then', 'else', 'fi',
      'for', 'do', 'done', 'case', 'esac', 'function'];
    return ['const', 'let', 'var', 'class', 'interface', 'enum', 'function', 'return', 'if', 'else', 'for',
      'while', 'async', 'await', 'import', 'export', 'new', 'true', 'false', 'undefined'];
  }
}
