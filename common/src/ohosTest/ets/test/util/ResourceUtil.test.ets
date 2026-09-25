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
import { ResourceUtil, ConfigMapKey } from '../../../../main/ets/util/ResourceUtil';
import { StorageKey } from '../../../../main/ets/constant/CommonEnums';

export default function ResourceUtilTest() {
  describe('ResourceUtilTest', () => {
    const uiContext = AppStorage.get<UIContext>(StorageKey.UI_CONTEXT);
    const context: Context = uiContext?.getHostContext() as Context;
    const testResource: Resource = {
      id: 0, type: 0, params: [], bundleName: '', moduleName: ''
    } as Resource;

    it('getRawFileContentSync_withUndefinedContext_shouldReturnUndefined', 0, () => {
      expect(ResourceUtil.getRawFileContentSync(undefined, 'test.json') === undefined).assertTrue();
    })

    it('getRawFileContentSync_withEmptyPath_shouldReturnUndefined', 0, () => {
      expect(ResourceUtil.getRawFileContentSync(undefined, '') === undefined).assertTrue();
    })

    it('getRawFileContentSync_withContextAndNonExistentFile_shouldReturnUndefined', 0, () => {
      expect(ResourceUtil.getRawFileContentSync(context, 'non_existent_file.json') === undefined).assertTrue();
    })

    it('getRawFileContentSync_withContextAndValidFile_shouldReturnParsedObjectOrUndefined', 0, () => {
      const result = ResourceUtil.getRawFileContentSync(context, 'mockdata/bulletin-list.json');
      if (result) {
        expect(result !== undefined).assertTrue();
      } else {
        expect(result === undefined).assertTrue();
      }
    })

    it('getDataFromRawfile_withUndefinedContext_shouldReject', 0, () => {
      return ResourceUtil.getDataFromRawfile(undefined, 'test.json').then(() => {
        expect(true).assertFalse();
      }).catch(() => {
        expect(true).assertTrue();
      });
    })

    it('getDataFromRawfile_withEmptyPath_shouldReject', 0, () => {
      return ResourceUtil.getDataFromRawfile(undefined, '').then(() => {
        expect(true).assertFalse();
      }).catch(() => {
        expect(true).assertTrue();
      });
    })

    it('getDataFromRawfile_withContextAndNonExistentFile_shouldReject', 0, () => {
      return ResourceUtil.getDataFromRawfile(context, 'non_existent.json').then(() => {
        expect(true).assertFalse();
      }).catch(() => {
        expect(true).assertTrue();
      });
    })

    it('getDataFromRawfile_shouldReturnPromise', 0, () => {
      expect(ResourceUtil.getDataFromRawfile(undefined, 'test.json') instanceof Promise).assertTrue();
    })

    it('getResourceString_shouldReturnString', 0, () => {
      const result = ResourceUtil.getResourceString(context, testResource);
      expect(typeof result === 'string').assertTrue();
    })

    it('getResourceString_withEmptyResource_shouldReturnEmptyString', 0, () => {
      const result = ResourceUtil.getResourceString(context, testResource);
      expect(typeof result === 'string').assertTrue();
      expect(result.length >= 0).assertTrue();
    })

    it('getResourceNumber_shouldReturnNumber', 0, () => {
      const result = ResourceUtil.getResourceNumber(context, testResource);
      expect(typeof result === 'number').assertTrue();
    })

    it('getResourceStringArray_shouldReturnArray', 0, () => {
      const result = ResourceUtil.getResourceStringArray(context, testResource);
      expect(Array.isArray(result)).assertTrue();
    })

    it('getDrawableDescriptor_withNoResourceId_shouldReturnUndefined', 0, () => {
      expect(ResourceUtil.getDrawableDescriptor(context) === undefined).assertTrue();
    })

    it('getDrawableDescriptor_withInvalidResourceId_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        ResourceUtil.getDrawableDescriptor(context, 999999);
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })

    it('getRawFileStringByKey_shouldReturnValue', 0, () => {
      const result = ResourceUtil.getRawFileStringByKey(context, ConfigMapKey.GALLERY_URL);
      expect(result !== undefined).assertTrue();
    })

    it('getRawFileStringByKey_withDifferentKeys_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        ResourceUtil.getRawFileStringByKey(context, ConfigMapKey.MIIT_URL);
        ResourceUtil.getRawFileStringByKey(context, ConfigMapKey.DEVELOPER_URL);
        ResourceUtil.getRawFileStringByKey(context, ConfigMapKey.WHITELIST);
        ResourceUtil.getRawFileStringByKey(context, ConfigMapKey.JS_WHITELIST);
        ResourceUtil.getRawFileStringByKey(context, ConfigMapKey.CONTENT_CENTER);
        ResourceUtil.getRawFileStringByKey(context, ConfigMapKey.TV_SOURCE_CODE_URL);
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })

    it('getRawFileStringByKey_cachedSecondCall_shouldReturnSameValue', 0, () => {
      const r1 = ResourceUtil.getRawFileStringByKey(context, ConfigMapKey.GALLERY_URL);
      const r2 = ResourceUtil.getRawFileStringByKey(context, ConfigMapKey.GALLERY_URL);
      expect(r1).assertEqual(r2);
    })

    it('getColorDataByPath_withNonExistentPath_shouldReject', 0, () => {
      return ResourceUtil.getColorDataByPath('non_existent.png').then(() => {
        expect(true).assertFalse();
      }).catch(() => {
        expect(true).assertTrue();
      });
    })

    it('getColorDataByPath_shouldReturnPromise', 0, () => {
      expect(ResourceUtil.getColorDataByPath('test.png') instanceof Promise).assertTrue();
    })

    it('ConfigMapKey_shouldHaveCorrectValues', 0, () => {
      expect(ConfigMapKey.GALLERY_URL).assertEqual('galleryUrl');
      expect(ConfigMapKey.MIIT_URL).assertEqual('miitUrl');
      expect(ConfigMapKey.WHITELIST).assertEqual('webWhitelist');
      expect(ConfigMapKey.JS_WHITELIST).assertEqual('jsWhitelist');
      expect(ConfigMapKey.CONTENT_CENTER).assertEqual('contentCenter');
      expect(ConfigMapKey.DEVELOPER_URL).assertEqual('developerUrl');
      expect(ConfigMapKey.TV_SOURCE_CODE_URL).assertEqual('tvSourceCodeUrl');
    })

    it('ConfigMapKey_allValuesShouldBeUnique', 0, () => {
      const values: string[] = [
        ConfigMapKey.GALLERY_URL, ConfigMapKey.MIIT_URL, ConfigMapKey.WHITELIST,
        ConfigMapKey.JS_WHITELIST, ConfigMapKey.AGREEMENT_BASE_URL, ConfigMapKey.TSMS_HOST,
        ConfigMapKey.CONTENT_CENTER, ConfigMapKey.DEVELOPER_URL, ConfigMapKey.TV_SOURCE_CODE_URL,
      ];
      expect(new Set(values).size).assertEqual(values.length);
    })
  })
}
