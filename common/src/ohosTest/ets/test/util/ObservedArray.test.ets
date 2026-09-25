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
import { ObservedArray } from '../../../../main/ets/util/ObservedArray';

export default function ObservedArrayTest() {
  describe('ObservedArrayTest', () => {
    it('constructor_withVariousInputs_shouldCreateCorrectArray', 0, () => {
      expect(new ObservedArray<number>().length).assertEqual(0);
      expect(new ObservedArray<number>([]).length).assertEqual(0);
      const arr = new ObservedArray<number>([1, 2, 3]);
      expect(arr.length).assertEqual(3);
      expect(arr[0]).assertEqual(1);
      expect(arr[1]).assertEqual(2);
      expect(arr[2]).assertEqual(3);
    })

    it('constructor_shouldNotModifySourceArray', 0, () => {
      const source = [1, 2, 3];
      new ObservedArray<number>(source);
      expect(source.length).assertEqual(3);
    })

    it('push_and_pop_shouldWorkAsExpected', 0, () => {
      const arr = new ObservedArray<number>();
      arr.push(1);
      expect(arr.length).assertEqual(1);
      expect(arr[0]).assertEqual(1);
      const last = arr.pop();
      expect(last).assertEqual(1);
      expect(arr.length).assertEqual(0);
    })

    it('splice_shouldRemoveAndInsert', 0, () => {
      const arr = new ObservedArray<number>([1, 2, 3, 4]);
      arr.splice(1, 2, 9);
      expect(arr.length).assertEqual(3);
      expect(arr[0]).assertEqual(1);
      expect(arr[1]).assertEqual(9);
      expect(arr[2]).assertEqual(4);
    })

    it('arrayMethods_shouldWorkCorrectly', 0, () => {
      const arr = new ObservedArray<number>([1, 2, 3, 4, 5]);
      let sum = 0;
      arr.forEach((item: number) => { sum += item; });
      expect(sum).assertEqual(15);
      const mapped = arr.map((item: number) => item * 2);
      expect(mapped[0]).assertEqual(2);
      expect(mapped[4]).assertEqual(10);
      const filtered = arr.filter((item: number) => item > 2);
      expect(filtered.length).assertEqual(3);
    })
  })
}
