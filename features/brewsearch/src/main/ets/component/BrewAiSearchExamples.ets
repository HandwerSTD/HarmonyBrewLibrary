/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { CommonConstants } from '@ohos/common';

/**
 * AI 模式建议态的「试试这样问」示例区（2026-11-26-ai-search-ask-spec §4.2）。
 *
 * 贴片退役后，AI 模式未提交时的引导由这里承担：三条示例提问 chips，
 * 点击 = 填入输入框 + 立即以 AI 模式提交（与建议词 pickWord 同语义）。
 *
 * - 只在 aiEnabled 时渲染（AI off 时本组件不出现，搜索建议页与改前逐字节一致，G8）；
 * - 示例文案三语各自资源（ai_search_example_1/2/3）；
 * - chips 形态与搜索历史的词 chip 同构（tertiary 底 + 圆角 + wrap）。
 */
@Component
export struct BrewAiSearchExamples {
  /** 点示例：页面填入输入框并立即以 AI 模式提交 */
  onPickExample: (query: string) => void = (_query: string) => {
  };

  @Builder
  ExampleChipBuilder(label: ResourceStr, query: ResourceStr) {
    Text(label)
      .fontSize($r('sys.float.Body_M'))
      .fontColor($r('sys.color.font_tertiary'))
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .backgroundColor($r('sys.color.comp_background_tertiary'))
      .borderRadius($r('sys.float.corner_radius_level4'))
      .padding({
        left: $r('sys.float.padding_level8'),
        right: $r('sys.float.padding_level8'),
        top: $r('sys.float.padding_level4'),
        bottom: $r('sys.float.padding_level4'),
      })
      .margin({ right: 8, bottom: 8 })
      .onClick(() => {
        this.onPickExample(query as string);
      })
  }

  build() {
    Column() {
      Text($r('app.string.ai_search_examples_header'))
        .fontSize($r('sys.float.Body_S'))
        .fontColor($r('sys.color.font_tertiary'))
        .width(CommonConstants.FULL_PERCENT)
        .padding({ bottom: $r('sys.float.padding_level4') })
      Flex({ wrap: FlexWrap.Wrap }) {
        this.ExampleChipBuilder($r('app.string.ai_search_example_1'), $r('app.string.ai_search_example_1'))
        this.ExampleChipBuilder($r('app.string.ai_search_example_2'), $r('app.string.ai_search_example_2'))
        this.ExampleChipBuilder($r('app.string.ai_search_example_3'), $r('app.string.ai_search_example_3'))
      }
      .width(CommonConstants.FULL_PERCENT)
    }
    .width(CommonConstants.FULL_PERCENT)
    .alignItems(HorizontalAlign.Start)
    .margin({ bottom: $r('sys.float.padding_level8') })
  }
}
