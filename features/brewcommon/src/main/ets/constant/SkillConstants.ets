/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

/**
 * Agent Skill 契约常量（docs/superpowers/specs/2026-11-22-agent-skill-spec.md §3 +
 * 2026-11-23 v2 能力面扩充）。
 *
 * 常量同时被两处消费：`BrewSkillBridge`（经 `@ohos/brewcommon` 正常引入）与
 * `products/pc_acl/skills/` 目录的入口脚本——脚本目录不引跨模块包（探针 Q3 未决），
 * 所以脚本里另有逐字一致的本地副本。`check_skill_contract.mjs` 负责核对
 * 「SKILL.md / 脚本副本 / 这里」三处不漂移；改任何一个值三处同步。
 */

/** Skill 名：目录名 / SKILL.md name / module.json5 skillProfiles[].name 三处一致 */
export const SKILL_NAME: string = 'handwer-brew-library';
/** 入口脚本相对路径（module.json5 srcEntries 与 SKILL.md exec-cli 示例共用） */
export const SKILL_SCRIPT_PATH: string = 'scripts/BrewSkill.ets';
export const SKILL_VERSION: string = '1.1.0';

/** 十四项能力的 functionName，与入口脚本 `public async` 方法名严格一致（官方约定） */
export const SKILL_FN_SEARCH: string = 'searchPackages';
export const SKILL_FN_QUERY: string = 'queryPackage';
export const SKILL_FN_PREVIEW: string = 'previewInstall';
export const SKILL_FN_REQUEST: string = 'requestInstall';
/** v2 扩充：读类 */
export const SKILL_FN_LIST_INSTALLED: string = 'listInstalled';
export const SKILL_FN_LIST_OUTDATED: string = 'listOutdated';
export const SKILL_FN_DETAIL: string = 'packageDetail';
export const SKILL_FN_USAGE: string = 'packageUsage';
export const SKILL_FN_TRENDING: string = 'listTrending';
export const SKILL_FN_CATEGORIES: string = 'listCategories';
export const SKILL_FN_CHECK: string = 'checkBrew';
/** v2 扩充：写操作的只读预演类 */
export const SKILL_FN_PREVIEW_UPGRADE: string = 'previewUpgrade';
export const SKILL_FN_PREVIEW_UPGRADE_ALL: string = 'previewUpgradeAll';
export const SKILL_FN_PREVIEW_UNINSTALL: string = 'previewUninstall';

/** SKILL.md 回包契约的错误分支（官方示例命名） */
export const SKILL_ERR_INVALID_PARAMS: string = 'ERR_INVALID_PARAMS';
export const SKILL_ERR_NOT_FOUND: string = 'ERR_NOT_FOUND';
export const SKILL_ERR_INTERNAL: string = 'ERR_INTERNAL';

/**
 * dry-run 是一次真实命令：依赖解析可能触发 API 元数据刷新（brew 侧 450 秒窗口），
 * 超时给足——超时由 ShellUtils 终止进程并回 SHELL_ERR_TIMEOUT，不重试。
 */
export const SKILL_BREW_TIMEOUT_MS: number = 120000;
/** brew 只读命令（uses / config）的应用侧超时：Ruby 启动 2–3 秒 + 命令本身，60 秒足够 */
export const SKILL_BREW_QUICK_TIMEOUT_MS: number = 60000;

/** searchPackages 回包条数上限（spec §3.3） */
export const SKILL_SEARCH_LIMIT: number = 5;
/** listInstalled / listOutdated 回包条数上限（v2） */
export const SKILL_LIST_LIMIT: number = 20;
/** listTrending 回包条数上限（v2） */
export const SKILL_TRENDING_LIMIT: number = 10;
/** packageUsage 回包示例条数上限（v2） */
export const SKILL_USAGE_LIMIT: number = 5;
/** packageDetail caveats 摘要最大长度（v2），超长截断加省略号 */
export const SKILL_CAVEATS_MAX_CHARS: number = 500;
