/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { Logger } from '@ohos/common';

const TAG: string = '[brew-load]';

/**
 * 加载打点。每加载一个数据阶段打**恰好一行**，格式固定：
 *
 * ```
 * [load] kind=<类型> reason=<原因> ms=<耗时> <明细...> at=<epoch ms>
 * ```
 *
 * `at` 是绝对 epoch ms，所以「相对 `Ability onCreate` 的耗时」可以直接用两行的 `at` 相减
 * 得到 —— 不需要解析 hilog 时间戳。`ms` 是这一段加载自身的耗时。
 *
 * ## 三个级别各管什么
 *
 * - `info`：**每一次**都打。回答「这一轮冷启动做了什么、花在哪」。
 * - `warn`：只在拖慢或失败的分支打。**级别本身就是判据** —— warn 出现的行数
 *   就是「这次冷启动为什么不快」的计数，不需要人去比对数值。
 * - `debug`：只在**判定与分支**处打（发不发条件请求、复用没复用内存、走没走回落）。
 *   排查具体某一个 token 为什么不对时才用 `hdc shell hilog -x <tag> | grep debug` 拉，
 *   默认全量输出里噪声太大。
 *
 * ## kind（数据类型）
 *
 * | kind | 是什么 | 存在哪 |
 * |---|---|---|
 * | `cold_start` | **冷启动原点**：数据层本次进程的第一次动作（第一次 `BrewTable.refresh`） | —— |
 * | `table_refresh` | 表的**新鲜度判定**（两片各自要不要发请求） | —— |
 * | `table_vol` | 安装量片：4 个聚合端点 → 算三张榜 → 写盘 | 网络 / Preference `brew_table` |
 * | `table_desc` | 描述片：`formula.json` / `cask.json` → `token → desc` | 网络 / Preference `brew_table` |
 * | `table` | 表的**读盘与派生**（从 Preference 读整份 + 相交 + 分组排序） | Preference `brew_table` |
 * | `discover_page` | Discover 首页整页（榜成员 + 大图卡显示名） | 组装 |
 * | `formula_page` | Formulae 首页 / 分类二级页构页 | 组装 |
 * | `cask_page` | Casks 首页 / 分类二级页构页 | 组装 |
 * | `detail_cache` | 详情页单条缓存**首次从盘上读进内存** | Preference `brew_detail_cache` |
 * | `detail_doc` | 详情页的单条文档（缓存命中 / 304 / 下载 / 失败） | 网络 / Preference |
 *
 * ## reason（加载原因，固定词表）
 *
 * | reason | 含义 |
 * |---|---|
 * | `origin` | 冷启动原点标记（`kind=cold_start` 专用，`ms` 恒为 0） |
 * | `vol-fresh` / `vol-stale` | 安装量片在窗口内 / 超窗口 |
 * | `desc-fresh` / `desc-stale` | 描述片在窗口内 / 超窗口（跟随 `table_refresh` 那行） |
 * | `in-flight` | 复用了在途请求（没发新请求） |
 * | `all-fresh` | 两片都在新鲜窗口内，本轮零请求 |
 * | `pref` | 从 Preference 读到并派生完成 |
 * | `missing` | 盘上没有这张表（首次安装） |
 * | `schema` | 盘上有但结构版本不对，整表当空表（改过结构会走到这里） |
 * | `conditional` | 这一轮带了 `If-Modified-Since`（判据：会拿到 304） |
 * | `full` | 这一轮不带条件请求，全量拉（判据：条件请求基准缺失或不可用） |
 * | `probe-done` | 聚合端点全部返回后的逐个状态码汇总 |
 * | `start` | 发起该片取数前的现状快照（盘上条数 + 基准） |
 * | `within-budget` | 在等待预算内就结束了（不用等迟到写入） |
 * | `vol-applied` / `desc-applied` | 某片写入并重新派生 |
 * | `vol-renewed` / `desc-renewed` | 整片 304，只推进时间戳不重算 |
 * | `no-such-category` | 分类二级页：词表与表数据对不上，找不到该分类 |
 * | `category-hit` | 分类二级页：分类找到了 |
 * | `net-200` | 下载了全文 |
 * | `net-304` | 条件请求 304 → 0 字节续期 |
 * | `probe-304` | 整批聚合端点都 304 → 0 字节续期，榜单不重算 |
 * | `budget` | 超过等待预算，先去开始下一个 kind（**下载仍在后台，结束时照常落盘**） |
 * | `skip-unsupported` | 本源不提供该 kind，跳过（不是失败） |
 * | `fetch-failed` | 取数失败 |
 * | `sync-failed` | 同步失败或扫出 0 条（会保留旧表） |
 * | `empty-table` | 表还没建好，页面走空态 |
 * | `assembled` | 由已就绪的各部分组装而成 |
 * | `cache-hit` | 详情页单条文档命中新鲜窗口，没发请求 |
 * | `not-modified` | 详情页单条文档 304，0 字节续期 |
 * | `downloaded` | 详情页单条文档下载全文 |
 * | `out-of-window` | 详情页单条文档超窗，带条件请求重问上游 |
 * | `absent` | 上游确认没这个包（404 / 410） |
 *
 * ## 读法（冷启动排查）
 *
 * 1. 拿 `kind=cold_start` 那行的 `at=` 当原点（它≈ `Ability onCreate` 后 ~300ms），
 *    其余每行都自带 `at=`，相减即得「相对冷启动的耗时」——**不需要解析 hilog 时间戳**。
 *    为什么要单独打一个原点：设备 hilog 是固定大小的环形缓冲，日志量大时只回收到 ~12s 前，
 *    `Ability onCreate` 经常在抓取时已被挤掉（实测 `--from 90s` 与 `--from 600s` 同一起点）。
 * 2. 看 `kind=table_refresh` 那行 —— `vol-stale` / `desc-stale` 说明这次发了请求，
 *    两个 `fresh` 说明一个字节都不发（稳态）。
 * 3. 看 `kind=table_vol` 与 `kind=table_desc` 的 `ms=`：`net-200` 慢就是上游慢，
 *    `net-304` / `probe-304` 是 0 字节续期，`budget` 之后还有一行 `net-200` 是迟到写入。
 * 4. 数字自相矛盾时（榜上第 1 名安装量比第 3 名少、分类明显错位），
 *    用 `--debug` 拉 `kind=table` 那行的分类分布，与 Python 侧 `check_algo.py` 对账。
 */
export class BrewLoadLog {
  /** 正常加载路径：info */
  public static info(kind: string, reason: string, ms: number, detail: string): void {
    Logger.info(TAG, BrewLoadLog.line(kind, reason, ms, detail));
  }

  /**
   * 会拖慢冷启动的异常分支：warn。
   *
   * 与 `info` 的唯一区别是日志级别 —— 级别本身是判据的一部分：`warn` 出现的次数
   * 就是「这次冷启动为什么慢」的计数，不需要人去比对数值。
   */
  public static warn(kind: string, reason: string, ms: number, detail: string): void {
    Logger.warn(TAG, BrewLoadLog.line(kind, reason, ms, detail));
  }

  /**
   * 判定与分支：debug。
   *
   * 只在「这里本可以不发请求 / 这里本可以复用」的位置打，所以它能回答
   * 「为什么这次还在发请求」「为什么这一行没变」。默认全量输出里噪声太大，
   * 排查单个 token 时才按 tag 拉出来。
   */
  public static debug(kind: string, reason: string, ms: number, detail: string): void {
    Logger.debug(TAG, BrewLoadLog.line(kind, reason, ms, detail));
  }

  private static line(kind: string, reason: string, ms: number, detail: string): string {
    return '[load] kind=' + kind + ' reason=' + reason + ' ms=' + ms +
      (detail.length > 0 ? ' ' + detail : '') + ' at=' + Date.now();
  }
}
