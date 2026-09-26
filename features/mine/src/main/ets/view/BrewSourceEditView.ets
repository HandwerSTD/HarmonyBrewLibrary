/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { BreakpointType, CommonConstants, GlobalInfoModel, StorageKey } from '@ohos/common';
import {
  BrewSourceEditCancelEvent,
  BrewSourceEditStartEvent,
  BrewSourceSaveEvent,
  BrewSourceSettingVM,
} from '../viewmodel/BrewSourceSettingVM';
import type { BrewSourceEditParams, BrewSourceSettingState } from '../viewmodel/BrewSourceSettingState';

/** 输入框高度。与页面里其它单行控件（搜索框、胶囊按钮）保持同一档位 */
const FIELD_HEIGHT: number = 40;
/** 表单卡片内部留白 */
const FORM_INSET: Resource = $r('sys.float.padding_level6');

/**
 * 数据源的「新增 / 编辑」表单页。
 *
 * 与列表页同一套视觉：`comp_background_primary` 卡片 + `corner_radius_level8` + `comp_divider` 分割，
 * 左右内缩走同一份断点口径（sm 8 / md 12 / lg 16）。
 *
 * 三个刻意的取舍：
 * 1. **字段带独立标签，不只靠 placeholder**。placeholder 在输入后就消失，
 *    而这一页有两件事需要随时可读：哪个框是名称、哪个是地址（地址还可能是灰的 —— 内置源）。
 * 2. **校验错误带底色面板**，不是一行裸文字。它是「为什么存不下去」的唯一解释，
 *    混在表单里容易被当成说明文字划过去。
 * 3. **内置源的地址框额外给一句原因**。控件被禁用却不说明原因，用户只会以为是坏了。
 */
@Component
export struct BrewSourceEditView {
  viewModel: BrewSourceSettingVM = BrewSourceSettingVM.getInstance();
  @State state: BrewSourceSettingState = this.viewModel.getState();
  @StorageProp(StorageKey.GLOBAL_INFO) globalInfoModel: GlobalInfoModel =
    AppStorage.get(StorageKey.GLOBAL_INFO) ?? new GlobalInfoModel();
  private pathStack?: NavPathStack;
  private sourceId: string = '';
  private currentBaseUrl: string = '';
  private builtin: boolean = false;
  @State editing: boolean = false;

  private handleOnReady(ctx: NavDestinationContext): void {
    this.pathStack = ctx?.pathStack;
    const params: BrewSourceEditParams = ctx?.pathInfo?.param as BrewSourceEditParams;
    this.sourceId = params?.id ?? '';
    this.currentBaseUrl = params?.url ?? '';
    this.builtin = params?.builtin ?? false;
    this.editing = this.sourceId.length > 0;
    this.viewModel.sendEvent(new BrewSourceEditStartEvent(this.sourceId, params?.name ?? '',
      params?.url ?? ''));
  }

  /** 内容左右内缩。与列表页、以及「我的」页其它二级页同一口径 */
  private contentInset(): Length {
    return new BreakpointType<Length>({
      sm: $r('sys.float.padding_level8'),
      md: $r('sys.float.padding_level12'),
      lg: $r('sys.float.padding_level16'),
    }).getValue(this.globalInfoModel.widthBreakpoint);
  }

  build() {
    NavDestination() {
      Scroll() {
        Column({ space: CommonConstants.SPACE_16 }) {
          this.FormCard()

          Row({ space: CommonConstants.SPACE_8 }) {
            Button($r('app.string.brew_source_cancel'))
              .layoutWeight(1)
              .height(CommonConstants.SPACE_40)
              .fontSize($r('sys.float.Body_L'))
              .fontWeight(FontWeight.Medium)
              .backgroundColor($r('sys.color.comp_background_tertiary'))
              .fontColor($r('sys.color.font_primary'))
              .borderRadius($r('sys.float.corner_radius_level8'))
              .onClick(() => this.cancelAndPop())
            Button($r('app.string.brew_source_save'))
              .layoutWeight(1)
              .height(CommonConstants.SPACE_40)
              .fontSize($r('sys.float.Body_L'))
              .fontWeight(FontWeight.Medium)
              .borderRadius($r('sys.float.corner_radius_level8'))
              .onClick(() => this.submitEdit())
          }
          .width(CommonConstants.FULL_PERCENT)
        }
        .width(CommonConstants.FULL_PERCENT)
        .padding({
          left: this.contentInset(),
          right: this.contentInset(),
          top: $r('sys.float.padding_level8'),
          bottom: $r('sys.float.padding_level24'),
        })
      }
      .width(CommonConstants.FULL_PERCENT)
      .height(CommonConstants.FULL_PERCENT)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    }
    .title(this.editing ? $r('app.string.brew_source_edit') : $r('app.string.brew_source_add'))
    .padding({ top: $r('sys.float.padding_level4') })
    .backgroundColor($r('sys.color.background_secondary'))
    .onReady((ctx: NavDestinationContext) => this.handleOnReady(ctx))
    .onBackPressed(() => {
      this.viewModel.sendEvent(new BrewSourceEditCancelEvent());
      if (this.pathStack !== undefined) {
        this.pathStack.pop();
        return true;
      }
      return false;
    })
  }

  /**
   * 字段标签。`topGap` 由调用方给：ArkTS 里 @Builder 的调用不是组件，
   * 不能在调用点上再链 `.margin()`，所以间距必须作为参数传进来。
   */
  @Builder
  FieldLabel(label: ResourceStr, topGap: Length) {
    Text(label)
      .fontSize($r('sys.float.Body_M'))
      .fontColor($r('sys.color.font_secondary'))
      .width(CommonConstants.FULL_PERCENT)
      .margin({ top: topGap, bottom: $r('sys.float.padding_level2') })
  }

  @Builder
  FormCard() {
    Column() {
      this.FieldLabel($r('app.string.brew_source_name_label'), 0)
      TextInput({ text: this.state.editingName, placeholder: $r('app.string.brew_source_name_hint') })
        .height(FIELD_HEIGHT)
        .fontSize($r('sys.float.Body_M'))
        .fontColor($r('sys.color.font_primary'))
        .placeholderFont({ size: $r('sys.float.Body_M') })
        .placeholderColor($r('sys.color.font_tertiary'))
        .backgroundColor($r('sys.color.comp_background_tertiary'))
        .borderRadius($r('sys.float.corner_radius_level4'))
        .padding({ left: $r('sys.float.padding_level4'), right: $r('sys.float.padding_level4') })
        .onChange((value: string) => this.viewModel.setEditingName(value))

      this.FieldLabel($r('app.string.brew_source_url_label'), $r('sys.float.padding_level6'))
      TextInput({ text: this.state.editingUrl, placeholder: $r('app.string.brew_source_url_hint') })
        .height(FIELD_HEIGHT)
        .fontSize($r('sys.float.Body_M'))
        .fontColor($r('sys.color.font_primary'))
        .placeholderFont({ size: $r('sys.float.Body_M') })
        .placeholderColor($r('sys.color.font_tertiary'))
        .backgroundColor($r('sys.color.comp_background_tertiary'))
        .borderRadius($r('sys.float.corner_radius_level4'))
        .padding({ left: $r('sys.float.padding_level4'), right: $r('sys.float.padding_level4') })
        .enabled(!this.builtin)
        .onChange((value: string) => this.viewModel.setEditingUrl(value))

      // 禁用而不说明原因，用户只会当成控件坏了
      if (this.builtin) {
        Text($r('app.string.brew_source_builtin_url_locked'))
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_tertiary'))
          .width(CommonConstants.FULL_PERCENT)
          .margin({ top: $r('sys.float.padding_level2') })
      }

      this.FieldLabel($r('app.string.brew_source_dialect_label'), $r('sys.float.padding_level6'))
      // 方言由探测自动识别，只读展示，不提供会覆盖自动识别结果的手动下拉。
      Row() {
        Text(this.viewModel.editingDialectText())
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('sys.color.font_secondary'))
          .maxLines(2)
          .ellipsisMode(EllipsisMode.END)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width(CommonConstants.FULL_PERCENT)
      .height(FIELD_HEIGHT)
      .alignItems(VerticalAlign.Center)
      .padding({
        left: $r('sys.float.padding_level4'),
        right: $r('sys.float.padding_level4'),
      })
      .backgroundColor($r('sys.color.comp_background_tertiary'))
      .borderRadius($r('sys.float.corner_radius_level4'))

      if (this.state.errorText.length > 0) {
        this.ErrorPanel()
      }
    }
    .width(CommonConstants.FULL_PERCENT)
    .alignItems(HorizontalAlign.Start)
    .padding(FORM_INSET)
    .backgroundColor($r('sys.color.comp_background_primary'))
    .borderRadius($r('sys.float.corner_radius_level8'))
  }

  @Builder
  ErrorPanel() {
    Row() {
      SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
        .fontSize($r('sys.float.Title_S'))
        .fontColor([$r('sys.color.warning')])
      Text(this.viewModel.saveErrorText())
        .fontSize($r('sys.float.Body_S'))
        .fontColor($r('sys.color.warning'))
        .maxLines(3)
        .ellipsisMode(EllipsisMode.END)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .margin({ left: $r('sys.float.padding_level2') })
    }
    .width(CommonConstants.FULL_PERCENT)
    .alignItems(VerticalAlign.Top)
    .padding({
      left: $r('sys.float.padding_level3'),
      right: $r('sys.float.padding_level3'),
      top: $r('sys.float.padding_level2'),
      bottom: $r('sys.float.padding_level2'),
    })
    .borderRadius($r('sys.float.corner_radius_level6'))
    .backgroundColor($r('sys.color.comp_background_warning_secondary'))
    .margin({ top: $r('sys.float.padding_level6') })
  }

  private submitEdit(): void {
    const isNew: boolean = this.sourceId.length === 0;
    const urlChanged: boolean = this.state.editingUrl.trim() !== this.currentBaseUrl;
    if (isNew || !urlChanged) {
      this.saveAndPop();
      return;
    }
    this.getUIContext().showAlertDialog({
      title: $r('app.string.brew_source_save'),
      message: $r('app.string.brew_source_edit_url_confirm'),
      primaryButton: {
        value: $r('app.string.brew_source_cancel'),
        action: () => {
        }
      },
      secondaryButton: {
        value: $r('app.string.brew_source_save'),
        action: () => this.saveAndPop()
      }
    });
  }

  private saveAndPop(): void {
    const saved: boolean = this.viewModel.save(new BrewSourceSaveEvent(this.sourceId,
      this.state.editingName, this.state.editingUrl));
    if (saved && this.pathStack !== undefined) {
      this.pathStack.pop();
    }
  }

  private cancelAndPop(): void {
    this.viewModel.sendEvent(new BrewSourceEditCancelEvent());
    if (this.pathStack !== undefined) {
      this.pathStack.pop();
    }
  }
}

@Builder
export function BrewSourceEditBuilder() {
  BrewSourceEditView()
}
