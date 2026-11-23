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

import { BundleInfoData, CommonConstants, PageEnum, ResourceUtil, StorageKey, Toast } from '@ohos/common';
import { BrewManifestSyncService } from '@ohos/brewcommon';
import { AboutItemCard } from '../component/AboutItemCard';
import { MineConstant } from '../constant/CommonConstants';
import { AboutVM, ViewRegistrationInfoEvent } from '../viewmodel/AboutVM';

/** 隐藏彩蛋（spec §3.8）：连点次数与相邻两次点按的最大间隔。 */
const EASTER_EGG_TAP_COUNT: number = 4;
const EASTER_EGG_TAP_WINDOW_MS: number = 800;

@Component
export struct AboutView {
  viewModel: AboutVM = AboutVM.getInstance();
  context: Context = this.getUIContext().getHostContext() as Context;
  @StorageProp(StorageKey.BUNDLE_INFO) bundleInfo?: BundleInfoData =
    AppStorage.get<BundleInfoData>(StorageKey.BUNDLE_INFO);
  @Consume('appIconDescriptor') drawableDescriptor: DrawableDescriptor;
  private pathStack?: NavPathStack;
  /** 彩蛋计数：第 4 次触发写入；超过 800ms 间隔即清零重新计。 */
  private tapCount: number = 0;
  private lastTapAt: number = 0;

  private handleOnReady(ctx: NavDestinationContext): void {
    this.pathStack = ctx?.pathStack;
  }

  private openStatement(): void {
    this.pathStack?.pushPath({ name: PageEnum.STATEMENT_VIEW });
  }

  /**
   * 「关于」图标连点彩蛋（spec §3.8，仅 pc_normal）：
   * 4 连点（相邻间隔 ≤800ms）→ 旁路直写 `device:<本机>/manifest` 的 3 个测试包
   * （python@3.12 / deepseek-harness / reasonix）→ 侧边栏「清单同步」入口随之出现。
   * pc_acl 直接 return：那台机器有真实发布链，写死 3 个包会被下一次发布覆盖，语义混乱。
   */
  private handleIconTap(): void {
    if (AppStorage.get<boolean>(StorageKey.BREW_CLI_ENABLED) === true) {
      return;
    }
    const now: number = Date.now();
    if (this.lastTapAt > 0 && now - this.lastTapAt > EASTER_EGG_TAP_WINDOW_MS) {
      this.tapCount = 0;
    }
    this.lastTapAt = now;
    this.tapCount++;
    if (this.tapCount < EASTER_EGG_TAP_COUNT) {
      return;
    }
    this.tapCount = 0;
    BrewManifestSyncService.getInstance().writeEasterEgg();
    Toast.showToast($r('app.string.sync_easter_egg_toast'));
  }

  /** 「声明」入口行：与上方「版本信息」同处一张卡片，中间以分隔线相隔（同设置页列表样式） */
  @Builder
  StatementItem() {
    Row() {
      Text($r('app.string.statement'))
        .fontWeight(FontWeight.Medium)
        .fontSize($r('sys.float.Body_L'))
        .fontColor($r('sys.color.font_primary'))
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize($r('sys.float.Title_S'))
        .fontColor([$r('sys.color.icon_fourth')])
    }
    .width(CommonConstants.FULL_PERCENT)
    .height($r('app.float.about_item_card_height'))
    .justifyContent(FlexAlign.SpaceBetween)
    .alignItems(VerticalAlign.Center)
    .padding({
      left: $r('sys.float.padding_level6'),
      right: $r('sys.float.padding_level6'),
    })
    .onClick(() => {
      this.openStatement();
    })
  }

  build() {
    NavDestination() {
      Column() {
        Column() {
          Image(this.drawableDescriptor)
            .draggable(false)
            .width($r('app.float.about_image_size'))
            .height($r('app.float.about_image_size'))
            .borderRadius($r('sys.float.corner_radius_level8'))
            .onClick(() => {
              this.handleIconTap();
            })
          Text(ResourceUtil.getResourceString(this.context, this.bundleInfo?.labelResource ?? $r(undefined)))
            .fontSize($r('sys.float.Title_S'))
            .fontWeight(FontWeight.Bold)
            .margin({ top: $r('sys.float.padding_level4') })
          Column() {
            AboutItemCard()
            Divider()
              .strokeWidth('0.5px')
              .color($r('sys.color.comp_divider'))              .margin({
                left: $r('sys.float.padding_level6'),
                right: $r('sys.float.padding_level6'),
              })
            this.StatementItem()
          }
          .width(CommonConstants.FULL_PERCENT)
          .borderRadius($r('sys.float.corner_radius_level7'))
          .backgroundColor($r('sys.color.comp_background_list_card'))
          .clip(true)
          .margin({ top: $r('sys.float.padding_level16') })
        }
        .margin({ top: $r('sys.float.padding_level8') })
        .padding({
          left: $r('sys.float.padding_level8'),
          right: $r('sys.float.padding_level8'),
        })

        Column() {
          if (MineConstant.SHOW_REGISTRATION_NO) {
            Text($r('app.string.copyright1'))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_emphasize'))
              .fontSize($r('sys.float.Body_S'))
              .onClick(() => {
                this.viewModel.sendEvent(new ViewRegistrationInfoEvent());
              })
          }
          Text($r('app.string.copyright2'))
            .fontColor($r('sys.color.font_secondary'))
            .fontWeight(FontWeight.Regular)
            .fontSize($r('sys.float.Body_S'))
        }
        .margin({ bottom: $r('sys.float.padding_level24') })
      }
      .justifyContent(FlexAlign.SpaceBetween)
      .width(CommonConstants.FULL_PERCENT)
      .height(CommonConstants.FULL_PERCENT)
    }
    .title($r('app.string.about'))
    .padding({ top: $r('sys.float.padding_level4') })
    .backgroundColor($r('sys.color.background_secondary'))
    .onReady((ctx: NavDestinationContext) => this.handleOnReady(ctx))
  }
}

@Builder
export function AboutViewBuilder() {
  AboutView()
}
