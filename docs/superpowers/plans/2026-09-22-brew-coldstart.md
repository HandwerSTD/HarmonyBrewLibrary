# brew 冷启动优化 实施计划

> **执行方式（需求方指定，覆盖本 skill 的默认建议）**：**一个 subagent 一次性写完全部代码，然后做一次整体 review** —— 不做逐任务 review。
> 所以 Task 1–6 是**同一次交付内的有序步骤**，不是 6 个评审关口。执行者按顺序做完 Task 1–6，跑通 Task 7 的构建，然后整份交付给 review。
> 勾选框用于跟踪进度，不表示需要停下来等人确认。

**Goal:** 把 Formulae/Casks 冷启动首屏从实测 **17.7 s** 降到 **≤1100 ms**，做法是让"元数据索引"成为上游存在性的权威（首屏零请求），同时保证**输出逐字节不变**。

**Architecture:** 只改 `BrewService.buildFormulaPage` / `buildCaskPage` 的**候选集取法**：索引可信时 `candidates = 目录 ∩ 索引` 且不发任何单条请求；索引不可信时逐字保留现有"前 N + 逐条 hydrate"降级路径。再加一个与既有 `catalogInFlight` 同款的在途去重（同一页会被构建两次）。不动 `BrewMetaSync`、不动目录、不新增落盘 key、不做页面级缓存。

**Tech Stack:** ArkTS / ArkUI（HarmonyOS 2in1）、`devecocli`（构建与装机，**不用** `hvigorw`/`hdc`）、hilog 打点。

**Spec:** `docs/superpowers/specs/2026-09-22-brew-coldstart-design.md`（**执行前必读 §2 根因、§3.3 闸门推论、§5 设计、§6.3 正确性**）

## Global Constraints

- **工作区状态**：本 plan 的编辑指令**引用的是当前工作区里已存在的 `[perf-probe]` 探针代码**（未提交，6 个文件）。**必须从当前工作区继续，不要 `git checkout` / `git stash` / `git clean`**，否则 Task 4 的 oldText 匹配不上。
- 只跑 PC（2in1）。构建用 `devecocli build`，装机用 `devecocli run --device 127.0.0.1:42021`。**不要跑 `hdc kill`**（会杀掉 `devecocli` 依赖的 hdc server，`brew-handover.md` §8.6）。
- **不新增任何 `PreferenceManager.setValue` 调用点**（不新增落盘 key）。
- **不做页面级缓存**：在途去重只复用"同一批未完成的 Promise"，完成后即清空，不缓存结果（`brew-handover.md` §5.1）。
- **降级路径逐字不改**（`brew-catalog-fullsync-spec.md` §4.5 已把它的语义定为"请求预算"）。
- **不重构 `BrewFormulaHomeView` 的双渲染结构**：它是照抄参考实现的写法（spec §2.4③），只去重。
- `desc` 的取数口径**只能**走 `BrewBrowseBuilder.descOf(token, descIndex, docDesc)`，不要在别处新写一遍（spec §3.2）。
- 注释写"为什么"，不写"做了什么"。中文。每条关键取舍都要能追溯到 spec 的某一节。

## Review Focus

> 这些是 spec 隐含、但**没有哪条测试能覆盖**的失效模式。Review 时按这个顺序看，最可能的排前面。

1. **`formulaPageInFlight` / `caskPageInFlight` 泄漏**：若某个分支提前 `return` 或 Promise reject 时忘了清空，后续每次调用都会拿到那个已 reject 的 Promise → 页面永久失败态，**直到重启 App**。这比改动前更糟（改动前只是慢）。Task 2/3 用两分支 `.then` 显式清空。
2. **闸门把正常情况判成"不可信"**：`trusted = covered >= 100`。若某 kind 的索引因上游改标识键而只扫出几十条，会静默走降级路径（慢 15 s）而不报错。日志里 `trusted=false` 必须可见（Task 2/3 的日志含该字段）。
3. **主路径真的零请求**：`trusted=true` 时 `missing` 必须恒为空数组。若写成"过滤 candidates 但仍调 `splitMissing`"，`splitMissing` 内部会重新按 `descIndex` 过滤 → 结果碰巧也是空，但**意图错、且未来一改就漏**。Task 2/3 显式短路。
4. **日志字段被后续改动破坏**：V4 的主判据依赖 `ready=` / `index=` / `dropped=` / `catalog=` 四个数值。它们必须与改动前的**同名语义**对齐（`index` 仍表示"索引覆盖数"，`ready` 的分母仍是**目录全量**而不是候选集）。
5. **`DEFAULT_TAB` 忘了还原**：它现在是临时改的 `FORMULAE`。留着会改变 App 的落地页（产品行为变更，不是本次目标）。

---

## 与 spec 的一处偏差（写 plan 时收敛的，已同步回 spec §12）

spec §12 第 5 条写"5 个探针文件都包进 `BREW_PERF_TRACE`"，plan 收敛为：

- **3 个文件包进开关**（`BrewService` / `BrewMetaSync` / `BrewBrowseBuilder`）—— 它们都在 `brewcommon` 内，直接 `import` 本模块的常量，不需要改 `Index.ets`。
- `PcAbility.ets` 的两行改成**与文件既有风格一致的生命周期日志**。理由：该文件其余四个生命周期回调都有一行 `Logger.info(TAG, 'Ability onXxx')`，**只有 `onCreate` / `onWindowStageCreate` 缺** —— 补上是一致性改动，而且 hilog 时间戳本身就够做差。**不为它引入 `BREW_PERF_TRACE`**：那会让 `products/pc` 依赖 `@ohos/brewcommon`，把整个 brew 数据层拉进 Ability —— 正是 spec §1.2 列为"后续"的 import 问题。
- `BrewFormulaHomeViewModel.ets` 的探针**直接撤掉**：`loadFormulaPage success` 这行的 hilog 时间戳就是"数据进 state"的时刻。

---

## review 后的修正（2026-09-22，**已落到代码；本 plan 的 Task 2/3 代码块是修正前的版本，以代码为准**）

独立 reviewer 查出 2 类真缺陷，都已修：

| 级别 | 缺陷 | 修法 |
|---|---|---|
| **P1** | `!trusted` 一律用 `all.slice(0, LIMIT)` —— **漏了旧代码在 `covered ∈ [1,99]` 时用的是目录全量**这一分支。后果：索引只扫出几十条时，索引命中的条目若排名在 100 名之外就**整片消失**（离线时表现为空页），比改动前更差。它也直接推翻了 spec A5 / 本 plan Global Constraints 里"降级路径逐字不改"的说法 | `!trusted` 改回 `covered > 0 ? all : all.slice(0, BREW_BROWSE_HYDRATE_LIMIT)` → `!trusted` 与改动前**逐字等价**，那句话从口号变成可核对的事实 |
| P2 | 去重键漏了 `pageSize`，而 plan 里"两个调用点 pageSize 相同"的前提**今天就不成立**（首页 `BaseHomeViewModel.pageSize = 30` vs `SIBLING_PAGE_SIZE = 100`，`BrewRepository.ets:54,168,209,317,354`） | join 增加 `InFlightPageSize === pageSize` 条件 |
| P2 | 一个永不 settle 的构建会永久占住在途字段（重试按钮也 join 同一个死 Promise）→ 页面永久 LOADING 直到重启 App，**比改动前更糟** | 新增 `BREW_PAGE_INFLIGHT_JOIN_MS` 时效守卫 + 递增序号守卫清空（避免超时新建的那次被旧的那次清掉） |
| P2 | 多调用方共享同一个 page 对象（新引入的别名耦合） | 在字段注释里写明"消费者必须只读" |

⇨ 实现细节：`BREW_PAGE_INFLIGHT_JOIN_MS` 引用 `BREW_BROWSE_HYDRATE_MS`，**必须声明在它之后** ——
初版按 plan 放在 `BREW_INDEX_MIN_TRUST` 之后，ArkTS 报 `Block-scoped variable used before its declaration`，已搬到 `BREW_BROWSE_HYDRATE_MS` 之后。

⇨ 三条**验收判据也要改**（reviewer 指出，已同步回 spec §9.1）：
① V2 必须先把 `DEFAULT_TAB` 临时改回 `FORMULAE`（否则量不到）；
② V3 的"零请求"**只能从 `browse … built` 行读**，不能用 `statsLine()` —— 它是会话累计，默认页签是 Discover 时会被 Discover 的请求污染（连 reviewer 都指出：G2 原来那句"`dl=0` 与 `failed` 增量为 0"在 Discover 落地时不可能成立）；
③ `browse … built` 行尾的 `ms` 不可与基线 `16989ms` 直接比（`tStart` 已提到函数第一行）。

---

## Task 1: 常量（`BrewConstants.ets`）

**Files:**
- Modify: `features/brewcommon/src/main/ets/constant/BrewConstants.ets`

**Interfaces:**
- Produces: `BREW_INDEX_MIN_TRUST: number`、`BREW_PERF_TRACE: boolean`（供 Task 2/3/4 使用）

- [ ] **Step 1: 新增 `BREW_PERF_TRACE`（放在文件顶部 `BREW_DATA_SOURCE` 之后、`BREW_API_BASE` 之前）**

```ts
// ---------------------------------------------------------------- 性能打点开关

/**
 * 冷启动分段打点的总开关。**默认关**。
 *
 * 为什么要留一个开关而不是测完就删：这一轮（2026-09-22）的实测结论是"瓶颈在请求语义，
 * 不在 I/O"，而这类结论**会随数据变化失效**（上游一改口径，`dropped` 的量级就变）。
 * 下次回归只需把它改成 `true` 重新量一遍，不用重写探针。
 *
 * 打开后会出现 `[perf]` 前缀的日志与 `browse … built` 行尾的分段耗时；
 * 覆盖 `BrewService.ensureCatalog`、`BrewMetaSync.ensureIndex`、`BrewBrowseBuilder.formulaPage/caskPage`。
 * 冷启动的起点用 `PcAbility` 的 `Ability onCreate` 生命周期日志（hilog 时间戳即可做差），
 * 终点用 `BrewFormulaHomeViewModel` 已有的 `loadFormulaPage success` 行 —— 这两处**不需要**探针。
 */
export const BREW_PERF_TRACE: boolean = false;
```

- [ ] **Step 2: 新增 `BREW_INDEX_MIN_TRUST`（紧跟 `BREW_BROWSE_HYDRATE_LIMIT` 之后）**

```ts
/**
 * 元数据索引的**可信度闸门**：某 kind 的索引至少覆盖这么多条目录行，才把索引当作
 * "上游有哪些包"的权威清单（从而走主路径：候选 = 目录 ∩ 索引、首屏零请求）。
 *
 * 为什么"非空 + 够一页"就够了，而不是用覆盖率比例（例如 `covered/all ≥ 0.9`）：
 * 一个 kind 的索引表是**原子地产出**的 —— `BrewMetaSync.syncKind()` 只在整份大文件扫完
 * 且 `pairs > 0` 时才返回新表，否则返回 `undefined` 让调用方保留旧表。所以不存在"半张表"，
 * 非空就意味着它是某次全量扫描的完整结果（只可能来自更早的一次同步，即已接受的 staleness）。
 *
 * 而**比例闸门会误伤 cask**：`cask.json` 有 2,645 条 `desc: null`，落盘时故意不写空串
 * （见 `brew-catalog-fullsync-spec.md` §4.6③），所以 cask 的覆盖率天然只有一半左右 ——
 * 用 0.9 会让 cask 永远走降级路径。
 *
 * 取 100（与 `BREW_BROWSE_HYDRATE_LIMIT` 同值但是**两个不同的概念**）：真出现
 * "表非空但覆盖率极低"（例如上游改了标识键导致只扫出几十条错配）时，此时"前 100 条 +
 * 逐条 hydrate"比"只显示这几十条"更有用，与改动前的行为一致。两个常量恰好同值，
 * 但改一个不必改另一个。
 */
export const BREW_INDEX_MIN_TRUST: number = 100;
```

- [ ] **Step 3: 改 `BREW_BROWSE_HYDRATE_LIMIT` 的注释（只改前两段，`export` 行不动）**

把现有的：
```ts
/**
 * **降级**浏览集上限：只在元数据索引不可用（首次安装、同步失败、断网）时生效。
 *
 * 索引可用时浏览集 = 目录全量，这个常量**不参与**；它管的是另一件事：
```
改成：
```ts
/**
 * **降级**浏览集的请求预算：只在元数据索引**不可信**（`covered < BREW_INDEX_MIN_TRUST`，
 * 即首次安装 / 同步失败 / 断网 / 扫描口径变了）时生效。
 *
 * 索引可信时浏览集 = 目录 ∩ 索引、首屏零请求，这个常量**完全不参与**；它管的是另一件事：
```

- [ ] **Step 4: 编译自检**

```bash
cd /storage/Users/currentUser/Documents/DevEcoStudioProjects/sample_in_harmonyos && devecocli build 2>&1 | tail -5
```
Expected: `BUILD SUCCESSFUL`（新增两个未被引用的常量，ArkTS 不报错）

---

## Task 2: `buildFormulaPage` —— 闸门 + 主/降级路径 + 去重 + 日志

**Files:**
- Modify: `features/brewcommon/src/main/ets/service/BrewService.ets`

**Interfaces:**
- Consumes: `BREW_INDEX_MIN_TRUST`、`BREW_PERF_TRACE`（Task 1）
- Produces: `BrewService.formulaPageInFlight`（私有静态）、`BrewService.perfSuffix(tStart, tCatalog, tIndex, tSplit): string`（私有静态，Task 3 复用）

- [ ] **Step 1: 把 `BREW_INDEX_MIN_TRUST` 与 `BREW_PERF_TRACE` 加进 `BrewConstants` 的导入块**

在 `import { … } from '../constant/BrewConstants';`（约 17–36 行）里，`BREW_HYDRATE_TIMEOUT_MS,` 之后插入两行：
```ts
  BREW_INDEX_MIN_TRUST,
  BREW_PERF_TRACE,
```

- [ ] **Step 2: 新增在途字段（紧跟 `catalogInFlight` 之后，约 248 行）**

```ts
  /**
   * 在途的浏览页构建。**同一页会被构建两次**：`BrewFormulaHomeView` 同时渲染了
   * `HdsNavigation` 的根内容与 push 进去的 `BrewFormulaListView` 两份 `BrewFormulaBaseView`
   * （照抄参考实现的写法，组件页同样双载），两份的 `aboutToAppear` 都派发 `LOAD_FORMULA_PAGE`。
   * 不合并的话分类要算两遍（实测 2×420ms），降级路径下 hydrate 还要翻倍。
   *
   * 为什么用两个具名字段而不是 `Map<string, Promise<…>>`：ArkTS 对泛型/`unknown` 的 `as`
   * 转换比 TS 严，用 Map 就得在取出时转型 —— 那是"编译期过、运行期才暴露"的写法。
   */
  private static formulaPageInFlight: Promise<BrewPageData<BrewFormulaPageData> | undefined> | undefined =
    undefined;
  private static caskPageInFlight: Promise<BrewPageData<BrewCaskPageData> | undefined> | undefined =
    undefined;
```

- [ ] **Step 3: 新增 `perfSuffix` 辅助方法（放在 `ghostSuffix` 之后，约 528 行）**

```ts
  /** [perf] 分段耗时尾缀。`BREW_PERF_TRACE` 关闭时返回空串，让正常日志不被污染 */
  private static perfSuffix(tStart: number, tCatalog: number, tIndex: number, tSplit: number): string {
    if (!BREW_PERF_TRACE) {
      return '';
    }
    const now: number = Date.now();
    return ` [perf tStart=${tStart} catalogMs=${tCatalog - tStart} indexMs=${tIndex - tCatalog} ` +
      `filterMs=${tSplit - tIndex} hydrate+classifyMs=${now - tSplit}]`;
  }
```

- [ ] **Step 4: 改 `ensureCatalog()` 的探针（约 834 行，把 `[perf-probe]` 那两行包进开关）**

把：
```ts
      // [perf-probe] 同 ensureIndex：主线程 `getSync` + `JSON.parse`（目录约 550KB）
      const t0: number = Date.now();
      const stored: BrewCatalog | null =
        PreferenceManager.getInstance().getValue<BrewCatalog>(BREW_CATALOG_STORAGE_KEY);
      const readMs: number = Date.now() - t0;
      BrewService.catalog = stored ?? undefined;
      Logger.info(TAG, `[perf-probe] catalog pref read+parse ts=${t0} readMs=${readMs} ` +
        `formula=${stored?.topTokens?.[BrewKindText.FORMULA]?.length ?? 0} ` +
        `cask=${stored?.topTokens?.[BrewKindText.CASK]?.length ?? 0}`);
```
改成：
```ts
      // [perf] 这一段是主线程 `getSync` + `JSON.parse`（目录约 550KB）。
      // 实测只有 19~22ms —— 记下来是为了防止"瓶颈在 I/O"这个直觉再回来。
      const t0: number = Date.now();
      const stored: BrewCatalog | null =
        PreferenceManager.getInstance().getValue<BrewCatalog>(BREW_CATALOG_STORAGE_KEY);
      const readMs: number = Date.now() - t0;
      BrewService.catalog = stored ?? undefined;
      if (BREW_PERF_TRACE) {
        Logger.info(TAG, `[perf] catalog pref read+parse ts=${t0} readMs=${readMs} ` +
          `formula=${stored?.topTokens?.[BrewKindText.FORMULA]?.length ?? 0} ` +
          `cask=${stored?.topTokens?.[BrewKindText.CASK]?.length ?? 0}`);
      }
```

- [ ] **Step 5: 重写 `buildFormulaPage`（整个方法替换）**

把从 `public buildFormulaPage(currentPage: number, pageSize: number):` 到它闭合的 `}`（约 882–940 行，含方法上方那段 JSDoc）**整体替换**为：

```ts
  /**
   * 用目录 + 元数据索引在设备端拼出 Formulae 首页。**拿不到目录时返回 undefined**（UI 走空态）。
   *
   * 两条路径（判据见 `BREW_INDEX_MIN_TRUST`）：
   *
   * **主路径（索引可信）**：候选 = **目录 ∩ 索引**，首屏**一个单条请求都不发**。
   * 索引是从 `formula.json`（上游"存在性"的权威清单）抽出来的，它没有的 token 就是上游没有的
   * —— 已经知道答案就不该再逐条去问。改动前这里会对"目录里有、`formula.json` 里没有"的
   * 93 个 token 逐条 hydrate，实测**全部 404**（`dl=0`），却占掉冷启动 96% 的时间（真机两轮
   * 17.7s / 18.8s，其中 16.5s 在这里）。详见 `docs/superpowers/specs/2026-09-22-brew-coldstart-design.md` §2。
   *
   * **降级路径（索引不可信）**：退化成「前 `BREW_BROWSE_HYDRATE_LIMIT` 个 + 逐条 hydrate」，
   * 与改动前**逐字相同** —— 那种情况下 `desc` 只能一条一条拉，瓶颈就在请求预算上。
   *
   * 为什么主路径不再 hydrate 也不会漏掉新包：`BrewMetaSync` 每次进程启动都在后台重拉全量
   * 索引（约 21.7s），而页面在 0.7s 就构建完了；`descOf()` 读的是内存里的当前索引，所以
   * 新包在**下一次构页**（重进页签）就会出现。这是需求方已接受的 stale-while-revalidate。
   *
   * 这一层不缓存"拼好的页面"：目录或分类口径一变，缓存会挡住新结果（Discover 吃过这个亏）。
   */
  public buildFormulaPage(currentPage: number, pageSize: number):
    Promise<BrewPageData<BrewFormulaPageData> | undefined> {
    // 同一页会被构建两次（见 formulaPageInFlight 的注释）—— 复用第一次的 Promise
    const pending: Promise<BrewPageData<BrewFormulaPageData> | undefined> | undefined =
      BrewService.formulaPageInFlight;
    if (pending !== undefined) {
      Logger.info(TAG, 'formula page build joined in-flight');
      return pending;
    }
    const tStart: number = Date.now();
    const catalog: BrewCatalog | undefined = BrewService.ensureCatalog();
    const tCatalog: number = Date.now();
    if (BREW_DATA_SOURCE !== BrewDataSource.REMOTE || catalog === undefined) {
      return Promise.resolve(undefined);
    }
    const all: CatalogEntry[] = BrewService.browseRows(catalog, BrewKindText.FORMULA);
    const descIndex: Record<string, string> = BrewMetaSync.descOf(BrewKindText.FORMULA);
    const tIndex: number = Date.now();
    const covered: number = all.filter((row: CatalogEntry) => descIndex[row.token] !== undefined).length;
    const trusted: boolean = covered >= BREW_INDEX_MIN_TRUST;
    // 主路径：目录 ∩ 索引（索引可信时它没有的 token 就是上游没有的）
    // 降级路径：前 N 个（请求预算），与改动前逐字相同
    const candidates: CatalogEntry[] = trusted ?
      all.filter((row: CatalogEntry) => descIndex[row.token] !== undefined) :
      all.slice(0, BREW_BROWSE_HYDRATE_LIMIT);
    // **主路径显式短路**，不是"过滤完再让 splitMissing 过滤一遍"：后者结果碰巧也是空，
    // 但意图错，而且将来一改就漏（见 spec §5.2）。
    const split: MissingSplit = trusted ?
      { tokens: [], ghosts: 0 } :
      BrewService.splitMissing(candidates, descIndex, BrewKindText.FORMULA);
    const missing: string[] = split.tokens;
    /** 目录里有、索引里没有的条数。两种成因（上游幽灵 / cask 的 `desc: null`），日志读法见 spec §7 */
    const dropped: number = all.length - covered;
    const tSplit: number = Date.now();
    const docsPromise: Promise<Record<string, LiveFormulaDoc>> = missing.length > 0 ?
      this.hydrateFormulaDocs(missing, BREW_BROWSE_HYDRATE_MS) :
      Promise.resolve<Record<string, LiveFormulaDoc>>({});
    const task: Promise<BrewPageData<BrewFormulaPageData> | undefined> = docsPromise
      .then((docs: Record<string, LiveFormulaDoc>) => {
        // “能上屏”的判据是**有可展示文案**，不是“字段存在”：`desc` 可能是 null/空串。
        const ready: CatalogEntry[] = candidates.filter((row: CatalogEntry) =>
          BrewBrowseBuilder.descOf(row.token, descIndex, docs[row.token]?.desc).length > 0);
        // 降级路径专用：拉到文档但上游没 desc（cask 实测有 2,645 条 `desc: null`）→ 对浏览页
        // 等同于“没有”：也记进负缓存，否则每轮重绘都拿这 100 个占掉 hydrate 预算。
        // 取数失败（doc 为 undefined）**不记**：那是“这次没拿到”，不是“上游没有”。
        // 主路径下 `missing` 是空数组，这段自然空转。
        missing.forEach((token: string) => {
          const doc: LiveFormulaDoc | undefined = docs[token];
          if (doc !== undefined && BrewService.descLen(descIndex, token, doc.desc) === 0) {
            BrewService.markMissing(`${BrewKindText.FORMULA}_${token}`);
          }
        });
        const page: BrewPageData<BrewFormulaPageData> =
          BrewBrowseBuilder.formulaPage(ready, docs, descIndex, FORMULA_CATEGORY_ORDER, pageSize);
        // 分母刻意是 `all.length`（目录全量）而不是 `candidates.length`：
        // `ready/catalog` 才是"这次上屏了多少 / 目录一共有多少"的读数，跨改动可比（spec §9.1 V4）。
        Logger.info(TAG, `browse formula built, ${ready.length}/${all.length} tokens ready ` +
          `(catalog ${all.length}, index ${covered}, dropped ${dropped}, hydrate ${missing.length}` +
          BrewService.ghostSuffix(split) + `, trusted=${trusted}), ` +
          `${page.data.cardData.length} cards, ${BrewService.browseEntryCount(page.data.cardData)} entries, ` +
          `${Date.now() - tStart}ms` + BrewService.perfSuffix(tStart, tCatalog, tIndex, tSplit) + ` | ` +
          BrewService.cardDistLine(page.data.cardData.map(
            (card: BrewCategoryCard) => [card.categoryKey, card.itemCount])) +
          ` | ${BrewService.statsLine()}`);
        return page;
      });
    // 两个分支都要清空在途字段：漏了失败分支就会把那个已 reject 的 Promise 永久留在字段里，
    // 后续每次构页都拿到它 → 页面永久失败态，直到重启 App（比改动前更糟）。
    const tracked: Promise<BrewPageData<BrewFormulaPageData> | undefined> = task.then(
      (page: BrewPageData<BrewFormulaPageData> | undefined) => {
        BrewService.formulaPageInFlight = undefined;
        return page;
      },
      (error: Error) => {
        BrewService.formulaPageInFlight = undefined;
        throw error;
      });
    BrewService.formulaPageInFlight = tracked;
    return tracked;
  }
```

---

## Task 3: `buildCaskPage` —— 同上

**Files:**
- Modify: `features/brewcommon/src/main/ets/service/BrewService.ets`

**Interfaces:**
- Consumes: `BrewService.caskPageInFlight`（Task 2 Step 2 已建）、`BrewService.perfSuffix`（Task 2 Step 3）、`BREW_INDEX_MIN_TRUST`

- [ ] **Step 1: 重写 `buildCaskPage`（整个方法替换，含上方那行 JSDoc）**

把：
```ts
  /** 同 `buildFormulaPage`（cask 的卡片是「分类 -> 卡 -> 条目」三层） */
  public buildCaskPage(currentPage: number, pageSize: number):
    Promise<BrewPageData<BrewCaskPageData> | undefined> {
```
到它闭合的 `}` 整体替换为：

```ts
  /**
   * 同 `buildFormulaPage`（cask 的卡片是「分类 -> 卡 -> 条目」三层）。
   *
   * cask 的 `dropped` 会明显大于 formula，**这是预期的**：`cask.json` 有 2,645 条
   * `desc: null`，落盘索引时故意不写空串，所以那些 token 永远不在索引里。改动前它们
   * 每轮都要被 hydrate 一遍（拿到 doc 但 desc 为空，才 `markMissing`）；主路径不再发这批请求，
   * 所以 cask 的收益预计比 formula 更大。**不要把这个数字当 bug 修**（spec §7）。
   */
  public buildCaskPage(currentPage: number, pageSize: number):
    Promise<BrewPageData<BrewCaskPageData> | undefined> {
    const pending: Promise<BrewPageData<BrewCaskPageData> | undefined> | undefined =
      BrewService.caskPageInFlight;
    if (pending !== undefined) {
      Logger.info(TAG, 'cask page build joined in-flight');
      return pending;
    }
    const tStart: number = Date.now();
    const catalog: BrewCatalog | undefined = BrewService.ensureCatalog();
    const tCatalog: number = Date.now();
    if (BREW_DATA_SOURCE !== BrewDataSource.REMOTE || catalog === undefined) {
      return Promise.resolve(undefined);
    }
    const all: CatalogEntry[] = BrewService.browseRows(catalog, BrewKindText.CASK);
    const descIndex: Record<string, string> = BrewMetaSync.descOf(BrewKindText.CASK);
    const tIndex: number = Date.now();
    const covered: number = all.filter((row: CatalogEntry) => descIndex[row.token] !== undefined).length;
    const trusted: boolean = covered >= BREW_INDEX_MIN_TRUST;
    const candidates: CatalogEntry[] = trusted ?
      all.filter((row: CatalogEntry) => descIndex[row.token] !== undefined) :
      all.slice(0, BREW_BROWSE_HYDRATE_LIMIT);
    const split: MissingSplit = trusted ?
      { tokens: [], ghosts: 0 } :
      BrewService.splitMissing(candidates, descIndex, BrewKindText.CASK);
    const missing: string[] = split.tokens;
    const dropped: number = all.length - covered;
    const tSplit: number = Date.now();
    const docsPromise: Promise<Record<string, LiveCaskDoc>> = missing.length > 0 ?
      this.hydrateCaskDocs(missing, BREW_BROWSE_HYDRATE_MS) :
      Promise.resolve<Record<string, LiveCaskDoc>>({});
    const task: Promise<BrewPageData<BrewCaskPageData> | undefined> = docsPromise
      .then((docs: Record<string, LiveCaskDoc>) => {
        const ready: CatalogEntry[] = candidates.filter((row: CatalogEntry) =>
          BrewBrowseBuilder.descOf(row.token, descIndex, docs[row.token]?.desc).length > 0);
        // 同上：cask 上游大量 `desc: null`，记进负缓存后不会每轮都占住 hydrate 预算
        missing.forEach((token: string) => {
          const doc: LiveCaskDoc | undefined = docs[token];
          if (doc !== undefined && BrewService.descLen(descIndex, token, doc.desc) === 0) {
            BrewService.markMissing(`${BrewKindText.CASK}_${token}`);
          }
        });
        const page: BrewPageData<BrewCaskPageData> = BrewBrowseBuilder.caskPage(ready, docs, descIndex,
          CASK_CATEGORY_ORDER, BrewService.caskCategoryNames(CASK_CATEGORY_ORDER), pageSize);
        Logger.info(TAG, `browse cask built, ${ready.length}/${all.length} tokens ready ` +
          `(catalog ${all.length}, index ${covered}, dropped ${dropped}, hydrate ${missing.length}` +
          BrewService.ghostSuffix(split) + `, trusted=${trusted}), ` +
          `${page.data.caskCategories.length} categories, ${Date.now() - tStart}ms` +
          BrewService.perfSuffix(tStart, tCatalog, tIndex, tSplit) + ` | ` +
          BrewService.cardDistLine(page.data.caskCategories.map((category: BrewCaskCategory) =>
            [category.categoryKey, BrewService.caskContentsOf(category).length] as [string, number])) +
          ` | ${BrewService.statsLine()}`);
        return page;
      });
    const tracked: Promise<BrewPageData<BrewCaskPageData> | undefined> = task.then(
      (page: BrewPageData<BrewCaskPageData> | undefined) => {
        BrewService.caskPageInFlight = undefined;
        return page;
      },
      (error: Error) => {
        BrewService.caskPageInFlight = undefined;
        throw error;
      });
    BrewService.caskPageInFlight = tracked;
    return tracked;
  }
```

- [ ] **Step 2: 编译自检**

```bash
cd /storage/Users/currentUser/Documents/DevEcoStudioProjects/sample_in_harmonyos && devecocli build 2>&1 | tail -8
```
Expected: `BUILD SUCCESSFUL`。若报 `currentPage` 未使用之类**不要**删参数（`buildFormulaPage` 原先也没用它，签名由调用方约定）。

---

## Task 4: 探针收进开关

**Files:**
- Modify: `features/brewcommon/src/main/ets/service/BrewMetaSync.ets`
- Modify: `features/brewcommon/src/main/ets/service/BrewBrowseBuilder.ets`
- Modify: `features/brewcommon/src/main/ets/constant/BrewConstants.ets`（已在 Task 1 完成 `BREW_PERF_TRACE`）

**Interfaces:**
- Consumes: `BREW_PERF_TRACE`（Task 1）

- [ ] **Step 1: `BrewMetaSync.ets` —— 把 `ensureIndex` 的探针包进开关**

在 `BREW_META_SYNC,` 之后（约 44 行）给导入块加 `BREW_PERF_TRACE,`（保持字母序位置：放在 `BREW_META_VERIFY,` 之后）。

然后把 `ensureIndex()` 里的：
```ts
      // [perf-probe] 这一段是主线程 `getSync` + `JSON.parse`（索引约 1MB），
      // 它此前完全不在 `browse … built` 的计时区间内 —— 先把它量出来。
      const t0: number = Date.now();
      const stored: BrewMetaIndex | null =
        PreferenceManager.getInstance().getValue<BrewMetaIndex>(BREW_META_INDEX_KEY);
      const readMs: number = Date.now() - t0;
```
改成：
```ts
      // [perf] 这一段是主线程 `getSync` + `JSON.parse`（索引约 1MB）。实测只有 17ms ——
      // 它此前完全不在 `browse … built` 的计时区间内，所以历史日志里的 ms 一直是低估的。
      const t0: number = Date.now();
      const stored: BrewMetaIndex | null =
        PreferenceManager.getInstance().getValue<BrewMetaIndex>(BREW_META_INDEX_KEY);
      const readMs: number = Date.now() - t0;
```
并把紧随其后的那行：
```ts
      Logger.info(TAG, `[perf-probe] meta index pref read+parse ts=${t0} readMs=${readMs} ` +
        `formula=${Object.keys(BrewMetaSync.index.formula).length} cask=${Object.keys(BrewMetaSync.index.cask).length}`);
```
改成：
```ts
      if (BREW_PERF_TRACE) {
        Logger.info(TAG, `[perf] meta index pref read+parse ts=${t0} readMs=${readMs} ` +
          `formula=${Object.keys(BrewMetaSync.index.formula).length} ` +
          `cask=${Object.keys(BrewMetaSync.index.cask).length}`);
      }
```

- [ ] **Step 2: `BrewBrowseBuilder.ets` —— 两个探针包进开关**

在导入块加 `import { BREW_CATEGORY_PREVIEW_COUNT, BREW_PERF_TRACE } from '../constant/BrewConstants';`（把现有的单名导入改成这个名字导入）。

把 `formulaPage` 里的：
```ts
    Logger.info(TAG, `[perf-probe] formulaPage rows=${rows.length} groupMs=${tGroup - t0} ` +
      `cardMs=${Date.now() - tGroup} cards=${cards.length}`);
```
改成：
```ts
    if (BREW_PERF_TRACE) {
      Logger.info(TAG, `[perf] formulaPage rows=${rows.length} groupMs=${tGroup - t0} ` +
        `cardMs=${Date.now() - tGroup} cards=${cards.length}`);
    }
```
`caskPage` 里同款（`categories=${categories.length}` 那行）。

同时把两处 `// [perf-probe] …` 的行内注释改成 `// [perf] …`，并把 `const t0` / `const tGroup` 的注释说明保留（它们即使开关关掉也只是两次 `Date.now()`，不必条件化 —— 条件化反而会让代码分叉）。

- [ ] **Step 3: `BrewFormulaHomeViewModel.ets` —— 撤掉探针**

把：
```ts
        Logger.info(TAG, `loadFormulaPage success, ${cards.length} category cards ` +
          `[perf-probe] stateSet ts=${Date.now()}`);
```
改回：
```ts
        Logger.info(TAG, `loadFormulaPage success, ${cards.length} category cards`);
```
理由：这一行的 **hilog 时间戳本身就是"数据进 state"的时刻**，做差不需要应用层再打一个 epoch（spec §2.1 已按这个口径量过）。留着 `ts=` 只是噪声。

- [ ] **Step 4: `PcAbility.ets` —— 把探针换成与文件风格一致的生命周期日志**

把：
```ts
    // [perf-probe] 冷启动锚点：绝对 epoch ms，与各层 perf 行的时间戳对减即可得分段耗时。
    // 临时探针，测完删除（见 docs/brew-coldstart-*）。
    Logger.info(TAG, `[perf-probe] ability onCreate ts=${Date.now()}`);
    AppStorage.setOrCreate<boolean>(StorageKey.IS_SIDEBAR_LAYOUT, true);
```
改成：
```ts
    Logger.info(TAG, 'Ability onCreate');
    AppStorage.setOrCreate<boolean>(StorageKey.IS_SIDEBAR_LAYOUT, true);
```
并把：
```ts
    Logger.info(TAG, `[perf-probe] windowStageCreate ts=${Date.now()}`);
```
改成：
```ts
    Logger.info(TAG, 'Ability onWindowStageCreate');
```
理由：这个文件里其它生命周期回调都有一行 `Logger.info(TAG, 'Ability onXxx')`（`onDestroy` / `onForeground` / `onBackground` / `onWindowStageDestroy`），而 `onCreate` / `onWindowStageCreate` **恰好缺** —— 补上它们是**与现有风格一致**的改动，顺带成为永久可用的冷启动锚点。**不要**为它引入 `BREW_PERF_TRACE`：那会让 `products/pc` 依赖 `@ohos/brewcommon`，把整个 brew 数据层拉进 Ability（正是 spec §1.2 列为"后续"的 import 问题）。

- [ ] **Step 5: 编译自检**

```bash
cd /storage/Users/currentUser/Documents/DevEcoStudioProjects/sample_in_harmonyos && devecocli build 2>&1 | tail -8
```
Expected: `BUILD SUCCESSFUL`，且 `grep -rn "perf-probe" --include=*.ets .` **无输出**。

---

## Task 5: `DEFAULT_TAB` 还原

**Files:**
- Modify: `features/abilitycommon/src/main/ets/model/TabBarModel.ets`

- [ ] **Step 1: 还原**

把：
```ts
// [perf-probe] 临时把默认页从 DISCOVER 改成 FORMULAE：冷启动即加载目标页签，
// 才能量到「进程启动 → Formulae 首屏可见」。测完改回 TabBarType.DISCOVER。
export const DEFAULT_TAB: TabBarType = TabBarType.FORMULAE;
```
改回：
```ts
export const DEFAULT_TAB: TabBarType = TabBarType.DISCOVER;
```

> ⚠ **顺序**：`DEFAULT_TAB` 必须先指到 `CASK` 跑完 spec §9.1 的 V7（补量 cask），再执行这一步。若执行者拿到本 plan 时 V7 尚未做，**先做 V7 再改这一行**，并把 V7 的原始日志附在交付里。

---

## Task 6: 文档同步

**Files:**
- Modify: `docs/brew-api-design.md`
- Modify: `docs/brew-catalog-fullsync-spec.md`
- Modify: `docs/brew-handover.md`

- [ ] **Step 1: `docs/brew-catalog-fullsync-spec.md` —— §4.4 的"补位"语义收紧**

把 §4.4 表格里的这一行：
```markdown
| index 里没有（新包 / 同步未完成 / 同步失败） | 回落到现有逐条 hydrate（预算与并发不变），结果回写 index（增量补齐） |
```
改成：
```markdown
| index 里没有（新包 / 同步未完成 / 同步失败） | **仅在索引不可信时**（`covered < BREW_INDEX_MIN_TRUST`）回落逐条 hydrate；索引可信时直接不上屏，等下一次构页（详见 `2026-09-22-brew-coldstart-design.md` §5） |
```
并在 §4.4 表格上方补一句：
```markdown
> **2026-09-22 修订**：主路径的判据从"`covered > 0`"收紧为"`covered >= BREW_INDEX_MIN_TRUST` 才走索引优先"，
> 且索引可信时**不再为索引里没有的 token 发单条请求**。原因是实测那批 token 全部 404（`dl=0`）却占掉冷启动 96% 的时间。
> 见 `2026-09-22-brew-coldstart-design.md` §2。
```

- [ ] **Step 2: `docs/brew-api-design.md` —— 加「hydrate 触发点」表 + 日志字段读法**

在讲 `BrewService` 的那一节（约 236 行附近，`| service/BrewService.ets | 单条拉取 + TTL 缓存 + 并发受限的批量 hydrate |` 所在的表格之后）插入：

```markdown
#### hydrate 的全部触发点（2026-09-22 清点）

| 层 | 调用点 | 触发条件 |
|---|---|---|
| 批量 | `BrewService.buildFormulaPage` / `buildCaskPage`（浏览页首页 **+ 分类二级页**，二级页复用 `getFormulaPage`） | **仅当索引不可信**（`covered < BREW_INDEX_MIN_TRUST`）：`missing = 前 BREW_BROWSE_HYDRATE_LIMIT 个 ∩ token ∉ 索引`，再剔除 `missCache` 幽灵 |
| 批量 | `BrewRepository.hydratePage`（Discover 首页 + 榜单二级页） | `BREW_DATA_SOURCE === REMOTE` 且 `page.boards` 非空 → 6 张榜的全部成员 |
| 单条 | `BrewRepository.getFormulaDetail` / `getCaskDetail` | 详情页主体，1 个 token |
| **间接** | `BrewRepository.getSameCategoryPackages`（详情页「同分类其他包」） | → `getCategoryPackages` → `getFormulaCategories` → `getFormulaPage` → **整页 hydrate**（§9.13 记过这个坑） |

**不触发 hydrate 的**：搜索（`BrewSearchEngine` 只读目录 + 索引，零请求）、Mine 的本机包（读 rawfile）、索引覆盖的浏览条目。

#### `browse … built` 行的三个新字段（读法）

```
browse formula built, 7299/7392 tokens ready (catalog 7392, index 7299, dropped 93, hydrate 0, trusted=true), …
```

| 字段 | 含义 | 什么时候该警觉 |
|---|---|---|
| `ready/catalog` | 上屏条数 / 目录全量。**分母是目录全量**（不是候选集），跨改动可比 | — |
| `index` | 索引覆盖的目录行数 | 突然变小 → 元数据同步没成功或扫描口径变了 |
| `dropped` | `catalog − index`：目录里不在索引里的 token 数。**两种成因**：上游幽灵（`formula.json` 里没有）与 cask 的 `desc: null`（落盘故意不写空串） | formula 从 ~93 持续变大 → 可能上游开始漏包；**cask ≈2645 是正常的，不要当 bug 修** |
| `hydrate` | 本次发出的单条请求数。**主路径应恒为 0** | 非 0 → 闸门没生效 |
| `trusted` | 走的是主路径（`true`）还是降级路径（`false`） | 期望恒为 `true`；`false` 且页面很慢 → 索引不可信，去看 `[BrewMetaSync] meta sync` 那几行 |
```

- [ ] **Step 3: `docs/brew-handover.md` —— §5.3 的数字换成实测**

把 §5.3 表格里的这一行：
```markdown
| 浏览页冷启动代价 | 100 条单条（现网前 100）× 约 1.2 KB ≈ **120 KB**；实测 2.7~7.4s（并发 6），之后 TTL 缓存命中 5~150ms |
```
改成：
```markdown
| 浏览页冷启动代价 | ~~100 条单条 × 1.2 KB，实测 2.7~7.4s~~ → **2026-09-22 实测 17.7s / 18.8s**（两轮），其中 **16.5s（96%）** 花在 93 个**必然 404** 的逐条 hydrate 上（`dl=0`，一条也没上屏）。根因与修法见 `docs/superpowers/specs/2026-09-22-brew-coldstart-design.md` §2 / §5 |
| 主线程 `JSON.parse` 的代价（易被高估） | 索引 1 MB = **17ms**、目录 550 KB = **19~22ms**、7500 条分类 = **396~420ms**。所以"瓶颈在 I/O"这个直觉是错的 —— 别再从"换存储/加硬盘缓存"入手 |
```

- [ ] **Step 4: `docs/brew-handover.md` —— §8.2 待办表加三条后续**

在 §8.2 表格末尾追加：
```markdown
| **分类结果落盘** | 每次构页主线程分类 7500 条 = 420ms。要再压就得把 `token → categoryKey` 并进元数据索引，代价是需要**词表版本失效机制**（`BrewTaxonomy` 随版本走）。**触发条件**：首屏进 1100ms 以内后还想再压 |
| **`import lazy` / 桶文件收敛** | `brewcommon/Index.ets` 24 条 export（含 1163 行的 `BrewService`），`SplashViewModel` 从它取符号 → 闪屏拉起整个 brew 数据层。**这是官方点名的冷启动项，但本轮未量到耗时，不凭"官方说重要"改结构**。触发条件：用 DevEco 的 AppAnalyzer 量出未使用 import 的实际耗时 |
| **元数据同步加 HEAD 探针** | 每次进程启动后台重拉 `formula.json`(32.4MB)+`cask.json`(18.9MB)，2 请求 + 21.7s + 一次 32MB 扫描，与首帧抢 CPU/网络。`brew-catalog-fullsync-spec.md` §4.2 已列为可选优化。触发条件：量出它确实影响首帧 |
```

- [ ] **Step 5: 文档自检**

```bash
cd /storage/Users/currentUser/Documents/DevEcoStudioProjects/sample_in_harmonyos && \
grep -c "BREW_INDEX_MIN_TRUST" docs/brew-catalog-fullsync-spec.md docs/brew-api-design.md docs/brew-handover.md
```
Expected: 三个文件都 ≥1（若某文件为 0，说明该处编辑漏了）。

---

## Task 7: 构建与静态验证（执行者交付前必须全绿）

- [ ] **Step 1: 全量构建**

```bash
cd /storage/Users/currentUser/Documents/DevEcoStudioProjects/sample_in_harmonyos && devecocli build 2>&1 | tail -25
```
Expected: `BUILD SUCCESSFUL`，且**没有**新增的 `ERROR`。已有的两条 `devpractices/.../ImagePreview.ets` WARN 与本次无关。

- [ ] **Step 2: 确认探针已清干净**

```bash
cd /storage/Users/currentUser/Documents/DevEcoStudioProjects/sample_in_harmonyos && \
grep -rn "perf-probe" --include=*.ets . ; echo "---"; \
grep -rn "BREW_PERF_TRACE" --include=*.ets features/brewcommon/src/main/ets | sed 's/^/  /'
```
Expected: 第一条**无输出**；第二条出现 1 处定义（`BrewConstants.ets`）+ 3 个使用文件（`BrewService.ets`×2、`BrewMetaSync.ets`、`BrewBrowseBuilder.ets`×2）。

- [ ] **Step 3: 确认没有新增落盘 key**

```bash
cd /storage/Users/currentUser/Documents/DevEcoStudioProjects/sample_in_harmonyos && \
git diff -- features/brewcommon/src/main/ets/service/BrewService.ets features/brewcommon/src/main/ets/service/BrewMetaSync.ets | grep -n "setValue" ; echo "(无输出 = 没有新增写盘)"
```

- [ ] **Step 4: 确认主路径真的短路（静态读一遍）**

```bash
cd /storage/Users/currentUser/Documents/DevEcoStudioProjects/sample_in_harmonyos && \
grep -n "trusted ?" -A 3 features/brewcommon/src/main/ets/service/BrewService.ets | sed 's/^/  /'
```
Expected: 两个 build 方法各有两处 `trusted ?` —— 一处选 `candidates`，一处给 `split` 直接 `{ tokens: [], ghosts: 0 }`。

- [ ] **Step 5: 交付物清单（写进交付说明）**

- [ ] `devecocli build` 的完整尾部输出（含 `BUILD SUCCESSFUL` 行）
- [ ] Step 2/3/4 的三条命令及其原始输出
- [ ] `git diff --stat` 的全量改动清单
- [ ] V7（cask 实测）的原始日志行 —— **若未做，明确写"未做"**，不要声称 cask 的收益

> **不要**声称"首屏已降到 X ms"。真机冷启动测量（spec §9.1 的 V2–V9）由 review 之后单独做，因为要反复装机 + 抓 `--follow` 日志。

---

## 真机验证（执行者**不做**，留给 review 之后）

| # | 动作 | 判据 |
|---|---|---|
| V2 | 两轮冷启动：`devecocli log --follow > .brewgen/cold-new-N.log &` → `devecocli run --device 127.0.0.1:42021 --skip-build` → 等 45s → kill | `loadFormulaPage success` 的 hilog 时间戳 − `Ability onCreate` 的 hilog 时间戳 **≤1100ms**，两轮一致 |
| V3 | 同轮日志 | `browse formula built` 行含 `hydrate 0`、`trusted=true`；`statsLine()` 的 `failed` 增量 **0** |
| V4 | **G3 输出不变**（主判据与目录快照无关） | `ready_新 == index_旧`（**7299**）且 `dropped_新 == catalog_旧 − index_旧`（**93**）；次判据：同一次目录 TTL 窗口内（`catalog loaded, age=Ns` 的 age 差 <3600s）`dist` 逐字相同 |
| V5 | `devecocli log --crash --from 5m` | 无崩溃 |
| V6 | `devecocli ui screenshot` | 9 张分类卡渲染正常 |
| V7 | 把 `DEFAULT_TAB` 临时指到 `CASK` 再跑一轮 | `browse cask built` 的 `dropped`（预期 ≈2645）/ `hydrate 0` / 首屏 ms |
| V8 | `devecocli run --uninstall` 后首次启动 | 不崩、不白屏；`trusted=false` 时仍走前 100 + hydrate |
| V9 | `devecocli ui layout --mode full` | 卡片头部（分类图标 + 中英文名 + 包数）与改动前一致 |
