/*
 * Copyright (c) 2025 Huawei Device Co., Ltd.
 * Licensed under the Apache License,Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { relationalStore } from '@kit.ArkData';
import Logger from '../util/Logger';
import { FormInfo } from '../viewmodel/FormInfo';
import { RdbUtils } from './RdbUtils';

const TAG = 'FormRdbHelper';

const SQL_CREATE_TABLE: string =
  'CREATE TABLE IF NOT EXISTS FormInfoTable(formId STRING PRIMARY KEY, formName STRING, formDimension STRING)';

const TABLE_NAME = 'FormInfoTable';
let rdbUtils: RdbUtils;

export class FormRdbHelper {
  private static instance: FormRdbHelper | undefined;

  private constructor(context: Context) {
    Logger.info(TAG, `constructor Context: ${context}`);
    rdbUtils = new RdbUtils(context, TABLE_NAME, SQL_CREATE_TABLE);
  }

  destroyer() {
    rdbUtils.destroyer()
      .then(() => {
        FormRdbHelper.instance = undefined;
        Logger.info(TAG, `rdbUtils closed, ${TAG} destoryed.`)
      })
  }

  public static getInstance(context: Context): FormRdbHelper {
    if (!FormRdbHelper.instance) {
      FormRdbHelper.instance = new FormRdbHelper(context);
    }
    return FormRdbHelper.instance;
  }

  public insertForm(formInfo: FormInfo): Promise<number> {
    Logger.info(TAG, `insertForm formInfo: ${formInfo.formName}`);
    let valueBucket = this.generateBucket(formInfo);
    return rdbUtils.insertData(valueBucket);
  }

  public deleteForm(formId: string): Promise<number> {
    Logger.debug(TAG, `deleteForm formId: ${formId}`);
    let predicates = new relationalStore.RdbPredicates(TABLE_NAME);
    predicates.equalTo('formId', formId);
    return rdbUtils.deleteData(predicates);
  }

  public updateForm(formInfo: FormInfo): Promise<number> {
    Logger.info(TAG, `updateForm formId: ${formInfo.formName}`);
    let valueBucket = this.generateBucket(formInfo);
    let predicates = new relationalStore.RdbPredicates(TABLE_NAME);
    predicates.equalTo('formId', formInfo.formId);
    return rdbUtils.updateData(predicates, valueBucket);
  }

  public queryAllForm(): Promise<FormInfo[]> {
    Logger.info(TAG, 'queryAllForm');
    let predicates = new relationalStore.RdbPredicates(TABLE_NAME);
    return this.queryForm(predicates);
  }

  public queryFormByName(formName: string): Promise<FormInfo[]> {
    Logger.info(TAG, 'queryAllForm');
    let predicates = new relationalStore.RdbPredicates(TABLE_NAME);
    predicates.contains('formName', formName);
    return this.queryForm(predicates);
  }

  public queryFormById(formId: string): Promise<FormInfo> {
    Logger.info(TAG, `queryFormById formId: ${formId}`);
    let predicates = new relationalStore.RdbPredicates(TABLE_NAME);
    predicates.equalTo('formId', formId);
    return new Promise<FormInfo>(async (resolve) => {
      let formInfoList = await this.queryForm(predicates);
      if (formInfoList.length > 0) {
        resolve(formInfoList[0]);
      }
    });
  }

  public queryForm(predicates: relationalStore.RdbPredicates): Promise<FormInfo[]> {
    Logger.info(TAG, 'queryForm');
    return new Promise<FormInfo[]>(async (resolve) => {
      let formInfoList: FormInfo[] = [];
      let resultSet: relationalStore.ResultSet | undefined = undefined;
      try {
        resultSet = await rdbUtils.query(predicates);
        while (resultSet.goToNextRow()) {
          let formInfo: FormInfo = new FormInfo();
          formInfo.formId = resultSet.getString(resultSet.getColumnIndex('formId'));
          formInfo.formName = resultSet.getString(resultSet.getColumnIndex('formName'));
          formInfo.formDimension = resultSet.getString(resultSet.getColumnIndex('formDimension'));
          formInfoList.push(formInfo);
        }
        resolve(formInfoList);
      } catch (error) {
        Logger.error(TAG, `failed to queryForm, code is ${error.code}, message is ${error.message}`);
      } finally {
        try {
          resultSet?.close();
        } catch (error) {
          Logger.error(TAG, `Failed to close resultSet, code is ${error.code}, message is ${error.message}`);
        }
      }
    });
  }

  private generateBucket(formInfo: FormInfo): relationalStore.ValuesBucket {
    let valueBucket: relationalStore.ValuesBucket = {
      formId: formInfo.formId,
      formName: formInfo.formName,
      formDimension: formInfo.formDimension,
    };
    return valueBucket;
  }
}
