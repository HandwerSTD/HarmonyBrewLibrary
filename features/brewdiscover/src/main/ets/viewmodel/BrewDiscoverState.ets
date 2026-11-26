/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { BaseHomeState } from '@ohos/commonbusiness';
import type { BrewDiscoverBoard, BrewDiscoverFeatured } from '@ohos/brewcommon';
import { BrewDiscoverCardSource } from './BrewDiscoverCardSource';

/**
 * AI 发现流（D4）的装配阶段。feed 数组由 VM 按 phase 重建，视图只按 feedType 渲染：
 *
 * - HIDDEN：前置闸门未过（pc_normal / 装机数不足 / 无 Key / 目录未 ready），
 *   feed 里**没有** AI 项——G6：静默降级，不占位不引导配 Key。
 * - LOADING：首载，AI 区 = 大图卡形骨架 ×3 + 榜卡形骨架 ×1。
 * - READY：AI 区 = 大图卡 ×3 + AI 榜卡。
 * - REFRESHING：换一批中，大图卡保留旧值、仅榜卡位回骨架（需求：少闪）。
 * - FAILED：AI 区 = 失败占位卡 ×1（E2-E5 可重试）。
 */
export enum BrewDiscoverAiPhase {
  HIDDEN = 0,
  LOADING = 1,
  READY = 2,
  REFRESHING = 3,
  FAILED = 4
}

/**
 * Discover 页状态。
 *
 * 与 BrewFormulaState 同构，都继承 BaseHomeState —— 模糊标题栏、section、滚动位置、
 * 返回键、断点/配色变化这些都在基类里，这里只加榜单卡片源与快照日期。
 */
export class BrewDiscoverState extends BaseHomeState {
  public cardSource: BrewDiscoverCardSource = new BrewDiscoverCardSource();
  public sections: WaterFlowSections = new WaterFlowSections();
  /**
   * 数据窗口结束日，如 `'2026-09-17'`。
   *
   * **必须是 state 上的一层属性**：`@State` 只观察一层，包进嵌套对象就不会触发页面更新。
   * 页面上「数据窗口 xxx」这行用它。
   */
  public snapshotDate: string = '';
  // ---- AI 发现流（D4）。同样遵守「一层属性」纪律：phase 一变 VM 就重建 feed ----
  /** AI 区装配阶段，驱动 feed 组成 */
  public aiPhase: BrewDiscoverAiPhase = BrewDiscoverAiPhase.HIDDEN;
  /** 最近一次成功的 AI 大图卡（picks 前三张），REFRESHING 期间保留旧值 */
  public aiFeatured: BrewDiscoverFeatured[] = [];
  /** 最近一次成功的 AI 榜卡（heroTitle = 画像 headline） */
  public aiBoard: BrewDiscoverBoard | null = null;
  /** FAILED 时的错误分类（AiErrorKind 的 message 摘要，失败卡展示用） */
  public aiErrorText: string = '';
  /** 换一批轮次（只进日志，用于核对 exclude 是否累进） */
  public aiRound: number = 0;

  public constructor() {
    super();
  }
}
