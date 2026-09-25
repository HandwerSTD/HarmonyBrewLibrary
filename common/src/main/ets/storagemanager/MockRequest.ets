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

import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { StorageKey } from '../constant/CommonEnums';
import { TriggerEnums } from '../constant/TriggerEnums';
import { ResponseData } from '../model/ResponseData';
import Logger from '../util/Logger';

const TAG = '[MockRequest]';

/**
 * Mock data request class.
 *
 * 数据源固定为 `rawfile/mockdata/<trigger>.json`（trigger 由 `TriggerEnums` 声明）。
 * 带 `singleId` 时按 `id` 命中数组里的一条并返回该条，否则返回 `body`。
 */
export class MockRequest {
  private static instance: MockRequest;

  private constructor() {
  }

  public static getInstance() {
    if (!MockRequest.instance) {
      MockRequest.instance = new MockRequest();
    }
    return MockRequest.instance;
  }

  public request<T>(trigger: TriggerEnums, param?: object): Promise<T> {
    return new Promise((resolve: (value: T | PromiseLike<T>) => void,
      reject: ((reason?: BusinessError) => void)) => {
      try {
        const uiContext: UIContext | undefined = AppStorage.get<UIContext>(StorageKey.UI_CONTEXT);
        const context: Context | undefined = uiContext?.getHostContext();
        if (!uiContext || !context) {
          Logger.error(TAG, `GetRawFileContent failed, cause uiContext or context is undefined.`);
          reject({ message: 'uiContext or context is undefined.' } as BusinessError);
          return;
        }

        const requestParam: Record<string, string | number | object> = {};
        if (param) {
          Object.keys(param).forEach((key: string) => {
            requestParam[key] = param[key];
          });
        }

        const filePath: string = `mockdata/${trigger}.json`;
        const result: Uint8Array = context.resourceManager.getRawFileContentSync(filePath);
        const textDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
        const content: string = textDecoder.decodeToString(result, { stream: false });
        Logger.info(TAG, `GetRawFileContent succeed.`);

        if (requestParam['singleId']) {
          // Detail data: pick the entry whose id matches.
          const jsonContent: ResponseData<CommonBaseData<T>[]> =
            JSON.parse(content) as ResponseData<CommonBaseData<T>[]>;
          const item: CommonBaseData<T> | undefined =
            jsonContent.body.find((item: CommonBaseData<T>) => item.id === requestParam['singleId'] as number);
          if (!item) {
            reject({ message: 'Not found details data' } as BusinessError);
            return;
          }
          resolve(item as T);
        } else {
          const jsonContent: ResponseData<T> = JSON.parse(content) as ResponseData<T>;
          resolve(jsonContent.body);
        }
      } catch (error) {
        Logger.error(TAG, `GetRawFileContent failed, error code: ${error.code}, message: ${error.message}.`);
        reject(error as BusinessError);
      }
    });
  }
}

interface CommonBaseData<T> {
  id: number;
}
