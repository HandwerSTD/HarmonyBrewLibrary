/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { SymbolGlyphModifier, TextModifier } from '@kit.ArkUI';
import { CommonConstants } from '@ohos/common';
import { BrewCommandLine, BrewCommandState, BrewCommandStatus, brewCommandStatusText } from '../model/BrewCommandModels';

/** 日志字体。设备自带的等宽字体；取不到时系统回退到默认字体 */
const LOG_FONT_FAMILY: string = 'monospace';

/** 终端观感：整页黑底，正文白字，stderr 行用 warning 色 */
const SHEET_BACKGROUND: ResourceColor = Color.Black;
const LOG_TEXT_COLOR: ResourceColor = Color.White;

/** 日志行高倍数。等宽字体配 1.5 倍行高，长输出更容易按行扫读 */
const LOG_LINE_HEIGHT: number = 1.5;

/** 标题栏图标尺寸 */
const MENU_ICON_SIZE: number = 20;

/**
 * brew 命令执行 Sheet 的内容组件。「我的 - 待更新」页与包详情页各绑一份，内容共用本组件。
 *
 * 形态与「我的 - 设置」同源：标题栏由 `Navigation` 提供（`title` 给标题，`menus` 给操作），
 * 两个操作放在标题栏的菜单里 —— trash 结束命令、xmark 关闭 Sheet。因此 Sheet 自身不显示关闭
 * 图标（`SheetOptions.showClose` 为 false），底部也没有按钮行；关掉 Sheet 不影响命令执行，
 * 重新打开看到的是完整输出。
 *
 * 内容区是一整块等宽文本（`Text` + `Span`）：第一行是真正跑的命令行，后面是输出行；
 * 黑底白字，stderr 行用 warning 色，命令结束之后把状态文案追加在文本末尾。
 * 整块文本放在 `Scroll` 里，可以随时回看历史输出。
 *
 * 入参用 `@ObjectLink` 而不是 `@Prop`：`@Prop` 对对象做深拷贝，日志每 200ms 增一批行，
 * 1000 行每 200ms 复制一次不可接受。三个回调由页面接到 `BrewCommandRunner` 与 Sheet 的开关上 ——
 * 本组件不碰单例，命令状态与命令生命周期都留在页面与 `BrewCommandRunner` 那一侧。
 */
@Component
export struct BrewCommandSheet {
  @ObjectLink @Watch('onLogChanged') state: BrewCommandState;
  onInterrupt: () => void = () => {};
  onForceKill: () => void = () => {};
  onClose: () => void = () => {};

  private scroller: Scroller = new Scroller();
  /** 用户是否还停在日志底部。离开底部后停止跟随，滚回底部恢复 */
  @State private followTail: boolean = true;
  /** 是否已经排了一次跟随滚动，避免一批日志排出一堆定时器 */
  private scrollPending: boolean = false;

  private isRunning(): boolean {
    return this.state.status === BrewCommandStatus.RUNNING;
  }

  /** 中断已发出但还没到宽限期：结束按钮禁用 */
  private inGracePeriod(): boolean {
    return this.isRunning() && this.state.interruptSentAt > 0 && !this.state.forceKillReady;
  }

  /** 宽限期已过且还没强杀：这一次点击发的是 SIGTERM / SIGKILL */
  private canForceKill(): boolean {
    return this.isRunning() && !this.state.killSent && this.state.forceKillReady;
  }

  /** 结束按钮的无障碍文案与当前动作一致：宽限期之前是中断，之后是强制终止 */
  private stopLabel(): ResourceStr {
    return this.canForceKill() ?
      $r('app.string.brew_action_force_kill') : $r('app.string.brew_action_interrupt');
  }

  /** 标题栏菜单：结束命令（trash）+ 关闭（xmark） */
  private titleMenus(): NavigationMenuItem[] {
    const stop: NavigationMenuItem = {
      value: this.stopLabel(),
      symbolIcon: new SymbolGlyphModifier($r('sys.symbol.trash'))
        .fontColor([LOG_TEXT_COLOR])
        .fontSize(MENU_ICON_SIZE),
      isEnabled: this.isRunning() && !this.inGracePeriod(),
      action: () => {
        // 两次点击走同一条升级链：第一次发 SIGINT，宽限期之后再点才升级成 SIGTERM / SIGKILL
        if (this.canForceKill()) {
          this.onForceKill();
        } else {
          this.onInterrupt();
        }
      },
    };
    const close: NavigationMenuItem = {
      value: $r('app.string.brew_action_close'),
      symbolIcon: new SymbolGlyphModifier($r('sys.symbol.xmark'))
        .fontColor([LOG_TEXT_COLOR])
        .fontSize(MENU_ICON_SIZE),
      action: () => {
        this.onClose();
      },
    };
    const menus: NavigationMenuItem[] = [stop, close];
    return menus;
  }

  /** 标题栏样式：与内容区同一块黑底，标题用等宽白字 */
  private titleOptions(): NavigationTitleOptions {
    const options: NavigationTitleOptions = {
      backgroundColor: SHEET_BACKGROUND,
      mainTitleModifier: new TextModifier().fontColor(LOG_TEXT_COLOR).fontFamily(LOG_FONT_FAMILY),
    };
    return options;
  }

  private onLogChanged(): void {
    if (!this.followTail || this.scrollPending) {
      return;
    }
    // 一批日志只安排一次滚动：一次 200ms 轮询可能落地上百行，逐行排定时器会把滚动任务堆起来
    this.scrollPending = true;
    setTimeout(() => {
      this.scrollPending = false;
      if (this.followTail) {
        this.scroller.scrollEdge(Edge.Bottom);
      }
    }, 0);
  }

  /**
   * 日志文本。整块日志是一个 `Text`：第一行是真正跑的命令行，后面每行一个 `Span`，
   * stderr 行单独给 warning 色，命令结束之后在末尾追加状态行（如 `[已完成 退出码 0]`、`[已中断]`）。
   */
  @Builder
  LogText() {
    Text() {
      // 第一行是命令行，让用户确认真跑的是哪条命令；空一行与输出分开
      Span(`$ ${this.state.command}\n\n`)
        .fontColor(LOG_TEXT_COLOR)
      if (this.state.omittedLines > 0) {
        Span($r('app.string.brew_cmd_omitted_lines', this.state.omittedLines))
          .fontColor($r('sys.color.font_tertiary'))
        Span('\n')
      }
      // 键用「行在日志里的总序号」（当前下标 + 已省略行数）而不是当前下标。
      // 超出上限裁剪时最早的行被丢弃，同样的下标会指向不同的内容，
      // 用当前下标做键会让已渲染的行保留旧文本，看起来像日志不更新。
      ForEach(this.state.lines, (line: BrewCommandLine, index: number) => {
        Span(`${line.text}\n`)
          .fontColor(line.stderr ? $r('sys.color.warning') : LOG_TEXT_COLOR)
      }, (line: BrewCommandLine, index: number) => `${this.state.omittedLines + index}`)
      if (this.state.status !== BrewCommandStatus.IDLE) {
        Span('\n')
        Span(brewCommandStatusText(this.state))
          .fontColor(LOG_TEXT_COLOR)
      }
    }
    .fontFamily(LOG_FONT_FAMILY)
    .fontSize($r('sys.float.Body_S'))
    .fontColor(LOG_TEXT_COLOR)
    // .lineHeight(LOG_LINE_HEIGHT)
    .width(CommonConstants.FULL_PERCENT)
    .textAlign(TextAlign.Start)
    .padding($r('sys.float.padding_level6'))
  }

  build() {
    Navigation() {
      Scroll(this.scroller) {
        this.LogText()
      }
      .width(CommonConstants.FULL_PERCENT)
      .height(CommonConstants.FULL_PERCENT)
      .align(Alignment.TopStart)
      .scrollBar(BarState.Auto)
      .onDidScroll((xOffset: number, yOffset: number, scrollState: ScrollState) => {
        // 只在用户自己滚动时改跟随状态：程序化滚到底之后 `isAtEnd()` 为真，跟随状态保持不变
        if (scrollState === ScrollState.Scroll) {
          this.followTail = this.scroller.isAtEnd();
        }
      })
    }
    .title(this.state.title, this.titleOptions())
    .menus(this.titleMenus())
    .hideBackButton(true)
    .titleMode(NavigationTitleMode.Mini)
    .mode(NavigationMode.Stack)
    .backgroundColor(SHEET_BACKGROUND)
    .width(CommonConstants.FULL_PERCENT)
    .height(CommonConstants.FULL_PERCENT)
  }
}
