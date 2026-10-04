/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
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

import { StorageKey } from '../constant/CommonEnums';
import { GlobalInfoModel } from '../model/GlobalInfoModel';
import { BreakpointType } from '../util/BreakpointSystem';

/**
 * 占位视图的形态。决定用转圈还是失败图标，以及要不要给操作按钮。
 *
 * 三者共用一份布局，差异只有图标与按钮 —— 因为它们在页面里的地位是同一件事：
 * 「这里暂时没有内容，以及为什么」。
 */
export enum StatePlaceholderKind {
  /** 正在建立本地数据（转圈 + 说明） */
  BUILDING = 'building',
  /** 没有内容，且不会自己变好（图标 + 说明 + 可选操作） */
  EMPTY = 'empty',
  /** 取数失败（同 EMPTY，但语义上是错误） */
  FAILED = 'failed'
}

/**
 * 整页状态占位视图。
 *
 * ## 与既有三个视图的关系
 *
 * `LoadingFailedView` / `NoNetworkView` / `EmptyContentView` 各自的适用面窄且文案写死：
 * 前两个的文案分别是「连不上服务器」与「网络中断」，`NoNetworkView` 还把补救动作绑在
 * 跳系统 Wi-Fi 设置上 —— 拿它们表达「上游数据源不可用」会把用户引到错误的设置页；
 * `EmptyContentView` 能传自定义图标与文案，但它用 `layoutWeight(1)`，不能作为整页根节点填充，
 * 也没有可见的操作按钮与「加载中」形态。
 *
 * 所以本组件**不合并**那三个（合并会改动它们 8 处调用页面的版式），而是按数据类页面的需要
 * 新做一份：文案由调用方给（因此 common 不依赖任何业务模块的资源）、操作按钮可见。
 *
 * 网络类失败仍然用 `NoNetworkView`，它的引导更准确。
 */
@Component
export struct StatePlaceholderView {
  /** 形态。默认 EMPTY —— 大多数调用点要的就是「没有内容」 */
  @Prop kind: StatePlaceholderKind = StatePlaceholderKind.EMPTY;
  /** 说明文字。由调用方给，所以 common 不需要知道任何业务模块的资源 */
  @Prop @Require message: ResourceStr;
  /** 操作按钮文案。undefined 表示不给按钮 */
  @Prop actionLabel: ResourceStr | undefined = undefined;
  /** 操作按钮回调。与 actionLabel 都在时才渲染按钮 */
  onAction?: () => void;
  @StorageProp(StorageKey.GLOBAL_INFO) globalInfoModel: GlobalInfoModel = new GlobalInfoModel();

  /** BUILDING 用转圈并给 loading_size 档位，其余两种用失败图标并给 failure_size 档位 */
  private spinning(): boolean {
    return this.kind === StatePlaceholderKind.BUILDING;
  }

  private hasAction(): boolean {
    return this.actionLabel !== undefined && this.onAction !== undefined;
  }

  @Builder
  SymbolBuilder() {
    if (this.spinning()) {
      Row() {
        LoadingProgress()
      }
      .width(new BreakpointType({
        sm: $r('app.float.loading_size_sm'),
        md: $r('app.float.loading_size_md'),
        lg: $r('app.float.loading_size_md'),
      }).getValue(this.globalInfoModel.widthBreakpoint))
      .aspectRatio(1)
    } else {
      Image($r('app.media.ic_failure'))
        .draggable(false)
        .width(new BreakpointType({
          sm: $r('app.float.failure_size_sm'),
          md: $r('app.float.failure_size_md'),
          lg: $r('app.float.failure_size_lg'),
        }).getValue(this.globalInfoModel.widthBreakpoint))
        .aspectRatio(1)
    }
  }

  build() {
    Column({ space: $r('sys.float.padding_level4') }) {
      this.SymbolBuilder()

      Text(this.message)
        .fontColor($r('sys.color.font_secondary'))
        .fontSize($r('sys.float.Body_M'))
        .textAlign(TextAlign.Center)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      // 只给「不点就永远不会变好」的那两种形态按钮。BUILDING 上放重试没有意义：
      // 正在建立的进度会自己往前走。
      if (this.hasAction()) {
        Button(this.actionLabel, { buttonStyle: ButtonStyleMode.NORMAL, controlSize: ControlSize.NORMAL })
          .onClick(() => {
            this.onAction?.();
          })
          .margin({ top: $r('sys.float.padding_level8') })
      }
    }
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
    .padding($r('sys.float.padding_level8'))
    .backgroundColor($r('sys.color.background_secondary'))
    .width('100%')
    .height('100%')
  }
}