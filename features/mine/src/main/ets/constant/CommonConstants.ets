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

export class MineConstant {
  public static readonly BUTTON_CLICK_THROTTLE: number = 1000;
  /** 开源仓库地址。本机包提示卡点击后打开这个地址 */
  public static readonly REPO_URL: string = 'https://gitcode.com/handwer/HarmonyBrewLibrary';
  /**
   * 备案号（`app.string.copyright1`）是否在「关于」页展示。
   * 上架审核前先隐藏：点击跳转 beian.miit.gov.cn 的入口随之一起关掉。
   * 恢复时改回 true 即可，资源 / 事件 / `miitUrl` 配置都还留着。
   */
  public static readonly SHOW_REGISTRATION_NO: boolean = false;
}