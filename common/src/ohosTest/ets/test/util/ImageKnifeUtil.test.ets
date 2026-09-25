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
import { ImageKnifeUtil } from '../../../../main/ets/util/ImageKnifeUtil';
import { StorageKey } from '../../../../main/ets/constant/CommonEnums';

export default function ImageKnifeUtilTest() {
  describe('ImageKnifeUtilTest', () => {
    const uiContext = AppStorage.get<UIContext>(StorageKey.UI_CONTEXT);
    const context: Context = uiContext?.getHostContext() as Context;
    it('getImgOption_withEmptyUrl_shouldReturnEmptyLoadSrc', 0, () => {
      expect(ImageKnifeUtil.getImgOption('').loadSrc).assertEqual('');
    })

    it('getImgOption_withValidUrlAndSig_shouldReturnCorrectOption', 0, () => {
      const result = ImageKnifeUtil.getImgOption('https://example.com/image.png?tag=abc123');
      expect(result.loadSrc !== undefined).assertTrue();
      expect(result.signature).assertEqual('abc123');
    })

    it('initialize_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        ImageKnifeUtil.initialize(context);
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })

    it('preloadImg_withNonNetUrl_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        ImageKnifeUtil.preloadImg('local/path/image.png');
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })

    it('preloadImg_withEmptyUrl_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        ImageKnifeUtil.preloadImg('');
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })

    it('preloadImg_withHttpsUrl_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        ImageKnifeUtil.preloadImg('https://example.com/image.png');
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })
  })
}
