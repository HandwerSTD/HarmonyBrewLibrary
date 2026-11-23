/**
 * 触达点零副作用审计（spec G6 + 2026-11-23 v2 能力面扩充）+ 解析器可执行用例。
 *
 * 审计两份「触达点」文件（小艺唯一能摸到的代码）：
 *   1. skills/.../scripts/BrewSkill.ets —— import 白名单（scriptManager / BasicServicesKit /
 *      BrewSkillBridge），整文件禁 UI 与执行符号；
 *   2. products/pc_acl/src/main/ets/skill/BrewSkillBridge.ets —— 只许 @ohos/common /
 *      pcnative / brewcommon 三个依赖，禁 BrewCommandRunner / BrewCommandSheet / startAbility /
 *      AppStorage / preferences / UI 符号。命令执行收口在两个 helper 上：
 *        - runDryRun：唯一允许的命令尾巴是 --dry-run；
 *        - runRead：只读白名单（uses --installed / config / info）。
 *      不变量用「ShellUtils.run 调用点数量 === 2」锁死——卸载预演的 plannedCommand
 *      只许拼出来展示，绝不许执行。
 * 注释先剥掉再扫描——注释里写着「不碰 AppStorage」不是违规，代码里出现才是。
 *
 * 解析器用例与 check_tldr_parser.mjs 同技术：三个纯函数解析器刻意保持零 import，
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
const USES_PARSER = join(ROOT, 'features', 'brewcommon', 'src', 'main', 'ets', 'util', 'BrewUsesParser.ets');
const CONFIG_PARSER = join(ROOT, 'features', 'brewcommon', 'src', 'main', 'ets', 'util', 'BrewConfigParser.ets');

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

// ---- 2. Bridge：依赖白名单 + 禁词 + 命令执行收口 ----
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
  'Toast', 'router', 'upgradeCommand', 'BrewCommandRequest',
];
for (const token of BRIDGE_FORBIDDEN) {
  assert(!bridge.includes(token), 'Bridge 出现禁词: ' + token);
}
// 命令拼装必须复用生成器，且四条预演各自用对生成函数
assert(bridge.includes('BrewCommandGenerator.installArgs'), 'Bridge 必须复用 installArgs 拼装');
assert(bridge.includes('BrewCommandGenerator.upgradeArgs'), '升级预演必须复用 upgradeArgs 拼装');
assert(bridge.includes('BrewCommandGenerator.upgradeAllArgs'), '批量升级预演必须复用 upgradeAllArgs 拼装');
assert(bridge.includes('BrewCommandGenerator.uninstallCommand'),
  '卸载预演的 plannedCommand 必须复用 uninstallCommand（仅展示，绝不执行）');
assert(bridge.includes(" + ' --dry-run'"), '写命令预演的唯一允许尾巴是 --dry-run');
// 不变量：ShellUtils.run 只许出现在 runDryRun 与 runRead 两个 helper 里
const runCallSites = bridge.split('ShellUtils.run(').length - 1;
assert.strictEqual(runCallSites, 2,
  'ShellUtils.run 调用点必须是 2（runDryRun + runRead），实际 ' + runCallSites);
// runRead 的只读白名单形态锁死
assert(bridge.includes("args === 'config' || args.startsWith('uses --installed ')"),
  'runRead 只读白名单形态不符（config / uses --installed / info）');
assert(bridge.includes('SKILL_BREW_QUICK_TIMEOUT_MS'), '只读命令必须走快速超时');
assert(bridge.includes('BrewDryRunParser.parse'), '预演必须经 BrewDryRunParser 解析');

// ---- 3. 解析器用例（拷成 .mts 跑真源码）----
const tmpDir = join(tmpdir(), 'brew-skill-audit-' + Date.now());
mkdirSync(tmpDir, { recursive: true });
const loadParser = async (sourcePath, name) => {
  const target = join(tmpDir, name);
  writeFileSync(target, readFileSync(sourcePath, 'utf8'));
  return await import(pathToFileURL(target).href);
};
const parserMod = await loadParser(PARSER, 'BrewDryRunParser.mts');
const usesMod = await loadParser(USES_PARSER, 'BrewUsesParser.mts');
const configMod = await loadParser(CONFIG_PARSER, 'BrewConfigParser.mts');
rmSync(tmpDir, { recursive: true, force: true });

const { BrewDryRunParser, BREW_DRYRUN_KIND_FORMULA, BREW_DRYRUN_KIND_CASK } = parserMod;
const { BrewUsesParser } = usesMod;
const { BrewConfigParser } = configMod;

// 设备实测样本（docs/knowledge/2026-11-21-brew-tap-trust.md）
const sample = BrewDryRunParser.parse('==> Would install 1 formula: wget 1.25.0_2');
assert.strictEqual(sample.ok, true, '实测样本应解析成功');
assert.strictEqual(sample.declaredCount, 1);
assert.strictEqual(sample.wouldInstall.length, 1);
assert.strictEqual(sample.wouldInstall[0].name, 'wget');
assert.strictEqual(sample.wouldInstall[0].version, '1.25.0_2');
assert.strictEqual(sample.wouldInstall[0].kind, BREW_DRYRUN_KIND_FORMULA);
assert.strictEqual(sample.wouldInstall[0].fromVersion, '');

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

// ---- 3.1 升级预演（v2）----
const upOne = BrewDryRunParser.parse('==> Would upgrade 1 outdated package: wget 1.25.0_2 -> 1.26.0');
assert.strictEqual(upOne.ok, true);
assert.strictEqual(upOne.declaredCount, 1);
assert.strictEqual(upOne.wouldInstall.length, 1);
assert.strictEqual(upOne.wouldInstall[0].name, 'wget');
assert.strictEqual(upOne.wouldInstall[0].fromVersion, '1.25.0_2');
assert.strictEqual(upOne.wouldInstall[0].version, '1.26.0');
assert.strictEqual(upOne.wouldInstall[0].kind, '', '通用名词 package 的 kind 留空，由 Bridge 按目录/快照补齐');

const upMulti = BrewDryRunParser.parse('==> Would upgrade 2 outdated packages: wget 1.25.0_2 -> 1.26.0, jq 1.7.1 -> 1.8.0');
assert.strictEqual(upMulti.ok, true);
assert.strictEqual(upMulti.wouldInstall.length, 2);
assert.strictEqual(upMulti.wouldInstall[1].name, 'jq');
assert.strictEqual(upMulti.wouldInstall[1].version, '1.8.0');

const upAnsi = BrewDryRunParser.parse('\x1b[1m==>\x1b[0m \x1b[1mWould upgrade 1 outdated cask:\x1b[0m foo-bar 2.0.0 -> 2.1.0');
assert.strictEqual(upAnsi.ok, true);
assert.strictEqual(upAnsi.wouldInstall[0].kind, BREW_DRYRUN_KIND_CASK);
assert.strictEqual(upAnsi.wouldInstall[0].name, 'foo-bar');

// ---- 3.1.1 设备实测（brew 7.0.9_7，2026-11-23）：表头与清单分行 + 连带依赖升级段 ----
// 真实失败样本（验收反馈）：表头尾部为空、条目在下一行，v2 解析器在这里漏成 0 条目
const deviceSplit = BrewDryRunParser.parse(
  'Warning: The following taps are not trusted:\n  harmony/ohos\n\n' +
  'Homebrew is currently ignoring formulae from these taps.\n' +
  '==> Would install 1 formula:\ndeepseek-harness 0.2.2-rc.2_1\n' +
  '==> Would upgrade 1 dependency for deepseek-harness:\nnode\n');
assert.strictEqual(deviceSplit.ok, true);
assert.strictEqual(deviceSplit.declaredCount, 2);
assert.strictEqual(deviceSplit.wouldInstall.length, 2);
assert.strictEqual(deviceSplit.wouldInstall[0].name, 'deepseek-harness');
assert.strictEqual(deviceSplit.wouldInstall[0].version, '0.2.2-rc.2_1');
assert.strictEqual(deviceSplit.wouldInstall[0].kind, BREW_DRYRUN_KIND_FORMULA);
// tap-trust 警告块的裸行（harmony/ohos）不得混进清单
assert.strictEqual(deviceSplit.wouldInstall[1].name, 'node');
assert.strictEqual(deviceSplit.wouldInstall[1].version, '');
assert.strictEqual(deviceSplit.wouldInstall[1].kind, '');

const wgetSplit = BrewDryRunParser.parse('==> Would install 1 formula:\nwget 1.25.0_2\n');
assert.strictEqual(wgetSplit.ok, true);
assert.strictEqual(wgetSplit.wouldInstall.length, 1);
assert.strictEqual(wgetSplit.wouldInstall[0].name, 'wget');
assert.strictEqual(wgetSplit.wouldInstall[0].version, '1.25.0_2');

// 升级预演的分行形态（条目带 旧 -> 新）
const upgradeSplit = BrewDryRunParser.parse('==> Would upgrade 1 outdated formula:\nwget 1.25.0_2 -> 1.26.0\n');
assert.strictEqual(upgradeSplit.ok, true);
assert.strictEqual(upgradeSplit.wouldInstall[0].name, 'wget');
assert.strictEqual(upgradeSplit.wouldInstall[0].fromVersion, '1.25.0_2');
assert.strictEqual(upgradeSplit.wouldInstall[0].version, '1.26.0');

// 真不存在的包（设备实测 exit 1）：G7 判据在 brew 7 文案下照常命中
const notFoundDevice = BrewDryRunParser.parse('Error: No formulae found for this-formula-does-not-exist-xyz.\n==> Searching for similarly named formulae...\n');
assert.strictEqual(notFoundDevice.ok, false);
assert.strictEqual(notFoundDevice.notFound, true);
assert(notFoundDevice.failureMessage.includes('No formulae found'));

// ---- 3.2 brew uses 解析（v2 卸载预演）----
const usesNames = BrewUsesParser.parse('wget\ncurl\njq\n');
assert.strictEqual(usesNames.ok, true);
assert.strictEqual(usesNames.names.length, 3);
assert.strictEqual(usesNames.names[0], 'wget');

const usesNoise = BrewUsesParser.parse('==> Warning: ignore me\nfoo 2.0 (installed)\n');
assert.strictEqual(usesNoise.ok, true);
assert.strictEqual(usesNoise.names.length, 1);
assert.strictEqual(usesNoise.names[0], 'foo');

const usesError = BrewUsesParser.parse('Error: No installed formula found.');
assert.strictEqual(usesError.ok, false);
assert(usesError.failureMessage.includes('No installed formula'));

const usesEmpty = BrewUsesParser.parse('');
assert.strictEqual(usesEmpty.ok, true);
assert.strictEqual(usesEmpty.names.length, 0);

// ---- 3.3 brew config 解析（v2 checkBrew）----
const cfg = BrewConfigParser.parse('HOMEBREW_VERSION: 4.6.9\nHOMEBREW_PREFIX: /data/harmonybrew\nHOMEBREW_CELLAR: /data/harmonybrew/Cellar\nCPU: arm64\n');
assert.strictEqual(cfg.ok, true);
assert.strictEqual(cfg.version, '4.6.9');
assert.strictEqual(cfg.prefix, '/data/harmonybrew');
assert.strictEqual(cfg.cellar, '/data/harmonybrew/Cellar');

const cfgCore = BrewConfigParser.parse('HOMEBREW_VERSION: 4.6.9\nCore tap HEAD: abc123');
assert.strictEqual(cfg.ok, true);
assert.strictEqual(cfgCore.coreTapHead, 'abc123');

const cfgGarbage = BrewConfigParser.parse('nothing useful here');
assert.strictEqual(cfgGarbage.ok, false);
assert.strictEqual(cfgGarbage.failureMessage, 'no HOMEBREW_VERSION line in output');

console.log('audit_skill_no_exec: all green (2 touchpoints, '
  + (16 + 4 + 3) + ' parser cases)');
