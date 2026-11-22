/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { skillManager } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '@ohos/common';
import { SKILL_NAME } from '@ohos/brewcommon';

const TAG: string = '[skill-probe]';

/** 本技能所在的模块名（module.json5 的 module.name） */
const SKILL_MODULE: string = 'pc_acl';

/** 17700093：skillName 未注册——SKILL.md / skillProfiles 没生效时的特征错误码 */
const ERR_SKILL_NOT_FOUND: number = 17700093;

/** 17700002：模块名不存在 */
const ERR_MODULE_NOT_FOUND: number = 17700002;

/**
 * Agent Skill 注册自检（spec 2026-11-22-agent-skill-spec.md G3 / Stage 0 探针的常驻探针位）。
 *
 * 应用启动后用 `@ohos.bundle.skillManager` 查询**本应用**的技能注册状态：
 * - 命中 → skillProfiles + skills/ 三件套打包生效，小艺 Work 应当可见；
 * - 17700093 → skillName 没注册（SKILL.md 缺失 / name 三处不一致 / srcEntries 路径错）；
 * - 17700002 → moduleName 对不上。
 *
 * 只读、只打日志、无 UI 触点；查询的是自身应用，不需要 MANAGE_SKILL 特权权限。
 */
export class SkillProbe {
  public static probe(): void {
    const flags: number = skillManager.SkillInfoFlag.GET_SKILL_INFO_DEFAULT
      | skillManager.SkillInfoFlag.GET_SKILL_INFO_WITH_DESCRIPTION
      | skillManager.SkillInfoFlag.GET_SKILL_INFO_WITH_SRC_ENTRIES;
    skillManager.getSkillInfoForSelf(SKILL_MODULE, SKILL_NAME, flags)
      .then((info) => {
        Logger.info(TAG, 'skill registered, module=' + SKILL_MODULE + ' name=' + SKILL_NAME
          + ' info=' + JSON.stringify(info));
      })
      .catch((err: BusinessError) => {
        if (err.code === ERR_SKILL_NOT_FOUND) {
          Logger.error(TAG, 'skill NOT registered (17700093): check SKILL.md presence, '
            + 'name consistency (dir/front-matter/skillProfiles) and srcEntries path, name=' + SKILL_NAME);
        } else if (err.code === ERR_MODULE_NOT_FOUND) {
          Logger.error(TAG, 'module NOT found (17700002): expected ' + SKILL_MODULE);
        } else {
          Logger.error(TAG, 'getSkillInfoForSelf failed: ' + err.code + ' ' + err.message);
        }
      });
    // 全量自查：本应用当前注册了几条技能。0 条同样意味着 skillProfiles 没生效。
    skillManager.getSkillInfosForSelf(skillManager.SkillInfoFlag.GET_SKILL_INFO_DEFAULT)
      .then((infos) => {
        Logger.info(TAG, 'self skill count=' + infos.length);
      })
      .catch((err: BusinessError) => {
        Logger.error(TAG, 'getSkillInfosForSelf failed: ' + err.code + ' ' + err.message);
      });
  }
}
