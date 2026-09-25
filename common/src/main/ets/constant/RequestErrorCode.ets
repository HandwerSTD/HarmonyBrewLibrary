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

export class RequestErrorCode {
  /**
   * The network connection could not be established.
   */
  public static readonly NETWORK_CONNECT_FAILED: number = 2100002;
  /**
   * Request rate limit code.
   */
  public static readonly REQUEST_RATE_LIMIT: number = 429;
  /**
   * Sign data invalid.
   */
  public static readonly SIGN_INVALID: number = 10010;
  /**
   * AccessKey invalid.
   */
  public static readonly ACCESS_KEY_INVALID: number = 10011;
  /**
   * AccessKey expired.
   */
  public static readonly ACCESS_KEY_EXPIRE: number = 10012;
  /**
   * Param invalid.
   */
  public static readonly PARAM_INVALID: number = 10002;
}