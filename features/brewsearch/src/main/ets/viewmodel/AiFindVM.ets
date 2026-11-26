/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import {
  AiError,
  AiErrorDetail,
  AiErrorKind,
  AiIntentInput,
  AiSearchAnswer,
  AiTasks,
} from '@ohos/brewcommon';
import type { BrewSearchEntry } from '@ohos/brewcommon';
import { Logger } from '@ohos/common';
import { AiCatalogIndex } from '../model/AiCatalogIndex';

const TAG: string = '[ai]';

/**
 * AI 搜索问答的结果状态（2026-11-26-ai-search-ask-spec §3）。
 *
 * `kind` 是**渲染分流口**：页面按它选 answer 混排 / fallback 本地 / error 卡 /
 * empty 卡。E1/E2/E3 的降级判断在这里做完，页面只消费结果不重复判错。
 */
export class AiAskState {
  /** 'idle' | 'loading' | 'answer' | 'fallback' | 'error' | 'empty' */
  public kind: string = 'idle';
  /** kind=answer 时的混排答案。 */
  public answer: AiSearchAnswer | null = null;
  /** kind=fallback 时的降级原因（决定通知条文案：E1 用 no_key 专用文案）。 */
  public fallbackNoKey: boolean = false;
  /** kind=error 时的错误分级。 */
  public errorKind: AiErrorKind | null = null;
  /** E4/E5 的细节后缀（诊断信息直达 UI，沿用 D2 排查记录）。空串 = 无细节。 */
  public errorDetail: string = '';
  /** 本页最近一次意图（防陈旧覆盖：新提交在途时旧结果直接丢弃）。 */
  public appliedIntent: string = '';
}

/** ask() 的结果包裹：state 已就地更新，answer 供页面取。 */
export interface AiAskOutcome {
  kind: string;
  answer?: AiSearchAnswer;
}

/**
 * D2 问答化的 VM。搜索框 AI 模式提交走这里（spec §3）。
 *
 * 流程：意图 → AiTasks.askSearch（LLM 单次调用产 lead+picks，缓存 24h，
 * 目录校验 G5）→ 混排答案。E1/E2/E3 自动降级为本地搜索（fallback 态），
 * E4/E5 给错误卡（重试 / 用本地搜索）。陈旧守卫沿用 D2。
 */
export class AiFindVM {
  private static instance: AiFindVM | undefined = undefined;

  public static getInstance(): AiFindVM {
    if (AiFindVM.instance === undefined) {
      AiFindVM.instance = new AiFindVM();
    }
    return AiFindVM.instance;
  }

  /**
   * 提问一次。`state.appliedIntent` 先写入（陈旧结果判定用），结果回来时
   * intent 不一致就不覆盖（返回 undefined）。空意图直接 undefined（回建议态）。
   */
  public ask(intent: string, state: AiAskState): Promise<AiAskOutcome | undefined> {
    const trimmed: string = intent.trim();
    if (trimmed.length === 0) {
      return Promise.resolve(undefined);
    }
    state.appliedIntent = trimmed;
    state.kind = 'loading';
    state.answer = null;
    state.errorKind = null;
    state.errorDetail = '';
    state.fallbackNoKey = false;
    const input: AiIntentInput = new AiIntentInput();
    input.intent = trimmed;
    const entries: BrewSearchEntry[] = AiCatalogIndex.entries();
    return AiTasks.askSearch(input, entries)
      .then((answer: AiSearchAnswer) => {
        if (state.appliedIntent !== trimmed) {
          return undefined;
        }
        // picks 空 = LLM 没有把握（合法空态，D2_SYSTEM 允许空 picks）→ empty 卡
        if (answer.picks.length === 0) {
          state.kind = 'empty';
          state.answer = null;
          const emptyOutcome: AiAskOutcome = { kind: 'empty' };
          return emptyOutcome;
        }
        state.kind = 'answer';
        state.answer = answer;
        const outcome: AiAskOutcome = { kind: 'answer', answer };
        return outcome;
      })
      .catch((error: AiError) => {
        if (state.appliedIntent !== trimmed) {
          return undefined;
        }
        const kind: AiErrorKind = error instanceof AiError ? error.kind : AiErrorKind.E2_NETWORK;
        // E1（未配 Key）/ E2（网络失败）/ E3（超时）→ 自动本地搜索（G6：不引导配 Key）
        if (kind === AiErrorKind.E1_NO_KEY || kind === AiErrorKind.E2_NETWORK ||
          kind === AiErrorKind.E3_TIMEOUT) {
          Logger.info(TAG, `d2 fallback local reason=${kind}`);
          state.kind = 'fallback';
          state.fallbackNoKey = kind === AiErrorKind.E1_NO_KEY;
          const fallbackOutcome: AiAskOutcome = { kind: 'fallback' };
          return fallbackOutcome;
        }
        // E4（格式不符）/ E5（内容拒绝）：错误卡（重试 / 用本地搜索）
        state.kind = 'error';
        state.errorKind = kind;
        state.errorDetail = error instanceof AiError ? AiErrorDetail.of(error) : '';
        const errorOutcome: AiAskOutcome = { kind: 'error' };
        return errorOutcome;
      });
  }
}
