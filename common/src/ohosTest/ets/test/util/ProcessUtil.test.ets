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
import type { common, Want } from '@kit.AbilityKit';
import { ProcessUtil } from '../../../../main/ets/util/ProcessUtil';
import { StorageKey } from '../../../../main/ets/constant/CommonEnums';

export default function ProcessUtilTest() {
  describe('ProcessUtilTest', () => {
    const uiContext = AppStorage.get<UIContext>(StorageKey.UI_CONTEXT);
    const context: common.UIAbilityContext = uiContext?.getHostContext() as common.UIAbilityContext;

    it('moveAbilityToBackground_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        ProcessUtil.moveAbilityToBackground(context);
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })

    it('startAbility_shouldReturnPromise', 0, () => {
      const want: Want = { action: 'ohos.want.action.viewData', uri: 'https://example.com' };
      const result = ProcessUtil.startAbility(context, want);
      expect(result instanceof Promise).assertTrue();
    })

    it('startAbility_withValidWant_shouldResolveOrReject', 0, () => {
      const want: Want = { action: 'ohos.want.action.viewData', uri: 'https://example.com' };
      return ProcessUtil.startAbility(context, want).then((result: boolean) => {
        expect(typeof result === 'boolean').assertTrue();
      });
    })

    it('startAbility_withDangerousScheme_shouldReturnFalse', 0, () => {
      const want: Want = { action: 'ohos.want.action.viewData', uri: 'javascript:alert(1)' };
      return ProcessUtil.startAbility(context, want).then((result: boolean) => {
        expect(result).assertFalse();
      });
    })

    it('startAbility_withDataScheme_shouldReturnFalse', 0, () => {
      const want: Want = { action: 'ohos.want.action.viewData', uri: 'data:text/html,<script>alert(1)</script>' };
      return ProcessUtil.startAbility(context, want).then((result: boolean) => {
        expect(result).assertFalse();
      });
    })

    it('startAbility_withFileScheme_shouldReturnFalse', 0, () => {
      const want: Want = { action: 'ohos.want.action.viewData', uri: 'file:///etc/passwd' };
      return ProcessUtil.startAbility(context, want).then((result: boolean) => {
        expect(result).assertFalse();
      });
    })

    it('startAbility_withDisallowedAction_shouldReturnFalse', 0, () => {
      const want: Want = { action: 'ohos.want.action.invalidAction', uri: 'https://example.com' };
      return ProcessUtil.startAbility(context, want).then((result: boolean) => {
        expect(result).assertFalse();
      });
    })

    it('startAbility_withNoUri_shouldResolveOrReject', 0, () => {
      const want: Want = { action: 'ohos.want.action.viewData' };
      return ProcessUtil.startAbility(context, want).then((result: boolean) => {
        expect(typeof result === 'boolean').assertTrue();
      });
    })

    it('exitApp_shouldBeFunction', 0, () => {
      expect(typeof ProcessUtil.exitApp === 'function').assertTrue();
    })

    // The following method will kill the process when executed, and terminal unit test.
    it('terminateAbility_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        ProcessUtil.terminateAbility(context);
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })

    it('killAllAbility_shouldReturnPromise', 0, () => {
      const result = ProcessUtil.killAllAbility(context);
      expect(result instanceof Promise).assertTrue();
    })

    it('killAllAbility_shouldResolveOrReject', 0, () => {
      return ProcessUtil.killAllAbility(context).then((result: boolean) => {
        expect(typeof result === 'boolean').assertTrue();
      }).catch(() => {
        expect(true).assertTrue();
      });
    })

    it('exitApp_shouldExecuteLast', 0, () => {
      ProcessUtil.exitApp();
      expect(true).assertTrue();
    })
  })
}
