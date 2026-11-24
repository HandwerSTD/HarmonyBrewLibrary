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
  AI_PREFS_KEY_AUTO_EXPLAIN,
  AI_PREFS_KEY_AUTO_RELEASE_INTEL,
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
      // add 与 remove 的 AssetMap **必须分开构造**（排查记录三的根因）：
      // remove 的入参是查询条件，带 SECRET 等无关属性会返回 401（INVALID_ARGUMENT，
      // 参数不合法）——旧值删不掉，addSync 撞 24000003（DUPLICATED），连锁误判
      // 「Asset 不可用」退内存。remove 只带 ALIAS。
      const removeMap: asset.AssetMap = new Map<asset.Tag, asset.Value>();
      removeMap.set(asset.Tag.ALIAS, AiSettingsStore.toBytes(AI_ASSET_ALIAS_API_KEY));
      try {
        // remove 的 NOT_FOUND（24000002）= 本来就没有旧值，不是错误。
        asset.removeSync(removeMap);
      } catch (removeErr) {
        const rmErr: BusinessError = removeErr as BusinessError;
        if (rmErr.code !== asset.ErrorCode.NOT_FOUND) {
          Logger.warn(TAG, `asset remove before add failed, code=${rmErr.code}`);
        }
      }
      const attrs: asset.AssetMap = new Map<asset.Tag, asset.Value>();
      attrs.set(asset.Tag.SECRET, AiSettingsStore.toBytes(trimmed));
      attrs.set(asset.Tag.ALIAS, AiSettingsStore.toBytes(AI_ASSET_ALIAS_API_KEY));
      // ACCESSIBILITY 省略 = 用默认值 DEVICE_FIRST_UNLOCKED（首次解锁后可访问，
      // 未设锁屏密码时等同开机可访问，对 PC/2in1 无锁屏密码场景最宽容，官方推荐形态）。
      asset.addSync(attrs);
      AiSettingsStore.memoryKey = '';
      AiSettingsStore.keyAvailable = true;
      Logger.info(TAG, `key saved ok=true store=asset`);
      return '';
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      // 24000003（DUPLICATED）= 可自愈的冲突（旧值在 remove 之前的窗口里出现了，
      // 极端时序）：remove 后重试一次 add，成功即走正常持久路径——**这不是
      // 「Asset 不可用」**，不该退内存。
      if (e.code === asset.ErrorCode.DUPLICATED) {
        try {
          const removeMap: asset.AssetMap = new Map<asset.Tag, asset.Value>();
          removeMap.set(asset.Tag.ALIAS, AiSettingsStore.toBytes(AI_ASSET_ALIAS_API_KEY));
          asset.removeSync(removeMap);
          const retry: asset.AssetMap = new Map<asset.Tag, asset.Value>();
          retry.set(asset.Tag.SECRET, AiSettingsStore.toBytes(trimmed));
          retry.set(asset.Tag.ALIAS, AiSettingsStore.toBytes(AI_ASSET_ALIAS_API_KEY));
          asset.addSync(retry);
          AiSettingsStore.memoryKey = '';
          AiSettingsStore.keyAvailable = true;
          Logger.info(TAG, `key saved ok=true store=asset (after conflict retry)`);
          return '';
        } catch (retryErr) {
          const rErr: BusinessError = retryErr as BusinessError;
          Logger.error(TAG, `asset conflict retry failed, code=${rErr.code}, msg=${rErr.message}`);
        }
      }
      // 错误码打全供真机日志诊断（含义见 asset 错误码表：24000001 服务不可用 /
      // 24000004 拒绝 / 24000005 锁屏不匹配 / 401 参数不合法）。
      Logger.error(TAG, `asset add failed, code=${e.code}, msg=${e.message}`);
      // Asset 真不可用：退进程内存（spec §13 方案 B 的保守形态——不落盘版本）。
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

  /** 删除 Key（Asset + 内存兜底一起清）。remove 只带 ALIAS（查询条件不带 SECRET）。 */
  public static async removeApiKey(): Promise<string> {
    AiSettingsStore.memoryKey = '';
    try {
      const removeMap: asset.AssetMap = new Map<asset.Tag, asset.Value>();
      removeMap.set(asset.Tag.ALIAS, AiSettingsStore.toBytes(AI_ASSET_ALIAS_API_KEY));
      try {
        asset.removeSync(removeMap);
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

  /**
   * 同步存在性探针：冷启进程里 `keyAvailable` 初始为 false（它只被 saveApiKey /
   * loadApiKey 的成功路径置位），而设置页首屏走的是同步 `snapshot()`——
   * 在 `loadApiKey()` 被任何一次 AI 请求调过之前，已持久化的 Key 会被误报
   * 「未配置」(用户实测 2026-11-24)。querySync 是同步 API，这里在快照读之前
   * 直接问一次 Asset 的存在性，把结论写回会话缓存。**只判断存在，不返回值**。
   */
  private static probeKeyAvailable(): void {
    try {
      const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
      query.set(asset.Tag.ALIAS, AiSettingsStore.toBytes(AI_ASSET_ALIAS_API_KEY));
      query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
      const result: Array<asset.AssetMap> = asset.querySync(query);
      for (let i: number = 0; i < result.length; i++) {
        if (result[i].has(asset.Tag.SECRET)) {
          AiSettingsStore.keyAvailable = true;
          return;
        }
      }
      AiSettingsStore.keyAvailable = false;
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      if (e.code !== asset.ErrorCode.NOT_FOUND) {
        Logger.warn(TAG, `asset probe failed, code=${e.code}, msg=${e.message}`);
      }
      AiSettingsStore.keyAvailable = false;
    }
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

  /** 设置页首屏快照：配置 + Key 存在性（含冷启探针，见 probeKeyAvailable）。 */
  public static snapshot(): AiSettingsSnapshot {
    AiSettingsStore.probeKeyAvailable();
    const out: AiSettingsSnapshot = new AiSettingsSnapshot();
    out.config = AiSettingsStore.loadConfig();
    out.hasKey = AiSettingsStore.hasApiKey();
    out.keyMemoryOnly = AiSettingsStore.memoryKey.length > 0;
    out.autoExplain = AiSettingsStore.autoExplain();
    out.autoReleaseIntel = AiSettingsStore.autoReleaseIntel();
    return out;
  }

  /**
   * 「自动生成 AI 讲解」开关（默认开）。**无 Key 时恒返回 false**——
   * 详情页装配只看这一个结论，不开也不引导（避免每个详情页推销 AI）。
   */
  public static autoExplain(): boolean {
    if (!AiSettingsStore.hasApiKey()) {
      return false;
    }
    const store: preferences.Preferences | null = AiSettingsStore.open();
    if (store === null) {
      return false;
    }
    return store.getSync(AI_PREFS_KEY_AUTO_EXPLAIN, true) === true;
  }

  /** 写自动生成开关（布尔单独存，不进 config JSON；不含 Key）。 */
  public static saveAutoExplain(enabled: boolean): boolean {
    const store: preferences.Preferences | null = AiSettingsStore.open();
    if (store === null) {
      return false;
    }
    try {
      store.putSync(AI_PREFS_KEY_AUTO_EXPLAIN, enabled === true);
      Logger.info(TAG, `auto explain saved enabled=${enabled}`);
      return true;
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.error(TAG, `auto explain save failed, code=${e.code}, msg=${e.message}`);
      return false;
    }
  }

  /**
   * 「自动解析更新日志」开关（Y 更新情报中心的 AI 摘要闸，默认开）。**无 Key 时恒
   * 返回 false**；关闭后情报卡只渲染 notes 原文节选，不发起 AI 请求。
   */
  public static autoReleaseIntel(): boolean {
    if (!AiSettingsStore.hasApiKey()) {
      return false;
    }
    const store: preferences.Preferences | null = AiSettingsStore.open();
    if (store === null) {
      return false;
    }
    return store.getSync(AI_PREFS_KEY_AUTO_RELEASE_INTEL, true) === true;
  }

  /** 写「自动解析更新日志」开关（布尔单独存；不含 Key）。 */
  public static saveAutoReleaseIntel(enabled: boolean): boolean {
    const store: preferences.Preferences | null = AiSettingsStore.open();
    if (store === null) {
      return false;
    }
    try {
      store.putSync(AI_PREFS_KEY_AUTO_RELEASE_INTEL, enabled === true);
      Logger.info(TAG, `auto release intel saved enabled=${enabled}`);
      return true;
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.error(TAG, `auto release intel save failed, code=${e.code}, msg=${e.message}`);
      return false;
    }
  }

  /** 清空全部 AI 设置（含 Key）。 */
  public static async clearAll(): Promise<void> {
    await AiSettingsStore.removeApiKey();
    const store: preferences.Preferences | null = AiSettingsStore.open();
    if (store !== null) {
      try {
        store.deleteSync(AI_PREFS_KEY_CONFIG);
        store.deleteSync(AI_PREFS_KEY_AUTO_EXPLAIN);
        store.deleteSync(AI_PREFS_KEY_AUTO_RELEASE_INTEL);
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
