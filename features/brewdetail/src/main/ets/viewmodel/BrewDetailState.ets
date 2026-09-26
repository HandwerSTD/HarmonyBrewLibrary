/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { LoadingModel } from '@ohos/common';
import { BrewInfoPageData, BrewKind, BrewPackageItem } from '@ohos/brewcommon';
import type { BrewDetailParams } from '@ohos/brewcommon';

/**
 * 详情页状态。不加 @Observed —— @State 会观察所持对象的**一级属性**赋值，
 * 因此下面每个字段都在一级，包括 `siblings`。
 *
 * `siblings` 特意**不放在** `BrewInfoPageData` 里：它与主详情是两个独立请求
 * （详情接口不返回同类包，需要另外读首页数据），如果嵌在 `data` 内部，
 * 后续单独赋值不会触发刷新（@State 只观察一级属性）。
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
  /** 同分类其他包，独立加载，失败时保持为空 */
  public siblings: BrewPackageItem[] = [];
}
