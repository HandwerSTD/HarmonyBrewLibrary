import { AbilityConstant, UIAbility, Configuration, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { Logger, StorageKey } from '@ohos/common';
import { ShellStreamProbe } from '@ohos/pcnative';
import { BaseAbilityHelper } from '@ohos/pcui';
import { SkillProbe } from '../skill/SkillProbe';

const TAG: string = '[PcAbility]';

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
    // Agent Skill 注册自检（G3 / Stage 0 探针）：只读查询本应用技能注册状态，只打日志
    SkillProbe.probe();
    this.baseAbilityHelper.doOnCreate(this.context, want, launchParam);
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    Logger.info(TAG, `onNewWant launchReason: ${launchParam.launchReason}`);
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
  }

  onBackground(): void {
    // Ability has back to background
    Logger.info(TAG, 'Ability onBackground');
    this.baseAbilityHelper.doOnBackground();
  }
}