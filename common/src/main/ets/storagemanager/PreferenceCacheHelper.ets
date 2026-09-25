/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
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

import type { BusinessError } from '@kit.BasicServicesKit';
import { PreferenceManager } from './PreferenceManager';

const PREFERENCE_NO_DATA_MSG: string = 'There is no data in the Preference.';

/**
 * Cache helper built on top of PreferenceManager for the preference cache
 * patterns used across service layers. Centralizes single-value read/write,
 * Record<string, T> sub-key read/write and bulk multi-key write so services
 * stay free of preference plumbing.
 */
export class PreferenceCacheHelper {

  public static getSubValue<T>(storageKey: string, subKey: string): Promise<T> {
    return new Promise((resolve: (value: T) => void, reject: (reason?: Object) => void) => {
      let resp = PreferenceManager.getInstance().getValue<Record<string, T>>(storageKey);
      if (!resp) {
        reject({ message: PREFERENCE_NO_DATA_MSG } as BusinessError);
        return;
      }
      resp = (resp as Record<string, T>);
      const ret = resp[subKey];
      if (!ret) {
        reject({ message: PREFERENCE_NO_DATA_MSG } as BusinessError);
        return;
      }
      resolve(ret);
    });
  }

  public static setSubValue<T>(storageKey: string, subKey: string, data: T): Promise<void> {
    return new Promise((resolve: () => void) => {
      const hasValue: boolean = PreferenceManager.getInstance().hasValue(storageKey);
      if (hasValue) {
        let resp = PreferenceManager.getInstance().getValue<Record<string, T>>(storageKey) ?? {};
        resp = (resp as Record<string, T>);
        resp[subKey] = data;
        PreferenceManager.getInstance().setValue(storageKey, resp);
      } else {
        const record: Record<string, T> = {};
        record[subKey] = data;
        PreferenceManager.getInstance().setValue(storageKey, record);
      }
      resolve();
    });
  }
}
