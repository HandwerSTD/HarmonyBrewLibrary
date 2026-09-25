import { AbilityConstant, UIAbility, Configuration, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { Logger, StorageKey } from '@ohos/common';
import { BaseAbilityHelper } from '@ohos/abilitycommon';

const TAG: string = '[PcAbility]';

export default class PcAbility extends UIAbility {
  private baseAbilityHelper: BaseAbilityHelper = new BaseAbilityHelper();

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    Logger.info(TAG, 'Ability onCreate');
    AppStorage.setOrCreate<boolean>(StorageKey.IS_SIDEBAR_LAYOUT, true);
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
