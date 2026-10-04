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

import { CommonConstants, HmosListItem } from '@ohos/common';
import { BrewLocalPackageRow } from '@ohos/brewcommon';
import type { BrewInstalledPackage } from '@ohos/brewcommon';

/** 卡片里最多预览几条包 */
const PREVIEW_COUNT: number = 3;

/**
 * 读取中占位区的高度。
 *
 * 与加载完成后的预览区等高，数据到位时卡片不会跳一下。
 * 这个值是实测出来的：「我的」页加载态与加载完成态两次 dump 里，
 * 第二张卡的 y 相差 74px（3 倍屏 ≈ 24.7vp），从三行预览的 168vp 里减掉它。
 */
const PREVIEW_LOADING_HEIGHT: number = 143;

/**
 * 「我的」页的包预览大卡片（待更新 / 已更新）。
 *
 * 卡片外观由 MineView 的分组容器提供（primary 底 + level8 圆角），
 * 这里只负责卡内内容：头部（图标 + 标题 + 数量）、预览行、「查看全部」。
 *
 * 预览只取前几条、整卡可点进子页面看完整列表 —— 直接把全部条目铺开会把「我的」页拉得很长
 * （已更新有 52 个），而这是「大卡片」而不是列表。
 *
 * **头部用 `HmosListItem`，与页面上「已安装」「设置」等 item 是同一个组件。**
 * 一开始是自己拼 `SymbolGlyph` + `Text`，结果标题用的 `Title_S` 比列表项标题（`Body_L`）
 * 大 25%、左边缘还多缩进一截，视觉上明显是"外来户"。改用同一个组件后，图标尺寸、标题字号、
 * 左侧缩进、右侧数字槽位全部天然一致，不需要我去猜任何一个数值。
 * 这些都是真机 `devecocli ui layout` 量出来的（标题 45 vs 36、左边缘 1106 vs 1099），
 * 靠读代码是看不出来的。
 */
@Component
export struct MinePackageCard {
  @Prop @Require title: ResourceStr;
  @Prop @Require symbolSrc: Resource;
  @Prop @Require packages: BrewInstalledPackage[];
  /**
   * 包集合是否还在读取。
   *
   * 为真时预览区显示转圈而不走空态：读取要拉起 brew（首次约 2–3 秒），
   * 而空态文案是「本机暂无可显示的包」—— 还没读到就写这句是在误导用户。
   */
  @Prop loading: boolean = false;
  handleViewAll?: () => void;
  /**
   * 点击某一行本机包。导航由「我的」页决定（本组件不持有路由逻辑，与 `BrewLocalPackageRow`
   * 同一口径：点击用 `.onClick()` 挂在行组件调用上）。
   */
  handlePackageClick?: (pkg: BrewInstalledPackage) => void;

  @Builder
  HeaderBuilder() {
    // 不给 handleClickAction：本卡的点击入口是下面的「查看全部」，头部只做展示
    // 读取中不显示数量：还没有数据，写 0 会被读成「一个包都没装」
    HmosListItem({
      title: this.title,
      prefixResource: this.symbolSrc,
      desc: this.loading ? '' : $r('app.string.brew_label_packages_count', this.packages.length),
    })
  }

  /** 预览行放在一层 tertiary 底的容器里，与卡片底部形成层次 */
  @Builder
  PreviewBuilder() {
    Column() {
      ForEach(this.packages.slice(0, PREVIEW_COUNT), (pkg: BrewInstalledPackage) => {
        BrewLocalPackageRow({
          installedPackage: pkg,
          itemHeight: $r('app.float.mine_preview_row_height'),
        })
          .onClick(() => {
            this.handlePackageClick?.(pkg);
          })
      }, (pkg: BrewInstalledPackage) => pkg.fullName)
    }
    .width(CommonConstants.FULL_PERCENT)
    .backgroundColor($r('sys.color.comp_background_tertiary'))
    .borderRadius($r('sys.float.corner_radius_level8'))
    .clip(true)
  }

  @Builder
  ViewAllBuilder() {
    Row() {
      Text($r('app.string.mine_view_all'))
        .fontSize($r('sys.float.Body_M'))
        .fontColor($r('sys.color.font_secondary'))
      Blank()
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize($r('sys.float.Title_M'))
        .fontColor([$r('sys.color.icon_secondary')])
    }
    .width(CommonConstants.FULL_PERCENT)
    .alignItems(VerticalAlign.Center)
    .padding({
      top: $r('sys.float.padding_level2'),
      bottom: $r('sys.float.padding_level2'),
    })
    .onClick(() => {
      this.handleViewAll?.();
    })
  }

  /** 读取中的占位：与预览区同底同高，数据到位后卡片不跳高度 */
  @Builder
  LoadingBuilder() {
    Column() {
      LoadingProgress()
        .width($r('app.float.loading_size_sm'))
        .height($r('app.float.loading_size_sm'))
    }
    .width(CommonConstants.FULL_PERCENT)
    .height(PREVIEW_LOADING_HEIGHT)
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('sys.color.comp_background_tertiary'))
    .borderRadius($r('sys.float.corner_radius_level8'))
    .clip(true)
  }

  build() {
    // 纵向内边距加在最外层；**左右内边距只加在预览区这一层**，头部保持全宽。
    // 这样头部的图标与标题才能和页面上其它 item 对齐（它们都是全宽行 + 分组容器的 level2 内边距）——
    // 如果整张卡都缩进，头部就会比其他 item 多缩一截，实测差 7px 肉眼可见。
    Column({ space: $r('sys.float.padding_level4') }) {
      this.HeaderBuilder()
      if (this.loading) {
        this.LoadingBuilder()
      } else if (this.packages.length > 0) {
        Column({ space: $r('sys.float.padding_level4') }) {
          this.PreviewBuilder()
          this.ViewAllBuilder()
        }
        .width(CommonConstants.FULL_PERCENT)
        // 用 level4 而不是 level8：这是上一轮已经确认过的预览框内缩量（约 7px），
        // 头部改成全宽是为了对齐，不该顺手把这一层也改掉。
        .padding({
          left: $r('sys.float.padding_level4'),
          right: $r('sys.float.padding_level4'),
        })
      } else {
        Text($r('app.string.mine_packages_empty'))
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('sys.color.font_tertiary'))
          .width(CommonConstants.FULL_PERCENT)
          .padding({
            left: $r('sys.float.padding_level4'),
            right: $r('sys.float.padding_level4'),
          })
      }
    }
    .width(CommonConstants.FULL_PERCENT)
    .alignItems(HorizontalAlign.Start)
    .padding({
      top: $r('sys.float.padding_level4'),
      bottom: $r('sys.float.padding_level4'),
    })
  }
}
