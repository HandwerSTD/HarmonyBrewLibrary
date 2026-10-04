/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { LoadingModel } from '@ohos/common';
import { BrewInfoPageData, BrewKind, BrewPackageItem } from '@ohos/brewcommon';
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
   * 是否渲染「安装 / 升级」按钮：设备上的 brew 能力开启，且包名与 tap 都通过命令行校验。
   * 校验不过时按钮整个不出现 —— 数据源来的包名不该进命令行。
   */
  public commandReady: boolean = false;
  /**
   * 包名校验不过的 warn 只打一条。
   * 这个标志不是给渲染看的，是给「每次重算都判一次、但别每次都打一条日志」用的去重开关。
   */
  public unsafeNameWarned: boolean = false;
  /** 同分类其他包，独立加载，失败时保持为空 */
  public siblings: BrewPackageItem[] = [];
}
