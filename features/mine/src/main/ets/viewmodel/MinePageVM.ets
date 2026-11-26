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

import type { common, Want } from '@kit.AbilityKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import {
  AccountService,
  CommonConstants,
  Logger,
  ObservedArray,
  PageContext,
  PageEnum,
  ProcessUtil,
  StorageKey,
  Toast,
  UserAccount,
} from '@ohos/common';
import { BaseHomeEventParam, BaseHomeEventType, BaseHomeViewModel } from '@ohos/commonbusiness';
import { BrewCli, BrewInstalledLoader } from '@ohos/brewcommon';
import type { BrewInstalledPackage } from '@ohos/brewcommon';
import { MineConstant } from '../constant/CommonConstants';
import { MineSettingBuilder } from '../view/MineSettingView';
import { MinePackagesUtil } from '../util/MinePackagesUtil';
import type { MinePackageSets } from '../model/MinePackagesModels';
import { PackageListMode } from '../model/MinePackagesModels';
import type { MinePackagesParams } from '../model/MinePackagesModels';
import type { MineItem } from './MinePageState';
import { BuilderEnum, ListGroup, MineFeature, MinePageState, PackageCardType } from './MinePageState';

const TAG: string = '[MinePageVM]';

/**
 * 「我的」页可选区块开关。
 *
 * 关掉只影响「是否出现在页面上」，条目定义、取数、子页面路由全部原样保留，
 * 需要展示时把对应开关置为 true 就能整块恢复。
 * 之所以不做成删代码/注释，是因为「问题与建议」是**阶段性下线**，后面还要按用户体验结论重新设计再上。
 */
/**
 * 本机包：已安装入口（含数量）+ 待更新 / 已更新预览卡片。
 * 显隐由 entry 在 `PcAbility.onCreate` 注入的 `StorageKey.BREW_CLI_ENABLED` 决定：
 * pc_acl 注入 true、pc_normal 注入 false；未注入时按 false 处理，此时入口不展示、也不发起取数。
 */
export function isLocalPackagesEnabled(): boolean {
  return AppStorage.get<boolean>(StorageKey.BREW_CLI_ENABLED) ?? false;
}
/**
 * 激活本机包管理提示卡：本机包管理能力未开启时（pc_normal）展示，点击打开开源仓库地址；
 * pc_acl 已经能用本机包，这张卡不出现。
 */
export function isLocalPackagesPromoVisible(): boolean {
  return !isLocalPackagesEnabled();
}
/**
 * brew 安装提示卡：能力已开启（pc_acl）但设备上找不到可用的 brew 时展示，点击打开 Harmonybrew 站点。
 *
 * `brewCliReady` 由 `MinePageVM` 在进入页面取数前刷新一次，不在本判定里现探：
 * 探测是同步的，而找不到 brew 的结果不进 `BrewCli` 的进程内缓存。
 */
export function isHarmonybrewInstallVisible(brewCliReady: boolean): boolean {
  return isLocalPackagesEnabled() && !brewCliReady;
}
/** 问题与建议入口 */
export const MINE_SHOW_FEEDBACK: boolean = false;

/** 某个可选区块当前是否展示。未登记的 feature 一律当常显。 */
export function isMineFeatureVisible(feature: MineFeature, brewCliReady: boolean): boolean {
  if (feature === MineFeature.LOCAL_PACKAGE) {
    // 设备上找不到 brew 时整块隐藏：三张卡片的内容都来自 brew 命令，没有命令就取不到数据，
    // 这一状态由「去安装 Harmonybrew」卡片承担提示
    return isLocalPackagesEnabled() && brewCliReady;
  }
  if (feature === MineFeature.LOCAL_PACKAGES_PROMO) {
    return isLocalPackagesPromoVisible();
  }
  if (feature === MineFeature.HARMONYBREW_INSTALL) {
    return isHarmonybrewInstallVisible(brewCliReady);
  }
  if (feature === MineFeature.FEEDBACK) {
    return MINE_SHOW_FEEDBACK;
  }
  return true;
}

export class MinePageVM extends BaseHomeViewModel<MinePageState> {
  private static instance: MinePageVM;
  public localPackagesPromoItem: MineItem = {
    textContent: $r('app.string.local_packages_promo_title'),
    subTextContent: $r('app.string.local_packages_promo_desc'),
    type: BuilderEnum.USER_EXPERIENCE_CARD,
    feature: MineFeature.LOCAL_PACKAGES_PROMO,
    onclick: () => {
      MinePageVM.getInstance().openUrl(MineConstant.REPO_URL);
    },
  };
  public harmonybrewInstallItem: MineItem = {
    textContent: $r('app.string.harmonybrew_install_title'),
    subTextContent: $r('app.string.harmonybrew_install_desc'),
    type: BuilderEnum.USER_EXPERIENCE_CARD,
    feature: MineFeature.HARMONYBREW_INSTALL,
    onclick: () => {
      MinePageVM.getInstance().openUrl(MineConstant.HARMONYBREW_URL);
    },
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
      group: [this.localPackagesPromoItem, this.harmonybrewInstallItem],
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
  /**
   * 快照更新回调。存成字段而不是在 `subscribe` 里现造一个箭头函数：
   * `BrewInstalledLoader` 按函数对象去重，两处传的不是同一个对象时会退订不掉、回调叠加。
   */
  private snapshotListener: () => void = () => {
    const snapshot = BrewInstalledLoader.snapshot();
    if (snapshot === null) {
      return;
    }
    this.applyLocalSets(snapshot.sets.installed, snapshot.sets.outdated, snapshot.sets.updated);
  };
  /**
   * 设备上有没有可用的 brew（能力开关打开、执行通道可用、候选路径里至少一个可执行）。
   *
   * 只在进入「我的」页取数前刷新：判定要走一次同步探测，而找不到 brew 的结果不进
   * `BrewCli` 的进程内缓存，放进渲染路径会让每次重建列表都重探一遍。
   * 初始取 true：pc_acl 首帧不会先闪一下安装提示卡。
   */
  private brewCliReady: boolean = true;

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
      // 能力开关关闭时不取数：loadSets() 会把全量本机包读一遍再排序，白跑一趟
      if (isLocalPackagesEnabled()) {
        this.loadLocalPackages();
      }
    } else if (eventType === MineEventType.REFRESH_LOCAL_PACKAGES) {
      this.refreshLocalPackages();
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
      item.feature === undefined || isMineFeatureVisible(item.feature, this.brewCliReady));
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

  /**
   * 刷新「设备上有没有可用的 brew」，供 brew 安装提示卡的显隐使用。
   *
   * 状态没变时不重建列表：`buildVisibleListGroups` 会为每个条目重新构造对象。
   */
  private refreshBrewCliReady(): void {
    const ready: boolean = BrewCli.isReady();
    // 刷新按钮的显隐依据，与下面「要不要重建列表」是两件事：能力开关会在会话中变化
    // （设备上装了 brew 之后 `isReady()` 会变成真），而列表只有在真的重建时才会跟着换。
    this.state.localPackagesReady = isLocalPackagesEnabled() && ready;
    if (ready === this.brewCliReady) {
      return;
    }
    this.brewCliReady = ready;
    this.state.listItemData = this.buildVisibleListGroups();
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
   * 快照优先（spec §6.4）：有快照时先用它赋值、收起加载态，页面不空着等命令；
   * 随后仍然走一次 `loadSets()` —— 新鲜窗口内它立刻返回快照不执行命令，超窗时它在后台刷新。
   * 订阅快照更新是为了后台刷新成功（或写命令结束后的刷新）时三块内容跟着变，
   * 本 VM 是进程内单例、回调只做一次取值与赋值，不退订也不会累积。
   *
   * 失败只记日志、不改成错误态：整页是账号/调研/公告/设置等混合内容，
   * 本机包只是其中三块，不该因为它们读不到就让整个「我的」页变成错误页。
   */
  private loadLocalPackages(): void {
    this.refreshBrewCliReady();
    BrewInstalledLoader.subscribe(this.snapshotListener);
    const snapshot = BrewInstalledLoader.snapshot();
    if (snapshot !== null) {
      this.applyLocalSets(snapshot.sets.installed, snapshot.sets.outdated, snapshot.sets.updated);
    } else {
      this.state.packagesLoading = true;
    }

    MinePackagesUtil.loadSets()
      .then((sets: MinePackageSets) => {
        this.applyLocalSets(sets.installed, sets.outdated, sets.updated);
      })
      .catch((error: BusinessError) => {
        this.state.installedCount = 0;
        this.state.outdatedPackages = [];
        this.state.updatedPackages = [];
        this.state.packagesLoading = false;
        Logger.error(TAG, `loadLocalPackages failed. ${error.code} ${error.message}`);
      });
  }

  /**
   * 顶部刷新按钮：跳过新鲜窗口，立即重跑一次本机包读取，并把结果填回三块内容。
   *
   * 失败时保留页面上已有的数量与两张卡片：用户点的是一次刷新，不该把已经看到的内容清空。
   * 失败以 Toast 告知；原因进日志。能力关闭时直接返回 —— 那种环境下 `loadSets` 返回空集合，
   * 刷一下会把三块内容刷成空。
   */
  private refreshLocalPackages(): void {
    if (this.state.packagesRefreshing || !isLocalPackagesEnabled()) {
      return;
    }
    this.state.packagesRefreshing = true;
    Logger.info(TAG, 'refreshLocalPackages start');
    MinePackagesUtil.loadSets(true)
      .then((sets: MinePackageSets) => {
        this.applyLocalSets(sets.installed, sets.outdated, sets.updated);
        Logger.info(TAG, `refreshLocalPackages success, installed=${sets.installed.length}`);
        this.state.packagesRefreshing = false;
      })
      .catch((error: BusinessError) => {
        Logger.error(TAG, `refreshLocalPackages failed. ${error.code} ${error.message}`);
        Toast.showToast($r('app.string.mine_refresh_failed'));
        this.state.packagesRefreshing = false;
      });
  }

  /**
   * 三个集合落到状态上。只写一级属性 —— 状态管理 V1 只观察第一层，
   * 与子页面 `MinePackagesVM.applySets` 同一个写法。
   */
  private applyLocalSets(installed: BrewInstalledPackage[], outdated: BrewInstalledPackage[],
    updated: BrewInstalledPackage[]): void {
    this.state.installedCount = installed.length;
    // F 线：待更新预览卡与「待更新」子页同一份置顶口径 —— 关注中的包排最前面，
    // 「优先提醒」在首页预览与二级列表上表现一致（两边共用 prioritizeFollowed）。
    this.state.outdatedPackages = MinePackagesUtil.prioritizeFollowed(outdated);
    this.state.updatedPackages = updated;
    this.state.packagesLoading = false;
  }

  private jumpToPackagesPage(mode: PackageListMode): void {
    this.packagePageContext()?.openPage({
      routerName: PageEnum.MINE_PACKAGES_VIEW,
      param: { mode: mode } as MinePackagesParams,
    }, true);
  }

  /**
   * 本机包行 -> 详情页。路由参数收在 `MinePackagesUtil.detailParamsOf`，与「本机包」二级页共用；
   * 页面上下文与「查看全部」相同（两个入口都在「我的」页上）。
   */
  public jumpToPackageDetail(pkg: BrewInstalledPackage): void {
    this.packagePageContext()?.openPage({
      routerName: PageEnum.BREW_DETAIL_VIEW,
      param: MinePackagesUtil.detailParamsOf(pkg),
    }, true);
  }

  /** 「我的」相关二级页用哪条导航路径。侧边栏布局下「我的」有自己的一条，其余布局共用首页那条 */
  private packagePageContext(): PageContext | undefined {
    return AppStorage.get<boolean>(StorageKey.IS_SIDEBAR_LAYOUT) ?
      AppStorage.get<PageContext>(StorageKey.MINE_PAGE_CONTEXT) :
      AppStorage.get<PageContext>(StorageKey.HOME_PAGE_CONTEXT);
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

  /** 打开外部地址。宿主上下文取不到时只记日志，不弹错误提示 */
  private openUrl(url: string): void {
    const uiContext = AppStorage.get<UIContext>(StorageKey.UI_CONTEXT);
    const hostContext = uiContext?.getHostContext();
    if (!hostContext) {
      Logger.error(TAG, `open url failed, cause uiContext or context is undefined. url=${url}`);
      return;
    }
    const want: Want = {
      action: 'ohos.want.action.viewData',
      entities: ['entity.system.browsable'],
      uri: url,
    };
    ProcessUtil.startAbility(hostContext as common.UIAbilityContext, want);
  }
}

export enum MineEventType {
  INIT_DATA = 'initData',
  LOAD_LOCAL_PACKAGES = 'loadLocalPackages',
  REFRESH_LOCAL_PACKAGES = 'refreshLocalPackages',
  LOGIN = 'login',
  LOGOUT = 'logout',
  UPDATE_ACCOUNT_DATA = 'updateAccountData',
  JUMP_TO_MINE_SETTINGS = 'jumpToMineSettings',
}

export interface MineEventParam<T> {
  type: MineEventType | BaseHomeEventType;
  param?: T;
}