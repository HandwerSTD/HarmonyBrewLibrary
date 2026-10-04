/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import type { BusinessError } from '@kit.BasicServicesKit';
import { LoadingStatus, Logger, PageContext, PageEnum, RequestErrorCode, StorageKey } from '@ohos/common';
import { BrewDiscoverModel, BrewFormat, BrewTable } from '@ohos/brewcommon';
import type { BrewDetailParams, BrewDiscoverBoard, BrewDiscoverEntry, BrewDiscoverPageData } from '@ohos/brewcommon';
import { BrewDiscoverBoardState } from './BrewDiscoverBoardState';

const TAG: string = '[BrewDiscoverBoardVM]';

/**
 * 榜单二级页 ViewModel。
 *
 * **无状态**：state 由页面自己 `new` 并通过参数传进来。
 * 这是详情页踩过的坑（docs §10.4.1）：把「每页实例」的状态放进共享单例，
 * 叠第二个同类页面时会互相覆盖 —— 返回时画面不变、返回键失效。
 * 本页虽然目前不会叠在自己上面，但同类页面已经吃过一次亏，一律照此办理。
 */
export class BrewDiscoverBoardVM {
  private static instance: BrewDiscoverBoardVM;
  private discoverModel: BrewDiscoverModel = BrewDiscoverModel.getInstance();

  private constructor() {
  }

  public static getInstance(): BrewDiscoverBoardVM {
    if (!BrewDiscoverBoardVM.instance) {
      BrewDiscoverBoardVM.instance = new BrewDiscoverBoardVM();
    }
    return BrewDiscoverBoardVM.instance;
  }

  /**
   * 按 id 取整张榜。
   *
   * 不新增端点、不发请求：数据全部来自包表（`brew_table` 的 `boards` 一半）。
   */
  public load(boardId: number, state: BrewDiscoverBoardState): void {
    state.boardId = boardId;
    const tableState: string = BrewTable.state();
    Logger.debug(TAG, `[load] 榜单二级页构建开始 boardId=${boardId} tableState=${tableState}`);
    state.loadingModel.loadingStatus = tableState === 'building' ? LoadingStatus.BUILDING :
      (tableState === 'ready' ? LoadingStatus.LOADING : LoadingStatus.EMPTY_DATA);
    this.discoverModel.getDiscoverPage()
      .then((data: BrewDiscoverPageData) => {
        const boards: BrewDiscoverBoard[] = data.boards ?? [];
        state.snapshotDate = data.snapshotDate ?? '';
        state.board = boards.find((item: BrewDiscoverBoard) => item.id === boardId);
        if (tableState !== 'ready') {
          state.loadingModel.loadingStatus = tableState === 'building' ?
            LoadingStatus.BUILDING : LoadingStatus.EMPTY_DATA;
          Logger.info(TAG, `board ${boardId} waiting, table state=${tableState}`);
          return;
        }
        // 骨架恒为 6 张榜，所以 `board` 一定找得到；找不到就是数据真的不对，给失败态
        state.loadingModel.loadingStatus = state.board ? LoadingStatus.SUCCESS : LoadingStatus.FAILED;
        Logger.info(TAG, `load board ${boardId}: ${state.board?.entryCount ?? 0} entries ` +
          `kind=${state.board?.kind ?? '?'}/${state.board?.boardKey ?? '?'} | ${BrewTable.statsLine()}`);
      })
      .catch((error: BusinessError) => {
        state.loadingModel.loadingStatus =
          error.code === RequestErrorCode.NETWORK_CONNECT_FAILED ? LoadingStatus.NO_NETWORK : LoadingStatus.FAILED;
        Logger.error(TAG, `load board ${boardId} failed: ${error.code} ${error.message}`);
      });
  }

  /** 重试按钮：强制重取两片，再重载本页 */
  public retry(boardId: number, state: BrewDiscoverBoardState): void {
    this.load(boardId, state);
    BrewTable.refresh(true).then(() => {
      this.load(boardId, state);
    });
  }

  public jumpDetail(entry: BrewDiscoverEntry, kind: string): void {
    if (!entry.id) {
      return;
    }
    const param: BrewDetailParams = {
      kind: BrewFormat.brewKindOf(kind),
      title: entry.token,
      id: entry.id,
      token: entry.token,
      categoryKey: entry.categoryKey,
    };
    const context: PageContext | undefined = AppStorage.get<boolean>(StorageKey.IS_SIDEBAR_LAYOUT) ?
      AppStorage.get<PageContext>(StorageKey.BREW_DISCOVER_PAGE_CONTEXT) :
      AppStorage.get<PageContext>(StorageKey.HOME_PAGE_CONTEXT);
    context?.openPage({
      routerName: PageEnum.BREW_DETAIL_VIEW,
      param: param,
    }, true);
  }
}
