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

import { Logger, ResourceUtil, StorageKey } from '@ohos/common';

const TAG: string = '[InitCenter]';

export class InitCenter {
  public static async initAfterAgreement(_context: Context): Promise<void> {
    Logger.info(TAG, 'initAfterAgreement :: start');
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