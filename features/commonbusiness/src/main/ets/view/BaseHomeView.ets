/*
 * Copyright (c) 2024 Huawei Device Co., Ltd.
 * Licensed under the Apache License,Version 2.0 (the "License");
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

import type { LoadingModel } from '@ohos/common';
import {
  GlobalInfoModel,
  LoadingFailedView,
  LoadingStatus,
  LoadingView,
  NoNetworkView,
  StatePlaceholderKind,
  StatePlaceholderView,
  StorageKey,
} from '@ohos/common';

@Component
export struct BaseHomeView {
  @Prop @Require loadingModel: LoadingModel;
  @BuilderParam @Require contentView: () => void;
  @StorageProp(StorageKey.GLOBAL_INFO) globalInfoModel: GlobalInfoModel = new GlobalInfoModel();
  reloadData?: Function;

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.loadingModel.loadingStatus === LoadingStatus.SUCCESS) {
        this.contentView()
      } else if (this.loadingModel.loadingStatus === LoadingStatus.FAILED) {
        LoadingFailedView(this.globalInfoModel.widthBreakpoint, () => {
          this.reloadData?.();
        })
      } else if (this.loadingModel.loadingStatus === LoadingStatus.LOADING) {
        LoadingView(this.globalInfoModel.widthBreakpoint)
      } else if (this.loadingModel.loadingStatus === LoadingStatus.NO_NETWORK) {
        NoNetworkView(this.globalInfoModel.widthBreakpoint, () => {
          this.reloadData?.();
        })
      } else if (this.loadingModel.loadingStatus === LoadingStatus.BUILDING) {
        // 正在建立本地数据：转圈 + 说明，不给重试按钮（进度会自己往前走）
        StatePlaceholderView({
          kind: StatePlaceholderKind.BUILDING,
          message: $r('app.string.state_building'),
        })
      } else if (this.loadingModel.loadingStatus === LoadingStatus.EMPTY_DATA) {
        StatePlaceholderView({
          kind: StatePlaceholderKind.EMPTY,
          message: $r('app.string.state_no_data'),
          actionLabel: $r('app.string.state_retry'),
          onAction: () => {
            this.reloadData?.();
          },
        })
      }
    }
    .backgroundColor($r('sys.color.background_secondary'))
    .width('100%')
    .height('100%')
  }
}