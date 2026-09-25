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
import { TimeUtil } from '../../../../main/ets/util/TimeUtil';

export default function TimeUtilTest() {
  describe('TimeUtilTest', () => {
    it('getCurrentTime_shouldReturnValidTimestamp', 0, () => {
      const before = new Date().getTime();
      const result = TimeUtil.getCurrentTime();
      const after = new Date().getTime();
      expect(typeof result === 'number').assertTrue();
      expect(result > 0).assertTrue();
      expect(result >= before).assertTrue();
      expect(result <= after).assertTrue();
    })
  })
}
