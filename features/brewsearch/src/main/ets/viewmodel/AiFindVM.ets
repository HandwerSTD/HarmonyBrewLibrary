/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { Logger } from '@ohos/common';
import {
  AiError,
  AiErrorKind,
  AiIntentInput,
  AiTaskWords,
  AiToolCandidate,
  AiToolResult,
  AiTasks,
  AiSettingsStore,
  BrewKind,
} from '@ohos/brewcommon';
import type { AiTaskWord, BrewSearchEntry } from '@ohos/brewcommon';
import { AiCatalogIndex } from '../model/AiCatalogIndex';
import { AiFindRow, AiFindResultSource } from '../model/AiFindRowSource';

const TAG: string = '[ai]';

/**
 * 「AI 帮我找工具」的状态（spec §5）。
 *
 * `mode` 记录**本次结果是谁产的**：AI 模式 / 词表模式。断网或未配 Key 时
 * 自动切词表（G6）并在 UI 顶部提示；两种模式的结果都过目录过滤与引擎排序。
 */
export class AiFindState {
  /** 'idle' | 'loading' | 'ai' | 'wordlist' | 'empty' | 'error' */
  public mode: string = 'idle';
  /** 错误分级（mode=error 时有值）。 */
  public errorKind: AiErrorKind | null = null;
  /** E4 细分：输出被截断（finishReason=length）时用专门文案。 */
  public errorTruncated: boolean = false;
  /** 词表模式的提示显隐（G6 的「AI 未配置，已切换离线词表」）。 */
  public fallbackNotice: boolean = false;
  /** 本页最近一次意图（防旧结果覆盖：与搜索页 appliedKeyword 同一思路）。 */
  public appliedIntent: string = '';
}

/**
 * D2 的 VM。「AI 帮我找工具」入口挂在搜索首页（spec §5）。
 *
 * 流程：意图 →（已配 Key 且在线）AiTasks.findTools → 目录过滤 + 引擎排序；
 * （未配 Key / 网络失败）AiTasks.findToolsOffline → 词表 28 条 + 引擎排序。
 * 两种模式产出的都是 `AiToolResult`，渲染层统一吃一个列表。
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
   * 跑一次「找工具」。`state.appliedIntent` 先写入（陈旧结果判定用），
   * 结果回来时 intent 不一致就不覆盖（返回 undefined）。
   */
  public find(intent: string, state: AiFindState): Promise<AiFindRow[] | undefined> {
    const trimmed: string = intent.trim();
    if (trimmed.length === 0) {
      return Promise.resolve(undefined);
    }
    state.appliedIntent = trimmed;
    state.mode = 'loading';
    state.errorKind = null;
    state.errorTruncated = false;
    state.fallbackNotice = false;
    const input: AiIntentInput = new AiIntentInput();
    input.intent = trimmed;
    const entries: BrewSearchEntry[] = AiCatalogIndex.entries();
    return AiTasks.findTools(input, entries)
      .then((result: AiToolResult) => {
        if (state.appliedIntent !== trimmed) {
          return undefined;
        }
        state.mode = 'ai';
        state.fallbackNotice = false;
        return AiFindVM.rowsOf(result);
      })
      .catch((error: AiError) => {
        const kind: AiErrorKind = error instanceof AiError ? error.kind : AiErrorKind.E2_NETWORK;
        // E1（未配 Key）/ E2（网络失败）/ E3（超时）→ 自动切词表模式（G6）
        if (kind === AiErrorKind.E1_NO_KEY || kind === AiErrorKind.E2_NETWORK ||
          kind === AiErrorKind.E3_TIMEOUT) {
          if (state.appliedIntent !== trimmed) {
            return undefined;
          }
          Logger.info(TAG, `d2 fallback wordlist reason=${kind}`);
          state.mode = 'wordlist';
          state.fallbackNotice = true;
          return Promise.resolve(AiFindVM.wordlistRows(trimmed));
        }
        // E4（格式不符）/ E5（内容拒绝）：给明确错误态（spec §8 D2 行）
        if (state.appliedIntent !== trimmed) {
          return undefined;
        }
        state.mode = 'error';
        state.errorKind = kind;
        state.errorTruncated = (error as AiError).message.indexOf('reason=truncated') >= 0;
        return Promise.resolve([]);
      });
  }

  /** 词表模式的同步结果（未配 Key 首次进入时 UI 直接走这条，不发起注定失败的请求）。 */
  public findOffline(intent: string, state: AiFindState): AiFindRow[] {
    const trimmed: string = intent.trim();
    state.appliedIntent = trimmed;
    state.mode = 'wordlist';
    state.errorKind = null;
    state.fallbackNotice = true;
    Logger.info(TAG, `d2 fallback wordlist reason=pre-check`);
    return AiFindVM.wordlistRows(trimmed);
  }

  /** 是否已配置到能发 AI 请求（Key + 配置齐全）。UI 入口的引导文案按它分流。 */
  public isConfigured(): boolean {
    if (!AiSettingsStore.hasApiKey()) {
      return false;
    }
    // provider_model 形如 `deepseek_deepseek-chat`；没配置时是 `deepseek_`（model 为空），
    // 此时发请求也会 E1，直接走词表省一次注定失败的网络等待。
    const key: string = AiTasks.providerModelKey();
    return key.indexOf('_') > 0 && !key.endsWith('_');
  }

  private static wordlistRows(intent: string): AiFindRow[] {
    const words: AiTaskWord[] = AiTaskWords.load();
    const result: AiToolResult = AiTasks.findToolsOffline(intent, AiCatalogIndex.entries(), words);
    return AiFindVM.rowsOf(result);
  }

  /** 结果 → 渲染行。空结果由 UI 的空态分支处理（mode=empty）。 */
  private static rowsOf(result: AiToolResult): AiFindRow[] {
    const source: AiFindResultSource = new AiFindResultSource();
    return source.rowsOf(result, (token: string): BrewKind => {
      // kind 判定来自目录索引（条目在组装时带 kind）；未命中默认 formula
      return AiCatalogIndex.kindOf(token) === 'cask' ? BrewKind.CASK : BrewKind.FORMULA;
    });
  }
}

/** 候选 → 行的转换收在数据源侧（与 BrewSearchRowSource 同构）。 */
export { AiFindRow } from '../model/AiFindRowSource';
export { AiToolCandidate as AiFindCandidateRow } from '@ohos/brewcommon';
