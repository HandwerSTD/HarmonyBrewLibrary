/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
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

import { common } from '@kit.AbilityKit';
import { BaseVM, BaseVMEvent } from '@ohos/common';
import {
  BrewCacheAdmin,
  BrewSourceProbe,
  BrewSourceRestart,
  BrewSourceStore,
  BrewSourceUrl,
} from '@ohos/brewcommon';
import type {
  BrewProbeResult,
  BrewSource,
  BrewSourceHealthRecord,
  BrewSourceUpdateResult,
  BrewSourceUrlCheck,
} from '@ohos/brewcommon';
import { BrewSourceRow, BrewSourceSettingState } from './BrewSourceSettingState';

export class BrewSourceInitEvent implements BaseVMEvent {
}

export class BrewSourceRefreshEvent implements BaseVMEvent {
}

export class BrewSourceSaveEvent implements BaseVMEvent {
  public id: string = '';
  public name: string = '';
  public url: string = '';

  public constructor(id: string, name: string, url: string) {
    this.id = id;
    this.name = name;
    this.url = url;
  }
}

export class BrewSourceClearEvent implements BaseVMEvent {
  public id: string = '';

  public constructor(id: string) {
    this.id = id;
  }
}

export class BrewSourceDeleteEvent implements BaseVMEvent {
  public id: string = '';

  public constructor(id: string) {
    this.id = id;
  }
}

export class BrewSourceEditStartEvent implements BaseVMEvent {
  public id: string = '';
  public name: string = '';
  public url: string = '';

  public constructor(id: string, name: string, url: string) {
    this.id = id;
    this.name = name;
    this.url = url;
  }
}

export class BrewSourceEditCancelEvent implements BaseVMEvent {
}

export class BrewSourceSettingVM extends BaseVM<BrewSourceSettingState> {
  private static instance: BrewSourceSettingVM;

  /**
   * 最近一次成功探测的源身份。探测本身是纯读操作，只有本 VM 的成功回调与保存路径可以写注册表。
   * 记录 URL 是为了防止用户探测后又改地址，却把旧地址的 dialect/tag 写到新地址上。
   */
  private pendingProbeId: string = '';
  private pendingProbeUrl: string = '';
  private pendingProbeDialect: string = '';
  private pendingProbeTag: string = '';

  /**
   * 由 View 注入（VM 拿不到 `UIAbilityContext`）。
   *
   * 用函数而不是直接存 context：`UIAbilityContext` 属于 UI 层，VM 持有它会把两者绑死；
   * 存成「需要时再取」的提供者，也让 VM 在非 UI 环境下（自检/后续测试）可以不给它。
   */
  public contextProvider: (() => common.UIAbilityContext | undefined) | undefined = undefined;

  private constructor() {
    super(new BrewSourceSettingState());
  }

  public static getInstance(): BrewSourceSettingVM {
    if (!BrewSourceSettingVM.instance) {
      BrewSourceSettingVM.instance = new BrewSourceSettingVM();
    }
    return BrewSourceSettingVM.instance;
  }

  public sendEvent(event: BaseVMEvent): void {
    if (event instanceof BrewSourceInitEvent) {
      this.clearProbeResult();
      this.refresh();
    } else if (event instanceof BrewSourceRefreshEvent) {
      this.refresh();
    } else if (event instanceof BrewSourceSaveEvent) {
      this.save(event);
    } else if (event instanceof BrewSourceEditStartEvent) {
      // 新增（id 为空串）与编辑（id 非空）必须分开记：光靠 `editingId` 分不开
      //「正在新增」与「没在编辑」（两者都是空串），表单就会无处渲染。
      this.state.creating = event.id.length === 0;
      this.state.editingId = event.id;
      this.state.editingName = event.name;
      this.state.editingUrl = event.url;
      this.state.errorText = '';
      this.clearProbeResult();
    } else if (event instanceof BrewSourceEditCancelEvent) {
      this.state.creating = false;
      this.state.editingId = '';
      this.state.editingName = '';
      this.state.editingUrl = '';
      this.state.errorText = '';
      this.clearProbeResult();
    } else if (event instanceof BrewSourceClearEvent) {
      this.clear(event.id);
    } else if (event instanceof BrewSourceDeleteEvent) {
      this.remove(event.id);
    }
  }

  /** 记录一条探测结果，并把它**绑定到源 id** —— 渲染条件靠它，否则结果会串到别的卡片上 */
  private setProbeResult(id: string, ok: boolean, reason: string, code: number = 0,
    detail: string = ''): void {
    this.state.probeResultId = id;
    this.state.probeResultOk = ok;
    this.state.probeReason = ok ? '' : reason;
    this.state.probeResultCode = code;
    this.state.probeResultDetail = detail;
  }

  /** 清掉上一次的探测结果（重新进页面 / 开始新增或编辑 / 取消编辑时） */
  private clearProbeResult(): void {
    this.state.probeResultId = '';
    this.state.probeResultOk = false;
    this.state.probeReason = '';
    this.state.probeResultCode = 0;
    this.state.probeResultDetail = '';
  }

  public setEditingName(value: string): void {
    this.state.editingName = value;
  }

  public setEditingUrl(value: string): void {
    this.state.editingUrl = value;
  }

  public refresh(): void {
    const sessionId: string = BrewSourceStore.sessionActive().id;
    const rows: BrewSourceRow[] = [];
    BrewSourceStore.listSources().forEach((one: BrewSource) => {
      const row: BrewSourceRow = new BrewSourceRow(one);
      const record: BrewSourceHealthRecord = BrewSourceStore.healthOf(one.id);
      // 两个正交维度分别取值（见 `BrewSourceReach` / `BrewSourceHealth` 的类注释）：
      //   reach    ← 探测记录（只有「测试连接 / 激活」会写）
      //   dataState ← 运行期取数记录（目录 / 全量包 / hydrate 三个写入点）
      // 旧代码在这里按「谁决定了当前状态」把两者合并成一行，于是同一张卡片上
      // 「刚点的测试连接」与「历史上的取数失败」互相覆盖，用户读到的取决于他刚才点过什么。
      row.reach = BrewSourceStore.reachState(one.id);
      row.reachReason = record.lastProbeAt > 0 && !record.lastProbeOk ? record.lastProbeReason : '';
      row.dataState = BrewSourceStore.healthState(one.id);
      row.dataCatalogReady = record.catalogOkAt > 0;
      row.dataIndexReady = record.metaIndexTokensAt > 0;
      row.dataErrorKind = record.lastErrorMessage.length > 0 ? record.lastErrorKind : '';
      row.dataDetail = record.lastErrorMessage;
      row.isSessionActive = one.id === sessionId;
      rows.push(row);
    });
    this.state.rows = rows;
  }

  /** 编辑页的只读方言标签。新增源尚未识别时显示「自动识别」。 */
  public editingDialectText(): ResourceStr {
    if (this.state.editingId.length === 0) {
      return $r('app.string.brew_source_dialect_auto');
    }
    const source: BrewSource | undefined = BrewSourceStore.find(this.state.editingId);
    if (source === undefined) {
      return $r('app.string.brew_source_dialect_auto');
    }
    if (source.dialect === 'upstream') {
      return $r('app.string.brew_source_dialect_upstream');
    }
    if (source.tag.length > 0) {
      return $r('app.string.brew_source_dialect_harmonybrew', source.tag);
    }
    return $r('app.string.brew_source_dialect_harmonybrew_unknown');
  }

  /**
   * 记住并写回一次成功探测识别出的身份。
   *
   * `BrewSourceProbe.check` 不碰持久化，设置 VM 是唯一写者。激活路径必须在重启前立即写入；
   * 测试连接也立即写入，让随后打开的编辑页能显示真识别出的方言。
   */
  private acceptProbeIdentity(id: string, baseUrl: string, result: BrewProbeResult): void {
    if (!result.ok) {
      return;
    }
    this.pendingProbeId = id;
    this.pendingProbeUrl = baseUrl;
    this.pendingProbeDialect = result.dialect;
    this.pendingProbeTag = result.tag;
    BrewSourceStore.updateProbeIdentity(id, result.dialect, result.tag);
  }

  /** 保存同名旧探测结果；URL 已变或无成功探测时不覆盖盘上的身份。 */
  private applyPendingProbeIdentity(id: string, baseUrl: string): void {
    if (this.pendingProbeId !== id || this.pendingProbeUrl !== baseUrl ||
      this.pendingProbeDialect.length === 0) {
      return;
    }
    BrewSourceStore.updateProbeIdentity(id, this.pendingProbeDialect, this.pendingProbeTag);
  }

  /**
   * 保存数据源。返回 true 表示保存成功，调用方据此关闭编辑页；
   * 校验失败时保留当前表单并通过 state.errorText 展示原因。
   */
  public save(event: BrewSourceSaveEvent): boolean {
    const name: string = event.name.trim();
    if (name.length === 0) {
      this.state.errorText = 'name-empty';
      return false;
    }
    const check: BrewSourceUrlCheck = BrewSourceUrl.check(event.url);
    if (!check.ok) {
      this.state.errorText = 'url-' + check.reason;
      return false;
    }
    if (event.id.length === 0) {
      const created: BrewSource | undefined = BrewSourceStore.addSource(name, check.normalized);
      if (created === undefined) {
        this.state.errorText = 'save-failed';
        return false;
      }
    } else {
      const result: BrewSourceUpdateResult = BrewSourceStore.updateSource(event.id, name, check.normalized);
      if (!result.ok) {
        this.state.errorText = 'save-failed';
        return false;
      }
      if (result.baseUrlChanged) {
        // 改 URL = 换了一份数据：清掉该源缓存（激活源会同时重置内存态）
        BrewCacheAdmin.clear(event.id).then(() => {
          this.refresh();
        });
      } else {
        this.applyPendingProbeIdentity(event.id, check.normalized);
      }
    }
    this.state.errorText = '';
    this.state.creating = false;
    this.state.editingId = '';
    this.state.editingName = '';
    this.state.editingUrl = '';
    this.refresh();
    return true;
  }

  private clear(id: string): void {
    BrewCacheAdmin.clear(id).then(() => {
      this.refresh();
    });
  }

  private remove(id: string): void {
    BrewCacheAdmin.drop(id).then(() => {
      this.refresh();
    });
  }

  /**
   * 激活一个源：**探测 → 写 activeId → 重启**。
   *
   * 探测失败是**硬阻断**：不写 `activeId`、不改任何状态，只把原因码放进 `state.probeReason`。
   * 理由是把 App 切到一个已确认不可用的源上，用户会看到全空页面，
   * 而因为「切换需重启」又很难退回来 —— 宁可让他在这一步就知道原因。
   *
   * 调用方（视图）负责先弹确认框；本方法在用户已确认后才会被调到。
   */
  public activate(id: string): void {
    const source: BrewSource | undefined = BrewSourceStore.find(id);
    if (source === undefined) {
      return;
    }
    this.state.probingId = id;
    this.clearProbeResult();
    BrewSourceProbe.check(source.baseUrl).then((result: BrewProbeResult) => {
      this.state.probingId = '';
      BrewSourceStore.noteProbe(id, result.ok, result.reason);
      this.acceptProbeIdentity(id, source.baseUrl, result);
      this.setProbeResult(id, result.ok, result.reason, result.httpCode, result.detail);
      if (!result.ok) {
        // 硬阻断：不写 activeId，不改任何状态
        this.refresh();
        return;
      }
      const written: boolean = BrewSourceStore.setActiveId(id);
      if (!written) {
        this.setProbeResult(id, false, 'write-failed');
        this.refresh();
        return;
      }
      const context: common.UIAbilityContext | undefined =
        this.contextProvider !== undefined ? this.contextProvider() : undefined;
      if (context === undefined) {
        this.setProbeResult(id, false, 'no-context');
        this.refresh();
        return;
      }
      BrewSourceRestart.restart(context);
    }).catch((err: Error) => {
      this.state.probingId = '';
      // 记录**连通性**失败。`noteError` 只收 catalog/meta/hydrate（数据轴），
      // 拿 'probe' 去调会被静默丢弃 —— 那样测试连接抛异常时卡片仍显示上次的结论。
      BrewSourceStore.noteProbe(id, false, 'network-unknown');
      this.setProbeResult(id, false, 'network-unknown', 0, err.message);
      this.refresh();
    });
  }

  /**
   * 「测试连接」：只探测地址能不能用，**不改任何 App 行为**。
   *
   * 与 `activate()` 的唯一区别：探测成功后**不写 `activeId`、不重启**。
   * 健康记录口径与激活路径相同（都是 `noteProbe`）—— 否则「测试连接说可用」
   * 与源列表上的状态会互相矛盾。
   */
  public testConnection(id: string): void {
    const source: BrewSource | undefined = BrewSourceStore.find(id);
    if (source === undefined) {
      return;
    }
    this.state.probingId = id;
    this.clearProbeResult();
    BrewSourceProbe.check(source.baseUrl).then((result: BrewProbeResult) => {
      this.state.probingId = '';
      BrewSourceStore.noteProbe(id, result.ok, result.reason);
      this.acceptProbeIdentity(id, source.baseUrl, result);
      this.setProbeResult(id, result.ok, result.reason, result.httpCode, result.detail);
      this.refresh();
    }).catch((err: Error) => {
      this.state.probingId = '';
      // 同 `activate()`：连通性失败走 `noteProbe`，不丢给只收数据轴 kind 的 `noteError`
      BrewSourceStore.noteProbe(id, false, 'network-unknown');
      this.setProbeResult(id, false, 'network-unknown', 0, err.message);
      this.refresh();
    });
  }

  /**
   * 保存表单的校验失败原因码 → 可读文案。
   *
   * 分支必须与 `save()` 写入 `state.errorText` 的码**一一对应**：
   * `name-empty` / `save-failed`，以及 `url-*`（后缀来自 `BrewSourceUrl.validate()` 的 reason 码：
   * `empty` / `too-long` / `scheme` / `query` / `fragment` / `host`）。
   *
   * 为什么要逐码分支而不是一句「输入不合法」：spec §8.1 要求「错误提示指向具体哪一条不满足」——
   * 用户粘一个带查询参数的地址进来时，「不能带查询参数」比「输入不合法」多给出了全部信息。
   * 未知码兜底到原句。
   */
  public saveErrorText(): ResourceStr {
    const code: string = this.state.errorText;
    if (code.length === 0) {
      return '';
    }
    if (code === 'name-empty') {
      return $r('app.string.brew_source_err_name_empty');
    }
    if (code === 'url-empty') {
      return $r('app.string.brew_source_err_url_empty');
    }
    if (code === 'url-scheme') {
      return $r('app.string.brew_source_err_url_scheme');
    }
    if (code === 'url-host') {
      return $r('app.string.brew_source_err_url_host');
    }
    if (code === 'url-query') {
      return $r('app.string.brew_source_err_url_query');
    }
    if (code === 'url-fragment') {
      return $r('app.string.brew_source_err_url_fragment');
    }
    if (code === 'url-too-long') {
      return $r('app.string.brew_source_err_url_too_long');
    }
    if (code === 'save-failed') {
      return $r('app.string.brew_source_err_save_failed');
    }
    return $r('app.string.brew_source_error_invalid');
  }

  /**
   * 探测失败原因码 → 可读文案。
   *
   * 分支必须与 `activate()` / `testConnection()` 写入的码一一对应，**也**与盘上持久的上次结论
   * （`BrewSourceRow.reachReason`）对应 —— 两者是同一批原因码，所以只保留这一个映射入口：
   * 刚测的传 `state.probeReason`，上次的传 `row.reachReason`。
   * 拆成“读 state”与“收参”两个方法会得到两份分支表，必然有一份漏改。
   */
  public probeReasonTextOf(reason: string): ResourceStr {
    if (reason === 'invalid-url') {
      return $r('app.string.brew_source_probe_invalid_url');
    }
    if (reason === 'dns') {
      return $r('app.string.brew_source_probe_dns');
    }
    if (reason === 'timeout') {
      return $r('app.string.brew_source_probe_timeout');
    }
    if (reason === 'tls') {
      return $r('app.string.brew_source_probe_tls');
    }
    if (reason === 'http-404') {
      return $r('app.string.brew_source_probe_404');
    }
    if (reason === 'http-4xx' || reason === 'http-5xx') {
      return $r('app.string.brew_source_probe_http');
    }
    if (reason === 'not-json' || reason === 'html-body' || reason === 'shape-mismatch') {
      return $r('app.string.brew_source_probe_not_api');
    }
    // 这两个码不是网络问题：探测其实成功了，是「写配置 / 取 context」失败。
    // 以前它们落到兜底分支、被显示成「网络错误」，会把用户引到完全错误的方向。
    if (reason === 'write-failed') {
      return $r('app.string.brew_source_probe_write_failed');
    }
    if (reason === 'no-context') {
      return $r('app.string.brew_source_probe_no_context');
    }
    if (reason.length === 0) {
      return '';
    }
    return $r('app.string.brew_source_probe_unknown');
  }

  /** 本次探测（`state.probeReason`）的原因文案；持久结论请调 `probeReasonTextOf(row.reachReason)` */
  public probeReasonText(): ResourceStr {
    return this.probeReasonTextOf(this.state.probeReason);
  }

  /** 官方源只允许改名 */
  public isBuiltin(id: string): boolean {
    const source: BrewSource | undefined = BrewSourceStore.find(id);
    return source !== undefined && source.builtin;
  }
}
