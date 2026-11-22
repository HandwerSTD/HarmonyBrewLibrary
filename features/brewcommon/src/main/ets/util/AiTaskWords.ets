/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { Logger, ResourceUtil, StorageKey } from '@ohos/common';
import {
  AI_TASKWORDS_MIN_COUNT,
  AI_TASKWORDS_RAWFILE,
} from '../constant/AiConstants';

const TAG: string = '[ai]';

/**
 * 一条中文任务词：意图关键词（或前缀）→ 目录内候选 token。
 * 结构由 `hmosword-build/brew-ai/check_taskwords.py` 在构建期校验（token 存在性 + 规模）。
 */
export class AiTaskWord {
  /** 触发词（中文，如「压缩图片」）。匹配时做精确或前缀比对（spec §5）。 */
  public task: string = '';
  /** 候选 token（全部必须在本地目录里——校验脚本钉住，设备端再守一道）。 */
  public tokens: string[] = [];
  /** 一句话说明（可选，渲染在结果上方）。 */
  public note: string = '';
}

/**
 * 28 条中文任务词表的加载与匹配（spec §5 的离线降级层，G6）。
 *
 * - 数据在 `features/brewcommon/src/main/resources/rawfile/ai/taskwords.json`（随 HAR 打包）；
 * - **匹配口径**：意图归一化（trim + 小写）后，「任务词与意图相等」或「意图以任务词开头」
 *   （前缀匹配）。中文没有大小写，小写化只是把混入的英文统一掉；
 * - 读盘失败 / 规模不足 → 返回空表，D2 词表模式显示空态（没有找到匹配的工具），
 *   **绝不抛错**——降级层自己不能再变成新的故障面；
 * - 进程内缓存一次读取结果：rawfile 读的是 HAR 内文件，重复读没有意义。
 */
export class AiTaskWords {
  private static cached: AiTaskWord[] | null = null;

  /** 加载词表。第二次调用起走进程内缓存。 */
  public static load(): AiTaskWord[] {
    if (AiTaskWords.cached !== null) {
      return AiTaskWords.cached;
    }
    AiTaskWords.cached = AiTaskWords.readFromRawfile();
    return AiTaskWords.cached;
  }

  /**
   * 意图匹配（spec §5：精确 / 前缀）。返回命中的词表条目（可能多条：命中同一个任务词的
   * 多种写法时全部给出，结果侧合并去重）。
   */
  public static match(intent: string, words: AiTaskWord[]): AiTaskWord[] {
    const key: string = intent.trim().toLowerCase();
    if (key.length === 0) {
      return [];
    }
    const hits: AiTaskWord[] = [];
    words.forEach((word: AiTaskWord) => {
      const task: string = word.task.trim().toLowerCase();
      if (task.length === 0) {
        return;
      }
      if (key === task || key.startsWith(task)) {
        hits.push(word);
      }
    });
    Logger.info(TAG, `wordlist match intent-len=${key.length} hits=${hits.length}`);
    return hits;
  }

  /** 词表条数（判据 G6 的「28」由校验脚本钉住；运行期只看 ≥1）。 */
  public static count(): number {
    return AiTaskWords.load().length;
  }

  private static readFromRawfile(): AiTaskWord[] {
    const uiContext: UIContext | undefined = AppStorage.get<UIContext>(StorageKey.UI_CONTEXT);
    const ctx: Context | undefined = uiContext === undefined ? undefined : uiContext.getHostContext();
    if (ctx === undefined) {
      Logger.warn(TAG, `wordlist load deferred, context unavailable`);
      return [];
    }
    try {
      const parsed: Object | undefined = ResourceUtil.getRawFileContentSync(ctx, AI_TASKWORDS_RAWFILE) as Object;
      if (parsed === undefined || parsed === null) {
        Logger.error(TAG, `wordlist missing, path=${AI_TASKWORDS_RAWFILE}`);
        return [];
      }
      const obj: Record<string, Object> = parsed as Record<string, Object>;
      const listObj: Object | undefined = obj['words'];
      if (!Array.isArray(listObj)) {
        Logger.error(TAG, `wordlist malformed, words is not an array`);
        return [];
      }
      const list: Array<Object> = listObj as Array<Object>;
      const out: AiTaskWord[] = [];
      list.forEach((item: Object) => {
        const rec: Record<string, Object> = item as Record<string, Object>;
        const task: string = typeof rec['task'] === 'string' ? rec['task'] as string : '';
        const tokensObj: Object | undefined = rec['tokens'];
        if (task.length === 0 || !Array.isArray(tokensObj)) {
          return;
        }
        const word: AiTaskWord = new AiTaskWord();
        word.task = task;
        (tokensObj as Array<Object>).forEach((tok: Object) => {
          if (typeof tok === 'string' && (tok as string).length > 0) {
            word.tokens.push(tok as string);
          }
        });
        if (typeof rec['note'] === 'string') {
          word.note = rec['note'] as string;
        }
        if (word.tokens.length > 0) {
          out.push(word);
        }
      });
      if (out.length < AI_TASKWORDS_MIN_COUNT) {
        Logger.error(TAG, `wordlist too small, count=${out.length} min=${AI_TASKWORDS_MIN_COUNT}`);
        return out;
      }
      Logger.info(TAG, `wordlist loaded, count=${out.length}`);
      return out;
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.error(TAG, `wordlist load failed, code=${e?.code}, msg=${e?.message}`);
      return [];
    }
  }
}
