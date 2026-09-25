/*
 * Copyright (c) 2024 Huawei Device Co., Ltd.
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

import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import {
  AccountService,
  CommonConstants,
  Logger,
  ObservedArray,
  PageContext,
  PageEnum,
  StorageKey,
  Toast,
  UserAccount,
} from '@ohos/common';
import { BaseHomeEventParam, BaseHomeEventType, BaseHomeViewModel } from '@ohos/commonbusiness';
import { MineSettingBuilder } from '../view/MineSettingView';
import { MinePackagesUtil } from '../util/MinePackagesUtil';
import type { MinePackageSets } from '../model/MinePackagesModels';
import { PackageListMode } from '../model/MinePackagesModels';
import type { MinePackagesParams } from '../model/MinePackagesModels';
import type { MineItem } from './MinePageState';
import { BuilderEnum, ListGroup, MineFeature, MinePageState, PackageCardType } from './MinePageState';
import { QuestionnaireViewBuilder } from '../view/QuestionnaireView';

const TAG: string = '[MinePageVM]';

/**
 * 「我的」页可选区块开关。
 *
 * 关掉只影响「是否出现在页面上」，条目定义、取数、子页面路由全部原样保留：
 * 把对应常量改回 true 就能整块恢复，不需要回滚代码。
 * 之所以不做成删代码/注释，是因为这三块都是**阶段性下线**，后面还要按用户体验结论重新设计再上。
 */
/** 本机包：已安装入口（含数量）+ 待更新 / 已更新预览卡片 */
export const MINE_SHOW_LOCAL_PACKAGES: boolean = false;
/** 用户体验调研卡片 */
export const MINE_SHOW_USER_EXPERIENCE: boolean = false;
/** 问题与建议入口 */
export const MINE_SHOW_FEEDBACK: boolean = false;

/** 某个可选区块当前是否展示。未登记的 feature 一律当常显。 */
export function isMineFeatureVisible(feature: MineFeature): boolean {
  if (feature === MineFeature.LOCAL_PACKAGE) {
    return MINE_SHOW_LOCAL_PACKAGES;
  }
  if (feature === MineFeature.USER_EXPERIENCE) {
    return MINE_SHOW_USER_EXPERIENCE;
  }
  if (feature === MineFeature.FEEDBACK) {
    return MINE_SHOW_FEEDBACK;
  }
  return true;
}

export class MinePageVM extends BaseHomeViewModel<MinePageState> {
  private static instance: MinePageVM;
  public userExperienceMineItem: MineItem = {
    textContent: $r('app.string.user_experience'),
    subTextContent: $r('app.string.user_experience_tips'),
    symbolSrc: $r('app.media.userExperience'),
    type: BuilderEnum.USER_EXPERIENCE_CARD,
    feature: MineFeature.USER_EXPERIENCE,
    builder: wrapBuilder(QuestionnaireViewBuilder),
  };
  public listGroupData: ListGroup[] = [
    {
      id: 0,
      group: [
        {
          textContent: '',
          type: BuilderEnum.LOGIN_ITEM,
        } as MineItem
      ]
    },
    {
      id: 1,
      group: [this.userExperienceMineItem],
    },
    {
      id: 2,
      group: [
        {
          textContent: $r('app.string.mine_installed'),
          symbolSrc: $r('sys.symbol.archivebox'),
          type: BuilderEnum.CARD_ITEM,
          feature: MineFeature.LOCAL_PACKAGE,
          // 数量在渲染时从 state 取：listGroupData 是静态字段，而数量是异步加载的
          showInstalledCount: true,
          onclick: () => {
            MinePageVM.getInstance().jumpToPackagesPage(PackageListMode.ALL);
          },
        } as MineItem
      ]
    },
    {
      id: 4,
      group: [
        {
          textContent: $r('app.string.mine_outdated'),
          symbolSrc: $r('sys.symbol.bolt'),
          type: BuilderEnum.PACKAGE_CARD,
          feature: MineFeature.LOCAL_PACKAGE,
          packageCardType: PackageCardType.OUTDATED,
          onclick: () => {
            MinePageVM.getInstance().jumpToPackagesPage(PackageListMode.OUTDATED);
          },
        } as MineItem
      ]
    },
    {
      id: 5,
      group: [
        {
          textContent: $r('app.string.mine_updated'),
          symbolSrc: $r('sys.symbol.checkmark_circle'),
          type: BuilderEnum.PACKAGE_CARD,
          feature: MineFeature.LOCAL_PACKAGE,
          packageCardType: PackageCardType.UPDATED,
          onclick: () => {
            MinePageVM.getInstance().jumpToPackagesPage(PackageListMode.UPDATED);
          },
        } as MineItem
      ]
    },
    {
      id: 6,
      group: [
        {
          textContent: $r('app.string.setting'),
          symbolSrc: $r('sys.symbol.gearshape'),
          type: BuilderEnum.CARD_ITEM,
          builder: wrapBuilder(MineSettingBuilder),
        } as MineItem,
        {
          textContent: $r('app.string.feedback'),
          symbolSrc: $r('sys.symbol.questionmark_circle'),
          type: BuilderEnum.FEEDBACK_CARD,
          feature: MineFeature.FEEDBACK,
          onclick: () => {
            Toast.showToast($r('app.string.feedback_desc'));
          },
        } as MineItem
      ]
    }
  ]
  private accountServiceIns: AccountService = AccountService.getInstance();

  private constructor() {
    super(new MinePageState());
  }

  public static getInstance() {
    if (!MinePageVM.instance) {
      MinePageVM.instance = new MinePageVM();
    }
    return MinePageVM.instance;
  }

  public sendEvent<T>(event: MineEventParam<T>): void | boolean {
    const eventType: MineEventType | BaseHomeEventType = event.type;
    if (eventType === MineEventType.LOAD_LOCAL_PACKAGES) {
      // 本机包三块关掉时不取数：loadSets() 会把全量本机包读一遍再排序，白跑一趟
      if (MINE_SHOW_LOCAL_PACKAGES) {
        this.loadLocalPackages();
      }
    } else if (eventType === MineEventType.INIT_DATA) {
      this.assignData();
    } else if (eventType === MineEventType.LOGIN) {
      this.login();
    } else if (eventType === MineEventType.LOGOUT) {
      this.displayLogoutView();
    } else if (eventType === MineEventType.UPDATE_ACCOUNT_DATA) {
      this.updateAccountData();
    } else if (eventType === MineEventType.JUMP_TO_MINE_SETTINGS) {
      this.jumpToMineSettings();
    } else {
      return super.sendEvent<T>(event as BaseHomeEventParam<T>);
    }
  }

  private assignData(): void {
    this.state.listItemData = this.buildVisibleListGroups();
    this.updateAccountData();
  }

  /**
   * 按区块开关过滤出真正要渲染的分组。
   *
   * 每回都从静态的 listGroupData 重新算，返回全新对象 —— INIT_DATA 可能来多次，
   * 就地删条目会让第二次过滤作用在已删过的数组上，越删越少。
   * 分组被清空则整组丢掉：空组建不出任何条目，只会渲染成一个只有 padding 的空白圆角块。
   */
  private buildVisibleListGroups(): ListGroup[] {
    const visibleGroups: ListGroup[] = [];
    this.listGroupData.forEach((group: ListGroup) => {
      const visibleItems: MineItem[] = group.group.filter((item: MineItem) =>
      item.feature === undefined || isMineFeatureVisible(item.feature));
      if (visibleItems.length === 0) {
        return;
      }
      const visibleGroup: ListGroup = new ListGroup();
      visibleGroup.id = group.id;
      visibleGroup.group = new ObservedArray<MineItem>(visibleItems);
      visibleGroups.push(visibleGroup);
    });
    return visibleGroups;
  }

  private updateAccountData(): void {
    // close account confirmation dialog
    this.state.isShowAccountInfo = false;
    const userInfo = this.accountServiceIns.getUserInfo();
    const isLogin = this.accountServiceIns.isUserLogin();
    if (isLogin && userInfo) {
      this.state.avatarUrl = userInfo.avatarUrl;
      this.state.nickName = userInfo.nickname;
      this.state.isLogin = true;
    } else {
      this.state.avatarUrl = '';
      this.state.nickName = '';
      this.state.isLogin = false;
    }
  }

  /**
   * 加载本机包。「我的」页只用到总数与两份预览，完整列表由子页面自己再取一次 ——
   * 取数口径两处共用 MinePackagesUtil，不会出现「预览的首项与查看全部的首项不一致」。
   *
   * 失败只记日志、不改成错误态：整页是账号/调研/公告/设置等混合内容，
   * 本机包只是其中三块，不该因为它们读不到就让整个「我的」页变成错误页。
   */
  private loadLocalPackages(): void {
    MinePackagesUtil.loadSets()
      .then((sets: MinePackageSets) => {
        this.state.installedCount = sets.installed.length;
        this.state.outdatedPackages = sets.outdated;
        this.state.updatedPackages = sets.updated;
      })
      .catch((error: BusinessError) => {
        this.state.installedCount = 0;
        this.state.outdatedPackages = [];
        this.state.updatedPackages = [];
        Logger.error(TAG, `loadLocalPackages failed. ${error.code} ${error.message}`);
      });
  }

  private jumpToPackagesPage(mode: PackageListMode): void {
    const pageContext: PageContext | undefined = AppStorage.get<boolean>(StorageKey.IS_SIDEBAR_LAYOUT) ?
      AppStorage.get<PageContext>(StorageKey.MINE_PAGE_CONTEXT) :
      AppStorage.get<PageContext>(StorageKey.HOME_PAGE_CONTEXT);
    pageContext?.openPage({
      routerName: PageEnum.MINE_PACKAGES_VIEW,
      param: { mode: mode } as MinePackagesParams,
    }, true);
  }

  private login(): void {
    const uiContext = AppStorage.get<UIContext>(StorageKey.UI_CONTEXT);
    if (!uiContext) {
      Logger.error(TAG, `login failed, cause uiContext or context is undefined.`);
      return;
    }
    this.accountServiceIns.login(uiContext)
      .then((userAccount: UserAccount) => {
        if (userAccount) {
          this.state.avatarUrl = userAccount.avatarUrl;
          this.state.nickName = userAccount.nickname;
          // Display account confirmation dialog
          this.state.isShowAccountInfo = true;
        }
      })
      .catch((err: BusinessError) => {
        Logger.error(TAG, ` AccountService.getInstance().login failed. Cause: message ${err.message}`);
      });
  }

  private displayLogoutView(): void {
    this.state.isShowAccountInfo = true;
  }

  private jumpToMineSettings(): void {
    let pageContext: PageContext;
    if (deviceInfo.deviceType === CommonConstants.TV_DEVICE_TYPE ||
      AppStorage.get<boolean>(StorageKey.IS_SIDEBAR_LAYOUT)) {
      pageContext = AppStorage.get<PageContext>(StorageKey.HOME_PAGE_CONTEXT) as PageContext;
    } else {
      pageContext = AppStorage.get<PageContext>(StorageKey.MINE_PAGE_CONTEXT) as PageContext;
    }
    pageContext.openPage({
      routerName: PageEnum.MINE_SETTING_VIEW,
    })
  }
}

export enum MineEventType {
  INIT_DATA = 'initData',
  LOAD_LOCAL_PACKAGES = 'loadLocalPackages',
  LOGIN = 'login',
  LOGOUT = 'logout',
  UPDATE_ACCOUNT_DATA = 'updateAccountData',
  JUMP_TO_MINE_SETTINGS = 'jumpToMineSettings',
}

export interface MineEventParam<T> {
  type: MineEventType | BaseHomeEventType;
  param?: T;
}