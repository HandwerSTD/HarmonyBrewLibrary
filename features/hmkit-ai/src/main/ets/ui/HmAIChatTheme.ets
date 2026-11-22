export interface HmAIChatThemeOptions {
  backgroundColor?: string;
  surfaceColor?: string;
  userBubbleColor?: string;
  assistantBubbleColor?: string;
  systemBubbleColor?: string;
  primaryColor?: string;
  textColor?: string;
  secondaryTextColor?: string;
  userTextColor?: string;
  borderColor?: string;
  errorColor?: string;
  codeBackgroundColor?: string;
  codeTextColor?: string;
  bubbleRadius?: number;
}

export class HmAIChatTheme {
  readonly backgroundColor: string;
  readonly surfaceColor: string;
  readonly userBubbleColor: string;
  readonly assistantBubbleColor: string;
  readonly systemBubbleColor: string;
  readonly primaryColor: string;
  readonly textColor: string;
  readonly secondaryTextColor: string;
  readonly userTextColor: string;
  readonly borderColor: string;
  readonly errorColor: string;
  readonly codeBackgroundColor: string;
  readonly codeTextColor: string;
  readonly bubbleRadius: number;

  constructor(options: HmAIChatThemeOptions = {}) {
    this.backgroundColor = options.backgroundColor ?? '#F7F7FA';
    this.surfaceColor = options.surfaceColor ?? '#FFFFFF';
    this.userBubbleColor = options.userBubbleColor ?? '#5B5BD6';
    this.assistantBubbleColor = options.assistantBubbleColor ?? '#FFFFFF';
    this.systemBubbleColor = options.systemBubbleColor ?? '#F0EFFA';
    this.primaryColor = options.primaryColor ?? '#5B5BD6';
    this.textColor = options.textColor ?? '#18181F';
    this.secondaryTextColor = options.secondaryTextColor ?? '#71717A';
    this.userTextColor = options.userTextColor ?? '#FFFFFF';
    this.borderColor = options.borderColor ?? '#E7E7ED';
    this.errorColor = options.errorColor ?? '#D14343';
    this.codeBackgroundColor = options.codeBackgroundColor ?? '#1A1A24';
    this.codeTextColor = options.codeTextColor ?? '#ECECF3';
    this.bubbleRadius = options.bubbleRadius ?? 20;
  }

  static light(): HmAIChatTheme {
    return new HmAIChatTheme();
  }

  static dark(): HmAIChatTheme {
    return new HmAIChatTheme({
      'backgroundColor': '#111116',
      'surfaceColor': '#1B1B22',
      'userBubbleColor': '#6C63E8',
      'assistantBubbleColor': '#1B1B22',
      'systemBubbleColor': '#292835',
      'primaryColor': '#8B83FF',
      'textColor': '#F5F5F7',
      'secondaryTextColor': '#A0A0AC',
      'userTextColor': '#FFFFFF',
      'borderColor': '#30303A',
      'errorColor': '#FF8C8C',
      'codeBackgroundColor': '#0D0D12',
      'codeTextColor': '#ECECF3'
    });
  }
}
