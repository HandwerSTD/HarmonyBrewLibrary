/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { CommonModifier } from '@kit.ArkUI';
import { CustomImmersiveStyle, MaterialUtil, StorageKey } from '@ohos/common';

/**
 * 单个胶囊 chip。
 *
 * 两个调用点：筛选 chip 栏（`BrewChipBar`）里的每一项，以及「我的 - 本机包」列表页标题栏右侧的
 * 隐藏依赖 chip。样式与 `BrewChipBar` 原来的 `ChipBuilder` 逐项相同，抽出来的理由只有一个 ——
 * 同一个外观有第二个调用点时，外观取值只定义一处，改一边不会让另一边悄悄变旧。
 *
 * 全部样式对齐「样例」页 PracticesView 的 CategoryHeaderBuilder：
 *   chip 内边距 left·right padding_level8，top·bottom padding_level4
 *   chip 圆角   侧边栏布局 corner_radius_level4，否则 '50%'（胶囊）
 *   选中态      emphasize 底色 + font_on_primary 文字
 *   未选中态    button_normal 底色 + font_tertiary 文字
 *
 * 底色挂在 `attributeModifier` 上，所以**调用方加外边距时要包一层容器**：
 * 直接给本组件加 `padding` 会作用在 Text 自己的框上，把胶囊底色一起撑大。
 */
@Component
export struct BrewChip {
  @Prop @Require label: ResourceStr;
  @Prop selected: boolean = false;
  handleClick?: () => void;
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

  build() {
    Text(this.label)
      .fontSize($r('sys.float.Body_M'))
      .fontWeight(FontWeight.Medium)
      .fontColor(this.selected ? $r('sys.color.font_on_primary') : $r('sys.color.font_tertiary'))
      .maxLines(1)
      .ellipsisMode(EllipsisMode.END)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .attributeModifier(this.selected ? this.selectedModifier : this.normalModifier)
      .padding({
        left: $r('sys.float.padding_level8'),
        right: $r('sys.float.padding_level8'),
        top: $r('sys.float.padding_level4'),
        bottom: $r('sys.float.padding_level4'),
      })
      .borderRadius(AppStorage.get<boolean>(StorageKey.IS_SIDEBAR_LAYOUT) ?
        $r('sys.float.corner_radius_level4') : '50%')
      .onClick(() => {
        this.handleClick?.();
      })
  }
}
