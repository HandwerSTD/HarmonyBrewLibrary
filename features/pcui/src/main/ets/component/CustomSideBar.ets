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
   * 入口的显示判据读它的一级属性。
   */
  @State commandState: BrewCommandState = BrewCommandRunner.getInstance().getState();
  /** Shell 入口的悬停状态 */
  @State shellFocus: boolean = false;
  sideBarChange: (index: number) => void = (_index: number) => {
  };

  /**
   * 入口是否展示：Sheet 没开着，且命令正在后台执行、或者终态结果还没在 Sheet 里看过。
   * 先把三个属性读出来再判断：读它们同时建立了对本组件的观察，
   * 命令起止、Sheet 开关、结果是否看过这三类变化都会让入口跟着出现或消失。
   */
  private shellEntryVisible(): boolean {
    const status: BrewCommandStatus = this.commandState.status;
    const sheetShown: boolean = this.commandState.sheetShown;
    const resultViewed: boolean = this.commandState.resultViewed;
    return !sheetShown && (status === BrewCommandStatus.RUNNING || !resultViewed);
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

  /** 底部 Shell 入口。点击只把执行 Sheet 拉起来，不切页签 */
  @Builder
  ShellEntryBuilder() {
    Row() {
      SymbolGlyph($r('sys.symbol.code'))
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