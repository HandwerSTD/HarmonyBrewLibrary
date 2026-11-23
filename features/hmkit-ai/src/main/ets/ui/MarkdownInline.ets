export enum HmAIMarkdownInlineType {
  TEXT = 'text',
  BOLD = 'bold',
  ITALIC = 'italic',
  CODE = 'code',
  LINK = 'link',
  FORMULA = 'formula'
}

export class HmAIMarkdownInlineToken {
  readonly key: string;
  readonly type: HmAIMarkdownInlineType;
  readonly text: string;
  readonly url: string;
  constructor(key: string, type: HmAIMarkdownInlineType, text: string, url: string = '') {
    this.key = key; this.type = type; this.text = text; this.url = url;
  }
}

export class HmAIMarkdownLinkPolicy {
  static isSafe(url: string): boolean {
    const normalized: string = url.trim().toLowerCase();
    return normalized.startsWith('https://') || normalized.startsWith('http://') || normalized.startsWith('mailto:');
  }
}

export class HmAIMarkdownInlineParser {
  static parse(source: string): HmAIMarkdownInlineToken[] {
    const tokens: HmAIMarkdownInlineToken[] = [];
    let plain: string = '';
    let index: number = 0;
    const flush = (): void => {
      if (plain.length === 0) return;
      tokens.push(new HmAIMarkdownInlineToken(`inline_${tokens.length}`, HmAIMarkdownInlineType.TEXT, plain));
      plain = '';
    };
    while (index < source.length) {
      if (source.startsWith('**', index)) {
        const end: number = source.indexOf('**', index + 2);
        if (end > index + 2) {
          flush(); tokens.push(new HmAIMarkdownInlineToken(`inline_${tokens.length}`,
            HmAIMarkdownInlineType.BOLD, source.substring(index + 2, end))); index = end + 2; continue;
        }
      }
      if (source.charAt(index) === '`') {
        const end: number = source.indexOf('`', index + 1);
        if (end > index + 1) {
          flush(); tokens.push(new HmAIMarkdownInlineToken(`inline_${tokens.length}`,
            HmAIMarkdownInlineType.CODE, source.substring(index + 1, end))); index = end + 1; continue;
        }
      }
      if (source.charAt(index) === '$') {
        const end: number = source.indexOf('$', index + 1);
        if (end > index + 1) {
          flush(); tokens.push(new HmAIMarkdownInlineToken(`inline_${tokens.length}`,
            HmAIMarkdownInlineType.FORMULA, source.substring(index + 1, end))); index = end + 1; continue;
        }
      }
      if (source.charAt(index) === '[') {
        const labelEnd: number = source.indexOf('](', index + 1);
        const urlEnd: number = labelEnd >= 0 ? source.indexOf(')', labelEnd + 2) : -1;
        if (labelEnd > index + 1 && urlEnd > labelEnd + 2) {
          const url: string = source.substring(labelEnd + 2, urlEnd);
          if (HmAIMarkdownLinkPolicy.isSafe(url)) {
            flush(); tokens.push(new HmAIMarkdownInlineToken(`inline_${tokens.length}`,
              HmAIMarkdownInlineType.LINK, source.substring(index + 1, labelEnd), url));
            index = urlEnd + 1; continue;
          }
        }
      }
      if (source.charAt(index) === '*' && source.charAt(index + 1) !== '*') {
        const end: number = source.indexOf('*', index + 1);
        if (end > index + 1) {
          flush(); tokens.push(new HmAIMarkdownInlineToken(`inline_${tokens.length}`,
            HmAIMarkdownInlineType.ITALIC, source.substring(index + 1, end))); index = end + 1; continue;
        }
      }
      plain += source.charAt(index); index++;
    }
    flush(); return tokens;
  }
}
