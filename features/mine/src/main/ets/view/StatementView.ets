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

import { CommonConstants } from '@ohos/common';

@Component
export struct StatementView {
  build() {
    NavDestination() {
      Scroll() {
        Column() {
          Text($r('app.string.statement_content'))
            .fontSize($r('sys.float.Body_L'))
            .fontColor($r('sys.color.font_primary'))
            .textAlign(TextAlign.Start)
            .width(CommonConstants.FULL_PERCENT)
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
