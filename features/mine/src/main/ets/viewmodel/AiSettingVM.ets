/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { BaseVM, BaseVMEvent, Logger } from '@ohos/common';
import {
  AiClient,
  AiError,
  AiErrorKind,
  AiSettingsStore,
  AI_DEEPSEEK_BASE_URL,
  AI_DEEPSEEK_DEFAULT_MODEL,
  AI_PROVIDER_DEEPSEEK,
  isKnownAiProvider,
} from '@ohos/brewcommon';
import { AiSettingState } from './AiSettingState';

const TAG: string = '[ai]';

export class AiSettingInitEvent implements BaseVMEvent {
}

/** 切 provider（deepseek ↔ custom）。DeepSeek 时 baseURL/model 填模板值并锁定。 */
export class AiSettingProviderEvent implements BaseVMEvent {
  public provider: string;

  public constructor(provider: string) {
    this.provider = provider;
  }
}

/** 切「自动生成 AI 讲解」开关（即时落盘；与表单保存按钮解耦——开关语义独立）。 */
export class AiSettingAutoExplainEvent implements BaseVMEvent {
  public enabled: boolean;

  public constructor(enabled: boolean) {
    this.enabled = enabled;
  }
}

/** 切「自动解析更新日志」开关（Y 更新情报中心；即时落盘，同上与保存按钮解耦）。 */
export class AiSettingAutoIntelEvent implements BaseVMEvent {
  public enabled: boolean;

  public constructor(enabled: boolean) {
    this.enabled = enabled;
  }
}

export class AiSettingSaveEvent implements BaseVMEvent {
}

/** 保存 Key（输入框内容随事件传，VM 保存后立刻清空 state 里的副本）。 */
export class AiSettingKeySaveEvent implements BaseVMEvent {
  public key: string;

  public constructor(key: string) {
    this.key = key;
  }
}

export class AiSettingKeyClearEvent implements BaseVMEvent {
}

export class AiSettingTestEvent implements BaseVMEvent {
}

/**
 * AI 设置页的 VM（spec §3.1）。单例；state 每页实例自己持（与 MinePageVM 不同的点：
 * 本页不会叠页，单例 state 亦可——但保持「state 注入」的既有签名以对齐 BaseVM）。
 *
 * Key 的流向（G1）：输入框 → 事件 → AiSettingsStore.saveApiKey()（Asset Store）→
 * 立即清空 state.editingKey。**saveApiKey 的返回值与 Key 本身永不落日志**。
 */
export class AiSettingVM extends BaseVM<AiSettingState> {
  private static instance: AiSettingVM;

  private constructor() {
    super(new AiSettingState());
  }

  public static getInstance(): AiSettingVM {
    if (!AiSettingVM.instance) {
      AiSettingVM.instance = new AiSettingVM();
    }
    return AiSettingVM.instance;
  }

  public sendEvent(event: BaseVMEvent): void {
    if (event instanceof AiSettingInitEvent) {
      this.init();
    } else if (event instanceof AiSettingProviderEvent) {
      this.switchProvider(event.provider);
    } else if (event instanceof AiSettingAutoExplainEvent) {
      this.setAutoExplain(event.enabled);
    } else if (event instanceof AiSettingAutoIntelEvent) {
      this.setAutoIntel(event.enabled);
    } else if (event instanceof AiSettingSaveEvent) {
      this.saveConfig();
    } else if (event instanceof AiSettingKeySaveEvent) {
      this.saveKey(event.key);
    } else if (event instanceof AiSettingKeyClearEvent) {
      this.clearKey();
    } else if (event instanceof AiSettingTestEvent) {
      this.testConnection();
    }
  }

  // ------------------------------------------------------------ 表单联动

  public setEditingBaseUrl(value: string): void {
    const state: AiSettingState = this.getState();
    if (state.editingProvider === AI_PROVIDER_DEEPSEEK) {
      return; // 预置 provider 的 baseURL 锁定
    }
    state.editingBaseUrl = value;
  }

  public setEditingModel(value: string): void {
    this.getState().editingModel = value;
  }

  /** 是否允许编辑 baseURL（DeepSeek 模板锁定）。 */
  public baseUrlLocked(state: AiSettingState): boolean {
    return state.editingProvider === AI_PROVIDER_DEEPSEEK;
  }

  private init(): void {
    const state: AiSettingState = this.getState();
    state.snapshot = AiSettingsStore.snapshot();
    state.editingProvider = state.snapshot.config.provider;
    state.editingBaseUrl = state.snapshot.config.baseUrl.length > 0 ?
      state.snapshot.config.baseUrl : AI_DEEPSEEK_BASE_URL;
    state.editingModel = state.snapshot.config.model.length > 0 ?
      state.snapshot.config.model : AI_DEEPSEEK_DEFAULT_MODEL;
    state.editingKey = '';
    state.errorText = '';
    state.editingAutoExplain = AiSettingsStore.autoExplain();
    state.editingAutoIntel = AiSettingsStore.autoReleaseIntel();
    state.testOkModel = '';
    state.testOkLatencyMs = -1;
    state.testErrorKind = '';
    state.savedFlash = false;
  }

  private switchProvider(provider: string): void {
    if (!isKnownAiProvider(provider)) {
      return;
    }
    const state: AiSettingState = this.getState();
    state.editingProvider = provider;
    if (provider === AI_PROVIDER_DEEPSEEK) {
      state.editingBaseUrl = AI_DEEPSEEK_BASE_URL;
      if (state.editingModel.length === 0) {
        state.editingModel = AI_DEEPSEEK_DEFAULT_MODEL;
      }
    }
    Logger.info(TAG, `provider switched to=${provider}`);
  }

  /** 自动生成开关：即时落盘（不走表单保存），成功后同步快照。 */
  private setAutoExplain(enabled: boolean): void {
    const state: AiSettingState = this.getState();
    const ok: boolean = AiSettingsStore.saveAutoExplain(enabled);
    if (ok) {
      state.editingAutoExplain = enabled;
      state.snapshot = AiSettingsStore.snapshot();
    }
  }

  /** 自动解析更新日志开关：即时落盘，成功后同步快照（语义与 setAutoExplain 同构）。 */
  private setAutoIntel(enabled: boolean): void {
    const state: AiSettingState = this.getState();
    const ok: boolean = AiSettingsStore.saveAutoReleaseIntel(enabled);
    if (ok) {
      state.editingAutoIntel = enabled;
      state.snapshot = AiSettingsStore.snapshot();
    }
  }

  private saveConfig(): boolean {
    const state: AiSettingState = this.getState();
    const model: string = state.editingModel.trim();
    if (model.length === 0) {
      state.errorText = 'invalid';
      return false;
    }
    const config = AiSettingsStore.loadConfig();
    config.provider = state.editingProvider;
    config.baseUrl = state.editingProvider === AI_PROVIDER_DEEPSEEK ?
      AI_DEEPSEEK_BASE_URL : state.editingBaseUrl.trim();
    config.model = model;
    const ok: boolean = AiSettingsStore.saveConfig(config);
    state.errorText = ok ? '' : 'save-failed';
    state.savedFlash = ok;
    if (ok) {
      state.snapshot = AiSettingsStore.snapshot();
      Logger.info(TAG, `config saved provider=${config.provider} model=${config.model}`);
    }
    return ok;
  }

  private saveKey(key: string): void {
    const state: AiSettingState = this.getState();
    const trimmed: string = key.trim();
    if (trimmed.length === 0) {
      state.errorText = 'key-empty';
      return;
    }
    AiSettingsStore.saveApiKey(trimmed).then((where: string) => {
      // where = '' | 'memory' | 'error'；**不含 Key 值**
      const state2: AiSettingState = this.getState();
      state2.editingKey = '';
      state2.snapshot = AiSettingsStore.snapshot();
      state2.keyMemoryOnly = where === 'memory';
      state2.savedFlash = true;
      state2.errorText = where === 'memory' ? 'key-memory-only' : '';
      Logger.info(TAG, `key save done store=${where === 'memory' ? 'memory' : 'asset'}`);
    });
  }

  private clearKey(): void {
    AiSettingsStore.removeApiKey().then(() => {
      const state: AiSettingState = this.getState();
      state.editingKey = '';
      state.snapshot = AiSettingsStore.snapshot();
      Logger.info(TAG, `key cleared`);
    });
  }

  /** 测试连接（G2）：最小 completion；成功显示 model + 时延，失败按 E 分级。 */
  private testConnection(): void {
    const state: AiSettingState = this.getState();
    if (state.testing) {
      return;
    }
    // 先落当前表单（没保存的配置也能测），再发探测
    if (!this.saveConfig()) {
      return;
    }
    state.testing = true;
    state.testOkModel = '';
    state.testOkLatencyMs = -1;
    state.testErrorKind = '';
    AiClient.probe()
      .then((completion) => {
        const s: AiSettingState = this.getState();
        s.testing = false;
        // 只存结构化值，不拼展示串：格式化归 View 的带参资源（G2）
        s.testOkModel = completion.model;
        s.testOkLatencyMs = completion.latencyMs;
        Logger.info(TAG, `probe ok model=${completion.model} latency=${completion.latencyMs}`);
      })
      .catch((error: AiError) => {
        const s: AiSettingState = this.getState();
        s.testing = false;
        s.testErrorKind = error instanceof AiError ? error.kind : AiErrorKind.E2_NETWORK;
        Logger.error(TAG, `probe fail kind=${s.testErrorKind}`);
      });
  }
}
