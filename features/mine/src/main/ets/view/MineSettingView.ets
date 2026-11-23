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

import { CommonConstants, GlobalInfoModel, HmosListItem, PageEnum, StorageKey } from '@ohos/common';
import { isLocalPackagesEnabled } from '../viewmodel/MinePageVM';
import { SettingState } from '../viewmodel/SettingState';
import { InitEvent, SettingPageVM } from '../viewmodel/SettingPageVM';

@Component
struct MineSettingView {
  pathStack: NavPathStack = new NavPathStack();
  @StorageProp(StorageKey.GLOBAL_INFO) globalInfoModel: GlobalInfoModel =
    AppStorage.get(StorageKey.GLOBAL_INFO) ?? new GlobalInfoModel();
  viewModel: SettingPageVM = SettingPageVM.getInstance();
  @State settingState: SettingState = this.viewModel.getState();

  aboutToAppear(): void {
    this.viewModel.sendEvent(new InitEvent());
  }

  build() {
    Navigation(this.pathStack) {
      Column() {
        List() {
          ListItemGroup() {
            ListItem() {
              HmosListItem({
                title: $r('app.string.brew_source_title'),
                handleClickAction: () => {
                  this.pathStack.pushPath({ name: PageEnum.BREW_SOURCE_SETTING_VIEW });
                }
              })
            }
            .padding({
              left: $r('sys.float.padding_level2'),
              right: $r('sys.float.padding_level2'),
            })
            ListItem() {
              HmosListItem({
                title: $r('app.string.ai_settings_title'),
                handleClickAction: () => {
                  this.pathStack.pushPath({ name: PageEnum.MINE_AI_SETTINGS_VIEW });
                }
              })
            }
            .padding({
              left: $r('sys.float.padding_level2'),
              right: $r('sys.float.padding_level2'),
            })
            // W′ 工具清单同步（spec §4.3）：常驻入口。「AI 设置」行下、哨兵行上；
            // 不挂 isLocalPackagesEnabled()——同步查看与 AI 配置应用在 pc_normal 也是真功能。
            ListItem() {
              HmosListItem({
                title: $r('app.string.mine_setting_manifest_sync'),
                handleClickAction: () => {
                  this.pathStack.pushPath({ name: PageEnum.BREW_MANIFEST_SYNC_VIEW });
                }
              })
            }
            .padding({
              left: $r('sys.float.padding_level2'),
              right: $r('sys.float.padding_level2'),
            })
            // 更新哨兵（H 线）：卡片 + 通知的频控入口。只在 pc_acl 展示——哨兵的一切数据
            // 与通知都来自 brew cli 能力，pc_normal 没有这个能力，入口也随之隐藏（G10）。
            // 放在「关于」之前：「关于」固定收尾
            if (isLocalPackagesEnabled()) {
              ListItem() {
                HmosListItem({
                  title: $r('app.string.sentinel_setting_row'),
                  handleClickAction: () => {
                    this.pathStack.pushPath({ name: PageEnum.SENTINEL_SETTING_VIEW });
                  }
                })
              }
              .padding({
                left: $r('sys.float.padding_level2'),
                right: $r('sys.float.padding_level2'),
              })
            }
            ListItem() {
              HmosListItem({
                title: $r('app.string.about'),
                handleClickAction: () => {
                  this.pathStack.pushPath({ name: 'AboutView' });
                }
              })
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
      .height(CommonConstants.FULL_PERCENT)
      .width(CommonConstants.FULL_PERCENT)
      .justifyContent(FlexAlign.SpaceBetween)
    }
    .backgroundColor($r('sys.color.background_secondary'))
    .hideBackButton(true)
    .title($r('app.string.setting'))
    .titleMode(NavigationTitleMode.Mini)
    .padding({ top: $r('sys.float.padding_level4') })
    .mode(NavigationMode.Stack)
  }
}

@Builder
export function MineSettingBuilder() {
  MineSettingView()
}