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

import { describe, it, expect, afterEach } from '@ohos/hypium';
import { GlobalContext } from '../../../../main/ets/util/GlobalContext';

export default function GlobalContextTest() {
  describe('GlobalContextTest', () => {
    afterEach(() => {
      GlobalContext.getContext().deleteObject('test_key');
      GlobalContext.getContext().deleteObject('test_key2');
    })

    it('getContext_shouldReturnSameSingleton', 0, () => {
      expect(GlobalContext.getContext() === GlobalContext.getContext()).assertTrue();
    })

    it('setAndGet_withVariousTypes_shouldStoreAndRetrieve', 0, () => {
      GlobalContext.getContext().setObject('test_key', 'test_value');
      expect(GlobalContext.getContext().getObject('test_key')).assertEqual('test_value');

      GlobalContext.getContext().setObject('test_key', 12345);
      expect(GlobalContext.getContext().getObject('test_key')).assertEqual(12345);

      GlobalContext.getContext().setObject('test_key', true);
      expect(GlobalContext.getContext().getObject('test_key')).assertTrue();
    })

    it('setObject_overwrite_shouldReturnNewValue', 0, () => {
      GlobalContext.getContext().setObject('test_key', 'value1');
      GlobalContext.getContext().setObject('test_key', 'value2');
      expect(GlobalContext.getContext().getObject('test_key')).assertEqual('value2');
    })

    it('getObject_withNonExistentKey_shouldReturnUndefined', 0, () => {
      expect(GlobalContext.getContext().getObject('non_existent') === undefined).assertTrue();
    })

    it('deleteObject_shouldRemoveKey', 0, () => {
      GlobalContext.getContext().setObject('test_key', 'test_value');
      GlobalContext.getContext().deleteObject('test_key');
      expect(GlobalContext.getContext().getObject('test_key') === undefined).assertTrue();
    })

    it('deleteObject_withNonExistentKey_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        GlobalContext.getContext().deleteObject('non_existent_key');
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })
  })
}
