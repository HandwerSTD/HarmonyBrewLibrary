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
import { BreakpointType } from '../../../../main/ets/util/BreakpointSystem';

export default function BreakpointSystemTest() {
  describe('BreakpointSystemTest', () => {
    it('getValue_withAllBreakpoints_shouldReturnCorrectValue', 0, () => {
      const bp = new BreakpointType<number>({ xs: 0, sm: 1, md: 2, lg: 3, xl: 4 });
      expect(bp.getValue(WidthBreakpoint.WIDTH_XS)).assertEqual(0);
      expect(bp.getValue(WidthBreakpoint.WIDTH_SM)).assertEqual(1);
      expect(bp.getValue(WidthBreakpoint.WIDTH_MD)).assertEqual(2);
      expect(bp.getValue(WidthBreakpoint.WIDTH_LG)).assertEqual(3);
      expect(bp.getValue(WidthBreakpoint.WIDTH_XL)).assertEqual(4);
    })

    it('getValue_withNoXs_shouldFallbackToSm', 0, () => {
      const bp = new BreakpointType<number>({ sm: 1, md: 2, lg: 3 });
      expect(bp.getValue(WidthBreakpoint.WIDTH_XS)).assertEqual(1);
    })

    it('getValue_withNoXl_shouldFallbackToLg', 0, () => {
      const bp = new BreakpointType<number>({ sm: 1, md: 2, lg: 3 });
      expect(bp.getValue(WidthBreakpoint.WIDTH_XL)).assertEqual(3);
    })

    it('getValue_withUnknownBreakpoint_shouldReturnLg', 0, () => {
      const bp = new BreakpointType<number>({ sm: 1, md: 2, lg: 3 });
      expect(bp.getValue(99 as WidthBreakpoint)).assertEqual(3);
    })

    it('getValue_withStringType_shouldReturnCorrectValues', 0, () => {
      const bp = new BreakpointType<string>({ sm: 'small', md: 'medium', lg: 'large' });
      expect(bp.getValue(WidthBreakpoint.WIDTH_SM)).assertEqual('small');
      expect(bp.getValue(WidthBreakpoint.WIDTH_MD)).assertEqual('medium');
      expect(bp.getValue(WidthBreakpoint.WIDTH_LG)).assertEqual('large');
    })

    it('getValue_withBooleanType_shouldReturnCorrectValues', 0, () => {
      const bp = new BreakpointType<boolean>({ sm: false, md: true, lg: true });
      expect(bp.getValue(WidthBreakpoint.WIDTH_SM)).assertFalse();
      expect(bp.getValue(WidthBreakpoint.WIDTH_MD)).assertTrue();
    })
  })
}
