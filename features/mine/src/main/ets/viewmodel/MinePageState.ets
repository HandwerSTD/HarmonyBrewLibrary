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

import { ObservedArray } from '@ohos/common';
import { BaseHomeState } from '@ohos/commonbusiness';
import type { BrewInstalledPackage } from '@ohos/brewcommon';

@Observed
export class MinePageState extends BaseHomeState {
  public listItemData: ListGroup[] = [];
  /** 已安装总数（Formulae + Casks），供「已安装」入口行显示数量 */
  public installedCount: number = 0;
  /** 有新版本可升级的包，卡片只取前几个做预览，点「查看全部」进子页面看完整列表 */
  public outdatedPackages: BrewInstalledPackage[] = [];
  /** 版本已是最新的包，同上 */
  public updatedPackages: BrewInstalledPackage[] = [];
  /**
   * 本机包是否还在读取。
   *
   * 读一次要拉起 brew（首次约 2–3 秒），期间三块内容还没有数据：
   * 不区分「还没读到」与「真的一个都没有」会把空态文案先闪一下。
   */
  public packagesLoading: boolean = false;
  public isLogin: boolean = false;
  public isShowAccountInfo: boolean = false;
  public nickName: string = '';
  public avatarUrl: string = '';
}

@Observed
export class ListGroup {
  public id: number = 0;
  public group: ObservedArray<MineItem> = [];
}

@Observed
export class MineItem {
  public textContent: ResourceStr = '';
  public subTextContent?: ResourceStr = '';
  public symbolSrc?: Resource = $r('sys.symbol.bell');
  public type: BuilderEnum = BuilderEnum.USER_EXPERIENCE_CARD;
  /** type 为 PACKAGE_CARD 时用：这张卡片展示待更新还是已更新 */
  public packageCardType?: PackageCardType = PackageCardType.OUTDATED;
  /** type 为 CARD_ITEM 时用：右侧是否显示「已安装数量」（数量在渲染时从 state 取） */
  public showInstalledCount?: boolean = false;
  /**
   * 条目归属的可选区块。
   *
   * 只有需要被开关控制的条目才写：渲染前 MinePageVM 会把开关关掉的区块整条剔除。
   * 不写（undefined）表示常显条目（登录卡、设置）。
   * 用**条目级**标记而不是按分组 id 过滤，是因为设置与「问题与建议」共用 id=6 那一组，
   * 按组过滤会连设置一起关掉。
   */
  public feature?: MineFeature = undefined;
  public builder?: WrappedBuilder<[]>;
  public onclick?: Function = () => {
  };
}

export enum BuilderEnum {
  USER_EXPERIENCE_CARD = 'UserExperienceCardItem',
  FEEDBACK_CARD = 'FeedBackCard',
  CARD_ITEM = 'CardItem',
  LOGIN_ITEM = 'LoginItem',
  /** 包预览大卡片（待更新 / 已更新） */
  PACKAGE_CARD = 'PackageCard'
}

/** PACKAGE_CARD 的数据来源 */
export enum PackageCardType {
  OUTDATED = 'Outdated',
  UPDATED = 'Updated'
}

/**
 * 「我的」页可选区块的归属标记，与 MinePageVM 里的 `isMineFeatureVisible` 判定一一对应。
 * 新增可下线区块时：这里加一项、VM 里加一条判定。
 */
export enum MineFeature {
  /** 本机包：已安装入口 + 待更新 / 已更新预览卡片 */
  LOCAL_PACKAGE = 'LocalPackage',
  /** 本机包提示卡：本机包管理能力未开启时指到开源仓库的完整版本 */
  LOCAL_PACKAGES_PROMO = 'LocalPackagesPromo',
  /** 问题与建议入口 */
  FEEDBACK = 'Feedback'
}