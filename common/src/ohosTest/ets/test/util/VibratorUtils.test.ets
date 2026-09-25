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
import { VibratorUtils } from '../../../../main/ets/util/VibratorUtils';

export default function VibratorUtilsTest() {
  describe('VibratorUtilsTest', () => {
    it('startVibration_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        VibratorUtils.startVibration();
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })
  })
}
