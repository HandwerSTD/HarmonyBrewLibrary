/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { BrewManifestSyncService, BrewManifestSyncView } from '@ohos/brewcommon';

/**
 * W′ 工具清单同步的常驻页（spec §4.3）：薄壳——标题栏 + 同一份 BrewManifestSyncView
 * （sheetMode=false，与侧边栏拉起的 Sheet 共用全部内容；Sheet 形态宿主在 PcMainPage 的
 * HdsSideBar 节点上）。MineSettingView「工具清单同步」行进入。
 *
 * 首次打开申请 DISTRIBUTED_DATASYNC 动态权限：init 时不弹窗（不打扰启动），
 * 未授权时这里补弹；授权成功后服务内部补跑本机身份解析 + refresh + sync。
 */
@Component
export struct BrewManifestSyncPage {

  aboutToAppear(): void {
    const service: BrewManifestSyncService = BrewManifestSyncService.getInstance();
    if (BrewManifestSyncService.hasDatasyncPermission()) {
      return;
    }
    const context: Context | undefined = this.getUIContext().getHostContext();
    if (context !== undefined) {
      service.requestDatasyncPermission(context);
    }
  }

  build() {
    NavDestination() {
      Column() {
        BrewManifestSyncView({ sheetMode: false })
      }
      .width('100%')
      .height('100%')
    }
    .title($r('app.string.sync_sheet_title'))
    .backgroundColor($r('sys.color.background_secondary'))
  }
}

@Builder
export function BrewManifestSyncPageBuilder() {
  BrewManifestSyncPage()
}
