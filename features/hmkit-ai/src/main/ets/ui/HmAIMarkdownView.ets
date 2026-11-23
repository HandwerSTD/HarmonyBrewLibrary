import { HmAIChatTheme } from './HmAIChatTheme';
import { HmAIMarkdownBlock, HmAIMarkdownBlockType, HmAIMarkdownParser } from './Markdown';
import { HmAIMarkdownInlineParser, HmAIMarkdownInlineToken,
  HmAIMarkdownInlineType } from './MarkdownInline';
import { HmAISyntaxHighlighter, HmAISyntaxToken, HmAISyntaxTokenType } from './SyntaxHighlighter';

@ComponentV2
export struct HmAIMarkdownView {
  @Require @Param content: string;
  @Param theme: HmAIChatTheme = HmAIChatTheme.light();
  @Param textColor: string = '';
  @Event onOpenLink: (url: string) => void = (_url: string): void => {};

  private color(): string {
    return this.textColor.length > 0 ? this.textColor : this.theme.textColor;
  }

  @Builder
  private inlineText(content: string): void {
    Text() {
      ForEach(HmAIMarkdownInlineParser.parse(content), (token: HmAIMarkdownInlineToken): void => {
        if (token.type === HmAIMarkdownInlineType.CODE) {
          Span(token.text).fontFamily('monospace').backgroundColor(this.theme.codeBackgroundColor)
        } else if (token.type === HmAIMarkdownInlineType.BOLD) {
          Span(token.text).fontWeight(FontWeight.Bold)
        } else if (token.type === HmAIMarkdownInlineType.ITALIC || token.type === HmAIMarkdownInlineType.FORMULA) {
          Span(token.text).fontStyle(FontStyle.Italic)
        } else if (token.type === HmAIMarkdownInlineType.LINK) {
          Span(token.text).fontColor(this.theme.primaryColor).decoration({ type: TextDecorationType.Underline })
            .onClick((): void => this.onOpenLink(token.url))
        } else {
          Span(token.text)
        }
      }, (token: HmAIMarkdownInlineToken): string => token.key)
    }
    .width('100%').fontSize('15fp').lineHeight('22fp').fontColor(this.color()).copyOption(CopyOptions.LocalDevice)
  }

  @Builder
  private codeText(block: HmAIMarkdownBlock): void {
    Text() {
      ForEach(HmAISyntaxHighlighter.tokenize(block.text, block.language), (token: HmAISyntaxToken): void => {
        if (token.type === HmAISyntaxTokenType.KEYWORD) {
          Span(token.text).fontColor(this.theme.primaryColor).fontWeight(FontWeight.Medium)
        } else if (token.type === HmAISyntaxTokenType.STRING) {
          Span(token.text).fontColor(this.theme.errorColor)
        } else if (token.type === HmAISyntaxTokenType.COMMENT) {
          Span(token.text).fontColor(this.theme.secondaryTextColor).fontStyle(FontStyle.Italic)
        } else if (token.type === HmAISyntaxTokenType.NUMBER) {
          Span(token.text).fontColor('#B76E00')
        } else {
          Span(token.text).fontColor(this.theme.codeTextColor)
        }
      }, (token: HmAISyntaxToken): string => token.key)
    }
    .width('100%').fontSize('13fp').fontFamily('monospace').copyOption(CopyOptions.LocalDevice)
  }

  @Builder
  private tableView(block: HmAIMarkdownBlock): void {
    Column() {
      ForEach(block.rows, (row: string[], rowIndex: number): void => {
        Row() {
          ForEach(row, (cell: string, cellIndex: number): void => {
            Text(cell).fontSize('13fp').fontColor(this.color()).fontWeight(rowIndex === 0 ?
              FontWeight.Bold : FontWeight.Normal).padding(8).layoutWeight(1)
              .border({ width: 0.5, color: this.theme.borderColor }).copyOption(CopyOptions.LocalDevice)
          }, (_cell: string, cellIndex: number): string => `cell_${rowIndex}_${cellIndex}`)
        }.width('100%')
      }, (_row: string[], rowIndex: number): string => `row_${rowIndex}`)
    }.width('100%').border({ width: 1, color: this.theme.borderColor }).borderRadius(8)
  }

  @Builder
  private blockView(block: HmAIMarkdownBlock): void {
    if (block.type === HmAIMarkdownBlockType.HEADING) {
      Text(block.text)
        .fontSize(block.level <= 1 ? '20fp' : block.level === 2 ? '18fp' : '16fp')
        .fontWeight(FontWeight.Bold)
        .fontColor(this.color())
        .copyOption(CopyOptions.LocalDevice)
    } else if (block.type === HmAIMarkdownBlockType.CODE) {
      Column({ space: 6 }) {
        if (block.language.length > 0) {
          Text(block.language).fontSize('10fp').fontColor(this.theme.secondaryTextColor)
        }
        this.codeText(block)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(10)
      .backgroundColor(this.theme.codeBackgroundColor)
      .borderRadius(10)
    } else if (block.type === HmAIMarkdownBlockType.BULLET || block.type === HmAIMarkdownBlockType.NUMBERED) {
      Row({ space: 8 }) {
        Text(block.marker).fontSize('14fp').fontColor(this.color())
        this.inlineText(block.text)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
    } else if (block.type === HmAIMarkdownBlockType.QUOTE) {
      Text(block.text)
        .width('100%')
        .fontSize('14fp')
        .fontColor(this.theme.secondaryTextColor)
        .fontStyle(FontStyle.Italic)
        .padding({ left: 10, top: 4, bottom: 4 })
        .border({ width: { left: 3 }, color: this.theme.primaryColor })
        .copyOption(CopyOptions.LocalDevice)
    } else if (block.type === HmAIMarkdownBlockType.DIVIDER) {
      Divider().color(this.theme.borderColor)
    } else if (block.type === HmAIMarkdownBlockType.TABLE) {
      this.tableView(block)
    } else if (block.type === HmAIMarkdownBlockType.FORMULA) {
      Text(block.text).width('100%').fontSize('15fp').fontFamily('serif').fontStyle(FontStyle.Italic)
        .fontColor(this.color()).textAlign(TextAlign.Center).padding(10)
        .backgroundColor(this.theme.codeBackgroundColor).borderRadius(8).copyOption(CopyOptions.LocalDevice)
    } else {
      this.inlineText(block.text)
    }
  }

  build(): void {
    Column({ space: 8 }) {
      ForEach(HmAIMarkdownParser.parse(this.content), (block: HmAIMarkdownBlock): void => {
        this.blockView(block)
      }, (block: HmAIMarkdownBlock): string => block.key)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
