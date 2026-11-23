/**
 * 触达点「零执行」审计（G5/G12）。
 *
 * 两组触达面共用一个脚本：
 *
 * 一、更新哨兵（H，G5，spec §6）：哨兵全链路（卡片页、FormExtensionAbility、
 * WorkScheduler 回调、SentinelBootstrap、哨兵服务）必须只做三件事：读盘上快照、
 * 推卡片数据、发通知。它**不允许出现任何 brew 命令拼装/执行符号**——
 * 「替用户按回车」的红线在本功能里没有例外路径。
 *
 * 二、更新情报中心（Y，G12，release intel spec §8）：情报链路（服务/偏好/基线库/
 * 过滤器/repo 解析/两张卡）只做「取上游发布情报 + 归纳展示 + 写策略偏好」。
 * 命令执行只有一条合法出口——详情页执行 Sheet——所以情报文件集合里
 * 五个命令符号全部禁止（含 BrewCommandGenerator：pin 命令文本由
 * BrewDetailViewModel 生成后作为纯字符串传入卡片，卡片自己不碰生成器）。
 * 情报文件允许 AppStorage（它们只跑在宿主进程，与哨兵的跨进程纯度约束不同）。
 *
 * 扫描对象：
 *   - products/pc_acl/src/main/ets/sentinel/ 下全部 .ets（递归）；
 *   - features/brewcommon/src/main/ets/service/BrewSentinelService.ets；
 *   - features/brewcommon|brewdetail 下 ReleaseIntel* / BrewRelease* 文件（Y 组）。
 *
 * 规则（剥注释后匹配，注释里提到这些符号不算违例）：
 *   1. 命令符号（H 组 5 个 / Y 组同 5 个）；
 *   2. 命令字面量：引号后紧跟 `brew ` 的字符串（含 --dry-run 拼装），以及孤立的 --dry-run；
 *   3. AppStorage：仅 H 组禁（跨进程纯度）；Y 组放行（宿主进程专属链路）；
 *   4. 数据来源单一：BrewSentinelService 必须 import BrewInstalledLoader（只读快照）；
 *   5. 策略联动唯一入口（G6）：BrewSentinelService 必须 import ReleaseIntelFilter，
 *      且 ReleaseIntelFilter 不得 import 任何命令符号（它自己是被 H 信任的守门人）。
 *
 * 允许的 brewcommon 内部 import：BrewInstalledLoader / BrewInstalledPackage（只读快照）。
 * 其余 brewcommon 命令相关符号由规则 1 的负向清单拦住。
 *
 * 运行：node hmosword-build/brew-sentinel/audit_no_brew_in_touchpoints.mjs
 */
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

const SENTINEL_DIR = 'products/pc_acl/src/main/ets/sentinel';
const SERVICE_FILE = 'features/brewcommon/src/main/ets/service/BrewSentinelService.ets';

/** Y 组触达面（G12）：情报链路的全部新文件。目录改名/新增文件时同步这里 */
const RELEASE_INTEL_FILES = [
  'features/brewcommon/src/main/ets/service/ReleaseIntelService.ets',
  'features/brewcommon/src/main/ets/service/ReleaseIntelFilter.ets',
  'features/brewcommon/src/main/ets/service/ReleaseIntelPrefs.ets',
  'features/brewcommon/src/main/ets/service/ReleaseIntelBaselineStore.ets',
  'features/brewcommon/src/main/ets/util/ReleaseIntelRepoResolver.ets',
  'features/brewdetail/src/main/ets/component/BrewReleaseIntelCard.ets',
  'features/brewdetail/src/main/ets/component/BrewReleaseArchiveView.ets',
];

/** 命令生成/执行层的符号。哨兵触达点出现任何一个都意味着数据链路越界（spec §6） */
const FORBIDDEN_SYMBOLS = [
  'BrewCommandGenerator',
  'BrewCommandRunner',
  'BrewCli',
  'ShellUtils',
  'BrewCommandRequest',
];

/** 引号 + brew + 边界：'brew info'、`brew ${args}`、`--dry-run` 拼装都会命中 */
const BREW_LITERAL_RE = /(['"`])brew[\s'"`]/;
const DRY_RUN_RE = /--dry-run/;
const APP_STORAGE_RE = /\bAppStorage\b/;
/** 哨兵服务的数据来源必须且只能是 BrewInstalledLoader 的只读快照 */
const LOADER_IMPORT_RE = /import\s*\{[^}]*BrewInstalledLoader[^}]*\}\s*from/;
/** G6：H 的通知计数过滤必须走 ReleaseIntelFilter（策略联动的唯一入口） */
const SENTINEL_FILTER_IMPORT_RE = /import\s*\{[^}]*ReleaseIntelFilter[^}]*\}\s*from/;

/**
 * 剥注释（保留字符串内容）。用状态机而不是正则：正则对嵌套引号与转义的处理靠不住，
 * 而这里漏剥一条注释就会把注释里的举例误判成违例（误报），多剥一段字符串又会漏判（漏报）。
 * 输出与输入等长（注释替换为空白），行号信息因此保留，报错能定位到行。
 */
export function stripComments(src) {
  let out = '';
  let i = 0;
  let mode = 'code';
  while (i < src.length) {
    const c = src[i];
    const c2 = src.substr(i, 2);
    if (mode === 'code') {
      if (c2 === '//') {
        mode = 'line';
        out += '  ';
        i += 2;
      } else if (c2 === '/*') {
        mode = 'block';
        out += '  ';
        i += 2;
      } else if (c === "'" || c === '"' || c === '`') {
        mode = c === "'" ? 'single' : c === '"' ? 'double' : 'template';
        out += c;
        i += 1;
      } else {
        out += c;
        i += 1;
      }
    } else if (mode === 'line') {
      if (c === '\n') {
        mode = 'code';
        out += '\n';
      } else {
        out += ' ';
      }
      i += 1;
    } else if (mode === 'block') {
      if (c2 === '*/') {
        mode = 'code';
        out += '  ';
        i += 2;
      } else {
        out += c === '\n' ? '\n' : ' ';
        i += 1;
      }
    } else {
      const close = mode === 'single' ? "'" : mode === 'double' ? '"' : '`';
      if (c === '\\') {
        out += src.substr(i, 2);
        i += 2;
      } else if (c === close) {
        mode = 'code';
        out += c;
        i += 1;
      } else {
        out += c === '\n' || mode !== 'template' ? c : c;
        i += 1;
      }
    }
  }
  return out;
}

/** 单文件扫描。返回违例列表（{ line, rule, snippet }），空数组 = 通过。
 * forbidden：本组禁用的符号集（H/Y 两组同表）；checkAppStorage：H 组 true（跨进程
 * 纯度），Y 组 false（宿主进程专属，读 UI_CONTEXT 取 filesDir 是既有惯例）。 */
export function scanContent(content, forbidden = FORBIDDEN_SYMBOLS, checkAppStorage = true) {
  const stripped = stripComments(content);
  const lines = stripped.split('\n');
  const violations = [];
  lines.forEach((line, idx) => {
    for (const symbol of forbidden) {
      if (line.includes(symbol)) {
        violations.push({ line: idx + 1, rule: `symbol:${symbol}`, snippet: line.trim().slice(0, 120) });
      }
    }
    if (BREW_LITERAL_RE.test(line)) {
      violations.push({ line: idx + 1, rule: 'brew-literal', snippet: line.trim().slice(0, 120) });
    }
    if (DRY_RUN_RE.test(line)) {
      violations.push({ line: idx + 1, rule: 'dry-run', snippet: line.trim().slice(0, 120) });
    }
    if (checkAppStorage && APP_STORAGE_RE.test(line)) {
      violations.push({ line: idx + 1, rule: 'AppStorage', snippet: line.trim().slice(0, 120) });
    }
  });
  return violations;
}

/** 递归收集目录下全部 .ets */
function collectEtsFiles(dir) {
  const found = [];
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) {
      found.push(...collectEtsFiles(full));
    } else if (name.endsWith('.ets')) {
      found.push(full);
    }
  }
  return found;
}

// ---------------------------------------------------------------- 自测用例（正向违例 / 负向干净）

const NEGATIVE_CASES = [
  {
    name: '干净的服务片段（只读快照 + 推卡 + 发通知）',
    code: `
import { preferences } from '@kit.ArkData';
import { BrewInstalledLoader } from './BrewInstalledLoader';
const snap = BrewInstalledLoader.snapshot();
formProvider.updateForm(formId, binding);
notificationManager.publish(request);
`,
  },
  {
    name: '注释里提到命令符号不算违例',
    code: `
// 参考 BrewCli.commandLine 与 ShellUtils.run 的既有口径，本文件不使用它们
const ok = 1;
`,
  },
  {
    name: '卡片页（纯声明式 + router 跳转）',
    code: `
postCardAction(this, { action: 'router', abilityName: 'PcAbility', params: { 'sentinel_route': 'MinePackagesView' } })
`,
  },
  {
    name: '含 brew 的普通字符串但不以引号+空格开头（不命中命令字面量）',
    code: `
const title = 'homebrew updater';
const url = "https://formulae.brew.sh";
`,
  },
];

const POSITIVE_CASES = [
  { name: 'import BrewCli', code: `import { BrewCli } from './BrewCli';\n` },
  { name: 'import ShellUtils', code: `import { ShellUtils } from '@ohos/pcnative';\n` },
  { name: '调用 BrewCommandRunner', code: `const r = BrewCommandRunner.getInstance();\n` },
  { name: '命令拼装 BrewCommandGenerator', code: `const cmd = BrewCommandGenerator.upgradeAll();\n` },
  { name: "命令字面量 'brew '", code: `const cmd = 'brew info --json=v2 --installed';\n` },
  { name: '模板串拼 brew', code: 'const cmd = `brew upgrade ${name}`;\n' },
  { name: '--dry-run 拼装', code: `const cmd = commandLine + ' --dry-run';\n` },
  { name: '使用 AppStorage', code: `const v = AppStorage.get<boolean>('x') ?? false;\n` },
  { name: 'import AppStorage', code: `import { AppStorage } from '@ohos/arkui';\n` },
];

/** Y 组的组内正反用例：AppStorage 放行但命令符号照禁（scanContent 的参数化行为） */
const RI_POSITIVE_CASES = [
  { name: 'Y 组：AppStorage 放行', code: `const ctx = AppStorage.get<UIContext>('ui_context');\n` },
  { name: 'Y 组：卡片收到纯字符串 pinCommand', code: `PasteboardUtil.copyText(this.pinCommand);\n` },
];
const RI_NEGATIVE_CASES = [
  { name: 'Y 组：注释里提到 pin 命令不算违例', code: `// 复制 brew pin <token> 命令文本，只有复制（G13）\nconst ok = 1;\n` },
];
const RI_FORBIDDEN_CASES = [
  { name: 'Y 组：import BrewCommandGenerator 也禁（pin 文本由 VM 生成后传入）',
    code: `import { BrewCommandGenerator } from './BrewCommandGenerator';\n` },
];

function runSelfTests() {
  let passed = 0;
  for (const c of NEGATIVE_CASES) {
    const v = scanContent(c.code);
    if (v.length !== 0) {
      throw new Error(`负向用例误报「${c.name}」：${JSON.stringify(v)}`);
    }
    passed++;
  }
  for (const c of POSITIVE_CASES) {
    const v = scanContent(c.code);
    if (v.length === 0) {
      throw new Error(`正向用例漏判「${c.name}」`);
    }
    passed++;
  }
  // Y 组参数化行为
  for (const c of RI_NEGATIVE_CASES) {
    const v = scanContent(c.code, FORBIDDEN_SYMBOLS, false);
    if (v.length !== 0) {
      throw new Error(`Y 负向用例误报「${c.name}」：${JSON.stringify(v)}`);
    }
    passed++;
  }
  for (const c of RI_POSITIVE_CASES) {
    const v = scanContent(c.code, FORBIDDEN_SYMBOLS, false);
    if (v.length !== 0) {
      throw new Error(`Y 正向用例误报「${c.name}」：${JSON.stringify(v)}`);
    }
    passed++;
  }
  for (const c of RI_FORBIDDEN_CASES) {
    const v = scanContent(c.code, FORBIDDEN_SYMBOLS, false);
    if (v.length === 0) {
      throw new Error(`Y 正向用例漏判「${c.name}」`);
    }
    passed++;
  }
  return passed;
}

// ---------------------------------------------------------------- 主流程

function main() {
  const selfTestCount = runSelfTests();

  const files = collectEtsFiles(join(ROOT, SENTINEL_DIR))
    .map((f) => relative(ROOT, f));
  files.push(SERVICE_FILE);
  if (files.length < 5) {
    // 触达点集合凭空变小通常意味着目录被改名/移动——宁可失败也不静默扫了个空集
    throw new Error(`触达点文件数异常（${files.length}），检查 sentinel 目录是否被移动`);
  }

  let violations = 0;
  for (const rel of files) {
    const content = readFileSync(join(ROOT, rel), 'utf-8');
    const found = scanContent(content);
    if (found.length > 0) {
      for (const v of found) {
        console.error(`FAIL ${rel}:${v.line} [${v.rule}] ${v.snippet}`);
        violations++;
      }
    } else {
      console.log(`PASS ${rel}`);
    }
  }

  // 数据来源单一性：BrewSentinelService 必须 import BrewInstalledLoader
  const serviceContent = readFileSync(join(ROOT, SERVICE_FILE), 'utf-8');
  const serviceStripped = stripComments(serviceContent);
  if (!LOADER_IMPORT_RE.test(serviceStripped)) {
    console.error(`FAIL ${SERVICE_FILE}: 未 import BrewInstalledLoader（数据来源必须单一，spec §3.1）`);
    violations++;
  } else {
    console.log(`PASS ${SERVICE_FILE}: imports BrewInstalledLoader`);
  }

  // G6：H 的通知计数过滤必须走 ReleaseIntelFilter（策略联动的唯一入口）
  if (!SENTINEL_FILTER_IMPORT_RE.test(serviceStripped)) {
    console.error(`FAIL ${SERVICE_FILE}: 未 import ReleaseIntelFilter（G6 策略联动唯一入口）`);
    violations++;
  } else {
    console.log(`PASS ${SERVICE_FILE}: imports ReleaseIntelFilter`);
  }

  // Y 组（G12）：情报链路零命令符号。AppStorage 在 Y 组放行（checkAppStorage=false）。
  if (RELEASE_INTEL_FILES.length < 7) {
    throw new Error(`Y 组触达面文件数异常（${RELEASE_INTEL_FILES.length}），检查清单是否被裁剪`);
  }
  for (const rel of RELEASE_INTEL_FILES) {
    const content = readFileSync(join(ROOT, rel), 'utf-8');
    const found = scanContent(content, FORBIDDEN_SYMBOLS, false);
    if (found.length > 0) {
      for (const v of found) {
        console.error(`FAIL ${rel}:${v.line} [${v.rule}] ${v.snippet}`);
        violations++;
      }
    } else {
      console.log(`PASS ${rel}`);
    }
  }

  console.log(`self-tests: ${selfTestCount} passed (${NEGATIVE_CASES.length} negative, ${POSITIVE_CASES.length} positive, ${RI_NEGATIVE_CASES.length + RI_POSITIVE_CASES.length + RI_FORBIDDEN_CASES.length} release-intel)`);
  if (violations > 0) {
    console.error(`audit failed: ${violations} violation(s) in ${files.length + RELEASE_INTEL_FILES.length} touchpoint file(s)`);
    process.exit(1);
  }
  console.log(`audit passed: ${files.length} sentinel + ${RELEASE_INTEL_FILES.length} release-intel file(s), zero command/exec references`);
}

main();
