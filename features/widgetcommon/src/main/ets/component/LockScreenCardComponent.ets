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

/**
 * 锁屏卡片（1*1）。**只展示，不再有交互**：点击卡片原本会拉起 App 并跳到组件页，
 * 而组件页已随 `features/componentlibrary` 一并移除，所以点击一律不响应。
 */
@Component
export struct LockScreenCardComponent {
  build() {
    Column() {
      Image($r('app.media.ic_lock_screen'))
        .width($r('app.float.lock_screen_icon_size'))
        .aspectRatio(1)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }
}