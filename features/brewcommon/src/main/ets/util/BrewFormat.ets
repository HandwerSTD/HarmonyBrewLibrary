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

import { BrewKind } from '../model/BrewModels';

/**
 * 热度表达的格式化工具。
 *
 * 决策：Homebrew 没有评分/评论，热度只用「近 30 天安装量 + 分类内排名」表达。
 * 这两个数字在列表行右侧很挤，因此安装量按 1.2M / 35.6k / 812 三档压缩。
 */
export class BrewFormat {
  /** 35603 -> '35.6k'，1200000 -> '1.2M'，812 -> '812' */
  public static compactCount(value: number): string {
    if (!value || value <= 0) {
      return '0';
    }
    if (value >= 1000000) {
      return `${(value / 1000000).toFixed(1)}M`;
    }
    if (value >= 1000) {
      return `${(value / 1000).toFixed(1)}k`;
    }
    return value.toString();
  }

  /** 分类内排名，如 3/14 -> '3 / 14' */
  public static rankText(rank: number, size: number): string {
    return `${rank} / ${size}`;
  }

  /**
   * Discover 榜单里的 `kind` 字符串 -> `BrewKind`。
   *
   * 榜单数据里的 kind 是 `'formula' | 'cask'`（与 Homebrew API 的 URL 段一致），
   * 详情页路由参数要的是 `BrewKind` 枚举，所以在这里收一处转换，
   * 不要在每个调用点各写一遍三元表达式。
   */
  public static brewKindOf(kind: string): BrewKind {
    return kind === 'cask' ? BrewKind.CASK : BrewKind.FORMULA;
  }
}
