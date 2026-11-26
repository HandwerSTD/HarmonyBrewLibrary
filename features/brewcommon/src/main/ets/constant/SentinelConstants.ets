/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

/**
 * 更新哨兵（桌面卡片）的常量。二期起通知链路整体移除（用户裁定无意义，
 * spec docs/superpowers/specs/2026-11-24-sentinel-phase2-spec.md §2.1/§3），触达只剩桌面卡片。
 *
 * 为什么不入 `CommonEnums.StorageKey`：哨兵的持久化键是**跨进程**的（宿主 UIAbility 进程与
 * FormExtensionAbility / WorkSchedulerExtension 扩展进程共用同一份 GSKV store），读写走
 * `preferences.getPreferencesSync`；而 `StorageKey` 全部是 AppStorage 键，AppStorage 只在
 * 单个进程内有效（见一期 spec §2）。两套键混在一个枚举里，迟早有人在扩展进程里拿哨兵键去查
 * AppStorage —— 所以从物理上分开。
 *
 * 三档调度的档位开关也收在这里。**当前全部是默认档（P1 休眠 / P2 开 / P3 恒开），
 * 真机探针后按 docs/knowledge/2026-11-22-sentinel-probe.md 的结论回改（G12）**：
 *   - P1：`SENTINEL_WORK_SCHEDULER_ENABLED` 探针 Q3 通过后翻 true；
 *   - P2：form_config 的 updateEnabled/updateDuration，探针 Q2 结论后调整；
 *   - P3：SentinelBootstrap + PcAbility.onForeground，恒开，无开关。
 */

// ---------------------------------------------------------------- GSKV store

/** 哨兵专用 store 名。宿主进程与扩展进程各用自己的 context.getApplicationContext() 打开同一份 */
export const SENTINEL_PREFERENCES_NAME: string = 'brew_sentinel';

// ---------------------------------------------------------------- preferences 键

/**
 * formId 登记表：JSON 数组字符串。onAddForm 登记 / onRemoveForm 注销 / 推卡遍历都读它。
 *
 * 二期 v2 格式：`[{"id":"...","dimension":"2*4"}]`（二期 spec §6.2）；一期 v1 格式
 * （纯 formId 字符串数组）仍可解析，规格一律兜底默认规格（F 线起是 2*4，见
 * SENTINEL_DIMENSION_DEFAULT），下次 onAddForm 按真实规格覆写。
 */
export const SENTINEL_KEY_FORM_IDS: string = 'sentinel_form_ids';

/**
 * 卡片数据镜像：JSON 序列化的 SentinelCardBase（readAt/count/items，二期 spec §6.1）。
 * 宿主进程每次评估把快照派生结果写进来，扩展进程（P1/P2 定时触发、卡片重添加首渲染）
 * 读它渲染真实数据——扩展进程读不到 BrewInstalledLoader 的盘上快照（探针文档 Q5）。
 * 一期 v1 格式（topNames 无 items）按 miss 处理 → 引导态，宿主一次评估后自愈（W9）。
 */
export const SENTINEL_KEY_LAST_CARD: string = 'sentinel_last_card';

// ---------------------------------------------------------------- 数据口径

/**
 * 快照陈旧阈值。超过它：卡片降显「打开应用刷新」（W7 / 一期 G9 同口径）。
 *
 * 盘上快照的新鲜窗口是 10 分钟（BREW_INSTALLED_FRESH_MS，应用侧决定何时重跑命令），
 * 哨兵只读不跑，所以这里用「卡片还能不能诚实地叫它实时」的口径取 24h。
 */
export const SENTINEL_STALE_MS: number = 24 * 60 * 60 * 1000;

/** 卡片版本对列表的条数上限：镜像 items 最多 6 条（二期 spec §6.1，4*4 列表容量） */
export const SENTINEL_CARD_ITEMS_LIMIT: number = 6;

/**
 * 卡片 top3 包名单行的条数上限（二期 spec §5.1 ④「jq、ripgrep、wget 等 9 个」）。
 * 卡片页按「零 import」约束使用同值字面量取 items[0..2]，这里保留常量作契约锚点，
 * 两处必须成对修改。
 */
export const SENTINEL_TOP_NAMES_LIMIT: number = 3;

// ---------------------------------------------------------------- 卡片规格

/**
 * 卡片规格字符串：form_config.supportDimensions 与 DIMENSION_KEY 归一后的统一口径
 * （二期 spec §6.3）。HarmonyOS 规格语义 = 行*列：2*4 宽横条 / 4*4 大方卡
 * （2*4 与 4*4 之间可拖拽 resize，官方 FAQ faqs-form-18）。
 *
 * F 线（关注更新）起 **2*2 规格整体下线**（用户裁定：小方卡装不下「只看关注」的列表语义，
 * 2*4/4*4 才是更新提醒的正式形态）：form_config 只登记两规格，未知值（含存量 2*2 卡
 * 的登记残影）一律兜底 2*4。
 */
export const SENTINEL_DIMENSION_2_4: string = '2*4';
export const SENTINEL_DIMENSION_4_4: string = '4*4';

/** 未知规格的兜底值。DIMENSION_KEY 实测值格式（串/数值枚举）探针 Q1+ 确认后收口 */
export const SENTINEL_DIMENSION_DEFAULT: string = SENTINEL_DIMENSION_2_4;

// ---------------------------------------------------------------- 卡片数据键

/**
 * FormBindingData 里给卡片页（LocalStorageProp）消费的键名（二期 spec §6.4）。
 *
 * 常量化而不是在 service 与卡片页各写一份字符串字面量：两处不一致就是「推了数据卡片不亮」，
 * 而且这种错编译期发现不了。卡片页按「零 import」约束使用同名字面量，两边必须成对修改。
 */
export const SENTINEL_DATA_FORM_ID: string = 'sentinelFormId';
export const SENTINEL_DATA_DIMENSION: string = 'sentinelDimension';
export const SENTINEL_DATA_HAS_SNAPSHOT: string = 'sentinelHasSnapshot';
/**
 * 用户是否一个关注都没有（F 线）。真 = 卡片给「关注空态」引导，而不是
 * 把「没有关注」误报成「全部最新」（零更新态的语义在 F 线后收窄为
 * 「关注中的包都已是最新」）。
 */
export const SENTINEL_DATA_FOLLOW_EMPTY: string = 'sentinelFollowEmpty';
export const SENTINEL_DATA_COUNT: string = 'sentinelCount';
export const SENTINEL_DATA_ITEMS: string = 'sentinelItems';
export const SENTINEL_DATA_AS_OF: string = 'sentinelAsOfText';
export const SENTINEL_DATA_STALE: string = 'sentinelStale';

// ---------------------------------------------------------------- want 参数键

/** 卡片 postCardAction 的路由参数键。值是 PageEnum 的路由名（一期 G2 / 二期 N3） */
export const SENTINEL_WANT_KEY_ROUTE: string = 'sentinel_route';

// ---------------------------------------------------------------- 卡片定义

/** form_config.json 里本卡片的 name。登记日志用它对账 */
export const SENTINEL_FORM_NAME: string = 'BrewSentinelCard';

// ---------------------------------------------------------------- P1 档（work scheduler）

/**
 * **P1 档总开关，默认关（休眠）**。
 *
 * work scheduler 在应用退出于 2in1 上的触发行为（间隔、冻结态、重启后 isPersisted 恢复）
 * 未探明（一期 spec §3.2 Q3）。实现与注册已就位，但 app 侧不 startWork；探针结论可用后把它翻成
 * true，并按 docs/knowledge/2026-11-22-sentinel-probe.md §4 的指引核对间隔常量（G12）。
 */
export const SENTINEL_WORK_SCHEDULER_ENABLED: boolean = false;

/** 延迟任务的 workId。startWork 同 workId 会覆盖旧登记，重复 init 不会叠加 */
export const SENTINEL_WORK_ID: number = 20261122;

/**
 * P1 档的循环间隔（ms）。
 *
 * work scheduler 对 repeatCycleTime 有下限约束（系统档位按分组限制，普通应用实测不低于 1h），
 * 这里取 2h 作为探针前的占位：真机实测（Q3）若被系统拉高或冻结，以探针结论回改。
 */
export const SENTINEL_WORK_INTERVAL_MS: number = 2 * 60 * 60 * 1000;
