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

import { BundleInfoData, CommonConstants, PageEnum, ResourceUtil, StorageKey } from '@ohos/common';
import { AboutItemCard } from '../component/AboutItemCard';
import { MineConstant } from '../constant/CommonConstants';
import { AboutVM, ViewRegistrationInfoEvent } from '../viewmodel/AboutVM';

@Component
export struct AboutView {
  viewModel: AboutVM = AboutVM.getInstance();
  context: Context = this.getUIContext().getHostContext() as Context;
  @StorageProp(StorageKey.BUNDLE_INFO) bundleInfo?: BundleInfoData =
    AppStorage.get<BundleInfoData>(StorageKey.BUNDLE_INFO);
  @Consume('appIconDescriptor') drawableDescriptor: DrawableDescriptor;
  private pathStack?: NavPathStack;

  private handleOnReady(ctx: NavDestinationContext): void {
    this.pathStack = ctx?.pathStack;
  }

  private openStatement(): void {
    this.pathStack?.pushPath({ name: PageEnum.STATEMENT_VIEW });
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