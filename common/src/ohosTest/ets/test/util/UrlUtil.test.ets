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
import { UrlUtil } from '../../../../main/ets/util/UrlUtil';

export default function UrlUtilTest() {
  describe('UrlUtilTest', () => {
    it('isNetUrl_shouldIdentifyNetworkUrls', 0, () => {
      expect(UrlUtil.isNetUrl('https://example.com')).assertTrue();
      expect(UrlUtil.isNetUrl('http://example.com')).assertTrue();
      expect(UrlUtil.isNetUrl('HTTPS://example.com')).assertTrue();
      expect(UrlUtil.isNetUrl('HTTP://example.com')).assertTrue();
      expect(UrlUtil.isNetUrl('ftp://example.com')).assertFalse();
      expect(UrlUtil.isNetUrl('/local/path')).assertFalse();
      expect(UrlUtil.isNetUrl('')).assertFalse();
      expect(UrlUtil.isNetUrl('example.com')).assertFalse();
    })

    it('maskUrl_shouldHandleVariousUrls', 0, () => {
      expect(UrlUtil.maskUrl('')).assertEqual('');
      expect(UrlUtil.maskUrl('https://example.com/path?key=value')).assertEqual('https://example.com/path');
      expect(UrlUtil.maskUrl('https://example.com/path')).assertEqual('https://example.com/path');
    })
  })
}
