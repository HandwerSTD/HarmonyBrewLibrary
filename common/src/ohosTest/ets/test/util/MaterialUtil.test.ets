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
import { SegmentButtonOptions, SegmentButtonItemTuple, CommonModifier, SelectModifier } from '@kit.ArkUI';
import { MaterialUtil, CustomImmersiveStyle } from '../../../../main/ets/util/MaterialUtil';

interface TestOriginOption {
  test: string;
}

interface TestParam {
  style: CustomImmersiveStyle;
  backgroundColor: ResourceColor;
}

interface TestMaterialParam {
  originOption: TestOriginOption;
  param: TestParam;
}

export default function MaterialUtilTest() {
  describe('MaterialUtilTest', () => {
    it('getMaterialOptions_shouldReturnOriginOption', 0, () => {
      const originOption: TestOriginOption = { test: 'value' };
      const testParam: TestParam = { style: CustomImmersiveStyle.THIN, backgroundColor: Color.White };
      const param: TestMaterialParam = { originOption: originOption, param: testParam };
      const result = MaterialUtil.getMaterialOptions(param);
      expect(result).assertEqual(originOption);
    })

    it('getMaterialOptions_withDifferentOriginOption_shouldReturnSameInstance', 0, () => {
      const originOption: TestOriginOption = { test: 'other_value' };
      const testParam: TestParam = { style: CustomImmersiveStyle.REGULAR, backgroundColor: Color.Black };
      const param: TestMaterialParam = { originOption: originOption, param: testParam };
      const result = MaterialUtil.getMaterialOptions<TestOriginOption>(param);
      expect(result).assertEqual(originOption);
    })

    it('getSegmentMaterialOptions_shouldSetBackgroundColor', 0, () => {
      const options: SegmentButtonOptions = SegmentButtonOptions.capsule({
        buttons: [{ text: 'A' }, { text: 'B' }] as SegmentButtonItemTuple,
      });
      const result = MaterialUtil.getSegmentMaterialOptions(options, Color.Red);
      expect(result.backgroundColor).assertEqual(Color.Red);
    })

    it('getSegmentMaterialOptions_withoutBackgroundColor_shouldKeepOriginal', 0, () => {
      const options: SegmentButtonOptions = SegmentButtonOptions.capsule({
        buttons: [{ text: 'A' }, { text: 'B' }] as SegmentButtonItemTuple,
      });
      const result = MaterialUtil.getSegmentMaterialOptions(options);
      expect(result).assertEqual(options);
    })

    it('getSegmentMaterialOptions_shouldReturnSameOptionsInstance', 0, () => {
      const options: SegmentButtonOptions = SegmentButtonOptions.capsule({
        buttons: [{ text: 'A' }, { text: 'B' }] as SegmentButtonItemTuple,
      });
      const result = MaterialUtil.getSegmentMaterialOptions(options, Color.White);
      expect(result === options).assertTrue();
    })

    it('CustomImmersiveStyle_shouldHaveCorrectValues', 0, () => {
      expect(CustomImmersiveStyle.ULTRA_THIN).assertEqual(0);
      expect(CustomImmersiveStyle.THIN).assertEqual(1);
      expect(CustomImmersiveStyle.REGULAR).assertEqual(2);
      expect(CustomImmersiveStyle.THICK).assertEqual(3);
      expect(CustomImmersiveStyle.ULTRA_THICK).assertEqual(4);
    })

    it('getMaterialModifier_withBackgroundColor_shouldReturnModifier', 0, () => {
      const modifier = new CommonModifier();
      const result = MaterialUtil.getMaterialModifier({
        modifier: modifier,
        style: CustomImmersiveStyle.ULTRA_THIN,
        backgroundColor: Color.Red,
      });
      expect(result).assertEqual(modifier);
    })

    it('getMaterialModifier_withBackgroundBlurStyle_shouldReturnModifier', 0, () => {
      const modifier = new CommonModifier();
      const result = MaterialUtil.getMaterialModifier({
        modifier: modifier,
        style: CustomImmersiveStyle.THIN,
        backgroundColor: Color.White,
        backgroundBlurStyle: BlurStyle.Regular,
      });
      expect(result).assertEqual(modifier);
    })

    it('getMaterialModifier_withoutBackground_shouldReturnModifier', 0, () => {
      const modifier = new CommonModifier();
      const result = MaterialUtil.getMaterialModifier({
        modifier: modifier,
        style: CustomImmersiveStyle.REGULAR,
      });
      expect(result).assertEqual(modifier);
    })

    it('getMaterialModifier_shouldReturnSameModifierInstance', 0, () => {
      const modifier = new CommonModifier();
      const result = MaterialUtil.getMaterialModifier({
        modifier: modifier,
        style: CustomImmersiveStyle.THICK,
        backgroundColor: Color.Blue,
        backgroundBlurStyle: BlurStyle.Thin,
      });
      expect(result === modifier).assertTrue();
    })

    it('getSelectMaterialModifier_withBackgroundColor_shouldReturnModifier', 0, () => {
      const modifier = new SelectModifier();
      const result = MaterialUtil.getSelectMaterialModifier({
        modifier: modifier,
        style: CustomImmersiveStyle.ULTRA_THIN,
        backgroundColor: Color.Green,
      });
      expect(result).assertEqual(modifier);
    })

    it('getSelectMaterialModifier_withoutBackground_shouldReturnModifier', 0, () => {
      const modifier = new SelectModifier();
      const result = MaterialUtil.getSelectMaterialModifier({
        modifier: modifier,
        style: CustomImmersiveStyle.THIN,
      });
      expect(result).assertEqual(modifier);
    })

    it('getSelectMaterialModifier_shouldReturnSameModifierInstance', 0, () => {
      const modifier = new SelectModifier();
      const result = MaterialUtil.getSelectMaterialModifier({
        modifier: modifier,
        style: CustomImmersiveStyle.REGULAR,
        backgroundColor: Color.Red,
        backgroundBlurStyle: BlurStyle.Regular,
      });
      expect(result === modifier).assertTrue();
    })
  })
}
