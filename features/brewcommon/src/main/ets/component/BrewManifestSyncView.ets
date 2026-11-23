/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

/**
 * W′ 工具清单同步的主视图（spec §4.2）——双形态共用一份内容：
 *
 * - `sheetMode = true`：顶部自带标题行（宿主是 PcMainPage 侧边栏节点的 bindSheet，
 *   Sheet 选项由宿主给），关闭按钮走 `BrewManifestSyncService.closeSheet()`；
 * - `sheetMode = false`：常驻页（BrewManifestSyncPage）内嵌形态，标题栏由页面的
 *   NavDestination 提供，这里只渲染内容区。
 *
 * 内容区自上而下：F1 失败行 → 互见句 → 新装列表（勾选仅 pc_acl）→ 批量安装条/查看进度 →
 * 空态提示 → 设备卡区（schema 过新设备给 F6 行）→ 底部行（未授权时换成授权引导）。
 *
 * 状态全部来自 `BrewManifestSyncService` 的单例 `@Observed` state（数据全内存，
 * T0 静默——spec §4.5）；队列状态 chip 的刷新靠订阅命令终态 bump 一个记号，
 * 记号进 ForEach key 强制重建行（BrewInstallQueue 不是 @Observed，不能指望深监听）。
 */

import { UIContext } from '@kit.ArkUI';
import { Toast, CommonConstants, GlobalInfoModel, Logger, PageContext, PageEnum, StorageKey } from '@ohos/common';
import { BrewKind } from '../model/BrewModels';
import type { BrewDetailParams } from '../model/BrewModels';
import { BrewCommandRunner } from '../service/BrewCommandRunner';
import { isBrewCommandEnded } from '../model/BrewCommandModels';
import type { BrewCommandState } from '../model/BrewCommandModels';
import { BrewInstallQueue } from '../service/BrewInstallQueue';
import { BrewManifestSyncService } from '../service/BrewManifestSyncService';
import { BREW_ACTION_BUTTON_HEIGHT, BREW_ACTION_BUTTON_MAX_WIDTH } from '../constant/BrewActionBar';
import { BrewManifestDeviceCard } from './BrewManifestDeviceCard';
import { BrewManifestDeviceParams, BrewQueueStatus, BrewSyncPackageDoc } from '../model/BrewSyncModels';
import type { BrewManifestSyncState } from '../model/BrewSyncModels';
import type { BrewQueueItem } from '../model/BrewSyncModels';
import type { BrewSyncDeviceEntry } from '../model/BrewSyncModels';

const TAG: string = '[BrewManifestSyncView]';

/** 主操作按钮的固定宽度（与 MinePackagesView 的 60% 同款）。 */
const BREW_SYNC_ACTION_WIDTH: Length = '60%';

@Component
export struct BrewManifestSyncView {
  /** true = Sheet 形态（自带标题行）；false = 常驻页内嵌（标题栏归 NavDestination）。 */
  @Prop sheetMode: boolean = false;

  /** 单例状态（@Observed；一级字段变更即刷新）。 */
  @State syncState: BrewManifestSyncState = BrewManifestSyncService.getInstance().getState();
  /** 勾选进批量安装的包（identity 集合；改动后整体重赋值保证 UI 刷新）。 */
  @State private selected: Set<string> = new Set<string>();
  /** 队列状态记号：命令终态 / 入队 / 重试时 +1，进 ForEach key 强制重算状态 chip。 */
  @State private queueTick: number = 0;
  @StorageProp(StorageKey.GLOBAL_INFO) globalInfoModel: GlobalInfoModel =
    AppStorage.get(StorageKey.GLOBAL_INFO) ?? new GlobalInfoModel();

  private service: BrewManifestSyncService = BrewManifestSyncService.getInstance();
  private queue: BrewInstallQueue = BrewInstallQueue.getInstance();
  private scroller: Scroller = new Scroller();
  /** 命令监听器必须存字段（subscribe/unsubscribe 按函数对象去重，字面量退订不掉）。 */
  private runnerListener: (() => void) | null = null;

  aboutToAppear(): void {
    this.runnerListener = () => {
      const commandState: BrewCommandState = BrewCommandRunner.getInstance().getState();
      if (isBrewCommandEnded(commandState.status)) {
        this.queueTick++;
      }
    };
    BrewCommandRunner.getInstance().subscribe(this.runnerListener);
  }

  aboutToDisappear(): void {
    if (this.runnerListener !== null) {
      BrewCommandRunner.getInstance().unsubscribe(this.runnerListener);
      this.runnerListener = null;
    }
  }

  // ---------------------------------------------------------------- 取数辅助

  /** pc_acl 才有的能力（勾选/批量安装/队列状态 chip）；pc_normal 清单只读。 */
  private cliEnabled(): boolean {
    return AppStorage.get<boolean>(StorageKey.BREW_CLI_ENABLED) === true;
  }

  private kindOf(pkg: BrewSyncPackageDoc): BrewKind {
    return pkg.kind === BrewKind.CASK ? BrewKind.CASK : BrewKind.FORMULA;
  }

  /** 包的来源设备名（新装行「来源」副文本）：第一个含此包的非本机设备。 */
  private sourceNameOf(pkg: BrewSyncPackageDoc): string {
    for (const device of this.syncState.devices) {
      if (device.isSelf || device.schemaTooNew) {
        continue;
      }
      for (const one of device.packages) {
        if (one.identity() === pkg.identity()) {
          return device.deviceName;
        }
      }
    }
    return this.syncState.pendingNewFrom;
  }

  private queueItemOf(pkg: BrewSyncPackageDoc): BrewQueueItem | undefined {
    return this.queue.itemOf(this.kindOf(pkg), pkg.tap, pkg.token);
  }

  /**
   * 行右 chip 的文案：队列无此条 = 待装；PENDING 已入队；RUNNING 安装中；
   * DONE 已完成；FAILED 失败（可点重试）。
   */
  private statusTextOf(item: BrewQueueItem | undefined): ResourceStr {
    if (item === undefined) {
      return $r('app.string.sync_pkg_status_pending');
    }
    if (item.status === BrewQueueStatus.PENDING) {
      return $r('app.string.sync_pkg_status_queued');
    }
    if (item.status === BrewQueueStatus.RUNNING) {
      return $r('app.string.sync_pkg_status_running');
    }
    if (item.status === BrewQueueStatus.DONE) {
      return $r('app.string.sync_pkg_status_done');
    }
    return $r('app.string.sync_pkg_status_failed');
  }

  private kindDescOf(pkg: BrewSyncPackageDoc): ResourceStr {
    return this.kindOf(pkg) === BrewKind.CASK ?
      $r('app.string.sync_pkg_kind_cask') : $r('app.string.sync_pkg_kind_formula');
  }

  /** 底部「上次同步」时刻文本；失败时刻不早于成功时刻时优先报失败。 */
  private lastSyncText(): string {
    if (this.lastSyncFailed()) {
      return this.formatTime(this.syncState.lastSyncFailAt);
    }
    if (this.syncState.lastSyncAt > 0) {
      return this.formatTime(this.syncState.lastSyncAt);
    }
    return '';
  }

  private lastSyncFailed(): boolean {
    return this.syncState.lastSyncFailAt > 0 && this.syncState.lastSyncFailAt >= this.syncState.lastSyncAt;
  }

  private formatTime(ts: number): string {
    const d: Date = new Date(ts);
    const mm: string = `${d.getMonth() + 1}`.padStart(2, '0');
    const dd: string = `${d.getDate()}`.padStart(2, '0');
    const hh: string = `${d.getHours()}`.padStart(2, '0');
    const mi: string = `${d.getMinutes()}`.padStart(2, '0');
    return `${mm}-${dd} ${hh}:${mi}`;
  }

  private contentBottomInset(): Length {
    return this.globalInfoModel.naviIndicatorHeight + CommonConstants.SPACE_24;
  }

  // ---------------------------------------------------------------- 动作

  private toggleSelect(pkg: BrewSyncPackageDoc): void {
    const next: Set<string> = new Set<string>(this.selected);
    if (next.has(pkg.identity())) {
      next.delete(pkg.identity());
    } else {
      next.add(pkg.identity());
    }
    this.selected = next;
  }

  /** 「安装所选」：逐条入队（失败域隔离在队列内），入队成功即清勾选。 */
  private enqueueSelected(): void {
    const done: string[] = [];
    let rejected: number = 0;
    this.syncState.pendingNew.forEach((pkg: BrewSyncPackageDoc) => {
      if (!this.selected.has(pkg.identity())) {
        return;
      }
      const ok: boolean = this.queue.enqueue(pkg.token, this.kindOf(pkg), pkg.tap);
      if (ok) {
        done.push(pkg.identity());
      } else {
        rejected++;
      }
    });
    const next: Set<string> = new Set<string>(this.selected);
    done.forEach((id: string) => {
      next.delete(id);
    });
    this.selected = next;
    this.queueTick++;
    if (rejected > 0) {
      Toast.showToast($r('app.string.sync_queue_fail_toast'));
    }
    Logger.info(TAG, `enqueue selected done=${done.length} rejected=${rejected} remain=${this.queue.pendingCount()}`);
  }

  /** 「查看进度」：拉起既有命令 Sheet（宏观在队列条目、微观在命令输出——spec §3.7）。 */
  private viewProgress(): void {
    BrewCommandRunner.getInstance().openSheet();
  }

  private syncNow(): void {
    if (this.syncState.syncing) {
      return;
    }
    this.service.sync(false);
  }

  private authorize(): void {
    const uiContext: UIContext | undefined = AppStorage.get<UIContext>(StorageKey.UI_CONTEXT);
    if (uiContext === undefined) {
      return;
    }
    const context: Context | undefined = uiContext.getHostContext();
    if (context === undefined) {
      return;
    }
    this.service.requestDatasyncPermission(context).then((granted: boolean) => {
      Logger.info(TAG, `authorize granted=${granted}`);
    });
  }

  /** 行点详情：双 product 都可进（浏览不受 BREW_CLI_ENABLED 闸）。 */
  private jumpDetail(pkg: BrewSyncPackageDoc): void {
    const param: BrewDetailParams = {
      kind: this.kindOf(pkg),
      title: pkg.token,
      id: 0,
      token: pkg.token,
      categoryKey: '',
    };
    this.service.closeSheet();
    this.pageContext()?.openPage({ routerName: PageEnum.BREW_DETAIL_VIEW, param: param }, true);
  }

  private openDevicePage(entry: BrewSyncDeviceEntry): void {
    const param: BrewManifestDeviceParams = new BrewManifestDeviceParams();
    param.deviceId = entry.deviceId;
    this.service.closeSheet();
    this.pageContext()?.openPage({ routerName: PageEnum.BREW_MANIFEST_DEVICE_VIEW, param: param }, true);
  }

  /**
   * 详情/二级页压到哪个栈：Sheet 与常驻页都长在「我的」侧（侧边栏布局用 MINE 栈），
   * 窗口布局用 HOME 栈——与 MinePackagesUtil 的跳转口径一致。
   */
  private pageContext(): PageContext | undefined {
    return AppStorage.get<boolean>(StorageKey.IS_SIDEBAR_LAYOUT) ?
      AppStorage.get<PageContext>(StorageKey.MINE_PAGE_CONTEXT) :
      AppStorage.get<PageContext>(StorageKey.HOME_PAGE_CONTEXT);
  }

  // ---------------------------------------------------------------- 构建器

  @Builder
  TitleBar() {
    Row() {
      Text($r('app.string.sync_sheet_title'))
        .fontSize($r('sys.float.Title_L'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
      Blank()
      Column() {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize($r('sys.float.Title_M'))
          .fontColor([$r('sys.color.icon_secondary')])
      }
      .justifyContent(FlexAlign.Center)
      .width($r('app.float.brew_monogram_size'))
      .height($r('app.float.brew_monogram_size'))
      .borderRadius($r('sys.float.corner_radius_level5'))
      .onClick(() => {
        this.service.closeSheet();
      })
    }
    .alignItems(VerticalAlign.Center)
    .width(CommonConstants.FULL_PERCENT)
    .height($r('app.float.brew_card_header_height'))
    .padding({
      left: $r('sys.float.padding_level8'),
      right: $r('sys.float.padding_level8'),
    })
  }

  /** 互见句（spec ②）：pendingNewCount > 0 才渲染。 */
  @Builder
  PendingHeadline() {
    Row() {
      SymbolGlyph($r('sys.symbol.arrow_2_circlepath'))
        .fontSize($r('sys.float.Title_S'))
        .fontColor([$r('sys.color.icon_emphasize')])
      Text($r('app.string.sync_mutual_seen', this.syncState.pendingNewFrom, this.syncState.pendingNewCount))
        .fontSize($r('sys.float.Title_S'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .maxLines(1)
        .ellipsisMode(EllipsisMode.END)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ left: $r('sys.float.padding_level4') })
    }
    .alignItems(VerticalAlign.Center)
    .width(CommonConstants.FULL_PERCENT)
    .padding({ top: $r('sys.float.padding_level4'), bottom: $r('sys.float.padding_level2') })
  }

  /** 新装行（spec ③）：勾选框仅 pc_acl；行点击 pc_acl 切勾选、pc_normal 进详情。 */
  @Builder
  PendingRow(pkg: BrewSyncPackageDoc, index: number) {
    Row() {
      if (this.cliEnabled()) {
        SymbolGlyph(this.selected.has(pkg.identity()) ?
          $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.checkmark_circle'))
          .fontSize($r('sys.float.Title_M'))
          .fontColor([this.selected.has(pkg.identity()) ?
            $r('sys.color.interactive_active') : $r('sys.color.icon_tertiary')])
          .margin({ right: $r('sys.float.padding_level4') })
      }

      Column() {
        Text(pkg.token)
          .fontSize($r('sys.float.Body_M'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .ellipsisMode(EllipsisMode.END)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row() {
          Text(this.kindDescOf(pkg))
            .fontSize($r('sys.float.Body_S'))
            .fontColor($r('sys.color.font_tertiary'))
            .padding({
              left: $r('sys.float.padding_level4'),
              right: $r('sys.float.padding_level4'),
              top: 1,
              bottom: 1,
            })
            .borderRadius($r('sys.float.corner_radius_level2'))
            .backgroundColor($r('sys.color.comp_background_tertiary'))
          if (pkg.tap.length > 0) {
            Text(pkg.tap)
              .fontSize($r('sys.float.Body_S'))
              .fontColor($r('sys.color.font_secondary'))
              .maxLines(1)
              .ellipsisMode(EllipsisMode.END)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          Text(this.sourceNameOf(pkg))
            .fontSize($r('sys.float.Body_S'))
            .fontColor($r('sys.color.font_tertiary'))
            .maxLines(1)
            .ellipsisMode(EllipsisMode.END)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(VerticalAlign.Center)
        .margin({ top: $r('sys.float.padding_level2') })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ right: $r('sys.float.padding_level4') })

      this.StatusChip(pkg)
    }
    .alignItems(VerticalAlign.Center)
    .width(CommonConstants.FULL_PERCENT)
    .height($r('app.float.brew_package_row_height'))
    .padding({ left: $r('sys.float.padding_level6'), right: $r('sys.float.padding_level4') })
    .onClick(() => {
      if (this.cliEnabled()) {
        this.toggleSelect(pkg);
      } else {
        this.jumpDetail(pkg);
      }
    })
  }

  /** 行右状态 chip（仅 pc_acl）：队列无此条 = 待装；失败可点「重试」。 */
  @Builder
  StatusChip(pkg: BrewSyncPackageDoc) {
    if (this.cliEnabled()) {
      Row() {
        Text(this.statusTextOf(this.queueItemOf(pkg)))
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_tertiary'))
        if ((this.queueItemOf(pkg)?.status ?? '') === BrewQueueStatus.FAILED) {
          Text($r('app.string.sync_retry'))
            .fontSize($r('sys.float.Body_S'))
            .fontColor($r('sys.color.interactive_active'))
            .margin({ left: $r('sys.float.padding_level4') })
        }
      }
      .alignItems(VerticalAlign.Center)
      .padding({
        left: $r('sys.float.padding_level4'),
        right: $r('sys.float.padding_level4'),
        top: 1,
        bottom: 1,
      })
      .borderRadius($r('sys.float.corner_radius_level2'))
      .backgroundColor($r('sys.color.comp_background_tertiary'))
      .onClick(() => {
        const item: BrewQueueItem | undefined = this.queueItemOf(pkg);
        if (item !== undefined && item.status === BrewQueueStatus.FAILED) {
          this.queue.retry(item);
          this.queueTick++;
        }
      })
    }
  }

  /** ④ 批量安装条（pc_acl 且有勾选）与「查看进度」（队列活跃）——互斥出现。 */
  @Builder
  ActionRow() {
    Row() {
      if (this.cliEnabled() && this.selected.size > 0) {
        Button($r('app.string.sync_install_selected', this.selected.size))
          .width(BREW_SYNC_ACTION_WIDTH)
          .constraintSize({ maxWidth: BREW_ACTION_BUTTON_MAX_WIDTH })
          .height(BREW_ACTION_BUTTON_HEIGHT)
          .type(ButtonType.ROUNDED_RECTANGLE)
          .fontSize($r('sys.float.Body_L'))
          .fontWeight(FontWeight.Medium)
          .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
          .fontColor($r('sys.color.font_on_primary'))
          .onClick(() => {
            this.enqueueSelected();
          })
      } else if (this.cliEnabled() && (this.queue.isRunning() || this.queue.pendingCount() > 0)) {
        Button($r('app.string.sync_view_progress'))
          .width(BREW_SYNC_ACTION_WIDTH)
          .constraintSize({ maxWidth: BREW_ACTION_BUTTON_MAX_WIDTH })
          .height(BREW_ACTION_BUTTON_HEIGHT)
          .type(ButtonType.ROUNDED_RECTANGLE)
          .fontSize($r('sys.float.Body_L'))
          .fontWeight(FontWeight.Medium)
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          .fontColor($r('sys.color.font_primary'))
          .onClick(() => {
            this.viewProgress();
          })
      }
    }
    .justifyContent(FlexAlign.Center)
    .width(CommonConstants.FULL_PERCENT)
    .padding({ top: $r('sys.float.padding_level2'), bottom: $r('sys.float.padding_level2') })
  }

  /** 空态提示：无组网设备 / 有设备但无新增。 */
  @Builder
  EmptyHint() {
    if (this.syncState.devices.length === 0) {
      Text($r('app.string.sync_empty_no_devices'))
        .fontSize($r('sys.float.Body_M'))
        .fontColor($r('sys.color.font_tertiary'))
        .width(CommonConstants.FULL_PERCENT)
        .textAlign(TextAlign.Center)
        .padding({
          top: $r('sys.float.padding_level8'),
          bottom: $r('sys.float.padding_level8'),
        })
    } else if (this.syncState.pendingNewCount === 0) {
      Text($r('app.string.sync_empty_no_pending'))
        .fontSize($r('sys.float.Body_M'))
        .fontColor($r('sys.color.font_tertiary'))
        .width(CommonConstants.FULL_PERCENT)
        .textAlign(TextAlign.Center)
        .padding({ top: $r('sys.float.padding_level4'), bottom: $r('sys.float.padding_level2') })
    }
  }

  /** F6：schema 过新的远端设备占位行（其余设备卡照常渲染）。 */
  @Builder
  SchemaTooNewRow(entry: BrewSyncDeviceEntry) {
    if (entry.schemaTooNew) {
      Row() {
        SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
          .fontSize($r('sys.float.Title_S'))
          .fontColor([$r('sys.color.icon_secondary')])
          .margin({ right: $r('sys.float.padding_level4') })
        Text($r('app.string.sync_schema_too_new'))
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('sys.color.font_secondary'))
      }
      .alignItems(VerticalAlign.Center)
      .width(CommonConstants.FULL_PERCENT)
      .padding({ top: $r('sys.float.padding_level4'), bottom: $r('sys.float.padding_level4') })
    }
  }

  /** ⑥ 底部行：未授权时整行换成授权引导；授权后「立即同步 + 上次同步」。 */
  @Builder
  BottomRow() {
    if (this.syncState.available && !this.syncState.permissionGranted) {
      Row() {
        Text($r('app.string.sync_permission_row'))
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('sys.color.font_secondary'))
          .layoutWeight(1)
        Button($r('app.string.sync_permission_go'))
          .height(BREW_ACTION_BUTTON_HEIGHT)
          .type(ButtonType.ROUNDED_RECTANGLE)
          .fontSize($r('sys.float.Body_M'))
          .fontWeight(FontWeight.Medium)
          .backgroundColor($r('sys.color.ohos_id_color_emphasize'))
          .fontColor($r('sys.color.font_on_primary'))
          .padding({ left: $r('sys.float.padding_level8'), right: $r('sys.float.padding_level8') })
          .onClick(() => {
            this.authorize();
          })
      }
      .alignItems(VerticalAlign.Center)
      .width(CommonConstants.FULL_PERCENT)
      .padding({
        top: $r('sys.float.padding_level4'),
        bottom: $r('sys.float.padding_level4'),
        left: $r('sys.float.padding_level6'),
        right: $r('sys.float.padding_level6'),
      })
      .borderRadius($r('sys.float.corner_radius_level8'))
      .backgroundColor($r('sys.color.comp_background_tertiary'))
    } else if (this.syncState.available) {
      Row() {
        if (this.syncState.syncing) {
          LoadingProgress()
            .width(16)
            .height(16)
            .margin({ right: $r('sys.float.padding_level2') })
        }
        Text($r('app.string.sync_sync_now'))
          .fontSize($r('sys.float.Body_M'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.interactive_active'))
        Blank()
        if (this.lastSyncText().length > 0) {
          Text(this.lastSyncFailed() ?
            $r('app.string.sync_last_failed', this.lastSyncText()) :
            $r('app.string.sync_last_at', this.lastSyncText()))
            .fontSize($r('sys.float.Body_S'))
            .fontColor($r('sys.color.font_tertiary'))
            .maxLines(1)
            .ellipsisMode(EllipsisMode.END)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(VerticalAlign.Center)
      .width(CommonConstants.FULL_PERCENT)
      .height(BREW_ACTION_BUTTON_HEIGHT)
      .padding({
        left: $r('sys.float.padding_level6'),
        right: $r('sys.float.padding_level6'),
        top: $r('sys.float.padding_level4'),
        bottom: $r('sys.float.padding_level4'),
      })
      .borderRadius($r('sys.float.corner_radius_level8'))
      .backgroundColor($r('sys.color.comp_background_tertiary'))
      .onClick(() => {
        this.syncNow();
      })
    }
  }

  @Builder
  ContentBody() {
    Column({ space: CommonConstants.SPACE_12 }) {
      if (this.syncState.initialized && !this.syncState.available) {
        // F1：同步库没开成，整页降级（侧边栏入口不出现，常驻页给失败行）。
        Text($r('app.string.sync_kv_unavailable'))
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('sys.color.font_secondary'))
          .width(CommonConstants.FULL_PERCENT)
          .textAlign(TextAlign.Center)
          .padding({
            top: $r('sys.float.padding_level8'),
            bottom: $r('sys.float.padding_level8'),
          })
      } else if (this.syncState.available) {
        if (this.syncState.pendingNewCount > 0) {
          this.PendingHeadline()
          ForEach(this.syncState.pendingNew, (pkg: BrewSyncPackageDoc, index: number) => {
            this.PendingRow(pkg, index)
          }, (pkg: BrewSyncPackageDoc, index: number) => `${pkg.identity()}#${index}#${this.queueTick}`)
          this.ActionRow()
        }
        this.EmptyHint()
        ForEach(this.syncState.devices, (entry: BrewSyncDeviceEntry) => {
          this.SchemaTooNewRow(entry)
          if (!entry.schemaTooNew) {
            BrewManifestDeviceCard({
              packages: entry.packages,
              deviceName: entry.deviceName,
              itemCount: entry.packages.length,
              isSelf: entry.isSelf,
              handlePackageClick: (pkg: BrewSyncPackageDoc): void => {
                this.jumpDetail(pkg);
              },
              handleViewAll: (): void => {
                this.openDevicePage(entry);
              },
            })
          }
        }, (entry: BrewSyncDeviceEntry) => `${entry.deviceId}#${entry.updatedAt}`)
        this.BottomRow()
      }
    }
    .width(CommonConstants.FULL_PERCENT)
    .padding({
      left: $r('sys.float.padding_level8'),
      right: $r('sys.float.padding_level8'),
      top: $r('sys.float.padding_level4'),
      bottom: this.contentBottomInset(),
    })
  }

  build() {
    Column() {
      if (this.sheetMode) {
        this.TitleBar()
        Divider()
          .strokeWidth('1px')
          .color($r('sys.color.comp_background_tertiary'))
      }
      Scroll(this.scroller) {
        this.ContentBody()
      }
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .width(CommonConstants.FULL_PERCENT)
      .layoutWeight(1)
    }
    .width(CommonConstants.FULL_PERCENT)
    .height(CommonConstants.FULL_PERCENT)
  }
}
