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

import { AccountService, InitResult, Logger, PreferenceManager, ResourceUtil, StorageKey } from '@ohos/common';

const TAG: string = '[InitCenter]';

export class InitCenter {
  public static async initAfterAgreement(context: Context): Promise<void> {
    Logger.info(TAG, 'initAfterAgreement :: start');
    await InitCenter.restoreAccountState(context);
  }

  /**
   * 恢复华为账号登录态（头像/昵称/unionId）。
   *
   * 登录信息存在 preferences 里，进程重启后必须有人把它读回 AccountService，
   * 否则「我的」页读到的永远是未登录。这里在首屏跳转前 await，
   * 保证主页面首次渲染时拿到的就是正确的登录态，不会先闪一下未登录再修正。
   *
   * 全程不抛异常：账号问题不应该把用户卡在启动页。
   */
  private static async restoreAccountState(context: Context): Promise<void> {
    try {
      // 先确保存储可用，否则后面读到的是「没有数据」而不是「没登录」。
      PreferenceManager.getInstance().initWithContext(context);
      const initResult: InitResult = await AccountService.getInstance().serviceInit();
      Logger.info(TAG, `restore account state done, isLogin=${initResult.isLogin}.`);
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      Logger.error(TAG, `restore account state failed, code ${err.code}, message ${err.message}`);
    }
  }

  public static async initBeforeAgreement(context: Context): Promise<void> {
    Logger.info(TAG, 'initBeforeAgreement :: start');
    try {
      if (!context) {
        return;
      }
      const envData = ResourceUtil.getDataFromRawfile(context, 'env.json');
      Logger.debug(TAG, `The env data is ${JSON.stringify(envData)}}`);
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      Logger.error(TAG, `getDataFromRawfile error: cause code ${err.code}, message ${err.message}`);
      return Promise.reject(err);
    }
  }
}