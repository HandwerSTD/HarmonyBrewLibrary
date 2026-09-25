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

/**
 * 搜索的 UI 侧常量：历史/发现的尺寸、落盘 key、chips 标识。
 *
 * 历史与发现**都是真实数据**（本轮变更，见 spec §8 的修订说明）：
 *   - 历史 = 用户真正执行过的搜索，落盘在 Preference（`BREW_SEARCH_HISTORY_KEY`）；
 *   - 发现 = 设备端目录里近 30 天安装量最高的真实包（`BrewSearchModel.hotTokens`）。
 * 这里因此只留尺寸与 key，**不再有写死的词组**：原先那两组词（`qoder`/`微信`…）在 Homebrew
 * 目录里一个都不存在，点下去必然空结果 —— 那是「版式还原」阶段的临时物。
 *
 * 也没有输入防抖常量：搜索改成**显式触发**（回车 / 点「搜索」/ 点建议项）后，
 * 不再存在「一串没人确认过的关键字被拿去跑全量匹配」这件事，防抖没有防的对象了。
 */

/** 历史落盘的 Preference key。读写只在 `BrewSearchHistoryStore`（唯一的持有者） */
export const BREW_SEARCH_HISTORY_KEY: string = 'brew_search_history';

/** 历史保留条数上限：超过就丢最旧的一条 */
export const BREW_SEARCH_HISTORY_LIMIT: number = 10;

/** 发现区一次展示的条数（2×2 版式） */
export const BREW_SEARCH_DISCOVERY_COUNT: number = 4;

/**
 * 发现池的大小（「换一批」的轮换范围）。
 *
 * 取 40 而不是 8：池子就是「本机目录的真实热门」，太小会每两下就轮回同一批，看着还是假的。
 * 40 条 = 10 批；归并只跑到第 40 个就停，不会为了这个池子遍历全量 1.3 万条。
 */
export const BREW_SEARCH_DISCOVERY_POOL_SIZE: number = 40;

/**
 * chips 的 id（`BrewChipItem` 的主键，只要求唯一）与过滤值（喂给引擎的 kind）。
 * 「全部」这项的 id 是 `'all'`，而它的**过滤值是空串**（引擎约定空串 = 不过滤）——
 * 两者不是一回事，所以分开命名。
 */
export const BREW_SEARCH_CHIP_ALL: string = 'all';
export const BREW_SEARCH_CHIP_FORMULA: string = 'formula';
export const BREW_SEARCH_CHIP_CASK: string = 'cask';

/** 历史 chips 换行时的横纵间距 */
export const BREW_SEARCH_CHIP_SPACE: number = 8;

/**
 * 搜索页输入框本体的高度（vp）。**布局与让位数学共用这一个常量** ——
 * 输入框行挂在标题栏的 `bottomBuilder` 上，标题栏是浮层，内容要靠 `topInset()` 手动让位；
 * 两处数字不一致就会出现「输入框盖住 chips」或「内容上方多一条空白」。
 */
export const BREW_SEARCH_BAR_HEIGHT: number = 40;

/**
 * HDS 间距令牌的**真实值**（vp）。规律是 **`levelN` = 2N vp** —— 名字里的数字要乘 2 才是 vp：
 * `level4`=8、`level6`=12、`level8`=16、`level12`=24、`level16`=32。
 *
 * 三处实测锚点（density 1.9，`ui layout`）：`level4`=8（输入框内侧留白 15px）、
 * `level8`=16（标题栏底区上侧留白 30px）、`level12`=24（chips 左右内缩 45px，窗口处于 **md** 档）；
 * 并与房屋惯例互证：`BaseHomeViewModel.setTitleBarStyle()` 的标题栏内缩在 sm/md/lg 档
 * 分别是 `SPACE_16`/`SPACE_24`/`SPACE_32` = 16/24/32vp，正好等于本组常量的三档。
 *
 * 为什么在这里写数字而不是用 `$r('sys.float.padding_levelN')`：
 * 标题栏的 `padding` 字段类型是 `LengthMetrics`（不是 `Length`），**资源型取不到**，
 * 只能 `LengthMetrics.vp(number)`。而标题栏与内容必须内缩一致（否则标题看着“没对齐”），
 * 所以数字必须是唯一真相，`$r()` 令牌只能出现在**不参与数学**的纯样式处。
 */
export const BREW_SEARCH_SPACE_LEVEL8: number = 16;
/** `padding_level12`：实测 45px ÷ density 1.9 = 23.7vp（md 档的标题栏与内容内缩都用它） */
export const BREW_SEARCH_SPACE_LEVEL12: number = 24;
/** `padding_level16`：未在本机实测（窗口不在 lg 档），按 `levelN = 2N` 与 `BaseHomeViewModel` 的 `SPACE_32` 互证 */
export const BREW_SEARCH_SPACE_LEVEL16: number = 32;

/**
 * 标题栏里「输入框行」的总高度 = 输入框 + 它与标题行之间的间距（`padding_level8`）。
 *
 * 三处引用必须同源：`BrewSearchResultView.topInset()`（内容让位）、
 * 标题栏 `bottomBuilder.height`（让位区实际有多高）、`TitleBarBottomBuilder` 的 `padding.top`。
 */
export const BREW_SEARCH_BAR_ROW_HEIGHT: number = BREW_SEARCH_BAR_HEIGHT + BREW_SEARCH_SPACE_LEVEL8;

/**
 * chips 行**下方**、内容**上方**的留白。
 *
 * 需求方真机反馈「全部/Formulae/Casks 下面还需要一个边距」：chips 自带的下内边距很窄，
 * 下面的「共 N 个结果」或分区标题会直接贴上来。这一档必须同时计入 `bottomBuilder.height`
 * 与 `topInset()`，否则留白会被内容当成“可以钻到标题栏底下”的区域。
 *
 * 取值 12（= `padding_level6` 的真实值）：需求方看过 16 的实物后要求收紧一档。
 */
export const BREW_SEARCH_CHIP_ROW_GAP: number = 12;
