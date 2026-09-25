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

import { Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { formBindingData, FormExtensionAbility, formInfo, formProvider } from '@kit.FormKit';
import { UpdateFormData } from '@ohos/abilitycommon/src/main/ets/widget/viewmodel/UpdateFormData';
import { FormInfo, FormRdbHelper, Logger } from '@ohos/common';

const TAG: string = '[PcFormAbility]';

export default class PcFormAbility extends FormExtensionAbility {
  onAddForm(want: Want) {
    if (!want || !want.parameters) {
      Logger.error(TAG, 'FormAbility onAddForm want or want.parameters is undefined.');
      return formBindingData.createFormBindingData('');
    }
    const formName: string = want.parameters?.[formInfo.FormParam.NAME_KEY] as string;
    const formId: string = want.parameters?.[formInfo.FormParam.IDENTITY_KEY] as string;
    const formDimension = want.parameters?.[formInfo.FormParam.DIMENSION_KEY] as string;
    if (formName === 'ArticleServiceCard' && formId) {
      return UpdateFormData.init(formId);
    } else if (formName === 'hmos_3d_live_widget' && formId) {
      let formInfo = new FormInfo(formId, formName, formDimension);
      Logger.info(TAG, `onAddForm formInfo: ${formInfo.formName}`);
      FormRdbHelper.getInstance(this.context)
        .insertForm(formInfo)
        .catch((err: BusinessError) => {
          Logger.error(TAG, `insertForm failed: code ${err.code}, message ${err.message}`);
        });
    }
    return formBindingData.createFormBindingData('');
  }

  onCastToNormalForm(formId: string) {
    // Called when the form provider is notified that a temporary form is successfully
    // converted to a normal form.
  }

  onUpdateForm(formId: string) {
    // Called to notify the form provider to update a specified form.
  }

  onFormEvent(formId: string, message: string) {
    // Called when a specified message event defined by the form provider is triggered.
    Logger.info(TAG, `onFormEvent`);
    try {
      // set a update for card after 5min.
      formProvider.setFormNextRefreshTime(formId, 6, (err: BusinessError) => {
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

  onRemoveForm(formId: string) {
    // Called to notify the form provider that a specified form has been destroyed.
    UpdateFormData.removeDataOfFormId(formId);
  }

  onAcquireFormState(want: Want) {
    // Called to return a {@link FormState} object.
    return formInfo.FormState.READY;
  }
};