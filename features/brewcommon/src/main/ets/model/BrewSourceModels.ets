/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { BREW_DIALECT_UPSTREAM } from '../constant/BrewSourceConstants';

/**
 * 一条数据源。
 *
 * **字段全部是 public 数据字段、没有方法**：这个类要经 `JSON.stringify` / `JSON.parse` 过一遍
 * Preferences，解析回来的是普通对象而不是类实例，方法会丢。所有行为放在 `BrewSourceStore` /
 * `BrewSourceUrl` 里。
 *
 * `id` 与 `baseUrl` 刻意解耦：改 URL 等于换了一份数据，必须清掉该源的 cache；
 * 而 `id` 生成后永不变更，所以改 URL 不会继承旧 cache。
 */
export class BrewSource {
  public id: string;
  public name: string;
  public baseUrl: string;
  /** 数据响应形状的方言；不改变 `id` / `baseUrl` 解耦及改 URL 清缓存的不变量。 */
  public dialect: string;
  /** Harmonybrew 探测识别出的 bottle tag；上游源为空串。 */
  public tag: string;
  public builtin: boolean;
  public createdAt: number;

  public constructor(id: string, name: string, baseUrl: string, builtin: boolean, createdAt: number,
    dialect: string, tag: string = '') {
    this.id = id;
    this.name = name;
    this.baseUrl = baseUrl;
    this.dialect = dialect;
    this.tag = tag;
    this.builtin = builtin;
    this.createdAt = createdAt;
  }
}

/** 源注册表。不变量见 `BrewSourceStore.normalizeRegistry` */
export class BrewSourceRegistry {
  public sources: BrewSource[];
  public activeId: string;

  public constructor(sources: BrewSource[], activeId: string) {
    this.sources = sources;
    this.activeId = activeId;
  }
}

/**
 * 源的**数据就绪**状态（由运行期取数记录推导）。
 *
 * ⚠ 它与「连通性」（`BrewSourceReach`）是**两个正交维度**，不要合成一个值：
 *   - `BrewSourceReach` 回答「这个地址能不能应答」——只在点「测试连接 / 激活」时探测一次；
 *   - 本枚举回答「必需的数据有没有完整取到过」——由包表两片的运行期记录推导。
 *
 * **两片都成功过才算成功**，其余一律未就绪。部分成功不再有单独的表达：
 * 一片成功一片失败之后能显示的内容本来就很少（只有一档榜有成员、或列表没有排序数字），
 * 为它单设一个状态并区分「哪一片挂了」成本大于收益。
 * 哪一片失败仍然查得到 —— 分片错误槽（`volError` / `descError`）与本枚举正交。
 */
export enum BrewSourceHealth {
  /**
   * 必需数据**还没有完整取到过**：首次安装、刚清空缓存、同步仍在进行，
   * 或只取到了一片。
   *
   * ⚠ 它不是「正常」：旧实现把「没记录到错误」直接当正常，于是全新安装、一页数据都没有时
   * 卡片就写着正常。现在缺失由这里表达，两片都取到后才转 `OK`。
   */
  NOT_READY = 'not_ready',
  /** 两片都成功过，且当前没有站着的分片错误 */
  OK = 'ok',
}

/**
 * 源的**连通性**结论。**只**由探测写入（`BrewSourceStore.noteProbe`），与取数进度无关。
 *
 * 这是「测试连接」唯一该表达的结论：地址能不能应答、返回的形状对不对。
 * 数据是否下载完整不由它回答（那是 `BrewSourceHealth`），所以它**不参与**后者判定。
 */
export enum BrewSourceReach {
  /** 从没探测过（本进程没测、盘上也没有记录） */
  UNKNOWN = 'unknown',
  OK = 'ok',
  FAILING = 'failing',
}

/**
 * 运行期健康记录。同样是纯数据字段。
 *
 * 两片的错误**分槽存**而不是挤在一个 `lastErrorKind` 里：表写入口知道自己是写成功哪片，
 * 于是「成功时清掉同类错误」变成自然结果，不需要时间戳比较（原先那套比较正是为了绕过
 * 同毫秒内成功与失败互相覆盖而写的，而它自己也被真机自检证伪过）。
 */
export class BrewSourceHealthRecord {
  public lastProbeOk: boolean = false;
  public lastProbeReason: string = '';
  public lastProbeAt: number = 0;
  /** 安装量片（4 个聚合端点）成功过的时刻 */
  public volReadyAt: number = 0;
  /** 描述片（两个全量包）成功过的时刻 */
  public descReadyAt: number = 0;
  public volError: string = '';
  public volErrorMessage: string = '';
  public volErrorAt: number = 0;
  public descError: string = '';
  public descErrorMessage: string = '';
  public descErrorAt: number = 0;
}

/** 探测结果 */
export class BrewProbeResult {
  public ok: boolean;
  public reason: string;
  public httpCode: number;
  public tookMs: number;
  public detail: string;
  /** 探测识别出的数据响应方言；上游探测的默认值也是 upstream。 */
  public dialect: string = BREW_DIALECT_UPSTREAM;
  /** Harmonybrew 响应中读出的 bottle tag；上游探测为空串。 */
  public tag: string = '';

  public constructor(ok: boolean, reason: string, httpCode: number, tookMs: number, detail: string) {
    this.ok = ok;
    this.reason = reason;
    this.httpCode = httpCode;
    this.tookMs = tookMs;
    this.detail = detail;
  }
}

/** 单个源的缓存统计 */
export class BrewSourceCacheStats {
  public sourceId: string = '';
  public keys: number = 0;
  public entries: number = 0;
  public approxBytes: number = 0;
  public updatedAt: number = 0;
}
