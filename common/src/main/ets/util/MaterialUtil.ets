/*
 * Copyright (c) 2024 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the 'License');
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

import { SegmentButtonOptions, SelectModifier } from '@kit.ArkUI';

export class MaterialUtil {
  public static getMaterialModifier(options: ModifierOptions): CommonModifier {
    if (options.backgroundColor) {
      options.modifier.backgroundColor(options.backgroundColor);
    }
    if (options.backgroundBlurStyle) {
      options.modifier.backgroundBlurStyle(options.backgroundBlurStyle);
    }
    return options.modifier;
  }

  public static getMaterialOptions<T>(params: MaterialOptionParam<T>): MaterialOptions<T> | T {
    return params.originOption;
  }

  public static getSelectMaterialModifier(options: SelectModifierOptions): SelectModifier {
    if (options.backgroundColor) {
      options.modifier.backgroundColor(options.backgroundColor);
    }
    return options.modifier;
  }

  public static getSegmentMaterialOptions(options: SegmentButtonOptions,
    backgroundColor?: ResourceColor): SegmentButtonOptions {
    if (backgroundColor) {
      options.backgroundColor = backgroundColor;
    }
    return options;
  }
}

interface MaterialOptionParam<T> {
  originOption: T;
  param: OptionsParam;
}

interface MaterialOptions<T> extends ThisType<T> {}

interface OptionsParam {
  style: CustomImmersiveStyle;
  backgroundColor?: ResourceColor;
}

interface ModifierOptions {
  modifier: CommonModifier;
  style: CustomImmersiveStyle;
  backgroundColor?: ResourceColor;
  materialColor?: ResourceColor;
  backgroundBlurStyle?: BlurStyle;
}

interface SelectModifierOptions {
  modifier: SelectModifier;
  style: CustomImmersiveStyle;
  backgroundColor?: ResourceColor;
  materialColor?: ResourceColor;
  backgroundBlurStyle?: BlurStyle;
}

export enum CustomImmersiveStyle {
  ULTRA_THIN = 0,
  THIN = 1,
  REGULAR = 2,
  THICK = 3,
  ULTRA_THICK = 4,
}