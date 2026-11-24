/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { LoadingModel } from '@ohos/common';
import {
  BrewInfoPageData,
  BrewKind,
  BrewPackageItem,
  ReleaseIntelArchiveEntry,
  ReleaseIntelSnapshot,
  TldrPage,
} from '@ohos/brewcommon';
import type { BrewDetailParams } from '@ohos/brewcommon';

/**
 * 详情页的安装状态（spec §6.5）。取值来自已安装列表快照。
 *
 * `UNKNOWN` 与 `NOT_INSTALLED` 的按钮文案都是「安装」：此时点下去执行 `brew install`，
 * 包其实已装时 brew 会打印 `Warning: ... is already installed`，结果同样进执行 Sheet，
 * 不会造成损坏。把这两种情况分开只是为了让日志能看清「快照还没有」与「快照里确实没有」。
 */
export enum BrewInstallState {
  /** 还没有快照（冷启动首次读取中），或读取失败 */
  UNKNOWN = 'unknown',
  NOT_INSTALLED = 'not_installed',
  INSTALLED = 'installed',
  OUTDATED = 'outdated',
}

/**
 * 详情页状态。不加 @Observed —— @State 会观察所持对象的**一级属性**赋值，
 * 因此下面每个字段都在一级，包括 `siblings`。
 *
 * `siblings` 特意**不放在** `BrewInfoPageData` 里：它与主详情是两个独立请求
 * （详情接口不返回同类包，需要另外读首页数据），如果嵌在 `data` 内部，
 * 后续单独赋值不会触发刷新（@State 只观察一级属性）。
 *
 * `loadingModel` 同样受这个约束：VM 不写 `loadingModel.loadingStatus`，
 * 而是用 `new LoadingModel(status)` 整体替换这个一级字段（见 `BrewDetailViewModel.setStatus`）。
 */
export class BrewDetailState {
  public loadingModel: LoadingModel = new LoadingModel();
  public pathStack?: NavPathStack;
  /** 本次加载的路由参数。失败重试要用它重新发起请求，不能只重置标志位。 */
  public params: BrewDetailParams = {
    kind: BrewKind.FORMULA,
    title: '',
    id: 0,
    token: '',
    categoryKey: '',
  };
  /** 归一化后的详情展示数据 */
  public data: BrewInfoPageData = new BrewInfoPageData();
  /** 本机安装状态，由 `BrewDetailViewModel.refreshInstallState` 按已安装快照重算 */
  public installState: BrewInstallState = BrewInstallState.UNKNOWN;
  /**
   * 是否渲染「安装 / 升级」按钮：设备上的 brew 能力开启、当前源的方言是 Harmonybrew，
   * 且包名与 tap 通过命令行校验。任何一条不满足时按钮整个不出现 ——
   * 上游源的包装不到本机的 Harmonybrew 上，数据源来的包名也不该进命令行。
   */
  public commandReady: boolean = false;
  /**
   * 「按钮被隐藏」的 warn 只打一条。
   * 这个标志不是给渲染看的，是给「每次重算都判一次、但别每次都打一条日志」用的去重开关。
   */
  public commandHiddenWarned: boolean = false;
  /** 同分类其他包，独立加载，失败时保持为空 */
  public siblings: BrewPackageItem[] = [];
  /**
   * tldr 用法示例页（「提供的命令」分区正下方的「用法示例」分区，spec 2026-11-22）。
   *
   * 与 `lifecycle` 同一条约束：ArkUI 的 `if` 不给属性表达式做联合类型收窄，
   * 所以这里放**恒非 null** 的实例 + `hasTldr` 开关，页面写
   * `if (hasTldr) { BrewTldrSectionView({ page: tldrPage }) }` 才过类型检查。
   *
   * tldr 是异步到达的增强层（spec §4.2）：数据到达前 `hasTldr=false`，分区不渲染、
   * 不占位；取数失败（无页/断网/解析失败）也落在这里 —— 保持 false，零错误提示（G6）。
   */
  public tldrPage: TldrPage = new TldrPage();
  public hasTldr: boolean = false;
  /**
   * Y 更新情报快照（release intel spec §3.1 / §4）。与 tldrPage 同一条约束：
   * **恒非 null 实例 + `hasReleaseIntel` 开关**（ArkUI 的 if 不做联合类型收窄）。
   * 只在「本机已装且过期」的 formula 详情页装配（G8 懒加载；cask v1 不渲染，spec §10）。
   */
  public releaseIntel: ReleaseIntelSnapshot = new ReleaseIntelSnapshot();
  public hasReleaseIntel: boolean = false;
  /** 当前 to 版本已被用户「忽略此版本」（详情页顶部弱化条 + 撤销入口，spec §4） */
  public releaseIntelIgnored: boolean = false;
  /** `brew pin <token>` 命令文本（G6：只复制不执行；cask 无 pin 语义，恒空串） */
  public releaseIntelPinCommand: string = '';
  /**
   * 版本档案（spec §3.3：更新完成后留档，详情页 caveats 与 siblings 之间展示）。
   * 只装当前 token 的条目；独立异步加载、失败保持为空（档案是增益记录，不提示错误）。
   */
  public releaseArchive: ReleaseIntelArchiveEntry[] = [];
}
