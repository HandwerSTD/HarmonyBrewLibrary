/*
 * Copyright (c) 2024 Huawei Device Co., Ltd.
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

import type { common } from '@kit.AbilityKit';
import { HdsNavDestination, HdsSideBar } from '@kit.UIDesignKit';
import {
  BreakpointType,
  CommonConstants,
  CustomImmersiveStyle,
  GlobalInfoModel,
  MaterialUtil,
  ProcessUtil,
  StorageKey,
  Toast,
  ColumnEnum,
} from '@ohos/common';
import {
  BrewCommandRunner,
  BrewCommandSheet,
  BrewCommandState,
  BrewCommandStatus,
  brewCommandStatusText,
  isBrewCommandEnded,
} from '@ohos/brewcommon';
import { CustomSideBar } from '../component/CustomSideBar';
import { DEFAULT_TAB } from '../model/TabBarModel';
import { HomeView } from './HomeView';

const PRESS_TIME: number = 1500;
const TAG: string = '[PcMainPage]';
const SCROLL_PADDING_LG: number = 32;
const BREAKPOINTS: string[] = ['xs', 'sm', 'md', 'lg', 'xl'];

/** 主页面容器：侧边栏 + 页签内容。路由入口 `MainPageBuilder` 在 entry 模块的 `page/PcMainPage` */
@Component({ freezeWhenInactive: true })
export struct PcMainPage {
  @StorageLink(StorageKey.GLOBAL_INFO) globalInfoModel: GlobalInfoModel =
    AppStorage.get(StorageKey.GLOBAL_INFO) ?? new GlobalInfoModel();
  @State currentIndex: number = DEFAULT_TAB;
  private backPressTime: number = 0;
  @State isShown: boolean = false;
  /**
   * 与 `BrewCommandRunner` 单例里**同一个**命令状态实例（`BrewCommandState` 是 `@Observed`）。
   * Sheet 的开关、侧边栏入口的显示判据、页面按钮的文案都读它。
   */
  @State commandState: BrewCommandState = BrewCommandRunner.getInstance().getState();
  /**
   * 上一次看到的命令状态。用来分辨「刚刚结束」与「进页面时看到的是上次那条命令的结局」，
   * 后者不该再弹一次结束提示。
   */
  private lastCommandStatus: BrewCommandStatus = BrewCommandStatus.IDLE;
  /** 命令状态回调。存成字段，保证 `subscribe` / `unsubscribe` 拿到的是同一个函数对象 */
  private commandListener: () => void = () => {
    this.onCommandEnded();
  };

  aboutToAppear(): void {
    // 结束提示由这个顶层宿主负责：它从应用启动到退出一直挂在树上，
    // 页面按钮与侧边栏入口只改 `sheetShown`，不各自弹提示。
    BrewCommandRunner.getInstance().subscribe(this.commandListener);
  }

  aboutToDisappear(): void {
    BrewCommandRunner.getInstance().unsubscribe(this.commandListener);
  }

  /** 命令结束时补一条提示。Sheet 关着才弹 —— Sheet 里已经有状态行了 */
  private onCommandEnded(): void {
    const status: BrewCommandStatus = this.commandState.status;
    if (status === this.lastCommandStatus) {
      return;
    }
    this.lastCommandStatus = status;
    if (!isBrewCommandEnded(status) || this.commandState.sheetShown) {
      return;
    }
    Toast.showToast(brewCommandStatusText(this.commandState));
  }

  onPageShow(): void {
    this.isShown = true;
    CommonConstants.PROMISE_WAIT(500).then(() => {
      AppStorage.setOrCreate(StorageKey.BLUE_RENDER_GROUP, false);
    });
  }

  onBackPress(): boolean {
    const newTime = new Date().getTime();
    if (this.backPressTime && newTime - this.backPressTime < PRESS_TIME) {
      ProcessUtil.moveAbilityToBackground(this.getUIContext().getHostContext() as common.UIAbilityContext);
      return true;
    }
    this.backPressTime = newTime;
    Toast.showToast($r('app.string.back_toast'));
    return true;
  }

  @Builder
  CustomSideBarBuilder() {
    CustomSideBar({
      currentIndex: this.currentIndex,
      sideBarChange: (currentIndex: number) => {
        this.currentIndex = currentIndex;
      }
    })
  }

  /** 全局唯一的执行 Sheet 的内容。命令状态在单例里，关掉 Sheet 不影响命令执行 */
  @Builder
  CommandSheetBuilder() {
    BrewCommandSheet({
      state: this.commandState,
      onInterrupt: () => {
        BrewCommandRunner.getInstance().interrupt();
      },
      onForceKill: () => {
        BrewCommandRunner.getInstance().interrupt();
      },
      onClose: () => {
        BrewCommandRunner.getInstance().closeSheet();
      },
    })
  }

  @Builder
  contentPanelBuilder() {
    GridRow({
      columns: { sm: ColumnEnum.SM, md: ColumnEnum.MD, lg: ColumnEnum.LG },
      direction: GridRowDirection.Row,
      breakpoints: { reference: BreakpointsReference.ComponentSize }
    }) {
      GridCol({ span: { sm: ColumnEnum.SM, md: ColumnEnum.MD, lg: ColumnEnum.LG } }) {
        HomeView({ showTabBar: false, currentIndex: this.currentIndex, isShown: this.isShown })
      }
      .margin({
        left: -SCROLL_PADDING_LG,
        right: -SCROLL_PADDING_LG,
      })
    }
    .padding({
      left: SCROLL_PADDING_LG,
      right: SCROLL_PADDING_LG,
    })
    .clip(false)
    .onBreakpointChange((breakpoints: string) => {
      this.globalInfoModel.widthBreakpoint =
        BREAKPOINTS.includes(breakpoints) ? BREAKPOINTS.indexOf(breakpoints) : WidthBreakpoint.WIDTH_XL;
    })
  }

  build() {
    HdsNavDestination() {
      HdsSideBar({
        isShowSideBar: true,
        autoHide: false,
        sideBarContainerType: SideBarContainerType.Embed,
        sideBarWidth: CommonConstants.SIDE_BAR_WIDTH,
        sideBarPanelBuilder: () => {
          this.CustomSideBarBuilder()
        },
        contentPanelBuilder: () => {
          this.contentPanelBuilder()
        },
      })
    }
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .transition(TransitionEffect.OPACITY)
    .hideTitleBar(true)
    .backgroundColor($r('sys.color.background_secondary'))
    // 执行 Sheet 的宿主绑在这里：五个页签内容与所有二级页都在这个容器的下方，
    // 从页面按钮或侧边栏入口打开的都是这一个半模态。
    // 材质与宽窄屏的尺寸口径沿用「我的 - 设置」的登录 Sheet 写法。
    // 关闭登记放在退场动画结束后的 onDisappear：官方文档写明 onWillDisappear 里不允许修改状态变量。
    .bindSheet(this.commandState.sheetShown, this.CommandSheetBuilder(),
      MaterialUtil.getMaterialOptions<SheetOptions>({
        originOption: {
          showClose: false,
          preferType: (this.globalInfoModel.widthBreakpoint === WidthBreakpoint.WIDTH_SM &&
            !AppStorage.get<boolean>(StorageKey.IS_SIDEBAR_LAYOUT)) ? SheetType.BOTTOM : SheetType.CENTER,
          height: this.globalInfoModel.widthBreakpoint === WidthBreakpoint.WIDTH_XL ?
            ((this.globalInfoModel.deviceHeight - this.globalInfoModel.decorHeight) *
              CommonConstants.SHEET_HEIGHT_RATIO_XL) : SheetSize.LARGE,
          width: this.globalInfoModel.widthBreakpoint === WidthBreakpoint.WIDTH_XL ?
            CommonConstants.SHEET_WIDTH_XL :
            undefined,
          onWillAppear: () => {
            BrewCommandRunner.getInstance().markViewed();
          },
          onDisappear: () => {
            BrewCommandRunner.getInstance().closeSheet();
          },
        },
        param: {
          style: CustomImmersiveStyle.ULTRA_THICK,
          backgroundColor: Color.Transparent,
        },
      }) as SheetOptions
    )
    .onBackPressed(() => {
      return this.onBackPress();
    })
    .onShown(() => {
      this.onPageShow();
    })
    .onHidden(() => {
      AppStorage.setOrCreate(StorageKey.BLUE_RENDER_GROUP, true);
      this.isShown = false;
    })
    .height('100%')
    .width('100%')
  }
}