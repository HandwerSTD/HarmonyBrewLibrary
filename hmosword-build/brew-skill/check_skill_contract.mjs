/**
 * SKILL.md ↔ 入口脚本 ↔ module.json5 契约一致性检查（spec G10 + 2026-11-23 v2 能力面扩充）。
 *
 * 官方约定：SKILL.md 的 functionName 必须与入口脚本 `public async` 方法名严格一致；
 * name 必须与目录名、module.json5 skillProfiles[].name 三处一致。这里把这些约定
 * 变成可执行的断言，并核对 skills/ 脚本里的契约常量本地副本与 brewcommon 的
 * SkillConstants.ets 逐字一致（脚本目录不引跨模块包，副本是刻意的设计）。
 *
 * 运行：node hmosword-build/brew-skill/check_skill_contract.mjs
 */
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..');
const SKILL_DIR = join(ROOT, 'products', 'pc_acl', 'skills', 'handwer-brew-library');
const MODULE_JSON5 = join(ROOT, 'products', 'pc_acl', 'src', 'main', 'module.json5');
const CONSTANTS = join(ROOT, 'features', 'brewcommon', 'src', 'main', 'ets', 'constant', 'SkillConstants.ets');

const FNS = [
  'searchPackages', 'queryPackage', 'previewInstall', 'requestInstall',
  'listInstalled', 'listOutdated', 'packageDetail', 'packageUsage',
  'listTrending', 'listCategories', 'checkBrew',
  'previewUpgrade', 'previewUpgradeAll', 'previewUninstall',
];

const md = readFileSync(join(SKILL_DIR, 'SKILL.md'), 'utf8');
const script = readFileSync(join(SKILL_DIR, 'scripts', 'BrewSkill.ets'), 'utf8');
const moduleJson5 = readFileSync(MODULE_JSON5, 'utf8');
const constants = readFileSync(CONSTANTS, 'utf8');

// ---- 1. front matter 与目录名 ----
const fm = md.match(/^---\r?\n([\s\S]*?)\r?\n---/);
assert(fm, 'SKILL.md 缺少 YAML front matter');
assert(/^name:\s*handwer-brew-library\s*$/m.test(fm[1]), 'front matter name 必须是 handwer-brew-library');
assert(/^description:\s*>-/m.test(fm[1]), 'front matter description 必须是 >- 多行块（含不适用边界）');
assert(/不适用于/.test(fm[1]), 'front matter description 缺「不适用于」边界');

// ---- 1.5 调用契约与错误重试纪律（对照真实生产样本 biandan-assistant 的约定）----
assert(md.includes('## 调用方式'), 'SKILL.md 缺「调用方式」段（单 JSON 字符串 + 转义约定）');
assert(md.includes('JSON.stringify'), 'SKILL.md 缺 JSON.stringify 压参约定');
assert(md.includes('\\"'), 'SKILL.md 缺命令行转义形态示例（\\"）');
assert(md.includes('argv.length === 1'), 'SKILL.md 缺 argv.length === 1 检查要求');
assert(md.includes('参数传递格式错误'), 'SKILL.md 缺「参数传递格式错误」自动重试判定锚点');
assert(md.includes('## 返回结果与错误处理'), 'SKILL.md 缺「返回结果与错误处理」段');
assert(md.includes('## 运行条件与业务约定'), 'SKILL.md 缺「运行条件与业务约定」段');

// ---- 1.7 实测调用形态与投喂强调（2026-11-23 真机机制实测）----
assert(md.includes('exec('), 'SKILL.md 缺实测 exec() 调用形态');
assert(md.includes('ohos-arktsscript'), 'SKILL.md 缺 ohos-arktsscript 工具名');
assert(md.includes('timeout_ms'), 'SKILL.md 缺 timeout_ms 指引');
assert(md.includes('不能安装本地 skill'), 'SKILL.md 缺「SKILL.md 不暴露 / 不能安装本地 skill」强调');
assert(md.includes('发到小艺 Work 对话框'), 'SKILL.md 缺「整份投喂到对话框」操作指引');
assert(md.includes("query\":\"python\"") || md.includes('query\\":\\"python'), 'SKILL.md 缺实测成功样本');

// ---- 1.8 v2 能力面（三档 timeout 与预演业务语义）----
assert(md.includes('60000') && md.includes('120000') && md.includes('180000'),
  'SKILL.md 缺三档 timeout_ms 指引（60000 / 120000 / 180000）');
assert(md.includes('nothing_to_upgrade'), 'SKILL.md 缺 nothing_to_upgrade 预演语义');
assert(md.includes('not_installed'), 'SKILL.md 缺 not_installed 预演语义');
assert(md.includes('不自动重放'), 'SKILL.md 缺「预演不自动重放」纪律');
assert(md.includes('"sizes"'), 'SKILL.md 缺 sizes 字段（当前已装占用补测）');
assert(md.includes('一一对应'), 'SKILL.md 缺 sizes 与 wouldUpgrade 一一对应的口径');
assert(md.includes('实测，仅已安装'), 'SKILL.md 缺 sizes 的 brew info 实测来源说明');
assert(md.includes('一一对应'), 'SKILL.md 缺 sizes 与 wouldUpgrade 一一对应的口径');
assert(md.includes('"note"'), 'SKILL.md 缺 nothing_to_upgrade 的 note 字段（brew 判定原文）');

// ---- 2. module.json5 注册 ----
assert(/"skillProfiles"[\s\S]*"name":\s*"handwer-brew-library"/.test(moduleJson5),
  'module.json5 缺 handwer-brew-library 的 skillProfiles 注册');
assert(/"abilityName":\s*"PcAbility"/.test(moduleJson5), 'skillProfiles.abilityName 必须是 PcAbility');
assert(/"\.\.\/\.\.\/skills\/handwer-brew-library\/scripts\/BrewSkill\.ets"/.test(moduleJson5),
  'skillProfiles.srcEntries 必须指向 skills/ 入口脚本');

// ---- 3. functionName 双向一致 ----
const mdFns = [...md.matchAll(/--functionName\s+'([^']+)'/g)].map((m) => m[1]);
const scriptFns = [...script.matchAll(/public async (\w+)\(/g)].map((m) => m[1]);
assert.deepStrictEqual([...new Set(mdFns)].sort(), [...FNS].sort(),
  'SKILL.md exec-cli functionName 集合不符: ' + mdFns.join(','));
assert.deepStrictEqual([...new Set(scriptFns)].sort(), [...FNS].sort(),
  '脚本 public async 方法集合不符: ' + scriptFns.join(','));

// ---- 4. 每个能力有 场景 小节且含 执行参数 / 执行返回值 ----
for (const fn of FNS) {
  const sectionRe = new RegExp('### 场景\\d{1,2}：[^\\n]*[(（]' + fn + '[)）]([\\s\\S]*?)(?=\\n### |$)');
  const section = md.match(sectionRe);
  assert(section, 'SKILL.md 缺少 ' + fn + ' 的场景小节');
  assert(/执行参数/.test(section[1]), fn + ' 小节缺「执行参数」段');
  assert(/执行返回值/.test(section[1]), fn + ' 小节缺「执行返回值」段');
  assert(section[1].includes("'handwer-brew-library'"), fn + ' 的 exec-cli 示例 skillName 不符');
  assert(section[1].includes("'scripts/BrewSkill.ets'"), fn + ' 的 exec-cli 示例 scriptPath 不符');
}

// ---- 5. 错误分支三件套 ----
for (const code of ['ERR_INVALID_PARAMS', 'ERR_NOT_FOUND', 'ERR_INTERNAL']) {
  assert(md.includes('"' + code + '"'), 'SKILL.md 缺 ' + code + ' 分支');
  assert(script.includes("'" + code + "'"), '脚本缺 ' + code + ' 常量');
}

// ---- 6. 触发场景与能力边界 ----
assert(/## 触发场景/.test(md), 'SKILL.md 缺「触发场景」段');
assert(/不调用的情况/.test(md), 'SKILL.md 缺「不调用的情况」边界段');
assert(/绝不直接执行安装/.test(md), 'SKILL.md 必须写明「绝不直接执行安装」的能力边界');

// ---- 7. 契约常量本地副本与 SkillConstants.ets 不漂移 ----
const constPairs = [
  ['SKILL_FN_SEARCH', 'searchPackages'],
  ['SKILL_FN_QUERY', 'queryPackage'],
  ['SKILL_FN_PREVIEW', 'previewInstall'],
  ['SKILL_FN_REQUEST', 'requestInstall'],
  ['SKILL_FN_LIST_INSTALLED', 'listInstalled'],
  ['SKILL_FN_LIST_OUTDATED', 'listOutdated'],
  ['SKILL_FN_DETAIL', 'packageDetail'],
  ['SKILL_FN_USAGE', 'packageUsage'],
  ['SKILL_FN_TRENDING', 'listTrending'],
  ['SKILL_FN_CATEGORIES', 'listCategories'],
  ['SKILL_FN_CHECK', 'checkBrew'],
  ['SKILL_FN_PREVIEW_UPGRADE', 'previewUpgrade'],
  ['SKILL_FN_PREVIEW_UPGRADE_ALL', 'previewUpgradeAll'],
  ['SKILL_FN_PREVIEW_UNINSTALL', 'previewUninstall'],
  ['SKILL_ERR_INVALID_PARAMS', 'ERR_INVALID_PARAMS'],
  ['SKILL_ERR_NOT_FOUND', 'ERR_NOT_FOUND'],
  ['SKILL_ERR_INTERNAL', 'ERR_INTERNAL'],
];
for (const [name, value] of constPairs) {
  const inConstants = constants.match(new RegExp('export const ' + name + '[^\\n]*=\\s*\'([^\']+)\''));
  const inScript = script.match(new RegExp('const ' + name + '[^\\n]*=\\s*\'([^\']+)\''));
  assert(inConstants && inConstants[1] === value, 'SkillConstants.ets 的 ' + name + ' 漂移');
  assert(inScript && inScript[1] === value, '脚本本地副本的 ' + name + ' 漂移');
}

// ---- 8. requestInstall / previewUninstall 的 needs_confirmation 语义在两处都有 ----
assert(md.includes('"needs_confirmation"'), 'SKILL.md 缺 needs_confirmation 返回示例');
assert(script.includes('needs_confirmation'), '脚本缺 needs_confirmation 内层状态');

console.log('check_skill_contract: all green (' + FNS.length + ' abilities, '
  + constPairs.length + ' constants)');
