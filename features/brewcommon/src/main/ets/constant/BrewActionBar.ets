/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { Logger } from '@ohos/common';

const TAG: string = '[BrewActionBar]';

/**
 * 底部悬浮操作栏的全部取值 —— 包详情页与「我的 - 待更新」页共用一份。
 *
 * 为什么收在这里：两个页面各写一套数字时，只要有人改了其中一处，两条栏就会长得不一样，
 * 而这种差异在真机上只能靠两张截图并排比出来。页面之间是平等关系，谁也不该"抄"另一方的常量，
 * 所以取值放在 brewcommon，由两个页面引用。
 */

/**
 * 操作栏的高度（vp）。与 `CommonConstants.NAVIGATION_HEIGHT` / `TAB_BAR_HEIGHT` 同值：
 * 与标题栏同高，按钮上下各留 8vp。设备有底部导航条时还要加 `globalInfo.naviIndicatorHeight`。
 */
export const BREW_ACTION_BAR_HEIGHT: number = 56;

/**
 * 遮罩的渐变长度（vp）—— 从底部实色渐变到顶部全透明要走过的距离。
 *
 * 取 32：HDS 页签栏渐变遮罩的默认渐变长度（页签栏高度 + 32vp）。遮罩总高 = 栏高 + 这个数
 * （56 + 32 = 88vp）；比这更高会让底部大片被白纱盖住。
 */
export const BREW_ACTION_BAR_MASK_GRADIENT: number = 32;

/** 按钮高度（vp）= 栏高 56 减上下各 8 */
export const BREW_ACTION_BUTTON_HEIGHT: number = 40;

/**
 * 按钮下沿到栏底之间额外留出的高度（vp）。
 *
 * 按钮在栏里垂直居中时上下各 8vp，看上去离底边近；这 16vp 把按钮抬起来一点，
 * 视觉重心与参考图一致。
 */
export const BREW_ACTION_BUTTON_BOTTOM_EXTRA: number = 16;

/** 按钮宽度：内容区宽度的 60%（构建器根 Row 的左右内缩与内容区同源，所以百分比也同源） */
export const BREW_ACTION_BUTTON_WIDTH: Length = '60%';

/**
 * 按钮宽度上限（vp）。窗口很宽时百分比算出来的宽度没有边界，上限收在 448vp ——
 * 按参考图（上方是本页 328vp 的按钮、下方是更长的目标，两张图同一显示比例）估算：
 * 623px ↔ 328vp，851px ↔ 448vp；同一比例下按钮高度 76px ↔ 40vp，与取值吻合。
 */
export const BREW_ACTION_BUTTON_MAX_WIDTH: number = 448;

/**
 * 操作栏（含底部导航条）的总高度。`barHeight` 与遮罩高度都调它，两条栏的高度来源只有一个。
 */
export function brewActionBarHeight(naviIndicatorHeight: number): number {
  return BREW_ACTION_BAR_HEIGHT + naviIndicatorHeight;
}

/**
 * 遮罩总高 = 栏高 + 遮罩渐变长度。与 `brewActionBarHeight()` 的差恒等于 `BREW_ACTION_BAR_MASK_GRADIENT`。
 */
export function brewActionBarMaskHeight(naviIndicatorHeight: number): number {
  return brewActionBarHeight(naviIndicatorHeight) + BREW_ACTION_BAR_MASK_GRADIENT;
}

/** 判据日志的去重表（同一页同内容只打一次）。与 `BrewTitleBar.logRamp()` 同一写法 */
const loggedActionBars: Map<string, string> = new Map();

/**
 * 操作栏渲染时打一行判据：`mask − height` 必须等于 `gradient`，`height` 必须等于 56 + `navi` ——
 * 对不上说明两个高度用了不同的来源。断点或导航条高度变化会让 build 反复执行，不去重会把日志刷满。
 */
export function brewLogActionBar(page: string, naviIndicatorHeight: number, breakpointText: string): void {
  const height: number = brewActionBarHeight(naviIndicatorHeight);
  const mask: number = brewActionBarMaskHeight(naviIndicatorHeight);
  const line: string = `action bar: page=${page} height=${height} mask=${mask}` +
    ` gradient=${BREW_ACTION_BAR_MASK_GRADIENT} button=${BREW_ACTION_BUTTON_WIDTH}` +
    ` max=${BREW_ACTION_BUTTON_MAX_WIDTH} navi=${naviIndicatorHeight} breakpoint=${breakpointText}`;
  if (loggedActionBars.get(page) === line) {
    return;
  }
  loggedActionBars.set(page, line);
  Logger.info(TAG, line);
}
