/*
 * Copyright (c) 2024 Huawei Device Co., Ltd.
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

import type { Want } from '@kit.AbilityKit';
import { formBindingData, formInfo, formProvider } from '@kit.FormKit';
import { FormInfo, FormRdbHelper, Logger } from '@ohos/common';
import { LIVE_CARD_RATIO } from '@ohos/widgetcommon';
import { UpdateFormData } from '../widget/viewmodel/UpdateFormData';

const TAG: string = '[FormAbilityHelper]';

export class FormAbilityHelper {
  public doOnAddForm(context: Context, want: Want): formBindingData.FormBindingData {
    if (!want || !want.parameters) {
      Logger.error(TAG, 'FormAbility onAddForm want or want.parameters is undefined.');
      return formBindingData.createFormBindingData('');
    }
    const formName: string = want.parameters?.[formInfo.FormParam.NAME_KEY] as string;
    const formId: string = want.parameters?.[formInfo.FormParam.IDENTITY_KEY] as string;
    const formDimension = want.parameters?.[formInfo.FormParam.DIMENSION_KEY] as string;
    if (!formName || typeof formName !== 'string') {
      Logger.error(TAG, 'formName is invalid');
      return formBindingData.createFormBindingData('');
    }
    if (!formId || typeof formId !== 'string') {
      Logger.error(TAG, 'formId is invalid');
      return formBindingData.createFormBindingData('');
    }
    if (!formDimension || typeof formDimension !== 'string') {
      Logger.error(TAG, 'formDimension is invalid');
      return formBindingData.createFormBindingData('');
    }
    if (formName === 'ArticleServiceCard') {
      return UpdateFormData.init(formId);
    } else if (formName === 'hmos_3d_live_widget') {
      let formInfo = new FormInfo(formId, formName, formDimension);
      Logger.debug(TAG, `onAddForm formInfo: ${formInfo.formName}`);
      FormRdbHelper.getInstance(context).insertForm(formInfo);
      this.trigger3DLiveRequest(formId);
    }
    return formBindingData.createFormBindingData('');
  }

  public doOnCastToNormalForm(_formId: string) {
    // Called when the form provider is notified that a temporary form is successfully
    // converted to a normal form.
  }

  public doOnUpdateForm(context: Context, formId: string) {
    // Called to notify the form provider to update a specified form.
    UpdateFormData.update(formId);
    FormRdbHelper.getInstance(context)
      .queryFormById(formId)
      .then((formInfo) => {
        if (formInfo.formName === 'hmos_3d_live_widget') {
          this.trigger3DLiveRequest(formId);
        }
      })
  }

  public doOnFormEvent(_formId: string, _message: string) {
    // Called when a specified message event defined by the form provider is triggered.
    Logger.info(TAG, `onFormEvent`);
    try {
      const shortMessage: string = JSON.parse(_message)['message'];
      // When user click the card and triggered play of card's animation
      if (shortMessage === 'requestOverFlow') {
        this.trigger3DLiveRequest(_formId);
      }

      // set a update for card after 5min.
      formProvider.setFormNextRefreshTime(_formId, 6, (err: BusinessError) => {
        if (err) {
          Logger.error(TAG, `Failed to setFormNextRefreshTime. Code: ${err.code}, message: ${err.message}`);
          return;
        } else {
          Logger.info(TAG, `Succeeded in setFormNextRefreshTiming.`);
        }
      });
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      Logger.error(TAG, `Failed to setFormNextRefreshTime. Code: ${err.code}, message: ${err.message}`);
    }
  }

  public doOnRemoveForm(formId: string) {
    // Called to notify the form provider that a specified form has been destroyed.
    UpdateFormData.removeDataOfFormId(formId);
  }

  public doOnAcquireFormState(_want: Want): formInfo.FormState {
    // Called to return a {@link FormState} object.
    return formInfo.FormState.READY;
  }

  public doOnFormLocationChanged(formId: string, _newFormLocation: formInfo.FormLocation): void {
    this.trigger3DLiveRequest(formId);
  }

  private trigger3DLiveRequest(formId: string) {
    formProvider.getFormRect(formId).then((data: formInfo.Rect) => {
      // LIVE_CARD_RATIO: card becomes x time bigger.
      let cardWidth = data.width * LIVE_CARD_RATIO;
      let cardHeight = data.height * LIVE_CARD_RATIO;
      let leftOffset = (data.width - cardWidth) / 2;
      let topOffset = (data.height - cardHeight) / 2;
      formProvider.requestOverflow(formId, {
        area: {
          left: leftOffset,
          top: topOffset,
          width: cardWidth,
          height: cardHeight
        },
        duration: 3500
      }).then(() => {
        Logger.info(TAG, 'requestOverflow result succeed');
      }).catch((error: BusinessError) => {
        Logger.error(TAG, `requestOverflow catch error, code: ${error.code}, message: ${error.message}`);
      })
    }).catch((error: BusinessError) => {
      Logger.error(TAG, `getFormRect catch error, code: ${error.code}, message: ${error.message}`);
    })
    return;
  }
}