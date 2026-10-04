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

import { PcSplashPage } from '@ohos/pcui';

/** 启动页入口。页面主体在 pcui，这里只保留路由入口 */
@Entry
@Component
struct SplashPage {
  build() {
    // @Entry 的 build 只允许一个根节点，且根节点必须是容器组件，
    // 所以这里用全屏 Stack 承载 pcui 导出的 PcSplashPage 结构体。
    Stack() {
      PcSplashPage()
    }
    .width('100%')
    .height('100%')
  }
}