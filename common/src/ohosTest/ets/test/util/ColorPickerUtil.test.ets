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
import { ColorPickerUtil } from '../../../../main/ets/util/ColorPickerUtil';

export default function ColorPickerUtilTest() {
  describe('ColorPickerUtilTest', () => {
    it('setRgba_shouldReturnFormattedString', 0, () => {
      expect(ColorPickerUtil.setRgba(255, 0, 0, 1)).assertEqual('rgba(255,0,0,1)');
      expect(ColorPickerUtil.setRgba(100, 200, 50, 0.5)).assertEqual('rgba(100,200,50,0.5)');
    })

    it('getBlockColor_withOutOfRange_shouldReturnEmptyString', 0, () => {
      expect(ColorPickerUtil.getBlockColor(-1)).assertEqual('');
      expect(ColorPickerUtil.getBlockColor(101)).assertEqual('');
    })

    it('getBlockColor_with0_shouldReturnRed', 0, () => {
      expect(ColorPickerUtil.getBlockColor(0).startsWith('rgba(255,')).assertTrue();
    })

    it('getBlockColor_with100_shouldReturnRed', 0, () => {
      expect(ColorPickerUtil.getBlockColor(100).startsWith('rgba(255,')).assertTrue();
    })

    it('getBlockColor_withValidValue_shouldReturnRgbaString', 0, () => {
      const result = ColorPickerUtil.getBlockColor(50);
      expect(result.startsWith('rgba(')).assertTrue();
      expect(result.endsWith(')')).assertTrue();
    })

    it('getRgb_withValidRgba_shouldReturnRgbArray', 0, () => {
      const result = ColorPickerUtil.getRgb('rgba(100,200,50,0.5)');
      expect(result.length).assertEqual(3);
      expect(result[0]).assertEqual(100);
      expect(result[1]).assertEqual(200);
      expect(result[2]).assertEqual(50);
    })

    it('getRgb_withInvalidInput_shouldReturnZeros', 0, () => {
      const result1 = ColorPickerUtil.getRgb('rgb');
      expect(result1[0]).assertEqual(0);
      expect(result1[1]).assertEqual(0);
      expect(result1[2]).assertEqual(0);
      const result2 = ColorPickerUtil.getRgb('rgba(invalid)');
      expect(result2[0]).assertEqual(0);
    })

    it('getColorFromRgb_withPureRed_shouldReturn0', 0, () => {
      expect(ColorPickerUtil.getColorFromRgb('rgba(255,0,0,1)')).assertEqual(0);
    })

    it('getColorFromRgb_withPureGreen_shouldReturn33', 0, () => {
      const result = ColorPickerUtil.getColorFromRgb('rgba(0,255,0,1)');
      expect(result > 0).assertTrue();
    })

    it('getColorFromRgb_withPureBlue_shouldReturn67', 0, () => {
      const result = ColorPickerUtil.getColorFromRgb('rgba(0,0,255,1)');
      expect(result > 0).assertTrue();
    })

    it('getColorFromRgb_roundTrip_shouldBeInRange0To100', 0, () => {
      const testValues = [0, 10, 25, 50, 75, 90, 100];
      testValues.forEach((val: number) => {
        const rgba = ColorPickerUtil.getBlockColor(val);
        const result = ColorPickerUtil.getColorFromRgb(rgba);
        expect(result >= 0 && result <= 100).assertTrue();
      })
    })
  })
}
