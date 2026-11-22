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

import { common } from '@kit.AbilityKit';
import { BundleInfoData, CommonConstants, Logger, ResourceUtil, StorageKey } from '@ohos/common';
import { TLDR_REPO_URL } from '@ohos/brewcommon';
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

  /** 署名行跳转 tldr-pages 仓库（CC BY 4.0 的署名指向）。宿主拿不到时静默结束 */
  private openTldrRepo(): void {
    const host: Context | undefined = this.getUIContext().getHostContext();
    if (host === undefined) {
      Logger.warn('[AboutView]', 'openTldrRepo skipped, host context unavailable');
      return;
    }
    const ability: common.UIAbilityContext = host as common.UIAbilityContext;
    ability.openLink(TLDR_REPO_URL).catch((error: Error) => {
      Logger.warn('[AboutView]', `openTldrRepo failed, msg=${error.message}`);
    });
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
          AboutItemCard()
            .margin({ top: $r('sys.float.padding_level16') })
          // 第三方内容署名（tldr 用法示例，CC BY 4.0 —— spec 2026-11-22 §6/G11）。
          // 与包详情页分区底部的署名行同源（同一个 string key），点击打开 tldr-pages 仓库。
          Row() {
            Text($r('app.string.brew_tldr_attribution'))
              .fontWeight(FontWeight.Regular)
              .fontColor($r('sys.color.font_secondary'))
              .fontSize($r('sys.float.Body_S'))
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize($r('sys.float.Body_S'))
              .fontColor([$r('sys.color.icon_fourth')])
              .margin({ left: $r('sys.float.padding_level2') })
          }
          .width('100%')
          .height($r('app.float.about_item_card_height'))
          .borderRadius($r('sys.float.corner_radius_level7'))
          .backgroundColor($r('sys.color.comp_background_list_card'))
          .justifyContent(FlexAlign.Start)
          .alignItems(VerticalAlign.Center)
          .padding({
            left: $r('sys.float.padding_level6'),
            right: $r('sys.float.padding_level6'),
          })
          .margin({ top: $r('sys.float.padding_level6') })
          .onClick(() => {
            this.openTldrRepo();
          })
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
  }
}

@Builder
export function AboutViewBuilder() {
  AboutView()
}