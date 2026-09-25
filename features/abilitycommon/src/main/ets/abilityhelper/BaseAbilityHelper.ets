/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { AbilityConstant, appRecovery, common, Configuration, ConfigurationConstant, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  BundleManagerUtil,
  DynamicInstallManager,
  Logger,
  PageContext,
  StorageKey,
  WebUtil,
  WindowUtil,
} from '@ohos/common';
import GlobalUIAbilityContext from '../util/ContextConfig';

const TAG = '[BaseAbilityHelper]';

export class BaseAbilityHelper {
  private context?: common.UIAbilityContext;

  constructor() {
  }

  public doOnCreate(context: common.UIAbilityContext, want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.context = context;
    appRecovery.enableAppRecovery(appRecovery.RestartFlag.RESTART_WHEN_JS_CRASH);
    Logger.info(TAG, `Ability onCreate launchReason: ${launchParam.launchReason}`);
    this.handleWantParam();
    AppStorage.setOrCreate(StorageKey.COLOR_MODE, this.context?.config.colorMode);
    try {
      this.context?.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      Logger.error(TAG, `onCreate setColorMode failed, ${err.code}, ${err.message}`);
    }
  }

  public doOnNewWant(context: common.UIAbilityContext, want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.context = context;
    Logger.info(TAG, `onNewWant launchReason: ${launchParam.launchReason}`);
    this.handleWantParam();
  }

  private handleWantParam(): void {
    AppStorage.setOrCreate(StorageKey.CONTEXT_ENTRY, this.context);
  }

  public doOnDestroy(): void {
    Logger.info(TAG, 'Ability onDestroy');
    DynamicInstallManager.unsubscribeDownloadProgress();
  }

  public doOnWindowStageCreate(context: common.UIAbilityContext, windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    Logger.info(TAG, 'Ability onWindowStageCreate');
    // Use for penkit component
    GlobalUIAbilityContext.setContext(context);
    AppStorage.setOrCreate(StorageKey.HOME_PAGE_CONTEXT, new PageContext());
    AppStorage.setOrCreate(StorageKey.MINE_PAGE_CONTEXT, new PageContext());
    AppStorage.setOrCreate(StorageKey.BREW_FORMULA_PAGE_CONTEXT, new PageContext());
    AppStorage.setOrCreate(StorageKey.BREW_CASK_PAGE_CONTEXT, new PageContext());
    BundleManagerUtil.getBundleInfo();
    windowStage.loadContent('page/SplashPage', (err: BusinessError) => {
      if (err.code) {
        Logger.error(TAG, `Failed to load the content. Cause: ${err.code} ${err.message}`);
        return;
      }
      WebUtil.initialize(windowStage);
      WindowUtil.initialize(windowStage);
      Logger.info(TAG, 'Succeeded in loading the content.');
    });
  }

  public doOnConfigurationUpdate(newConfig: Configuration): void {
    const newColorMode: ConfigurationConstant.ColorMode =
      newConfig.colorMode || ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    const currentColorMode = AppStorage.get<ConfigurationConstant.ColorMode>(StorageKey.COLOR_MODE);
    // When the system dark/light color mode is different form the app color mode,modify the app's color mode.
    if (newColorMode !== currentColorMode) {
      AppStorage.setOrCreate(StorageKey.COLOR_MODE, newColorMode);
    }
  }

  public doOnWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    WindowUtil.release();
    Logger.info(TAG, 'Ability onWindowStageDestroy');
  }

  public doOnForeground(): void {
    // Ability has brought to foreground
    Logger.info(TAG, 'Ability onForeground');
  }

  public doOnBackground(): void {
    // Ability has back to background
    Logger.info(TAG, 'Ability onBackground');
  }
}
