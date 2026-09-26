/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { BrewIconSize, BrewPackageIcon } from '@ohos/brewcommon';
import type { BrewInfoPageData, BrewKind } from '@ohos/brewcommon';

/**
 * 详情页头部（§5.3 分区 1）。
 *
 * 包图标 + 包名 + 英文描述 + tap 来源。
 * 图标用列表页同一个基底 `BrewPackageIcon`，只是放大到 `BrewIconSize.DETAIL`（64vp）——
 * 与列表保持一致，不引入第二套视觉语言。
 *
 * `kind` 必须由页面传入（来自路由参数）：`BrewInfoPageData` 本身不带类型字段。
 */
@Component
export struct BrewDetailHero {
  @Prop @Require data: BrewInfoPageData;
  @Prop @Require kind: BrewKind;

  build() {
    Row() {
      BrewPackageIcon({
        kind: this.kind,
        boxSize: BrewIconSize.DETAIL,
        boxRadius: $r('sys.float.corner_radius_level8'),
        boxMarginStart: $r('sys.float.padding_level0'),
        boxMarginEnd: $r('sys.float.padding_level12'),
      })

      Column() {
        Text(this.data.name)
          .fontSize($r('sys.float.Title_L'))
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(2)
          .ellipsisMode(EllipsisMode.END)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.data.desc)
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('sys.color.font_secondary'))
          .margin({ top: $r('sys.float.padding_level4') })
        Text(this.data.shortName)
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_tertiary'))
          .margin({ top: $r('sys.float.padding_level2') })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .alignItems(VerticalAlign.Top)
    .width('100%')
  }
}
