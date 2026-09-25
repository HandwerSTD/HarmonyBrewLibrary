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

import { TextModifier } from '@kit.ArkUI';
import {
  HdsListItemCard,
  PrefixCustomBuilder,
  SuffixCustomBuilder,
} from '@kit.UIDesignKit';
import type { BrewKind, BrewPackageItem } from '../model/BrewModels';
import { BrewFormat } from '../util/BrewFormat';
import { BrewIconSize } from '../constant/BrewIconStyle';
import { BrewPackageIcon } from './BrewPackageIcon';

/**
 * 分类卡里的一行包。
 *
 * 放在 brewcommon 而不是某个页签模块里：Formulae / Casks / Discover / 详情页都要用它，
 * 各页签模块之间不应互相依赖。所有 brew 页签共享的 UI 原子都收在这里。
 *
 * 用官方 HDS 的 HdsListItemCard（与组件页 ComponentItemList 同款），
 * 行高、分割线、点击态与现有页面保持一致。
 *
 * 两个与组件页不同的点，都源于 Homebrew 数据本身的限制：
 *   1. Homebrew 没有包图标 -> prefix 用统一的包图标基底 `BrewPackageIcon`（中性底 +
 *      类型色 symbol），而不是图片。`kind` 必须由调用方传入：`BrewPackageItem`
 *      自己没有 kind 字段（它同时被 formula / cask 两条路复用）
 *   2. 热度只有安装量 -> suffix 用「分类内排名（`hideRank` 为 false 时）+ 近 30 天安装量 +
 *      箭头」的紧凑排布；搜索结果跨分类、没有「分类内名次」这个语境，传 `hideRank: true` 隐藏名次
 */
@Component
export struct BrewPackageRow {
  @Prop @Require packageItem: BrewPackageItem;
  /** 包类型，透传给 `BrewPackageIcon` 决定符号颜色。`BrewPackageItem` 里没有这个字段 */
  @Prop @Require kind: BrewKind;
  @Prop itemHeight: Dimension = $r('app.float.brew_package_row_height');
  /**
   * `true` = 不渲染「分类内名次」。搜索结果用：一次搜索跨 17 个分类，没有「分类内名次」
   * 这个语境，而 `BrewFormat.rankText(0, 0)` 会老老实实渲染出 `0 / 0`（它不判 0）。
   * **默认 false，现有 5 个调用点的行为完全不变**（Formulae 分类页与分类卡、Casks 分类页与分类卡、
   * 包详情页的「同分类其他包」）；目前无一处传它。
   */
  @Prop hideRank: boolean = false;
  // 此处曾声明 `handleItemClick?: (item: BrewPackageItem) => void;`，但本组件的 `HdsListItemCard`
  // 从未把 `onClick` 接上，所以传进来的回调被**静默丢弃**：无编译错误、无运行时报错，
  // 只是行根本点不动。搜索结果页曾因此完全无法点击进入详情。
  // 点击一律用 `.onClick()` 挂在**组件调用**上（本项目 6 处调用点的统一写法）；
  // 参数式入口在这里只会造出第二个机制，已删除。对照 `HmosListItem` 是把
  // `handleClickAction` 真的转发给 `HdsListItemCard.onClick` 的。

  @Builder
  PackageIconBuilder() {
    BrewPackageIcon({ kind: this.kind, boxSize: BrewIconSize.ROW })
  }

  /** 右侧：分类内排名（可隐藏）+ 近 30 天安装量 + 箭头 */
  @Builder
  HeatBuilder() {
    Row() {
      if (!this.hideRank) {
        Text(BrewFormat.rankText(this.packageItem.categoryRank, this.packageItem.categorySize))
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_tertiary'))
      }
      Text(BrewFormat.compactCount(this.packageItem.installs30d))
        .fontSize($r('sys.float.Body_S'))
        .fontColor($r('sys.color.font_secondary'))
        .margin({ left: $r('sys.float.padding_level6') })
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontColor([$r('sys.color.icon_secondary')])
        .fontSize($r('sys.float.Title_M'))
        .margin({ left: $r('sys.float.padding_level4') })
    }
    .alignItems(VerticalAlign.Center)
    .padding({ right: $r('sys.float.padding_level4') })
  }

  build() {
    HdsListItemCard({
      prefixItem: new PrefixCustomBuilder(() => {
        this.PackageIconBuilder();
      }),
      textItem: {
        primaryText: {
          text: this.packageItem.subTitle,
          modifier: new TextModifier()
            .maxLines(1)
            .ellipsisMode(EllipsisMode.END)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontColor($r('sys.color.font_primary')),
        },
        secondaryText: {
          text: this.packageItem.title,
          modifier: new TextModifier()
            .maxLines(1)
            .ellipsisMode(EllipsisMode.END)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontColor($r('sys.color.font_secondary')),
        },
      },
      suffixItem: new SuffixCustomBuilder(() => {
        this.HeatBuilder();
      }),
      cardHeight: this.itemHeight,
      cardPrefixMargin: $r('sys.float.padding_level0'),
      cardSuffixMargin: $r('sys.float.padding_level2'),
      cardBorderRadius: 0,
      cardBackgroundColor: $r('sys.color.ohos_id_color_background_transparent'),
    })
  }
}
