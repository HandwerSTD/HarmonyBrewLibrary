/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

/**
 * 缓存世代号。
 *
 * ## 它解决什么
 *
 * 「清空某源缓存」和「后台正在写入该源缓存」会撞车：元数据同步一次要跑几十秒到几分钟，
 * 目录刷新要 17 秒。用户在这期间点「清空缓存」，随后的写入会把刚清掉的东西**写回去** ——
 * 表现为「清了但没清掉」，而且下一次进页面数据又回来了，用户无法理解。
 *
 * ## 机制
 *
 * **只有「清空当前会话激活源」时才 `bump()`**（见 `BrewCacheAdmin.clear`）。
 * 所有**长时间运行**的写入口在**操作入口**（`hydrate` / `conditionalFetch` / `getCatalog` /
 * `BrewMetaSync.sync`）`current()` 存一份，写之前比对：不相等就**丢弃结果**
 * （既不写盘也不更新内存），并打一条 `[BrewCache] epoch mismatch, dropped write key=…`。
 *
 * ## ⚠ 禁止在 drop 分支里改写 epoch
 *
 * 曾经的写法是在发现不匹配时把该字段改成 `current()` 再 return。那等于「只保护 bump 后的
 * **第一次**写入」，而一次操作里往往有多个写入口、且它们的代价差几个数量级：
 * `BrewMetaSync` 的 `epoch` 是 `rememberStamp`（几十字节）与 `persistIndex`（1MB）**共用的同一个
 * static**，而 `applyKindResult` 先调前者再调后者 —— 于是几十字节的那次把「不匹配」消化掉了，
 * 紧接着 1MB 的索引照写不误，日志里只留一条 `dropped write key=brew_meta_stamp`，
 * 看起来守卫生效了。结果是用户「清了缓存，浏览页立刻从降级态恢复」（G5 被击穿）。
 *
 * 正确语义是：**捕获点只能是操作入口**，drop 分支只记日志 + return。
 *
 * ## 范围（不要为了「顺手」在别的维护操作里 bump）
 *
 * 能被写入的只有**当前会话激活源**（`BrewSourcePrefs` 的 get/set 只面向它），
 * 所以只有「清空激活源」才存在需要作废的在途写入。清空**非激活源**、以及 `drop`
 * （其对象必定不是激活源）都**不应该**推进世代号 —— 真机实测过：清理一个从未激活的
 * 源会误伤当时正在跑的目录取数、数据集戳与单条 doc 写入（启动期 4 次无谓的 drop）。
 *
 * ## 为什么单独一个文件
 *
 * `BrewService` 需要读它、`BrewCacheAdmin` 需要写它、而 `BrewCacheAdmin` 又要调
 * `BrewService.resetMemoryCaches()`。放在两者任一里都会形成运行时循环 import。
 */
export class BrewCacheEpoch {
  private static value: number = 0;

  public static current(): number {
    return BrewCacheEpoch.value;
  }

  public static bump(): number {
    BrewCacheEpoch.value++;
    return BrewCacheEpoch.value;
  }
}
