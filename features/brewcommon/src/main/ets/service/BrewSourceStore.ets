/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { Logger, PreferenceManager, StorageKey } from '@ohos/common';
import {
  BREW_DIALECT_HARMONYBREW,
  BREW_DIALECT_UPSTREAM,
  BREW_HARMONYBREW_BASE_URL,
  BREW_HARMONYBREW_DEFAULT_TAG,
  BREW_HARMONYBREW_SOURCE_ID,
  BREW_OFFICIAL_BASE_URL,
  BREW_OFFICIAL_SOURCE_ID,
  BREW_SOURCE_HEALTH_KEY,
  BREW_SOURCE_MAX_NAME_LEN,
  BREW_SOURCE_REGISTRY_KEY,
} from '../constant/BrewSourceConstants';
import {
  BrewSource,
  BrewSourceHealth,
  BrewSourceHealthRecord,
  BrewSourceReach,
  BrewSourceRegistry,
} from '../model/BrewSourceModels';
import { BrewSourceUrl, BrewSourceUrlCheck } from './BrewSourceUrl';

const TAG: string = '[BrewSource]';

/**
 * 源注册表 + 会话快照 + 健康记录。
 *
 * ## 为什么会话快照是「必须重启」的实现落点
 *
 * `sessionActive()` 在进程内**只读一次并冻结**。之后 `setActiveId()` 写进盘里对当前进程
 * **零影响** —— 所有 URL 与 store 名都取快照。于是：
 *   - 「切换源必须重启」不是靠约定，而是靠结构保证；
 *   - 不存在「已切换但还在跑旧源」或「新旧源缓存混杂」的中间态。
 *
 * ## 为什么注册表放主 store 而不是每源一个 store
 *
 * 注册表是**跨源**的、只有几百字节。给它单开一个 store 只会多一个文件、多一次加载，
 * 换不来任何隔离收益。
 */
export class BrewSourceStore {
  private static registry: BrewSourceRegistry | undefined = undefined;
  private static session: BrewSource | undefined = undefined;
  private static health: Record<string, BrewSourceHealthRecord> | undefined = undefined;

  /**
   * 内置 Harmonybrew 源在本产品上是否启用。
   *
   * 由 entry 的 UIAbility 在 `onCreate` 写入 `StorageKey.BREW_HARMONYBREW_SOURCE_ENABLED`：
   * pc_acl 注入 true、pc_normal 注入 false；未注入时按 false 处理。
   *
   * 注册表里它**恒存在**（两个产品形状一致），这里只决定它是否可选可用、是否上屏。
   * `normalizeRegistry` 与设置页都读这一个入口，不走两套判定。
   */
  public static harmonybrewBuiltinEnabled(): boolean {
    return AppStorage.get<boolean>(StorageKey.BREW_HARMONYBREW_SOURCE_ENABLED) ?? false;
  }

  /** 该地址是否属于内置源（内置源的地址不能另立一个自定义源指向它） */
  public static isReservedBuiltinUrl(baseUrl: string): boolean {
    return BrewSourceUrl.normalize(baseUrl) === BREW_HARMONYBREW_BASE_URL;
  }

  /** 本产品是否展示这一条源。目前只有内置 Harmonybrew 源是有条件的 */
  public static isVisible(id: string): boolean {
    if (id !== BREW_HARMONYBREW_SOURCE_ID) {
      return true;
    }
    return BrewSourceStore.harmonybrewBuiltinEnabled();
  }

  // ------------------------------------------------------------ 读

  public static listSources(): BrewSource[] {
    return BrewSourceStore.ensureRegistry().sources;
  }

  public static activeId(): string {
    return BrewSourceStore.ensureRegistry().activeId;
  }

  /** 本会话冻结的 active 源。**唯一权威** —— URL 与 store 名都取它 */
  public static sessionActive(): BrewSource {
    if (BrewSourceStore.session === undefined) {
      const registry: BrewSourceRegistry = BrewSourceStore.ensureRegistry();
      let found: BrewSource | undefined = BrewSourceStore.findInList(registry.sources, registry.activeId);
      if (found === undefined) {
        found = BrewSourceStore.officialOf(registry.sources);
      }
      BrewSourceStore.session = found;
      Logger.info(TAG, `session active frozen, id=${found.id}, base=${found.baseUrl}`);
    }
    return BrewSourceStore.session;
  }

  public static activeBaseUrl(): string {
    return BrewSourceStore.sessionActive().baseUrl;
  }

  /** 返回指定源在本会话快照中的方言。运行期取数只认已冻结的会话源。 */
  public static dialectOf(sourceId: string): string {
    const active: BrewSource = BrewSourceStore.sessionActive();
    return active.id === sourceId ? active.dialect : BREW_DIALECT_UPSTREAM;
  }

  /**
   * 写回一次成功探测识别出的源身份。
   *
   * 按源 id 定位，不能按 baseUrl：同名地址的源必须各自持有自己的方言与 bottle tag。
   * dialect 为空表示本次探测没有可用信息，保留盘上原值；tag 允许为空，用于上游源显式清掉
   * 旧 tag。只有至少一个字段真的变化时才落盘。
   */
  public static updateProbeIdentity(id: string, dialect: string, tag: string): void {
    const registry: BrewSourceRegistry = BrewSourceStore.ensureRegistry();
    const source: BrewSource | undefined = BrewSourceStore.findInList(registry.sources, id);
    if (source === undefined) {
      return;
    }
    const dialectChanged: boolean = dialect.length > 0 && source.dialect !== dialect;
    const tagChanged: boolean = source.tag !== tag;
    if (!dialectChanged && !tagChanged) {
      return;
    }
    if (dialectChanged) {
      source.dialect = dialect;
    }
    if (tagChanged) {
      source.tag = tag;
    }
    BrewSourceStore.persistRegistry(registry);
    Logger.info(TAG, `probe identity updated, id=${id}, dialect=${source.dialect}, tag=${source.tag}`);
  }

  public static find(id: string): BrewSource | undefined {
    return BrewSourceStore.findInList(BrewSourceStore.listSources(), id);
  }

  // ------------------------------------------------------------ 写

  /** 只写注册表。**不影响当前进程**（见类注释），重启后生效 */
  public static setActiveId(id: string): boolean {
    const registry: BrewSourceRegistry = BrewSourceStore.ensureRegistry();
    if (BrewSourceStore.findInList(registry.sources, id) === undefined) {
      Logger.error(TAG, `setActiveId rejected, unknown id=${id}`);
      return false;
    }
    // 不可用的内置源不能被写成 active：用户看不到它，也没有退回去的入口
    if (!BrewSourceStore.isVisible(id)) {
      Logger.error(TAG, `setActiveId rejected, source not available on this product, id=${id}`);
      return false;
    }
    registry.activeId = id;
    BrewSourceStore.persistRegistry(registry);
    Logger.info(TAG, `activeId written, id=${id} (生效需重启；本会话仍用 ${BrewSourceStore.sessionActive().id})`);
    return true;
  }

  public static addSource(name: string, baseUrl: string): BrewSource | undefined {
    const check: BrewSourceUrlCheck = BrewSourceUrl.check(baseUrl);
    if (!check.ok) {
      Logger.error(TAG, `addSource rejected, url reason=${check.reason}, raw=${baseUrl}`);
      return undefined;
    }
    if (name.trim().length === 0 || name.trim().length > BREW_SOURCE_MAX_NAME_LEN) {
      Logger.error(TAG, `addSource rejected, bad name length=${name.trim().length}`);
      return undefined;
    }
    // 内置源的地址不能再作为自定义源加一遍：同一个地址会出现两条卡片，
    // 而它们各自持有独立缓存，用户看到的是「同一份数据两个进度」。
    if (BrewSourceStore.isReservedBuiltinUrl(check.normalized)) {
      Logger.error(TAG, `addSource rejected, reserved builtin url=${check.normalized}`);
      return undefined;
    }
    const registry: BrewSourceRegistry = BrewSourceStore.ensureRegistry();
    const source: BrewSource = new BrewSource(BrewSourceStore.newId(), name.trim(), check.normalized, false,
      Date.now(), BREW_DIALECT_UPSTREAM);
    registry.sources.push(source);
    BrewSourceStore.persistRegistry(registry);
    Logger.info(TAG, `source added, id=${source.id}, name=${source.name}, base=${source.baseUrl}`);
    return source;
  }

  /** 改名与改 URL。返回 `baseUrlChanged` 供调用方决定是否清缓存 */
  public static updateSource(id: string, name: string, baseUrl: string): BrewSourceUpdateResult {
    const result: BrewSourceUpdateResult = new BrewSourceUpdateResult(false, false);
    const registry: BrewSourceRegistry = BrewSourceStore.ensureRegistry();
    const source: BrewSource | undefined = BrewSourceStore.findInList(registry.sources, id);
    if (source === undefined) {
      return result;
    }
    const trimmedName: string = name.trim();
    if (trimmedName.length === 0 || trimmedName.length > BREW_SOURCE_MAX_NAME_LEN) {
      return result;
    }
    if (source.builtin) {
      // 内置源只允许改名，不允许改 URL（官方源与内置 Harmonybrew 源同此规则）
      source.name = trimmedName;
      BrewSourceStore.persistRegistry(registry);
      result.ok = true;
      return result;
    }
    const check: BrewSourceUrlCheck = BrewSourceUrl.check(baseUrl);
    if (!check.ok) {
      return result;
    }
    // 与 `addSource` 同一条拒绝：否则「先加一个无关地址、再改成本内置地址」
    // 就能绕开新增时的限制。
    if (BrewSourceStore.isReservedBuiltinUrl(check.normalized)) {
      Logger.error(TAG, `updateSource rejected, reserved builtin url=${check.normalized}, id=${id}`);
      return result;
    }
    source.name = trimmedName;
    result.baseUrlChanged = source.baseUrl !== check.normalized;
    source.baseUrl = check.normalized;
    BrewSourceStore.persistRegistry(registry);
    result.ok = true;
    Logger.info(TAG, `source updated, id=${id}, baseUrlChanged=${result.baseUrlChanged}`);
    return result;
  }

  public static removeSource(id: string): boolean {
    const registry: BrewSourceRegistry = BrewSourceStore.ensureRegistry();
    const source: BrewSource | undefined = BrewSourceStore.findInList(registry.sources, id);
    if (source === undefined) {
      return false;
    }
    if (source.builtin) {
      Logger.error(TAG, `removeSource rejected, builtin id=${id}`);
      return false;
    }
    if (id === BrewSourceStore.sessionActive().id) {
      // 删激活源会让本进程的 store 句柄悬空；而「切走」本身就是重启，重启后再删即可
      Logger.error(TAG, `removeSource rejected, id=${id} is the session active source`);
      return false;
    }
    const kept: BrewSource[] = registry.sources.filter((one: BrewSource) => one.id !== id);
    registry.sources = kept;
    BrewSourceStore.persistRegistry(registry);
    Logger.info(TAG, `source removed, id=${id}, left=${kept.length}`);
    return true;
  }

  // ------------------------------------------------------------ 健康记录

  public static healthOf(id: string): BrewSourceHealthRecord {
    const all: Record<string, BrewSourceHealthRecord> = BrewSourceStore.ensureHealth();
    let one: BrewSourceHealthRecord | undefined = all[id];
    if (one === undefined) {
      one = new BrewSourceHealthRecord();
      all[id] = one;
    }
    return one;
  }

  /**
   * 记录一次探测结果。**这是连通性轴唯一的写入点**。
   *
   * 除了「测试连接」，激活路径也会调它（激活前必须先确认地址可用）；两处口径相同，
   * 所以「测试连接说可用」与列表上的连通性结论不会互相矛盾。
   */
  public static noteProbe(id: string, ok: boolean, reason: string): void {
    const one: BrewSourceHealthRecord = BrewSourceStore.healthOf(id);
    one.lastProbeOk = ok;
    one.lastProbeReason = reason;
    one.lastProbeAt = Date.now();
    BrewSourceStore.persistHealth();
  }

  /**
   * 记录一个「当前站着」的错误。**纯诊断，不参与 `healthState` 判定**。
   *
   * `kind` **只接受** `vol` / `desc`（包表的两个分片）。其它 kind 一律拒绝并打 warn ——
   * 错误按片分槽，一个无关 kind 会占错槽位，让用户看到一片明明正常的提示。
   * 探测的结果不走这里，它由 `noteProbe` 单独表达。
   */
  public static noteError(id: string, kind: string, message: string): void {
    if (kind !== 'vol' && kind !== 'desc') {
      Logger.warn(TAG, `noteError ignored, kind=${kind} 不在词表内（vol/desc）, id=${id}`);
      return;
    }
    const one: BrewSourceHealthRecord = BrewSourceStore.healthOf(id);
    const at: number = Date.now();
    if (kind === 'vol') {
      one.volError = 'vol';
      one.volErrorMessage = message;
      one.volErrorAt = at;
    } else {
      one.descError = 'desc';
      one.descErrorMessage = message;
      one.descErrorAt = at;
    }
    BrewSourceStore.persistHealth();
    Logger.info(TAG, `shard error noted, id=${id}, kind=${kind}, ${message}`);
  }

  /**
   * 安装量片取数**成功**。
   *
   * 成功时必须**清掉本片的错误槽** —— 它表达的是「当前站着什么错误」，
   * 而不是「历史上出错过」。
   */
  public static noteVolOk(id: string): void {
    const one: BrewSourceHealthRecord = BrewSourceStore.healthOf(id);
    const hadError: boolean = one.volError.length > 0;
    one.volReadyAt = Date.now();
    one.volError = '';
    one.volErrorMessage = '';
    one.volErrorAt = 0;
    BrewSourceStore.persistHealth();
    Logger.info(TAG, `vol shard ok noted, id=${id}${hadError ? '（清掉了上一个错误槽）' : ''}`);
  }

  /** 描述片取数**成功**。与 `noteVolOk` 对称 */
  public static noteDescOk(id: string): void {
    const one: BrewSourceHealthRecord = BrewSourceStore.healthOf(id);
    const hadError: boolean = one.descError.length > 0;
    one.descReadyAt = Date.now();
    one.descError = '';
    one.descErrorMessage = '';
    one.descErrorAt = 0;
    BrewSourceStore.persistHealth();
    Logger.info(TAG, `desc shard ok noted, id=${id}${hadError ? '（清掉了上一个错误槽）' : ''}`);
  }

  /**
   * 状态判定（**数据轴**）：只读运行期取数记录，**绝不看 `lastProbe*`**。
   *
   * 两片都成功过 → `OK`；其余一律 `NOT_READY`。
   * 部分成功不单设状态（见 `BrewSourceHealth` 的注释）。
   *
   * 数据轴**不做预探测**：它只说明「至今为止两片各自的实际取数结果」。
   */
  public static healthState(id: string): BrewSourceHealth {
    const one: BrewSourceHealthRecord = BrewSourceStore.healthOf(id);
    return one.volReadyAt > 0 && one.descReadyAt > 0 ? BrewSourceHealth.OK : BrewSourceHealth.NOT_READY;
  }

  /**
   * 当前站着的分片错误（`''` 表示没有）。设置页拿它决定要不要给 warning 色与说明文字。
   *
   * 这是诊断，不影响状态：一个曾经失败过、现在早已恢复的源，它的槽已被成功写入清空，
   * 所以这里返回 `''`。
   */
  public static standingError(id: string): string {
    const one: BrewSourceHealthRecord = BrewSourceStore.healthOf(id);
    return one.volError.length > 0 ? 'vol' : (one.descError.length > 0 ? 'desc' : '');
  }

  /**
   * 状态判定（**连通性轴**）：「测试连接」唯一该表达的结论。
   *
   * 只看探测记录。**不看任何取数记录** —— 数据没下载完不代表地址不通，
   * 地址通也不代表数据下载完了（后一个由 `healthState` 回答）。
   */
  public static reachState(id: string): BrewSourceReach {
    const one: BrewSourceHealthRecord = BrewSourceStore.healthOf(id);
    if (one.lastProbeAt === 0) {
      return BrewSourceReach.UNKNOWN;
    }
    return one.lastProbeOk ? BrewSourceReach.OK : BrewSourceReach.FAILING;
  }

  /**
   * 作废某源的**数据轴**记录（清空缓存 / 改地址后调）。
   *
   * 为什么必须做：这些字段是「上一份数据的取数结论」。缓存被清掉后，
   * `volReadyAt` / `descReadyAt` 已经不成立、错误槽也是旧数据的错误，
   * 不重置就会出现「清空缓存了，列表还写着部分可用」这种自相矛盾的状态。
   *
   * ⚠ **探测记录（`lastProbe*`）故意保留**：它描述的是远端地址能不能应答，
   * 与本地缓存无关 —— 清缓存不该把「刚测过、地址是通的」结论一并抹掉。
   */
  public static resetDataHealth(id: string): void {
    const all: Record<string, BrewSourceHealthRecord> = BrewSourceStore.ensureHealth();
    const one: BrewSourceHealthRecord | undefined = all[id];
    if (one === undefined) {
      return;
    }
    one.volReadyAt = 0;
    one.descReadyAt = 0;
    one.volError = '';
    one.volErrorMessage = '';
    one.volErrorAt = 0;
    one.descError = '';
    one.descErrorMessage = '';
    one.descErrorAt = 0;
    BrewSourceStore.persistHealth();
    Logger.info(TAG, `data health reset, id=${id}`);
  }

  // ------------------------------------------------------------ 内部

  private static findInList(sources: BrewSource[], id: string): BrewSource | undefined {
    for (let i: number = 0; i < sources.length; i++) {
      if (sources[i].id === id) {
        return sources[i];
      }
    }
    return undefined;
  }

  private static officialOf(sources: BrewSource[]): BrewSource {
    const found: BrewSource | undefined = BrewSourceStore.findInList(sources, BREW_OFFICIAL_SOURCE_ID);
    return found !== undefined ? found : BrewSourceStore.newOfficial();
  }

  private static newOfficial(): BrewSource {
    return new BrewSource(BREW_OFFICIAL_SOURCE_ID, 'Official', BREW_OFFICIAL_BASE_URL, true, 0,
      BREW_DIALECT_UPSTREAM);
  }

  /**
   * 内置 Harmonybrew 源的初值。
   *
   * `tag` 给默认值是因为它必须有值才能取数（`HarmonybrewAdapter` 拿它拼目录路径），
   * 而探测会在第一次「测试连接 / 激活」时把响应里的真实 tag 写回来。
   */
  private static newBuiltinHarmonybrew(): BrewSource {
    return new BrewSource(BREW_HARMONYBREW_SOURCE_ID, 'Harmonybrew', BREW_HARMONYBREW_BASE_URL, true, 0,
      BREW_DIALECT_HARMONYBREW, BREW_HARMONYBREW_DEFAULT_TAG);
  }

  private static newId(): string {
    const rand: number = Math.floor(Math.random() * 1000000);
    return `src_${Date.now()}_${rand}`;
  }

  private static ensureRegistry(): BrewSourceRegistry {
    if (BrewSourceStore.registry === undefined) {
      const stored: BrewSourceRegistry | null =
        PreferenceManager.getInstance().getValue<BrewSourceRegistry>(BREW_SOURCE_REGISTRY_KEY);
      const needsDialectMigration: boolean = BrewSourceStore.hasMissingDialect(stored);
      const normalized: BrewSourceRegistry = BrewSourceStore.normalizeRegistry(stored);
      BrewSourceStore.registry = normalized;
      Logger.info(TAG, `registry loaded, n=${normalized.sources.length}, active=${normalized.activeId}`);
      // 自愈结果必须落盘（spec §4：「回落并落盘」）。不落的话盘上一直是损坏值，
      // 每次启动都重复自愈一遍，且日志里每次都会出现同样的 warn —— 看起来像反复出问题。
      if (BrewSourceStore.isDegenerate(stored, normalized) || needsDialectMigration) {
        BrewSourceStore.persistRegistry(normalized);
        Logger.warn(TAG, 'registry self-healed and persisted');
      }
    }
    return BrewSourceStore.registry;
  }

  /**
   * 盘上的注册表是否需要自愈（用于决定要不要回写）。
   *
   * 只比较**结构性**事实（official 是否缺失 / 是否被改、`activeId` 是否命中），
   * 不比较数组引用或字段顺序 —— 否则每次启动都会回写一次。
   */
  private static hasMissingDialect(stored: BrewSourceRegistry | null): boolean {
    if (stored === null || stored === undefined || stored.sources === undefined) {
      return true;
    }
    for (let i: number = 0; i < stored.sources.length; i++) {
      const source: BrewSource = stored.sources[i];
      if (source === undefined || source === null || source.dialect === undefined ||
        source.dialect.length === 0) {
        return true;
      }
    }
    return false;
  }

  private static isDegenerate(stored: BrewSourceRegistry | null,
    normalized: BrewSourceRegistry): boolean {
    if (stored === null || stored === undefined || stored.sources === undefined) {
      return true;
    }
    const storedOfficial: BrewSource | undefined =
      BrewSourceStore.findInList(stored.sources, BREW_OFFICIAL_SOURCE_ID);
    if (storedOfficial === undefined) {
      return true;
    }
    if (storedOfficial.builtin !== true || storedOfficial.baseUrl !== BREW_OFFICIAL_BASE_URL) {
      return true;
    }
    if (storedOfficial !== normalized.sources[0]) {
      return true;
    }
    const storedHarmonybrew: BrewSource | undefined =
      BrewSourceStore.findInList(stored.sources, BREW_HARMONYBREW_SOURCE_ID);
    if (storedHarmonybrew === undefined || storedHarmonybrew.builtin !== true ||
      storedHarmonybrew.baseUrl !== BREW_HARMONYBREW_BASE_URL ||
      storedHarmonybrew !== normalized.sources[1]) {
      return true;
    }
    return stored.activeId !== normalized.activeId;
  }

  /**
   * 不变量（每条越界都自愈 + 打日志）：
   *   1. 恒存在且仅存在一条 official，`builtin=true`、`baseUrl` 为官方地址；
   *   2. 恒存在且仅存在一条内置 Harmonybrew 源（id `harmonybrew`、`builtin=true`、`baseUrl` 固定），
   *      它的**可用与展示**由 `harmonybrewBuiltinEnabled()` 决定；
   *   3. official 恒为 `sources[0]`、内置 Harmonybrew 源恒为 `sources[1]`；
   *   4. `activeId` 必须命中；不命中回落 official，命中内置 Harmonybrew 源但本产品未启用它也回落 official；
   *   5. 同时只有一条 active（由 `activeId` 单值天然保证）。
   */
  private static normalizeRegistry(stored: BrewSourceRegistry | null): BrewSourceRegistry {
    const sources: BrewSource[] = stored !== null && stored.sources !== undefined ? stored.sources : [];
    const cleaned: BrewSource[] = sources.filter((one: BrewSource) =>
      one !== undefined && one !== null && one.id !== BREW_OFFICIAL_SOURCE_ID &&
        one.id !== BREW_HARMONYBREW_SOURCE_ID && one.id !== undefined);
    let official: BrewSource | undefined = BrewSourceStore.findInList(sources, BREW_OFFICIAL_SOURCE_ID);
    if (official === undefined) {
      Logger.warn(TAG, 'official missing, recreated');
      official = BrewSourceStore.newOfficial();
    } else {
      official.builtin = true;
      official.baseUrl = BREW_OFFICIAL_BASE_URL;
    }
    official.dialect = BREW_DIALECT_UPSTREAM;
    official.tag = '';
    // 内置 Harmonybrew 源同理：baseUrl 与 dialect 恒定（地址本身决定了方言），
    // 只有 `tag` 与显示名保留盘上的值 —— 前者由探测写回，后者允许用户改名。
    let harmonybrew: BrewSource | undefined =
      BrewSourceStore.findInList(sources, BREW_HARMONYBREW_SOURCE_ID);
    if (harmonybrew === undefined) {
      Logger.warn(TAG, 'builtin harmonybrew missing, recreated');
      harmonybrew = BrewSourceStore.newBuiltinHarmonybrew();
    } else {
      harmonybrew.builtin = true;
      harmonybrew.baseUrl = BREW_HARMONYBREW_BASE_URL;
      harmonybrew.dialect = BREW_DIALECT_HARMONYBREW;
      if (harmonybrew.tag === undefined || harmonybrew.tag.length === 0) {
        harmonybrew.tag = BREW_HARMONYBREW_DEFAULT_TAG;
      }
      if (harmonybrew.name === undefined || harmonybrew.name.trim().length === 0) {
        harmonybrew.name = 'Harmonybrew';
      }
    }
    const next: BrewSource[] = [official, harmonybrew];
    cleaned.forEach((one: BrewSource) => {
      if (one.dialect === undefined || one.dialect.length === 0) {
        one.dialect = BREW_DIALECT_UPSTREAM;
      }
      if (one.tag === undefined) {
        one.tag = '';
      }
      next.push(one);
    });
    let activeId: string = stored !== null && stored.activeId !== undefined ? stored.activeId : '';
    if (BrewSourceStore.findInList(next, activeId) === undefined) {
      Logger.warn(TAG, `activeId=${activeId} not found, fallback to official`);
      activeId = BREW_OFFICIAL_SOURCE_ID;
    } else if (activeId === BREW_HARMONYBREW_SOURCE_ID && !BrewSourceStore.harmonybrewBuiltinEnabled()) {
      // 本产品不提供这个源，把它当 active 等于把 App 切到一个用户看不到、也退不回来的源上
      Logger.warn(TAG, 'activeId=harmonybrew but builtin harmonybrew disabled, fallback to official');
      activeId = BREW_OFFICIAL_SOURCE_ID;
    }
    return new BrewSourceRegistry(next, activeId);
  }

  private static persistRegistry(registry: BrewSourceRegistry): void {
    BrewSourceStore.registry = registry;
    PreferenceManager.getInstance().setValue<BrewSourceRegistry>(BREW_SOURCE_REGISTRY_KEY, registry);
  }

  private static ensureHealth(): Record<string, BrewSourceHealthRecord> {
    if (BrewSourceStore.health === undefined) {
      const stored: Record<string, BrewSourceHealthRecord> | null =
        PreferenceManager.getInstance().getValue<Record<string, BrewSourceHealthRecord>>(BREW_SOURCE_HEALTH_KEY);
      BrewSourceStore.health = stored ?? {};
    }
    return BrewSourceStore.health;
  }

  private static persistHealth(): void {
    if (BrewSourceStore.health !== undefined) {
      PreferenceManager.getInstance().setValue<Record<string, BrewSourceHealthRecord>>(
        BREW_SOURCE_HEALTH_KEY, BrewSourceStore.health);
    }
  }
}

/** `updateSource` 的结果：`baseUrlChanged` 决定调用方是否要清该源缓存 */
export class BrewSourceUpdateResult {
  public ok: boolean;
  public baseUrlChanged: boolean;

  public constructor(ok: boolean, baseUrlChanged: boolean) {
    this.ok = ok;
    this.baseUrlChanged = baseUrlChanged;
  }
}
