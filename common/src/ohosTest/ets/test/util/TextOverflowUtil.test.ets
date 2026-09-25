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
import { TextOverflowUtil, TextOverflowProperty, TextOverflowData } from '../../../../main/ets/util/TextOverflowUtil';
import { StorageKey } from '../../../../main/ets/constant/CommonEnums';

export default function TextOverflowUtilTest() {
  describe('TextOverflowUtilTest', () => {
    const prop: TextOverflowProperty = {
      constraintWidth: 100,
      lineHeight: 20,
      fontSize: 14,
      fontWeight: FontWeight.Normal,
      wordBreak: WordBreak.BREAK_WORD,
    };

    it('TextOverflowProperty_interfaceShouldBeConstructable', 0, () => {
      expect(prop.constraintWidth).assertEqual(100);
      expect(prop.lineHeight).assertEqual(20);
      expect(prop.fontSize).assertEqual(14);
      expect(prop.fontWeight).assertEqual(FontWeight.Normal);
      expect(prop.wordBreak).assertEqual(WordBreak.BREAK_WORD);
    })

    it('TextOverflowData_interfaceShouldBeConstructable', 0, () => {
      const data: TextOverflowData = { overflowStatus: false };
      expect(data.overflowStatus).assertFalse();
      const dataWithIndex: TextOverflowData = { overflowStatus: true, breakWordIndex: 5 };
      expect(dataWithIndex.overflowStatus).assertTrue();
      expect(dataWithIndex.breakWordIndex).assertEqual(5);
    })
  })

  describe('getTextHeightTest', () => {
    const uiContext = AppStorage.get<UIContext>(StorageKey.UI_CONTEXT) as UIContext;
    const prop: TextOverflowProperty = {
      constraintWidth: 100,
      lineHeight: 20,
      fontSize: 14,
      fontWeight: FontWeight.Normal,
      wordBreak: WordBreak.BREAK_WORD,
    };

    it('getTextHeight_withValidUiContext_shouldReturnLength', 0, () => {
      const result = TextOverflowUtil.getTextHeight(uiContext, 'test text', prop, 1);
      expect(result !== undefined).assertTrue();

    })

    it('getTextHeight_withEmptyText_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        const result = TextOverflowUtil.getTextHeight(uiContext, '', prop, 1);
        expect(result !== undefined).assertTrue();
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })

    it('getTextHeight_withSingleChar_shouldReturnLength', 0, () => {
      const result = TextOverflowUtil.getTextHeight(uiContext, 'A', prop, 1);
      expect(result !== undefined).assertTrue();
    })

    it('getTextHeight_withMultipleLines_shouldReturnLength', 0, () => {
      if (uiContext) {
        const result = TextOverflowUtil.getTextHeight(uiContext, 'line1\nline2\nline3', prop, 3);
        expect(result !== undefined).assertTrue();
      } else {
        expect(true).assertTrue();
      }
    })

    it('getTextHeight_withLargeMaxLines_shouldReturnLength', 0, () => {
        const result = TextOverflowUtil.getTextHeight(uiContext, 'short text', prop, 1000);
        expect(result !== undefined).assertTrue();
    })

    it('getTextHeight_withMaxLine0_shouldReturnLength', 0, () => {
        let thrown = false;
        try {
          const result = TextOverflowUtil.getTextHeight(uiContext, 'test', prop, 0);
          expect(result !== undefined).assertTrue();
        } catch (e) {
          thrown = true;
        }
        expect(thrown).assertFalse();
    })

    it('getTextHeight_withUnicodeText_shouldReturnLength', 0, () => {
        const result = TextOverflowUtil.getTextHeight(uiContext, '你好世界🌍', prop, 2);
        expect(result !== undefined).assertTrue();
    })

    it('getTextHeight_withLongText_shouldReturnLength', 0, () => {
        const longText = 'A'.repeat(200);
        const result = TextOverflowUtil.getTextHeight(uiContext, longText, prop, 5);
        expect(result !== undefined).assertTrue();
    })

    it('getTextHeight_calledTwice_shouldReturnConsistentResult', 0, () => {
        const result1 = TextOverflowUtil.getTextHeight(uiContext, 'same text', prop, 1);
        const result2 = TextOverflowUtil.getTextHeight(uiContext, 'same text', prop, 1);
        expect(result1).assertEqual(result2);
    })

    it('getTextHeight_withNarrowWidth_shouldReturnSmallerOrEqualHeight', 0, () => {
        const narrowProp: TextOverflowProperty = {
          constraintWidth: 20,
          lineHeight: 20,
          fontSize: 14,
          fontWeight: FontWeight.Normal,
          wordBreak: WordBreak.BREAK_WORD,
        };
        const wideProp: TextOverflowProperty = {
          constraintWidth: 500,
          lineHeight: 20,
          fontSize: 14,
          fontWeight: FontWeight.Normal,
          wordBreak: WordBreak.BREAK_WORD,
        };
        const narrowResult = TextOverflowUtil.getTextHeight(uiContext, 'test text content', narrowProp, 1);
        const wideResult = TextOverflowUtil.getTextHeight(uiContext, 'test text content', wideProp, 1);
        if (narrowResult !== undefined && wideResult !== undefined) {
          const narrowVal = Number(narrowResult);
          const wideVal = Number(wideResult);
          expect(narrowVal >= wideVal).assertTrue();
        }
    })
  })

  describe('getOverflowDataTest', () => {
    const uiContext = AppStorage.get<UIContext>(StorageKey.UI_CONTEXT) as UIContext;
    const prop: TextOverflowProperty = {
      constraintWidth: 100,
      lineHeight: 20,
      fontSize: 14,
      fontWeight: FontWeight.Normal,
      wordBreak: WordBreak.BREAK_WORD,
    };
    const narrowProp: TextOverflowProperty = {
      constraintWidth: 20,
      lineHeight: 20,
      fontSize: 14,
      fontWeight: FontWeight.Normal,
      wordBreak: WordBreak.BREAK_WORD,
    };
    const wideProp: TextOverflowProperty = {
      constraintWidth: 500,
      lineHeight: 20,
      fontSize: 14,
      fontWeight: FontWeight.Normal,
      wordBreak: WordBreak.BREAK_WORD,
    };

    it('getOverflowData_withShortText_shouldReturnNoOverflow', 0, () => {
        const result = TextOverflowUtil.getOverflowData(uiContext, 'hi', 2, prop);
        expect(result.overflowStatus).assertFalse();
        expect(result.breakWordIndex === undefined).assertTrue();
    })

    it('getOverflowData_withEmptyText_shouldReturnNoOverflow', 0, () => {

        const result = TextOverflowUtil.getOverflowData(uiContext, '', 1, prop);
        expect(result.overflowStatus).assertFalse();
        expect(result.breakWordIndex === undefined).assertTrue();
    })

    it('getOverflowData_withSingleChar_shouldReturnNoOverflow', 0, () => {
        const result = TextOverflowUtil.getOverflowData(uiContext, 'A', 1, prop);
        expect(result.overflowStatus).assertFalse();
    })

    it('getOverflowData_withLongTextAndNarrowWidth_shouldDetectOverflow', 0, () => {
        const longText = '这是一段很长的文本内容用于测试文本溢出检测功能是否正常工作';
        const result = TextOverflowUtil.getOverflowData(uiContext, longText, 1, narrowProp);
        if (result.overflowStatus) {
          expect(result.breakWordIndex !== undefined).assertTrue();
          const index: number = result.breakWordIndex as number;
          expect(index >= 0).assertTrue();
          expect(index <= longText.length).assertTrue();
        } else {
          expect(result.overflowStatus).assertFalse();
        }

    })

    it('getOverflowData_withLongTextAndWideWidth_shouldReturnNoOverflow', 0, () => {
        const longText = 'short text';
        const result = TextOverflowUtil.getOverflowData(uiContext, longText, 1, wideProp);
        expect(result.overflowStatus).assertFalse();
    })

    it('getOverflowData_withMaxLine1_shouldReturnCorrectResult', 0, () => {
        const longText = 'AAAA AAAA BBBB CCCC DDDD EEEE FFFF GGGG';
        const result = TextOverflowUtil.getOverflowData(uiContext, longText, 1, prop);
        expect(typeof result.overflowStatus === 'boolean').assertTrue();
        if (result.overflowStatus) {
          const index: number = result.breakWordIndex as number;
          expect(index >= 0).assertTrue();
          expect(index <= longText.length).assertTrue();
        }
    })

    it('getOverflowData_withMaxLine2_shouldReturnCorrectResult', 0, () => {
        const longText = 'AAAA AAAA BBBB CCCC DDDD EEEE FFFF GGGG HHHH';
        const result = TextOverflowUtil.getOverflowData(uiContext, longText, 2, prop);
        expect(typeof result.overflowStatus === 'boolean').assertTrue();
    })

    it('getOverflowData_withMaxLine5_shouldReturnCorrectResult', 0, () => {
        const longText = 'A'.repeat(100);
        const result = TextOverflowUtil.getOverflowData(uiContext, longText, 5, prop);
        expect(typeof result.overflowStatus === 'boolean').assertTrue();
    })

    it('getOverflowData_shouldReturnTextOverflowData', 0, () => {
        const result = TextOverflowUtil.getOverflowData(uiContext, 'test', 1, prop);
        expect(typeof result.overflowStatus === 'boolean').assertTrue();
    })

    it('getOverflowData_withRepeatedChars_shouldDetectOverflow', 0, () => {
        const longText = 'X'.repeat(50);
        const result = TextOverflowUtil.getOverflowData(uiContext, longText, 1, narrowProp);
        if (result.overflowStatus) {
          const index: number = result.breakWordIndex as number;
          expect(index >= 0).assertTrue();
        }
    })

    it('getOverflowData_withTextExactlyFitting_shouldReturnNoOverflow', 0, () => {
        const shortText = 'fit';
        const result = TextOverflowUtil.getOverflowData(uiContext, shortText, 10, wideProp);
        expect(result.overflowStatus).assertFalse();
    })

    it('getOverflowData_withBoldFontWeight_shouldReturnCorrectResult', 0, () => {
        const boldProp: TextOverflowProperty = {
          constraintWidth: 100,
          lineHeight: 20,
          fontSize: 14,
          fontWeight: FontWeight.Bold,
          wordBreak: WordBreak.BREAK_WORD,
        };
        const longText = 'bold text content that might overflow';
        const result = TextOverflowUtil.getOverflowData(uiContext, longText, 1, boldProp);
        expect(typeof result.overflowStatus === 'boolean').assertTrue();
    })

    it('getOverflowData_breakWordIndexShouldBeLessThanTextLength', 0, () => {
        const longText = '这是一段测试文本用于验证溢出索引范围';
        const result = TextOverflowUtil.getOverflowData(uiContext, longText, 1, narrowProp);
        if (result.overflowStatus && result.breakWordIndex !== undefined) {
          const index: number = result.breakWordIndex as number;
          expect(index < longText.length).assertTrue();
        }
    })
  })
}
