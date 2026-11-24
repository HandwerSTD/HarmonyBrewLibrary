/*
 * Copyright (c) 2026 Instant Bird Network Technology (Qingdao) Co., Ltd.
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
import { CommonConstants, Logger } from '@ohos/common';
import { TLDR_REPO_URL } from '@ohos/brewcommon';

@Component
export struct StatementView {
  /** 署名行跳转 tldr-pages 仓库（CC BY 4.0 的署名指向）。宿主拿不到时静默结束 */
  private openTldrRepo(): void {
    const host: Context | undefined = this.getUIContext().getHostContext();
    if (host === undefined) {
      Logger.warn('[StatementView]', 'openTldrRepo skipped, host context unavailable');
      return;
    }
    const ability: common.UIAbilityContext = host as common.UIAbilityContext;
    ability.openLink(TLDR_REPO_URL).catch((error: Error) => {
      Logger.warn('[StatementView]', `openTldrRepo failed, msg=${error.message}`);
    });
  }

  build() {
    NavDestination() {
      Scroll() {
        Column() {
          Text($r('app.string.statement_content'))
            .fontSize($r('sys.float.Body_L'))
            .fontColor($r('sys.color.font_primary'))
            .textAlign(TextAlign.Start)
            .width(CommonConstants.FULL_PERCENT)

          // 第三方内容署名（tldr 用法示例，CC BY 4.0 —— spec 2026-11-22 §6/G11）。
          // 与关于页同源（同一个 string key），点击打开 tldr-pages 仓库。
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

          // AI 数据披露（spec §9：发送给 provider 的内容 = 包元数据 + 错误文本，不含用户身份）。
          // 纯声明行：不可点击、不跳转——发送什么在 AI 设置页的语境里看更完整，这里只做告知。
          Text($r('app.string.ai_privacy_note'))
            .fontColor($r('sys.color.font_secondary'))
            .fontWeight(FontWeight.Regular)
            .fontSize($r('sys.float.Body_S'))
            .textAlign(TextAlign.Start)
            .width('100%')
            .padding({
              left: $r('sys.float.padding_level6'),
              right: $r('sys.float.padding_level6'),
              top: $r('sys.float.padding_level4'),
              bottom: $r('sys.float.padding_level2'),
            })
            .margin({ top: $r('sys.float.padding_level2') })

          // 更新情报披露（release intel spec G13：本功能会访问上游 GitHub Releases
          // 公开页面并把 Release Notes 原文发给 AI provider 归纳；请求不含用户身份，
          // 摘要结果缓存在本机。同样只做告知，纯声明行）。
          Text($r('app.string.release_intel_privacy_note'))
            .fontColor($r('sys.color.font_secondary'))
            .fontWeight(FontWeight.Regular)
            .fontSize($r('sys.float.Body_S'))
            .textAlign(TextAlign.Start)
            .width('100%')
            .padding({
              left: $r('sys.float.padding_level6'),
              right: $r('sys.float.padding_level6'),
              top: $r('sys.float.padding_level4'),
              bottom: $r('sys.float.padding_level2'),
            })
            .margin({ top: $r('sys.float.padding_level2') })
        }
        .alignItems(HorizontalAlign.Start)
        .padding({
          left: $r('sys.float.padding_level8'),
          right: $r('sys.float.padding_level8'),
          top: $r('sys.float.padding_level6'),
          bottom: $r('sys.float.padding_level12'),
        })
        .width(CommonConstants.FULL_PERCENT)
      }
      .scrollBar(BarState.Off)
      .width(CommonConstants.FULL_PERCENT)
      .height(CommonConstants.FULL_PERCENT)
      .align(Alignment.Top)
    }
    .title($r('app.string.statement'))
    .padding({ top: $r('sys.float.padding_level4') })
    .backgroundColor($r('sys.color.background_secondary'))
  }
}

@Builder
export function StatementViewBuilder() {
  StatementView()
}
