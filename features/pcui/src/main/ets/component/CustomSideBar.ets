/*
 * Copyright (c) 2024 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import {
  BrewCommandRunner,
  BrewCommandState,
  BrewCommandStatus,
  isBrewCommandEnded,
} from '@ohos/brewcommon';
import { TabBarData, TABS_LIST } from '../model/TabBarModel';

@Component
export struct CustomSideBar {
  @Prop @Require currentIndex: number;
  @State focus: boolean = false;
  @Consume('appIconDescriptor') drawableDescriptor?: DrawableDescriptor;
  @State symbolEffect: BounceSymbolEffect = new BounceSymbolEffect(EffectScope.LAYER, EffectDirection.UP);
  /**
   * 与 `BrewCommandRunner` 单例里**同一个**命令状态实例（`BrewCommandState` 是 `@Observed`）。
   * 入口的显示判据与图标读它的一级属性。
   */
  @State commandState: BrewCommandState = BrewCommandRunner.getInstance().getState();
  /** Shell 入口的悬停状态 */
  @State shellFocus: boolean = false;
  sideBarChange: (index: number) => void = (_index: number) => {
  };

  /**
   * 入口是否展示：命令执行过一次之后就常显，直到应用退出。
   * 状态离开 IDLE 就不会再回来，所以只读 `status` 一个一级属性即可；
   * 读它同时建立了对本组件的观察，命令起止都会让入口跟着出现。
   */
  private shellEntryVisible(): boolean {
    return this.commandState.status !== BrewCommandStatus.IDLE;
  }

  /**
   * 入口图标：终态结果还没看过时是结局（成功对号、失败叉号），其余情况是原来的 code 图标。
   * 读 `status` 与 `resultViewed` 两个一级属性，命令结束与结果被看过都会让图标跟着切换。
   * `INTERRUPTED` 与 `TIMEOUT` 归入失败：两者都是命令没有走完就被结束。
   */
  private shellEntryIcon(): Resource {
    const status: BrewCommandStatus = this.commandState.status;
    const resultViewed: boolean = this.commandState.resultViewed;
    if (isBrewCommandEnded(status) && !resultViewed) {
      return status === BrewCommandStatus.DONE ? $r('sys.symbol.checkmark') : $r('sys.symbol.xmark');
    }
    return $r('sys.symbol.code');
  }

  @Builder
  BarItemBuilder(item: TabBarData) {
    Row() {
      SymbolGlyph(item.icon)
        .fontSize($r('sys.float.Title_M'))
        .fontColor(item.id === this.currentIndex ? [$r('sys.color.icon_emphasize')] :
          [$r('sys.color.icon_secondary')])
        .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_OPACITY)
        .padding({
          left: $r('sys.float.padding_level4'),
          right: $r('sys.float.padding_level4'),
        })
      Text(item.title)
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(FontWeight.Medium)
        .fontColor(item.id === this.currentIndex ? $r('sys.color.interactive_active') :
          $r('sys.color.font_tertiary'))
    }
    .alignItems(VerticalAlign.Center)
    .backgroundColor(this.currentIndex !== item.id ? Color.Transparent :
      this.focus ? $r('app.color.hmos_side_bar_background_color') : $r('sys.color.interactive_hover'))
    .width('100%')
    .height($r('app.float.side_bar_height'))
    .margin({
      top: $r('sys.float.padding_level4'),
      bottom: $r('sys.float.padding_level1'),
    })
    .borderRadius($r('sys.float.corner_radius_level4'))
    .onClick(() => {
      if (this.currentIndex !== item.id) {
        this.sideBarChange(item.id);
      }
    })
  }

  /** 底部 Shell 入口。图标反映最近一条命令的结局，点击只把执行 Sheet 拉起来，不切页签 */
  @Builder
  ShellEntryBuilder() {
    Row() {
      SymbolGlyph(this.shellEntryIcon())
        .fontSize($r('sys.float.Title_M'))
        .fontColor([$r('sys.color.icon_secondary')])
        .renderingStrategy(SymbolRenderingStrategy.MULTIPLE_OPACITY)
        .padding({
          left: $r('sys.float.padding_level4'),
          right: $r('sys.float.padding_level4'),
        })
      Text($r('app.string.tab_shell'))
        .fontSize($r('sys.float.Body_L'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_tertiary'))
    }
    .alignItems(VerticalAlign.Center)
    .backgroundColor(this.shellFocus ? $r('sys.color.interactive_hover') : Color.Transparent)
    .width('100%')
    .height($r('app.float.side_bar_height'))
    // 底部避让与侧边栏的左右内缩同值（`Column` 的 padding）。写成 margin 而不写成 padding：
    // 悬停底色画在这一层的框上，padding 会把底色一起撑到窗口下沿。
    .margin({ bottom: $r('sys.float.padding_level8') })
    .borderRadius($r('sys.float.corner_radius_level4'))
    .onHover((isHover: boolean) => {
      this.shellFocus = isHover;
    })
    .onClick(() => {
      BrewCommandRunner.getInstance().openSheet();
    })
  }

  build() {
    Column() {
      Row() {
        Image(this.drawableDescriptor)
          .width($r('app.float.app_icon_width'))
          .aspectRatio(1)
          .borderRadius($r('sys.float.corner_radius_level4'))
          .margin({ right: $r('sys.float.padding_level6') })
        Text($r('app.string.hmos_app_name'))
          .fontColor($r('sys.color.font_primary'))
          .fontSize($r('sys.float.Body_L'))
      }
      .padding({
        left: $r('sys.float.padding_level4'),
        right: $r('sys.float.padding_level4'),
      })
      .height($r('app.float.side_bar_title_height'))
      .width('100%')

      ForEach(TABS_LIST, (item: TabBarData) => {
        this.BarItemBuilder(item)
      }, (item: TabBarData, index: number) => item.id.toString() + (this.currentIndex === index))

      // Blank 占掉剩余高度，把入口压在侧边栏最下方；分隔线与入口一起出现、一起消失
      Blank()

      if (this.shellEntryVisible()) {
        Divider()
          .strokeWidth('1px')
          .color($r('sys.color.comp_divider'))
          .margin({
            top: $r('sys.float.padding_level2'),
            bottom: $r('sys.float.padding_level2'),
          })
        this.ShellEntryBuilder()
      }
    }
    .width('100%')
    .height('100%')
    .padding({
      left: $r('sys.float.padding_level8'),
      right: $r('sys.float.padding_level8'),
    })
    .onHover((isHover: boolean) => {
      this.focus = isHover;
    })
  }
}