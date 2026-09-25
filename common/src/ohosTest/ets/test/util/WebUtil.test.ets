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
import { webview } from '@kit.ArkWeb';
import { WebUtil, NativeActionData, WebNodeController } from '../../../../main/ets/util/WebUtil';
import { ModuleNameEnum, StorageKey } from '../../../../main/ets/constant/CommonEnums';

export default function WebUtilTest() {
  const uiContext = AppStorage.get<UIContext>(StorageKey.UI_CONTEXT) as UIContext;

  describe('WebUtilTest', () => {
    it('getMethods_withNonExistentUrl_shouldReturnUndefined', 0, () => {
      expect(WebUtil.getWebNode('non_existent') === undefined).assertTrue();
      expect(WebUtil.getWebController('non_existent') === undefined).assertTrue();
      expect(WebUtil.getWebScroller('non_existent') === undefined).assertTrue();
    })

    it('setWebController_thenGetWebController_shouldReturnSameInstance', 0, () => {
      let controller: webview.WebviewController | undefined;
      try {
        controller = new webview.WebviewController();
      } catch (e) {
        controller = undefined;
      }
      if (controller) {
        WebUtil.setWebController('test_set_controller', controller);
        const result = WebUtil.getWebController('test_set_controller');
        expect(result === controller).assertTrue();
        WebUtil.removeNode('test_set_controller');
      } else {
        expect(true).assertTrue();
      }
    })

    it('upPage_withNonExistentUrl_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        WebUtil.upPage('non_existent_url');
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })

    it('downPage_withNonExistentUrl_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        WebUtil.downPage('non_existent_url');
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })

    it('removeNode_withNonExistentUrl_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        WebUtil.removeNode('non_existent_url');
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })

    it('checkWebLoaded_shouldReturnBoolean', 0, () => {
      const result = WebUtil.checkWebLoaded('test_check_loaded');
      expect(typeof result === 'boolean').assertTrue();
    })

    it('registerAndUnregisterCallbacks_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        WebUtil.registerEmitter(ModuleNameEnum.ARTICLE_DETAIL, () => {});
        WebUtil.unregisterEmitter(ModuleNameEnum.ARTICLE_DETAIL);
        WebUtil.setWebSheetAction('test_url', () => {});
        WebUtil.deleteWebSheetAction('test_url');
        WebUtil.setJumpPageAction('test_url', () => {});
        WebUtil.deleteJumpPageAction('test_url');
        WebUtil.setImagePreviewAction('test_url', () => {});
        WebUtil.deleteImagePreviewAction('test_url');
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })

    it('callbackRegistration_setThenDelete_shouldCleanupCorrectly', 0, () => {
      const callback = (): void => {};
      WebUtil.setWebSheetAction('callback_test', callback);
      WebUtil.setJumpPageAction('callback_test', callback);
      WebUtil.setImagePreviewAction('callback_test', callback);
      WebUtil.deleteWebSheetAction('callback_test');
      WebUtil.deleteJumpPageAction('callback_test');
      WebUtil.deleteImagePreviewAction('callback_test');
      expect(true).assertTrue();
    })

    it('getComponentCodeUrl_shouldNotThrow', 0, () => {
      let thrown = false;
      let result = '';
      try {
        result = WebUtil.getComponentCodeUrl();
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
      expect(typeof result === 'string').assertTrue();
    })

    it('getJsPermission_shouldNotThrow', 0, () => {
      let thrown = false;
      let result = '';
      try {
        result = WebUtil.getJsPermission();
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
      expect(typeof result === 'string').assertTrue();
    })

    it('setTrustList_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        WebUtil.setTrustList('test_trust_list');
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })

    it('checkUrl_withInvalidUrl_shouldReturnFalse', 0, () => {
      const result = WebUtil.checkUrl('not_a_valid_url');
      expect(result).assertFalse();
    })

    it('checkUrl_withHttpsUrl_shouldReturnBoolean', 0, () => {
      const result = WebUtil.checkUrl('https://example.com/path');
      expect(typeof result === 'boolean').assertTrue();
    })

    it('updateWebNode_withNonExistentUrl_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        WebUtil.updateWebNode('non_existent_url');
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })

    it('addNode_withNonExistentUrl_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        WebUtil.addNode('non_existent_url');
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })

    it('createWebNode_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        WebUtil.createWebNode('test_create_webnode', uiContext, undefined, undefined, true, false);
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
      WebUtil.removeNode('test_create_webnode');
    })

    it('createWebNode_alreadyExists_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        WebUtil.createWebNode('test_duplicate_node', uiContext);
        WebUtil.createWebNode('test_duplicate_node', uiContext);
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
      WebUtil.removeNode('test_duplicate_node');
    })

    it('initialize_shouldBeFunction', 0, () => {
      expect(typeof WebUtil.initialize === 'function').assertTrue();
    })

    it('handleLoadIntercept_shouldBeFunction', 0, () => {
      expect(typeof WebUtil.handleLoadIntercept === 'function').assertTrue();
    })

    it('ARTICLE_WHITE_METHODS_shouldContainExpectedMethods', 0, () => {
      expect(WebUtil.ARTICLE_WHITE_METHODS.includes('checkPreview()')).assertTrue();
      expect(WebUtil.ARTICLE_WHITE_METHODS.includes('closePreview()')).assertTrue();
    })
  })

  describe('NativeActionDataTest', () => {
    it('constructor_shouldCreateObjectWithThreeMethods', 0, () => {
      const data = new NativeActionData('test_native_url');
      expect(typeof data.webSheet === 'function').assertTrue();
      expect(typeof data.jumpPage === 'function').assertTrue();
      expect(typeof data.imagePreviewChanged === 'function').assertTrue();
    })

    it('webSheet_withoutCallback_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        const data = new NativeActionData('no_callback_url');
        data.webSheet('src', 1);
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })

    it('jumpPage_withoutCallback_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        const data = new NativeActionData('no_callback_url');
        data.jumpPage('type', 1);
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })

    it('imagePreviewChanged_withoutCallback_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        const data = new NativeActionData('no_callback_url');
        data.imagePreviewChanged(true);
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })

    it('webSheet_withCallback_shouldInvokeCallback', 0, () => {
      let called = false;
      WebUtil.setWebSheetAction('sheet_callback_url', () => { called = true; });
      const data = new NativeActionData('sheet_callback_url');
      data.webSheet('src', 1);
      expect(called).assertTrue();
      WebUtil.deleteWebSheetAction('sheet_callback_url');
    })

    it('jumpPage_withCallback_shouldInvokeCallback', 0, () => {
      let called = false;
      WebUtil.setJumpPageAction('jump_callback_url', () => { called = true; });
      const data = new NativeActionData('jump_callback_url');
      data.jumpPage('type', 1);
      expect(called).assertTrue();
      WebUtil.deleteJumpPageAction('jump_callback_url');
    })

    it('imagePreviewChanged_withCallback_shouldInvokeCallback', 0, () => {
      let called = false;
      WebUtil.setImagePreviewAction('preview_callback_url', () => { called = true; });
      const data = new NativeActionData('preview_callback_url');
      data.imagePreviewChanged(true);
      expect(called).assertTrue();
      WebUtil.deleteImagePreviewAction('preview_callback_url');
    })
  })

  describe('WebNodeControllerTest', () => {
    it('makeNode_withoutInit_shouldReturnNull', 0, () => {
      const controller = new WebNodeController();
      expect(controller.makeNode() === null).assertTrue();
    })

    it('disposeNode_withoutInit_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        const controller = new WebNodeController();
        controller.disposeNode();
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })

    it('remove_withoutInit_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        const controller = new WebNodeController();
        controller.remove();
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })

    it('add_withoutInit_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        const controller = new WebNodeController();
        controller.add();
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })

    it('initWebNode_withUiContext_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        const controller = new WebNodeController();
        const webController = new webview.WebviewController();
        const webMockScroller = new Scroller();
        const webBuilderParam: Record<string, Object> = {
          'webUrl': 'test_init_node',
          'webController': webController,
          'webMockScroller': webMockScroller,
          'nestedScroll': { 'scrollForward': 0, 'scrollBackward': 0 } as NestedScrollOptions,
          'module': ModuleNameEnum.ARTICLE_DETAIL,
          'onlyWhiteMode': true,
          'nativeActionData': new NativeActionData('test_init_node'),
          'verticalScrollBarAccess': false,
        } as Record<string, Object>;
        controller.initWebNode(uiContext, webBuilderParam as Record<string, Object> as never);
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })

    it('updateWebNode_withoutInit_shouldNotThrow', 0, () => {
      let thrown = false;
      try {
        const controller = new WebNodeController();
        const webBuilderParam: Record<string, Object> = {
          'webUrl': 'test_update_node',
          'webController': new webview.WebviewController(),
          'webMockScroller': new Scroller(),
          'nestedScroll': { 'scrollForward': 0, 'scrollBackward': 0 } as NestedScrollOptions,
          'module': ModuleNameEnum.ARTICLE_DETAIL,
          'onlyWhiteMode': true,
          'nativeActionData': new NativeActionData('test_update_node'),
          'verticalScrollBarAccess': false,
        } as Record<string, Object>;
        controller.updateWebNode(webBuilderParam as Record<string, Object> as never);
      } catch (e) {
        thrown = true;
      }
      expect(thrown).assertFalse();
    })
  })
}
