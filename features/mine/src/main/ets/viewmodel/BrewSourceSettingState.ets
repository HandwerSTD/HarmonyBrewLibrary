/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { BaseState } from '@ohos/common';
import { BrewSource, BrewSourceHealth, BrewSourceReach } from '@ohos/brewcommon';

/** 编辑页的路由参数。新增和编辑共用同一页，id 为空串表示新增。 */
export interface BrewSourceEditParams {
  id: string;
  name: string;
  url: string;
  builtin: boolean;
}

/** 列表一行。`BrewSource` 是纯数据类，UI 需要额外的展示字段，所以包一层。
 *
 * 不加 `@Observed`：VM 每次 `refresh()` 都**整体替换** `state.rows`，靠 `@State` 的
 * 顶层赋值通知即可；给元素加 `@Observed` 而不配 `@ObjectLink` 是无效的。
 */
export class BrewSourceRow {
  public source: BrewSource;
  /**
   * **连通性**结论（探测轴）：未验证 / 连接正常 / 连接失败。
   *
   * 这一行才是「测试连接」的结论。它与下方 `dataState` **互不影响** ——
   * 旧实现把两者合成一个值，于是「点测试连接正常、列表却写着部分可用」。
   */
  public reach: BrewSourceReach = BrewSourceReach.UNKNOWN;
  /** 最近一次探测的失败原因码（`reach === FAILING` 时有意义），逐码映射成人话 */
  public reachReason: string = '';
  /**
   * **数据就绪**状态（运行期轴）。只对会话激活源有意义（只有它会被取数），
   * 其余源不展示这一行（它们的运行期记录永远是空的，展示出来只会是误导）。
   *
   * **两片都成功过才算 `OK`**，其余一律 `NOT_READY` —— 部分成功不单设状态。
   */
  public dataState: BrewSourceHealth = BrewSourceHealth.NOT_READY;
  /** 安装量片（4 个聚合端点，给成员与安装量）是否成功取到过 */
  public dataVolReady: boolean = false;
  /** 描述片（两个全量包，给分类用的 desc）是否成功取到过 */
  public dataDescReady: boolean = false;
  /**
   * 当前站着的运行期错误分片（`vol` / `desc`），空串表示没站着错误。
   *
   * 为什么需要它：`dataDetail` 里那串 `ok=false code=0 text=0B pairs=0 skips=0 err=download …`
   * 是给人看日志的，不是给人看设置页的 —— 直接渲染出来用户只会看到一屏乱码。
   * 有它就能把「哪一片挂了」翻成人话，而信息量并不比原串少（原串里真正有意义的也只有这个）。
   */
  public dataErrorKind: string = '';
  /** 运行期原始诊断串（开发者向）。UI 不渲染它，只写 hilog */
  public dataDetail: string = '';
  /** 本会话冻结的 active 源 id —— 「使用中」标注看它，不是看注册表的 activeId */
  public isSessionActive: boolean = false;

  public constructor(source: BrewSource) {
    this.source = source;
  }
}

@Observed
export class BrewSourceSettingState extends BaseState {
  public rows: BrewSourceRow[] = [];
  /** 正在编辑的源 id；空串表示没在编辑已有源 */
  public editingId: string = '';
  /**
   * 是否正在**新增**源。
   *
   * 为什么需要这个独立标志：新增时还没有源，`editingId` 只能是空串，
   * 而「空串」同时也表示「没在编辑」—— 两者靠 `editingId` 分不开，
   * 于是表单无处渲染（新增按钮点了没有任何反应）。
   */
  public creating: boolean = false;
  public editingName: string = '';
  public editingUrl: string = '';
  /** 错误提示（表单校验 / 探测失败 / 操作被拒），空串表示无 */
  public errorText: string = '';
  /** 正在探测的源 id（激活与「测试连接」共用），空串表示没有探测在进行 */
  public probingId: string = '';
  /**
   * 这条探测结果属于哪个源 id；空串表示当前没有结果。
   *
   * 必须存 id 而不是只看 `probeReason`：否则激活源 B 失败时，
   * 所有非激活卡片都会显示同一个失败原因（结果串卡片）。
   */
  public probeResultId: string = '';
  /** 探测结果是否成功（`probeResultId` 非空时才有意义） */
  public probeResultOk: boolean = false;
  /** 探测失败的原因码（与 `probeReasonText()` 的分支一一对应），空串表示无 */
  public probeReason: string = '';
  /** 探测结果里的 HTTP / 平台错误码，用于 pretty print 诊断行。 */
  public probeResultCode: number = 0;
  /** 探测返回的补充诊断信息，例如 bodyLen、content-type 或平台错误消息。 */
  public probeResultDetail: string = '';
  /** 探测耗时（ms，P1-4 诊断 AI 卡的 grounding 字段之一；与 probeResult* 同生命周期）。 */
  public probeResultTookMs: number = 0;
}
