/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { BreakpointType, CommonConstants, GlobalInfoModel, StorageKey, Toast } from '@ohos/common';
import {
  AiErrorKind,
  AI_PROVIDER_CUSTOM,
  AI_PROVIDER_DEEPSEEK,
} from '@ohos/brewcommon';
import {
  AiSettingInitEvent,
  AiSettingKeyClearEvent,
  AiSettingKeySaveEvent,
  AiSettingProviderEvent,
  AiSettingSaveEvent,
  AiSettingTestEvent,
  AiSettingVM,
} from '../viewmodel/AiSettingVM';
import { AiSettingState } from '../viewmodel/AiSettingState';

/** 输入框高度。与数据源编辑页（BrewSourceEditView）同一档位 */
const FIELD_HEIGHT: number = 40;
/** 表单卡片内部留白 */
const FORM_INSET: number = 12;

/**
 * AI 设置页（spec §3.1 / G1 / G2）。
 *
 * 结构 = 「服务商（DeepSeek / 自定义）+ 接口地址 + 模型 + API Key + 测试连接」的表单卡，
 * 视觉与数据源编辑页同源（comp_background_primary 卡 + 断点内缩）。
 *
 * ## Key 安全（G1）在本页的落点
 *
 * - Key 输入框 `TextInput.type(InputType.Password)`：屏幕上也不露明文；
 * - 保存即走 Asset Store Kit；输入框内容立刻清空，state 里不保留副本；
 * - 页面上只显示「已配置 / 未配置」与「仅本次会话有效」标记，**永不回显 Key**；
 * - 测试连接的日志只有 model 与时延（`[ai] probe ok/…`），Key 不进 hilog。
 */
@Component
export struct AiSettingView {
  @StorageProp(StorageKey.GLOBAL_INFO) globalInfoModel: GlobalInfoModel =
    AppStorage.get(StorageKey.GLOBAL_INFO) ?? new GlobalInfoModel();
  @State state: AiSettingState = AiSettingVM.getInstance().getState();
  private pathStack?: NavPathStack;

  aboutToAppear(): void {
    AiSettingVM.getInstance().sendEvent(new AiSettingInitEvent());
    // 单例 VM 的 state 不是本组件的 @State 引用外的另一份——这里引用同一实例后，
    // 字段变化靠 @State 的一级观察刷新；保存后的整体替换走 snapshot 字段。
  }

  private handleOnReady(ctx: NavDestinationContext): void {
    this.pathStack = ctx?.pathStack;
  }

  /** 内容左右内缩。与「我的」页二级页同一口径（sm 8 / md 12 / lg 16） */
  private contentInset(): Length {
    return new BreakpointType<Length>({
      sm: 8,
      md: 12,
      lg: 16,
    }).getValue(this.globalInfoModel.widthBreakpoint);
  }

  build() {
    NavDestination() {
      Scroll() {
        Column({ space: CommonConstants.SPACE_16 }) {
          this.FormCard()
        }
        .width(CommonConstants.FULL_PERCENT)
        .padding({
          left: this.contentInset(),
          right: this.contentInset(),
          top: 8,
          bottom: 24,
        })
      }
      .width(CommonConstants.FULL_PERCENT)
      .height(CommonConstants.FULL_PERCENT)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    }
    .title($r('app.string.ai_settings_title'))
    .padding({ top: 4 })
    .backgroundColor($r('sys.color.background_secondary'))
    .onReady((ctx: NavDestinationContext) => this.handleOnReady(ctx))
  }

  @Builder
  FieldLabel(label: ResourceStr, topGap: Length) {
    Text(label)
      .fontSize($r('sys.float.Body_M'))
      .fontColor($r('sys.color.font_secondary'))
      .width(CommonConstants.FULL_PERCENT)
      .margin({ top: topGap, bottom: 4 })
  }

  @Builder
  ProviderChips() {
    Row({ space: 8 }) {
      this.ProviderChip($r('app.string.ai_provider_deepseek'), AI_PROVIDER_DEEPSEEK)
      this.ProviderChip($r('app.string.ai_provider_custom'), AI_PROVIDER_CUSTOM)
    }
    .width(CommonConstants.FULL_PERCENT)
  }

  @Builder
  ProviderChip(label: ResourceStr, provider: string) {
    Text(label)
      .fontSize($r('sys.float.Body_M'))
      .fontColor(this.state.editingProvider === provider ?
        $r('sys.color.font_on_primary') : $r('sys.color.font_primary'))
      .padding({
        left: 12,
        right: 12,
        top: 6,
        bottom: 6,
      })
      .borderRadius($r('sys.float.corner_radius_level4'))
      .backgroundColor(this.state.editingProvider === provider ?
        $r('sys.color.ohos_id_color_emphasize') : $r('sys.color.comp_background_tertiary'))
      .onClick(() => {
        AiSettingVM.getInstance().sendEvent(new AiSettingProviderEvent(provider));
      })
  }

  @Builder
  FormCard() {
    Column() {
      this.FieldLabel($r('app.string.ai_settings_provider'), 0)
      this.ProviderChips()

      this.FieldLabel($r('app.string.ai_settings_baseurl'), 12)
      TextInput({
        text: this.state.editingBaseUrl,
        placeholder: 'https://api.deepseek.com',
      })
        .height(FIELD_HEIGHT)
        .fontSize($r('sys.float.Body_M'))
        .fontColor($r('sys.color.font_primary'))
        .backgroundColor($r('sys.color.comp_background_tertiary'))
        .borderRadius($r('sys.float.corner_radius_level4'))
        .enabled(!AiSettingVM.getInstance().baseUrlLocked(this.state))
        .onChange((value: string) => AiSettingVM.getInstance().setEditingBaseUrl(value))

      this.FieldLabel($r('app.string.ai_settings_model'), 12)
      TextInput({ text: this.state.editingModel, placeholder: 'deepseek-chat' })
        .height(FIELD_HEIGHT)
        .fontSize($r('sys.float.Body_M'))
        .fontColor($r('sys.color.font_primary'))
        .backgroundColor($r('sys.color.comp_background_tertiary'))
        .borderRadius($r('sys.float.corner_radius_level4'))
        .onChange((value: string) => AiSettingVM.getInstance().setEditingModel(value))

      this.FieldLabel($r('app.string.ai_settings_key'), 12)
      TextInput({
        text: this.state.editingKey,
        placeholder: $r('app.string.ai_settings_key_hint'),
      })
        .height(FIELD_HEIGHT)
        .fontSize($r('sys.float.Body_M'))
        .fontColor($r('sys.color.font_primary'))
        .backgroundColor($r('sys.color.comp_background_tertiary'))
        .borderRadius($r('sys.float.corner_radius_level4'))
        .type(InputType.Password)
        .onChange((value: string) => {
          this.state.editingKey = value;
        })

      Row({ space: 8 }) {
        Button($r('app.string.ai_settings_save'))
          .layoutWeight(1)
          .height(CommonConstants.SPACE_40)
          .fontSize($r('sys.float.Body_L'))
          .fontWeight(FontWeight.Medium)
          .borderRadius($r('sys.float.corner_radius_level8'))
          .onClick(() => {
            const key: string = this.state.editingKey;
            if (key.trim().length > 0) {
              AiSettingVM.getInstance().sendEvent(new AiSettingKeySaveEvent(key));
            }
            AiSettingVM.getInstance().sendEvent(new AiSettingSaveEvent());
            Toast.showToast($r('app.string.ai_settings_saved'));
          })
        Button($r('app.string.ai_settings_test'))
          .layoutWeight(1)
          .height(CommonConstants.SPACE_40)
          .fontSize($r('sys.float.Body_L'))
          .fontWeight(FontWeight.Medium)
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          .fontColor($r('sys.color.font_primary'))
          .borderRadius($r('sys.float.corner_radius_level8'))
          .enabled(!this.state.testing)
          .onClick(() => {
            AiSettingVM.getInstance().sendEvent(new AiSettingTestEvent());
          })
      }
      .width(CommonConstants.FULL_PERCENT)
      .margin({ top: 16 })

      if (this.state.testing) {
        Row() {
          LoadingProgress()
            .width(16)
            .height(16)
          Text($r('app.string.ai_settings_testing'))
            .fontSize($r('sys.float.Body_S'))
            .fontColor($r('sys.color.font_secondary'))
            .margin({ left: 6 })
        }
        .width(CommonConstants.FULL_PERCENT)
        .margin({ top: 8 })
      }

      if (this.state.testOkModel.length > 0 && this.state.testOkLatencyMs >= 0) {
        // G2：成功显示 model 与时延。**带参资源格式化**——不能在模板字符串里内插 $r()
        //（Resource 对象会被 toString 成 [object Object]，真机实测过）。
        Text($r('app.string.ai_settings_test_ok_detail', this.state.testOkModel,
          this.state.testOkLatencyMs))
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_emphasize'))
          .width(CommonConstants.FULL_PERCENT)
          .margin({ top: 8 })
      }

      if (this.state.testErrorKind.length > 0) {
        // G2：失败按 §8 分级给明确原因
        Text(this.testErrorText())
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.warning'))
          .width(CommonConstants.FULL_PERCENT)
          .margin({ top: 8 })
      }

      if (this.state.snapshot.hasKey) {
        Row() {
          Text(this.state.snapshot.keyMemoryOnly ?
            $r('app.string.ai_settings_key_memory_only') : $r('app.string.ai_settings_key_saved'))
            .fontSize($r('sys.float.Body_S'))
            .fontColor($r('sys.color.font_secondary'))
            .layoutWeight(1)
          Text($r('app.string.ai_settings_key_clear'))
            .fontSize($r('sys.float.Body_S'))
            .fontColor($r('sys.color.warning'))
            .onClick(() => {
              AiSettingVM.getInstance().sendEvent(new AiSettingKeyClearEvent());
            })
            .padding({ left: 8 })
        }
        .width(CommonConstants.FULL_PERCENT)
        .margin({ top: 8 })
      }

      if (this.state.errorText.length > 0) {
        Text(this.errorText())
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.warning'))
          .width(CommonConstants.FULL_PERCENT)
          .margin({ top: 8 })
      }
    }
    .width(CommonConstants.FULL_PERCENT)
    .alignItems(HorizontalAlign.Start)
    .padding(FORM_INSET)
    .backgroundColor($r('sys.color.comp_background_primary'))
    .borderRadius($r('sys.float.corner_radius_level8'))
  }

  private testErrorText(): ResourceStr {
    if (this.state.testErrorKind === AiErrorKind.E1_NO_KEY) {
      return $r('app.string.ai_error_e1');
    }
    if (this.state.testErrorKind === AiErrorKind.E3_TIMEOUT) {
      return $r('app.string.ai_error_e3');
    }
    if (this.state.testErrorKind === AiErrorKind.E4_BAD_FORMAT) {
      return $r('app.string.ai_error_e4');
    }
    if (this.state.testErrorKind === AiErrorKind.E5_BLOCKED) {
      return $r('app.string.ai_error_e5');
    }
    if (this.state.testErrorKind === AiErrorKind.E2_NETWORK) {
      return $r('app.string.ai_error_e2');
    }
    return $r('app.string.ai_error_e2');
  }

  private errorText(): ResourceStr {
    if (this.state.errorText === 'invalid') {
      return $r('app.string.ai_settings_invalid');
    }
    if (this.state.errorText === 'key-empty') {
      return $r('app.string.ai_settings_key_hint');
    }
    return $r('app.string.ai_error_e4');
  }
}

@Builder
export function AiSettingViewBuilder() {
  AiSettingView()
}
