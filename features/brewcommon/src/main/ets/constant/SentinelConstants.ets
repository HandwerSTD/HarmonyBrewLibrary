/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

/**
 * 更新哨兵（桌面卡片 + 系统通知）的常量。
 *
 * 为什么不入 `CommonEnums.StorageKey`：哨兵的持久化键是**跨进程**的（宿主 UIAbility 进程与
 * FormExtensionAbility / WorkSchedulerExtension 扩展进程共用同一份 GSKV store），读写走
 * `preferences.getPreferencesSync`；而 `StorageKey` 全部是 AppStorage 键，AppStorage 只在
 * 单个进程内有效（见 spec §2）。两套键混在一个枚举里，迟早有人在扩展进程里拿哨兵键去查
 * AppStorage —— 所以从物理上分开。
 *
 * 三档调度的档位取值也收在这里。**当前全部是默认档（P1 休眠 / P2 开 / P3 恒开），
 * 真机探针后按 docs/knowledge/2026-11-22-sentinel-probe.md 的结论回改（G12）**：
 *   - P1：`SENTINEL_WORK_SCHEDULER_ENABLED` 探针 Q3 通过后翻 true；
 *   - P2：form_config 的 updateEnabled/updateDuration，探针 Q2 结论后调整；
 *   - P3：SentinelBootstrap + PcAbility.onForeground，恒开，无开关。
 */

// ---------------------------------------------------------------- GSKV store

/** 哨兵专用 store 名。宿主进程与扩展进程各用自己的 context.getApplicationContext() 打开同一份 */
export const SENTINEL_PREFERENCES_NAME: string = 'brew_sentinel';

// ---------------------------------------------------------------- preferences 键

/** formId 登记表：JSON 数组字符串。onAddForm 登记 / onRemoveForm 注销 / 推卡遍历都读它 */
export const SENTINEL_KEY_FORM_IDS: string = 'sentinel_form_ids';

/**
 * 卡片数据镜像：JSON 序列化的 SentinelCardBase（readAt/count/topNames）。
 * 宿主进程每次评估把快照派生结果写进来，扩展进程（P1/P2 定时触发、卡片重添加首渲染）
 * 读它渲染真实数据——扩展进程读不到 BrewInstalledLoader 的盘上快照（探针文档 Q5）。
 */
export const SENTINEL_KEY_LAST_CARD: string = 'sentinel_last_card';

/** 上次成功发布通知的集合键（outdated 的 fullName 排序 join）。相等 = 同一集合，不通知（G6） */
export const SENTINEL_KEY_LAST_SET: string = 'sentinel_last_set';

/** 上次成功发布通知的日期字符串（yyyy-MM-dd）。频控「每天/每周」以它判定（spec §3.4） */
export const SENTINEL_KEY_LAST_NOTIFY_DATE: string = 'sentinel_last_notify_date';

/** 用户点「稍后」时记下的集合键。该集合在变化前不再打扰（spec §3.4） */
export const SENTINEL_KEY_REMINDED_SET: string = 'sentinel_reminded_set';

/** 用户拒绝过通知授权的标记（'1'）。拒绝后 requestEnableNotification 不再弹窗（G8：静默降级） */
export const SENTINEL_KEY_NOTIFY_REFUSED: string = 'sentinel_notify_refused';

/** 频控档位：SENTINEL_FREQUENCY_* 之一，默认每天 */
export const SENTINEL_KEY_FREQUENCY: string = 'sentinel_frequency';

// ---------------------------------------------------------------- 通知

/**
 * 哨兵通知的固定 id。单通道语义：重复发布覆盖旧通知不堆叠，「稍后」按它撤销。
 *
 * 取值随意但要避开 0：cancel(0) 在某些错误路径上语义不明。
 */
export const SENTINEL_NOTIFICATION_ID: number = 20261122;

// ---------------------------------------------------------------- 数据口径

/**
 * 快照陈旧阈值。超过它：卡片降显「打开应用刷新」（G9）、通知跳过（数据太旧不配打扰，spec §5）。
 *
 * 盘上快照的新鲜窗口是 10 分钟（BREW_INSTALLED_FRESH_MS，应用侧决定何时重跑命令），
 * 哨兵只读不跑，所以这里用「卡片还能不能诚实地叫它实时」的口径取 24h。
 */
export const SENTINEL_STALE_MS: number = 24 * 60 * 60 * 1000;

/** 卡片与通知正文里列出的包名条数（spec §4：前 3 个，多则「等 N-3 个」） */
export const SENTINEL_TOP_NAMES_LIMIT: number = 3;

/** 「每周」档的最小间隔（日历日差 ≥ 7 天才允许再发） */
export const SENTINEL_WEEKLY_MIN_MS: number = 7 * 24 * 60 * 60 * 1000;

// ---------------------------------------------------------------- 频控档位

export const SENTINEL_FREQUENCY_OFF: string = 'off';
export const SENTINEL_FREQUENCY_DAILY: string = 'daily';
export const SENTINEL_FREQUENCY_WEEKLY: string = 'weekly';

/** 频控默认档：每天（spec §4）。盘上没有记录时按它处理 */
export const SENTINEL_FREQUENCY_DEFAULT: string = SENTINEL_FREQUENCY_DAILY;

// ---------------------------------------------------------------- 卡片数据键

/**
 * FormBindingData 里给卡片页（LocalStorageProp）消费的键名。
 *
 * 常量化而不是在 service 与卡片页各写一份字符串字面量：两处不一致就是「推了数据卡片不亮」，
 * 而且这种错编译期发现不了。
 */
export const SENTINEL_DATA_FORM_ID: string = 'sentinelFormId';
export const SENTINEL_DATA_HAS_SNAPSHOT: string = 'sentinelHasSnapshot';
export const SENTINEL_DATA_COUNT: string = 'sentinelCount';
export const SENTINEL_DATA_TOP_NAMES: string = 'sentinelTopNames';
export const SENTINEL_DATA_AS_OF: string = 'sentinelAsOfText';
export const SENTINEL_DATA_STALE: string = 'sentinelStale';

// ---------------------------------------------------------------- want 参数键

/** 卡片 postCardAction 与通知按钮共用的路由参数键。值是 PageEnum 的路由名（G2/G4） */
export const SENTINEL_WANT_KEY_ROUTE: string = 'sentinel_route';

/** 通知「稍后」按钮的参数键。消费端撤通知 + 把当次集合记为已提醒 */
export const SENTINEL_WANT_KEY_DISMISS: string = 'sentinel_dismiss';

// ---------------------------------------------------------------- 卡片定义

/** form_config.json 里本卡片的 name。登记日志用它对账 */
export const SENTINEL_FORM_NAME: string = 'BrewSentinelCard';

// ---------------------------------------------------------------- P1 档（work scheduler）

/**
 * **P1 档总开关，默认关（休眠）**。
 *
 * work scheduler 在应用退出于 2in1 上的触发行为（间隔、冻结态、重启后 isPersisted 恢复）
 * 未探明（spec §3.2 Q3）。实现与注册已就位，但 app 侧不 startWork；探针结论可用后把它翻成
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
