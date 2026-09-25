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
import Logger from '../../../../main/ets/util/Logger';

export default function LoggerTest() {
  describe('LoggerTest', () => {
    it('allLogMethods_withVariousArgs_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        Logger.debug('debug message');
        Logger.debug('arg1', 'arg2', 123, true);
        Logger.debug();
        Logger.info('info message');
        Logger.info('arg1', 'arg2', 456, false);
        Logger.info();
        Logger.warn('warn message');
        Logger.warn('arg1', 'arg2', 789, true);
        Logger.warn();
        Logger.error('error message');
        Logger.error('arg1', 'arg2', 999, false);
        Logger.error();
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })

    it('allMethods_inSequence_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        Logger.debug('debug');
        Logger.info('info');
        Logger.warn('warn');
        Logger.error('error');
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })
  })
}
