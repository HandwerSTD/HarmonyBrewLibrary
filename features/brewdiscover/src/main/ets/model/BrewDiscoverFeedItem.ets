/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import type { BrewDiscoverBoard, BrewDiscoverFeatured } from '@ohos/brewcommon';

export enum BrewDiscoverFeedType {
  /** 单 App 大图卡（一张卡 = 一个包） */
  FEATURED = 0,
  /** 榜单大卡（一张卡 = 一张榜，卡内多行） */
  BOARD = 1,
  /** AI 发现流 · 单包大图卡（复用大图卡组件渲染，数据来自 LLM picks） */
  AI_FEATURED = 2,
  /** AI 发现流 · 榜卡（heroTitle = 画像 headline，行全显） */
  AI_BOARD = 3,
  /** AI 发现流 · 首载骨架 · 大图卡形 */
  AI_SKELETON_FEATURED = 4,
  /** AI 发现流 · 首载骨架 · 榜卡形 */
  AI_SKELETON_BOARD = 5,
  /** AI 发现流 · 失败占位卡 */
  AI_FAILED = 6
}

/**
 * 瀑布流里的一项。
 *
 * 用「带类型判别字段的联合项」而不是两个 section：两个 section 各有自己的 margin，
 * 交界处会多出一段间距，而两种卡本该是同一条连续瀑布。
 * 一个 section、一个数据源、按 `feedType` 分支渲染，间距就是统一的 rowsGap。
 */
export class BrewDiscoverFeedItem {
  public feedType: number = BrewDiscoverFeedType.BOARD;
  public featured?: BrewDiscoverFeatured = undefined;
  public board?: BrewDiscoverBoard = undefined;
  /** AI 骨架项的槽位号（同类多张时 key 需要区分）；其余 feedType 恒 0 */
  public slot: number = 0;

  public static ofFeatured(item: BrewDiscoverFeatured): BrewDiscoverFeedItem {
    const feed: BrewDiscoverFeedItem = new BrewDiscoverFeedItem();
    feed.feedType = BrewDiscoverFeedType.FEATURED;
    feed.featured = item;
    return feed;
  }

  public static ofBoard(board: BrewDiscoverBoard): BrewDiscoverFeedItem {
    const feed: BrewDiscoverFeedItem = new BrewDiscoverFeedItem();
    feed.feedType = BrewDiscoverFeedType.BOARD;
    feed.board = board;
    return feed;
  }

  /** AI 大图卡。与 stat 大图卡**渲染同款**，但 key 前缀不同：同一个包可能既是
   * 榜单头名又是 AI pick（候选池不排除 stat-featured），LazyForEach key 撞了会串卡 */
  public static ofAiFeatured(item: BrewDiscoverFeatured): BrewDiscoverFeedItem {
    const feed: BrewDiscoverFeedItem = new BrewDiscoverFeedItem();
    feed.feedType = BrewDiscoverFeedType.AI_FEATURED;
    feed.featured = item;
    return feed;
  }

  /** AI 榜卡。渲染走 BrewDiscoverBoardCard 的 'ai' 特判（heroTitle / 全显 / 换一批） */
  public static ofAiBoard(board: BrewDiscoverBoard): BrewDiscoverFeedItem {
    const feed: BrewDiscoverFeedItem = new BrewDiscoverFeedItem();
    feed.feedType = BrewDiscoverFeedType.AI_BOARD;
    feed.board = board;
    return feed;
  }

  /** AI 首载骨架：featuredCount 张大图卡形 + 1 张榜卡形，占住 AI 区的位置防跳动 */
  public static aiSkeletonFeed(featuredCount: number): BrewDiscoverFeedItem[] {
    const feed: BrewDiscoverFeedItem[] = [];
    for (let i = 0; i < featuredCount; i++) {
      const one: BrewDiscoverFeedItem = new BrewDiscoverFeedItem();
      one.feedType = BrewDiscoverFeedType.AI_SKELETON_FEATURED;
      one.slot = i;
      feed.push(one);
    }
    const boardSkel: BrewDiscoverFeedItem = new BrewDiscoverFeedItem();
    boardSkel.feedType = BrewDiscoverFeedType.AI_SKELETON_BOARD;
    feed.push(boardSkel);
    return feed;
  }

  /** AI 失败占位卡（E2-E5；E1 无 Key 是 hidden 不占位） */
  public static ofAiFailed(): BrewDiscoverFeedItem {
    const feed: BrewDiscoverFeedItem = new BrewDiscoverFeedItem();
    feed.feedType = BrewDiscoverFeedType.AI_FAILED;
    return feed;
  }

  /** ForEach/LazyForEach 的 key 必须跨所有类型唯一，否则同 id 的包与榜会撞 */
  public key(): string {
    if (this.feedType === BrewDiscoverFeedType.FEATURED) {
      return `featured_${this.featured?.id ?? 0}`;
    }
    if (this.feedType === BrewDiscoverFeedType.AI_FEATURED) {
      return `ai_featured_${this.featured?.id ?? 0}`;
    }
    if (this.feedType === BrewDiscoverFeedType.AI_BOARD) {
      return `ai_board_${this.board?.id ?? 0}`;
    }
    if (this.feedType === BrewDiscoverFeedType.AI_SKELETON_FEATURED) {
      return `ai_skel_f_${this.slot}`;
    }
    if (this.feedType === BrewDiscoverFeedType.AI_SKELETON_BOARD) {
      return 'ai_skel_b';
    }
    if (this.feedType === BrewDiscoverFeedType.AI_FAILED) {
      return 'ai_failed';
    }
    return `board_${this.board?.id ?? 0}`;
  }

  /**
   * 组装瀑布流：**大图卡排在它所属那张榜的前面**（需求方选定，替代原先的「大图卡一段、榜一段」）。
   *
   * 规则：按 `boards` 的顺序展开，每张榜先吐**归属它**的 featured，再吐榜卡本身。
   * 归属按 `kind + boardKey` 匹配（`BrewDiscoverFeatured` 这两个字段就是从榜上带下来的）。
   * 以目录现算出的六张榜为例，结果是：
   *
   * ```
   * 序号 0  1  2  3  4  5  6  7  8  9  10
   * 类型 F  F  B  B  F  B  F  B  B  F  B
   * 归属      ▲trending/f  ▲alltime/f  ▲fresh/f  ▲trending/c  ▲alltime/c  ▲fresh/c
   * ```
   *
   * ## 为什么是「归属前置」而不是「按数量均匀分摊」
   *
   * 均匀分摊改动更小，但大图卡与相邻的榜卡**内容无关** —— 大卡旁边可能是另一张榜，
   * 顺序不表达任何东西。归属前置有语义：**大卡就是紧跟其后那张榜的头名**。
   *
   * ## 两个已知性质（都不是本方法引入的）
   *
   * 1. 大图卡里的 App 会在**紧随的榜卡里再出现一次** —— `buildFeatured` 用的是
   *    `entries.slice(0, count)`，是复制不是搬走。原先「大图卡一段 + 榜一段」时这个
   *    重复隔着很远、不易察觉，现在变成相邻，会明显一些。
   * 2. `formula/trending` 有 2 张（`FEATURED_RULE` 的 count=2），所以**开头是连续两张
   *    大图卡**；`formula/alltime` 与 `cask/alltime` 没有大图卡，所以那两处是连续两张榜卡。
   */
  public static mix(featured: BrewDiscoverFeatured[], boards: BrewDiscoverBoard[]): BrewDiscoverFeedItem[] {
    const feed: BrewDiscoverFeedItem[] = [];
    // 已归位的 featured 下标。**用下标而不是 id**：同一张榜可能有 2 张（rank 1/2），
    // 用 id 去重会把它们当成同一个；下标天然区分，且能保住原数组顺序 = rank 顺序。
    const placed: boolean[] = [];
    for (let i = 0; i < featured.length; i++) {
      placed.push(false);
    }
    for (let b = 0; b < boards.length; b++) {
      const board: BrewDiscoverBoard = boards[b];
      for (let f = 0; f < featured.length; f++) {
        const one: BrewDiscoverFeatured = featured[f];
        if (placed[f] || one.kind !== board.kind || one.boardKey !== board.boardKey) {
          continue;
        }
        placed[f] = true;
        feed.push(BrewDiscoverFeedItem.ofFeatured(one));
      }
      feed.push(BrewDiscoverFeedItem.ofBoard(board));
    }
    // 兜底：归属榜不存在的 featured **不能静默丢掉**，追加到末尾。
    // 正常走不到（`buildFeatured` 就是从 `boards` 派生的），但 `loadDiscover` 读的是
    // `result.boards` / `result.featured` 两个独立字段，万一上游筛掉了某张榜，
    // 丢掉一张大图卡是无声的（页面只是少一张卡），所以宁可排在末尾也不丢。
    for (let f = 0; f < featured.length; f++) {
      if (!placed[f]) {
        feed.push(BrewDiscoverFeedItem.ofFeatured(featured[f]));
      }
    }
    return feed;
  }
}
