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

import { preferences, ValueType } from '@kit.ArkData';
import type { BusinessError } from '@kit.BasicServicesKit';
import { StorageKey } from '../constant/CommonEnums';
import Logger from '../util/Logger';

const PREFERENCES_NAME: string = 'HMosWorldStoreWithNet';
const TAG: string = '[PreferenceManager]';

export class PreferenceManager {
  private static instance: PreferenceManager;
  private preferences?: preferences.Preferences;

  private constructor() {
    this.initPreference(PREFERENCES_NAME);
  }

  public static getInstance(): PreferenceManager {
    if (!PreferenceManager.instance) {
      PreferenceManager.instance = new PreferenceManager();
    }
    return PreferenceManager.instance;
  }

  private initPreference(storeName: string): void {
    const uiContext: UIContext | undefined = AppStorage.get<UIContext>(StorageKey.UI_CONTEXT);
    try {
      if (!uiContext) {
        Logger.error(TAG, `initPreference failed, cause uiContext is undefined.`);
        return;
      }
      this.preferences = preferences.getPreferencesSync(uiContext.getHostContext() as Context, { name: storeName });
    } catch (err) {
      Logger.error(TAG, `initPreference failed, err code:${err.code},msg:${err.message}`);
    }
  }

  public setValue<T>(key: string, value: T, retry: boolean = true): void {
    if (this.preferences) {
      try {
        this.preferences.putSync(key, JSON.stringify(value));
        this.saveValue();
      } catch (e) {
        Logger.error(TAG, `Preferences put ${key} failed, err code:${e?.code},msg:${e?.message}`);
      }
    } else {
      if (retry) {
        this.initPreference(PREFERENCES_NAME);
        this.setValue<T>(key, value, false);
      }
    }
  }

  public getValue<T>(key: string, defaultValue?: ValueType, retry: boolean = true): T | null {
    if (this.preferences) {
      let rawValue: string | undefined;
      try {
        const res = this.preferences.getSync(key, defaultValue);
        if (res) {
          rawValue = res as string;
        }
      } catch (err) {
        const e: BusinessError = err as BusinessError;
        Logger.error(TAG, `Preferences getSync ${key} failed. err code:${e.code},msg:${e.message}`);
        return null;
      }
      if (!rawValue) {
        return null;
      }
      try {
        return JSON.parse(rawValue) as T;
      } catch (parseErr) {
        const e: BusinessError = parseErr as BusinessError;
        Logger.error(TAG,
          `Preferences JSON.parse ${key} failed, data may be corrupted. err code:${e.code},msg:${e.message}`);
        this.deleteValue(key, false);
        return null;
      }
    } else {
      if (retry) {
        this.initPreference(PREFERENCES_NAME);
        return this.getValue<T>(key, defaultValue, false);
      }
      return null;
    }
  }

  public hasValue(key: string, retry: boolean = true): boolean {
    if (this.preferences) {
      try {
        return this.preferences.hasSync(key);
      } catch (err) {
        Logger.error(TAG, `Preferences hasValue ${key} failed. err code:${err.code},msg:${err.message}`);
        return false;
      }
    } else {
      if (retry) {
        this.initPreference(PREFERENCES_NAME);
        return this.hasValue(key, false);
      }
      return false;
    }
  }

  public deleteValue(key: string, retry: boolean = true): void {
    if (this.preferences) {
      try {
        this.preferences.deleteSync(key);
        this.saveValue();
      } catch (err) {
        Logger.error(TAG, `Preferences delete ${key} failed. err code:${err.code},msg:${err.message}`);
      }
    } else {
      if (retry) {
        this.initPreference(PREFERENCES_NAME);
        this.deleteValue(key, false);
      }
    }
  }

  saveValue() {
    try {
      this.preferences?.flush()
        .catch((err: BusinessError) => {
          Logger.error(TAG, `Preferences flush failed.err code:${err.code},msg:${err.message}`);
        });
    } catch (err) {
      Logger.error(TAG, `Preferences flush failed.err code:${err.code},msg:${err.message}`);
    }
  }
}