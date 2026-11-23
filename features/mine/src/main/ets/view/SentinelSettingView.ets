/*
 * Copyright (c) 2025 Huawei Device Co., Ltd.
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

import type { common } from '@kit.AbilityKit';
import type { BusinessError } from '@kit.BasicServicesKit';
import { notificationManager } from '@kit.NotificationKit';
import { HmosListItem, Logger } from '@ohos/common';
import { BrewSentinelService, SENTINEL_FREQUENCY_DAILY, SENTINEL_FREQUENCY_OFF,
  SENTINEL_FREQUENCY_WEEKLY } from '@ohos/brewcommon';

const TAG: string = '[SentinelSetting]';

/** 用户拒绝通知授权的错误码（与 BrewSentinelService 同一口径） */
const ERR_NOTIFICATION_REFUSED: number = 1600004;

/**
 * 「我的 - 设置 - 更新哨兵」子页（spec §4）。
 *
 * 两行：
 *   - 提醒频率：关 / 每天 / 每周，点按循环切换并持久化到 GSKV（哨兵键，跨进程）；
 *   - 桌面通知授权：已授权显示「已开启」不可点；未授权显示「去开启」——首次
 *     requestEnableNotification，被拒绝过（接口不再弹窗）后改拉通知设置半模态二次申请。
 *     用户再拒绝就静默收场（G8：不崩、不反复弹）。
 *
 * 频控「关」只停通知不停卡片（G7）：这里没有卡片开关，卡片由哨兵服务恒推。
 */
@Component
struct SentinelSettingView {
  pathStack: NavPathStack = new NavPathStack();
  /** 当前频控档位。aboutToAppear 从 GSKV 读初值 */
  @State frequency: string = SENTINEL_FREQUENCY_DAILY;
  /** 通知授权状态。同步接口取值，进入页面即反映系统设置的真实状态 */
  @State authorized: boolean = false;

  aboutToAppear(): void {
    const service: BrewSentinelService = BrewSentinelService.getInstance();
    this.frequency = service.getFrequency(this.hostContext());
    try {
      this.authorized = notificationManager.isNotificationEnabledSync();
    } catch (err) {
      // 查询失败按未授权展示：显示「去开启」，点击后真实接口会给出结果
      this.authorized = false;
    }
  }

  /** 宿主 UIAbilityContext。本页只在宿主进程可达（pc_normal 无哨兵入口），直接收窄 */
  private hostContext(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private frequencyLabel(): ResourceStr {
    if (this.frequency === SENTINEL_FREQUENCY_OFF) {
      return $r('app.string.sentinel_freq_off');
    }
    if (this.frequency === SENTINEL_FREQUENCY_WEEKLY) {
      return $r('app.string.sentinel_freq_weekly');
    }
    return $r('app.string.sentinel_freq_daily');
  }

  /** 关 → 每天 → 每周 → 关 循环（spec §4：点按循环切换） */
  private cycleFrequency(): void {
    const service: BrewSentinelService = BrewSentinelService.getInstance();
    let next: string = SENTINEL_FREQUENCY_DAILY;
    if (this.frequency === SENTINEL_FREQUENCY_DAILY) {
      next = SENTINEL_FREQUENCY_WEEKLY;
    } else if (this.frequency === SENTINEL_FREQUENCY_WEEKLY) {
      next = SENTINEL_FREQUENCY_OFF;
    } else {
      next = SENTINEL_FREQUENCY_DAILY;
    }
    this.frequency = next;
    service.setFrequency(this.hostContext(), next);
  }

  private requestAuthorization(): void {
    const context: common.UIAbilityContext = this.hostContext();
    notificationManager.requestEnableNotification(context).then(() => {
      this.authorized = true;
      Logger.info(TAG, 'notification authorized from setting');
    }).catch((err: BusinessError) => {
      if (err.code !== ERR_NOTIFICATION_REFUSED) {
        Logger.warn(TAG, `requestEnableNotification failed code=${err.code}`);
        return;
      }
      // 拒绝后 requestEnableNotification 不再弹窗（官方口径）：拉通知设置半模态二次申请
      notificationManager.openNotificationSettingsWithResult(context).then(() => {
        // 半模态关闭后按系统真实状态刷新展示；用户仍未开启就静默（G8）
        this.authorized = notificationManager.isNotificationEnabledSync();
      }).catch((settingsErr: BusinessError) => {
        Logger.info(TAG, `openNotificationSettings closed code=${settingsErr.code}`);
        this.authorized = notificationManager.isNotificationEnabledSync();
      });
    });
  }

  build() {
    Navigation(this.pathStack) {
      Column() {
        List() {
          ListItemGroup() {
            ListItem() {
              HmosListItem({
                title: $r('app.string.sentinel_setting_frequency'),
                desc: this.frequencyLabel(),
                handleClickAction: () => {
                  this.cycleFrequency();
                }
              })
            }
            .padding({
              left: $r('sys.float.padding_level2'),
              right: $r('sys.float.padding_level2'),
            })
            ListItem() {
              if (this.authorized) {
                HmosListItem({
                  title: $r('app.string.sentinel_setting_auth'),
                  desc: $r('app.string.sentinel_setting_auth_on')
                })
              } else {
                HmosListItem({
                  title: $r('app.string.sentinel_setting_auth'),
                  buttonTitle: $r('app.string.sentinel_setting_auth_go'),
                  handleClickAction: () => {
                    this.requestAuthorization();
                  }
                })
              }
            }
            .padding({
              left: $r('sys.float.padding_level2'),
              right: $r('sys.float.padding_level2'),
            })
          }
          .divider({
            strokeWidth: $r('app.float.mine_divider'),
            color: $r('sys.color.comp_divider'),
            startMargin: $r('sys.float.padding_level6'),
            endMargin: $r('sys.float.padding_level6'),
          })
          .padding({
            top: $r('sys.float.padding_level2'),
            bottom: $r('sys.float.padding_level2'),
          })
          .backgroundColor($r('sys.color.comp_background_primary'))
          .borderRadius($r('sys.float.corner_radius_level8'))
        }
      }
      .padding($r('sys.float.padding_level8'))
      .height('100%')
      .width('100%')
    }
    .backgroundColor($r('sys.color.background_secondary'))
    .hideBackButton(true)
    .title($r('app.string.sentinel_setting_row'))
    .titleMode(NavigationTitleMode.Mini)
    .padding({ top: $r('sys.float.padding_level4') })
    .mode(NavigationMode.Stack)
  }
}

@Builder
export function SentinelSettingBuilder() {
  SentinelSettingView()
}
