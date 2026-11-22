/**
 * TldrParser 的可执行检查（G12：抽样 30 页 + 构造用例全绿）。
 *
 * 为什么用 Node 而不是 Python：要检查的是**真源码**，而不是它的转写。解析器刻意保持
 * 「除 TldrPage 模型外零 import」的纯函数，本脚本把 `TldrParser.ets` 与 `TldrPage.ets`
 * 原样拷进临时目录当 `.mts` 跑（Node 的类型剥离）。与 `brew-search/check_engine.mjs`
 * 的唯一差别是解析器必须引用模型类型，所以拷贝时**只重写那一行 import 的路径**：
 * 脚本先断言源文件里恰好有一行 `import { TldrExample, TldrPage } from '../model/TldrPage';`，
 * 改成 `'./TldrPage.mts'`，其余字节不动 —— 有人动过这一行，脚本会立刻失败，
 * 而不是静默检查到一份被改写过的代码。
 *
 * 抽样：`pages/` 下 30 页**真实 tldr 仓库快照**（2026-11-22 经 jsDelivr 抓取，25 zh + 5 en，
 * 覆盖 common/linux/osx 三个平台目录）。`--fetch` 重新抓一遍并覆盖快照
 * （与 `brew-mockgen/check_algo.py --fetch` 同一模式）；默认离线跑快照。
 *
 * 运行：node hmosword-build/brew-tldr/check_tldr_parser.mjs
 */
import { readFileSync, writeFileSync, mkdirSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert';

const HERE = dirname(fileURLToPath(import.meta.url));
const COMMON_ETS = join(HERE, '../../features/brewcommon/src/main/ets');
const PAGES_DIR = join(HERE, 'pages');
const FETCH = process.argv.includes('--fetch');

const JSDELIVR_BASE = 'https://cdn.jsdelivr.net/gh/tldr-pages/tldr@main';

/** 抽样清单：spec §9 的高频 token + 平台覆盖。ripgrep 不在清单 —— 它是负缓存用例（tldr 页名是 rg） */
const SAMPLES = [
  ...['wget', 'curl', 'jq', 'ffmpeg', 'gh', 'htop', 'tree', 'yt-dlp', 'fd', 'node', 'npm', 'git',
    'docker', 'tar', 'gzip', 'ssh', 'awk', 'grep', 'find', 'chmod', 'chown', 'kill', 'ls', 'mkdir', 'ps']
    .map((token) => ({ token, locale: 'zh', platform: 'common' })),
  { token: 'rg', locale: 'en', platform: 'common' },
  { token: 'brew', locale: 'en', platform: 'common' },
  { token: 'tar', locale: 'en', platform: 'common' },
  { token: 'apt', locale: 'en', platform: 'linux' },
  { token: 'open', locale: 'en', platform: 'osx' },
];

const samplePath = (sample) => join(PAGES_DIR, sample.locale, sample.platform, `${sample.token}.md`);

// ---- --fetch：重抓快照 ----
if (FETCH) {
  console.log(`--fetch: 从 jsDelivr 重抓 ${SAMPLES.length} 页快照`);
  for (const sample of SAMPLES) {
    const url = `${JSDELIVR_BASE}/pages${sample.locale === 'zh' ? '.zh' : ''}/${sample.platform}/${sample.token}.md`;
    // jsDelivr 对突发速率会回 403（实测）：小退避重试两次，仍失败就让断言响
    let text = null;
    let lastStatus = 0;
    for (let attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        await new Promise((resolve) => setTimeout(resolve, 5000 * attempt));
      }
      const resp = await fetch(url);
      lastStatus = resp.status;
      if (resp.status === 200) {
        text = await resp.text();
        break;
      }
    }
    assert.strictEqual(lastStatus, 200, `fetch ${url} 期望 200，实际 ${lastStatus}`);
    assert.ok(text.startsWith('# '), `fetch ${url} 正文应以标题行开头`);
    const dest = samplePath(sample);
    mkdirSync(dirname(dest), { recursive: true });
    writeFileSync(dest, text);
    console.log(`  ok ${sample.locale}/${sample.platform}/${sample.token}.md (${text.length}B)`);
    await new Promise((resolve) => setTimeout(resolve, 1000)); // 对限流礼貌一点
  }
}

// ---- 加载真源码（拷贝 + 断言式单行 import 改写）----
const dir = join(tmpdir(), `brew-tldr-${Date.now()}`);
let P;
try {
  mkdirSync(dir, { recursive: true });
  const modelSrc = readFileSync(join(COMMON_ETS, 'model/TldrPage.ets'), 'utf8');
  const parserSrc = readFileSync(join(COMMON_ETS, 'util/TldrParser.ets'), 'utf8');
  const IMPORT_LINE = `import { TldrExample, TldrPage } from '../model/TldrPage';`;
  const importLines = parserSrc.split('\n').filter((line) => line.startsWith('import '));
  assert.deepStrictEqual(importLines, [IMPORT_LINE],
    'TldrParser.ets 必须只 import TldrPage 模型且逐字匹配（检查脚本依赖这一行做拷贝改写）');
  writeFileSync(join(dir, 'TldrPage.mts'), modelSrc);
  writeFileSync(join(dir, 'TldrParser.mts'), parserSrc.replace(IMPORT_LINE,
    `import { TldrExample, TldrPage } from './TldrPage.mts';`));
  ({ TldrParser: P } = await import(join(dir, 'TldrParser.mts')));
} finally {
  rmSync(dir, { recursive: true, force: true });
}

let n = 0;
const eq = (actual, expected, label) => {
  assert.strictEqual(actual, expected, `${label}: 期望 ${expected}，实际 ${actual}`);
  n++;
};
const ok = (condition, label) => {
  assert.ok(condition, label);
  n++;
};

// ---- 全部抽样页：可解析、标题与 token 一致、每条示例都过「复制逐字一致」不变量 ----
let sampledExamples = 0;
for (const sample of SAMPLES) {
  assert.ok(existsSync(samplePath(sample)), `缺少快照 ${samplePath(sample)}（跑一次 --fetch 生成）`);
  const markdown = readFileSync(samplePath(sample), 'utf8');
  const page = P.parse(markdown, sample.token, sample.locale);
  ok(page !== null, `${sample.token}(${sample.locale}) 解析成功`);
  eq(page.command, sample.token, `${sample.token} 标题与 token 匹配`);
  eq(page.locale, sample.locale, `${sample.token} locale 透传`);
  ok(page.examples.length >= 1, `${sample.token} 至少一条示例（抽样页都是有示例的页面）`);
  ok(!page.summary.includes('另请参阅') && !page.summary.includes('See also'),
    `${sample.token} 说明段不含「另请参阅 / See also」`);
  ok(!page.summary.toLowerCase().includes('more information') && !page.summary.includes('更多信息'),
    `${sample.token} 说明段不含「更多信息 / More information」`);
  for (const example of page.examples) {
    sampledExamples++;
    // G3 的机器可验形式：切段拼接 === 原文；占位符判定与 spec §3.2 的正则同源
    const joined = P.splitCodeSegments(example.code).map((seg) => seg.text).join('');
    eq(joined, example.code, `${sample.token} 示例切段拼接与原文逐字一致`);
    eq(P.hasPlaceholder(example.code), example.hasPlaceholder,
      `${sample.token} hasPlaceholder 与正则判定一致`);
    ok(example.code.length > 0 && example.desc.length > 0,
      `${sample.token} 示例的说明与命令都非空`);
    ok(!example.desc.startsWith('- '), `${sample.token} 说明不带列表前缀`);
  }
}
console.log(`抽样通过：${SAMPLES.length} 页 / ${sampledExamples} 条示例`);

// ---- 构造用例：占位符 ----
{
  const markdown = [
    '# demo',
    '',
    '> Download things.',
    '> More information: <https://example.com>.',
    '',
    '- Fetch a URL to a file:',
    '',
    '`demo {{https://example.com/file}} -o {{out}}`',
    '',
    '- Ping without placeholders:',
    '',
    '`demo --ping`',
  ].join('\n');
  const page = P.parse(markdown, 'demo', 'en');
  ok(page !== null, '构造：基础页可解析');
  eq(page.summary, 'Download things.', '构造：More information 行被丢弃、说明段只剩正文');
  eq(page.examples.length, 2, '构造：两条示例');
  ok(page.examples[0].hasPlaceholder, '构造：占位符示例 hasPlaceholder=true');
  ok(!page.examples[1].hasPlaceholder, '构造：无占位符示例 hasPlaceholder=false');
  ok(!P.isExecutable(page.examples[0].code), '构造：含占位符不可执行（G4）');
  ok(P.isExecutable(page.examples[1].code), '构造：无占位符可执行（G4）');
  const segments = P.splitCodeSegments(page.examples[0].code);
  eq(segments.filter((seg) => seg.placeholder).length, 2, '构造：两个占位符段');
  ok(segments.every((seg) => seg.placeholder === seg.text.startsWith('{{')),
    '构造：占位符段以 {{ 开头（含花括号本体）');
}

// ---- 构造用例：多行说明 ----
{
  const markdown = [
    '# multi',
    '',
    '> A demo page.',
    '',
    '- Do something complicated',
    '  with a wrapped description:',
    '',
    '`multi --go`',
  ].join('\n');
  const page = P.parse(markdown, 'multi', 'en');
  ok(page !== null, '构造：多行说明页可解析');
  eq(page.examples.length, 1, '构造：多行说明仍是一条示例');
  eq(page.examples[0].desc, 'Do something complicated\nwith a wrapped description:',
    '构造：多行说明合并（换行连接）');
  eq(page.examples[0].code, 'multi --go', '构造：代码原样');
}

// ---- 构造用例：无示例页 ----
{
  const markdown = [
    '# empty',
    '',
    '> Only a description.',
    '> No examples here.',
  ].join('\n');
  const page = P.parse(markdown, 'empty', 'en');
  ok(page !== null, '构造：无示例页解析通过（不崩、不误判标题）');
  eq(page.examples.length, 0, '构造：无示例页 examples 为空');
  eq(page.command, 'empty', '构造：无示例页标题仍被校验');
  eq(page.summary, 'Only a description.\nNo examples here.', '构造：无示例页说明段完整');
  ok(page !== null && P.parse(markdown, 'other', 'en') === null,
    '构造：无示例页 + token 不匹配 → null（F6）');
}

// ---- 构造用例：中文页 ----
{
  const markdown = [
    '# 中文页',
    '',
    '> 从网络上下载文件。',
    '> 支持 HTTP，HTTPS 和 FTP。',
    '> 另请参阅：`wcurl`, `curl`。',
    '> 更多信息：<https://example.com/manual>。',
    '',
    '- 将该 URL 的内容下载到文件中：',
    '',
    '`wget {{https://example.com/foo}}`',
  ].join('\n');
  const page = P.parse(markdown, 'wget', 'zh');
  ok(page === null, '构造：中文页标题与 token 不匹配 → null（F6，防御抓错页）');
  const matched = P.parse(markdown, '中文页', 'zh');
  ok(matched !== null, '构造：中文页按标题匹配解析成功（token 为页名）');
  eq(matched.summary, '从网络上下载文件。\n支持 HTTP，HTTPS 和 FTP。',
    '构造：中文页的另请参阅 / 更多信息行被丢弃');
  eq(matched.examples.length, 1, '构造：中文页示例条数');
  ok(matched.examples[0].hasPlaceholder, '构造：中文页占位符示例');
}

// ---- 构造用例：围栏代码块兼容 + 引号包裹的占位符 ----
{
  const fenced = [
    '# fenced',
    '',
    '> A fenced page.',
    '',
    '- Do it:',
    '',
    '```',
    'fenced --flag \\',
    '  --other',
    '```',
  ].join('\n');
  const page = P.parse(fenced, 'fenced', 'en');
  ok(page !== null && page.examples.length === 1, '构造：围栏代码块作为兼容分支可解析');
  eq(page.examples[0].code, 'fenced --flag \\\n  --other', '构造：围栏内多行原样保留');
  ok(page.examples[0].hasPlaceholder === false, '构造：围栏示例无占位符');

  const quoted = '`yt-dlp "{{https://example.com/watch?v=1}}"`';
  const segments = P.splitCodeSegments(quoted.slice(1, -1));
  eq(segments.filter((seg) => seg.placeholder).length, 1, '构造：引号在花括号外仍识别为一个占位符段');
  ok(segments.some((seg) => !seg.placeholder && seg.text.includes('"')),
    '构造：花括号外的引号留在普通文本段（原文的一部分）');
}

// ---- 失败结构（F3 / F6）----
{
  ok(P.parse('', 'wget', 'zh') === null, '构造：空 markdown → null（F3）');
  ok(P.parse('没有标题行\n\n`wget x`', 'wget', 'zh') === null, '构造：无标题行 → null（F3）');
  ok(P.parse('# other\n\n> 描述\n\n`wget x`', 'wget', 'zh') === null,
    '构造：标题与 token 不匹配 → null（F6）');
}

console.log(`OK: TldrParser 检查通过，${n} 条断言`);
