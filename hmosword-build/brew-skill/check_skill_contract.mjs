/**
 * SKILL.md ↔ 入口脚本 ↔ module.json5 契约一致性检查（spec G10）。
 *
 * 官方约定：SKILL.md 的 functionName 必须与入口脚本 `public async` 方法名严格一致；
 * name 必须与目录名、module.json5 skillProfiles[].name 三处一致。这里把这些约定
 * 变成可执行的断言，并核对 skills/ 脚本里的契约常量本地副本与 brewcommon 的
 * SkillConstants.ets 逐字一致（脚本目录不引跨模块包，副本是刻意的设计）。
 *
 * 运行：node hmosword-build/brew-skill/check_skill_contract.mjs
 */
import { readFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..');
const SKILL_DIR = join(ROOT, 'products', 'pc_acl', 'skills', 'handwer-brew-library');
const MODULE_JSON5 = join(ROOT, 'products', 'pc_acl', 'src', 'main', 'module.json5');
const CONSTANTS = join(ROOT, 'features', 'brewcommon', 'src', 'main', 'ets', 'constant', 'SkillConstants.ets');

const FNS = ['searchPackages', 'queryPackage', 'previewInstall', 'requestInstall'];

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

// ---- 1.6 云端 invoke 工具注册件（references/tools，A 通道）----
const appJson5 = readFileSync(join(ROOT, 'AppScope', 'app.json5'), 'utf8');
const bundleMatch = appJson5.match(/"bundleName":\s*"([^"]+)"/);
assert(bundleMatch, 'AppScope/app.json5 缺 bundleName');
const BUNDLE = bundleMatch[1];
const toolsDir = join(SKILL_DIR, 'references', 'tools');
for (const fn of FNS) {
  const toolPath = join(toolsDir, BUNDLE + '__' + fn + '.json');
  assert(existsSync(toolPath), '缺 invoke 工具注册件: ' + BUNDLE + '__' + fn + '.json');
  const tool = JSON.parse(readFileSync(toolPath, 'utf8'));
  assert.strictEqual(tool.toolName, fn, fn + ' 工具注册件 toolName 不符');
  assert.strictEqual(tool.bundleName, BUNDLE, fn + ' 工具注册件 bundleName 不符');
  assert.strictEqual(tool.pluginType, 'Device', fn + ' 工具注册件 pluginType 应为 Device');
  assert(tool.description && tool.description.length > 20, fn + ' 工具注册件 description 过短');
  const execParam = tool.deviceCommand.template.payload.executeParam;
  assert.strictEqual(execParam.intentName, fn, fn + ' intentName 必须等于 functionName（A/B 汇合同一脚本）');
  assert.strictEqual(execParam.bundleName, BUNDLE, fn + ' executeParam.bundleName 不符');
  assert.strictEqual(execParam.achieveType, 'INTENT', fn + ' achieveType 应为 INTENT');
  const required = (tool.arguments && tool.arguments.required) || [];
  for (const key of required) {
    assert.strictEqual(execParam.intentParam[key], '#{arguments.' + key + '}',
      fn + ' intentParam 缺占位符 #{arguments.' + key + '}');
  }
}
assert(md.includes('方式 A') && /invoke/.test(md), 'SKILL.md 缺 A 通道（invoke）路由');
assert(md.includes('先选 A 或 B'), 'SKILL.md 缺 A/B 选择表');
assert(md.includes(BUNDLE), 'SKILL.md 应写明应用标识 ' + BUNDLE);

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
  const sectionRe = new RegExp('### 场景\\d：[^\\n]*[(（]' + fn + '[)）]([\\s\\S]*?)(?=\\n### |$)');
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

// ---- 8. requestInstall 的 needs_confirmation 语义在两处都有 ----
assert(md.includes('"needs_confirmation"'), 'SKILL.md 缺 needs_confirmation 返回示例');
assert(script.includes('needs_confirmation'), '脚本缺 needs_confirmation 内层状态');

console.log('check_skill_contract: all green (' + FNS.length + ' abilities, '
  + constPairs.length + ' constants)');
