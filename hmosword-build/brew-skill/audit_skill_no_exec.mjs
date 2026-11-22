/**
 * 触达点零副作用审计（spec G6）+ BrewDryRunParser 可执行用例。
 *
 * 审计两份「触达点」文件（小艺唯一能摸到的代码）：
 *   1. skills/.../scripts/BrewSkill.ets —— import 白名单（scriptManager / BasicServicesKit /
 *      BrewSkillBridge），整文件禁 UI 与执行符号；
 *   2. products/pc_acl/src/main/ets/skill/BrewSkillBridge.ets —— 只许 @ohos/common /
 *      pcnative / brewcommon 三个依赖，禁 BrewCommandRunner / BrewCommandSheet / startAbility /
 *      AppStorage / preferences / UI 符号，唯一允许的命令拼装是 installArgs + ' --dry-run'。
 * 注释先剥掉再扫描——注释里写着「不碰 AppStorage」不是违规，代码里出现才是。
 *
 * 解析器用例与 check_tldr_parser.mjs 同技术：BrewDryRunParser.ets 刻意保持零 import，
 * 原样拷成 .mts 用 Node 类型剥离直接跑真源码。
 *
 * 运行：node hmosword-build/brew-skill/audit_skill_no_exec.mjs
 */
import { readFileSync, writeFileSync, mkdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import assert from 'node:assert';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..');
const SCRIPT = join(ROOT, 'products', 'pc_acl', 'skills', 'handwer-brew-library', 'scripts', 'BrewSkill.ets');
const BRIDGE = join(ROOT, 'products', 'pc_acl', 'src', 'main', 'ets', 'skill', 'BrewSkillBridge.ets');
const PARSER = join(ROOT, 'features', 'brewcommon', 'src', 'main', 'ets', 'util', 'BrewDryRunParser.ets');

/** 剥掉注释再扫描：注释里的禁词是文档，代码里的禁词才是违规 */
const stripComments = (text) => text
  .replace(/\/\*[\s\S]*?\*\//g, '')
  .replace(/^\s*\/\/.*$/gm, '');

const extractFromPaths = (text) => [...text.matchAll(/import\s+(?:type\s+)?[\s\S]*?from\s+'([^']+)';/g)]
  .map((m) => m[1]);

// ---- 1. 入口脚本：import 白名单 + 全文禁词 ----
const scriptRaw = readFileSync(SCRIPT, 'utf8');
const script = stripComments(scriptRaw);
const scriptFroms = extractFromPaths(script);
const SCRIPT_ALLOWED = [
  '@kit.AbilityKit',
  '@kit.BasicServicesKit',
  '../../../src/main/ets/skill/BrewSkillBridge',
];
for (const from of scriptFroms) {
  assert(SCRIPT_ALLOWED.includes(from), '脚本 import 越界: ' + from);
}
assert.strictEqual(scriptFroms.length, 4, '脚本 import 数应为 4（scriptManager/BusinessError/Bridge 值+类型）');
const SCRIPT_FORBIDDEN = [
  'AppStorage', 'preferences', 'startAbility', 'openSheet', 'BrewCommandRunner',
  'BrewCommandSheet', 'UIContext', 'NavPathStack', 'window.', '@ohos/', 'startStream',
  'Toast', 'router', 'emitUI', 'runSync',
];
for (const token of SCRIPT_FORBIDDEN) {
  assert(!script.includes(token), '脚本出现禁词: ' + token);
}

// ---- 2. Bridge：依赖白名单 + 禁词 + 唯一命令拼装 ----
const bridgeRaw = readFileSync(BRIDGE, 'utf8');
const bridge = stripComments(bridgeRaw);
const bridgeFroms = extractFromPaths(bridge);
const BRIDGE_ALLOWED = ['@ohos/common', '@ohos/pcnative', '@ohos/brewcommon'];
for (const from of bridgeFroms) {
  assert(BRIDGE_ALLOWED.includes(from), 'Bridge import 越界: ' + from);
}
const BRIDGE_FORBIDDEN = [
  'BrewCommandRunner', 'BrewCommandSheet', 'openSheet', 'startAbility', 'AppStorage',
  'preferences', 'UIContext', '@kit.ArkUI', 'startStream', 'killStream', 'interruptStream',
  'Toast', 'router', 'upgradeArgs', 'upgradeAllArgs', 'uninstallCommand', 'upgradeCommand',
  'BrewCommandRequest',
];
for (const token of BRIDGE_FORBIDDEN) {
  assert(!bridge.includes(token), 'Bridge 出现禁词: ' + token);
}
assert(bridge.includes('BrewCommandGenerator.installArgs'), 'Bridge 必须复用 installArgs 拼装');
assert(bridge.includes(" + ' --dry-run'"), 'Bridge 唯一允许的命令尾巴是 --dry-run');
assert(bridge.includes('ShellUtils.run('), 'Bridge 走 ShellUtils.run 只读执行');
assert(bridge.includes('BrewDryRunParser.parse'), 'Bridge 必须经 BrewDryRunParser 解析');

// ---- 3. BrewDryRunParser 用例（拷成 .mts 跑真源码）----
const tmpDir = join(tmpdir(), 'brew-skill-audit-' + Date.now());
mkdirSync(tmpDir, { recursive: true });
const parserMts = join(tmpDir, 'BrewDryRunParser.mts');
writeFileSync(parserMts, readFileSync(PARSER, 'utf8'));
const parser = await import(pathToFileURL(parserMts).href);
rmSync(tmpDir, { recursive: true, force: true });

const { BrewDryRunParser, BREW_DRYRUN_KIND_FORMULA, BREW_DRYRUN_KIND_CASK } = parser;

// 设备实测样本（docs/knowledge/2026-11-21-brew-tap-trust.md）
const sample = BrewDryRunParser.parse('==> Would install 1 formula: wget 1.25.0_2');
assert.strictEqual(sample.ok, true, '实测样本应解析成功');
assert.strictEqual(sample.declaredCount, 1);
assert.strictEqual(sample.wouldInstall.length, 1);
assert.strictEqual(sample.wouldInstall[0].name, 'wget');
assert.strictEqual(sample.wouldInstall[0].version, '1.25.0_2');
assert.strictEqual(sample.wouldInstall[0].kind, BREW_DRYRUN_KIND_FORMULA);

// 多依赖复数形态
const multi = BrewDryRunParser.parse('==> Fetching dependencies for ffmpeg\n==> Would install 2 formulae: aom 3.9.1, dav1d 1.5.0');
assert.strictEqual(multi.ok, true);
assert.strictEqual(multi.wouldInstall.length, 2);
assert.strictEqual(multi.wouldInstall[0].name, 'aom');

// cask 形态
const cask = BrewDryRunParser.parse('==> Would install 1 cask: foo-bar 2.1.0');
assert.strictEqual(cask.ok, true);
assert.strictEqual(cask.wouldInstall[0].kind, BREW_DRYRUN_KIND_CASK);
assert.strictEqual(cask.wouldInstall[0].name, 'foo-bar');

// 无版本号条目
const noVersion = BrewDryRunParser.parse('==> Would install 1 formula: wget');
assert.strictEqual(noVersion.wouldInstall[0].version, '');

// NOT_FOUND（G7 判据）
const notFound = BrewDryRunParser.parse('Error: No available formula with the name "wgat".');
assert.strictEqual(notFound.ok, false);
assert.strictEqual(notFound.notFound, true);
assert(notFound.failureMessage.includes('No available formula'));

// ANSI 着色包裹的实测行（HOMEBREW_COLOR=1 时）
const ansi = BrewDryRunParser.parse('\x1b[32m==>\x1b[0m \x1b[1mWould install 1 formula:\x1b[0m wget 1.25.0_2');
assert.strictEqual(ansi.ok, true);
assert.strictEqual(ansi.wouldInstall[0].name, 'wget');

// 空输出
const empty = BrewDryRunParser.parse('');
assert.strictEqual(empty.ok, false);
assert.strictEqual(empty.notFound, false);
assert.strictEqual(empty.failureMessage, 'no Would install line in output');

// formula + cask 两行累计
const mixed = BrewDryRunParser.parse('==> Would install 2 formulae: aom 3.9.1, dav1d 1.5.0\n==> Would install 1 cask: foo 2.0');
assert.strictEqual(mixed.ok, true);
assert.strictEqual(mixed.wouldInstall.length, 3);
assert.strictEqual(mixed.declaredCount, 3);

console.log('audit_skill_no_exec: all green (2 touchpoints, 9 parser cases)');
