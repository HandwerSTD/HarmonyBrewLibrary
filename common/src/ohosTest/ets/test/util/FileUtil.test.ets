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
import { FileUtil } from '../../../../main/ets/util/FileUtil';

export default function FileUtilTest() {
  describe('FileUtilTest', () => {
    it('isInvalidPath_shouldIdentifyInvalidPaths', 0, () => {
      expect(FileUtil.isInvalidPath(null)).assertTrue();
      expect(FileUtil.isInvalidPath(undefined)).assertTrue();
      expect(FileUtil.isInvalidPath('')).assertTrue();
      expect(FileUtil.isInvalidPath('../etc/passwd')).assertTrue();
      expect(FileUtil.isInvalidPath('/data/../etc')).assertTrue();
      expect(FileUtil.isInvalidPath('a'.repeat(256))).assertTrue();
    })

    it('isInvalidPath_shouldIdentifyValidPaths', 0, () => {
      expect(FileUtil.isInvalidPath('/data/local/tmp')).assertFalse();
      expect(FileUtil.isInvalidPath('a'.repeat(255))).assertFalse();
    })

    it('separator_shouldBeSlash', 0, () => {
      expect(FileUtil.separator).assertEqual('/');
    })

    it('isFileExist_withInvalidPath_shouldReturnFalse', 0, () => {
      expect(FileUtil.isFileExist('')).assertFalse();
      expect(FileUtil.isFileExist('../etc/passwd')).assertFalse();
    })

    it('isFileExist_withNonExistentFile_shouldReturnFalse', 0, () => {
      expect(FileUtil.isFileExist('/data/local/non_existent_file.txt')).assertFalse();
    })

    it('isDirExist_withInvalidPath_shouldReturnFalse', 0, () => {
      expect(FileUtil.isDirExist('')).assertFalse();
      expect(FileUtil.isDirExist('../etc')).assertFalse();
    })

    it('isDirExist_withNonExistentDir_shouldReturnFalse', 0, () => {
      expect(FileUtil.isDirExist('/data/local/non_existent_dir')).assertFalse();
    })

    it('makeDir_withInvalidPath_shouldReturnFalse', 0, () => {
      expect(FileUtil.makeDir('')).assertFalse();
      expect(FileUtil.makeDir('../invalid')).assertFalse();
    })

    it('makeDir_withExistingDir_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        FileUtil.makeDir('/data/local/tmp');
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })
  })
}
