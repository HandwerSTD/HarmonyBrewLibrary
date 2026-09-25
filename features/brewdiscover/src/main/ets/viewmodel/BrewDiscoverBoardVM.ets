/*
 * Copyright (c) 2025 Huawei Device Co., Ltd.
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

import type { BusinessError } from '@kit.BasicServicesKit';
import { LoadingStatus, Logger, PageContext, PageEnum, RequestErrorCode, StorageKey } from '@ohos/common';
import { BrewDiscoverModel, BrewFormat } from '@ohos/brewcommon';
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
   * 不新增端点：首页已经把这 6 张榜整份加载并写进 Preference 缓存，
   * 这里再取一次是命中缓存（比把整张榜当路由参数穿过页面栈稳）。
   */
  public load(boardId: number, state: BrewDiscoverBoardState): void {
    state.boardId = boardId;
    state.loadingModel.loadingStatus = LoadingStatus.LOADING;
    this.discoverModel.getDiscoverPage()
      .then((data: BrewDiscoverPageData) => {
        const boards: BrewDiscoverBoard[] = data.boards ?? [];
        state.snapshotDate = data.snapshotDate ?? '';
        state.board = boards.find((item: BrewDiscoverBoard) => item.id === boardId);
        state.loadingModel.loadingStatus = state.board ? LoadingStatus.SUCCESS : LoadingStatus.FAILED;
        Logger.info(TAG, `load board ${boardId}: ${state.board?.entryCount ?? 0} entries`);
      })
      .catch((error: BusinessError) => {
        state.loadingModel.loadingStatus =
          error.code === RequestErrorCode.NETWORK_CONNECT_FAILED ? LoadingStatus.NO_NETWORK : LoadingStatus.FAILED;
        Logger.error(TAG, `load board ${boardId} failed: ${error.code} ${error.message}`);
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
