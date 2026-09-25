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

import { describe, it, expect, beforeEach, afterEach } from '@ohos/hypium';
import { AppType, AppTypeUtil } from '../../../../main/ets/util/AppTypeUtil';

const APP_TYPE_KEY: string = 'hmos_world_AppTypeKey';

export default function AppTypeUtilTest() {
  describe('AppTypeUtilTest', () => {
    beforeEach(() => {
      AppStorage.delete(APP_TYPE_KEY);
    })
    afterEach(() => {
      AppStorage.delete(APP_TYPE_KEY);
    })

    it('setAppType_PHONE_isPhoneAppTrue_othersFalse', 0, () => {
      AppTypeUtil.setAppType(AppType.PHONE);
      expect(AppTypeUtil.isPhoneApp()).assertTrue();
      expect(AppTypeUtil.isPcApp()).assertFalse();
      expect(AppTypeUtil.isWearableApp()).assertFalse();
      expect(AppTypeUtil.isTvApp()).assertFalse();
    })

    it('setAppType_PC_isPcAppTrue_othersFalse', 0, () => {
      AppTypeUtil.setAppType(AppType.PC);
      expect(AppTypeUtil.isPhoneApp()).assertFalse();
      expect(AppTypeUtil.isPcApp()).assertTrue();
      expect(AppTypeUtil.isWearableApp()).assertFalse();
      expect(AppTypeUtil.isTvApp()).assertFalse();
    })

    it('setAppType_WEARABLE_isWearableAppTrue_othersFalse', 0, () => {
      AppTypeUtil.setAppType(AppType.WEARABLE);
      expect(AppTypeUtil.isPhoneApp()).assertFalse();
      expect(AppTypeUtil.isPcApp()).assertFalse();
      expect(AppTypeUtil.isWearableApp()).assertTrue();
      expect(AppTypeUtil.isTvApp()).assertFalse();
    })

    it('setAppType_TV_isTvAppTrue_othersFalse', 0, () => {
      AppTypeUtil.setAppType(AppType.TV);
      expect(AppTypeUtil.isPhoneApp()).assertFalse();
      expect(AppTypeUtil.isPcApp()).assertFalse();
      expect(AppTypeUtil.isWearableApp()).assertFalse();
      expect(AppTypeUtil.isTvApp()).assertTrue();
    })

    it('setAppType_CAR_allIsMethodsFalse', 0, () => {
      AppTypeUtil.setAppType(AppType.CAR);
      expect(AppTypeUtil.isPhoneApp()).assertFalse();
      expect(AppTypeUtil.isPcApp()).assertFalse();
      expect(AppTypeUtil.isWearableApp()).assertFalse();
      expect(AppTypeUtil.isTvApp()).assertFalse();
    })

    it('setAppType_emptyString_shouldNotSet', 0, () => {
      AppTypeUtil.setAppType('' as AppType);
      expect(AppTypeUtil.isPhoneApp()).assertFalse();
      expect(AppTypeUtil.isPcApp()).assertFalse();
      expect(AppTypeUtil.isWearableApp()).assertFalse();
      expect(AppTypeUtil.isTvApp()).assertFalse();
    })

    it('withoutSetAppType_allIsMethodsFalse', 0, () => {
      expect(AppTypeUtil.isPhoneApp()).assertFalse();
      expect(AppTypeUtil.isPcApp()).assertFalse();
      expect(AppTypeUtil.isWearableApp()).assertFalse();
      expect(AppTypeUtil.isTvApp()).assertFalse();
    })

    it('setAppType_overwrite_shouldReplacePreviousValue', 0, () => {
      AppTypeUtil.setAppType(AppType.PHONE);
      expect(AppTypeUtil.isPhoneApp()).assertTrue();
      AppTypeUtil.setAppType(AppType.PC);
      expect(AppTypeUtil.isPhoneApp()).assertFalse();
      expect(AppTypeUtil.isPcApp()).assertTrue();
      AppTypeUtil.setAppType(AppType.TV);
      expect(AppTypeUtil.isPcApp()).assertFalse();
      expect(AppTypeUtil.isTvApp()).assertTrue();
      AppTypeUtil.setAppType(AppType.WEARABLE);
      expect(AppTypeUtil.isTvApp()).assertFalse();
      expect(AppTypeUtil.isWearableApp()).assertTrue();
    })
  })
}
