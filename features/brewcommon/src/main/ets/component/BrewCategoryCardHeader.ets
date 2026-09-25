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

import { BrewKind } from '../model/BrewModels';
import { getCategoryNameMap, getCategorySymbolMap } from '../constant/BrewConstants';

/**
 * 分类卡的**卡头**：分类图标 + 中英文分类名 + 包数。
 *
 * 为什么要抽出来：这段在 Formulae 首页卡、Casks 首页卡、以及两张分类二级页上出现过四份
 * （二级页原先靠「复用首页那张卡 + previewLimit = 0」拿到它）。四份手抄的排版必然漂移，
 * 而分类二级页改成 `List` + `LazyForEach` 之后**不能再套整张卡**（卡会把上千行一次性构建，
 * 虚拟化就白做了），所以卡头必须能独立使用 —— 这个组件的存在就是那次改动的直接结果。
 *
 * Homebrew 没有包图标/横幅素材，所以卡头不是图片头，而是「分类 symbol + 中英文分类名 + 包数」，
 * 与组件页 PictureListCard 的视觉语言保持一致（圆角、卡片底色、行高由调用方给）。
 */
@Component
export struct BrewCategoryCardHeader {
  /** 包类型：决定分类名与图标的映射表（`BrewKind.FORMULA` / `BrewKind.CASK`） */
  @Prop @Require kind: BrewKind;
  @Prop @Require categoryKey: string;
  /** 英文分类名（卡头第二行） */
  @Prop @Require title: string;
  /** 该分类的**总**条数（不是当前渲染了多少条） */
  @Prop @Require itemCount: number;

  private categoryName(): Resource {
    return getCategoryNameMap(this.kind)[this.categoryKey] ?? $r('app.string.brew_cat_unknown');
  }

  private categorySymbol(): Resource {
    return getCategorySymbolMap(this.kind)[this.categoryKey] ?? $r('sys.symbol.square_grid_2x2');
  }

  build() {
    Row() {
      Column() {
        SymbolGlyph(this.categorySymbol())
          .fontColor([$r('sys.color.icon_emphasize')])
          .fontSize($r('app.float.brew_card_header_icon_size'))
      }
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .width($r('app.float.brew_monogram_size'))
      .height($r('app.float.brew_monogram_size'))
      .borderRadius($r('sys.float.corner_radius_level5'))
      .backgroundColor($r('sys.color.comp_background_tertiary'))
      .margin({ right: $r('sys.float.padding_level8') })

      Column() {
        Text(this.categoryName())
          .fontSize($r('sys.float.Title_S'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .ellipsisMode(EllipsisMode.END)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.title)
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(1)
          .ellipsisMode(EllipsisMode.END)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: $r('sys.float.padding_level2') })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text($r('app.string.brew_label_packages_count', this.itemCount))
        .fontSize($r('sys.float.Body_S'))
        .fontColor($r('sys.color.font_tertiary'))
        .margin({ left: $r('sys.float.padding_level6') })
    }
    .alignItems(VerticalAlign.Center)
    .width('100%')
    .height($r('app.float.brew_card_header_height'))
    .padding({
      left: $r('sys.float.padding_level6'),
      right: $r('sys.float.padding_level8'),
    })
  }
}
