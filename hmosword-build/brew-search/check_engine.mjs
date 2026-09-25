/**
 * BrewSearchEngine 的可执行检查。
 *
 * 为什么用 Node 而不是 Python（本项目其它检查脚本都是 Python）：要检查的是**真源码**，
 * 而不是它的转写。这层引擎刻意保持零 import 的纯 TS，Node 24 的类型剥离能直接跑它 ——
 * 把 `.ets` 原样复制成 `.mts` 再 import，**不做任何改写**。
 * 一旦有人给它加了 import（例如 import BrewKind），这个脚本会立刻跑不起来：
 * 那正是我们希望被拦住的改动（引擎一旦依赖外部类型，就不再是机器可验的纯函数）。
 *
 * 运行：node hmosword-build/brew-search/check_engine.mjs
 */
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import assert from 'node:assert';

const SRC = new URL('../../features/brewcommon/src/main/ets/model/BrewSearchEngine.ets', import.meta.url);
const dir = mkdtempSync(join(tmpdir(), 'brew-search-'));
let E;
let Entry;
try {
  const copy = join(dir, 'BrewSearchEngine.mts');
  writeFileSync(copy, readFileSync(SRC));
  // 模块加载是 eager 的：import 返回时源码已读入内存，临时目录到这里就可以整个删掉
  ({ BrewSearchEngine: E, BrewSearchEntry: Entry } = await import(copy));
} finally {
  rmSync(dir, { recursive: true, force: true });
}

let n = 0;
const eq = (actual, expected, label) => {
  assert.strictEqual(actual, expected, `${label}: 期望 ${expected}，实际 ${actual}`);
  n++;
};

// ---- 归一化 ----
eq(E.normalize('  RipGrep  '), 'ripgrep', 'normalize 去空白+小写');
eq(E.scoreOf('', 'node', 'x'), 0, '空关键字得 0 分');
eq(E.scoreOf('   ', 'node', 'x'), 0,
  '空白串得 0 分（evaluate 只判 k 长度 0、不做归一化：这里只是恰好没有任何档位命中；归一化由 rank 负责）');

// ---- 打分各档（k 必须已归一化）----
eq(E.scoreOf('node', 'node', ''), 100, '全等');
eq(E.scoreOf('node', 'node@20', ''), 77, '前缀 + 长度惩罚 3（7-4）');
eq(E.scoreOf('a', 'averyveryverylong', ''), 70, '前缀惩罚封顶 10（下界 70）');
eq(E.scoreOf('node', 'node-sass', ''), 75, '前缀优先于词边界（80-5=75 > 70）');
eq(E.scoreOf('sass', 'node-sass', ''), 70, '词边界');
eq(E.scoreOf('20', 'node@20', ''), 70, '@ 也是词边界');
eq(E.scoreOf('node', 'libnode', ''), 60, '子串（不以 node 开头、无边界）');
eq(E.scoreOf('tool', 'ripgrep', 'Search tool like grep'), 40, 'desc 词首');
eq(E.scoreOf('rep', 'x', 'Search tool like grep'), 20, 'desc 子串（非词首：grep 里的 rep）');
eq(E.scoreOf('zzz', 'node', 'Search tool'), 0, '无命中');

// ---- 词首判定不能把 "research" 里的 search 当词首 ----
eq(E.scoreOf('search', 'x', 'research tool'), 20, '"research" 里的 search 不是词首');
eq(E.scoreOf('tool', 'x', 'research tool'), 40, '空格后的 tool 是词首');

// ---- 标签：分数与标签必须同源 ----
// 70 分可由**两条不同规则**给出：词边界命中，与前缀惩罚封顶到 10。任何「从分数反推标签」的
// 写法都会把前者误标成 prefix —— 这正是本文件要钉住的回归。两对断言里的分数相同、标签必须不同。
const pair = (k, token, desc, expectedScore, expectedMatchedBy, label) => {
  eq(E.scoreOf(k, token, desc), expectedScore, `${label}：分数`);
  eq(E.matchedByOf(k, token, desc), expectedMatchedBy, `${label}：matchedBy`);
};
pair('sass', 'node-sass', '', 70, 'word', '词边界命中（70 分）');
pair('a', 'averyveryverylong', '', 70, 'prefix', '前缀惩罚封顶到 10（同为 70 分，标签必须是 prefix）');
eq(E.matchedByOf('tool', 'x', 'Search tool like grep'), 'descHead', 'desc 词首的 matchedBy');
// 最后两档此前无人钉住：desc（desc 子串，但不是词首）与 none（一条规则都没命中）
eq(E.matchedByOf('rep', 'x', 'Search tool like grep'), 'desc', 'desc 子串（非词首）→ desc');
eq(E.matchedByOf('zzz', 'node', 'Search tool'), 'none', '无命中 → none');

// ---- 排序：score → vol30d → order ----
const mk = (kind, token, desc, vol30d, order) => {
  const e = new Entry();
  e.kind = kind; e.token = token; e.desc = desc; e.vol30d = vol30d; e.order = order;
  return e;
};
const entries = [
  mk('formula', 'libnode', '', 999999, 0),    // 60（子串）
  mk('cask', 'node', '', 10, 1),              // 100
  mk('formula', 'node-sass', '', 500, 2),     // 75（前缀，9 字符）
  mk('formula', 'node@3', '', 100, 6),        // 78（前缀，6 字符）
  mk('formula', 'nodenv', '', 500, 4),        // 78（前缀，6 字符）
  mk('formula', 'node@2', '', 100, 5),        // 78（前缀，6 字符）
  mk('formula', 'nothing', 'unrelated', 1, 7),
];
const hits = E.rank('node', entries, 50);
eq(hits.length, 6, '命中数（nothing 不命中）');
// 逐级验证 tie-break：node(100) > nodenv(78,500) > node@2(78,100,order5) > node@3(78,100,order6) > node-sass(75) > libnode(60)
eq(hits.map((h) => h.token).join(','), 'node,nodenv,node@2,node@3,node-sass,libnode',
  '排序：score → vol30d → order 三级 tie-break');
eq(hits[0].matchedBy, 'exact', 'matchedBy exact');
eq(hits[1].matchedBy, 'prefix', 'matchedBy prefix');
eq(hits[5].matchedBy, 'substr', 'matchedBy substr');
// rank 也必须带上正确标签：fixture 里的 node-sass 只在词边界命中时才是 word
const sassHits = E.rank('sass', entries, 50);
eq(sassHits.length, 1, 'rank: sass 在 fixture 里只命中 node-sass');
eq(sassHits[0].token, 'node-sass', 'rank: 命中项确实是 node-sass');
eq(sassHits[0].matchedBy, 'word', 'rank: node-sass 的 matchedBy 是 word（不是 prefix）');

// ---- limit ----
eq(E.rank('node', entries, 2).length, 2, 'limit 生效');
eq(E.rank('node', entries, 0).length, 6, 'limit=0 表示不截断');
// limit<0 与 limit=0 走的是同一个分支（`limit > 0 && ...`），两条都要钉住
eq(E.rank('node', entries, -1).length, 6, 'limit<0 同样表示不截断');
// 归一化由 rank 自己做：大小写不同的关键字必须得到同一批命中
eq(E.rank('NODE', entries, 50).length, 6, 'rank 内部归一化关键字（混合大小写）');
eq(E.rank('', entries, 50).length, 0, '空关键字不产生结果');

// ---- 确定性：同输入同输出（项目里这条性质被当正确性判据用）----
// 这里只证明**这一份输入**上两次调用一致；全序的真正保证在 rank 的三级 tie-break
// （score → vol30d → order，order 唯一）
eq(E.rank('node', entries, 50).map((h) => h.token).join(','), hits.map((h) => h.token).join(','),
  '同输入同输出（两次调用）；真正的定序保证在 rank 的三级 tie-break（order 唯一）');

// ---- chips 过滤：顺序必须与「全部」一致 ----
eq(E.filterByKind(hits, 'formula').map((h) => h.token).join(','), 'nodenv,node@2,node@3,node-sass,libnode',
  'kind 过滤保持相对顺序');
eq(E.filterByKind(hits, 'cask').map((h) => h.token).join(','), 'node', 'cask 过滤');
eq(E.filterByKind(hits, '').length, 6, '空 kind 不过滤');

console.log(`OK: BrewSearchEngine 检查通过，${n} 条断言`);
