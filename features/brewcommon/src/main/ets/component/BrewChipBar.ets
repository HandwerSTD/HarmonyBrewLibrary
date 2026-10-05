/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import {
  BreakpointType,
  CommonConstants,
  GlobalInfoModel,
  StorageKey,
} from '@ohos/common';
import { brewChipBarHorizontalInset } from '../constant/BrewConstants';
import { BrewChip } from './BrewChip';

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
 *   栏内边距   left·right level6/level12/level16，top level8，bottom level5
 *   chip 自身  字号、内边距、圆角、选中配色在 `BrewChip` 里（见该文件头部注释）
 *
 * 与样例页的唯一差异：**样例页 chip 有图标，这里没有。**
 * 样例页图标走 `Image($rawfile(item.defaultIcon))`，而 Homebrew 没有分类图标素材
 * （mock 的 defaultIcon / selectedIcon 实测为空字符串，样例页代码本身也是
 * `if (item.defaultIcon)` guarded —— 数据为空时它同样只渲染文字）。
 * 这里不再用 sys.symbol.* 自己补图标，保持与样例页一致的纯文字 chip。
 *
 * 与 `BrewChip` 的分工：本组件管 chip 之间的间距与整栏内边距，chip 自身的外观在
 * `BrewChip` 里 —— 「我的 - 本机包」列表页标题栏右侧的隐藏 chip 也用它，两处共一份取值。
 */
@Component
export struct BrewChipBar {
  @Prop @Require chips: BrewChipItem[];
  @Prop @Require currentIndex: number;
  handleChipClick?: (index: number) => void;
  @StorageProp(StorageKey.GLOBAL_INFO) globalInfoModel: GlobalInfoModel =
    AppStorage.get(StorageKey.GLOBAL_INFO) ?? new GlobalInfoModel();

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
    const horizontal: Length = brewChipBarHorizontalInset(this.globalInfoModel);
    return {
      left: horizontal,
      right: horizontal,
      top: $r('sys.float.padding_level8'),
      bottom: $r('sys.float.padding_level5'),
    };
  }

  @Builder
  ChipBuilder(item: BrewChipItem, index: number) {
    BrewChip({
      label: item.label,
      selected: this.isSelected(index),
      handleClick: () => {
        this.handleChipClick?.(index);
      },
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
