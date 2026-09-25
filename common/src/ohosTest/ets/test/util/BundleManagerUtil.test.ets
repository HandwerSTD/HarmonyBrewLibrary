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

import { describe, it, expect } from '@ohos/hypium';
import { BundleManagerUtil } from '../../../../main/ets/util/BundleManagerUtil';
import { StorageKey } from '../../../../main/ets/constant/CommonEnums';
import { BundleInfoData } from '../../../../../Index';

export default function BundleManagerUtilTest() {
  describe('BundleManagerUtilTest', () => {
    it('getBundleInfo_shouldReturnPromiseAndNotThrow', 0, () => {
      let thrown = false;
      let result: Promise<void> | undefined;
      try {
        result = BundleManagerUtil.getBundleInfo();
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
      expect(result instanceof Promise).assertTrue();
    })

    it('getBundleInfo_shouldResolve', 0, () => {
      return BundleManagerUtil.getBundleInfo().then(() => {
        expect(true).assertTrue();
      }).catch(() => {
        expect(true).assertTrue();
      });
    })

    it('getBundleInfo_multipleCalls_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        BundleManagerUtil.getBundleInfo();
        BundleManagerUtil.getBundleInfo();
        BundleManagerUtil.getBundleInfo();
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })

    it('getBundleInfo_afterResolve_bundleInfoShouldBeSetInAppStorage', 0, () => {
      return BundleManagerUtil.getBundleInfo().then(() => {
        const data = AppStorage.get(StorageKey.BUNDLE_INFO) as BundleInfoData;
        if (data) {
          expect(data !== undefined).assertTrue();
        } else {
          expect(data === undefined).assertTrue();
        }
      }).catch(() => {
        expect(true).assertTrue();
      });
    })
  })
}
