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
import { FormatDate } from '../../../../main/ets/util/DateFormatUtil';

export default function DateFormatUtilTest() {
  describe('DateFormatUtilTest', () => {
    it('formatDate_withDefaultFormat_shouldReturnFullDateTime', 0, () => {
      const date = new Date(2026, 6, 31, 14, 30, 45);
      expect(FormatDate.formatDate(date)).assertEqual('2026-07-31 14:30:45');
    })

    it('formatDate_withYYYYMMDD_shouldReturnDateOnly', 0, () => {
      const date = new Date(2026, 0, 1, 10, 20, 30);
      expect(FormatDate.formatDate(date, 'YYYY-MM-DD')).assertEqual('2026-01-01');
    })

    it('formatDate_withYearFormats_shouldReturnCorrect', 0, () => {
      const date = new Date(2026, 0, 1);
      expect(FormatDate.formatDate(date, 'YYYY')).assertEqual('2026');
      expect(FormatDate.formatDate(date, 'YY')).assertEqual('26');
    })

    it('formatDate_withMonthFormats_shouldReturnCorrect', 0, () => {
      const date = new Date(2026, 2, 1);
      expect(FormatDate.formatDate(date, 'MM')).assertEqual('03');
      expect(FormatDate.formatDate(date, 'M')).assertEqual('3');
    })

    it('formatDate_withDayFormats_shouldReturnCorrect', 0, () => {
      const date = new Date(2026, 0, 5);
      expect(FormatDate.formatDate(date, 'DD')).assertEqual('05');
      expect(FormatDate.formatDate(date, 'D')).assertEqual('5');
    })

    it('formatDate_withHourFormats_shouldReturnCorrect', 0, () => {
      const morningDate = new Date(2026, 0, 1, 9, 0, 0);
      expect(FormatDate.formatDate(morningDate, 'HH')).assertEqual('09');
      const afternoonDate = new Date(2026, 0, 1, 14, 0, 0);
      expect(FormatDate.formatDate(afternoonDate, 'HH')).assertEqual('14');
    })

    it('formatDate_with12HourFormat_shouldReturnCorrect', 0, () => {
      const afternoonDate = new Date(2026, 0, 1, 14, 0, 0);
      expect(FormatDate.formatDate(afternoonDate, 'hh')).assertEqual('02');
      const midnightDate = new Date(2026, 0, 1, 0, 0, 0);
      expect(FormatDate.formatDate(midnightDate, 'hh')).assertEqual('12');
    })

    it('formatDate_withMinuteSecondFormats_shouldReturnCorrect', 0, () => {
      const date = new Date(2026, 0, 1, 10, 5, 9);
      expect(FormatDate.formatDate(date, 'mm')).assertEqual('05');
      expect(FormatDate.formatDate(date, 'm')).assertEqual('5');
      expect(FormatDate.formatDate(date, 'ss')).assertEqual('09');
      expect(FormatDate.formatDate(date, 's')).assertEqual('9');
    })

    it('formatDate_withMilliseconds_shouldReturnPadded3Digits', 0, () => {
      const date = new Date(2026, 0, 1, 0, 0, 0, 5);
      expect(FormatDate.formatDate(date, 'SSS')).assertEqual('005');
    })

    it('formatDate_withAMPM_shouldReturnCorrectPeriod', 0, () => {
      const morning = new Date(2026, 0, 1, 9, 0, 0);
      expect(FormatDate.formatDate(morning, 'A')).assertEqual('AM');
      expect(FormatDate.formatDate(morning, 'a')).assertEqual('am');
      const afternoon = new Date(2026, 0, 1, 15, 0, 0);
      expect(FormatDate.formatDate(afternoon, 'A')).assertEqual('PM');
      expect(FormatDate.formatDate(afternoon, 'a')).assertEqual('pm');
    })

    it('formatDate_withCustomFormat_shouldReturnCorrectly', 0, () => {
      const date = new Date(2026, 6, 31, 8, 5, 9);
      expect(FormatDate.formatDate(date, 'YYYY/MM/DD HH:mm:ss')).assertEqual('2026/07/31 08:05:09');
    })

    it('formatDate_withNoArgs_shouldUseCurrentDate', 0, () => {
      expect(FormatDate.formatDate().length > 0).assertTrue();
    })
  })
}
