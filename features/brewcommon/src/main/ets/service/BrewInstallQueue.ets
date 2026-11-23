/**
 * W′ 批量安装队列（spec §3.7）。
 *
 * 落盘 filesDir/brew_state/install_queue.json（不属于 CacheAdmin 的生命周期——
 * 队列是用户明确排期的数据，清缓存不误删）。逐条独立 `brew install` 失败域
 * 隔离（单条 FAILED 不影响其余）；事件驱动复用 BrewCommandRunner（订阅其
 * 终态，收干净了再推进下一条），BUSY 不抢（runner 单飞语义保持）。
 *
 * 宏观/微观分工（spec §5）：队列条目是宏观进度（PENDING→RUNNING→DONE/FAILED），
 * 命令 Sheet 输出是微观流水；「查看进度」把命令 Sheet 拉起即可。
 */
import { fileIo } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { UIContext } from '@kit.ArkUI';
import { Logger, StorageKey } from '@ohos/common';
import { BrewCli } from './BrewCli';
import { BrewCommandGenerator } from '../util/BrewCommandGenerator';
import { BrewCommandRunner } from './BrewCommandRunner';
import {
  BrewCommandRequest,
  BrewCommandStartResult,
  BrewCommandStatus,
  isBrewCommandEnded
} from '../model/BrewCommandModels';
import { BrewKind } from '../model/BrewModels';
import {
  BrewQueueDoc,
  BrewQueueItem,
  BrewQueueStatus,
  parseBrewQueueItem
} from '../model/BrewSyncModels';

const TAG: string = '[queue]';
const QUEUE_DIR_NAME: string = 'brew_state';
const QUEUE_FILE_NAME: string = 'install_queue.json';

/**
 * 队列单例。状态本体是 @Observed BrewQueueDoc 的 items 数组持有者。
 */
export class BrewInstallQueue {
  private static instance: BrewInstallQueue | null = null;

  private items: BrewQueueItem[] = [];
  private loaded: boolean = false;
  private kicking: boolean = false;
  private runnerListener: (() => void) | null = null;
  private queueDir: string = '';

  private constructor() {
  }

  public static getInstance(): BrewInstallQueue {
    if (BrewInstallQueue.instance === null) {
      BrewInstallQueue.instance = new BrewInstallQueue();
    }
    return BrewInstallQueue.instance;
  }

  // ---------------------------------------------------------------- 加载/落盘

  /** 首次使用时读盘（懒加载：filesDir 要等 UIContext 就绪）。 */
  private ensureLoaded(): void {
    if (this.loaded) {
      return;
    }
    this.loaded = true;
    try {
      const dir: string = this.resolveDir();
      if (dir.length === 0) {
        return;
      }
      const path: string = `${dir}/${QUEUE_FILE_NAME}`;
      if (!fileIo.accessSync(path)) {
        return;
      }
      const fd: number = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY).fd;
      const size: number = fileIo.statSync(fd).size;
      const buf: ArrayBuffer = new ArrayBuffer(size);
      fileIo.readSync(fd, buf);
      fileIo.closeSync(fd);
      // ArrayBuffer → string 用 util.TextDecoder（与 BrewCatalogFile / AiCache 同款）
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      const raw: string = decoder.decodeToString(new Uint8Array(buf), { stream: false }).trim();
      if (raw.length === 0) {
        return;
      }
      const parsed: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
      const rawItems: Object = parsed['items'];
      if (rawItems instanceof Array) {
        const arr: Object[] = rawItems as Object[];
        for (const one of arr) {
          const item: BrewQueueItem | null = parseBrewQueueItem(one);
          if (item !== null) {
            // 进程重启后 RUNNING 悬置：命令早没了，拉回 PENDING 重跑
            if (item.status === BrewQueueStatus.RUNNING) {
              item.status = BrewQueueStatus.PENDING;
            }
            this.items.push(item);
          }
        }
      }
      Logger.info(TAG, `load items=${this.items.length}`);
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.warn(TAG, `load failed code=${e.code} msg=${e.message}`);
    }
  }

  /** 临时文件写 + rename（renameSync 不覆盖已存在目标，先 unlink）。 */
  private persist(): void {
    try {
      const dir: string = this.resolveDir();
      if (dir.length === 0) {
        return;
      }
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir, true);
      }
      const path: string = `${dir}/${QUEUE_FILE_NAME}`;
      const tmp: string = `${path}.tmp`;
      const fd: number = fileIo.openSync(tmp,
        fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC).fd;
      const doc: BrewQueueDoc = new BrewQueueDoc();
      doc.items = this.items;
      fileIo.writeSync(fd, JSON.stringify(doc));
      fileIo.closeSync(fd);
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
      fileIo.renameSync(tmp, path);
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.warn(TAG, `persist failed code=${e.code} msg=${e.message}`);
    }
  }

  private resolveDir(): string {
    if (this.queueDir.length > 0) {
      return this.queueDir;
    }
    try {
      const uiContext: UIContext | undefined = AppStorage.get<UIContext>(StorageKey.UI_CONTEXT);
      if (uiContext === undefined) {
        return '';
      }
      const host = uiContext.getHostContext();
      if (host === undefined) {
        return '';
      }
      this.queueDir = `${host.filesDir}/${QUEUE_DIR_NAME}`;
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      Logger.warn(TAG, `resolve dir failed code=${e.code} msg=${e.message}`);
    }
    return this.queueDir;
  }

  // ---------------------------------------------------------------- 入队（§3.7 闸）

  /**
   * 入队（安装所选按钮 / 行内加队都走这里）。
   *
   * 闸：BrewCli 能力（G9——pc_normal 无按钮，这里再挡一层）；isSafeName
   * 不合法的包在入队前拒（返回 false 由调用方 Toast）。
   */
  public enqueue(token: string, kind: BrewKind, tap: string): boolean {
    if (!BrewCli.isEnabled()) {
      return false;
    }
    if (!BrewCommandGenerator.isSafeName(token) ||
      (tap.length > 0 && !BrewCommandGenerator.isSafeName(tap))) {
      Logger.warn(TAG, `enqueue rejected unsafe token=${token} tap=${tap}`);
      return false;
    }
    this.ensureLoaded();
    const identity: string = BrewQueueItem.identityOf(kind, tap, token);
    for (const one of this.items) {
      if (one.identity() === identity) {
        // 已在队列（或已完成）——不重复排
        return true;
      }
    }
    const item: BrewQueueItem = new BrewQueueItem();
    item.token = token;
    item.kind = kind;
    item.tap = tap;
    item.status = BrewQueueStatus.PENDING;
    item.queuedAt = Date.now();
    item.finishedAt = 0;
    this.items.push(item);
    this.persist();
    Logger.info(TAG, `enqueue token=${BrewCommandGenerator.qualifiedName(token, tap)} remain=${this.pendingCount()}`);
    this.kick();
    return true;
  }

  // ---------------------------------------------------------------- 推进（事件驱动）

  /** 有 PENDING 且 runner 空闲时启动下一条；BUSY 不抢。 */
  public kick(): void {
    this.ensureLoaded();
    if (this.kicking) {
      return;
    }
    if (!BrewCli.isEnabled() || !BrewCli.isReady()) {
      return;
    }
    const next: BrewQueueItem | undefined = this.items.find((one: BrewQueueItem): boolean =>
      one.status === BrewQueueStatus.PENDING);
    if (next === undefined) {
      return;
    }
    const runner: BrewCommandRunner = BrewCommandRunner.getInstance();
    if (runner.isRunning()) {
      return;
    }
    this.attachRunnerListener();
    const name: string = BrewCommandGenerator.qualifiedName(next.token, next.tap);
    const request: BrewCommandRequest = new BrewCommandRequest(
      name, 'brew', BrewCommandGenerator.installArgs(next.kind, next.token, next.tap));
    const started: BrewCommandStartResult = runner.start(request);
    if (started !== BrewCommandStartResult.STARTED) {
      // BUSY / UNAVAILABLE：不置 RUNNING，下次事件再试
      Logger.info(TAG, `kick deferred token=${name} result=${started}`);
      return;
    }
    this.kicking = true;
    next.status = BrewQueueStatus.RUNNING;
    this.persist();
    Logger.info(TAG, `start token=${name} remain=${this.pendingCount()}`);
  }

  /** 订阅 runner 终态一次（订阅者存字段，终态收干净后推进下一条）。 */
  private attachRunnerListener(): void {
    if (this.runnerListener !== null) {
      return;
    }
    this.runnerListener = (): void => {
      const runner: BrewCommandRunner = BrewCommandRunner.getInstance();
      const status: BrewCommandStatus = runner.getState().status;
      if (!isBrewCommandEnded(status)) {
        return;
      }
      const running: BrewQueueItem | undefined = this.items.find((one: BrewQueueItem): boolean =>
        one.status === BrewQueueStatus.RUNNING);
      if (running !== undefined) {
        running.finishedAt = Date.now();
        running.status = status === BrewCommandStatus.DONE ?
          BrewQueueStatus.DONE : BrewQueueStatus.FAILED;
        this.persist();
        const name: string = BrewCommandGenerator.qualifiedName(running.token, running.tap);
        Logger.info(TAG, `${running.status === BrewQueueStatus.DONE ? 'ok' : 'fail'} token=${name} ` +
          `remain=${this.pendingCount()}`);
      }
      this.kicking = false;
      this.kick();
    };
    BrewCommandRunner.getInstance().subscribe(this.runnerListener);
  }

  // ---------------------------------------------------------------- 查询/操作

  public snapshot(): BrewQueueItem[] {
    this.ensureLoaded();
    return this.items;
  }

  public pendingCount(): number {
    let count: number = 0;
    for (const one of this.items) {
      if (one.status === BrewQueueStatus.PENDING || one.status === BrewQueueStatus.RUNNING) {
        count += 1;
      }
    }
    return count;
  }

  public isRunning(): boolean {
    for (const one of this.items) {
      if (one.status === BrewQueueStatus.RUNNING) {
        return true;
      }
    }
    return false;
  }

  /** 单条重试（FAILED 行的重试按钮）：置回 PENDING + kick。 */
  public retry(item: BrewQueueItem): void {
    if (item.status !== BrewQueueStatus.FAILED) {
      return;
    }
    item.status = BrewQueueStatus.PENDING;
    item.finishedAt = 0;
    this.persist();
    this.kick();
  }

  /** 清掉已完成/已失败条目（收尾动作，队列只剩待装时不清）。 */
  public clearFinished(): void {
    const before: number = this.items.length;
    this.items = this.items.filter((one: BrewQueueItem): boolean =>
      one.status === BrewQueueStatus.PENDING || one.status === BrewQueueStatus.RUNNING);
    if (this.items.length !== before) {
      this.persist();
    }
  }

  /** 队列某包的条目（同步行状态 chip 的数据源）。 */
  public itemOf(kind: BrewKind, tap: string, token: string): BrewQueueItem | undefined {
    this.ensureLoaded();
    const identity: string = BrewQueueItem.identityOf(kind, tap, token);
    return this.items.find((one: BrewQueueItem): boolean => one.identity() === identity);
  }
}

