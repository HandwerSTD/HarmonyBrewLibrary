/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { Logger, StorageKey } from '@ohos/common';
import {
  AI_ASSET_ALIAS_API_KEY,
  AI_PREFS_KEY_CONFIG,
  AI_PREFS_STORE,
} from '../constant/AiConstants';
import { AiProviderConfig, AiSettingsSnapshot } from '../model/AiTypes';

const TAG: string = '[ai]';

/**
 * BYOK 设置的存储（spec §3.1 / G1）。
 *
 * ## Key 只进 Asset Store Kit
 *
 * API Key 存 `@kit.AssetStoreKit`（alias = `AI_ASSET_ALIAS_API_KEY`，设备解锁即可读，
 * 不落应用沙箱的任何文件）。baseURL / model / provider 存普通 GSKV 偏好
 * （store `brew_ai_settings`）。三处口径由本类收敛：
 *   - **偏好文件**：写入前不含 Key 字段；
 *   - **hilog**：本类的日志只打 ok=/code=，永不拼 Key 值；
 *   - **缓存文件**：AI 缓存（AiCache）只落模型输出，不落请求头。
 *
 * ## Asset 不可用时的兜底（spec §13 风险行）
 *
 * `add()` 抛 24000001（服务不可用）等异常时，Key 退到**本进程内存**（`memoryKey`）：
 * 会话内功能可用，重启后需重填；`keyMemoryOnly=true` 让设置页能提示这件事。
 * 这条路径**不写盘**——宁可丢 Key 也不把明文落到偏好文件，G1 没有折中档。
 */
export class AiSettingsStore {
  /** Asset 不可用时的进程内 Key 兜底（永不持久化）。 */
  private static memoryKey: string = '';
  /** 会话内缓存「Key 是否可用」的结论，避免读路径每次都过一遍 asset.query。 */
  private static keyAvailable: boolean = false;
  /** 偏好句柄（懒加载；Context 未就绪时返回 null，与 BrewSourcePrefs 同语义）。 */
  private static store: preferences.Preferences | undefined = undefined;

  // ------------------------------------------------------------ Key（Asset Store）

  /** 保存 Key。Asset 成功返回 ''（持久）；退内存兜底返回 'memory'；失败抛错给 UI 提示。 */
  public static async saveApiKey(key: string): Promise<string> {
    const trimmed: string = key.trim();
    if (trimmed.length === 0) {
      return AiSettingsStore.removeApiKey();
    }
    try {
      const attrs: asset.AssetMap = new Map<asset.Tag, asset.Value>();
      attrs.set(asset.Tag.SECRET, AiSettingsStore.toBytes(trimmed));
      attrs.set(asset.Tag.ALIAS, AiSettingsStore.toBytes(AI_ASSET_ALIAS_API_KEY));
      attrs.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_POWERED_ON);
      try {
        // 先删旧值：asset 对同 alias 的重复 add 抛 24000003。remove 的 NOT_FOUND 不是错误。
        asset.removeSync(attrs);
      } catch (removeErr) {
        const rmErr: BusinessError = removeErr as BusinessError;
        if (rmErr.code !== asset.ErrorCode.NOT_FOUND) {
          Logger.warn(TAG, `asset remove before add failed, code=${rmErr.code}`);
        }
      }
      asset.addSync(attrs);
      AiSettingsStore.memoryKey = '';
      AiSettingsStore.keyAvailable = true;
      Logger.info(TAG, `key saved ok=true store=asset`);
      return '';
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.error(TAG, `asset add failed, code=${e.code}, msg=${e.message}`);
      // Asset 不可用：退进程内存（spec §13 方案 B 的保守形态——不落盘版本）。
      AiSettingsStore.memoryKey = trimmed;
      AiSettingsStore.keyAvailable = true;
      Logger.warn(TAG, `key saved ok=true store=memory (asset unavailable, code=${e.code})`);
      return 'memory';
    }
  }

  /** 读 Key。**返回值只喂给 AiClient 的请求头，调用方不得写日志/落盘。** */
  public static async loadApiKey(): Promise<string> {
    try {
      const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
      query.set(asset.Tag.ALIAS, AiSettingsStore.toBytes(AI_ASSET_ALIAS_API_KEY));
      query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
      const result: Array<asset.AssetMap> = asset.querySync(query);
      for (let i: number = 0; i < result.length; i++) {
        const one: asset.AssetMap = result[i];
        if (one.has(asset.Tag.SECRET)) {
          const secret: asset.Value = one.get(asset.Tag.SECRET) as asset.Value;
          if (secret instanceof Uint8Array) {
            AiSettingsStore.keyAvailable = true;
            return AiSettingsStore.fromBytes(secret as Uint8Array);
          }
        }
      }
      AiSettingsStore.keyAvailable = false;
      return '';
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      if (e.code !== asset.ErrorCode.NOT_FOUND) {
        Logger.error(TAG, `asset query failed, code=${e.code}, msg=${e.message}`);
      }
      return AiSettingsStore.memoryKey;
    }
  }

  /** 删除 Key（Asset + 内存兜底一起清）。 */
  public static async removeApiKey(): Promise<string> {
    AiSettingsStore.memoryKey = '';
    try {
      const attrs: asset.AssetMap = new Map<asset.Tag, asset.Value>();
      attrs.set(asset.Tag.ALIAS, AiSettingsStore.toBytes(AI_ASSET_ALIAS_API_KEY));
      try {
        asset.removeSync(attrs);
      } catch (removeErr) {
        const rmErr: BusinessError = removeErr as BusinessError;
        if (rmErr.code !== asset.ErrorCode.NOT_FOUND) {
          Logger.warn(TAG, `asset remove failed, code=${rmErr.code}`);
        }
      }
      AiSettingsStore.keyAvailable = false;
      Logger.info(TAG, `key removed ok=true`);
      return '';
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.error(TAG, `asset remove failed, code=${e.code}, msg=${e.message}`);
      return 'error';
    }
  }

  /** Key 是否存在（不读取值）。Asset 结论 + 内存兜底。 */
  public static hasApiKey(): boolean {
    return AiSettingsStore.keyAvailable || AiSettingsStore.memoryKey.length > 0;
  }

  private static toBytes(text: string): Uint8Array {
    const encoder: util.TextEncoder = util.TextEncoder.create('utf-8');
    return encoder.encodeInto(text);
  }

  private static fromBytes(bytes: Uint8Array): string {
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
    return decoder.decodeToString(bytes, { stream: false });
  }

  // ------------------------------------------------------------ 偏好（baseURL / model / provider）

  /** 读配置（不含 Key）。盘上没有或数据坏了都返回默认空配置。 */
  public static loadConfig(): AiProviderConfig {
    const store: preferences.Preferences | null = AiSettingsStore.open();
    if (store === null) {
      return new AiProviderConfig();
    }
    try {
      const raw: preferences.ValueType = store.getSync(AI_PREFS_KEY_CONFIG, '');
      if (typeof raw !== 'string' || (raw as string).length === 0) {
        return new AiProviderConfig();
      }
      const parsed: Object = JSON.parse(raw as string);
      const obj: Record<string, Object> = parsed as Record<string, Object>;
      const out: AiProviderConfig = new AiProviderConfig();
      if (typeof obj['provider'] === 'string') {
        out.provider = obj['provider'] as string;
      }
      if (typeof obj['baseUrl'] === 'string') {
        out.baseUrl = obj['baseUrl'] as string;
      }
      if (typeof obj['model'] === 'string') {
        out.model = obj['model'] as string;
      }
      return out;
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.error(TAG, `config load failed, code=${e.code}, msg=${e.message}`);
      return new AiProviderConfig();
    }
  }

  /** 写配置。**入参必须不含 Key**（类型上就装不下；保险起见再整体 JSON 化确认一次）。 */
  public static saveConfig(config: AiProviderConfig): boolean {
    const store: preferences.Preferences | null = AiSettingsStore.open();
    if (store === null) {
      return false;
    }
    const clean: AiProviderConfig = new AiProviderConfig();
    clean.provider = config.provider;
    clean.baseUrl = config.baseUrl.trim();
    clean.model = config.model.trim();
    try {
      store.putSync(AI_PREFS_KEY_CONFIG, JSON.stringify(clean));
      // GSKV 不保证「写完即落盘」（见 BrewSourcePrefs.persistNow 的注释）；设置页低频写，
      // 这里同步 flush 语义靠 removePreferencesFromCacheSync 达成（下次读会重新开句柄）。
      Logger.info(TAG, `config saved provider=${clean.provider} model=${clean.model}`);
      return true;
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.error(TAG, `config save failed, code=${e.code}, msg=${e.message}`);
      return false;
    }
  }

  /** 设置页首屏快照：配置 + Key 存在性。 */
  public static snapshot(): AiSettingsSnapshot {
    const out: AiSettingsSnapshot = new AiSettingsSnapshot();
    out.config = AiSettingsStore.loadConfig();
    out.hasKey = AiSettingsStore.hasApiKey();
    out.keyMemoryOnly = AiSettingsStore.memoryKey.length > 0;
    return out;
  }

  /** 清空全部 AI 设置（含 Key）。 */
  public static async clearAll(): Promise<void> {
    await AiSettingsStore.removeApiKey();
    const store: preferences.Preferences | null = AiSettingsStore.open();
    if (store !== null) {
      try {
        store.deleteSync(AI_PREFS_KEY_CONFIG);
      } catch (err) {
        const e: BusinessError = err as BusinessError;
        Logger.error(TAG, `config delete failed, code=${e.code}`);
      }
    }
    Logger.info(TAG, `settings cleared`);
  }

  private static open(): preferences.Preferences | null {
    if (AiSettingsStore.store !== undefined) {
      return AiSettingsStore.store;
    }
    const uiContext: UIContext | undefined = AppStorage.get<UIContext>(StorageKey.UI_CONTEXT);
    if (uiContext === undefined) {
      return null;
    }
    const ctx: Context | undefined = uiContext.getHostContext();
    if (ctx === undefined) {
      return null;
    }
    try {
      const options: preferences.Options = { name: AI_PREFS_STORE, storageType: preferences.StorageType.GSKV };
      AiSettingsStore.store = preferences.getPreferencesSync(ctx, options);
      return AiSettingsStore.store;
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.error(TAG, `store open failed, code=${e.code}, msg=${e.message}`);
      return null;
    }
  }
}
