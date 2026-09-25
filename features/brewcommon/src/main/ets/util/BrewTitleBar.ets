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

import { LengthMetrics } from '@kit.ArkUI';
import { hdsMaterial, ScrollEffectOptions, ScrollEffectType, TitleBarStyleOptions } from '@kit.UIDesignKit';
import { HdsUtil, Logger } from '@ohos/common';

const TAG: string = '[BrewTitleBar]';

/**
 * 标题栏模糊的渐变区间长度（vp）—— brew 所有页共用。
 *
 * 数值出处：参考页（组件 / 样例 / 实践三个页签，走 `BaseHomeViewModel.setTitleBarStyle()`）的区间长度
 * = `BANNER_CONTENT_HEIGHT`(160) − `NAVIGATION_HEIGHT`(56) = **104**。
 */
export const BREW_TITLEBAR_BLUR_RAMP: number = 104;

/**
 * 区间长度下限（vp）。低于这个值就不算渐变（HDS 默认值 8vp 的教训），
 * 一旦算出来的区间比它还窄，就按它兜底并打 warn —— 这种错误必须能在日志里看见，
 * 而不是只能靠肉眼看。
 */
export const BREW_TITLEBAR_BLUR_MIN_RAMP: number = 32;

/**
 * 滚动驱动的模糊配置：**区间 = [0, ramp]**，也就是「内容区滚动总偏移量」从 0 起连续渐变。
 *
 * ## 为什么起点只能是 0（负数会被 HDS 静默丢掉）
 *
 * HDS（`@kit.UIDesignKit`）对这两个字段的取值范围是 **[0, +∞)**，越界**按默认值处理**
 * （官方 API 参考 `ScrollEffectOptions`）：
 *   - `blurEffectiveStartOffset` 默认 `vp(0)` → 传负数会被**当成 0**（不是当成负的起点）；
 *   - `blurEffectiveEndOffset` 默认：COMMON_BLUR / GRADIENT_BLUR 为 `vp(8)`；
 *     **若 end < start，同样按默认值处理**。
 *
 * 这两条都是**静默降级**：编译过、不报错、无日志，只是表现不对。
 * 上一轮就是踩在这里 —— 我们为了让区间「左移」写了一个负的 start，
 * 结果 start 被丢成 0、end 留在 `104 − 56 = 48`，区间退化成 [0,48]：
 * 前 56vp（= contentStartOffset）毫无动静，后 48vp 猛增到最大模糊。
 *
 * ## 为什么起点 0 必须对应「内容贴在标题栏下沿」这一刻
 *
 * HDS 用的是**滚动容器自报的偏移量**（`Scroller.currentOffset().yOffset`）。
 * 关键实测：用 `contentStartOffset(C)` 让位的页面，**静止时自报的偏移量是 −C**（本机测得 −56），
 * 而不是 0 —— 因为 `contentStartOffset` 是「内容区起始偏移」，它把内容区的原点挪到了 +C，
 * 于是滚动坐标系整体左移了 C。而 HDS 又规定起点不能为负，**它永远够不到那个原点**
 * → 内容在标题栏下已经钻了 C 却还没开始模糊，这就是用户看到的「空行程」。
 *
 * ## 所以 brew 所有页都用「内容里的占位」让位
 *
 * 两种都不行（都在真机上实测过）：
 *   - **容器上的 `padding`**：会把内容**裁剪**在 padding 区域之外，内容永远滚不到标题栏下面，
 *     而标题栏模糊正是靠「内容透上来」才看得出效果 → 模糊“形同虚设”；也同时把滚动坐标系
 *     原点推开（实测静止时自报 16vp）。
 *   - **`contentStartOffset` / `contentEndOffset`**：不裁剪，但会把滚动坐标系整体左移 C。
 *
 * 正确的做法是**把让位写进内容**，三个参考页都是这么做的：
 *   - 组件页：顶部空间是 waterfall 里的第一个 FlowItem（banner）；
 *   - 我的页：内层 Column 的 `margin.top`（左右内缩也写在它身上，不写在 Scroll 上）；
 *   - Casks 页：Scroll 内层 Column 的 `margin.top`（本页的 chips 行也在标题栏里，所以让得更多）。
 *
 * 这样静止时自报的偏移量就是 0，区间 [0, ramp] 才能真正从「内容贴在标题栏下沿」起渐变。
 *
 * `ramp` 长度的意义与参考页一致：从静止位置起滚过 `ramp` vp 到最大模糊。
 */
export function brewBlurScrollEffect(base?: ScrollEffectOptions,
  ramp: number = BREW_TITLEBAR_BLUR_RAMP): ScrollEffectOptions {
  let end: number = ramp;
  if (!(end >= BREW_TITLEBAR_BLUR_MIN_RAMP)) {
    Logger.warn(TAG, `blur ramp too small (${ramp}), clamped to ${BREW_TITLEBAR_BLUR_MIN_RAMP}`);
    end = BREW_TITLEBAR_BLUR_MIN_RAMP;
  }
  // 传了 base 就**只补区间**：材质类型（COMMON_BLUR / GRADIENT_BLUR / IMMERSIVE_GRADIENT_BLUR）
  // 保持调用方原来的选择。页签页走的正是这条路 —— 基类已经按「新材质 API 是否可用」选好了
  // 材质（`IMMERSIVE_GRADIENT_BLUR`，与参考页 组件 同款），它缺的只有区间。
  const opts: ScrollEffectOptions = base ?? {
    enableScrollEffect: true,
    scrollEffectType: ScrollEffectType.COMMON_BLUR,
  };
  opts.enableScrollEffect = true;
  if (base === undefined && HdsUtil.isSupportNewMaterialApi()) {
    // 没给 base 的场景（二级页/详情页）：与这些页面原本的 inline 写法一致 ——
    // 系统有材质列表时用渐变模糊，否则退回普通模糊
    opts.scrollEffectType = hdsMaterial.getSystemMaterialTypes().length > 0 ?
      ScrollEffectType.GRADIENT_BLUR : ScrollEffectType.COMMON_BLUR;
  }
  // 起点显式写 0：**这是唯一合法的起点**（见上面的取值范围说明）。
  // 不要改成负数 —— 会被 HDS 丢成 0，而终点还留在减去补偿后的值上，区间就悄悄变短了。
  opts.blurEffectiveStartOffset = LengthMetrics.vp(0);
  opts.blurEffectiveEndOffset = LengthMetrics.vp(end);
  return opts;
}

/**
 * brew 所有页共用的标题栏样式（模糊部分）。
 *
 * @param page 页名，只用于日志判据行（`strings modules.abc` 与日志一起核对哪些页接上了）
 *
 * 调用方不需要再自己拼 `systemMaterialEffect` / `scrollEffectOpts`：
 * 接上新材质的方法也是这里统一判断的（`HdsUtil.isSupportNewMaterialApi()`）。
 */
export function brewTitleBarStyle(page: string): TitleBarStyleOptions {
  const ramp: number = BREW_TITLEBAR_BLUR_RAMP;
  logRamp(page, ramp);
  const style: TitleBarStyleOptions = {
    scrollEffectOpts: brewBlurScrollEffect(undefined, ramp),
  };
  if (HdsUtil.isSupportNewMaterialApi()) {
    style.systemMaterialEffect = {
      materialType: hdsMaterial.MaterialType.IMMERSIVE,
      materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE,
    };
  }
  return style;
}

/**
 * 每页一行判据日志（同页同样的值只打一次 —— 这个函数会在断点变化时被反复调用）。
 *
 * 判据：`start=0 且 ramp>=104`。若某页缺这一行，说明那页没接上共用实现。
 */
export function brewLogRampForPage(page: string): void {
  logRamp(page, BREW_TITLEBAR_BLUR_RAMP);
}

const loggedRamps: Map<string, string> = new Map();

function logRamp(page: string, ramp: number): void {
  const material: string = HdsUtil.isSupportNewMaterialApi() ? 'new' : 'legacy';
  const line: string = `blur ramp: page=${page} start=0 end=${ramp} ramp=${ramp} material=${material}`;
  if (loggedRamps.get(page) === line) {
    return;
  }
  loggedRamps.set(page, line);
  Logger.info(TAG, line);
}
