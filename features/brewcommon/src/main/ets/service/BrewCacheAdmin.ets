/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '@ohos/common';
import { BrewSource, BrewSourceCacheStats } from '../model/BrewSourceModels';
import { objKeys } from '../util/objkeys';
import { BrewCacheEpoch } from './BrewCacheEpoch';
import { BrewCatalogFile } from './BrewCatalogFile';
import { BrewService } from './BrewService';
import { BrewTable } from './BrewTable';
import { BrewSourcePrefs } from './BrewSourcePrefs';
import { BrewSourceStore } from './BrewSourceStore';

const TAG: string = '[BrewCache]';

/**
 * 源缓存的维护入口：查看 / 清空 / 删除。
 *
 * ## 为什么 clear/drop 要串行
 *
 * 官方文档明确：「不允许 `deletePreferences` 与其他接口多线程、多进程并发调用，
 * 否则可能会发生不可预期行为」。所以这里用一个 Promise 链把维护操作排成队列。
 *
 * ## 为什么清空激活源要重置内存
 *
 * 内存里还有一份包表与详情缓存。只清盘不重置内存，下一次写入就会把它们写回去 ——
 * 用户看到「清了但数据还在」。配合 `BrewCacheEpoch` 一起，在途的后台写入也会被丢弃。
 *
 * ## 为什么删激活源被拒绝
 *
 * 本进程的 store 句柄正指着它，删掉会让句柄悬空；而「切走」这个动作本身就是重启，
 * 重启后再删即可。拒绝比「自动切回官方 + 重启」更可预测。
 *
 * ## 为什么要连带删目录文件
 *
 * Harmonybrew 的归一化目录正文（约 3.4MB）留在 `filesDir`，不在 Preferences 里，
 * 清 Preferences 清不到它。而 `BrewCatalogFile.readRange` 在偏移表缺失时会从残留正文
 * 重建索引继续供数 —— 只清 store 等于没清。所以 clear 与 drop 都要调
 * `BrewCatalogFile.delete`。
 */
export class BrewCacheAdmin {
  private static queue: Promise<void> = Promise.resolve();

  /** 单源缓存统计。**会打开该源的 store**（非激活源用完即释放） */
  public static stats(sourceId: string): BrewSourceCacheStats {
    const out: BrewSourceCacheStats = new BrewSourceCacheStats();
    out.sourceId = sourceId;
    const store: preferences.Preferences | null = BrewSourcePrefs.openFor(sourceId);
    if (store === null) {
      return out;
    }
    const t0: number = Date.now();
    try {
      const all: Object = store.getAllSync();
      const keys: string[] = objKeys(all);
      const map: Record<string, Object> = all as Record<string, Object>;
      out.keys = keys.length;
      keys.forEach((key: string) => {
        const raw: string = typeof map[key] === 'string' ? map[key] as string : JSON.stringify(map[key]);
        out.approxBytes += raw.length;
        out.entries += BrewCacheAdmin.countEntries(key, raw);
        const ts: number = BrewCacheAdmin.extractTs(key, raw);
        if (ts > out.updatedAt) {
          out.updatedAt = ts;
        }
      });
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.error(TAG, `stats failed, id=${sourceId}, code=${e.code}, msg=${e.message}`);
    }
    if (sourceId !== BrewSourceStore.sessionActive().id) {
      BrewSourcePrefs.releaseFor(sourceId);
    }
    Logger.info(TAG, `stats id=${sourceId} keys=${out.keys} entries=${out.entries} ` +
      `bytes=${out.approxBytes} ms=${Date.now() - t0}`);
    return out;
  }

  /** 清空某源的缓存。激活源会同时重置内存态 */
  public static clear(sourceId: string): Promise<void> {
    return BrewCacheAdmin.enqueue(() => {
      const isActive: boolean = sourceId === BrewSourceStore.sessionActive().id;
      const before: number = BrewCacheEpoch.current();
      Logger.info(TAG, `[clear] begin id=${sourceId} active=${isActive} epoch=${before} ` +
        `table=${BrewTable.statsLine()}`);
      // **只在清空当前会话激活源时才推进世代号**。
      //
      // 世代号保护的是「激活源正在进行中的写入」。非激活源在本次会话里没有任何写入者
      // （只有会话激活源会被读写，见 `BrewSourcePrefs`），所以推进它只会误伤激活源：
      // 真机实测过 —— 清理一个从未激活的 throwaway 源，把当时正在跑的目录取数、数据集戳、
      // 单条 doc 写入全丢了（启动期 4 次 `epoch mismatch, dropped write`）。
      const after: number = isActive ? BrewCacheEpoch.bump() : before;
      // 顺序：先作废世代号（上面）→ 再重置内存指针 → 最后才清盘。
      // 这样「内存里已无旧数据」与「盘上正在被清」之间不存在窗口：
      // 在途写入读到的是已重置的内存指针，且世代号已不匹配（见 `BrewCacheEpoch`）。
      if (isActive) {
        BrewService.resetMemoryCaches();
        BrewTable.resetMemory();
        Logger.debug(TAG, `[clear] 内存副本已重置（服务详情缓存 + 包表），世代号已推进至 ${after}`);
      }
      // 数据轴记录随缓存一起作废：两片的「成功过」时刻与站着的错误都是
      // **上一份数据**的结论。不重置就会出现「清空缓存了，列表还写着已就绪」。
      // 探测记录（连通性）保留 —— 它描述远端地址，与本地缓存无关。
      BrewSourceStore.resetDataHealth(sourceId);
      // 必须先删目录正文与源目录，再清 store。`BrewCatalogFile.readRange` 在偏移表
      // 缺失时会从正文重建索引继续供数，正文留着就清不干净。
      BrewCatalogFile.delete(sourceId);
      const store: preferences.Preferences | null = BrewSourcePrefs.openFor(sourceId);
      if (store !== null) {
        try {
          store.clearSync();
        } catch (err) {
          const e: BusinessError = err as BusinessError;
          Logger.error(TAG, `clearSync failed, id=${sourceId}, code=${e.code}, msg=${e.message}`);
        }
      }
      // **本方法最重要的一行**：`clearSync()` 只清了 GSKV 的内存缓存页。
      // 不显式刷盘的话，用户清完缓存、进程被杀，下次启动**缓存整份回来** ——
      // 而 `BrewCacheEpoch` 只能挡住同一会话内的在途写入，跨不了进程。
      // `persistNow` 同时会作废该源的句柄（所以下面不再需要 `releaseFor`）。
      BrewSourcePrefs.persistNow(sourceId);
      // 通知放在清盘完成之后：订阅者收到通知会立刻读盘，早一步通知就会把还没被
      // 清掉的旧内容重新装进内存副本，用户看到「清了但列表还在」。
      if (isActive) {
        BrewTable.notifyObservers();
      }
      Logger.info(TAG, `clear id=${sourceId} active=${isActive} epoch=${before}→${after} done`);
      return Promise.resolve();
    });
  }

  /** 删除某源的整个 store。builtin 与会话激活源会被拒绝 */
  public static drop(sourceId: string): Promise<void> {
    return BrewCacheAdmin.enqueue(() => {
      // active 检查必须在最前面：drop 的对象必定不是激活源，因此**完全不需要**推进世代号
      // （非激活源没有在途写入者，没有需要作废的写入）
      if (sourceId === BrewSourceStore.sessionActive().id) {
        Logger.error(TAG, `drop rejected, id=${sourceId} is the session active source`);
        return Promise.resolve();
      }
      // 显式拒绝 builtin：下面改成「先删 store」之后，靠 `removeSource` 的拒绝就太晚了 ——
      // 那时官方源的 store 已经被删掉了。
      const source: BrewSource | undefined = BrewSourceStore.find(sourceId);
      if (source === undefined) {
        Logger.error(TAG, `drop rejected, unknown id=${sourceId}`);
        return Promise.resolve();
      }
      if (source.builtin) {
        Logger.error(TAG, `drop rejected, builtin id=${sourceId}`);
        return Promise.resolve();
      }
      // 与 `clear` 同理：正文与源目录要一并删掉，否则留下约 3.4MB 正文和它的偏移表
      BrewCatalogFile.delete(sourceId);
      BrewSourcePrefs.releaseFor(sourceId);
      // **先删 store，成功才删注册表**。
      // 反过来的话，`deleteStore` 失败（Context 未就绪 / `deletePreferences` 抛错）时，
      // 源已从列表消失、文件却永久留着，且用户再点删除已找不到入口 —— 静默破坏 G4。
      return BrewSourcePrefs.deleteStore(sourceId).then((ok: boolean) => {
        if (!ok) {
          Logger.warn(TAG, `drop: store 删除失败，保留注册表条目以便重试, id=${sourceId}`);
          return;
        }
        const removed: boolean = BrewSourceStore.removeSource(sourceId);
        // 源已不在注册表里，它的数据轴记录没有任何意义了；顺手作废，避免残留旧结论
        // （id 不会再被复用，所以只是卫生问题，不会串源）。
        BrewSourceStore.resetDataHealth(sourceId);
        Logger.info(TAG, `drop id=${sourceId} ok=${removed} epochUnchanged=${BrewCacheEpoch.current()}`);
      });
    });
  }

  private static enqueue(task: () => Promise<void>): Promise<void> {
    const next: Promise<void> = BrewCacheAdmin.queue.then(() => task())
      .catch((err: BusinessError) => {
        Logger.error(TAG, `maintenance task failed, code=${err?.code}, msg=${err?.message}`);
      });
    BrewCacheAdmin.queue = next;
    return next;
  }

  /** 结构化条目数。口径见 spec §9.1。用 `objKeys`（ArkTS 不允许 `Object.keys(Object)`） */
  private static countEntries(key: string, raw: string): number {
    try {
      if (key === 'brew_table') {
        const table: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
        let n: number = 0;
        objKeys(table['vol'] as Object).forEach((kind: string) => {
          n += objKeys((table['vol'] as Record<string, Object>)[kind] as Object).length;
        });
        objKeys(table['desc'] as Object).forEach((kind: string) => {
          n += objKeys((table['desc'] as Record<string, Object>)[kind] as Object).length;
        });
        return n;
      }
      if (key === 'brew_detail_cache' || key === 'brew_detail_view') {
        return objKeys(JSON.parse(raw) as Object).length;
      }
    } catch (err) {
      return 0;
    }
    return 0;
  }

  private static extractTs(key: string, raw: string): number {
    try {
      if (key === 'brew_table') {
        const table: Record<string, number> = JSON.parse(raw) as Record<string, number>;
        // 表没有单一的 ts：两片各自有「成功过」的时刻，取较晚的那个作为整表的写入时刻
        const vol: number = table['volReadyAt'] ?? 0;
        const desc: number = table['descReadyAt'] ?? 0;
        return Math.max(vol, desc);
      }
    } catch (err) {
      return 0;
    }
    return 0;
  }
}
