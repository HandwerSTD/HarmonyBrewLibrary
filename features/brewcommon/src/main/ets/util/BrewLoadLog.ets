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

import { Logger } from '@ohos/common';

const TAG: string = '[brew-load]';

/**
 * 冷启动**各数据类型的加载打点**。每加载一个数据类型打**恰好一行**，格式固定：
 *
 * ```
 * [load] kind=<类型> reason=<原因> ms=<耗时> <明细...> at=<epoch ms>
 * ```
 *
 * `at` 是绝对 epoch ms，所以「相对 `Ability onCreate` 的耗时」可以直接用两行的 `at` 相减
 * 得到 —— 不需要解析 hilog 时间戳。`ms` 是这一段加载自身的耗时。
 *
 * ## kind（数据类型）
 *
 * | kind | 是什么 | 存在哪 |
 * |---|---|---|
 * | `catalog` | 全量目录**从盘上读整份**（安装量 + 六张榜 + 浏览表） | Preference `brew_catalog` |
 * | `cold_start` | **冷启动原点**：数据层本次进程的第一次动作（splash 里的 meta sync 启动） | —— |
 * | `catalog_fetch` | 目录的**新鲜度判定与取数**（探针 / 条件请求） | 网络 |
 * | `meta_index` | `token → desc` 索引（分类与列表主文案的唯一来源） | Preference `brew_meta_index` |
 * | `meta_index_sync` | 索引的**后台同步**（下载 + 扫描两个全量包） | 网络 |
 * | `live_data` | 单条 doc 缓存整体 | Preference `brew_live_data` |
 * | `live_docs` | 一批单条 doc 的 hydrate（缓存命中 + 下载） | 网络 / 内存 |
 * | `dataset_stamps` | 数据集版本戳（Last-Modified / ETag 基准） | Preference `brew_live_dataset` |
 * | `discover_snapshot` | Discover 的内置回落快照 | rawfile |
 * | `discover_page` | Discover 首页整页（快照 + 目录 + hydrate） | 组装 |
 * | `formula_page` | Formulae 首页构页（分类 + 建卡） | 组装 |
 * | `cask_page` | Casks 首页构页 | 组装 |
 *
 * ## reason（加载原因，固定词表）
 *
 * | reason | 含义 |
 * |---|---|
 * | `mem` | 进程内已有内存副本，零 I/O |
 * | `pref` | 从 Preference 读到（新鲜度由调用方另行判断） |
 * | `pref-fresh` | 读到且在新鲜窗口内 → 直接用 |
 * | `pref-stale` | 读到但已超新鲜窗口 → 接下来会探针/条件请求 |
 * | `rawfile` | 读内置 rawfile 快照 |
 * | `assembled` | 由已加载的各部分组装而成（Discover 整页） |
 * | `origin` | 冷启动原点标记（`kind=cold_start` 专用，`ms` 恒为 0） |
 * | `in-flight` | 复用了在途请求（没发新请求） |
 * | `probe-304` | 数据集探针说整批未变 → 0 字节续期 |
 * | `net-304` | 条件请求 304 → 0 字节续期 |
 * | `net-200` | 下载全文 |
 * | `missing` | 盘上没有（或上游没有） |
 * | `shape-invalid` | 盘上有但形状校验不过，按空表处理 |
 * | `index-trusted` | 浏览页**主路径**：索引可信，候选 = 目录 ∩ 索引，**零请求** |
 * | `degraded-hydrate` | 浏览页**降级**：索引部分覆盖，逐条 hydrate（慢） |
 * | `degraded-prefix` | 浏览页**降级**：索引全空，只取目录前 N 条（慢） |
 * | `empty-catalog` | 目录缺失 → 页面空态 |
 * | `batch` | 批量 hydrate 汇总 |
 * | `partial` | 批量 hydrate 有失败 |
 * | `fetch-failed` | 取数失败 |
 * | `sync-failed` | 同步失败或扫出 0 条（会保留旧表） |
 * | `budget` | 超过等待预算、先去处理下一个 kind（**下载仍在后台，结束时照常落盘**） |
 *
 * ## 读法（冷启动排查）
 *
 * 1. 拿 `kind=cold_start` 那行的 `at=` 当原点（它≈ `Ability onCreate` 后 ~300ms），
 *    其余每行都自带 `at=`，相减即得「相对冷启动的耗时」——**不需要解析 hilog 时间戳**。
 *    为什么要单独打一个原点：设备 hilog 是固定大小的环形缓冲，日志量大时只回收到 ~12s 前，
 *    `Ability onCreate` 经常在抓取时已被挤掉（实测 `--from 90s` 与 `--from 600s` 同一起点）。
 * 2. 先看 `kind=meta_index reason=missing` —— 它出现就意味着这次浏览页**必然**走降级路径；
 * 3. 再看 `kind=formula_page reason=index-trusted|degraded-*` 与 `ms=` —— 前者 ~400ms，后者 5~15s；
 * 4. `reason=degraded-*` 会额外跟一行 **warn**（含根因提示），不需要自己推。
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

  private static line(kind: string, reason: string, ms: number, detail: string): string {
    return '[load] kind=' + kind + ' reason=' + reason + ' ms=' + ms +
      (detail.length > 0 ? ' ' + detail : '') + ' at=' + Date.now();
  }
}
