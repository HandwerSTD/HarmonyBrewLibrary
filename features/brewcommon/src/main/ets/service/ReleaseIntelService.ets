/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger, StorageKey } from '@ohos/common';
import {
  RELEASE_INTEL_ARCHIVE_CAP,
  RELEASE_INTEL_ARCHIVE_FILE,
  RELEASE_INTEL_ARCHIVE_SEGMENT,
  RELEASE_INTEL_ATOM_PATH,
  RELEASE_INTEL_ATOM_TIMEOUT_MS,
  RELEASE_INTEL_GAP_NET,
  RELEASE_INTEL_GAP_NONE,
  RELEASE_INTEL_GAP_NOTES,
  RELEASE_INTEL_GAP_REPO,
  RELEASE_INTEL_GAP_TAG,
  RELEASE_INTEL_RELEASES_PATH,
} from '../constant/ReleaseIntelConstants';
import {
  ReleaseIntelArchiveEntry,
  ReleaseIntelCard,
  ReleaseIntelDiff,
  ReleaseIntelInput,
  ReleaseIntelSnapshot,
  releaseIntelArchiveEntryOf,
} from '../model/ReleaseIntelModels';
import { BrewNotesExtractor } from '../util/BrewNotesExtractor';
import { FormulaDiffer } from '../util/FormulaDiffer';
import { ReleaseIntelRepoResolver, ReleaseIntelTagFilter } from '../util/ReleaseIntelRepoResolver';
import { SemverJudge } from '../util/SemverJudge';
import { AiSettingsStore } from './AiSettingsStore';
import { AiTasks } from './AiTasks';
import { BrewHttp } from './BrewHttp';
import { ReleaseIntelBaselineStore } from './ReleaseIntelBaselineStore';

const TAG: string = '[release-intel]';

/** kind 口径（与 BrewService.cacheKey 的 kind 段一致）。 */
const KIND_FORMULA: string = 'formula';
const KIND_CASK: string = 'cask';

/**
 * GitHub releases.atom 的单条 entry（拉取期形态，feed 专用，不出模块边界）。
 */
class AtomEntry {
  public title: string = '';
  public tag: string = '';
  public updated: string = '';
  public contentHtml: string = '';
}

/** fetchAtom 的返回：entry 列表或失败原因（两者不同时有值）。 */
class AtomFetchOutcome {
  public entries: AtomEntry[] = [];
  public error: string = '';
}

/**
 * 更新情报中心的编排层（spec §3.1，`docs/superpowers/specs/2026-11-23-release-intel-spec.md`）。
 *
 * 输入是三类现成数据：
 *   - `rawDoc`：当前（新版）单条 API JSON（BrewService 抓取成功后给）；
 *   - `oldRawJson`：diff 基线（已装版本的 raw JSON，`ReleaseIntelBaselineStore.read`）；
 *   - `fromVersion`：已装版本（BrewInstalledLoader.installedOf(token).version）。
 *
 * 输出是 `ReleaseIntelSnapshot`：结构化区（verdict/diff）**同步可得**（G1）；
 * 信息缺口用独立 gapCode 表达（G5），失败态分级见 spec §5；AI 卡缺席不阻塞。
 */
export class ReleaseIntelService {
  /** Release 页 URL（`{repo}/releases/tag/{tag}`；tag 走 encodeURIComponent）。 */
  public static releaseUrlOf(repoUrl: string, tag: string): string {
    if (repoUrl.length === 0) {
      return '';
    }
    return repoUrl + '/' + RELEASE_INTEL_RELEASES_PATH + '/' + encodeURIComponent(tag);
  }

  /**
   * 主装配。`oldRawJson` 为空串 = 基线缺失（F5，diff.baselineAvailable=false）。
   * atom 拉取内置一次重试（F1）；AI 失败只落 `aiFailed`，结构化区照常（G5）。
   * `force` 仅透传给 AI 任务（「重新生成」= 旁路 AI 缓存强制取数，G8；与 D1 同口径），
   * atom 每次都是现拉的，不受 force 影响。
   */
  public static async assemble(rawDoc: Object, oldRawJson: string, token: string,
    kind: string, fromVersion: string, force: boolean = false): Promise<ReleaseIntelSnapshot> {
    const snapshot: ReleaseIntelSnapshot = new ReleaseIntelSnapshot();
    snapshot.token = token;
    snapshot.kind = kind;
    snapshot.fromVersion = fromVersion;
    snapshot.toVersion = ReleaseIntelService.rawVersionOf(rawDoc, kind);
    snapshot.fetchedAt = Date.now();
    snapshot.gapCode = RELEASE_INTEL_GAP_NONE;

    // 结构化区（G3：零 AI）
    const verdict = SemverJudge.judge(fromVersion, snapshot.toVersion);
    snapshot.verdict = verdict.kind;

    let diff: ReleaseIntelDiff = new ReleaseIntelDiff();
    if (oldRawJson.length > 0) {
      let oldRaw: Object | null = null;
      try {
        oldRaw = JSON.parse(oldRawJson) as Object;
      } catch (err) {
        oldRaw = null; // 基线损坏按缺失处理
      }
      if (oldRaw !== null) {
        diff = FormulaDiffer.diff(oldRaw, rawDoc);
      }
    }
    snapshot.diff = diff;

    // 上游 repo（F2：非 GitHub）
    const repo = ReleaseIntelRepoResolver.resolve(rawDoc);
    if (repo.url.length === 0) {
      snapshot.gapCode = RELEASE_INTEL_GAP_REPO;
      return snapshot;
    }
    snapshot.sourceUrl = repo.url;

    // 拉取 releases.atom（Stage-0 探针 + 主取数一体；F1 内置一次重试）
    const outcome: AtomFetchOutcome = await ReleaseIntelService.fetchAtomFeed(repo.owner, repo.repo);
    if (outcome.entries.length === 0 && outcome.error.length > 0) {
      snapshot.gapCode = RELEASE_INTEL_GAP_NET;
      return snapshot;
    }
    // tag 过滤（G2：零误报）
    const entry: AtomEntry | null = ReleaseIntelService.matchEntry(outcome.entries, snapshot.toVersion);
    if (entry === null) {
      snapshot.gapCode = RELEASE_INTEL_GAP_TAG;
      return snapshot;
    }
    snapshot.sourceUrl = ReleaseIntelService.releaseUrlOf(repo.url, entry.tag);

    // notes 提取（F4：匹配到发布但正文为空）
    const notes = BrewNotesExtractor.extract(entry.contentHtml);
    snapshot.notesTruncated = notes.truncated;
    if (notes.text.length === 0) {
      snapshot.gapCode = RELEASE_INTEL_GAP_NOTES;
      return snapshot;
    }

    // AI 卡（G5/G8：无 Key / 开关关 → 静默；失败 → aiFailed，UI 给重试）
    if (!AiSettingsStore.autoExplain()) {
      return snapshot; // card=null 静默
    }
    const input: ReleaseIntelInput = new ReleaseIntelInput();
    input.token = token;
    input.from = fromVersion;
    input.to = snapshot.toVersion;
    input.notes = notes.text;
    input.diffJson = JSON.stringify(diff);
    try {
      snapshot.card = await AiTasks.releaseIntel(input, undefined, force);
    } catch (err) {
      Logger.warn(TAG, `release intel ai failed, token=${token}`);
      snapshot.aiFailed = true;
    }
    return snapshot;
  }

  // ------------------------------------------------------------ 基线

  /**
   * 预捕获基线（VM.load 取数**前**调用）：store 缓存里的 raw 若仍是「已装版本」的
   * 配方，立刻快照进基线库——否则随后的一次详情抓取会把它覆盖掉（BrewService 的
   * `brew_detail_cache` 是覆盖式的，见侦察结论）。
   */
  public static captureBaselineFromStore(kind: string, token: string,
    installedVersion: string, cachedRawJson: string): void {
    if (cachedRawJson.length === 0 || installedVersion.length === 0) {
      return;
    }
    try {
      const raw: Object = JSON.parse(cachedRawJson) as Object;
      const version: string = ReleaseIntelService.rawVersionOf(raw, kind);
      if (version === installedVersion) {
        ReleaseIntelBaselineStore.save(token, installedVersion, cachedRawJson);
      }
    } catch (err) {
      // 缓存内容损坏：放弃预捕获（后续走 F5）
    }
  }

  /** 详情加载成功且「已装 = 最新」时顺手快照（幂等）。 */
  public static captureBaselineIfCurrent(kind: string, token: string,
    installedVersion: string, rawDoc: Object): void {
    if (installedVersion.length === 0) {
      return;
    }
    const version: string = ReleaseIntelService.rawVersionOf(rawDoc, kind);
    if (version !== installedVersion) {
      return;
    }
    ReleaseIntelBaselineStore.save(token, installedVersion, JSON.stringify(rawDoc));
  }

  public static readBaseline(token: string, version: string): string {
    return ReleaseIntelBaselineStore.read(token, version);
  }

  // ------------------------------------------------------------ 档案

  /**
   * 档案钩子入口（Runner 在 upgrade DONE 时调，spec §3.3 / G7）。
   * 卡片内容从 AI 缓存就地取（用户没打开过情报卡时缓存 miss → cardJson 留空）；
   * 条目**内嵌 cardJson**（设计决策①：AI 缓存可被 CacheAdmin 清掉，档案必须自含）；
   * 同包同版本重升级：覆盖旧条目（防重复堆叠）；内部全兜底，任何异常都不影响
   * 命令收尾——档案是增益记录，不是命令结果的组成部分。
   */
  public static appendArchiveSync(token: string, kind: string, from: string, to: string): void {
    if (token.length === 0 || kind.length === 0 || from.length === 0 || to.length === 0 ||
      from === to) {
      return;
    }
    try {
      const card: ReleaseIntelCard | null = AiTasks.cachedIntelCard(token, to);
      const entry: ReleaseIntelArchiveEntry = releaseIntelArchiveEntryOf(token, kind, from, to,
        Date.now(), card === null ? '' : JSON.stringify(card));
      ReleaseIntelService.appendArchive(entry);
    } catch (err) {
      Logger.warn(TAG, `archive append failed, token=${token}`);
    }
  }

  public static appendArchive(entry: ReleaseIntelArchiveEntry): void {
    const entries: ReleaseIntelArchiveEntry[] = ReleaseIntelService.readArchive();
    const kept: ReleaseIntelArchiveEntry[] = [];
    for (let i: number = 0; i < entries.length; i++) {
      const one: ReleaseIntelArchiveEntry = entries[i];
      if (one.token === entry.token && one.to === entry.to) {
        continue;
      }
      kept.push(one);
    }
    kept.unshift(entry);
    while (kept.length > RELEASE_INTEL_ARCHIVE_CAP) {
      kept.pop();
    }
    ReleaseIntelService.writeArchive(kept);
  }

  /** 读全部档案（新→旧）。文件缺失/损坏 → 空表（档案缺席不是错误）。 */
  public static readArchive(): ReleaseIntelArchiveEntry[] {
    const path: string = ReleaseIntelService.archivePath();
    if (path.length === 0) {
      return [];
    }
    let file: fileIo.File | undefined = undefined;
    try {
      if (!fileIo.accessSync(path)) {
        return [];
      }
      file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      const size: number = fileIo.statSync(file.fd).size;
      const buffer: ArrayBuffer = new ArrayBuffer(size);
      const read: number = fileIo.readSync(file.fd, buffer, { offset: 0, length: size });
      fileIo.closeSync(file);
      file = undefined;
      if (read !== size) {
        return [];
      }
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      const text: string = decoder.decodeToString(new Uint8Array(buffer), { stream: false });
      const parsed: Object = JSON.parse(text) as Object;
      const rec: Record<string, Object> = parsed as Record<string, Object>;
      const list: Object | undefined = rec['entries'];
      if (list === undefined || list === null || !Array.isArray(list)) {
        return [];
      }
      const arr: Array<Object> = list as Array<Object>;
      const out: ReleaseIntelArchiveEntry[] = [];
      for (let i: number = 0; i < arr.length; i++) {
        const one: Object | undefined = arr[i];
        if (one === undefined || one === null) {
          continue;
        }
        const recOne: Record<string, Object> = one as Record<string, Object>;
        const token: string = typeof recOne['token'] === 'string' ? recOne['token'] as string : '';
        const kind: string = typeof recOne['kind'] === 'string' ? recOne['kind'] as string : '';
        const from: string = typeof recOne['from'] === 'string' ? recOne['from'] as string : '';
        const to: string = typeof recOne['to'] === 'string' ? recOne['to'] as string : '';
        const at: number = typeof recOne['at'] === 'number' ? recOne['at'] as number : 0;
        const cardJson: string =
          typeof recOne['cardJson'] === 'string' ? recOne['cardJson'] as string : '';
        if (token.length === 0 || to.length === 0) {
          continue;
        }
        out.push(releaseIntelArchiveEntryOf(token, kind, from, to, at, cardJson));
      }
      return out;
    } catch (error) {
      if (file !== undefined) {
        try {
          fileIo.closeSync(file);
        } catch (closeErr) {
          Logger.warn(TAG, `archive read close failed, code=${(closeErr as BusinessError)?.code}`);
        }
      }
      const err: BusinessError = error as BusinessError;
      Logger.warn(TAG, `archive read failed, code=${err?.code}`);
      return [];
    }
  }

  // ------------------------------------------------------------ atom

  /** atom 单条解析出的 tag 去重后与目标版本精确匹配；多条命中取 updated 最新。 */
  private static matchEntry(entries: AtomEntry[], version: string): AtomEntry | null {
    let best: AtomEntry | null = null;
    for (let i: number = 0; i < entries.length; i++) {
      const one: AtomEntry = entries[i];
      if (!ReleaseIntelTagFilter.matches(one.tag, version)) {
        continue;
      }
      if (best === null || one.updated > best.updated) {
        best = one;
      }
    }
    return best;
  }

  /**
   * 拉取 `{repo}/releases.atom`，失败重试一次（spec F1）。两次都失败 → error 非空。
   */
  private static async fetchAtomFeed(owner: string, repo: string): Promise<AtomFetchOutcome> {
    const url: string = 'https://github.com/' + owner + '/' + repo + '/' + RELEASE_INTEL_ATOM_PATH;
    let firstError: string = '';
    for (let attempt: number = 0; attempt < 2; attempt++) {
      try {
        const result = await BrewHttp.request(url, http.RequestMethod.GET, {}, RELEASE_INTEL_ATOM_TIMEOUT_MS);
        if (result.code === 200 && result.text.length > 0) {
          return ReleaseIntelService.parseAtomFeed(result.text);
        }
        firstError = `atom status=${result.code}`;
      } catch (err) {
        const e: BusinessError = err as BusinessError;
        firstError = `atom fetch failed, code=${e?.code}`;
      }
    }
    const outcome: AtomFetchOutcome = new AtomFetchOutcome();
    outcome.error = firstError;
    Logger.warn(TAG, `${firstError}, repo=${owner}/${repo}`);
    return outcome;
  }

  /**
   * 极简 Atom 解析：只要 entry 的 title/updated/id/content 四样。
   * GitHub releases.atom 结构稳定（探测报告：title=tag，content type="html"，
   * id="tag:github.com,2008:Repository/{repoId}/{tag}"）。解析异常按空表返回，
   * 上层落 net 缺口（不抛出——feed 格式漂移不是可恢复错误）。
   */
  private static parseAtomFeed(xml: string): AtomFetchOutcome {
    const outcome: AtomFetchOutcome = new AtomFetchOutcome();
    try {
      let cursor: number = 0;
      while (true) {
        const entryStart: number = xml.indexOf('<entry>', cursor);
        if (entryStart < 0) {
          break;
        }
        const entryEnd: number = xml.indexOf('</entry>', entryStart);
        if (entryEnd < 0) {
          break;
        }
        const body: string = xml.substring(entryStart + '<entry>'.length, entryEnd);
        cursor = entryEnd + '</entry>'.length;
        const entry: AtomEntry | null = ReleaseIntelService.parseAtomEntry(body);
        if (entry !== null) {
          outcome.entries.push(entry);
        }
      }
    } catch (err) {
      Logger.warn(TAG, 'atom parse failed');
    }
    return outcome;
  }

  private static parseAtomEntry(body: string): AtomEntry | null {
    const title: string = ReleaseIntelService.sliceTagText(body, 'title');
    const idText: string = ReleaseIntelService.sliceTagText(body, 'id');
    const updated: string = ReleaseIntelService.sliceTagText(body, 'updated');
    const content: string = ReleaseIntelService.sliceTagText(body, 'content');
    if (title.length === 0 && idText.length === 0) {
      return null;
    }
    const entry: AtomEntry = new AtomEntry();
    entry.title = title;
    entry.tag = ReleaseIntelTagFilter.tagFromEntryId(idText.length > 0 ? idText : title);
    entry.updated = updated;
    entry.contentHtml = content;
    return entry;
  }

  /** 取 `<tag ...>text</tag>` 的 text（容 attribute；atom 四样都不嵌套）。 */
  private static sliceTagText(body: string, tag: string): string {
    const open: string = '<' + tag;
    const start: number = body.indexOf(open);
    if (start < 0) {
      return '';
    }
    const gt: number = body.indexOf('>', start);
    if (gt < 0) {
      return '';
    }
    const close: string = '</' + tag + '>';
    const end: number = body.indexOf(close, gt);
    if (end < 0) {
      return '';
    }
    return body.substring(gt + 1, end).trim();
  }

  // ------------------------------------------------------------ 杂项

  /** raw JSON 的版本口径：formula=versions.stable，cask=version。 */
  private static rawVersionOf(rawDoc: Object, kind: string): string {
    const rec: Record<string, Object> = rawDoc as Record<string, Object>;
    if (kind === KIND_CASK) {
      const v: Object | undefined = rec['version'];
      return typeof v === 'string' ? v as string : '';
    }
    const versions: Object | undefined = rec['versions'];
    if (versions === undefined || versions === null) {
      return '';
    }
    const vrec: Record<string, Object> = versions as Record<string, Object>;
    const stable: Object | undefined = vrec['stable'];
    return typeof stable === 'string' ? stable as string : '';
  }

  private static archivePath(): string {
    const uiContext: UIContext | undefined = AppStorage.get<UIContext>(StorageKey.UI_CONTEXT);
    const ctx: Context | undefined = uiContext === undefined ? undefined : uiContext.getHostContext();
    if (ctx === undefined) {
      return '';
    }
    return ctx.filesDir + '/' + RELEASE_INTEL_ARCHIVE_SEGMENT + '/' + RELEASE_INTEL_ARCHIVE_FILE;
  }

  private static writeArchive(entries: ReleaseIntelArchiveEntry[]): void {
    const path: string = ReleaseIntelService.archivePath();
    if (path.length === 0) {
      return;
    }
    const dir: string = path.substring(0, path.lastIndexOf('/'));
    const body: Record<string, Object> = {};
    const arr: Array<Object> = [];
    for (let i: number = 0; i < entries.length; i++) {
      const one: ReleaseIntelArchiveEntry = entries[i];
      const rec: Record<string, Object> = {};
      rec['token'] = one.token;
      rec['kind'] = one.kind;
      rec['from'] = one.from;
      rec['to'] = one.to;
      rec['at'] = one.at;
      rec['cardJson'] = one.cardJson;
      arr.push(rec as Object);
    }
    body['entries'] = arr as Object;
    let file: fileIo.File | undefined = undefined;
    const tempPath: string = path + '.tmp';
    try {
      fileIo.mkdirSync(dir, true);
      if (fileIo.accessSync(tempPath)) {
        fileIo.unlinkSync(tempPath);
      }
      file = fileIo.openSync(tempPath, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE |
        fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, JSON.stringify(body));
      fileIo.closeSync(file);
      file = undefined;
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
      fileIo.renameSync(tempPath, path);
      Logger.info(TAG, `archive written, count=${entries.length}`);
    } catch (error) {
      if (file !== undefined) {
        try {
          fileIo.closeSync(file);
        } catch (closeErr) {
          Logger.warn(TAG, `archive write close failed, code=${(closeErr as BusinessError)?.code}`);
        }
      }
      const err: BusinessError = error as BusinessError;
      Logger.error(TAG, `archive write failed, code=${err?.code}, msg=${err?.message}`);
    }
  }
}
