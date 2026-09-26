/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { Logger, PreferenceManager } from '@ohos/common';
import {
  BREW_DIALECT_UPSTREAM,
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
      // 官方源只允许改名，不允许改 URL
      source.name = trimmedName;
      BrewSourceStore.persistRegistry(registry);
      result.ok = true;
      return result;
    }
    const check: BrewSourceUrlCheck = BrewSourceUrl.check(baseUrl);
    if (!check.ok) {
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
   * 记录一个「当前站着」的错误。
   *
   * `kind` **只接受** `catalog` / `meta` / `hydrate`（spec §9.5 的三个运行期写入点）。
   * 其它 kind 一律拒绝并打 warn —— 因为本字段是**单槽**语义（`healthState` 只看
   * `lastErrorKind` 是哪一种），任何无关 kind 都会冲掉「当前站着的是哪个错误」。
   * 探测的结果不走这里，它由 `noteProbe` 单独表达；而两者现在分属两个正交维度，
   * 不再参与同一个状态判定（见 `healthState` / `reachState`）。
   */
  public static noteError(id: string, kind: string, message: string): void {
    if (kind !== 'catalog' && kind !== 'meta' && kind !== 'hydrate') {
      Logger.warn(TAG, `noteError ignored, kind=${kind} 不在词表内（catalog/meta/hydrate）, id=${id}`);
      return;
    }
    const one: BrewSourceHealthRecord = BrewSourceStore.healthOf(id);
    one.lastErrorKind = kind;
    one.lastErrorMessage = message;
    one.lastErrorAt = Date.now();
    BrewSourceStore.persistHealth();
  }

  /**
   * 目录（聚合端点）**取数成功**。
   *
   * 成功时必须**主动清掉同类错误**：`lastErrorKind` 表达的是「当前站着什么错误」，
   * 而不是「历史上出过错」。靠时间戳先后去推「错误是否被后续成功覆盖」在时钟分辨率内必然失效
   * （真机自检实测：同一毫秒内的成功 + 失败让 `PARTIAL` 被判成 `OK`）。
   */
  public static noteCatalogOk(id: string): void {
    const one: BrewSourceHealthRecord = BrewSourceStore.healthOf(id);
    one.catalogOkAt = Date.now();
    if (one.lastErrorKind === 'catalog') {
      one.lastErrorKind = '';
      one.lastErrorMessage = '';
    }
    BrewSourceStore.persistHealth();
    Logger.info(TAG, `catalog ok noted, id=${id}`);
  }

  /**
   * 元数据索引（全量包）**同步成功**。与 `noteCatalogOk` 对称。
   *
   * `tokens` 是当前索引里的条目数（formula + cask），只用于日志与后续展示；
   * 「是否仍然可用」靠的是清掉同类错误，不是比较时间戳（见 `healthState` 注释）。
   */
  public static noteMetaOk(id: string, tokens: number): void {
    const one: BrewSourceHealthRecord = BrewSourceStore.healthOf(id);
    one.metaIndexTokensAt = Date.now();
    if (one.lastErrorKind === 'meta') {
      one.lastErrorKind = '';
      one.lastErrorMessage = '';
    }
    BrewSourceStore.persistHealth();
    Logger.info(TAG, `meta ok noted, id=${id}, tokens=${tokens}`);
  }

  /**
   * 状态判定（**数据轴**）：只读运行期取数记录，**绝不看 `lastProbe*`**。
   *
   *   - 有通道当前站着错误（`catalog` / `meta` / `hydrate`）→ `PARTIAL`（数据不全）；
   *   - 否则，目录与全量包**都成功过至少一次** → `OK`；
   *   - 其余 → `UNKNOWN`（数据未就绪：首次安装 / 刚清空缓存 / 同步仍在进行）。
   *
   * 改动前这里先看 `lastProbeAt` / `lastProbeOk`，把「连通性」与「数据是否取到」
   * 混成了一个值 —— 那正是本次拆开的对象（见 `BrewSourceHealth` 注释）。
   * 数据轴**不做预探测**：它只说明「至今为止各通道的实际取数结果」。
   *
   * 三条错误通道对应 spec §9.5 的三个写入点：`catalog`（`getCatalog`）、
   * `meta`（`BrewMetaSync`）、`hydrate`（`BrewService.hydrate` 失败率超阈值）。
   *
   * ⚠ `UNKNOWN` 不等于「正常」：这是刻意的。旧实现把「没记录到错误」当正常，于是全新安装、
   * 一页数据都没有时卡片就写着正常；现在未就绪由 `UNKNOWN` 表达，不再指望「没出错」。
   *
   * **为什么不比时间戳**：原先写的是 `lastErrorAt > catalogOkAt`，用来表达「错误发生在最后一次成功之后」。
   * 但同一毫秒内的成功与失败会让这个比较失效（真机自检实测：`partial` 被判成 `ok`），
   * 而根因是时间戳本来就不该承担「错误是否仍然成立」这个语义。改成成功时主动清掉同类错误后，
   * `lastErrorKind` 本身就表达了「当前站着什么错误」—— 不需要时间比较，也没有分辨率问题。
   */
  public static healthState(id: string): BrewSourceHealth {
    const one: BrewSourceHealthRecord = BrewSourceStore.healthOf(id);
    const broken: boolean = one.lastErrorKind === 'catalog' || one.lastErrorKind === 'meta' ||
      one.lastErrorKind === 'hydrate';
    if (broken) {
      return BrewSourceHealth.PARTIAL;
    }
    // 目录与全量包都必须「成功过至少一次」才算就绪。两者分工不同：目录给成员与安装量，
    // 全量包给分类用的 desc；只有其一可用时浏览页/榜单确实是不完整的。
    const ready: boolean = one.catalogOkAt > 0 && one.metaIndexTokensAt > 0;
    return ready ? BrewSourceHealth.OK : BrewSourceHealth.UNKNOWN;
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
   * `catalogOkAt` / `metaIndexTokensAt` 已经不成立、`lastErrorKind` 也是旧数据的错误，
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
    one.lastErrorKind = '';
    one.lastErrorMessage = '';
    one.lastErrorAt = 0;
    one.catalogOkAt = 0;
    one.metaIndexTokensAt = 0;
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
    return stored.activeId !== normalized.activeId;
  }

  /**
   * 不变量（每条越界都自愈 + 打日志）：
   *   1. 恒存在且仅存在一条 official，`builtin=true`、`baseUrl` 为官方地址；
   *   2. official 恒为 `sources[0]`；
   *   3. `activeId` 必须命中；不命中回落 official；
   *   4. 同时只有一条 active（由 `activeId` 单值天然保证）。
   */
  private static normalizeRegistry(stored: BrewSourceRegistry | null): BrewSourceRegistry {
    const sources: BrewSource[] = stored !== null && stored.sources !== undefined ? stored.sources : [];
    const cleaned: BrewSource[] = sources.filter((one: BrewSource) =>
      one !== undefined && one !== null && one.id !== BREW_OFFICIAL_SOURCE_ID && one.id !== undefined);
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
    const next: BrewSource[] = [official];
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
