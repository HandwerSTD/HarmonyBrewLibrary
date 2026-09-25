# 搜索功能实现计划（brew 应用市场）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给 Homebrew 应用市场加搜索：侧边栏搜索框 + 历史/发现浮层 + 真实本地搜索结果页，且退出搜索后原页签状态不丢。

**Architecture:** 匹配跑在设备端已有的两份内存数据上（目录 `vol30d` + 元数据索引 `token→desc`），不引入新数据源、不发请求。引擎是**零 import 的纯函数**，因此能在 Node 里直接跑真测试。搜索态挂在内容区：`HomeView` 用 `Stack + Visibility.Hidden` 保活，搜索结果页走自己独立的 `NavPathStack`，详情页零改动复用。

**Tech Stack:** ArkTS / ArkUI（Stage 模型，API 23）、HDS（`@kit.UIDesignKit`：`HdsSideBar` / `HdsNavigation` / `HdsNavDestination` / `HdsListItemCard`）、HAR 模块化、Node 24（只用于跑引擎检查脚本）。

**Spec:** `docs/superpowers/specs/2026-09-21-brew-search-design.md`（本计划是它的实现；两份一起读）

## Global Constraints

- **只跑 PC**：`deviceTypes` 照抄 `features/brewdiscover`；目标设备 `HUAWEI MateBook Pro / 127.0.0.1:42021`。
- **构建只用 `devecocli build`**（`[Outside sandbox]`），不要直接调 `hvigorw`。
- **绝对不要碰 `hdc`**：`hdc kill` 会杀掉 `devecocli` 依赖的 hdc server，设备掉线后 Agent 侧无法自行恢复（handover §8.6 实测踩过）。
- **符号自检**：`strings <modules.abc> | grep -c <符号>` **不要加 `^...$` 锚点**（加了连跑通的符号也会是 0，handover §9.5.1）。
- **版面数值必须用 `devecocli ui layout` 量**，不靠猜（handover §8.5）。
- **不存在的 `sys.symbol.*` 是「构建全绿、运行期才炸」**（handover §10.6）→ 本计划新增的 3 个符号必须装机看截图确认。
- 文案三份同步：`base`（英文）/ `zh_CN` / `en_US`。
- 新建 HAR 模块必须带模块级 `.gitignore`（首行 `/oh_modules`），否则会把依赖符号链接提交进去（`brewdiscover` 踩过）。
- **`BrewSearchEngine.ets` 必须保持零 import**：只要 import 任何东西，Node 检查脚本就跑不了（这是本计划唯一的真测试手段，见 Task 1）。
- 提交信息写**改动理由 + 实测结果**（项目惯例，比 diff 有信息量）。
- 每轮改完必查两项（`BUILD SUCCESSFUL` 不够）：符号进字节码 + `router_map.json` 条数（当前 **24**，本计划完成后 **25**）。

## Review Focus

以下五条是 spec 隐含、但**没有任何单元测试能覆盖**、最容易坑住使用者的行为。每条都已绑定到某个任务的一个具体步骤：

1. **首帧就打字（索引还没同步完）**：`BrewMetaSync.start()` 在启动时后台跑（不阻塞首屏），所以冷启动后几秒内索引是空的 → 期望：仍能按包名搜出结果 + 顶部提示，**不是**白屏/崩溃。绑定 Task 5 Step 6。
2. **结果页在栈底按返回键**：期望退出搜索回到原页签；若 `return false` 让它冒泡，会落到 `PcMainPage` 的「再按一次退出应用」Toast —— 用户想退搜索却看到退应用。绑定 Task 5 Step 5。
3. **退出搜索再进来，页签状态必须还在**（G4）：`if/else` 会销毁 `HomeView` 导致页签重置回首页。绑定 Task 7 Step 5。
4. **连续快速输入**：期望只保留最后一次关键字的结果；旧的 `setTimeout` 不回写。绑定 Task 6 Step 1（`clearTimeout` 的防抖实现）+ Task 5 Step 3（陈旧结果丢弃）+ Task 7 Step 6（连输后的日志断言）。
5. **断网但索引在**：目录拿不到时**仍要能搜**（desc 索引是落盘的、离线可用），只是排序缺 `vol30d`。绑定 Task 3 Step 3（回落分支）+ Task 7 Step 6（真机日志 `rows from index only`）。

---

## File Structure

**新建**

| 文件 | 职责 |
|---|---|
| `hmosword-build/brew-search/check_engine.mjs` | 引擎的可执行检查（把 `.ets` 原样复制成 `.mts` 后 import，不改写源码） |
| `features/brewcommon/src/main/ets/model/BrewSearchEngine.ets` | 纯匹配 + 排序：零 import、无状态、无网络 |
| `features/brewsearch/**`（新 HAR 模块） | 见下 |
| ↳ `constant/BrewSearchConstants.ets` | 死写词组、防抖、chips id |
| ↳ `viewmodel/BrewSearchState.ets` | **每页实例**状态（keyword / chips / 上一次结果） |
| ↳ `viewmodel/BrewSearchVM.ets` | 单例：历史与发现的会话状态、跑引擎、给 chips 与行数据 |
| ↳ `model/BrewSearchRowSource.ets` | 结果行包装（`kind` + `BrewPackageItem`）与 `IDataSource` |
| ↳ `component/BrewSearchSuggestions.ets` | 历史 + 发现（**浮层与结果页空态共用一份实现**） |
| ↳ `component/BrewSideSearchBox.ets` | 侧边栏搜索框 + `bindPopup` 浮层 |
| ↳ `view/BrewSearchHomeView.ets` | 内容区壳（自己的 `PageContext`） |
| ↳ `view/BrewSearchResultView.ets` | 结果页（栈底） |

**改动**

| 文件 | 改什么 |
|---|---|
| `features/brewcommon/.../service/BrewService.ets` | + `public searchRows(kind)` |
| `features/brewcommon/.../service/BrewBrowseBuilder.ets` | `formulaItem`/`caskItem`：`private static` → `public static`（只改可见性） |
| `features/brewcommon/.../component/BrewPackageRow.ets` | + `@Prop hideRank: boolean = false` |
| `features/brewcommon/.../model/BrewRepository.ets` | + `BrewSearchResult` / `BrewSearchModel` |
| `features/brewcommon/.../constant/BrewConstants.ets` | + `BREW_SEARCH_LIMIT`（数据层的截断口径，不能放 brewsearch，否则循环依赖） |
| `features/brewcommon/Index.ets` | 导出上面新增的公开符号 |
| `features/brewcommon/src/main/resources/{base,zh_CN,en_US}/element/string.json` | + 11 条搜索文案、改 1 条（placeholder 的中文）、删 1 条（coming_soon） |
| `common/.../model/PageEnum.ets` | + `BREW_SEARCH_RESULT_VIEW` |
| `common/.../constant/CommonEnums.ets` | + `BREW_SEARCH_PAGE_CONTEXT` / `BREW_SEARCH_ACTIVE` / `BREW_SEARCH_KEYWORD` |
| `build-profile.json5` | `modules[]` + `brewsearch` |
| `products/pc/oh-package.json5` | + `@ohos/brewsearch` |
| `products/pc/.../component/CustomSideBar.ets` | 插搜索框；切页签时退出搜索态 |
| `products/pc/.../page/PcMainPage.ets` | 内容区改 `Stack` + 保活 + 搜索态 |
| `docs/brew-handover.md` / `docs/brew-marketplace-content-plan.md` / `docs/brew-api-design.md` | 同步文档（Task 8） |

---

## Task 1: 匹配引擎 + 可执行检查

**Files:**
- Create: `hmosword-build/brew-search/check_engine.mjs`
- Create: `features/brewcommon/src/main/ets/model/BrewSearchEngine.ets`

**Interfaces:**
- Consumes: 无（本任务不依赖任何既有代码，这是刻意的 —— 引擎保持零 import）
- Produces:
  - `class BrewSearchEntry { kind: string; token: string; desc: string; vol30d: number; order: number }`
  - `class BrewSearchHit { kind: string; token: string; desc: string; vol30d: number; score: number; matchedBy: string; order: number }`
  - `const BREW_SEARCH_SCORE_EXACT|PREFIX_BASE|PREFIX_PENALTY_MAX|WORD|SUBSTR|DESC_HEAD|DESC: number`
  - `class BrewSearchScore { score: number; matchedBy: string }`
  - `BrewSearchEngine.normalize(keyword: string): string`
  - `BrewSearchEngine.evaluate(k: string, token: string, desc: string): BrewSearchScore`
  - `BrewSearchEngine.scoreOf(k: string, token: string, desc: string): number`
  - `BrewSearchEngine.matchedByOf(k: string, token: string, desc: string): string`
  - `BrewSearchEngine.rank(keyword: string, entries: BrewSearchEntry[], limit: number): BrewSearchHit[]`
  - `BrewSearchEngine.filterByKind(hits: BrewSearchHit[], kind: string): BrewSearchHit[]`

- [ ] **Step 1: 写检查脚本（此时引擎还不存在）**

创建 `hmosword-build/brew-search/check_engine.mjs`：

```javascript
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
```

- [ ] **Step 2: 跑它，确认失败**

Run: `node hmosword-build/brew-search/check_engine.mjs`
Expected: FAIL —— `ENOENT: no such file or directory, open '.../features/brewcommon/src/main/ets/model/BrewSearchEngine.ets'`

- [ ] **Step 3: 写引擎**

创建 `features/brewcommon/src/main/ets/model/BrewSearchEngine.ets`（Apache 许可证头照抄 `BrewBrowseBuilder.ets` 的前 15 行）：

```typescript
/**
 * 搜索的匹配与排序：**纯函数层**。
 *
 * 三条刻意约束，都不是风格问题：
 *   1. **零 import** —— 于是 `hmosword-build/brew-search/check_engine.mjs` 能把本文件原样
 *      当成 `.mts` 跑起来（Node 的类型剥离）。加任何 import 都会让那份检查失效。
 *   2. **kind 用 `string` 而不是 `BrewKind`** —— 同上：`BrewKind` 在 `BrewModels.ets` 里，
 *      import 它就破坏了第 1 条。`BrewService` / `BrewTaxonomy` 本来就是拿 `string`
 *      当 kind 用的（`BrewKindText.FORMULA`），口径一致。
 *   3. **无状态、无网络、无时间** —— 排序的 tie-break 里不允许出现 `Date.now()` 或随机，
 *      否则「同输入同输出」这条性质就没了（生成器那边正是拿它当正确性判据的）。
 */

export class BrewSearchEntry {
  public kind: string = '';
  public token: string = '';
  public desc: string = '';
  public vol30d: number = 0;
  /** 目录里的原始下标：同分同安装量时的稳定 tie-break */
  public order: number = 0;
}

export class BrewSearchHit {
  public kind: string = '';
  public token: string = '';
  public desc: string = '';
  public vol30d: number = 0;
  public score: number = 0;
  /** 'exact' | 'prefix' | 'word' | 'substr' | 'descHead' | 'desc' | 'none'，只用于日志。
   * `rank()` 每次都会赋值，这里的初始值只是占位：取 **枚举内的 `'none'`**（不是 `''`），
   * 与 `BrewSearchScore.matchedBy` 口径一致，读日志时不会看到枚举外的空串。 */
  public matchedBy: string = 'none';
  /** 目录里的原始下标。**不在 UI 上展示** */
  public order: number = 0;
}

export const BREW_SEARCH_SCORE_EXACT: number = 100;
export const BREW_SEARCH_SCORE_PREFIX_BASE: number = 80;
/** 前缀档的长度惩罚上限：把前缀档的下界钉在 70（= 词边界档），始终高于子串档 60 */
export const BREW_SEARCH_SCORE_PREFIX_PENALTY_MAX: number = 10;
export const BREW_SEARCH_SCORE_WORD: number = 70;
export const BREW_SEARCH_SCORE_SUBSTR: number = 60;
export const BREW_SEARCH_SCORE_DESC_HEAD: number = 40;
export const BREW_SEARCH_SCORE_DESC: number = 20;

/**
 * 分数与命中方式**同源**的载体：`evaluate()` 一次判定里同时填这两个字段。
 *
 * 为什么必须同源：**70 分可由两条不同规则给出** —— 前缀惩罚封顶到 10、以及词边界命中。
 * 因此任何「从分数反推标签」的映射（`score >= 70 → 'prefix'`）都会把词边界误标成 `prefix`。
 * 同一分数对应不同规则时，只有携带规则本身的判定结果才能给出正确标签。
 */
export class BrewSearchScore {
  public score: number = 0;
  /** 'exact' | 'prefix' | 'word' | 'substr' | 'descHead' | 'desc' | 'none'，只用于日志 */
  public matchedBy: string = 'none';
}

export class BrewSearchEngine {
  public static normalize(keyword: string): string {
    return keyword.trim().toLowerCase();
  }

  /**
   * 判定一次，同时得到分数与命中方式。
   *
   * 规则链按优先级自上而下：exact → prefix → word → substr → descHead → desc，停在第一个
   * 命中的档位上（所以一个条目只算一次分）。分数与标签在同一个分支里一起写，二者不可能不一致。
   *
   * `k` **必须是 `normalize()` 过的**（调用点只有 `rank()`，所以这条由 `rank` 保证）。
   */
  public static evaluate(k: string, token: string, desc: string): BrewSearchScore {
    const result: BrewSearchScore = new BrewSearchScore();
    // 契约：`k` **必须已由 `normalize()` 归一化**。生产路径上的唯一调用点是 `rank()`（它先归一化
    // 再判空）；`scoreOf()` / `matchedByOf()` 只是转发，供检查脚本使用。这里只判 `k.length === 0`，
    // **不 trim**：传入未归一化的原始关键字（例如 `' '`）不在支持范围内。
    if (k.length === 0) {
      return result;
    }
    if (token === k) {
      result.score = BREW_SEARCH_SCORE_EXACT;
      result.matchedBy = 'exact';
      return result;
    }
    if (token.startsWith(k)) {
      result.score = BREW_SEARCH_SCORE_PREFIX_BASE -
        Math.min(BREW_SEARCH_SCORE_PREFIX_PENALTY_MAX, token.length - k.length);
      result.matchedBy = 'prefix';
      return result;
    }
    if (BrewSearchEngine.hasWordSegment(token, k)) {
      result.score = BREW_SEARCH_SCORE_WORD;
      result.matchedBy = 'word';
      return result;
    }
    if (token.includes(k)) {
      result.score = BREW_SEARCH_SCORE_SUBSTR;
      result.matchedBy = 'substr';
      return result;
    }
    const lower: string = desc.toLowerCase();
    if (BrewSearchEngine.hasWordHead(lower, k)) {
      result.score = BREW_SEARCH_SCORE_DESC_HEAD;
      result.matchedBy = 'descHead';
      return result;
    }
    if (lower.includes(k)) {
      result.score = BREW_SEARCH_SCORE_DESC;
      result.matchedBy = 'desc';
      return result;
    }
    return result;
  }

  /** 打分。转发到 `evaluate()`：与 `matchedByOf()` 出自同一条判定链 */
  public static scoreOf(k: string, token: string, desc: string): number {
    return BrewSearchEngine.evaluate(k, token, desc).score;
  }

  /** 命中方式（日志用）。转发到 `evaluate()`：与 `scoreOf()` 出自同一条判定链 */
  public static matchedByOf(k: string, token: string, desc: string): string {
    return BrewSearchEngine.evaluate(k, token, desc).matchedBy;
  }

  /** `-` 与 `@` 都算分隔符：`node@20` 里 `20` 是独立一段（`python@3.13` 同理） */
  private static splitSegments(token: string): string[] {
    const out: string[] = [];
    token.split('-').forEach((part: string) => {
      part.split('@').forEach((piece: string) => {
        if (piece.length > 0) {
          out.push(piece);
        }
      });
    });
    return out;
  }

  private static hasWordSegment(token: string, k: string): boolean {
    return BrewSearchEngine.splitSegments(token).some((seg: string) => seg === k);
  }

  private static isWordChar(ch: string): boolean {
    return (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9');
  }

  /**
   * desc 里是否有**词首**等于 `k`。手写扫描而不用正则/`split(/[^a-z0-9]+/)`：
   * 正则在这条路径上是每次匹配都在编译，而这里是 2.6 万行的热循环。
   * 注意 `atHead` 只在遇到非单词字符时置位 —— `research` 里的 `search` 不算词首。
   */
  private static hasWordHead(lowerDesc: string, k: string): boolean {
    let atHead: boolean = true;
    for (let i: number = 0; i < lowerDesc.length; i++) {
      const ch: string = lowerDesc.charAt(i);
      if (!BrewSearchEngine.isWordChar(ch)) {
        atHead = true;
        continue;
      }
      if (atHead && lowerDesc.substring(i, i + k.length) === k) {
        return true;
      }
      atHead = false;
    }
    return false;
  }

  /**
   * 排序 + 截断。`limit <= 0` 表示不截断（调用方要「命中总数」时用它）。
   *
   * 三级定序：`score` 降序 → `vol30d` 降序 → `order` 升序。
   * `order` 唯一，所以结果是全序，不依赖 `sort` 的稳定性。
   */
  public static rank(keyword: string, entries: BrewSearchEntry[], limit: number): BrewSearchHit[] {
    const k: string = BrewSearchEngine.normalize(keyword);
    if (k.length === 0) {
      return [];
    }
    const hits: BrewSearchHit[] = [];
    entries.forEach((entry: BrewSearchEntry) => {
      const scored: BrewSearchScore = BrewSearchEngine.evaluate(k, entry.token, entry.desc);
      if (scored.score > 0) {
        const hit: BrewSearchHit = new BrewSearchHit();
        hit.kind = entry.kind;
        hit.token = entry.token;
        hit.desc = entry.desc;
        hit.vol30d = entry.vol30d;
        hit.score = scored.score;
        hit.matchedBy = scored.matchedBy;
        hit.order = entry.order;
        hits.push(hit);
      }
    });
    hits.sort((a: BrewSearchHit, b: BrewSearchHit) => {
      if (a.score !== b.score) {
        return b.score - a.score;
      }
      if (a.vol30d !== b.vol30d) {
        return b.vol30d - a.vol30d;
      }
      return a.order - b.order;
    });
    return limit > 0 && hits.length > limit ? hits.slice(0, limit) : hits;
  }

  /** chips 过滤。`kind` 为空串表示不过滤（「全部」） */
  public static filterByKind(hits: BrewSearchHit[], kind: string): BrewSearchHit[] {
    return kind.length === 0 ? hits : hits.filter((hit: BrewSearchHit) => hit.kind === kind);
  }
}
```

- [ ] **Step 4: 跑检查，确认通过**

Run: `node hmosword-build/brew-search/check_engine.mjs`
Expected: `OK: BrewSearchEngine 检查通过，39 条断言`

- [ ] **Step 5: 确认引擎仍为零 import（这条性质是后续所有验证的前提）**

Run: `grep -c "^import" features/brewcommon/src/main/ets/model/BrewSearchEngine.ets`
Expected: `0`

- [ ] **Step 6: 编译（确认 ArkTS 接受它）**

Run: `devecocli build 2>&1 | tail -5`
Expected: `BUILD SUCCESSFUL`

- [ ] **Step 7: 提交**

```bash
git add hmosword-build/brew-search/check_engine.mjs features/brewcommon/src/main/ets/model/BrewSearchEngine.ets
git commit -m "feat(brew): 搜索匹配引擎（纯函数 + 可执行检查）

引擎刻意保持零 import：Node 24 的类型剥离能把这份 .ets 原样当 .mts 跑，
所以 hmosword-build/brew-search/check_engine.mjs 检查的是**真源码**而不是它的转写
（本项目其它检查脚本是 Python，唯独这份必须能执行 ArkTS 本体）。

打分：token 全等 100 / 前缀 80-长度惩罚（封顶 10，下界 70）/ 词边界 70 /
子串 60 / desc 词首 40 / desc 子串 20；定序 score → vol30d → order（全序，不用 sort 稳定性）。

实测：39 条断言通过；grep -c '^import' = 0；devecocli build BUILD SUCCESSFUL。

写用例时抓到并修掉两处我自己算错的期望值（都是手算暴露的）：
  node@20 长度 7 → 80-(7-4)=77（不是 78）；nodenv 是前缀 78 而不是子串 60。"
```

> **事后更正（2026-09-22，执行期）**：本节引擎代码里 `matchedByOf` 的第一版用
> `score >= 70` 反推 `prefix`，而 `word` 档**恰好也是 70 分** → 词边界命中被误标成 `prefix`
> 且 `word` 分支不可达。评审点出后已改为「分数与标签出自同一条判定链」（新增
> `BrewSearchScore` + `evaluate()`，`scoreOf`/`matchedByOf` 转发，`rank` 每条只走一次链），
> 并补了 4 组标签断言 —— 断言数因此从 27 变成 **35**。上面代码块已是更正后的版本。
> 修复提交：`abec113`；等价性证据：1995 组 `(k, token, desc)` 对照扫描，分数零差异。

---

## Task 2: `brewcommon` 三处公开入口

**Files:**
- Modify: `features/brewcommon/src/main/ets/service/BrewService.ets`（`catalogInstallsOf` 之后）
- Modify: `features/brewcommon/src/main/ets/service/BrewBrowseBuilder.ets:214,233`
- Modify: `features/brewcommon/src/main/ets/component/BrewPackageRow.ets`
- Modify: `features/brewcommon/src/main/ets/constant/BrewConstants.ets`

**Interfaces:**
- Consumes: Task 1 的 `BrewSearchEngine`（本任务不直接用，但同模块后续要用）
- Produces:
  - `BrewService.searchRows(kind: string): CatalogEntry[]`
  - `BrewBrowseBuilder.formulaItem(row: CatalogEntry, doc: LiveFormulaDoc | undefined, desc: string, categoryKey: string): BrewPackageItem`（公开化）
  - `BrewBrowseBuilder.caskItem(row: CatalogEntry, doc: LiveCaskDoc | undefined, desc: string, categoryKey: string): BrewPackageItem`（公开化）
  - `BrewPackageRow.hideRank: boolean`
  - `BREW_SEARCH_LIMIT: number`（值 `50`）

- [ ] **Step 1: 给 `BrewService` 加公开的目录全量行入口**

在 `features/brewcommon/src/main/ets/service/BrewService.ets` 里，紧接 `public catalogInstallsOf(...)` 方法之后（约 `:1005`，方法体结束的 `}` 之后）插入：

```typescript
  /**
   * 目录里的**全量行**（浏览集 = 目录全量，已按 30d 安装量降序，不裁切）。
   *
   * 搜索要的就是这一份数据，但 `browseRows` 是 `private static` —— TS 的 private 是
   * **类作用域**而不是模块作用域，跨类（`BrewSearchModel`）拿不到，所以在类内部开一个口子。
   * 返回空数组表示「目录没拿到」（无网 / SNAPSHOT 模式），调用方据此回落 desc 索引。
   */
  public searchRows(kind: string): CatalogEntry[] {
    const catalog: BrewCatalog | undefined = BrewService.ensureCatalog();
    return catalog === undefined ? [] : BrewService.browseRows(catalog, kind);
  }
```

- [ ] **Step 2: 把两个行工厂从 private 改成 public**

`features/brewcommon/src/main/ets/service/BrewBrowseBuilder.ets:214`：

```typescript
  private static formulaItem(row: CatalogEntry, doc: LiveFormulaDoc | undefined, desc: string,
    categoryKey: string): BrewPackageItem {
```

改成（只改可见性，**同时补一句为什么 doc 允许缺省**）：

```typescript
  /**
   * 行数据的唯一构造口径（分类首页与搜索结果都用它，避免两处各写一遍导致漂移）。
   * `doc` 允许 `undefined`：搜索结果不拉现网单条，而下面每个字段都是 `doc?.x ?? ''`，
   * 缺省时拿到空串而不是崩 —— 列表行只展示 `token` / `desc` / `installs30d`。
   */
  public static formulaItem(row: CatalogEntry, doc: LiveFormulaDoc | undefined, desc: string,
    categoryKey: string): BrewPackageItem {
```

`:233` 同样处理：

```typescript
  private static caskItem(row: CatalogEntry, doc: LiveCaskDoc | undefined, desc: string,
    categoryKey: string): BrewPackageItem {
```

改成：

```typescript
  /** 同 `formulaItem`：`doc` 允许缺省，搜索结果不拉单条 */
  public static caskItem(row: CatalogEntry, doc: LiveCaskDoc | undefined, desc: string,
    categoryKey: string): BrewPackageItem {
```

- [ ] **Step 3: 给行组件加「隐藏名次」开关**

`features/brewcommon/src/main/ets/component/BrewPackageRow.ets`，在 `@Prop itemHeight` 之后加一行：

```typescript
  /**
   * `true` = 不渲染「分类内名次」。搜索结果用：一次搜索跨 17 个分类，没有「分类内名次」
   * 这个语境，而 `BrewFormat.rankText(0, 0)` 会老老实实渲染出 `0 / 0`（它不判 0）。
   * **默认 false，现有 5 个调用点的行为完全不变**（Formulae 分类页/分类卡、Casks 分类页/分类卡、包详情页的「同分类其他包」）。
   */
  @Prop hideRank: boolean = false;
```

并把 `HeatBuilder` 里的第一个 `Text` 用 `if` 包起来（**只加分支，不动原有样式**）：

```typescript
  /** 右侧：分类内排名（可隐藏）+ 近 30 天安装量 + 箭头 */
  @Builder
  HeatBuilder() {
    Row() {
      if (!this.hideRank) {
        Text(BrewFormat.rankText(this.packageItem.categoryRank, this.packageItem.categorySize))
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_tertiary'))
      }
      Text(BrewFormat.compactCount(this.packageItem.installs30d))
        .fontSize($r('sys.float.Body_S'))
        .fontColor($r('sys.color.font_secondary'))
        .margin({ left: $r('sys.float.padding_level6') })
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontColor([$r('sys.color.icon_secondary')])
        .fontSize($r('sys.float.Title_M'))
        .margin({ left: $r('sys.float.padding_level4') })
    }
    .alignItems(VerticalAlign.Center)
    .padding({ right: $r('sys.float.padding_level4') })
  }
```

- [ ] **Step 4: 把截断上限放进 `brewcommon`**

在 `features/brewcommon/src/main/ets/constant/BrewConstants.ets` 末尾追加（**不能放 brewsearch**：`BrewSearchModel` 在 brewcommon，反向依赖会成环）：

```typescript
/**
 * 搜索结果一次上屏的条数上限。
 *
 * 归属说明：它决定的是**数据层返回多少行**（`BrewSearchModel` 里用它 `slice`），
 * 所以必须待在 brewcommon；brewsearch 的 `BrewSearchConstants` 只放 UI 侧的东西
 * （死写词组、防抖、几何）。放在 brewsearch 会让 brewcommon → brewsearch 成环。
 */
export const BREW_SEARCH_LIMIT: number = 50;
```

- [ ] **Step 5: 编译 + 确认没弄坏既有页面**

Run: `devecocli build 2>&1 | tail -5`
Expected: `BUILD SUCCESSFUL`

Run: `grep -rn "hideRank" --include="*.ets" features | grep -v build`
Expected: 只有 `BrewPackageRow.ets` 里的一处声明 + 一处 `if`（**没有任何既有页面传它** —— 传了才说明默认值被破坏）

- [ ] **Step 6: 提交**

```bash
git add features/brewcommon/src/main/ets/service/BrewService.ets \
  features/brewcommon/src/main/ets/service/BrewBrowseBuilder.ets \
  features/brewcommon/src/main/ets/component/BrewPackageRow.ets \
  features/brewcommon/src/main/ets/constant/BrewConstants.ets
git commit -m "feat(brew): 开放搜索所需的三个既有入口（不改既有行为）

- BrewService.searchRows：browseRows 是 private static（TS 的 private 是类作用域，
  跨类不可见），在类内开一个公开口子拿到「目录全量行」。
- BrewBrowseBuilder.formulaItem/caskItem：private static → public static，**只改可见性**。
  搜索要复用它们把 CatalogEntry 变成 BrewPackageItem，但不该再写一遍（复制漂移）。
  doc 传 undefined 是安全的：两个工厂内部全是 doc?.x ?? ''。
- BrewPackageRow.hideRank（默认 false）：搜索结果没有「分类内名次」语境，而
  BrewFormat.rankText(0,0) 会渲染出 \"0 / 0\"（它不判 0）。默认值保证 5 个既有调用点不变。
- BREW_SEARCH_LIMIT 落在 brewcommon 而不是 brewsearch：它是数据层的截断口径，
  放 brewsearch 会让 brewcommon → brewsearch 成环。

实测：build BUILD SUCCESSFUL；grep hideRank 只有声明与 if，没有任何既有页面传它。"
```

---

## Task 3: `BrewSearchModel`（取数 + 回落 + 日志）

**Files:**
- Modify: `features/brewcommon/src/main/ets/model/BrewRepository.ets`（文件末尾追加两个类）
- Modify: `features/brewcommon/Index.ets`

**Interfaces:**
- Consumes: Task 1 的 `BrewSearchEngine` / `BrewSearchEntry` / `BrewSearchHit`；Task 2 的 `BrewService.searchRows` / `BrewBrowseBuilder.formulaItem|caskItem` / `BREW_SEARCH_LIMIT`
- Produces:
  - `class BrewSearchResult { keyword: string; total: number; indexReady: boolean; rowsFromIndexOnly: boolean; hits: BrewSearchHit[]; items: BrewPackageItem[] }`
  - `BrewSearchModel.getInstance(): BrewSearchModel`、`search(keyword: string): Promise<BrewSearchResult>`

- [ ] **Step 1: 追加 `BrewSearchResult` / `BrewSearchModel`**

在 `features/brewcommon/src/main/ets/model/BrewRepository.ets` 的**文件末尾**追加（该文件已 import `BrewKindText`、`BrewTaxonomy`、`BrewMetaSync`、`BrewPackageItem`；本步还要补三个 import，见 Step 2）：

```typescript
// ---------------------------------------------------------------- 搜索

/**
 * 一次搜索的结果。
 *
 * `hits` 与 `items` 是**等长同序的平行数组**（`items[i]` 就是 `hits[i]` 的行数据）：
 * UI 侧要 `kind`（在 hit 上）也要行数据（在 item 上），拆成两个类数组比拼成一个类更好读，
 * 但**不变量必须写死在这里** —— 任何改动都要保持两者同步，否则列表会串行。
 */
export class BrewSearchResult {
  /** 归一化后的关键字。UI 用它判断「这是不是我这次要的结果」（陈旧结果丢弃） */
  public keyword: string = '';
  /** 命中总数（**截断前**），用于「共 N 个结果」 */
  public total: number = 0;
  /** 元数据索引是否就绪。false = desc 一律为空，只按包名匹配过 */
  public indexReady: boolean = true;
  /** 目录拿不到、行是仅凭 desc 索引造出来的（此时 `vol30d` 全为 0，排序信息不全） */
  public rowsFromIndexOnly: boolean = false;
  public hits: BrewSearchHit[] = [];
  public items: BrewPackageItem[] = [];
}

/**
 * 搜索的数据入口（单例 + getInstance，与 `BrewFormulaModel` 等一致）。
 *
 * 三条口径：
 *   1. **同步计算**：目录在内存、索引在内存/Preference，全程不发请求 —— 所以这里
 *      没有 loading 态可言（`Promise` 只是跟随既有仓库层签名，不是真异步）。
 *   2. **目录缺失时回落到 desc 索引**：索引是落盘的、离线可用；只认目录会让
 *      「有索引没目录」（断网 / SNAPSHOT）变成整页空态，而那正是最该能用的时候。
 *   3. **不做结果缓存**：索引与目录本身已在内存，匹配是毫秒级纯计算；
 *      缓存只会引入「数据变了但结果不变」（Discover 吃过这个亏）。
 */
export class BrewSearchModel {
  private static instance: BrewSearchModel | undefined = undefined;
  private service: BrewService = new BrewService();

  private constructor() {
  }

  public static getInstance(): BrewSearchModel {
    if (BrewSearchModel.instance === undefined) {
      BrewSearchModel.instance = new BrewSearchModel();
    }
    return BrewSearchModel.instance;
  }

  public search(keyword: string): Promise<BrewSearchResult> {
    const started: number = Date.now();
    const k: string = BrewSearchEngine.normalize(keyword);
    const result: BrewSearchResult = new BrewSearchResult();
    result.keyword = k;
    if (k.length === 0) {
      return Promise.resolve(result);
    }
    result.indexReady = BrewMetaSync.ready();
    const entries: BrewSearchEntry[] = [];
    let order: number = 0;
    [BrewKindText.FORMULA, BrewKindText.CASK].forEach((kind: string) => {
      const descIndex: Record<string, string> = BrewMetaSync.descOf(kind);
      const rows: CatalogEntry[] = this.service.searchRows(kind);
      if (rows.length > 0) {
        rows.forEach((row: CatalogEntry) => {
          entries.push(BrewSearchModel.entryOf(kind, row.token,
            BrewBrowseBuilder.descOf(row.token, descIndex), row.vol30d, order++));
        });
        return;
      }
      // 目录缺失：用 desc 索引的键当行（vol30d = 0）。索引为空时这一趟也拿不到东西，
      // 于是结果为空 —— UI 那边有「索引未就绪」的提示条兜着，不报错。
      result.rowsFromIndexOnly = true;
      Object.keys(descIndex).forEach((token: string) => {
        entries.push(BrewSearchModel.entryOf(kind, token, descIndex[token], 0, order++));
      });
    });
    const all: BrewSearchHit[] = BrewSearchEngine.rank(k, entries, 0);
    result.total = all.length;
    const limited: BrewSearchHit[] = all.length > BREW_SEARCH_LIMIT ? all.slice(0, BREW_SEARCH_LIMIT) : all;
    result.hits = limited;
    limited.forEach((hit: BrewSearchHit) => result.items.push(this.itemOf(hit)));
    Logger.info(TAG, `search "${k}" → ${result.total} hits, ${result.hits.length} items, ` +
      `indexReady=${result.indexReady}, indexOnly=${result.rowsFromIndexOnly}, ` +
      `${Date.now() - started}ms | top: ${BrewSearchModel.topLine(result.hits)}`);
    return Promise.resolve(result);
  }

  /**
   * 命中行 → 列表行。只补 `token` / `vol30d` 两个字段：`formulaItem` / `caskItem`
   * 内部只读这两个（其余是榜单语义，搜索结果里没有）。
   */
  private itemOf(hit: BrewSearchHit): BrewPackageItem {
    const row: CatalogEntry = {
      token: hit.token,
      vol30d: hit.vol30d,
      vol365d: 0,
      prior: 0,
      velocity: 0,
      score: 0,
    };
    const categoryKey: string = BrewTaxonomy.categoryOf(hit.kind, hit.token, hit.desc);
    // 分支放这里而不是 BrewBrowseBuilder：`BrewKindText` 定义在 BrewService.ets，
    // 而 BrewService 已经 import 了 BrewBrowseBuilder —— 反向 import 会成环。
    return hit.kind === BrewKindText.CASK
      ? BrewBrowseBuilder.caskItem(row, undefined, hit.desc, categoryKey)
      : BrewBrowseBuilder.formulaItem(row, undefined, hit.desc, categoryKey);
  }

  private static entryOf(kind: string, token: string, desc: string, vol30d: number,
    order: number): BrewSearchEntry {
    const entry: BrewSearchEntry = new BrewSearchEntry();
    entry.kind = kind;
    entry.token = token;
    entry.desc = desc;
    entry.vol30d = vol30d;
    entry.order = order;
    return entry;
  }

  /** 日志判据行：Top5 的 `token(分数/方式)`，一眼能看出排序是否合理 */
  private static topLine(hits: BrewSearchHit[]): string {
    return hits.slice(0, 5)
      .map((hit: BrewSearchHit) => `${hit.kind === BrewKindText.CASK ? 'cask:' : ''}${hit.token}` +
        `(${hit.score}/${hit.matchedBy})`)
      .join(' ');
  }
}
```

- [ ] **Step 2: 补三个 import**

`features/brewcommon/src/main/ets/model/BrewRepository.ets` 顶部的 import 区，按现有分组风格补：

```typescript
import { BREW_SEARCH_LIMIT } from '../constant/BrewConstants';
import { BrewBrowseBuilder } from '../service/BrewBrowseBuilder';
import { BrewSearchEngine, BrewSearchEntry, BrewSearchHit } from './BrewSearchEngine';
```

> 若 `Logger` / `BrewMetaSync` / `BrewTaxonomy` 已在该文件 import，**不要重复 import**（先 `grep "^import" features/brewcommon/src/main/ets/model/BrewRepository.ets` 看一遍）。

- [ ] **Step 3: 从 `Index.ets` 导出**

`features/brewcommon/Index.ets` 里，`export { BrewCaskModel, BrewDiscoverModel, BrewFormulaModel, BrewLocalModel } from './src/main/ets/model/BrewRepository';` 这一行改成：

```typescript
export {
  BrewCaskModel,
  BrewDiscoverModel,
  BrewFormulaModel,
  BrewLocalModel,
  BrewSearchModel,
  BrewSearchResult,
} from './src/main/ets/model/BrewRepository';

// 搜索的匹配引擎（纯函数）。导出它是因为 brewsearch 要用 normalize 做「陈旧结果」判定。
export {
  BrewSearchEngine,
  BREW_SEARCH_SCORE_DESC,
  BREW_SEARCH_SCORE_DESC_HEAD,
  BREW_SEARCH_SCORE_EXACT,
  BREW_SEARCH_SCORE_PREFIX_BASE,
  BREW_SEARCH_SCORE_PREFIX_PENALTY_MAX,
  BREW_SEARCH_SCORE_SUBSTR,
  BREW_SEARCH_SCORE_WORD,
} from './src/main/ets/model/BrewSearchEngine';

export type { BrewSearchEntry, BrewSearchHit } from './src/main/ets/model/BrewSearchEngine';
```

并在常量导出块 `} from './src/main/ets/constant/BrewConstants';` 里加一行 `BREW_SEARCH_LIMIT,`（保持字母序位置）。

- [ ] **Step 4: 编译 + 符号自检**

Run: `devecocli build 2>&1 | tail -5`
Expected: `BUILD SUCCESSFUL`

Run: `strings products/pc/build/default/intermediates/loader_out/default/ets/modules.abc | grep -c BrewSearchModel`
Expected: 正数（**不要加 `^...$` 锚点**）

- [ ] **Step 5: 提交**

```bash
git add features/brewcommon/src/main/ets/model/BrewRepository.ets features/brewcommon/Index.ets
git commit -m "feat(brew): 搜索数据入口 BrewSearchModel（同步计算 + 目录缺失回落）

- 同步计算：目录在内存、索引在内存/Preference，全程不发请求，所以没有 loading 态；
  Promise 只是跟随既有仓库层签名。
- 目录缺失时回落到 desc 索引的键（vol30d=0）：索引是落盘的、离线可用，
  只认目录会让「有索引没目录」（断网/SNAPSHOT）变成整页空态，而那正是最该能用的时候。
- 不做结果缓存：数据已在内存、匹配是毫秒级纯计算，缓存只会引入
  「数据变了但结果不变」（Discover 吃过这个亏）。
- hits 与 items 是等长同序的平行数组，不变量写在类注释里。
- 日志判据行：命中数 / 耗时 / indexReady / top5 token(分数/方式)。

实测：build BUILD SUCCESSFUL；strings modules.abc 命中 BrewSearchModel。"
```

---

## Task 4: `brewsearch` 模块骨架 + 最小结果页 + 路由 + 文案

**Files:**
- Create: `features/brewsearch/**`（骨架，见下）
- Modify: `build-profile.json5`
- Modify: `products/pc/oh-package.json5`
- Modify: `common/src/main/ets/model/PageEnum.ets`
- Modify: `common/src/main/ets/constant/CommonEnums.ets`
- Modify: `features/brewcommon/src/main/resources/{base,zh_CN,en_US}/element/string.json`

**Interfaces:**
- Consumes: 无（骨架任务）
- Produces:
  - 路由名 `BrewSearchResultView`，构建函数 `BrewSearchResultBuilder`
  - `PageEnum.BREW_SEARCH_RESULT_VIEW`
  - `StorageKey.BREW_SEARCH_PAGE_CONTEXT` / `BREW_SEARCH_ACTIVE` / `BREW_SEARCH_KEYWORD`
  - `@ohos/brewsearch` 的 `BrewSearchHomeView`
  - 浮点常量 `brew_search_box_height`(40vp) / `brew_search_panel_width`(400vp) / `brew_search_row_height`(64vp)
  - 全部搜索文案键（见 Step 6）

- [ ] **Step 1: 建模块骨架**

```bash
mkdir -p features/brewsearch/src/main/ets/{constant,model,viewmodel,component,view}
mkdir -p features/brewsearch/src/main/resources/base/{element,profile}
mkdir -p features/brewsearch/src/main/resources/zh_CN/element
mkdir -p features/brewsearch/src/main/resources/en_US/element
```

`features/brewsearch/hvigorfile.ts`（与 brewdiscover 逐字一致）：

```typescript
import { harTasks } from '@ohos/hvigor-ohos-plugin';

export default {
    system: harTasks,  /* Built-in plugin of Hvigor. It cannot be modified. */
    plugins:[]         /* Custom plugin to extend the functionality of Hvigor. */
}
```

`features/brewsearch/build-profile.json5`（与 brewdiscover 逐字一致）：

```json5
{
  "apiType": "stageMode",
  "buildOption": {
  },
  "buildOptionSet": [
    {
      "name": "release",
      "arkOptions": {
        "obfuscation": {
          "ruleOptions": {
            "enable": true,
            "files": [
              "./obfuscation-rules.txt"
            ]
          },
          "consumerFiles": [
            "./consumer-rules.txt"
          ]
        }
      },
    },
  ],
  "targets": [
    {
      "name": "default"
    }
  ]
}
```

`features/brewsearch/oh-package.json5`：

```json5
{
  "name": "@ohos/brewsearch",
  "version": "1.0.0",
  "description": "Homebrew 应用市场 · 搜索（侧边栏搜索框 + 结果页）",
  "main": "Index.ets",
  "author": "",
  "license": "Apache-2.0",
  "dependencies": {
    "@ohos/common": "file:../../common",
    "@ohos/commonbusiness": "file:../commonbusiness",
    "@ohos/brewcommon": "file:../brewcommon"
  }
}
```

`features/brewsearch/.gitignore`（**首行必须是 `/oh_modules`**，否则依赖符号链接会被提交）：

```
/node_modules
/oh_modules
/.preview
/build
/.cxx
/.test
```

`features/brewsearch/consumer-rules.txt`：空文件（0 字节，与 brewdiscover 一致）。

`features/brewsearch/obfuscation-rules.txt`（与 brewdiscover 逐字一致）：

```
# Define project specific obfuscation rules here.
# You can include the obfuscation configuration files in the current module's build-profile.json5.
#
# For more details, see
#   https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V5/source-obfuscation-V5

# Obfuscation options:
# -disable-obfuscation: disable all obfuscations
# -enable-property-obfuscation: obfuscate the property names
# -enable-toplevel-obfuscation: obfuscate the names in the global scope
# -compact: remove unnecessary blank spaces and all line feeds
# -remove-log: remove all console.* statements
# -print-namecache: print the name cache that contains the mapping from the old names to new names
# -apply-namecache: reuse the given cache file

# Keep options:
# -keep-property-name: specifies property names that you want to keep
# -keep-global-name: specifies names that you want to keep in the global scope
-enable-property-obfuscation
-enable-toplevel-obfuscation
-enable-filename-obfuscation
-enable-export-obfuscation
```

`features/brewsearch/src/main/module.json5`：

```json5
{
  "module": {
    "name": "brewsearch",
    "type": "har",
    "routerMap": "$profile:router_map",
    "deviceTypes": [
      "default",
      "tablet",
      "2in1"
    ]
  }
}
```

`features/brewsearch/src/main/resources/base/profile/router_map.json`：

```json
{
  "routerMap": [
    {
      "name": "BrewSearchResultView",
      "pageSourceFile": "src/main/ets/view/BrewSearchResultView.ets",
      "buildFunction": "BrewSearchResultBuilder"
    }
  ]
}
```

`features/brewsearch/src/main/resources/base/element/float.json`：

```json
{
  "float": [
    {
      "name": "brew_search_box_height",
      "value": "40.0vp"
    },
    {
      "name": "brew_search_panel_width",
      "value": "400.0vp"
    },
    {
      "name": "brew_search_row_height",
      "value": "64.0vp"
    },
    {
      "name": "brew_search_suggestion_height",
      "value": "48.0vp"
    }
  ]
}
```

`features/brewsearch/src/main/resources/zh_CN/element/float.json` 与 `en_US/.../float.json`：本模块**不需要**（文案在 brewcommon 的 string.json 里，见 Step 6；float 不分语言）。

- [ ] **Step 2: 注册模块与依赖**

`build-profile.json5` 的 `modules[]` 末尾（`abilitycommon` 项之后）加：

```json5
    {
      "name": "brewsearch",
      "srcPath": "./features/brewsearch"
    }
```

`products/pc/oh-package.json5` 的 `dependencies` 加一行（`@ohos/brewcommon` 之后）：

```json5
    "@ohos/brewsearch": "file:../../features/brewsearch"
```

- [ ] **Step 3: 加路由常量与三个 StorageKey**

`common/src/main/ets/model/PageEnum.ets`，在 `BREW_DISCOVER_BOARD_VIEW = 'BrewDiscoverBoardView',` 之后加：

```typescript
  /** 搜索结果页（侧边栏搜索框触达，不属于任何页签） */
  BREW_SEARCH_RESULT_VIEW = 'BrewSearchResultView',
```

`common/src/main/ets/constant/CommonEnums.ets`，在 `BREW_CASK_PAGE_CONTEXT = 'hmos_world_BrewCaskPageContext',` 之后加：

```typescript
  /** 搜索页自己的页面栈。**不能与任何页签共用** —— 共用会让两个栈串起来（见 handover §3.3） */
  BREW_SEARCH_PAGE_CONTEXT = 'hmos_world_BrewSearchPageContext',
  /**
   * 是否处于搜索态。写它的三处：搜索框（输入/提交 → true）、切页签（→ false）、
   * 结果页栈底按返回（→ false）。读它的是 PcMainPage（决定内容区渲染谁）。
   * 走 AppStorage 而不是回调：CustomSideBar 是 HdsSideBar 的 builder 参数、
   * 结果页是 NavDestination，**函数穿不过路由参数**（handover §3.3）。
   */
  BREW_SEARCH_ACTIVE = 'hmos_world_BrewSearchActive',
  /** 当前关键字。**唯一写者是搜索框**；结果页 @Watch 它 → popToIndex(0) + 重算 */
  BREW_SEARCH_KEYWORD = 'hmos_world_BrewSearchKeyword',
```

- [ ] **Step 4: 最小可编译的结果页与壳**

`features/brewsearch/src/main/ets/view/BrewSearchResultView.ets`（本任务只要它能编译、能被路由到；Task 5 会整体替换内容）：

```typescript
import { LengthMetrics } from '@kit.ArkUI';
import { HdsNavDestination } from '@kit.UIDesignKit';
import type { TitleBarStyleOptions } from '@kit.UIDesignKit';
import { CommonConstants, GlobalInfoModel, StorageKey } from '@ohos/common';
import { brewTitleBarStyle, brewTitleBarTotalHeight } from '@ohos/brewcommon';

/**
 * 搜索结果页（栈底）。本任务先落一个可编译、可路由的最小版本，
 * 真实内容（chips / 列表 / 空态 / 降级条 / 返回键处理）在 Task 5 补齐。
 */
@Component({ freezeWhenInactive: true })
export struct BrewSearchResultView {
  @StorageProp(StorageKey.GLOBAL_INFO) globalInfoModel: GlobalInfoModel =
    AppStorage.get(StorageKey.GLOBAL_INFO) ?? new GlobalInfoModel();
  @State titleBarStyle: TitleBarStyleOptions = brewTitleBarStyle('search');

  build() {
    HdsNavDestination() {
      Column() {
        Text($r('app.string.brew_search_title'))
          .fontSize($r('sys.float.Title_L'))
          .fontColor($r('sys.color.font_primary'))
      }
      .width(CommonConstants.FULL_PERCENT)
      .margin({ top: brewTitleBarTotalHeight(this.globalInfoModel.statusBarHeight) })
    }
    .hideBackButton(false)
    .backgroundColor($r('sys.color.background_secondary'))
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .titleBar({
      padding: {
        start: LengthMetrics.vp(CommonConstants.SPACE_16),
        end: LengthMetrics.vp(CommonConstants.SPACE_16),
      },
      avoidLayoutSafeArea: true,
      style: this.titleBarStyle,
      content: {
        title: { mainTitle: $r('app.string.brew_search_title') },
      },
    })
  }
}

@Builder
export function BrewSearchResultBuilder() {
  BrewSearchResultView()
}
```

`features/brewsearch/src/main/ets/view/BrewSearchHomeView.ets`：

```typescript
import { HdsNavigation, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { CommonConstants, PageContext, PageEnum, StorageKey } from '@ohos/common';
import { BrewSearchResultView } from './BrewSearchResultView';

/** 结果页的路由参数（只传简单标识，与项目既有二级页一致） */
export interface BrewSearchParams {
  keyword: string;
}

/**
 * 搜索态在内容区的壳，与 `BrewDiscoverHomeView` 同构：自己持有一个 PageContext 的
 * NavPathStack，进入时把结果页压栈作为栈底。
 *
 * `StorageKey` 必须是**本模块自己的** `BREW_SEARCH_PAGE_CONTEXT`：共用会让搜索的
 * 页面栈与某个页签串起来（从一个页签的二级页会影响到另一个）。
 */
@Component({ freezeWhenInactive: true })
export struct BrewSearchHomeView {
  @StorageLink(StorageKey.BREW_SEARCH_PAGE_CONTEXT) searchPageContext: PageContext =
    AppStorage.get<PageContext>(StorageKey.BREW_SEARCH_PAGE_CONTEXT) ?? new PageContext();
  @StorageProp(StorageKey.BREW_SEARCH_KEYWORD) keyword: string = '';

  aboutToAppear(): void {
    this.searchPageContext.openPage({
      routerName: PageEnum.BREW_SEARCH_RESULT_VIEW,
      param: { keyword: this.keyword } as BrewSearchParams,
    }, false);
  }

  build() {
    HdsNavigation(this.searchPageContext.navPathStack) {
      BrewSearchResultView()
    }
    .mode(NavigationMode.Stack)
    .hideBackButton(true)
    .hideTitleBar(true)
    .titleMode(HdsNavigationTitleMode.MINI)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .width(CommonConstants.FULL_PERCENT)
    .height(CommonConstants.FULL_PERCENT)
  }
}
```

> 更正记录：本节原先把 import 拆成两块、并写成「补 import（放文件末尾）」，那是笔误 ——
> 上表已合并为**一个完整文件**，所有 import 在顶部。
`features/brewsearch/Index.ets`：

```typescript
export { BrewSearchHomeView } from './src/main/ets/view/BrewSearchHomeView';
export type { BrewSearchParams } from './src/main/ets/view/BrewSearchHomeView';

// 结果页通过 module.json5 的 routerMap 进入编译图，不需要在这里再导出一次
// （与 brewdiscover 的 BrewDiscoverBoardView 同理）。
```

- [ ] **Step 5: 编译 + 三项自检**

Run: `devecocli build 2>&1 | tail -5`
Expected: `BUILD SUCCESSFUL`

Run: `strings products/pc/build/default/intermediates/loader_out/default/ets/modules.abc | grep -c BrewSearchResultView`
Expected: 正数（不加锚点）

Run: `python3 -c "import json;print(len(json.load(open('products/pc/build/default/intermediates/router_map/default/router_map.json'))['routerMap']))"`
Expected: `25`（本计划开始时是 24）

- [ ] **Step 6: 加文案（三份）+ 删死文案**

`features/brewcommon/src/main/resources/base/element/string.json`，把这一整段（`:227-234`）：

```json
    {
      "name": "brew_search_placeholder",
      "value": "Search packages"
    },
    {
      "name": "brew_search_coming_soon",
      "value": "Search is not available yet"
    },
```

替换成：

```json
    {
      "name": "brew_search_placeholder",
      "value": "Search packages"
    },
    {
      "name": "brew_search_action",
      "value": "Search"
    },
    {
      "name": "brew_search_title",
      "value": "Search"
    },
    {
      "name": "brew_search_history",
      "value": "Search history"
    },
    {
      "name": "brew_search_discovery",
      "value": "Discover"
    },
    {
      "name": "brew_search_empty_history",
      "value": "No search history"
    },
    {
      "name": "brew_search_no_result",
      "value": "No packages found"
    },
    {
      "name": "brew_search_result_count",
      "value": "%d results"
    },
    {
      "name": "brew_search_index_pending",
      "value": "Local index is not ready — matching by package name only"
    },
    {
      "name": "brew_search_filter_all",
      "value": "All"
    },
    {
      "name": "brew_search_filter_formula",
      "value": "Formulae"
    },
    {
      "name": "brew_search_filter_cask",
      "value": "Casks"
    },
```

`features/brewcommon/src/main/resources/zh_CN/element/string.json` 的同一段（`:227-234`）替换成同样的键，值改成：

```json
    {
      "name": "brew_search_placeholder",
      "value": "搜索内容"
    },
```

其后 11 条的值依次为：`搜索`（action）/ `搜索`（title）/ `搜索历史` / `搜索发现` / `暂无搜索历史` / `没有找到相关包` / `共 %d 个结果` / `本地索引未就绪，当前仅按包名匹配` / `全部` / `Formulae` / `Casks`。

`features/brewcommon/src/main/resources/en_US/element/string.json` 的同一段（`:223-230`）替换成与 `base` **完全相同**的内容。

> `brew_search_placeholder` 的 zh 值由「搜索软件包」改成「搜索内容」是照截图；`brew_search_coming_soon` 三条一并删除 —— 搜索落地后它才成为真死代码（handover §8.3 把它归为「预备未用」，因为当时还有对应待办）。

- [ ] **Step 7: 确认 JSON 没写坏 + 再编译一次**

Run: `python3 -c "import json;[json.load(open(f'features/brewcommon/src/main/resources/{d}/element/string.json')) for d in ['base','zh_CN','en_US']];print('3 份 string.json 合法')"`
Expected: `3 份 string.json 合法`

Run: `grep -c "brew_search_coming_soon" features/brewcommon/src/main/resources/*/element/string.json`
Expected: 三行都是 `0`

Run: `devecocli build 2>&1 | tail -5`
Expected: `BUILD SUCCESSFUL`

- [ ] **Step 8: 提交**

```bash
git add features/brewsearch build-profile.json5 products/pc/oh-package.json5 \
  common/src/main/ets/model/PageEnum.ets common/src/main/ets/constant/CommonEnums.ets \
  features/brewcommon/src/main/resources
git commit -m "feat(brew): 新建 brewsearch 模块（骨架 + 最小结果页 + 路由 + 文案）

- 骨架逐字照抄 brewdiscover（HAR + routerMap + 模块级 .gitignore 首行 /oh_modules，
  漏了会把依赖符号链接提交进来，brewdiscover 踩过）。
- 三个新 StorageKey 走 AppStorage：CustomSideBar 是 HdsSideBar 的 builder 参数、
  结果页是 NavDestination，函数穿不过路由参数，这是两层之间唯一现成的通道。
- 文案放 brewcommon 的 string.json 而不是新模块自己的：brewdiscover 也是这么做的
  （跨 HAR 的 app.string 能解析），搜索文案与既有 brew_* 同属一个命名空间。
- 删 brew_search_coming_soon：搜索落地后它才成为真死代码。
- brew_search_placeholder 的 zh 值改「搜索内容」是照截图。

实测：build BUILD SUCCESSFUL；strings 命中 BrewSearchResultView；
router_map.json 24 → 25；三份 string.json 合法且 coming_soon 计数为 0。"
```

---

## Task 5: 结果页完整实现（状态 / 数据源 / 三态 / 降级条 / 返回键）

**Files:**
- Create: `features/brewsearch/src/main/ets/constant/BrewSearchConstants.ets`
- Create: `features/brewsearch/src/main/ets/viewmodel/BrewSearchState.ets`
- Create: `features/brewsearch/src/main/ets/viewmodel/BrewSearchVM.ets`
- Create: `features/brewsearch/src/main/ets/model/BrewSearchRowSource.ets`
- Create: `features/brewsearch/src/main/ets/component/BrewSearchSuggestions.ets`
- Modify: `features/brewsearch/src/main/ets/view/BrewSearchResultView.ets`（整体替换）

**Interfaces:**
- Consumes: Task 3 的 `BrewSearchModel.search` / `BrewSearchResult`；Task 2 的 `BrewPackageRow.hideRank`；Task 4 的 `StorageKey.BREW_SEARCH_KEYWORD` / `BREW_SEARCH_ACTIVE`
- Produces:
  - `class BrewSearchState { keyword: string; filterIndex: number; total: number; indexReady: boolean; rowsFromIndexOnly: boolean; result?: BrewSearchResult }`
  - `class BrewSearchRow { kind: BrewKind; item: BrewPackageItem }`、`BrewSearchRowSource implements IDataSource`
  - `BrewSearchVM.getInstance()` / `.chips()` / `.history()` / `.clearHistory()` / `.discoveries()` / `.rotateDiscovery()` / `.search(keyword, state)` / `.rowsOf(state)`
  - `BrewSearchSuggestions`（`@Prop large: boolean`、回调 `pickWord`）

- [ ] **Step 1: 写 `BrewSearchConstants.ets`**

```typescript
/**
 * 搜索的 UI 侧常量：死写词组、防抖、chips 标识。
 *
 * 为什么历史与发现是死写数组（而不是从目录/榜单取）：需求方口径「先写死，不做数据源」。
 * 直接后果必须写清楚 —— 下面这些词在 Homebrew 目录里**一个都不存在**，
 * 点下去必然空结果；那是本轮「版式还原」的预期，不是 bug
 * （见 docs/superpowers/specs/2026-09-21-brew-search-design.md §8）。
 * 数据层的截断上限不在这里，在 brewcommon 的 BREW_SEARCH_LIMIT（放这会让模块成环）。
 */

/** 搜索历史（照截图原词）。执行搜索**不会**往里加词：历史在本轮是死写词组 */
export const BREW_SEARCH_HISTORY: string[] = ['qoder', '元宝', 'qq邮箱', '哔哩哔哩'];

/** 发现池：池内轮换，一次展示 BREW_SEARCH_DISCOVERY_COUNT 条 */
export const BREW_SEARCH_DISCOVERY_POOL: string[] = [
  'WPS Office', '爱奇艺', '微信', '小红书',
  'QQ', '钉钉', '腾讯会议', '高德地图',
];

export const BREW_SEARCH_DISCOVERY_COUNT: number = 4;

/**
 * 输入防抖。**不用 common 的 `DebounceUtil`**：它是「全局单例时间戳 + leading」的节流，
 * 语义（不是 trailing）与作用域（会与别处共用同一个 lastClickTime）都不对。
 */
export const BREW_SEARCH_DEBOUNCE_MS: number = 300;

/**
 * chips 的 id（`BrewChipItem` 的主键，只要求唯一）与过滤值（喂给引擎的 kind）。
 * 「全部」这项的 id 是 `'all'`，而它的**过滤值是空串**（引擎约定空串 = 不过滤）——
 * 两者不是一回事，所以分开命名。
 */
export const BREW_SEARCH_CHIP_ALL: string = 'all';
export const BREW_SEARCH_CHIP_FORMULA: string = 'formula';
export const BREW_SEARCH_CHIP_CASK: string = 'cask';

/** 历史 chips 换行时的横纵间距 */
export const BREW_SEARCH_CHIP_SPACE: number = 8;
```

- [ ] **Step 2: 写 `BrewSearchState.ets` 与 `BrewSearchRowSource.ets`**

`features/brewsearch/src/main/ets/viewmodel/BrewSearchState.ets`：

```typescript
import type { BrewSearchResult } from '@ohos/brewcommon';

/**
 * 搜索页的**每页实例**状态。
 *
 * 为什么不能放单例 VM：搜索态关掉再进来是**新的页面实例**，共享一份状态会让新页面
 * 先渲染出上一次的结果（详情页正是这么踩的：handover §10.4.1）。
 * 所以 `result` 也在这里，而不是在 `BrewSearchVM` 里。
 */
export class BrewSearchState {
  /** 原始关键字（含大小写与空白；归一化交给引擎） */
  public keyword: string = '';
  /** chips 选中项，对应 `BrewSearchVM.chips()` 的下标 */
  public filterIndex: number = 0;
  /** 命中总数（截断前），用于「共 N 个结果」 */
  public total: number = 0;
  /** 元数据索引是否就绪（false → 顶部提示条） */
  public indexReady: boolean = true;
  /** 行是仅凭 desc 索引造出来的（目录缺失） */
  public rowsFromIndexOnly: boolean = false;
  /** 本页最近一次搜索结果。与 hits 等长同序的 items 也在这里面 */
  public result?: BrewSearchResult = undefined;
}
```

`features/brewsearch/src/main/ets/model/BrewSearchRowSource.ets`：

```typescript
import { BrewKind, BrewPackageItem } from '@ohos/brewcommon';

/**
 * 结果行。`BrewPackageRow` 需要 `kind`（它透传给 `BrewPackageIcon` 决定符号颜色），
 * 而 `BrewPackageItem` 里没有这个字段 —— 所以这里包一层。
 */
export class BrewSearchRow {
  public kind: BrewKind = BrewKind.FORMULA;
  public item: BrewPackageItem = new BrewPackageItem();

  constructor(kind: BrewKind, item: BrewPackageItem) {
    this.kind = kind;
    this.item = item;
  }
}

/**
 * 结果列表的 `LazyForEach` 数据源。形状与 `BrewPackageItemSource` 一致
 * （同为 `IDataSource`），差别只在元素类型多带了 `kind`。
 *
 * 换数据必须走 `setDataArray`：它替换数组**并通知**已注册的监听者重载 ——
 * 直接改私有数组不会触发 `List` 刷新。
 */
export class BrewSearchRowSource implements IDataSource {
  private rows: BrewSearchRow[] = [];
  private listeners: DataChangeListener[] = [];

  public setDataArray(rows: BrewSearchRow[]): void {
    this.rows = rows;
    this.listeners.forEach((listener: DataChangeListener) => {
      listener.onDataReloaded();
    });
  }

  totalCount(): number {
    return this.rows.length;
  }

  getData(index: number): BrewSearchRow {
    if (index >= 0 && index < this.rows.length) {
      return this.rows[index];
    }
    return new BrewSearchRow(BrewKind.FORMULA, new BrewPackageItem());
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos: number = this.listeners.indexOf(listener);
    if (pos >= 0) {
      this.listeners.splice(pos, 1);
    }
  }
}
```

- [ ] **Step 3: 写 `BrewSearchVM.ets`**

```typescript
import { BrewChipItem, BrewFormat, BrewKind, BrewSearchEngine, BrewSearchModel } from '@ohos/brewcommon';
import type { BrewSearchHit, BrewSearchResult } from '@ohos/brewcommon';
import { Logger } from '@ohos/common';
import { BrewSearchRow } from '../model/BrewSearchRowSource';
import { BrewSearchState } from './BrewSearchState';
import {
  BREW_SEARCH_CHIP_ALL,
  BREW_SEARCH_CHIP_CASK,
  BREW_SEARCH_CHIP_FORMULA,
  BREW_SEARCH_DISCOVERY_COUNT,
  BREW_SEARCH_DISCOVERY_POOL,
  BREW_SEARCH_HISTORY,
} from '../constant/BrewSearchConstants';

const TAG: string = '[BrewSearch]';

/**
 * 搜索的门面。持有**会话级**状态（历史 / 发现的轮换位置），
 * **每页**状态（关键字、chips、结果）由调用方通过 `BrewSearchState` 传进来。
 *
 * 这样切分的理由：搜索框（侧边栏，始终存活）与结果页（可被销毁重建）都要读历史与发现，
 * 只有共享一份才不会出现「在浮层里清空历史、结果页还显示旧的」；而结果本身必须每页独立。
 */
export class BrewSearchVM {
  private static instance: BrewSearchVM | undefined = undefined;
  private model: BrewSearchModel = BrewSearchModel.getInstance();
  private historyWords: string[] = BREW_SEARCH_HISTORY.slice();
  private discoveryOffset: number = 0;
  private chipItems: BrewChipItem[] = [
    new BrewChipItem(BREW_SEARCH_CHIP_ALL, $r('app.string.brew_search_filter_all')),
    new BrewChipItem(BREW_SEARCH_CHIP_FORMULA, $r('app.string.brew_search_filter_formula')),
    new BrewChipItem(BREW_SEARCH_CHIP_CASK, $r('app.string.brew_search_filter_cask')),
  ];

  public static getInstance(): BrewSearchVM {
    if (BrewSearchVM.instance === undefined) {
      BrewSearchVM.instance = new BrewSearchVM();
    }
    return BrewSearchVM.instance;
  }

  public chips(): BrewChipItem[] {
    return this.chipItems;
  }

  /** 历史（副本语义由调用方自己处理：拿到后存进自己的 @State 才会重渲染） */
  public history(): string[] {
    return this.historyWords;
  }

  public clearHistory(): void {
    this.historyWords = [];
    Logger.info(TAG, 'history cleared (session only, restored on restart)');
  }

  public discoveries(): string[] {
    const out: string[] = [];
    for (let i: number = 0; i < BREW_SEARCH_DISCOVERY_COUNT; i++) {
      out.push(BREW_SEARCH_DISCOVERY_POOL[(this.discoveryOffset + i) % BREW_SEARCH_DISCOVERY_POOL.length]);
    }
    return out;
  }

  /** 「换一批」：池内轮换。**有真实行为**，不是假按钮 */
  public rotateDiscovery(): void {
    this.discoveryOffset =
      (this.discoveryOffset + BREW_SEARCH_DISCOVERY_COUNT) % BREW_SEARCH_DISCOVERY_POOL.length;
  }

  /** 当前 chips 对应的 kind（空串 = 不过滤），与 `BrewSearchEngine.filterByKind` 的语义一致 */
  public filterKindOf(state: BrewSearchState): string {
    if (state.filterIndex === 1) {
      return BREW_SEARCH_CHIP_FORMULA;
    }
    if (state.filterIndex === 2) {
      return BREW_SEARCH_CHIP_CASK;
    }
    return '';
  }

  /**
   * 跑一次搜索并把结果写进**这一页**的 state。
   *
   * 返回 `undefined` = 这次调用已经过期（关键字在等待期间又被改过），调用方**不要覆盖列表**。
   * 引擎是同步的，所以实际不会发生；这条判定是给「将来真异步化」（例如详情 hydrate）留的护栏。
   */
  public search(keyword: string, state: BrewSearchState): Promise<BrewSearchRow[] | undefined> {
    return this.model.search(keyword).then((result: BrewSearchResult) => {
      // 用引擎的 normalize 归一化后对比（不自己写一份 trim+toLowerCase，否则口径会漂）
      if (result.keyword !== BrewSearchEngine.normalize(keyword)) {
        return undefined;
      }
      state.result = result;
      state.total = result.total;
      state.indexReady = result.indexReady;
      state.rowsFromIndexOnly = result.rowsFromIndexOnly;
      return this.rowsOf(state);
    });
  }

  /** 按当前 chips 从**已算好的**结果里取行（chips 切换不重跑引擎） */
  public rowsOf(state: BrewSearchState): BrewSearchRow[] {
    const result: BrewSearchResult | undefined = state.result;
    if (result === undefined) {
      return [];
    }
    const kind: string = this.filterKindOf(state);
    const rows: BrewSearchRow[] = [];
    result.hits.forEach((hit: BrewSearchHit, index: number) => {
      if (kind.length === 0 || hit.kind === kind) {
        rows.push(new BrewSearchRow(BrewFormat.brewKindOf(hit.kind), result.items[index]));
      }
    });
    return rows;
  }
}
```

> 说明：`BrewFormat.brewKindOf(kind: string): BrewKind` 是 brewcommon 既有工具（`:51`），
> 注释里明确写着「在这里收一处转换，不要在每个调用点各写一遍三元表达式」。

- [ ] **Step 4: 写 `BrewSearchSuggestions.ets`（浮层与结果页空态共用）**

```typescript
import { CommonConstants } from '@ohos/common';
import { BrewSearchVM } from '../viewmodel/BrewSearchVM';
import { BREW_SEARCH_CHIP_SPACE } from '../constant/BrewSearchConstants';

/**
 * 「搜索历史 + 搜索发现」。**浮层与结果页空关键字态共用这一份实现**：
 * 两处内容本来就一模一样，做两份一定会漂移（项目为这类事故付过代价，handover §3.2）。
 * `large` 只控制字号与行高：浮层里紧凑，结果页里大字。
 *
 * 两个标题行**各写各的 @Builder，不参数化**：标题右侧的动作图标与回调都不同
 * （历史是清空+折叠，发现是换一批）。ArkUI 的 @Builder 传数组/闭包参数是能编译的，
 * 但本项目已经因为「组件/回调的传递方式」踩过坑（handover §9.8），
 * 两条各三行的标题行不值得为省那几行引入那个风险。
 */
@Component
export struct BrewSearchSuggestions {
  @Prop @Require large: boolean;
  /** 点历史 chip 或发现项：把词交给调用方（浮层写进搜索框并搜索；结果页只写关键字） */
  pickWord: (word: string) => void = (_word: string) => {
  };
  // 历史与发现在单例 VM 里（会话级）：浮层与结果页必须看到同一份，
  // 否则会出现「在浮层里清空历史、结果页还显示旧的」
  @State history: string[] = [];
  @State discoveries: string[] = [];
  @State historyCollapsed: boolean = false;
  private viewModel: BrewSearchVM = BrewSearchVM.getInstance();

  aboutToAppear(): void {
    this.syncFromViewModel();
  }

  /** 改动 VM 之后必须把值取回自己的 @State，否则不重渲染（VM 是普通单例，不是 @State） */
  private syncFromViewModel(): void {
    this.history = this.viewModel.history();
    this.discoveries = this.viewModel.discoveries();
  }

  private titleSize(): Resource {
    return this.large ? $r('sys.float.Title_S') : $r('sys.float.Body_L');
  }

  private rowHeight(): Resource {
    return $r('app.float.brew_search_suggestion_height');
  }

  /** 标题行：左边标题、右边动作图标。标题行本身不接收任何参数（见结构体注释） */
  @Builder
  HistoryHeaderBuilder() {
    Row() {
      Text($r('app.string.brew_search_history'))
        .fontSize(this.titleSize())
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
      Blank()
      SymbolGlyph($r('sys.symbol.trash'))
        .fontSize($r('sys.float.Title_M'))
        .fontColor([$r('sys.color.icon_secondary')])
        .margin({ left: $r('sys.float.padding_level4') })
        .onClick(() => {
          this.viewModel.clearHistory();
          this.syncFromViewModel();
        })
      SymbolGlyph(this.historyCollapsed ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_up'))
        .fontSize($r('sys.float.Title_M'))
        .fontColor([$r('sys.color.icon_secondary')])
        .margin({ left: $r('sys.float.padding_level4') })
        .onClick(() => {
          this.historyCollapsed = !this.historyCollapsed;
        })
    }
    .width(CommonConstants.FULL_PERCENT)
    .height(this.rowHeight())
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  DiscoveryHeaderBuilder() {
    Row() {
      Text($r('app.string.brew_search_discovery'))
        .fontSize(this.titleSize())
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
      Blank()
      SymbolGlyph($r('sys.symbol.arrow_clockwise'))
        .fontSize($r('sys.float.Title_M'))
        .fontColor([$r('sys.color.icon_secondary')])
        .margin({ left: $r('sys.float.padding_level4') })
        .onClick(() => {
          // 「换一批」：池内轮换，有真实行为（不是假按钮）
          this.viewModel.rotateDiscovery();
          this.syncFromViewModel();
        })
    }
    .width(CommonConstants.FULL_PERCENT)
    .height(this.rowHeight())
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  HistoryChipsBuilder() {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(this.history, (word: string) => {
        Text(word)
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('sys.color.font_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          .borderRadius($r('sys.float.corner_radius_level4'))
          .padding({
            left: $r('sys.float.padding_level8'),
            right: $r('sys.float.padding_level8'),
            top: $r('sys.float.padding_level4'),
            bottom: $r('sys.float.padding_level4'),
          })
          .margin({ right: BREW_SEARCH_CHIP_SPACE, bottom: BREW_SEARCH_CHIP_SPACE })
          .onClick(() => {
            this.pickWord(word);
          })
      }, (word: string) => word)
    }
    .width(CommonConstants.FULL_PERCENT)
  }

  @Builder
  DiscoveryItemBuilder(word: string) {
    Row() {
      SymbolGlyph($r('sys.symbol.magnifyingglass'))
        .fontSize($r('sys.float.Body_M'))
        .fontColor([$r('sys.color.icon_secondary')])
        .margin({ right: $r('sys.float.padding_level6') })
      Text(word)
        .fontSize($r('sys.float.Body_M'))
        .fontColor($r('sys.color.font_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Blank()
    }
    .width('50%')
    .height(this.rowHeight())
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.pickWord(word);
    })
  }

  build() {
    Column() {
      this.HistoryHeaderBuilder();
      if (this.historyCollapsed || this.history.length === 0) {
        Text($r('app.string.brew_search_empty_history'))
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('sys.color.font_tertiary'))
          .width(CommonConstants.FULL_PERCENT)
          .padding({ bottom: $r('sys.float.padding_level4') })
      } else {
        this.HistoryChipsBuilder();
      }
      this.DiscoveryHeaderBuilder();
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.discoveries, (word: string) => {
          this.DiscoveryItemBuilder(word);
        }, (word: string) => word)
      }
      .width(CommonConstants.FULL_PERCENT)
    }
    .width(CommonConstants.FULL_PERCENT)
    .alignItems(HorizontalAlign.Start)
  }
}
```

> 注意 `backgroundColor` 用的是 `sys.color.comp_background_tertiary`（不是 `background_tertiary`）：
> **`sys.color.background_tertiary` 并不存在** —— 能用的系统颜色就是项目里已经出现过的那些。

- [ ] **Step 5: 整体替换 `BrewSearchResultView.ets`**

```typescript
import { ConfigurationConstant } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { LengthMetrics } from '@kit.ArkUI';
import { HdsNavDestination } from '@kit.UIDesignKit';
import type { TitleBarStyleOptions } from '@kit.UIDesignKit';
import {
  BreakpointType,
  CommonConstants,
  GlobalInfoModel,
  Logger,
  PageEnum,
  StorageKey,
  StatusBarColorType,
} from '@ohos/common';
import {
  BREW_CHIP_BAR_HEIGHT,
  BrewChipBar,
  BrewPackageRow,
  brewTitleBarStyle,
  brewTitleBarTotalHeight,
} from '@ohos/brewcommon';
// BrewDetailParams 在 brewcommon 的 Index.ets 里是 `export type`，所以用 import type；
// BrewPackageItem 是值导出（要 new 出来做兜底），必须放上面的值 import 里。
import type { BrewDetailParams, BrewPackageItem } from '@ohos/brewcommon';
import { BrewSearchRow, BrewSearchRowSource } from '../model/BrewSearchRowSource';
import { BrewSearchState } from '../viewmodel/BrewSearchState';
import { BrewSearchVM } from '../viewmodel/BrewSearchVM';
import { BrewSearchSuggestions } from '../component/BrewSearchSuggestions';

const TAG: string = '[BrewSearch]';

/**
 * 搜索结果页（搜索栈的栈底）。
 *
 * 结构对齐 `MinePackagesView`：模糊标题栏（chips 挂在 `bottomBuilder`）+ 内容区靠
 * `brewTitleBarTotalHeight()` 手动让位 + `LazyForEach` 列表 + 返回键防重入。
 *
 * 两个本页特有的点：
 *   1. **每页实例状态**：`state` 在字段初始化里 `new`（不从单例 VM 取）。
 *      搜索态关掉再进来是新的页面实例，共享状态会让新页面先渲染上一次的结果。
 *   2. **栈底的返回键必须自己吞掉**：见 `onBackPressed` 里的注释。
 */
@Component({ freezeWhenInactive: true })
export struct BrewSearchResultView {
  @StorageProp(StorageKey.GLOBAL_INFO) globalInfoModel: GlobalInfoModel =
    AppStorage.get(StorageKey.GLOBAL_INFO) ?? new GlobalInfoModel();
  @StorageProp(StorageKey.COLOR_MODE) systemColorMode: ConfigurationConstant.ColorMode =
    AppStorage.get(StorageKey.COLOR_MODE) ?? ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
  /** 侧边栏搜索框是**唯一写者**：它一变，这一页就重算 */
  @StorageProp(StorageKey.BREW_SEARCH_KEYWORD) @Watch('onKeywordChange') keyword: string = '';
  @State titleBarStyle: TitleBarStyleOptions = brewTitleBarStyle('search');
  @State state: BrewSearchState = new BrewSearchState();
  @State rowSource: BrewSearchRowSource = new BrewSearchRowSource();
  /** 返回键防重入。**必须是本组件的 @State**（放共享 state 会置位后不复位，handover §10.4.1） */
  @State backPressed: boolean = false;
  private viewModel: BrewSearchVM = BrewSearchVM.getInstance();
  /** 页面栈。不是 @State —— 只用于出栈/回栈底，不参与渲染 */
  private pathStack?: NavPathStack;

  handleOnReady(ctx: NavDestinationContext): void {
    this.pathStack = ctx?.pathStack;
    this.apply(this.keyword);
  }

  onKeywordChange(): void {
    this.apply(this.keyword);
  }

  /**
   * 用新关键字重算。**新关键字不 push 新页面**：先把栈回到栈底
   * （可能正叠着详情页）再换数据 —— 否则连输会堆一叠结果页。
   */
  private apply(keyword: string): void {
    if (this.pathStack !== undefined && this.pathStack.size() > 1) {
      this.pathStack.popToIndex(0);
    }
    this.state.keyword = keyword;
    this.viewModel.search(keyword, this.state)
      .then((rows: BrewSearchRow[] | undefined) => {
        if (rows !== undefined) {
          this.rowSource.setDataArray(rows);
        }
      })
      .catch((error: BusinessError) => {
        Logger.error(TAG, `search failed, code=${error?.code}, msg=${error?.message}`);
      });
  }

  private contentInset(): Length {
    return new BreakpointType<Length>({
      sm: $r('sys.float.padding_level8'),
      md: $r('sys.float.padding_level12'),
      lg: $r('sys.float.padding_level16'),
    }).getValue(this.globalInfoModel.widthBreakpoint);
  }

  /** 空关键字（含纯空格）= 显示历史与发现；否则看命中数 */
  private showingSuggestions(): boolean {
    return this.state.keyword.trim().length === 0;
  }

  private openDetail(row: BrewSearchRow): void {
    const item: BrewPackageItem = row.item;
    this.pathStack?.pushPath({
      name: PageEnum.BREW_DETAIL_VIEW,
      param: {
        kind: row.kind,
        title: item.subTitle,
        id: item.id,
        token: item.token,
        categoryKey: item.categoryKey,
      } as BrewDetailParams,
    }, true);
  }

  @Builder
  ChipBarBuilder() {
    BrewChipBar({
      chips: this.viewModel.chips(),
      currentIndex: this.state.filterIndex,
      handleChipClick: (index: number) => {
        this.state.filterIndex = index;
        this.rowSource.setDataArray(this.viewModel.rowsOf(this.state));
      },
    })
  }

  /** 索引未就绪的提示条（不是失败态：仍按包名搜出了结果） */
  @Builder
  IndexPendingBuilder() {
    Text($r('app.string.brew_search_index_pending'))
      .fontSize($r('sys.float.Body_S'))
      .fontColor($r('sys.color.font_tertiary'))
      .width(CommonConstants.FULL_PERCENT)
      .padding({ bottom: $r('sys.float.padding_level4') })
  }

  @Builder
  ResultListBuilder() {
    List() {
      LazyForEach(this.rowSource, (row: BrewSearchRow) => {
        ListItem() {
          BrewPackageRow({
            packageItem: row.item,
            kind: row.kind,
            // 搜索结果没有「分类内名次」语境；不隐藏的话每行都会是 "0 / 0"
            hideRank: true,
            itemHeight: $r('app.float.brew_search_row_height'),
            handleItemClick: () => {
              this.openDetail(row);
            },
          })
        }
      }, (row: BrewSearchRow) => `${row.kind}_${row.item.token}`)
    }
    .width(CommonConstants.FULL_PERCENT)
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .backgroundColor($r('sys.color.comp_background_primary'))
    .borderRadius($r('sys.float.corner_radius_level8'))
    .clip(true)
  }

  @Builder
  ContentBuilder() {
    Column() {
      if (!this.state.indexReady && !this.showingSuggestions()) {
        this.IndexPendingBuilder();
      }
      if (this.showingSuggestions()) {
        BrewSearchSuggestions({
          large: true,
          pickWord: (word: string) => {
            // 侧边栏搜索框是唯一写者：这里改了它，@Watch 会把这一页重算一遍
            AppStorage.setOrCreate(StorageKey.BREW_SEARCH_KEYWORD, word);
          },
        })
      } else if (this.state.total === 0) {
        Text($r('app.string.brew_search_no_result'))
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('sys.color.font_tertiary'))
          .width(CommonConstants.FULL_PERCENT)
          .textAlign(TextAlign.Center)
          .padding({ top: $r('sys.float.padding_level16') })
      } else {
        Text($r('app.string.brew_search_result_count', this.state.total))
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_tertiary'))
          .width(CommonConstants.FULL_PERCENT)
          .padding({ bottom: $r('sys.float.padding_level4') })
        this.ResultListBuilder();
      }
    }
    .width(CommonConstants.FULL_PERCENT)
    .height(CommonConstants.FULL_PERCENT)
    // 让位写成**内层内容的 margin**（容器 padding 会裁剪内容、contentStartOffset 会让
    // 模糊区间出现空行程，两种都在真机上实测失败过，见 hds-titlebar-blur.md）
    .margin({
      top: brewTitleBarTotalHeight(this.globalInfoModel.statusBarHeight),
      bottom: this.globalInfoModel.naviIndicatorHeight + CommonConstants.SPACE_24,
    })
    .padding({
      left: this.contentInset(),
      right: this.contentInset(),
    })
  }

  build() {
    HdsNavDestination() {
      this.ContentBuilder()
    }
    .hideBackButton(false)
    .backgroundColor($r('sys.color.background_secondary'))
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .titleBar({
      padding: {
        start: LengthMetrics.vp(CommonConstants.SPACE_16),
        end: LengthMetrics.vp(CommonConstants.SPACE_16),
      },
      avoidLayoutSafeArea: true,
      style: this.titleBarStyle,
      content: {
        title: {
          mainTitle: this.state.keyword.length > 0 ? this.state.keyword : $r('app.string.brew_search_title'),
        },
        bottomBuilder: {
          builder: () => {
            this.ChipBarBuilder();
          },
          height: BREW_CHIP_BAR_HEIGHT,
        },
      },
    })
    .systemBarStyle({
      statusBarContentColor: this.systemColorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK ?
        StatusBarColorType.WHITE : StatusBarColorType.BLACK
    }, {
      statusBarContentColor: this.systemColorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK ?
        StatusBarColorType.WHITE : StatusBarColorType.BLACK
    })
    .onReady((ctx: NavDestinationContext) => this.handleOnReady(ctx))
    .onBackPressed(() => {
      if (this.backPressed) {
        return true;
      }
      this.backPressed = true;
      if (this.pathStack !== undefined && this.pathStack.size() > 1) {
        this.pathStack.pop();
        return true;
      }
      // 栈底：退出搜索态回到原页签。
      // **必须 return true 吞掉** —— return false 会让事件冒泡到 PcMainPage 的
      // HdsNavDestination.onBackPressed，那是「再按一次退出应用」的 Toast
      // （PcMainPage.ets:53）：用户想退出搜索，看到的却是退出应用，而且不报错、没有日志。
      AppStorage.setOrCreate(StorageKey.BREW_SEARCH_ACTIVE, false);
      return true;
    })
  }
}

@Builder
export function BrewSearchResultBuilder() {
  BrewSearchResultView()
}
```


- [ ] **Step 6: 编译 + 符号自检 + 装机确认无崩溃**

Run: `devecocli build 2>&1 | tail -5`
Expected: `BUILD SUCCESSFUL`

Run: `strings products/pc/build/default/intermediates/loader_out/default/ets/modules.abc | grep -c BrewSearchSuggestions`
Expected: 正数

Run: `devecocli run --device 127.0.0.1:42021 2>&1 | tail -5`
Expected: 安装并启动成功（此时搜索框还没接上，页面不可达 —— 本步只确认**没有引入编译期/启动期崩溃**）

Run: `devecocli log --crash --from 3m --tail 30`
Expected: 无崩溃记录

- [ ] **Step 7: 提交**

```bash
git add features/brewsearch
git commit -m "feat(brew): 搜索结果页完整实现（chips + 虚拟滚动 + 三态 + 降级条）

- 每页实例状态（BrewSearchState 在字段初始化里 new）：搜索态关掉再进来是新页面实例，
  共享单例状态会让新页面先渲染上一次的结果（详情页踩过，handover §10.4.1）。
  result 也放每页 state 而不是单例 VM，同理。
- 会话级状态（历史/发现的轮换位置）放单例 VM：搜索框与结果页都要读，
  不共享会出现「在浮层里清空历史、结果页还显示旧的」。
- 历史与发现只做一份 BrewSearchSuggestions，用 large 区分浮层与结果页空态：
  两处内容本来就一样，两份实现必然漂移（handover §3.2）。
- 结果行 hideRank: true：搜索跨 17 个分类，没有「分类内名次」语境，
  不隐藏每行都会是 \"0 / 0\"（BrewFormat.rankText 不判 0）。
- chips 切换不重跑引擎：按已算好的结果过滤（BrewSearchEngine.filterByKind 保证相对顺序一致）。
- 栈底返回键 return true 吞掉：否则冒泡到 PcMainPage 的「再按一次退出应用」Toast，
  用户想退搜索却看到退应用（编译过、不报错、没日志）。
- 新关键字 popToIndex(0) 而不是 push：否则连输会堆一叠结果页。

实测：build BUILD SUCCESSFUL；strings 命中 BrewSearchSuggestions；
装机启动成功；devecocli log --crash 无崩溃。"
```

---

## Task 6: 侧边栏搜索框 + 浮层

**Files:**
- Create: `features/brewsearch/src/main/ets/component/BrewSideSearchBox.ets`
- Modify: `features/brewsearch/src/main/ets/component/BrewSearchSuggestions.ets`（标题行扩成两个动作图标）
- Modify: `features/brewsearch/Index.ets`

**Interfaces:**
- Consumes: Task 4 的 `StorageKey.BREW_SEARCH_KEYWORD` / `BREW_SEARCH_ACTIVE`；Task 5 的 `BrewSearchSuggestions`；Task 5 的 `BREW_SEARCH_DEBOUNCE_MS`
- Produces: `BrewSideSearchBox`（`@ohos/brewsearch` 导出）

- [ ] **Step 1: 写 `BrewSideSearchBox.ets`**

```typescript
import { CommonConstants, StorageKey } from '@ohos/common';
import { BrewSearchSuggestions } from './BrewSearchSuggestions';
import { BREW_SEARCH_DEBOUNCE_MS } from '../constant/BrewSearchConstants';

/**
 * 侧边栏搜索框 + 浮层。**进入搜索态的唯一入口**。
 *
 * 三个刻意的决定：
 *   1. **浮层用 `bindPopup`**：popup 渲染在窗口 overlay 层，**不受 `HdsSideBar` 侧边栏
 *      容器裁剪**，所以能像截图那样横向盖到内容区上方。`bindContentCover` 会把侧边栏
 *      一起盖住（与截图不符）；自己写 `Stack + position` 则要手工处理点击外部关闭、
 *      层级与焦点，且要在 PcMainPage 里再造一套共享状态。
 *   2. **展开态与浮层开关是同一个状态**（`active`）：截图里框变白、右侧出现「搜索」
 *      与浮层弹出是同时发生的。所以不做 `onBlur` 收起 —— 点「搜索」时输入框会先失焦，
 *      真在 onBlur 里收起会把那个按钮在点击落地前删掉，点击就丢了。
 *   3. **关键字是本组件的 @State，写进 AppStorage**：它是唯一写者，结果页只读。
 */
@Component
export struct BrewSideSearchBox {
  /** 搜索框内部输入；`@State` 保证跟随输入重渲染 */
  @State keyword: string = '';
  @State active: boolean = false;
  /** 外部（切页签 / 退出搜索态）把 ACTIVE 置 false 时，这里跟着收起 */
  @StorageProp(StorageKey.BREW_SEARCH_ACTIVE) @Watch('onSearchActiveChange') searchActive: boolean = false;
  private debounceTimer: number = -1;

  aboutToDisappear(): void {
    this.cancelDebounce();
  }

  onSearchActiveChange(): void {
    if (!this.searchActive) {
      this.active = false;
    }
  }

  private cancelDebounce(): void {
    if (this.debounceTimer !== -1) {
      clearTimeout(this.debounceTimer);
      this.debounceTimer = -1;
    }
  }

  /**
   * 把关键字发布出去。`immediate = true`（回车 / 点「搜索」/ 点建议项）立即发布；
   * 否则 300ms 防抖 —— 每次输入都先取消上一个定时器，避免旧关键字的结果后到。
   */
  private publish(immediate: boolean): void {
    this.cancelDebounce();
    const run = () => {
      this.debounceTimer = -1;
      // 顺序要紧：先写关键字再置 ACTIVE —— 反过来的话，壳会先渲染出一个空关键字的结果页
      AppStorage.setOrCreate(StorageKey.BREW_SEARCH_KEYWORD, this.keyword);
      if (this.keyword.trim().length > 0) {
        AppStorage.setOrCreate(StorageKey.BREW_SEARCH_ACTIVE, true);
      }
    };
    if (immediate) {
      run();
    } else {
      this.debounceTimer = setTimeout(run, BREW_SEARCH_DEBOUNCE_MS);
    }
  }

  @Builder
  PanelBuilder() {
    Column() {
      BrewSearchSuggestions({
        large: false,
        pickWord: (word: string) => {
          this.keyword = word;
          this.publish(true);
          this.active = false;
        },
      })
    }
    .width($r('app.float.brew_search_panel_width'))
    .padding($r('sys.float.padding_level8'))
  }

  build() {
    Row() {
      SymbolGlyph($r('sys.symbol.magnifyingglass'))
        .fontSize($r('sys.float.Body_L'))
        .fontColor([$r('sys.color.icon_secondary')])
        .margin({ right: $r('sys.float.padding_level4') })
      TextInput({ text: this.keyword, placeholder: $r('app.string.brew_search_placeholder') })
        .placeholderFont({ size: $r('sys.float.Body_M') })
        .fontSize($r('sys.float.Body_M'))
        .fontColor($r('sys.color.font_primary'))
        .placeholderColor($r('sys.color.font_tertiary'))
        .backgroundColor(Color.Transparent)
        .padding(0)
        .layoutWeight(1)
        .enterKeyType(EnterKeyType.Search)
        .onChange((value: string) => {
          this.keyword = value;
          this.publish(false);
        })
        .onFocus(() => {
          this.active = true;
        })
        .onSubmit(() => {
          this.publish(true);
          this.active = false;
        })
      if (this.active) {
        Divider()
          .vertical(true)
          .height($r('sys.float.padding_level8'))
          .color($r('sys.color.comp_divider'))
          .margin({ left: $r('sys.float.padding_level4'), right: $r('sys.float.padding_level4') })
        Text($r('app.string.brew_search_action'))
          .fontSize($r('sys.float.Body_M'))
          .fontColor($r('sys.color.font_emphasize'))
          .onClick(() => {
            this.publish(true);
            this.active = false;
          })
      }
    }
    .width(CommonConstants.FULL_PERCENT)
    .height($r('app.float.brew_search_box_height'))
    .alignItems(VerticalAlign.Center)
    .padding({
      left: $r('sys.float.padding_level4'),
      right: $r('sys.float.padding_level4'),
    })
    // 折叠态灰底 / 展开态白底（照截图）。注意用 comp_background_tertiary：
    // sys.color.background_tertiary 并不存在（能用的系统颜色就是项目里已出现过的那些）
    .backgroundColor(this.active ? $r('sys.color.background_primary') : $r('sys.color.comp_background_tertiary'))
    .borderRadius($r('sys.float.corner_radius_level4'))
    .margin({ bottom: $r('sys.float.padding_level4') })
    .onClick(() => {
      this.active = true;
    })
    .bindPopup(this.active, {
      builder: () => {
        this.PanelBuilder();
      },
      placement: Placement.BottomLeft,
      enableArrow: false,
      mask: false,
      popupColor: $r('sys.color.background_primary'),
      radius: $r('sys.float.corner_radius_level8'),
      onWillDismiss: () => {
        // 点外部 / Esc：只关浮层与展开态，**不退出搜索态**（浮层 ≠ 搜索态）
        this.active = false;
      },
    })
  }
}
```

- [ ] **Step 2: 导出**

`features/brewsearch/Index.ets` 改成：

```typescript
export { BrewSearchHomeView } from './src/main/ets/view/BrewSearchHomeView';
export type { BrewSearchParams } from './src/main/ets/view/BrewSearchHomeView';

// 侧边栏搜索框（products/pc 的 CustomSideBar 用它）
export { BrewSideSearchBox } from './src/main/ets/component/BrewSideSearchBox';

// 结果页通过 module.json5 的 routerMap 进入编译图，不需要在这里再导出一次
// （与 brewdiscover 的 BrewDiscoverBoardView 同理）。
```

- [ ] **Step 3: 编译**

Run: `devecocli build 2>&1 | tail -5`
Expected: `BUILD SUCCESSFUL`

- [ ] **Step 4: 符号名实测（本步是全计划风险最高的一步）**

`sys.symbol.magnifyingglass` / `sys.symbol.trash` / `sys.symbol.arrow_clockwise` 这三个名字
**项目里从未出现过**，而 handover §10.6 记着「不存在的 `sys.symbol.*` 是构建全绿、运行期才炸」——
所以编译过**不代表**它们存在。Task 7 装机后必须看截图确认三个图标都渲染出来了。
若某个图标没渲染（或日志里出现资源解析失败），按下面的候选表**逐个替换后重装再看**：

| 用途 | 候选顺序 |
|---|---|
| 放大镜 | `magnifyingglass` → `doc_text_magnifyingglass` → `magnifyingglass_circle` |
| 垃圾桶 | `trash` → `trash_fill` → `delete_left` |
| 换一批 | `arrow_clockwise` → `arrow_counterclockwise` → `arrow_2_circlepath` |

**已确认存在**（项目里已在用，不必替换）：`magnifyingglass` 之外的 `chevron_up` / `chevron_down` / `chevron_right`。

- [ ] **Step 5: 提交**

```bash
git add features/brewsearch
git commit -m "feat(brew): 侧边栏搜索框 + 历史/发现浮层

- 浮层用 bindPopup：popup 渲染在窗口 overlay 层，不受 HdsSideBar 侧边栏容器裁剪，
  所以能像截图那样横向盖到内容区；bindContentCover 会把侧边栏一起盖住（与截图不符）。
- 展开态与浮层开关合成一个 active 状态：截图里框变白/出现「搜索」/浮层弹出是同时的。
  刻意不写 onBlur 收起 —— 点「搜索」时输入框先失焦，真在 onBlur 里收起会在点击
  落地前把按钮删掉，点击就丢了。
- 防抖自实现（setTimeout + clearTimeout），不用 common 的 DebounceUtil：
  那是全局单例时间戳的 leading 节流，语义与作用域都不对。
- 发布顺序先写 KEYWORD 再写 ACTIVE：反过来壳会先渲染一个空关键字的结果页。
实测：build BUILD SUCCESSFUL。
待验（Task 7 装机看截图）：magnifyingglass / trash / arrow_clockwise 三个符号名
项目里从未用过，而不存在的 sys.symbol.* 是运行期才炸（handover §10.6）。"
```

---

## Task 7: 接入搜索态（PcMainPage 保活 + CustomSideBar）+ 真机验证

**Files:**
- Modify: `products/pc/src/main/ets/component/CustomSideBar.ets`
- Modify: `products/pc/src/main/ets/page/PcMainPage.ets`

**Interfaces:**
- Consumes: Task 4 的 `StorageKey.BREW_SEARCH_ACTIVE`、Task 5/6 的 `BrewSearchHomeView` / `BrewSideSearchBox`
- Produces: 可用的搜索（本任务是 G1/G4 真正成立的地方）

- [ ] **Step 1: 侧边栏插入搜索框 + 切页签退出搜索态**

`products/pc/src/main/ets/component/CustomSideBar.ets`：

import 区加：

```typescript
import { BrewSideSearchBox } from '@ohos/brewsearch';
import { StorageKey } from '@ohos/common';
```

在 `build()` 里，把标题行 `Row() {...}` 与 `ForEach(TABS_LIST, ...)` 之间插入：

```typescript
      // 搜索框（Homebrew 市场新增）。放在标题行与页签列表之间，与截图一致
      BrewSideSearchBox()
```

并把 `BarItemBuilder` 里的 `onClick` 改成（退出搜索态优先于切页签）：

```typescript
    .onClick(() => {
      // 侧边栏是「离开搜索」的唯一手势：点任何页签都先退出搜索态再切页签
      AppStorage.setOrCreate(StorageKey.BREW_SEARCH_ACTIVE, false);
      if (this.currentIndex !== item.id) {
        this.sideBarChange(item.id);
      }
    })
```

- [ ] **Step 2: 内容区加搜索态与保活**

`products/pc/src/main/ets/page/PcMainPage.ets`：

import 区加：

```typescript
import { BrewSearchHomeView } from '@ohos/brewsearch';
```

struct 字段加（`@State currentIndex` 之后）：

```typescript
  /**
   * 是否处于搜索态。写它的三处：搜索框（true）、切页签（false）、结果页栈底返回（false）。
   * 用 AppStorage 而不是回调：CustomSideBar 是 HdsSideBar 的 builder 参数、
   * 结果页是 NavDestination，函数穿不过路由参数（handover §3.3）。
   */
  @StorageLink(StorageKey.BREW_SEARCH_ACTIVE) searchActive: boolean = false;
```

把 `contentPanelBuilder` 里的 `GridCol` 内容换成 `Stack`：

```typescript
  @Builder
  contentPanelBuilder() {
    GridRow({
      columns: { sm: ColumnEnum.SM, md: ColumnEnum.MD, lg: ColumnEnum.LG },
      direction: GridRowDirection.Row,
      breakpoints: { reference: BreakpointsReference.ComponentSize }
    }) {
      GridCol({ span: { sm: ColumnEnum.SM, md: ColumnEnum.MD, lg: ColumnEnum.LG } }) {
        Stack() {
          // 保活用 visibility 而**不是 if/else**：if 分支切换会销毁 HomeView，
          // 页签会重建（回到首页、丢滚动位置），G4 直接不成立。
          HomeView({ showTabBar: false, currentIndex: this.currentIndex, isShown: this.isShown })
            .visibility(this.searchActive ? Visibility.Hidden : Visibility.Visible)
          if (this.searchActive) {
            BrewSearchHomeView()
          }
        }
        .width(CommonConstants.FULL_PERCENT)
        .height(CommonConstants.FULL_PERCENT)
      }
      .margin({
        left: -SCROLL_PADDING_LG,
        right: -SCROLL_PADDING_LG,
      })
    }
    .padding({
      left: SCROLL_PADDING_LG,
      right: SCROLL_PADDING_LG,
    })
    .clip(false)
    .onBreakpointChange((breakpoints: string) => {
      this.globalInfoModel.widthBreakpoint =
        BREAKPOINTS.includes(breakpoints) ? BREAKPOINTS.indexOf(breakpoints) : WidthBreakpoint.WIDTH_XL;
    })
  }
```

- [ ] **Step 3: 编译 + 装机**

Run: `devecocli build 2>&1 | tail -5`
Expected: `BUILD SUCCESSFUL`

Run: `devecocli run --device 127.0.0.1:42021 2>&1 | tail -5`
Expected: 安装并启动成功

- [ ] **Step 4: 确认无崩溃 + 看搜索日志**

Run: `devecocli log --crash --from 3m --tail 30`
Expected: 无崩溃

Run: `devecocli ui window list --device 127.0.0.1:42021`
Expected: 有 `Focused` 的主窗口（**若窗口不在前台，后面的点击会被别的窗口吃掉、App 里什么都不会发生**，handover §2.1）

- [ ] **Step 5: 【Review Focus 3】保活专项验证**

```bash
# 1) 先切到 Formulae 页签并向下滚动若干（用方向 fling 更接近真实滚动）
devecocli ui dircfling down --device 127.0.0.1:42021
# 2) 点搜索框（坐标从 ui layout 里取搜索框中心；点完应看到浮层）
devecocli ui click <搜索框中心x> <搜索框中心y> --device 127.0.0.1:42021
# 3) 输入一个能命中的包名
devecocli ui text "git" --device 127.0.0.1:42021
# 4) 截图：应看到结果页（左侧栏仍在、搜索框为白底展开态）
devecocli ui screenshot --device 127.0.0.1:42021 --path .brewgen/search-result.png
# 5) 按返回键退出搜索（栈底）→ 截图：应回到 Formulae 页**且仍在原来的滚动位置**
devecocli ui click <返回按钮中心x> <返回按钮中心y> --device 127.0.0.1:42021
devecocli ui screenshot --device 127.0.0.1:42021 --path .brewgen/back-to-tab.png
```

用 read 工具看两张 png。判据：
- `search-result.png`：内容区是搜索结果列表（每行有图标 + token + desc + 安装量，**没有 `0 / 0`**）；
- `back-to-tab.png`：回到 Formulae，**且滚动位置没回到顶部**（若回到了顶部 → 保活失败，说明 `Visibility.Hidden` 方案不成立，按 spec §5.1 的退路改成隐藏的第五个 `TabContent`）。

- [ ] **Step 6: 【Review Focus 1/5】降级与索引未就绪的真机观察**

Run: `devecocli log --keyword BrewSearch --from 10m --tail 50`
Expected: 至少一行 `[BrewSearch] search "git" → N hits, M items, indexReady=true, indexOnly=false, Xms | top: git(100/exact) …`
判据：
- `top:` 的第一个人应是 `git(100/exact)`（全等优先）；
- 耗时 `Xms` 记录在案（若超过 50ms，记进交付说明，Task 8 时决定是否挪 taskpool）；
- 冷启动后**立刻**搜索（索引还在同步）时 `indexReady=false` 且仍有命中 —— 这条就是 Review Focus 1。

【Review Focus 4】连输只保留最后一次：
```bash
devecocli ui text "g" --device 127.0.0.1:42021
devecocli ui text "it" --device 127.0.0.1:42021
devecocli log --keyword BrewSearch --from 1m --tail 20
```
判据：最后一行是 `search "git"`（不是 `search "g"`），且**没有** `search "g"` 的结果把列表覆盖回去 ——
`"g"` 的那次发布应被 `clearTimeout` 取消（300ms 内），日志里最多出现一条。

- [ ] **Step 7: 【Review Focus 2】栈底返回键不能弹「再按一次退出应用」**

在 Step 5 第 5 步（栈底返回）之后立刻：

Run: `devecocli ui screenshot --device 127.0.0.1:42021 --path .brewgen/after-back.png`
Expected: 画面里**没有** `back_toast` 的「再按一次退出应用」提示（若有 → 说明 `onBackPressed` 返回了 false，按 Task 5 Step 5 的注释修）。

- [ ] **Step 8: 量几何（不靠猜）**

Run: `devecocli ui layout --device 127.0.0.1:42021 --mode full > .brewgen/search-layout.txt`
Expected: 在里面找到搜索框与浮层/结果页的尺寸，核对：
- 搜索框宽 ≈ 侧边栏内缩后满宽（≈208vp）、高 ≈ 40vp；
- 浮层面板宽 ≈ **400vp**，且 **面板宽 / 搜索框宽 ≈ 1.9 ± 0.1**（截图量出的比例）。
不一致就调 `features/brewsearch/src/main/resources/base/element/float.json` 的两个值后重装再看。

- [ ] **Step 9: 提交**

```bash
git add products/pc/src/main/ets/component/CustomSideBar.ets products/pc/src/main/ets/page/PcMainPage.ets
git commit -m "feat(brew): 侧边栏搜索框接入搜索态（内容区保活）

- 内容区用 Stack + Visibility.Hidden 而不是 if/else：if 会销毁 HomeView，
  页签重建（回首页、丢滚动位置），G4「退出搜索回原页签」直接不成立。
- searchActive 走 AppStorage：CustomSideBar 是 HdsSideBar 的 builder 参数、
  结果页是 NavDestination，函数穿不过路由参数。
- 点侧边栏任何页签都先置 BREW_SEARCH_ACTIVE=false 再切：侧边栏是「离开搜索」的唯一手势。
- 搜索框插在标题行与页签列表之间（照截图）。

实测（真机 127.0.0.1:42021）：
- build BUILD SUCCESSFUL、装机启动成功、log --crash 无崩溃；
- 保活专项：进搜索 → 返回 → Formulae 页仍在原滚动位置（截图 .brewgen/{search-result,back-to-tab}.png）；
- 栈底返回不弹「再按一次退出应用」（.brewgen/after-back.png）；
- [BrewSearch] 日志：git → N hits，top: git(100/exact)，耗时 Xms；
- ui layout 量得：搜索框 208x40vp、浮层宽 400vp（比例 1.92）。"
```

---

## Task 8: 文档同步 + 交付说明

**Files:**
- Modify: `docs/brew-handover.md`
- Modify: `docs/brew-marketplace-content-plan.md`
- Modify: `docs/brew-api-design.md`

**Interfaces:**
- Consumes: Task 1-7 的全部结论与实测数据
- Produces: 三份文档与新代码一致（handover §0 要求「改任何一处时留意其余几处有没有需要同步的表述」）

- [ ] **Step 1: `docs/brew-handover.md`**

1. §1 的页面状态表：把 `| 搜索 | ⬜ 仅预留入口，未实现 |` 改成
   `| 搜索 | ✅ 完成：侧边栏搜索框 + 历史/发现浮层 + 本地全量索引搜索结果页 + 详情页复用 |`
2. §3.1 模块表加一行：
   `| \`brewsearch\` | **新增** | 搜索：侧边栏搜索框、历史/发现、结果页（引擎在 brewcommon） |`
3. §3.3 路由小节：在既有路由列表后补一句
   「搜索页 `BrewSearchResultView` 是**第五个独立页面栈**（`BREW_SEARCH_PAGE_CONTEXT`），
   不属于任何页签 —— 搜索态由 `PcMainPage` 用 `Stack + Visibility.Hidden` 保活 `HomeView` 后叠加。」
4. §6 加一节 `### 6.5 搜索（brewsearch）`，写清：入口位置、三态（空关键字/有结果/无命中）、
   降级条、`BREW_SEARCH_LIMIT=50`、死写词组与它必然空结果的后果、`hits`/`items` 平行数组不变量。
5. §8.2 待办表：把 `**搜索**` 一行删掉，换成
   `| 搜索热词/联想 | 当前只有死写词组（点下去必然空结果，见 spec §8）；要真热词得从目录/榜单取 |`
   与 `| 搜索历史不落盘 | 现在重启即回到内置 4 条；接 PreferenceManager 即可 |`
6. §8.5 之前补一条踩坑索引（§7.2 属性覆盖那类下面）：
   `| 想退出搜索却弹出「再按一次退出应用」 | §6.5 | 页面栈底的 onBackPressed 必须 return true 吞掉，否则冒泡到 PcMainPage |`

- [ ] **Step 2: `docs/brew-marketplace-content-plan.md`**

1. §13 标题从 `## 13. 搜索预留方案（本轮不实现）` 改成 `## 13. 搜索（已实现）`，
   表里的「预留内容」改成实际实现（侧边栏搜索框 + 浮层 + 结果页 + `BrewSearchModel`），
   并加一行指向 spec：`实现细节与取舍见 docs/superpowers/specs/2026-09-21-brew-search-design.md`。
2. §12 文案表里 `| 搜索入口 | 「搜索功能开发中」 |` 那一行删掉（该文案已从三份 string.json 删除）。

- [ ] **Step 3: `docs/brew-api-design.md`**

新增一节 `## 14. 搜索`（放在现有章节之后），内容必须包含：
1. 引擎口径：六档打分 + 三级 tie-break（照抄 `BrewSearchEngine` 的常量名与数值）；
2. 为什么引擎**必须零 import**（Node 检查脚本 `hmosword-build/brew-search/check_engine.mjs` 靠它）；
   连同运行命令与「39 条断言」（初版 27 条；执行期因词边界标签缺陷补 8 条，评审后又补 4 条覆盖）
3. Task 2 三处既有入口的改动理由（`private static` 的类作用域、`rankText(0,0)`）；
4. 三条降级路径（索引未就绪 / 目录缺失回落 desc 索引 / 两者都缺）+ 各自的日志判据；
5. `hits` 与 `items` 等长同序的不变量；
6. 本次实测数据：搜索耗时、`ui layout` 量到的搜索框与浮层尺寸、装机验证结论。

- [ ] **Step 4: 文档自检**

Run: `grep -rn "brew_search_coming_soon\|仅预留入口" docs/ features/brewcommon/src/main/resources/ 2>/dev/null`
Expected: 无输出（文案与文档里都不该再提到它）

Run: `grep -rn "brewsearch" docs/brew-handover.md | head`
Expected: 至少 2 处（模块表 + 搜索结果页小节）

- [ ] **Step 5: 提交**

```bash
git add docs/brew-handover.md docs/brew-marketplace-content-plan.md docs/brew-api-design.md
git commit -m "docs(brew): 同步搜索功能的文档口径（handover / content-plan / api-design）

按 handover §0 的分工各改各的：
- handover：页面状态表搜索划掉、模块表加 brewsearch、路由补第五个独立页面栈、
  新增 §6.5、待办表把「搜索」换成「热词/联想」与「历史不落盘」、踩坑索引加
  「想退出搜索却弹出再按一次退出应用」。
- content-plan：§13 从「预留方案（本轮不实现）」改成「已实现」，§12 文案表删掉
  「搜索入口」行。
- api-design：新增搜索小节，含引擎口径、零 import 的理由与检查脚本命令、
  三处既有入口的改动理由、三条降级路径与日志判据、hits/items 不变量、本次实测数据。

实测：grep brew_search_coming_soon / 「仅预留入口」在 docs 与资源里均无残留。"
```

---

## 完成后的整体验证（Task 8 之后跑一遍）

```bash
# 1) 引擎检查（唯一能在本机跑的真测试）
node hmosword-build/brew-search/check_engine.mjs
# 期望：OK: BrewSearchEngine 检查通过，39 条断言

# 2) 全量构建
devecocli build 2>&1 | tail -5
# 期望：BUILD SUCCESSFUL

# 3) 符号进字节码（不加锚点）
ABC=products/pc/build/default/intermediates/loader_out/default/ets/modules.abc
for s in BrewSearchResultView BrewSearchSuggestions BrewSideSearchBox BrewSearchModel BrewSearchEngine; do
  printf '%s: %s\n' "$s" "$(strings "$ABC" | grep -c "$s")"
done
# 期望：五个都是正数

# 4) 路由条数
python3 -c "import json;print(len(json.load(open('products/pc/build/default/intermediates/router_map/default/router_map.json'))['routerMap']))"
# 期望：25

# 5) 三份 string.json 合法
python3 -c "import json;[json.load(open(f'features/brewcommon/src/main/resources/{d}/element/string.json')) for d in ['base','zh_CN','en_US']];print('ok')"

# 6) 装机 + 无崩溃
devecocli run --device 127.0.0.1:42021 2>&1 | tail -5
devecocli log --crash --from 5m --tail 30
```

然后交需求方按 spec §12.3 的 8 步手动验收。

---

## 追加任务（2026-09-22）：搜索改页签形态 —— 已完成，commit `cb79a08`

**这不是原计划里的任务**：原计划 Task 4–7 做的是「侧边栏搜索框 + `bindPopup` 历史/发现浮层 +
`PcMainPage` 保活 + 真搜索页」。需求方真机测试后改了形态（理由与两条 P0 见
`specs/2026-09-21-brew-search-design.md` 的「追加（R16）」一节与
`.superpowers/sdd/2026-09-21-brew-search/progress.md` 的 R16）。

**Task 4/5/6 的哪些产物被作废**
- Task 6 全部（`BrewSideSearchBox` + 浮层）—— 组件已删除
- Task 7 的 `PcMainPage` / `CustomSideBar` 改动 —— 已回退（页签形态不需要覆盖层保活）
- Task 4 的 `PcMainPage` 保活截图与「退出搜索不丢页签状态」验收项 —— 不再适用
- Task 5 的输入框相关部分 —— 输入框从侧边栏搬进搜索页标题栏

**保留并继续有效**：Task 1（引擎，39 条断言）、Task 2（`BrewSearch.searchRows` 等接缝）、
Task 3（`BrewSearchModel`）、`BrewSearchVM` / `BrewSearchState` / `BrewSearchRowSource` /
`BrewSearchSuggestions`（浮层与页共用的那份实现，现在只被页用）、全部文案。

**本任务新增的验证判据**（原计划的验收块之外，必须一起跑）
- `modules.abc` 里 `BrewSearchBar` > 0、`BrewSideSearchBox` **= 0**、`BREW_SEARCH_ACTIVE` **= 0**（无锚点 grep）
- `router_map.json` 仍为 **25** 条（搜索页仍是该页签的栈底页，路由不能删）
- 真机：侧边栏出现「搜索」页签（CASKS 与 MINE 之间），点进去有输入框 + 历史 + 发现；
  输入真实包名出结果（实测 `git` → 336 hits / 50 items）
- `ui layout`：输入框盒与 chips/分区标题/发现项**同一条左竖线**（本机 = x 1016）
