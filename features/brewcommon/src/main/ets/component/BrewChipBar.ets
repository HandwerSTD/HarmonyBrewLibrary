/*
 * Copyright (c) 2025 Huawei Device Co., Ltd.
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

import { CommonModifier } from '@kit.ArkUI';
import {
  BreakpointType,
  CommonConstants,
  CustomImmersiveStyle,
  GlobalInfoModel,
  MaterialUtil,
  StorageKey,
} from '@ohos/common';

/**
 * chip 栏的一项。`label` 交给调用方给 —— 文案可能来自 string.json（如「全部 / Formulae」），
 * 也可能来自数据里的分类名（如 Casks 的分类），所以这里不预设任何取值来源。
 */
export class BrewChipItem {
  public id: string = '';
  public label: ResourceStr = '';

  constructor(id: string, label: ResourceStr) {
    this.id = id;
    this.label = label;
  }
}

/**
 * 通用的胶囊 chip 栏。Casks 的分类 chips 与「我的-本机包」的筛选 chips 共用。
 *
 * 全部样式逐项对齐「样例」页 PracticesView 的 CategoryHeaderBuilder：
 *   chip 间距  sm SPACE_10 / md·lg SPACE_12
 *   chip 内边距 left·right padding_level8，top·bottom padding_level4
 *   chip 圆角  侧边栏布局 corner_radius_level4，否则 '50%'（胶囊）
 *   选中态     emphasize 底色 + font_on_primary 文字
 *   未选中态   button_normal 底色 + font_tertiary 文字
 *   栏内边距   left·right level6/level12/level16，top level8，bottom level5
 *
 * 与样例页的唯一差异：**样例页 chip 有图标，这里没有。**
 * 样例页图标走 `Image($rawfile(item.defaultIcon))`，而 Homebrew 没有分类图标素材
 * （mock 的 defaultIcon / selectedIcon 实测为空字符串，样例页代码本身也是
 * `if (item.defaultIcon)` guarded —— 数据为空时它同样只渲染文字）。
 * 这里不再用 sys.symbol.* 自己补图标，保持与样例页一致的纯文字 chip。
 */
@Component
export struct BrewChipBar {
  @Prop @Require chips: BrewChipItem[];
  @Prop @Require currentIndex: number;
  handleChipClick?: (index: number) => void;
  @StorageProp(StorageKey.GLOBAL_INFO) globalInfoModel: GlobalInfoModel =
    AppStorage.get(StorageKey.GLOBAL_INFO) ?? new GlobalInfoModel();
  @State normalModifier: CommonModifier = new CommonModifier();
  @State selectedModifier: CommonModifier = new CommonModifier();

  aboutToAppear(): void {
    this.normalModifier = MaterialUtil.getMaterialModifier({
      modifier: new CommonModifier(),
      style: CustomImmersiveStyle.ULTRA_THIN,
      backgroundColor: $r('sys.color.ohos_id_color_button_normal'),
    });
    this.selectedModifier = MaterialUtil.getMaterialModifier({
      modifier: new CommonModifier(),
      style: CustomImmersiveStyle.ULTRA_THIN,
      backgroundColor: $r('sys.color.ohos_id_color_emphasize'),
      materialColor: $r('sys.color.ohos_id_color_emphasize'),
    });
  }

  private isSelected(index: number): boolean {
    return index === this.currentIndex;
  }

  private chipSpace(): Length {
    return new BreakpointType<Length>({
      sm: CommonConstants.SPACE_10,
      md: CommonConstants.SPACE_12,
      lg: CommonConstants.SPACE_12,
    }).getValue(this.globalInfoModel.widthBreakpoint);
  }

  /** chip 栏自己的左右内缩。样例页 chips 与卡片并不对齐（卡片另有 SCROLL_MARGIN / gutter），这里同样各管各的。 */
  private barPadding(): Padding {
    const horizontal: Length = new BreakpointType<Length>({
      sm: $r('sys.float.padding_level6'),
      md: $r('sys.float.padding_level12'),
      lg: $r('sys.float.padding_level16'),
    }).getValue(this.globalInfoModel.widthBreakpoint);
    return {
      left: horizontal,
      right: horizontal,
      top: $r('sys.float.padding_level8'),
      bottom: $r('sys.float.padding_level5'),
    };
  }

  @Builder
  ChipBuilder(item: BrewChipItem, index: number) {
    Text(item.label)
      .fontSize($r('sys.float.Body_M'))
      .fontWeight(FontWeight.Medium)
      .fontColor(this.isSelected(index) ? $r('sys.color.font_on_primary') : $r('sys.color.font_tertiary'))
      .maxLines(1)
      .ellipsisMode(EllipsisMode.END)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .attributeModifier(this.isSelected(index) ? this.selectedModifier : this.normalModifier)
      .padding({
        left: $r('sys.float.padding_level8'),
        right: $r('sys.float.padding_level8'),
        top: $r('sys.float.padding_level4'),
        bottom: $r('sys.float.padding_level4'),
      })
      .borderRadius(AppStorage.get<boolean>(StorageKey.IS_SIDEBAR_LAYOUT) ?
        $r('sys.float.corner_radius_level4') : '50%')
      .onClick(() => {
        this.handleChipClick?.(index);
      })
  }

  build() {
    Scroll() {
      Row({ space: this.chipSpace() }) {
        ForEach(this.chips, (item: BrewChipItem, index: number) => {
          this.ChipBuilder(item, index)
        }, (item: BrewChipItem) => item.id)
      }
      .padding(this.barPadding())
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .align(Alignment.Start)
    .width('100%')
  }
}
