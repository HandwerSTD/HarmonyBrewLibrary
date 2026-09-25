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

import { ImageKnifeUtil, WindowUtil } from '@ohos/common';
import { PreloadParam, SplashEventTypeEnum, SplashViewModel } from '../viewmodel/SplashViewModel';

@Component
export struct SplashView {
  context: Context = this.getUIContext().getHostContext() as Context;
  private viewModel: SplashViewModel = SplashViewModel.getInstance();

  async aboutToAppear(): Promise<void> {
    WindowUtil.updateStatusBarColor(true);
    await ImageKnifeUtil.initialize(this.context);
    this.viewModel.sendEvent<PreloadParam>({
      type: SplashEventTypeEnum.PRELOAD_RESOURCES,
      param: { needJump: true },
    });
  }

  build() {
    Stack() {
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.start_window_background'))
  }
}
