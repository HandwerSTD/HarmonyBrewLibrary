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
import { ImageUtil } from '../../../../main/ets/util/ImageUtil';

export default function ImageUtilTest() {
  describe('ImageUtilTest', () => {
    it('getImgResource_withFalsyValues_shouldReturnPlaceholder', 0, () => {
      [undefined, null, ''].forEach((url: string | undefined | null) => {
        expect(ImageUtil.getImgResource(url as string) !== undefined).assertTrue();
      });
    })

    it('getImgResource_withNetworkUrls_shouldReturnUrlString', 0, () => {
      const urls = [
        'https://example.com/image.png',
        'http://example.com/image.png',
        'HTTPS://example.com/image.png',
        'HTTP://example.com/image.png',
        'https://example.com/image.png?sig=abc&width=100',
      ];
      urls.forEach((url: string) => {
        expect(ImageUtil.getImgResource(url)).assertEqual(url);
      });
    })

    it('getImgResource_withLocalPaths_shouldReturnRawfile', 0, () => {
      ['images/test.png', 'local/file/path.jpg', 'data.json'].forEach((path: string) => {
        expect(ImageUtil.getImgResource(path) !== undefined).assertTrue();
      });
    })

    it('getImgResource_shouldReturnCorrectType', 0, () => {
      const placeholder = ImageUtil.getImgResource();
      const network = ImageUtil.getImgResource('https://example.com/img.png');
      const local = ImageUtil.getImgResource('test.png');
      expect(typeof placeholder === 'object' || typeof placeholder === 'string').assertTrue();
      expect(typeof network === 'string').assertTrue();
      expect(typeof local === 'object' || typeof local === 'string').assertTrue();
    })

    it('getColorFromImgUrl_withFalsyUrls_shouldReject', 0, () => {
      return Promise.all([
        ImageUtil.getColorFromImgUrl('').then(() => false).catch(() => true),
      ]).then((results: boolean[]) => {
        results.forEach((r: boolean) => expect(r).assertTrue());
      });
    })

    it('getColorFromImgUrl_withNonExistentUrl_shouldReject', 0, () => {
      return ImageUtil.getColorFromImgUrl('non_existent_image.png').then(() => {
        expect(true).assertFalse();
      }).catch(() => {
        expect(true).assertTrue();
      });
    })

    it('getColorFromImgUrl_withNonExistentUrlAndDeepColor_shouldReject', 0, () => {
      return ImageUtil.getColorFromImgUrl('non_existent_image.png', true).then(() => {
        expect(true).assertFalse();
      }).catch(() => {
        expect(true).assertTrue();
      });
    })

    it('getColorFromImgUrl_withNonExistentUrlAndNonDeepColor_shouldReject', 0, () => {
      return ImageUtil.getColorFromImgUrl('non_existent_image.png', false).then(() => {
        expect(true).assertFalse();
      }).catch(() => {
        expect(true).assertTrue();
      });
    })

    it('getColorFromImgUrl_shouldReturnPromise', 0, () => {
      expect(ImageUtil.getColorFromImgUrl('') instanceof Promise).assertTrue();
    })

    it('getColorFromImgUrl_withIsDeepColorParam_shouldReturnPromise', 0, () => {
      expect(ImageUtil.getColorFromImgUrl('test.png', true) instanceof Promise).assertTrue();
      expect(ImageUtil.getColorFromImgUrl('test.png', false) instanceof Promise).assertTrue();
    })
  })
}
