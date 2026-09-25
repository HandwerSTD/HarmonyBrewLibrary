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
import { ColorUtil } from '../../../../main/ets/util/ColorUtil';

export default function ColorUtilTest() {
  describe('ColorUtilTest', () => {
    it('getDeepenImmersionColor_shouldReturn3ValuesInRange', 0, () => {
      const testCases: number[][] = [[0, 0, 0], [255, 255, 255], [255, 0, 0], [100, 150, 200]];
      testCases.forEach((rgb: number[]) => {
        const result = ColorUtil.getDeepenImmersionColor(rgb[0], rgb[1], rgb[2]);
        expect(result.length).assertEqual(3);
        expect(result[0] >= 0 && result[0] <= 255).assertTrue();
        expect(result[1] >= 0 && result[1] <= 255).assertTrue();
        expect(result[2] >= 0 && result[2] <= 255).assertTrue();
      });
    })

    it('getDeepenImmersionColor_withExceedingValues_shouldClamp', 0, () => {
      const result = ColorUtil.getDeepenImmersionColor(300, 300, 300);
      expect(result.length).assertEqual(3);
      expect(result[0] >= 0 && result[0] <= 255).assertTrue();
    })

    it('getDeepenImmersionColor_withNegativeValues_shouldClampToNonNegative', 0, () => {
      const result = ColorUtil.getDeepenImmersionColor(-10, -20, -30);
      expect(result.length).assertEqual(3);
      expect(result[0] >= 0).assertTrue();
      expect(result[1] >= 0).assertTrue();
      expect(result[2] >= 0).assertTrue();
    })

    it('getBlendColor_shouldReturnResourceColor', 0, () => {
      const result = ColorUtil.getBlendColor('test', Color.Red, Color.Blue);
      expect(result !== undefined).assertTrue();
      expect(result !== null).assertTrue();
    })

    it('getBlendColor_withBlackAndWhite_shouldReturnColor', 0, () => {
      const result = ColorUtil.getBlendColor('bw', Color.Black, Color.White);
      expect(result !== undefined).assertTrue();
    })

    it('getBlendColor_withSameColors_shouldReturnColor', 0, () => {
      const result = ColorUtil.getBlendColor('same', Color.Red, Color.Red);
      expect(result !== undefined).assertTrue();
    })
  })
}
