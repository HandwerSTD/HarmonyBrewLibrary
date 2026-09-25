/*
 * Copyright (c) 2025 Huawei Device Co., Ltd.
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

import type { BrewLifecycleNotice } from '@ohos/brewcommon';

/**
 * 生命周期警示条（§5.3 分区 9）。
 *
 * Homebrew 是三态：正常 / deprecated（可用但警告）/ disabled（不可安装）。
 * 这个区分来自数据本身（`deprecated` 与 `disabled` 是两个独立字段，且各有自己的
 * 日期与原因字段），不是我们自己推的，所以提示条要如实区分两种措辞。
 *
 * 组件本身不判断是否显示 —— 该由调用方用 `if (lifecycle)` 控制，避免组件内部再存一份状态。
 *
 * 图标的取舍：本可以配一个警告类图标，但实测有效的 38 个 `sys.symbol.*` 里没有合适的一个
 * （`exclamationmark_triangle_fill` 之类均未验证，见 docs §10.3）。
 * 与其赌一个名字，先用「警示底色 + 文字」表达 —— 信息本身已经完整。
 */
@Component
export struct BrewLifecycleBanner {
  @Prop @Require notice: BrewLifecycleNotice;

  build() {
    Column() {
      Text(this.notice.label)
        .fontSize($r('sys.float.Title_S'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_on_primary'))
      Text(this.notice.hint)
        .fontSize($r('sys.float.Body_M'))
        .fontColor($r('sys.color.font_on_primary'))
        .margin({ top: $r('sys.float.padding_level2') })
      if (this.notice.reason) {
        Text(this.notice.reason)
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_on_primary'))
          .margin({ top: $r('sys.float.padding_level2') })
      }
      if (this.notice.replacement) {
        Text(this.notice.replacement)
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_on_primary'))
          .margin({ top: $r('sys.float.padding_level2') })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding($r('sys.float.padding_level6'))
    .borderRadius($r('sys.float.corner_radius_level8'))
    .backgroundColor($r('sys.color.ohos_id_color_alert'))
  }
}
