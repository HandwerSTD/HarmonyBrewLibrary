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
import type { BrewInstalledPackage } from '../model/BrewModels';
import { BrewFormat } from '../util/BrewFormat';
import { BrewIconSize } from '../constant/BrewIconStyle';
import { BrewPackageIcon } from './BrewPackageIcon';

/**
 * 本机已安装包的一行（「我的」页与它的子页面用）。
 *
 * 与 `BrewPackageRow` 分开而不合并，是因为右侧信息完全不同：
 * `BrewPackageRow` 面向「浏览商店里的包」，右侧是分类内排名 + 近 30 天安装量；
 * 本组件面向「我自己机器上的包」，右侧是版本 —— 本机数据里根本没有
 * categoryRank / installs30d 这两个字段，硬塞进同一个组件只能靠开关参数，
 * 反而更难读。
 *
 * 两块辅助信息的摆位是**按长度定的**：
 *   副标题行（宽度充裕）  版本：有新版本 -> "5.9.1 → 5.9.2"，已是最新 -> "5.9.2"
 *   尾部槽位（宽度最短）  来源：主动安装 / 作为依赖安装
 * 反过来的话 cask 的长版本号会被尾部槽位截掉，等于没显示。
 *
 * 没有箭头、不可点击：本机包数据里只有 token，没有商店目录里的包 id，
 * 无法据此打开详情页（见 docs §11 的遗留项）。
 */
@Component
export struct BrewLocalPackageRow {
  @Prop @Require installedPackage: BrewInstalledPackage;
  @Prop itemHeight: Dimension = $r('app.float.brew_package_row_height');

  /** 有新版本时显示版本变化，否则只显示当前版本 */
  private versionText(): ResourceStr {
    const pkg: BrewInstalledPackage = this.installedPackage;
    if (pkg.outdated && pkg.latestVersion && pkg.latestVersion !== pkg.version) {
      return $r('app.string.brew_version_delta', pkg.version, pkg.latestVersion);
    }
    return pkg.version;
  }

  /**
   * 副标题用「主动安装 / 作为依赖安装」而不是原始 kind 字符串。
   * brew 用户真正关心的是「这个包是我主动装的还是被带进来的」——
   * 42 个 formula 里往往只有十几个是主动装的。kind 的区分交给筛选 chips。
   */
  private sourceText(): ResourceStr {
    return this.installedPackage.installedAsDependency ?
      $r('app.string.brew_mine_as_dependency') : $r('app.string.brew_mine_on_request');
  }

  @Builder
  SourceBuilder() {
    Row() {
      Text(this.sourceText())
        .fontSize($r('sys.float.Body_S'))
        .fontColor($r('sys.color.font_tertiary'))
        .maxLines(1)
        .ellipsisMode(EllipsisMode.END)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .alignItems(VerticalAlign.Center)
    .padding({ right: $r('sys.float.padding_level4') })
  }

  /**
   * 必须包一层 @Builder，不能在 PrefixCustomBuilder 的箭头里直接写 `BrewPackageIcon({...})`。
   *
   * 原因：@Builder 方法体内的组件调用会被 ArkTS 编译器改写成视图创建代码，而普通箭头函数
   * 内的不会 —— 直接内联会编译成裸的类调用，运行期抛
   * `class constructor cannot called without 'new'`（真机实测在这个位置闪退）。
   * BrewPackageRow 里也是同样的写法，保持一致。
   */
  @Builder
  PackageIconBuilder() {
    // 本机数据自带 kind（`BrewInstalledPackage.kind`），不必像 `BrewPackageRow` 那样外传
    BrewPackageIcon({ kind: BrewFormat.brewKindOf(this.installedPackage.kind), boxSize: BrewIconSize.ROW })
  }

  build() {
    HdsListItemCard({
      prefixItem: new PrefixCustomBuilder(() => {
        this.PackageIconBuilder();
      }),
      textItem: {
        primaryText: {
          text: this.installedPackage.name,
          modifier: new TextModifier()
            .maxLines(1)
            .ellipsisMode(EllipsisMode.END)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontColor($r('sys.color.font_primary')),
        },
        // 版本放在副标题行而不是尾部槽位：cask 的版本号很长
        // （如 `2026.2.5,262.10315.131 → 2026.2.5,262.10315.132`，45 字符），
        // 尾部槽位宽度最短，放那里必然被截成没有信息量的前缀。
        secondaryText: {
          text: this.versionText(),
          modifier: new TextModifier()
            .maxLines(1)
            .ellipsisMode(EllipsisMode.END)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontColor($r('sys.color.font_secondary')),
        },
      },
      suffixItem: new SuffixCustomBuilder(() => {
        this.SourceBuilder();
      }),
      cardHeight: this.itemHeight,
      cardPrefixMargin: $r('sys.float.padding_level0'),
      cardSuffixMargin: $r('sys.float.padding_level2'),
      cardBorderRadius: 0,
      cardBackgroundColor: $r('sys.color.ohos_id_color_background_transparent'),
    })
  }
}
