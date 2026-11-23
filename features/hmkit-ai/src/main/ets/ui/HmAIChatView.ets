import { HmAIMessage, HmAIMessageRole } from '../core/Message';
import { HmAIConversationState } from '../conversation/ConversationController';
import { HmAIChatTheme } from './HmAIChatTheme';
import { HmAIMarkdownView } from './HmAIMarkdownView';
import { HmAIContentPart, HmAIContentPartType } from '../core/Content';

@ComponentV2
export struct HmAIChatView {
  @Require @Param messages: HmAIMessage[];
  @Require @Param state: HmAIConversationState;
  @Param theme: HmAIChatTheme = HmAIChatTheme.light();
  @Param placeholder: string = '问点什么…';
  @Param emptyText: string = '今天想一起完成什么？';
  @Param emptyDescription: string = '我可以帮你分析内容、整理思路，也可以阅读图片和附件。';
  @Param assistantLabel: string = 'HMKit AI';
  @Param suggestions: string[] = [];
  @Param pendingAttachments: string[] = [];
  @Param errorText: string = '生成失败，请重试';
  @Param showSystemMessages: boolean = false;
  @Param showToolMessages: boolean = false;
  @Param maxVisibleMessages: number = 200;
  @Param showAttachmentButton: boolean = false;
  @Event onSend: (content: string) => void = (_content: string): void => {};
  @Event onCancel: () => void = (): void => {};
  @Event onRetry: () => void = (): void => {};
  @Event onRegenerate: () => void = (): void => {};
  @Event onAttachmentRequested: () => void = (): void => {};
  @Event onSuggestion: (content: string) => void = (_content: string): void => {};
  @Local draft: string = '';
  private messageScroller: Scroller = new Scroller();

  @Monitor('messages')
  private scrollToLatest(_monitor: IMonitor): void {
    setTimeout((): void => this.messageScroller.scrollEdge(Edge.Bottom), 0);
  }

  private visibleMessages(): HmAIMessage[] {
    const filtered: HmAIMessage[] = this.messages.filter((message: HmAIMessage): boolean => {
      if (!this.showSystemMessages &&
        (message.role === HmAIMessageRole.SYSTEM || message.role === HmAIMessageRole.DEVELOPER)) return false;
      if (!this.showToolMessages && message.role === HmAIMessageRole.TOOL) return false;
      return true;
    });
    const limit: number = Math.max(1, this.maxVisibleMessages);
    return filtered.length > limit ? filtered.slice(filtered.length - limit) : filtered;
  }

  private lastAssistantId(): string {
    for (let index: number = this.messages.length - 1; index >= 0; index--) {
      if (this.messages[index].role === HmAIMessageRole.ASSISTANT) return this.messages[index].id;
    }
    return '';
  }

  private submit(): void {
    const content: string = this.draft.trim();
    if (content.length === 0 || this.state === HmAIConversationState.STREAMING) return;
    this.draft = '';
    this.onSend(content);
  }

  @Builder
  private instructionBubble(message: HmAIMessage): void {
    Row() {
      Text(message.content)
        .fontSize('12fp').fontColor(this.theme.secondaryTextColor).textAlign(TextAlign.Center)
        .padding({ left: 14, right: 14, top: 8, bottom: 8 })
        .backgroundColor(this.theme.systemBubbleColor).borderRadius(16)
    }
    .width('100%').justifyContent(FlexAlign.Center)
  }

  @Builder
  private toolBubble(message: HmAIMessage): void {
    Column({ space: 5 }) {
      Text(`工具结果${message.name === undefined ? '' : ` · ${message.name}`}`)
        .fontSize('11fp').fontWeight(FontWeight.Medium).fontColor(this.theme.primaryColor)
      Text(message.content).fontSize('13fp').fontColor(this.theme.textColor).copyOption(CopyOptions.LocalDevice)
    }
    .width('100%').alignItems(HorizontalAlign.Start).padding(12)
    .backgroundColor(this.theme.systemBubbleColor).borderRadius(14)
  }

  @Builder
  private assistantContent(message: HmAIMessage): void {
    Row({ space: 10 }) {
      Text('✦')
        .width(30).height(30).fontSize('14fp').fontColor(this.theme.primaryColor)
        .textAlign(TextAlign.Center).backgroundColor(this.theme.systemBubbleColor).borderRadius(10)
      Column({ space: 7 }) {
        Text(this.assistantLabel).fontSize('11fp').fontWeight(FontWeight.Medium)
          .fontColor(this.theme.secondaryTextColor)
        if (message.content.length > 0) {
          HmAIMarkdownView({ content: message.content, theme: this.theme })
        } else if (message.toolCalls.length > 0) {
          Text(`已请求 ${message.toolCalls.length} 个工具`).fontSize('13fp').fontColor(this.theme.secondaryTextColor)
        } else {
          Row({ space: 4 }) {
            Text('●').fontSize('9fp').fontColor(this.theme.primaryColor)
            Text('●').fontSize('9fp').fontColor(this.theme.primaryColor).opacity(0.7)
            Text('●').fontSize('9fp').fontColor(this.theme.primaryColor).opacity(0.4)
          }
        }
        if (message.id === this.lastAssistantId() && this.state === HmAIConversationState.IDLE) {
          Button('↻  重新生成', { type: ButtonType.Normal })
            .id('hmkit_ai_regenerate').height(30).fontSize('11fp')
            .fontColor(this.theme.secondaryTextColor).backgroundColor(Color.Transparent)
            .padding({ left: 0, right: 8 }).onClick((): void => this.onRegenerate())
        }
      }
      .layoutWeight(1).alignItems(HorizontalAlign.Start)
    }
    .width('100%').alignItems(VerticalAlign.Top)
  }

  @Builder
  private userContent(message: HmAIMessage): void {
    Column({ space: 9 }) {
      ForEach(message.parts.filter((part: HmAIContentPart): boolean => part.type !== HmAIContentPartType.TEXT),
        (part: HmAIContentPart, index: number): void => {
          if (part.type === HmAIContentPartType.IMAGE) {
            Image(part.dataUrl()).width(196).height(140).objectFit(ImageFit.Cover).borderRadius(14)
          } else {
            Row({ space: 7 }) {
              Text(part.type === HmAIContentPartType.AUDIO ? '♫' : '⌁').fontSize('14fp')
              Text(part.fileName || part.mimeType).fontSize('12fp').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .padding({ left: 10, right: 10, top: 7, bottom: 7 })
            .backgroundColor('#22FFFFFF').borderRadius(10)
          }
        }, (_part: HmAIContentPart, index: number): string => `${message.id}_part_${index}`)
      if (message.content.length > 0) {
        Text(message.content).fontSize('15fp').fontColor(this.theme.userTextColor).lineHeight('22fp')
          .copyOption(CopyOptions.LocalDevice)
      }
    }
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 15, right: 15, top: 11, bottom: 11 })
    .constraintSize({ maxWidth: '78%' })
    .backgroundColor(this.theme.userBubbleColor).borderRadius(this.theme.bubbleRadius)
  }

  @Builder
  private messageBubble(message: HmAIMessage): void {
    if (message.role === HmAIMessageRole.SYSTEM || message.role === HmAIMessageRole.DEVELOPER) {
      this.instructionBubble(message)
    } else if (message.role === HmAIMessageRole.TOOL) {
      this.toolBubble(message)
    } else if (message.role === HmAIMessageRole.USER) {
      Row() { this.userContent(message) }
        .width('100%').justifyContent(FlexAlign.End).accessibilityText(`用户：${message.content}`)
    } else {
      Row() { this.assistantContent(message) }
        .width('100%').justifyContent(FlexAlign.Start).accessibilityText(`助手：${message.content}`)
    }
  }

  @Builder
  private emptyState(): void {
    Column({ space: 14 }) {
      Text('✦').width(52).height(52).fontSize('24fp').fontColor('#FFFFFF')
        .textAlign(TextAlign.Center).backgroundColor(this.theme.primaryColor).borderRadius(17)
      Text(this.emptyText).fontSize('24fp').fontWeight(FontWeight.Bold).fontColor(this.theme.textColor)
        .textAlign(TextAlign.Center)
      Text(this.emptyDescription).fontSize('14fp').lineHeight('21fp').fontColor(this.theme.secondaryTextColor)
        .textAlign(TextAlign.Center).width('86%')
      if (this.suggestions.length > 0) {
        Column({ space: 8 }) {
          ForEach(this.suggestions.slice(0, 3), (suggestion: string): void => {
            Button({ type: ButtonType.Normal }) {
              Row({ space: 10 }) {
                Text(suggestion).fontSize('13fp').fontColor(this.theme.textColor).layoutWeight(1)
                  .textAlign(TextAlign.Start).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                Text('→').fontSize('14fp').fontColor(this.theme.primaryColor)
              }.width('100%')
            }
            .width('100%').height(46).padding({ left: 14, right: 14 })
            .backgroundColor(this.theme.surfaceColor).borderRadius(14)
            .border({ width: 1, color: this.theme.borderColor })
            .onClick((): void => this.onSuggestion(suggestion))
          }, (suggestion: string): string => suggestion)
        }.width('88%').margin({ top: 6 })
      }
    }
    .layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
  }

  @Builder
  private composer(): void {
    Column({ space: 8 }) {
      if (this.pendingAttachments.length > 0) {
        Scroll() {
          Row({ space: 7 }) {
            ForEach(this.pendingAttachments, (label: string): void => {
              Row({ space: 6 }) {
                Text('⌁').fontSize('12fp').fontColor(this.theme.primaryColor)
                Text(label).fontSize('11fp').fontColor(this.theme.textColor).maxLines(1)
              }
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .backgroundColor(this.theme.systemBubbleColor).borderRadius(10)
            }, (label: string): string => label)
          }
        }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%')
      }
      Row({ space: 7 }) {
        if (this.showAttachmentButton) {
          Button('+', { type: ButtonType.Circle })
            .id('hmkit_ai_attach').width(42).height(42).fontSize('21fp')
            .fontColor(this.theme.primaryColor).backgroundColor(this.theme.systemBubbleColor)
            .onClick((): void => this.onAttachmentRequested())
        }
        TextInput({ placeholder: this.placeholder, text: this.draft })
          .id('hmkit_ai_input').layoutWeight(1).height(44).fontSize('15fp')
          .fontColor(this.theme.textColor).placeholderColor(this.theme.secondaryTextColor)
          .backgroundColor(Color.Transparent).enabled(this.state !== HmAIConversationState.STREAMING)
          .onChange((value: string): void => { this.draft = value; }).onSubmit((): void => this.submit())
        if (this.state === HmAIConversationState.STREAMING) {
          Button('■', { type: ButtonType.Circle })
            .id('hmkit_ai_cancel').width(42).height(42).fontSize('13fp')
            .fontColor('#FFFFFF').backgroundColor(this.theme.errorColor).onClick((): void => this.onCancel())
        } else {
          Button('↑', { type: ButtonType.Circle })
            .id('hmkit_ai_send').width(42).height(42).fontSize('20fp').fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF').enabled(this.draft.trim().length > 0)
            .backgroundColor(this.theme.primaryColor).onClick((): void => this.submit())
        }
      }
      .width('100%').padding({ left: 8, right: 8, top: 6, bottom: 6 })
      .backgroundColor(this.theme.surfaceColor).borderRadius(24)
      .border({ width: 1, color: this.theme.borderColor })
      .shadow({ radius: 18, color: '#14000000', offsetX: 0, offsetY: 6 })
      Text('AI 生成内容可能有误，请核对重要信息')
        .fontSize('10fp').fontColor(this.theme.secondaryTextColor).textAlign(TextAlign.Center).width('100%')
    }
    .width('100%').padding({ left: 14, right: 14, top: 8, bottom: 10 })
  }

  build(): void {
    Column() {
      if (this.visibleMessages().length === 0) {
        this.emptyState()
      } else {
        List({ space: 20, scroller: this.messageScroller }) {
          ForEach(this.visibleMessages(), (message: HmAIMessage): void => {
            ListItem() { this.messageBubble(message) }
          }, (message: HmAIMessage): string => message.id)
        }
        .id('hmkit_ai_message_list').layoutWeight(1).width('100%')
        .padding({ left: 18, right: 18, top: 18, bottom: 16 }).scrollBar(BarState.Auto)
      }
      if (this.state === HmAIConversationState.ERROR) {
        Row({ space: 10 }) {
          Text('!').width(26).height(26).fontSize('13fp').fontWeight(FontWeight.Bold)
            .fontColor(this.theme.errorColor).textAlign(TextAlign.Center)
            .backgroundColor(this.theme.systemBubbleColor).borderRadius(9)
          Text(this.errorText).fontSize('13fp').fontColor(this.theme.textColor).layoutWeight(1)
          Button('重试', { type: ButtonType.Normal }).id('hmkit_ai_retry').height(32).fontSize('12fp')
            .fontColor(this.theme.errorColor).backgroundColor(Color.Transparent).onClick((): void => this.onRetry())
        }
        .width('100%').padding({ left: 16, right: 16, top: 10, bottom: 10 })
        .backgroundColor(this.theme.surfaceColor).borderRadius(14).margin({ left: 14, right: 14 })
      }
      this.composer()
    }
    .width('100%').height('100%').backgroundColor(this.theme.backgroundColor)
  }
}
