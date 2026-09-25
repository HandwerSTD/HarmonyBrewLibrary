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
  SuffixButton,
} from '@kit.UIDesignKit';
import { BrewIconSize, BrewPackageIcon } from '@ohos/brewcommon';
import type { BrewDiscoverEntry, BrewKind } from '@ohos/brewcommon';

/**
 * 榜单卡片里的一行。
 *
 * **格式与组件页 ListCard 的行列表（`ComponentItemList`）一致**：
 * 左 icon、右按钮。规格逐项照搬：
 *
 * | 部位 | 组件页 | 这里 |
 * |---|---|---|
 * | 左 icon | `Image` 48vp（`tip_image_height`）+ `corner_radius_level5` + `backgroundColor(themeColor)`，margin `left level6 / right level8` | 同样 48vp / `level5` / 同样 margin；底色改**中性**、内容改**类型色 symbol**（`BrewPackageIcon`），见下方说明 |
 * | 左 icon 角标 | 左上角挂 `TagTipLabel`（NEW 之类） | **不挂**：名次角标（1/2/3…）按要求移除，名次由行的**顺序**表达 |
 * | primary | 该行的主字段 | **包名**（`token`，即 `brew install` 用的标识） |
 * | secondary | 该行的次字段 | **应用的 `desc`**（英文原文）。原来放度量数字，按要求改成描述 |
 * | 右按钮 | `SuffixButton({ text: '打开', textColor: themeColor })` | `SuffixButton({ text: '查看', textColor: font_emphasize })` |
 * | 行高 | `component_item_height` 64vp | `brew_package_row_height` 64vp（同值） |
 *
 * **方块的底色不再用榜色**（原先是 `BrewBoardStyle.colorEndOf`）：榜是**页面级**的 ——
 * `BrewDiscoverBoardView` 一页一个榜，同一页所有行同色，行内并不区分任何东西；
 * 而行级的 formula/cask 才是这里真正需要行内区分的信息。两个维度挤在同一个方块上会互相污染
 * （看到红无法判断这是"Trending 榜"还是"这是个 cask"），且类型色图标压在饱和榜色底上
 * 对比度很差。榜色仍由卡片头部/Hero 承载，页面身份不丢。
 *
 * **行尾按钮的颜色也不再跟随榜色**，固定用系统强调色 `sys.color.font_emphasize`：
 * 按钮颜色应当只表达"可点"，跟随榜色会让同一页的按钮颜色随页面变。
 * 这也是一个**必要前提**：榜色末端原本还兼任按钮文字色（压在浅色行底上，必须对白 ≥4.5:1），
 * 按钮改成固定色后，末端色从此只服务于卡片渐变、约束变松（详见 `BrewBoardStyle.colorEndOf`）。
 *
 * 至此**行里已完全不使用榜色**：方块走类型色、按钮走系统强调色，榜色只留在卡片渐变里。
 *
 * **点击**：整行 `.onClick` 交给 `handleItemClick`（跳包详情）。写法与 Formulae 的
 * `BrewPackageRow({...}).onClick(...)` 同款 —— 挂在自定义组件调用上，命中区域就是该行的根节点。
 * 注意 ArkUI 的手势**不冒泡**（docs：父子组件绑定同类手势时最多只有一个响应，默认子组件优先），
 * 所以这一行的点击不会同时触发榜单大卡根节点的「查看全部」。
 *
 * 之前左侧是名次数字块、右侧是箭头的做法虽然也能用，但与组件页"左图标右按钮"的格式不同；
 * 需求方要求格式统一，所以改成这套。
 *
 * **度量数字目前不在行里**（随 secondary 改成 `desc` 而退出界面）。
 * 四个度量文案模板（`brew_discover_metric_*`）保留在资源里未删，要挪回界面可直接复用；
 * 但恢复时**必须一并恢复 `velocity <= 0` 的判断** —— 那表示该包在 365 天窗口里没有历史（新包），
 * 显示成「0 倍」会被读成"没涨"，而事实是"没有可比的历史"。
 *
 * **`@Builder` 方法必须经方法调用**：`@Builder` 方法体内的组件调用会被编译成视图创建代码，
 * 直接写进 `CustomBuilder` 的箭头函数里运行期会抛 `class constructor cannot called without 'new'`（docs §9.8）。
 */
@Component
export struct BrewDiscoverRow {
  @Prop @Require entry: BrewDiscoverEntry;
  /** 包类型（来自所属榜的 `board.kind`），透传给 `BrewPackageIcon` 决定符号颜色 */
  @Prop @Require kind: BrewKind;
  @Prop itemHeight: Dimension = $r('app.float.brew_package_row_height');
  handleItemClick?: (entry: BrewDiscoverEntry) => void;

  @Builder
  PackageIconBuilder() {
    BrewPackageIcon({ kind: this.kind, boxSize: BrewIconSize.DISCOVER })
  }

  build() {
    HdsListItemCard({
      prefixItem: new PrefixCustomBuilder(() => {
        this.PackageIconBuilder();
      }),
      textItem: {
        primaryText: {
          text: this.entry.token,
          modifier: new TextModifier()
            .maxLines(1)
            .ellipsisMode(EllipsisMode.END)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontColor($r('sys.color.font_primary')),
        },
        // secondary = 应用的 description（英文原文）。原来放的是度量数字
        // （「1.3k 次安装（30天）· 增速 22.0×」），按要求改成描述。
        //
        // `WordBreak.BREAK_ALL`：描述是英文，默认的按词换行遇到长 token
        // （`libreoffice-language-pack` 之类）会把整词挪走、提前省略；
        // BREAK_ALL 允许在词内断开，先把整行填满再省略（与 `maxLines + TextOverflow.Ellipsis` 同用）。
        secondaryText: {
          text: this.entry.desc,
          modifier: new TextModifier()
            .maxLines(1)
            .ellipsisMode(EllipsisMode.END)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .wordBreak(WordBreak.BREAK_ALL)
            .fontColor($r('sys.color.font_secondary')),
        },
      },
      // 右侧按钮：文案"查看"。颜色固定用系统强调色，不跟榜色走
      // （否则同一页按钮颜色随页面变；且榜色末端调浅会直接让按钮文字读不出来）
      suffixItem: new SuffixButton({
        text: $r('app.string.brew_action_view'),
        textColor: $r('sys.color.font_emphasize'),
      }),
      cardHeight: this.itemHeight,
      cardPrefixMargin: $r('sys.float.padding_level0'),
      cardSuffixMargin: $r('sys.float.padding_level2'),
      cardBorderRadius: 0,
      cardBackgroundColor: $r('sys.color.ohos_id_color_background_transparent'),
    })
      .onClick(() => {
        this.handleItemClick?.(this.entry);
      })
  }
}

/** 行分隔线。参数与组件页 `ComponentItemList` 的 `divider` 一致 */
@Component
export struct BrewDiscoverRowDivider {
  build() {
    Divider()
      .strokeWidth('1px')
      .color($r('sys.color.comp_background_tertiary'))
      .margin({
        left: $r('sys.float.padding_level36'),
        right: $r('sys.float.padding_level6'),
      })
  }
}
