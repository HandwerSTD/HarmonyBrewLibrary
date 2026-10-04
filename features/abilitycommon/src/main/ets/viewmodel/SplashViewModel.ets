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

import { BaseVM, Logger, PageContext, PageEnum, StorageKey } from '@ohos/common';
import { BrewTable } from '@ohos/brewcommon';
import { SplashModel } from '../model/SplashModel';
import { InitCenter } from '../util/InitCenter';

const TAG: string = '[SplashViewModel]';

export class SplashViewModel extends BaseVM<SplashModel> {
  private static instance: SplashViewModel;

  private constructor() {
    super(new SplashModel());
  }

  public static getInstance(): SplashViewModel {
    if (!SplashViewModel.instance) {
      SplashViewModel.instance = new SplashViewModel();
    }
    return SplashViewModel.instance;
  }

  public sendEvent<T>(eventParam: SplashEventParam<T>): void {
    if (eventParam.type === SplashEventTypeEnum.INIT_ENV_INFO) {
      this.initEnvInfo();
    } else if (eventParam.type === SplashEventTypeEnum.PRELOAD_RESOURCES) {
      this.preloadResources(eventParam.param as PreloadParam);
    } else if (eventParam.type === SplashEventTypeEnum.JUMP_TO_MAIN) {
      this.jumpToMainPage();
    }
  }

  private jumpToMainPage(): void {
    AppStorage.get<PageContext>(StorageKey.HOME_PAGE_CONTEXT)?.replacePage({
      routerName: PageEnum.MAIN_PAGE,
    }, false);
  }

  private preloadResources(param: PreloadParam): void {
    const uiContext: UIContext | undefined = AppStorage.get<UIContext>(StorageKey.UI_CONTEXT);
    if (uiContext) {
      const context: Context | undefined = uiContext.getHostContext();
      if (!context) {
        Logger.error(TAG, 'preloadResources fail cause the context is undefined.');
        return;
      }
      InitCenter.initAfterAgreement(context).then(() => {
        // 数据层的**唯一取数入口**。不 await、不阻塞首屏：
        // 包表的两片各自独立推进，页面用 `BrewTable.current()` 读内存派生结构，
        // 表落地时通过观察者通知页面重出内容（见 BrewTable.addObserver）。
        BrewTable.refresh().catch((error: Error) => {
          Logger.error(TAG, `table refresh failed, ${error.message}`);
        });
        if (param.needJump) {
          this.jumpToMainPage();
        }
      })
    }
  }

  private initEnvInfo(): Promise<void> {
    const uiContext: UIContext | undefined = AppStorage.get<UIContext>(StorageKey.UI_CONTEXT);
    if (uiContext) {
      const context: Context | undefined = uiContext.getHostContext();
      if (!context) {
        Logger.error(TAG, 'preloadResources fail cause the context is undefined.');
        return Promise.reject({ message: `Failed to get context.` } as BusinessError);
      }
      return InitCenter.initBeforeAgreement(context);
    }
    return Promise.reject({ message: `Failed to initEnvInfo.` } as BusinessError);
  }
}

export interface SplashEventParam<T> {
  type: SplashEventTypeEnum,
  param?: T,
}

export interface PreloadParam {
  needJump?: boolean;
}

export enum SplashEventTypeEnum {
  JUMP_TO_MAIN = 'jumpToMainPage',
  PRELOAD_RESOURCES = 'preloadResources',
  INIT_ENV_INFO = 'initEnvInfo',
}
