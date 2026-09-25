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
import { window } from '@kit.ArkUI';
import type { common } from '@kit.AbilityKit';
import { WindowUtil, StatusBarColorType, ScreenOrientation } from '../../../../main/ets/util/WindowUtil';
import { StorageKey } from '../../../../main/ets/constant/CommonEnums';

export default function WindowUtilTest() {
  describe('WindowUtilTest', () => {
    const uiContext = AppStorage.get<UIContext>(StorageKey.UI_CONTEXT);
    const context: common.UIAbilityContext = uiContext?.getHostContext() as common.UIAbilityContext;

    it('updateStatusBarColor_withDarkAndLight_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        WindowUtil.updateStatusBarColor(true);
        WindowUtil.updateStatusBarColor(false);
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })

    it('updateStatusBarColor_repeatedCalls_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        for (let i = 0; i < 5; i++) {
          WindowUtil.updateStatusBarColor(i % 2 === 0);
        }
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })

    it('enableFloatWindowRotate_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        WindowUtil.enableFloatWindowRotate();
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })

    it('disableFloatWindowRotate_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        WindowUtil.disableFloatWindowRotate();
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })

    it('enableThenDisableFloatWindowRotate_sequence_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        WindowUtil.enableFloatWindowRotate();
        WindowUtil.disableFloatWindowRotate();
        WindowUtil.enableFloatWindowRotate();
        WindowUtil.disableFloatWindowRotate();
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })

    it('setMainWindowOrientation_withAllOrientations_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        WindowUtil.setMainWindowOrientation(window.Orientation.PORTRAIT);
        WindowUtil.setMainWindowOrientation(window.Orientation.LANDSCAPE);
        WindowUtil.setMainWindowOrientation(window.Orientation.PORTRAIT_INVERTED);
        WindowUtil.setMainWindowOrientation(window.Orientation.LANDSCAPE_INVERTED);
        WindowUtil.setMainWindowOrientation(window.Orientation.AUTO_ROTATION);
        WindowUtil.setMainWindowOrientation(window.Orientation.UNSPECIFIED);
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })

    it('setMainWindowOrientation_withCallback_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        WindowUtil.setMainWindowOrientation(window.Orientation.UNSPECIFIED, () => {});
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })

    it('setMainWindowOrientation_repeatedSameOrientation_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        WindowUtil.setMainWindowOrientation(window.Orientation.PORTRAIT);
        WindowUtil.setMainWindowOrientation(window.Orientation.PORTRAIT);
        WindowUtil.setMainWindowOrientation(window.Orientation.PORTRAIT);
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })

    it('release_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        WindowUtil.release();
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })

    it('release_multipleCalls_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        WindowUtil.release();
        WindowUtil.release();
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })

    it('initialize_shouldBeFunction', 0, () => {
      expect(typeof WindowUtil.initialize === 'function').assertTrue();
    })

    it('setWindowSize_withUndefined_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        WindowUtil.setWindowSize(undefined);
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })

    it('setMissionContinueActive_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        WindowUtil.setMissionContinueActive(context, true);
        WindowUtil.setMissionContinueActive(context, false);
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })

    it('setAvoidArea_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
          const avoidArea: window.AvoidArea = {
            visible: true,
            topRect: { top: 0, width: 100, left: 0, height: 0 },
            bottomRect: { top: 0, width: 0, left: 0, height: 0 },
            leftRect: { top: 0, width: 0, left: 0, height: 0 },
            rightRect: { top: 0, width: 0, left: 0, height: 0 },
          } as window.AvoidArea;
          WindowUtil.setAvoidArea(window.AvoidAreaType.TYPE_SYSTEM, avoidArea);
          WindowUtil.setAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR, avoidArea);
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })

    it('StatusBarColorType_shouldHaveCorrectValues', 0, () => {
      expect(StatusBarColorType.WHITE).assertEqual('#ffffff');
      expect(StatusBarColorType.BLACK).assertEqual('#E5000000');
    })

    it('ScreenOrientation_shouldHaveCorrectValues', 0, () => {
      expect(ScreenOrientation.PORTRAIT).assertEqual('portrait');
      expect(ScreenOrientation.LANDSCAPE).assertEqual('landscape');
    })
  })
}
