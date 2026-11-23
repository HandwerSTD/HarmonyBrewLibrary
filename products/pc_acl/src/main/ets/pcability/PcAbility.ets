import { AbilityConstant, UIAbility, Configuration, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { Logger, StorageKey } from '@ohos/common';
import { BrewManifestSyncService } from '@ohos/brewcommon';
import { ShellStreamProbe } from '@ohos/pcnative';
import { BaseAbilityHelper } from '@ohos/pcui';
import { SentinelBootstrap } from '../sentinel/SentinelBootstrap';
import { SkillProbe } from '../skill/SkillProbe';

const TAG: string = '[PcAbility]';

/** 通知「稍后」按钮的参数取值（与 BrewSentinelService.agentInfo 的键值成对） */
const SENTINEL_DISMISS_VALUE: string = '1';

export default class PcAbility extends UIAbility {
  private baseAbilityHelper: BaseAbilityHelper = new BaseAbilityHelper();

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    Logger.info(TAG, 'Ability onCreate');
    // 侧边栏布局与本机包能力开关由 entry 注入：带 ACL 的版本读写设备上的 Homebrew 安装记录
    AppStorage.setOrCreate<boolean>(StorageKey.IS_SIDEBAR_LAYOUT, true);
    AppStorage.setOrCreate<boolean>(StorageKey.BREW_CLI_ENABLED, true);
    // 内置 Harmonybrew 源只在能执行 brew 的产品上提供：安装命令要能跑，这个源才有用
    AppStorage.setOrCreate<boolean>(StorageKey.BREW_HARMONYBREW_SOURCE_ENABLED, true);
    // 执行通道启动自检。`SHELL_STREAM_VERIFY` 默认关闭，此时这里不会起任何子进程
    ShellStreamProbe.run();
    // P3 档保底（恒开）：订阅本机包快照更新 → 评估推卡 + 按频控发通知。档位开关在 SentinelBootstrap
    SentinelBootstrap.init(this.context);
    // 卡片点击 / 通知按钮经 want 进来：落进 AppStorage 待 UI 消费（G2/G4）
    this.captureSentinelWant(want);
    // Agent Skill 注册自检（G3 / Stage 0 探针）：只读查询本应用技能注册状态，只打日志
    SkillProbe.probe();
    // W′ 分布式清单同步（spec §3.3）：打开 KV 同步库 + 订阅远端变更 + 首次 sync。
    // init 不弹权限窗；DISTRIBUTED_DATASYNC 由常驻页 / Sheet 首开时动态申请
    BrewManifestSyncService.getInstance().init(this.context);
    this.baseAbilityHelper.doOnCreate(this.context, want, launchParam);
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    Logger.info(TAG, `onNewWant launchReason: ${launchParam.launchReason}`);
    this.captureSentinelWant(want);
    this.baseAbilityHelper.doOnNewWant(this.context, want, launchParam);
  }


  onDestroy(): void {
    Logger.info(TAG, 'Ability onDestroy');
    this.baseAbilityHelper.doOnDestroy();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    Logger.info(TAG, 'Ability onWindowStageCreate');
    this.baseAbilityHelper.doOnWindowStageCreate(this.context, windowStage);
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    this.baseAbilityHelper.doOnConfigurationUpdate(newConfig);
  }

  onWindowStageDestroy(): void {
    Logger.info(TAG, 'Ability onWindowStageDestroy');
    this.baseAbilityHelper.doOnWindowStageDestroy();
  }

  onForeground(): void {
    // Ability has brought to foreground
    Logger.info(TAG, 'Ability onForeground');
    this.baseAbilityHelper.doOnForeground();
    // P3 档：每次回前台评估一次快照。UI 尚未就绪时服务读不到快照会静默跳过，无副作用
    SentinelBootstrap.onForeground(this.context);
  }

  onBackground(): void {
    // Ability has back to background
    Logger.info(TAG, 'Ability onBackground');
    this.baseAbilityHelper.doOnBackground();
  }

  /**
   * 把哨兵相关 want 参数落进 AppStorage，等待 UI 侧消费（决策 6）。
   *
   * 两条进路（官方 router 事件文档口径）：
   *   - 卡片 postCardAction 的 router 事件：params 整体被序列化成 `parameters.params` 字符串；
   *   - 通知 wantAgent：parameters 平铺在 want.parameters 顶层。
   * 两处都认，先平铺后嵌套。消费端：路由 MineHomeView、「稍后」PcMainPage。
   *
   * 这里只落 AppStorage，不做导航——onCreate 阶段导航栈还没建起来，消费端就绪后再处理。
   */
  private captureSentinelWant(want: Want): void {
    const params: Record<string, Object> | undefined = want?.parameters;
    if (!params) {
      return;
    }
    let route: string = '';
    let dismiss: boolean = false;
    const directRoute: Object | undefined = params['sentinel_route'];
    if (directRoute !== undefined && directRoute !== null) {
      route = directRoute as string;
    }
    const directDismiss: Object | undefined = params['sentinel_dismiss'];
    if (directDismiss !== undefined && directDismiss !== null) {
      dismiss = (directDismiss as string) === SENTINEL_DISMISS_VALUE;
    }
    if (route.length === 0) {
      // 卡片 router 事件路径：嵌套 JSON 串。解析失败按「没有哨兵参数」处理
      const nestedRaw: Object | undefined = params['params'];
      if (nestedRaw !== undefined && nestedRaw !== null) {
        const nested: string = nestedRaw as string;
        if (nested.indexOf('sentinel_route') >= 0) {
          try {
            const parsed: Record<string, Object> = JSON.parse(nested) as Record<string, Object>;
            const nestedRoute: Object | undefined = parsed['sentinel_route'];
            if (nestedRoute !== undefined && nestedRoute !== null) {
              route = nestedRoute as string;
            }
          } catch (err) {
            Logger.warn(TAG, 'captureSentinelWant: nested params parse failed');
          }
        }
      }
    }
    if (route.length > 0) {
      AppStorage.setOrCreate<string>(StorageKey.SENTINEL_PENDING_ROUTE, route);
      Logger.info(TAG, `sentinel route pending: ${route}`);
    }
    if (dismiss) {
      AppStorage.setOrCreate<boolean>(StorageKey.SENTINEL_PENDING_DISMISS, true);
      Logger.info(TAG, 'sentinel dismiss pending');
    }
  }
}
