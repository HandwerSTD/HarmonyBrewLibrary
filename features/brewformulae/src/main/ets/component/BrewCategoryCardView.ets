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
  BREW_CATEGORY_PREVIEW_COUNT,
  BrewCategoryCardHeader,
  BrewKind,
  BrewPackageRow,
} from '@ohos/brewcommon';
import type { BrewCategoryCard, BrewPackageItem } from '@ohos/brewcommon';

/**
 * Formulae 首页的一个分类大卡。
 *
 * 与组件页 PictureListCard 的视觉语言保持一致（圆角、卡片底色、条目行高、分割线），
 * 但**顶部不是图片**：Homebrew 没有包图标/横幅素材，用「分类 symbol + 中英文分类名 + 包数」
 * 的信息头代替图片头，避免渲染一整块空白。
 *
 * **卡内只给前 `BREW_CATEGORY_PREVIEW_COUNT` 条**（排序口径就是数据层的原顺序：分类内近 30 天安装量降序，
 * 见 `BrewBrowseBuilder.rankWithin`），装不下就在底部给一行「查看全部」。
 *
 * 预览条数与数据层的 `hasMore` 判据共用 `BREW_CATEGORY_PREVIEW_COUNT` 一个常量 ——
 * 分开写就会漂成「预览装得下却给了查看全部」（或反之）。
 *
 * **点击分工**（与 Discover 榜单卡同款，那里已经验证过 ArkUI 的手势不冒泡，父子同类手势只响应最内层）：
 *   - 整张卡根节点 -> `handleViewAll`（进分类二级页）：点卡头、点卡片空白处都算「看这个分类的全部」；
 *   - 卡内每一行 -> `handlePackageClick`（进包详情）；
 *   - 底部「查看全部」行 -> 也是 `handleViewAll`。
 *
 * 同一张卡也用在分类二级页（那里 `previewLimit = 0` + `showViewAllEntry = false`）——
 * 二级页要的正是「Casks 一级页那张卡」的样子，样式只应该有一份。
 */
@Component
export struct BrewCategoryCardView {
  @Prop @Require cardData: BrewCategoryCard;
  /**
   * 卡内最多显示几条。`<= 0` = 不截断（二级页要显示该分类的全部成员）。
   * 默认值就是卡内预览条数，与数据层的 `hasMore` 判据同源。
   */
  @Prop previewLimit: number = BREW_CATEGORY_PREVIEW_COUNT;
  /** 是否给「查看全部」入口（含整卡点击与点击态）。二级页自己就是「全部」，传 false。 */
  @Prop showViewAllEntry: boolean = true;
  handlePackageClick?: (item: BrewPackageItem) => void;
  handleViewAll?: (card: BrewCategoryCard) => void;

  /** 卡片预览的这几条：数据层已经按「分类内近 30 天安装量降序」排好并编好名次，这里只截前 N 条 */
  private previewItems(): BrewPackageItem[] {
    const all: BrewPackageItem[] = this.cardData.formulaContents ?? [];
    return this.previewLimit > 0 ? all.slice(0, this.previewLimit) : all;
  }

  /**
   * 卡片的点击态。
   *
   * 二级页没有「整卡点击」这回事，所以必须把点击态也一起关掉 ——
   * `clickEffect` 是独立于 `onClick` 的，不关的话点卡片会缩放一下却什么都不发生。
   * ArkUI 的 `ClickEffectLevel` 没有 NONE，所以只能用属性修饰符按需设置（传 null = 默认）。
   */
  private cardModifier(): CommonModifier {
    const modifier: CommonModifier = new CommonModifier();
    modifier.clickEffect(this.showViewAllEntry ? { level: ClickEffectLevel.MIDDLE } : null);
    return modifier;
  }

  /**
   * 卡头改用 `brewcommon` 的共享组件（见 `BrewCategoryCardHeader`）：
   * 这段排版还在两张分类二级页上各有一份，四份手抄必然漂移，所以只留一处。
   */
  @Builder
  HeaderBuilder() {
    BrewCategoryCardHeader({
      kind: BrewKind.FORMULA,
      categoryKey: this.cardData.categoryKey,
      title: this.cardData.title,
      itemCount: this.cardData.itemCount,
    })
  }

  @Builder
  ViewAllBuilder() {
    Row() {
      Text($r('app.string.brew_action_view_all'))
        .fontSize($r('sys.float.Body_M'))
        .fontColor($r('sys.color.font_secondary'))
      Blank()
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize($r('sys.float.Title_M'))
        .fontColor([$r('sys.color.icon_secondary')])
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({
      left: $r('sys.float.padding_level8'),
      right: $r('sys.float.padding_level8'),
      top: $r('sys.float.padding_level4'),
      bottom: $r('sys.float.padding_level4'),
    })
    .onClick(() => {
      this.handleViewAll?.(this.cardData);
    })
  }

  build() {
    Column() {
      this.HeaderBuilder()

      Divider()
        .strokeWidth('1px')
        .color($r('sys.color.comp_background_tertiary'))
        .margin({ bottom: $r('sys.float.padding_level2') })

      ForEach(this.previewItems(), (item: BrewPackageItem) => {
        BrewPackageRow({ packageItem: item, kind: BrewKind.FORMULA })
          .onClick(() => {
            this.handlePackageClick?.(item);
          })
      }, (item: BrewPackageItem) => item.id.toString())

      // 预览装不下才给入口（与 Discover 榜单卡同一判据）。`hasMore` 由数据层用
      // `BREW_CATEGORY_PREVIEW_COUNT` 算，与上面的截断同源；二级页传 false 直接不给。
      if (this.showViewAllEntry && this.cardData.hasMore) {
        this.ViewAllBuilder()
      }
    }
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .borderRadius($r('sys.float.corner_radius_level8'))
    .clip(true)
    .width('100%')
    .padding({ bottom: $r('sys.float.padding_level2') })
    .attributeModifier(this.cardModifier())
    .onClick(() => {
      this.handleViewAll?.(this.cardData);
    })
  }
}
