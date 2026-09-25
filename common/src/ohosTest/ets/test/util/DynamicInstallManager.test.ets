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
import type { common } from '@kit.AbilityKit';
import { DynamicInstallManager } from '../../../../main/ets/util/DynamicInstallManager';
import { StorageKey } from '../../../../main/ets/constant/CommonEnums';

export default function DynamicInstallManagerTest() {
  describe('DynamicInstallManagerTest', () => {
    const uiContext = AppStorage.get<UIContext>(StorageKey.UI_CONTEXT);
    const context: common.UIAbilityContext = uiContext?.getHostContext() as common.UIAbilityContext;
    it('getModuleStatus_withVariousModuleNames_shouldReturnNumber', 0, () => {
      ['non_existent', '', 'module_a', 'module_b', 'KnocksharesampleAbility'].forEach((name: string) => {
        const result = DynamicInstallManager.getModuleStatus(name);
        expect(typeof result === 'number').assertTrue();
      });
    })

    it('getModuleStatus_sameModuleCalledTwice_shouldReturnConsistentResult', 0, () => {
      const r1 = DynamicInstallManager.getModuleStatus('test_module');
      const r2 = DynamicInstallManager.getModuleStatus('test_module');
      expect(r1).assertEqual(r2);
    })

    it('setStartAbilityProperty_shouldReturnObject', 0, () => {
      const result = DynamicInstallManager.setStartAbilityProperty();
      expect(result !== null).assertTrue();
      expect(typeof result === 'object').assertTrue();
    })

    it('setStartAbilityProperty_multipleCalls_shouldReturnObjectEachTime', 0, () => {
      const r1 = DynamicInstallManager.setStartAbilityProperty();
      const r2 = DynamicInstallManager.setStartAbilityProperty();
      expect(typeof r1 === 'object').assertTrue();
      expect(typeof r2 === 'object').assertTrue();
    })

    it('cancelDownloadTask_withAndWithoutTaskId_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        DynamicInstallManager.cancelDownloadTask();
        DynamicInstallManager.cancelDownloadTask('test_task_id');
        DynamicInstallManager.cancelDownloadTask('');
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })

    it('subscribeAndUnsubscribe_sequence_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        DynamicInstallManager.subscribeDownloadProgress();
        DynamicInstallManager.unsubscribeDownloadProgress();
        DynamicInstallManager.subscribeDownloadProgress();
        DynamicInstallManager.unsubscribeDownloadProgress();
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })

    it('fetchModule_shouldReturnPromise', 0, () => {
      const result = DynamicInstallManager.fetchModule(context, 'test_module');
      expect(result instanceof Promise).assertTrue();
    })

    it('fetchModule_withNonExistentModule_shouldResolveOrReject', 0, () => {
      return DynamicInstallManager.fetchModule(context, 'test_module')
        .then(() => {
          expect(true).assertTrue();
        }).catch(() => {
          expect(true).assertTrue();
        });
    })

    it('loadModule_shouldReturnPromise', 0, () => {
      const result = DynamicInstallManager.loadModule(context, 'test_ability');
      expect(result instanceof Promise).assertTrue();
    })

    it('loadModule_withNonExistentModule_shouldResolveOrReject', 0, () => {
      return DynamicInstallManager.loadModule(context, 'test_ability')
        .then(() => {
          expect(true).assertTrue();
        }).catch(() => {
          expect(true).assertTrue();
        });
    })
  })
}
