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
import { DebounceUtil } from '../../../../main/ets/util/DebounceUtil';

export default function DebounceUtilTest() {
  describe('DebounceUtilTest', () => {
    it('debounce_shouldExecuteOnFirstCall_whenLastClickTimeIsZero', 0, () => {
      let count = 0;
      const debounced = DebounceUtil.debounce(() => { count++; }, 1000);
      debounced();
      expect(count).assertEqual(1);
    })

    it('debounce_shouldSkipAllCalls_whenWithinWaitWindow', 0, () => {
      let count = 0;
      const debounced = DebounceUtil.debounce(() => { count++; }, 1000);
      debounced();
      debounced();
      debounced();
      expect(count).assertEqual(0);
    })

    it('debounce_withNoWaitParam_shouldUseDefaultWait', 0, () => {
      let count = 0;
      const debounced = DebounceUtil.debounce(() => { count++; });
      debounced();
      expect(count).assertEqual(0);
    })

    it('debounce_shouldReturnFunction', 0, () => {
      const debounced = DebounceUtil.debounce(() => {});
      expect(typeof debounced === 'function').assertTrue();
    })
  })
}
