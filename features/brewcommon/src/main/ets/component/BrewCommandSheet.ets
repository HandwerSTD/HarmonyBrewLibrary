/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { CommonConstants } from '@ohos/common';
import {
  BrewCommandLine,
  BrewCommandState,
  BrewCommandStatus,
} from '../model/BrewCommandModels';

/** 底部按钮高度。与「我的」页及其它二级页的操作按钮同高 */
const ACTION_BUTTON_HEIGHT: number = 32;

/**
 * brew 命令执行 Sheet 的内容组件。「我的 - 待更新」页与包详情页各绑一份，内容共用本组件。
 *
 * 入参用 `@ObjectLink` 而不是 `@Prop`：`@Prop` 对对象做深拷贝，日志每 200ms 增一批行，
 * 1000 行每 200ms 复制一次不可接受。三个回调由页面接到 `BrewCommandRunner` 与 Sheet 的开关上 ——
 * 本组件不碰单例，命令状态与命令生命周期都留在页面与 `BrewCommandRunner` 那一侧。
 *
 * Sheet 可随时关闭：命令状态在 `BrewCommandRunner` 单例里，关掉不影响命令执行，
 * 重新打开看到的是完整输出。
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

  /** 状态标签文案。IDLE 不显示标签（还没执行过命令，不该显示任何状态） */
  private statusText(): ResourceStr {
    const state: BrewCommandState = this.state;
    if (state.status === BrewCommandStatus.RUNNING) {
      return state.interruptSentAt > 0 ?
        $r('app.string.brew_cmd_status_interrupting') : $r('app.string.brew_cmd_status_running');
    }
    if (state.status === BrewCommandStatus.DONE) {
      return $r('app.string.brew_cmd_status_done');
    }
    if (state.status === BrewCommandStatus.INTERRUPTED) {
      return $r('app.string.brew_cmd_status_interrupted');
    }
    if (state.status === BrewCommandStatus.TIMEOUT) {
      return $r('app.string.brew_cmd_status_timeout');
    }
    if (state.status === BrewCommandStatus.FAILED) {
      return $r('app.string.brew_cmd_status_failed');
    }
    return '';
  }

  private isRunning(): boolean {
    return this.state.status === BrewCommandStatus.RUNNING;
  }

  /**
   * 中断已发出但还没到宽限期：按钮禁用。
   *
   * 宽限期到点由 `forceKillReady` 承载（runner 在定时回调里置真），所以这里只判断
   * 「发出过中断、且还没到点」：它只用于禁用「中断」按钮，命令静默时也不会停在旧状态。
   */
  private inGracePeriod(): boolean {
    return this.isRunning() && this.state.interruptSentAt > 0 && !this.state.forceKillReady;
  }

  /** 宽限期已过且仍在运行：底部按钮从「中断」切到「强制终止」 */
  private canForceKill(): boolean {
    return this.isRunning() && !this.state.killSent && this.state.forceKillReady;
  }

  /**
   * 判断用户是否停在底部。
   *
   * 用可见的末条行号而不是「滚动偏移 + 视口高度」比较：偏移是像素、内容高度与区域高度是 vp，
   * 三者混算需要额外的换算，而行号比较没有单位问题。
   */
  private updateFollowTail(lastVisible: number): void {
    const total: number = this.state.lines.length + (this.state.omittedLines > 0 ? 1 : 0);
    this.followTail = total === 0 || lastVisible >= total - 1;
  }

  private scrollToTail(): void {
    this.scroller.scrollEdge(Edge.Bottom);
  }

  @Builder
  LogLineBuilder(line: BrewCommandLine) {
    // stdout 用主色、stderr 用次色：两路在设备上都是 brew 的原始输出，
    // 颜色是唯一能一眼分辨「这行是进度」与「这行是错误」的办法
    Text(line.text)
      .fontSize($r('sys.float.Body_S'))
      .fontColor(line.stderr ? $r('sys.color.font_secondary') : $r('sys.color.font_primary'))
      .width(CommonConstants.FULL_PERCENT)
      // 日志行不限制行数：brew 的错误信息常带很长的路径与依赖列表，截断等于丢掉排错信息
  }

  /**
   * 新一批行落地后的跟随滚动。
   *
   * 用 `@Watch` 而不是 `onDidScroll`：后者只在用户滚动时触发，内容变高而用户没动时它一次都不响，
   * 跟随就断了。这里监听 `state` 的属性变化，并把滚动推到下一轮：
   * 回调触发时布局还没做完，此刻读到的 `contentSize` 还是旧值。
   */
  private onLogChanged(): void {
    if (!this.followTail || this.scrollPending) {
      return;
    }
    // 一批日志只安排一次滚动：一次 200ms 轮询可能落地上百行，逐行排定时器会把滚动任务堆起来
    this.scrollPending = true;
    setTimeout(() => {
      this.scrollPending = false;
      if (this.followTail) {
        this.scrollToTail();
      }
    }, 0);
  }

  @Builder
  ActionBuilder() {
    Row() {
      if (this.isRunning()) {
        if (this.canForceKill()) {
          Button($r('app.string.brew_action_force_kill'))
            .height(ACTION_BUTTON_HEIGHT)
            .fontSize($r('sys.float.Body_M'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .backgroundColor($r('sys.color.comp_background_tertiary'))
            .borderRadius($r('sys.float.corner_radius_level4'))
            .padding({ left: $r('sys.float.padding_level6'), right: $r('sys.float.padding_level6') })
            .onClick(() => {
              this.onForceKill();
            })
        } else {
          Button($r('app.string.brew_action_interrupt'))
            .height(ACTION_BUTTON_HEIGHT)
            .fontSize($r('sys.float.Body_M'))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .backgroundColor($r('sys.color.comp_background_tertiary'))
            .borderRadius($r('sys.float.corner_radius_level4'))
            .padding({ left: $r('sys.float.padding_level6'), right: $r('sys.float.padding_level6') })
            .enabled(!this.inGracePeriod())
            .onClick(() => {
              this.onInterrupt();
            })
        }
      } else {
        Button($r('app.string.brew_action_close'))
          .height(ACTION_BUTTON_HEIGHT)
          .fontSize($r('sys.float.Body_M'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          .borderRadius($r('sys.float.corner_radius_level4'))
          .padding({ left: $r('sys.float.padding_level6'), right: $r('sys.float.padding_level6') })
          .onClick(() => {
            this.onClose();
          })
      }
    }
    .width(CommonConstants.FULL_PERCENT)
    .justifyContent(FlexAlign.End)
  }

  build() {
    Column() {
      // 头部：标题与状态标签
      Row() {
        Text(this.state.title)
          .fontSize($r('sys.float.Title_S'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Blank()
        if (this.state.status !== BrewCommandStatus.IDLE) {
          Text(this.statusText())
            .fontSize($r('sys.float.Body_S'))
            .fontColor($r('sys.color.font_secondary'))
            .padding({ left: $r('sys.float.padding_level3'), right: $r('sys.float.padding_level3') })
            .borderRadius($r('sys.float.corner_radius_level4'))
            .backgroundColor($r('sys.color.comp_background_tertiary'))
        }
      }
      .width(CommonConstants.FULL_PERCENT)
      .alignItems(VerticalAlign.Center)

      // 命令行：让用户确认真跑的是哪条命令。长命令换行，不截断
      Text(this.state.command)
        .fontSize($r('sys.float.Body_S'))
        .fontColor($r('sys.color.font_secondary'))
        .width(CommonConstants.FULL_PERCENT)
        .margin({ top: $r('sys.float.padding_level2') })

      // 日志区
      List({ scroller: this.scroller }) {
        if (this.state.omittedLines > 0) {
          ListItem() {
            Text($r('app.string.brew_cmd_omitted_lines', this.state.omittedLines))
              .fontSize($r('sys.float.Body_S'))
              .fontColor($r('sys.color.font_tertiary'))
              .width(CommonConstants.FULL_PERCENT)
          }
        }
        // 键用「行在日志里的总序号」（当前下标 + 已省略行数）而不是当前下标。
        // 超出上限裁剪时最早的行被丢弃，同样的下标会指向不同的内容，
        // 用当前下标做键会让已渲染的行保留旧文本，看起来像日志不更新。
        // 序号稳定之后，追加的行是新键、只增量渲染已有的行不必重建。
        ForEach(this.state.lines, (line: BrewCommandLine, index: number) => {
          ListItem() {
            this.LogLineBuilder(line)
          }
        }, (line: BrewCommandLine, index: number) => `${this.state.omittedLines + index}`)
      }
      .layoutWeight(1)
      .width(CommonConstants.FULL_PERCENT)
      .scrollBar(BarState.Auto)
      .onScrollIndex((start: number, end: number) => {
        this.updateFollowTail(end);
      })

      this.ActionBuilder()
    }
    .width(CommonConstants.FULL_PERCENT)
    .height(CommonConstants.FULL_PERCENT)
    .padding({
      left: $r('sys.float.padding_level6'),
      right: $r('sys.float.padding_level6'),
      top: $r('sys.float.padding_level6'),
      bottom: $r('sys.float.padding_level6'),
    })
  }
}