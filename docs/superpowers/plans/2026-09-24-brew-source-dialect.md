# Harmonybrew 数据源方言适配 · 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让应用能添加并使用 **Harmonybrew 分支**（`https://harmonybrew.atomgit.com/api`）作为数据源 —— 它的 API 形状与上游 Homebrew 不同（单文件、字典键、Ruby DSL 参数原样序列化、无 per-token 端点、无 cask、无 analytics），需要在应用内做方言适配与字段映射。

**Architecture:** 在 `BrewHttp` / `BrewSourceUrl` 之上引入 **transport 级 adapter 接缝**：每个方言一个实现，向上提供 `probe` / `fetchCatalog` / `fetchDoc` 三个能力，**返回的 doc 已归一化成现有的 `LiveFormulaDoc` 形状**。于是 `BrewApiMapper`、TTL 缓存、在途去重、世代号守卫、多源隔离**全部不动**。方言选择自动识别（探测时判定）+ 手动覆盖，存在 `BrewSource.dialect` 里。

**Tech Stack:** HarmonyOS NEXT / ArkTS / ArkUI、`@ohos.data.preferences`（GSKV）、`@kit.NetworkKit`、`@kit.CoreFileKit`（fileIo）、hvigor + devecocli。

**前置调研文档：** 本计划 §1 的实测数据是本计划的全部事实基础；结论同时应回写到 `docs/brew-api-design.md`（Task 10）。

---

## Global Constraints

- **不做** Node 测试、**不做** `ohosTest`（handover §9.3）。每个任务的验证环 = `devecocli build` 编译 + 判据日志 +（必要时）真机点击。
- **不改** `common` 模块的任何文件。
- **不改** 六条缓存键的名字与数据形状：`brew_live_data` / `brew_live_dataset` / `brew_catalog` / `brew_meta_index` / `brew_meta_stamp` / `brew_detail_page_data`。
- **不引入** 本地 HTTP server。理由见 §3.5（决策记录）。
- 所有新代码必须过 ArkTS 语法：不用 `any` / `var` / 解构赋值 / `for..in`；对象字面量只能赋给已声明的 interface/class 类型；**无类型对象字面量不能作为实参传出去**（`arkts-no-untyped-obj-literals`）；`Record<string, T>` 一律「先声明再逐字段赋值」，不写字面量。
- 模板字符串里**禁止**把 `${…}` 拆到以 `` ` `` 结尾的下一行。跨行插值先把值算成局部变量再插。
- **ArkTS 不支持函数重载**：同作用域内两个同名函数会报 `Duplicate function implementation`，需要时改名。
- `Object.keys` 不能直接作用于 `Object` 类型 → 走 `features/brewcommon/src/main/ets/util/objkeys.ts`。
- 每轮 build 后按 handover §9.5.1 查两项：新符号在 `modules.abc` 里（`grep -c`，**不加** `^$` 锚点）、HAR 路由合并进 HAP 的 `router_map.json`。
- 提交信息用 `feat(brew):` / `fix(brew):` / `refactor(brew):` / `docs(brew):` 前缀，中文正文。
- **步骤粒度已按本项目的验证条件调整**：本项目没有自动化测试，所以不存在「写测试 → 看它失败 → 实现 → 看它通过」这个循环。每个步骤是**一个可独立完成的产出**，任务末尾固定是「编译 + 真机日志对账 + 提交」。计划里给出的代码块是**可直接落地的完整实现**，不是伪代码。

---

## 1. 调研结论（本计划的事实基础，全部为实测）

### 1.1 端点对照：应用要 10 个，Harmonybrew 只有 1 个

| 用途 | 应用请求的路径 | Harmonybrew |
|---|---|---|
| 探测 | `GET /formula/wget.json` | **404** ← 今天卡在这一步 |
| 全量索引 | `GET /formula.json`、`GET /cask.json` | **404** |
| 单条详情 | `GET /formula/<token>.json`、`GET /cask/<token>.json` | **404** |
| 排行/安装量 | 4× `GET /analytics/…/30d\|365d.json` | **404** |
| — | — | `GET /internal/packages.arm64_ohos.jws.json` ← 唯一存在的端点 |

今天的实际表现：粘 `https://harmonybrew.atomgit.com/api` 进去 → 探测 404 → 界面 `连接失败：该地址没有 /api 数据` + `HTTP 状态码：404`（`BrewSourceProbe.ets:64` → `http-404` → `brew_source_probe_404`）。URL 格式校验本身是**通过**的，不是输入问题。

### 1.2 服务端响应头能力（决定了取数与缓存设计）

| 能力 | 实测 | 影响 |
|---|---|---|
| `HEAD` | `200` + `Content-Length` + `ETag` + `Last-Modified` | 可用于探测 |
| `Range` | `206` + `Content-Range: bytes 0-999/3973524` | 可用于按字节切片（本计划**暂不用**，见 §3.4） |
| `If-None-Match`（ETag） | **`304`** | 条件请求可行 |
| `If-Modified-Since` | **不生效**（仍回 `200` + 全量 body） | ⚠ 与上游相反，必须用 ETag |
| `Accept-Encoding: gzip` | **不支持**（无 `Content-Encoding` 响应头） | 每次都是 3.97MB 明文 |
| `Content-Type` | `application/json` | 形状校验可用 |

### 1.3 数据形状：字段只重合 7/32

`packages.arm64_ohos.jws.json`（3,973,524 B，**单行**）是 JWS，目录在 `payload` 字段里、是**被转义的 JSON 字符串**：

```
{"payload":"{\"metadata\":{\"homebrew_version\":\"7.0.6_2\",\"bottle_tag\":\"arm64_ohos\",…},\"formulae\":{\"aamath\":{…}},\"casks\":{},…}","signature":"…"}
```

解包后：`formulae` 是**以 token 为键的字典**（4761 条），`casks` **恒为空**（`len=0`），`token` / `name` 都不在值里。

字段对账（4761 条的字段并集 33 个）：

- 应用需要 32 个，**只重合 7 个**：`aliases` `caveats` `desc` `executables` `homepage` `license` `versioned_formulae`
- **缺 25 个**：`token` `name` `full_name` `tap` `versions` `bottle` `dependencies` `build_dependencies` `optional_dependencies` `recommended_dependencies` `uses_from_macos` `analytics` `keg_only` `keg_only_reason` `deprecated` `deprecation_*` `disabled` `disable_*` `service` `requirements` `conflicts_with`
- **多 26 个**，其中一批是 **Ruby DSL 调用参数的原样序列化**（`stable_url_args` / `keg_only_args` / `deprecate_args` / `disable_args` / `service_run_args` / `stable_dependencies` / `stable_uses_from_macos` / `conflicts` …），**必须反解**，不是改名就行。

### 1.4 单条 doc 只有 ~700B（这条改变了详情取数的可行性）

payload 解码后 3,659,172 B / 4761 条 → **中位 703 B，最大 5,663 B**，全量落盘约 **3.4 MB**。

对比：上游 `formula.json` 是 32.4MB、单条 doc ~5KB，`BrewMetaSync` 的文件头注释明确写了「落盘只存 desc，整份 doc 要 65MB，不可接受」。**那个约束对本方言不成立**（3.4MB vs 65MB，差 19 倍）。

### 1.5 服务端还发布了一个**未转义**的 `packages.arm64_ohos.json` —— 但已陈旧 86 天，不要用

| 文件 | `Last-Modified` | `metadata.homebrew_version` | `generated_at` |
|---|---|---|---|
| `packages.arm64_ohos.json`（3,591,130 B，**无 JWS 包装**） | **Tue, 30 Jun 2026** | `6.0.6_3-dirty` | 1782803170 |
| `packages.arm64_ohos.jws.json`（3,973,524 B） | **Thu, 24 Sep 2026** | `7.0.6_2` | 1790238276 |

未转义版是**旧发布流程的遗留物，已停止更新**。用它实现更简单（不用处理 `\"`），但会静默拿到三个月前的数据 —— **必须用 `.jws.json`**。

### 1.6 字段映射的 ground truth：用 fork 自己的规范化器交叉验证

`brew info --json=v2 <token>`（本机 Harmonybrew 7.0.2_1）输出的是**上游形状**（58 个字段，含 `versions` / `bottle.stable.files[tag].url` / `dependencies` / `keg_only_reason` …）。它内部就是 `FormulaStruct#to_hash`，即 **fork 自己认可的映射规则**。§4 的映射表逐条对照过它，以下是三个**光看原始数据猜不到**的规则：

| 陷阱 | 原始数据 | `brew info` 的规范结果 | 规则 |
|---|---|---|---|
| **`keg_only` 依赖平台** | `apr` 的 `keg_only_args = [":provided_by_macos", "Apple's CLT provides apr"]` | `keg_only: **false**`（但 `keg_only_reason` 非空） | `:versioned_formula` → `true`；`:provided_by_macos` / `:shadowed_by_macos` → **false**（非 macOS 不适用）。**不能按「字段存在」判真** |
| **`disabled` 依赖日期** | `access` 的 `deprecate_args {date:2024-07-07}` + `disable_args {date:2025-07-07}` | `deprecated: true`、`disabled: true` | `disabled = disable_args 存在 && today >= :date`。`disable_args` 存在**不等于**已禁用（134 条 deprecated vs 124 条 disable_args，两者都可能有未来日期） |
| **`reason` 的冒号不一致** | `deprecate_args[":because"] = ":unmaintained"`；`keg_only_args[0] = ":versioned_formula"` | `deprecation_reason: "unmaintained"`（**去冒号**）；`keg_only_reason.reason: ":versioned_formula"`（**留冒号**） | 两处规则不同，必须分别处理 |

另外两条也确认了：

- **`versions.stable` 不含 revision**：`apr` 是 `revision:1`，`brew info` 给 `versions.stable = "1.7.6"`（不是 `1.7.6_1`）。所以 `versions.stable = stable_version`，直接取。
- **bottle 文件名用 formula revision，不是 `bottle_rebuild`**（本计划不需要，但记录下来）：
  `{encodeURIComponent(name)}-{stable_version}{revision>0 ? '_'+revision : ''}.{tag}.bottle{rebuild>0 ? '.'+rebuild : ''}.tar.gz`
  实测：`wget`(rev1,rb0) → `wget-1.25.0_1.arm64_ohos.bottle.tar.gz`；`ant@1.9`(rev0) → `ant%401.9-1.9.16.arm64_ohos.bottle.tar.gz`（**`@` 被百分号编码**、**无 `_0`**）；`binutils`(rev2,rb1) → `binutils-2.47_2.arm64_ohos.bottle.1.tar.gz`。`sha256` = `bottle_checksum`（逐字一致）。
  ⚠ **应用目前不消费 bottle URL**（`BrewApiMapper.ets:318-322` 只读 `versions.bottle` / `bottle.files` 的键 / `bottle.rebuild`），所以本计划**不做 URL 合成** —— 只把 `bottle.files` 填上 tag 键。这条规则留在文档里备用。

### 1.7 应用侧不需要改的地方（已确认）

- **`installed` / `outdated` / `pinned`**：不在 `LiveFormulaDoc` 里，应用不从数据源取安装态 → 无影响。
- **`tap`**：`BrewApiMapper.installCommand`（`:651`）对 `homebrew/core` / `homebrew/cask` 之外的 tap 会拼成 `brew install <tap>/<token>`。本方言**不设 `tap`** → 安装命令是 `brew install wget`（在 Harmonybrew 上正确，因为它的默认 tap 就是 `harmonybrew/core`）。设成 `harmonybrew/core` 会显示成 `brew install harmonybrew/core/wget`，不必要。
- **bottle URL**：见上，不消费。

---

## 2. Review Focus

以下 6 类输入/条件是「编译通过」覆盖不到、最可能伤到真实用户的。每一条在对应任务里都有明确验证步骤：

1. **服务端换了 bottle tag**（例如以后发布 `arm64_ohos_v2`）—— 端点名里带 tag，写死会 404。→ **tag 必须从 payload 的 `metadata.bottle_tag` 读出来**，Task 3/5。
2. **`.jws.json` 的 `payload` 字段名或信封结构变了** —— 解包会拿到 `undefined` 而不是抛错，静默变成空目录。→ Task 3 的形状校验必须显式判 `typeof payload === 'string'`，且空目录要能被 `pairs === 0` 判据拦住。
3. **`formulae` 里某个 token 的名字在 `desc` 字符串里出现过** —— 用 `indexOf` 找 token 边界会配错位。→ Task 3 必须用**结构感知**的扫描（跟踪字符串字面量与转义），不能 `indexOf`。
4. **一个已弃用但禁用日期在未来的 formula**（如 `access` 之外的 124 条）—— 判成 `disabled: true` 会让详情页显示错误的生命周期横幅。→ Task 4 的日期比较，用 `access`（已过期）和一个未来日期样本双向验证。
5. **`keg_only_args` 只有 `:provided_by_macos`**（如 `apr` / `apr-util`）—— 判成 keg-only 会让详情页多显示一段不存在的说明。→ Task 4，用 `apr` 与 `ant@1.9` 双向验证。
6. **Harmonybrew 源被激活后用户去看 Casks / Discover** —— 两者都是空的，不能变成错误页或转圈不停。→ Task 8 的能力开关 + 空态。

---

## 3. 架构与关键决策

### 3.1 方言字段

`BrewSource` 加一个 `dialect: string`，取值 `'upstream'`（默认，含内置源）与 `'harmonybrew'`。

- 存量源没有这个字段 → `BrewSourceStore.normalizeRegistry` 补 `'upstream'`。**必须是迁移而不是默认值兜底**：注册表是 `JSON.parse` 出来的普通对象，读不到字段的地方不止一处（设置页、诊断、激活链路），逐处兜底必然漏。
- `id` / `baseUrl` 解耦的不变量不变：改 URL 仍等于换数据、仍要清缓存。

### 3.2 adapter 接缝（transport 级）

```
BrewSourceProbe ─┐
BrewMetaSync   ─┼─→ BrewSourceAdapter (按 dialect 分派)
BrewService    ─┤     ├→ UpstreamAdapter   （现有行为的原样搬迁）
BrewCatalogAlgo─┘     └→ HarmonybrewAdapter（新增）
```

三个能力，**返回的 doc 已归一化成 `LiveFormulaDoc` / `LiveCaskDoc`**：

```ts
export interface BrewSourceAdapter {
  readonly dialect: string;
  readonly supportsCasks: boolean;
  readonly supportsAnalytics: boolean;
  probe(baseUrl: string): Promise<BrewProbeResult>;
  fetchCatalog(baseUrl: string, sinceStamp: string, idKey: string): Promise<BrewCatalogResult>;
  /** 返回 BrewHttpResult 形状，让 conditionalFetch 的下游解析原样复用 */
  fetchDoc(baseUrl: string, token: string, kind: string,
    headers: Record<string, string>): Promise<BrewHttpResult>;
}
```

**为什么把接缝放在 transport 级而不是更高层**：`BrewService.getLiveDoc` 里的 TTL 缓存、在途去重、数据集探针、世代号守卫是四套已经调好的机制（`BrewService.ets:355-470`）。只要 adapter 交回 `BrewHttpResult`（`code` / `text` / `headers`），这四套全部原样复用 —— 归一化放在 adapter 内部，`BrewApiMapper` 一行不用改。

**为什么把映射放在 adapter 边界**：`BrewApiMapper` 消费的是 `LiveFormulaDoc`。让 HarmonybrewAdapter 直接产出这个形状，就把「26 个 DSL 参数字段的反解」全部关进一个文件，且是**纯函数、可单独断言**。

### 3.3 探测：用 Range 一次拿到形状与 tag

Harmonybrew 没有 `/formula/wget.json`，但 `.jws.json` 的**开头 1KB 就够**：

```
GET /internal/packages.<tag>.jws.json   Range: bytes=0-1023
→ 206
{"payload":"{\"metadata\":{\"homebrew_version\":\"7.0.6_2\",\"bottle_tag\":\"arm64_ohos\",…
```

一次请求同时确认三件事：信封里有 `payload`、`metadata.bottle_tag`（**tag 从数据里读，不硬编码、也不猜设备 ABI**，解决 Review Focus #1）、`Content-Type` 是 JSON。

⚠ **端点名本身需要 tag**，而 tag 要从响应里读 —— 这是个先有鸡还是先有蛋。解法：探测**先用已知 tag 试**（`arm64_ohos`，常量），成功后再用响应里的 tag **覆盖**并写回源配置。这样「服务端换 tag」表现为「第一次探测仍能成功并自动纠正」，而不是 404。

### 3.3.1 探测必须**方言无关**，不能按当前激活源的方言分派

Task 2 把探测实现成了「按**会话激活源**的方言分派」：

```ts
// ✗ 错：探测对象是尚未激活的新源
return adapterFor(BrewSourceStore.dialectOf(BrewSourceStore.sessionActive().id)).probe(baseUrl);
```

那对 Task 2 当时的代码是**零回归**（所有源都是 `upstream`），但语义是错的：**探测发生在新增/编辑时，被探测的源还没激活**。新增一个 Harmonybrew 源时激活源仍是内置 Official，于是会拿上游探测去打 Harmonybrew 地址、404 失败。

正确语义是**自动识别**（即 §3.1 说的「方言选择自动识别（探测时判定）」）：

1. 先做**方言无关**的 URL 格式校验（`BrewSourceUrl.check`，保住 6 类格式原因码）；
2. 试**上游**端点；成功 → 判定 `upstream`；
3. 试 **Harmonybrew** 端点；成功 → 判定 `harmonybrew`（并带出 tag）；
4. 都失败 → 返回**上游的**失败结果。理由：上游失败原因信息量最大，且与改动前的 UX **逐字一致**（地址打错时仍然看到 `http-404` / `not-json` / `html-body` 这些具体原因，不退化成模糊提示）。

失败路径最多两次请求（上游 ~5KB + Range 1KB）；成功路径第一次就返回。

`BrewSourceStore.dialectOf()` **只服务于运行期取数**（索引/详情），那里必须用会话冻结源 —— 这与本文件 `BrewMetaSync` 里「不能拿注册表里可能已改的 activeId」的硬规一致，不要改。

### 3.4 详情取数：本地目录 + 偏移量（D-A）

fork 没有 per-token 端点，详情只能来自本地持有的目录。**两个子方案**：

| | D-A 本地目录 + 偏移（**选它**） | D-B 服务端 Range + 偏移 |
|---|---|---|
| 做法 | 同步时把**解包后的**目录写成每行一个 token 的文件（~3.4MB）+ `token → [start,end]` 偏移表（~50KB，存 Preferences）；详情 = 本地随机读 ~700B | 偏移表指向**转义后**的服务端文件；详情 = `Range` GET ~700B |
| 新增存储 | +3.4MB/源（**用 `fileIo` 存文件，不塞 GSKV** —— Preferences 是整份加载/整份落盘，3.4MB 的 flush 不可接受） | 基本不变（+50KB） |
| 风险 | 低 | **高**：偏移量必须算在转义后的坐标里。payload 在 JSON 字符串内、原文是 `\"wget\":{`，而 `\"` 是 2 字节、`"` 是 1 字节，坐标**不线性**；要么写一个转义感知的流式扫描器（~200 行，全案最脆），要么整份解包后再算（那就等于 D-A） |

**选 D-A**：3.4MB/源可接受（应用本来就有 ~1MB 索引），换来「不写脆弱的转义扫描器」，且详情变成本地读、更快、可离线。D-B 留作后续优化。

**「每行一个 token」的格式为什么能免掉扫描器**：写文件时每行的字节偏移是**顺序产生的**，边写边记即可，不需要事后再解析。行格式 `token\t<归一化后的 doc JSON>\n`。

### 3.5 决策记录：为什么不用「应用内 HTTP server 转发」

评估过，**否决**。它是 D-A 的全部工作量 **加上**：

1. **SDK 没有 HTTP server API** —— `@ohos.net.http` 只有 `createHttp`/`createHttpResponseCache`，全 SDK 搜 `createHttpServer` 无结果；服务端能力只有 `@ohos.net.socket` 的 `TCPSocketServer`。要手写 HTTP/1.1（请求行/头解析、路由、`Content-Length`、keep-alive、并发、错误应答）。
2. **共用难点一个没省** —— 映射照样要做，而且多做一遍（映射成上游 JSON 再序列化出去）。
3. **详情问题没被解决** —— 代理要应答 `/formula/<token>.json`，就必须持有整份目录，难题原样存在，只是多隔一层 socket。
4. **探测语义失效** —— 源探测会打本机代理，代理活着就恒成功，「测试连接」不再测试真实远端。对多源功能是实质性破坏。
5. **源身份被污染** —— 端口一变 `baseUrl` 就变，缓存键、健康记录、日志对账全跟着漂。
6. **生命周期/多实例** —— 2in1 多窗口、后台化、进程重启都要管端口占用；两个实例直接抢端口。
7. **审核与安全** —— 应用监听端口需要解释，本机其它应用可任意查询。

它唯一的好处是「现有 pipeline 完全不动」，但代价是总代码量更大、把风险从「改 4 个调用点」换成「手写一个 HTTP server」。**唯一值得保留的用法**：在开发机上用一次性 Python 脚本做转换 PoC（不进应用），提前验证 §4 的映射表 —— 本计划的 §4 已经用 `brew info --json=v2` 完成了这件事，不需要再写脚本。

### 3.6 能力降级

`HarmonybrewAdapter` 声明 `supportsCasks = false`（`casks` 恒空）、`supportsAnalytics = false`（4 个端点全 404）。UI 与算法据此：

- **Casks**：分类/榜单里不出现 cask；这是**对的** —— cask 是 macOS `.app`，HarmonyOS 上无意义，fork 只做 formula 正是这个原因。
- **Analytics**：`BrewCatalogAlgo.catalogSources()` 返回空 → Discover 三个榜（trending/alltime/fresh）无数据。这是**本方案最大的功能损失**，需要产品决定（隐藏 Discover / 换排序信号）。本计划先做**不崩、不空转**，即 Task 8 的空态。

---

## 4. 字段映射表（Harmonybrew formula → `LiveFormulaDoc`）

逐条对照 `brew info --json=v2` 验证过。`S` = fork 原始字段，`N` = `brew info` 的规范结果。

| `LiveFormulaDoc` | 来源 | 备注 |
|---|---|---|
| `token` | 字典键 | |
| `name` | 字典键 | fork 无 `name` |
| `full_name` | 字典键 | 同上 |
| `tap` | **不设**（留空） | 见 §1.7；设了会让安装命令变成 `brew install harmonybrew/core/wget` |
| `desc` | `S.desc` | 4761/4761 都有 |
| `homepage` | `S.homepage` | |
| `license` | `S.license` | |
| `versions.stable` | `S.stable_version` | **不含 revision**（N 实测 `apr` = `1.7.6`） |
| `versions.head` | `S.head_url_args` 存在 ? `'HEAD'` : `null` | N 实测：`wget` 有 → `'HEAD'`；`apr` / `ant@1.9` 无 → `null` |
| `versions.bottle` | `S.bottle_checksum !== undefined` | **4761/4761 都有** → 恒 `true` |
| `bottle.stable.rebuild` | `S.bottle_rebuild ?? 0` | 63/4761 有 |
| `bottle.stable.files` | `{ [tag]: {} }` | 只需 tag 键存在（`BrewApiMapper:321` 取 `Object.keys`）。**URL 不消费，不合成** |
| `keg_only` | `S.keg_only_args` 存在 **且** `[0] === ':versioned_formula'` | ⚠ `:provided_by_macos` / `:shadowed_by_macos` → **false**（N 实测 `apr`/`apr-util`） |
| `keg_only_reason` | `{ reason: S.keg_only_args[0], explanation: S.keg_only_args[1] ?? '' }` | ⚠ `reason` **保留前导冒号**（N 实测 `":provided_by_macos"`）；`explanation` 缺省是**空串**不是 null |
| `deprecated` | `S.deprecate_args` 存在 且 `today >= S.deprecate_args[':date']` | |
| `deprecation_date` | `S.deprecate_args[':date']` | `"2024-07-07"` 原样 |
| `deprecation_reason` | `S.deprecate_args[':because']` **去掉前导冒号** | ⚠ 与 `keg_only_reason.reason` 规则相反（N 实测 `"unmaintained"`） |
| `deprecation_replacement_formula` | `S.deprecate_args[':replacement_formula']` | |
| `deprecation_replacement_cask` | `S.deprecate_args[':replacement_cask']` | |
| `disabled` | `S.disable_args` 存在 且 `today >= S.disable_args[':date']` | ⚠ 存在 ≠ 已禁用 |
| `disable_date` / `disable_reason` | `S.disable_args[':date']` / `[':because']`（去冒号） | |
| `versioned_formulae` | `S.versioned_formulae` | 直接有 |
| `aliases` | `S.aliases` | 直接有（另有顶层 `formula_aliases` 表，暂不用） |
| `executables` | `S.executables` | 直接有 |
| `caveats` | `S.caveats` | 直接有 |
| `requirements` | `[]` | fork 无此字段 |
| `dependencies` | `S.stable_dependencies` 中**值不是 `':build'`** 的项 | 字符串项算运行时依赖 |
| `build_dependencies` | `S.stable_dependencies` 中**值为 `':build'`** 的键 | `{"pkgconf":":build"}` → `pkgconf`（N 实测 `aliddns`：`[{"go":":build"}]` → `dependencies:[]` + `build_dependencies:["go"]`） |
| `optional_dependencies` / `recommended_dependencies` | `[]` | fork 无此字段 |
| `uses_from_macos` | `S.stable_uses_from_macos` **展平一层** | ⚠ 形状是「调用参数数组的数组」：`[["expat"],["libxcrypt"],["sqlite"]]` → `["expat","libxcrypt","sqlite"]`（N 实测 `apr-util`）；含 build 的形如 `[[{"bison":":build"}],…]` |
| `conflicts_with` | `S.conflicts` 每项取 `[0]` | ⚠ 同样是调用参数数组：`[["cgrep",{":because":"…"}]]` → `["cgrep"]`（N 实测 `aerleon`） |
| `analytics` | `undefined` | fork 无 |
| `service` | `S.service_run_args[0]` 是数组时 → `{ run: S.service_run_args[0] }` | ⚠ 形状 `[["$HOMEBREW_PREFIX/opt/x/bin/x","-c","…"]]`（N 实测 `aliddns`）。应用模型注释（`BrewModels.ets:220`）本来就期望 `$HOMEBREW_PREFIX` 形式，**不需要替换** |

**cask**：`casks` 恒空 → `supportsCasks = false`，不实现 cask 映射。

---

## 5. 文件结构

### 新增（`features/brewcommon/src/main/ets/`）

| 文件 | 职责 |
|---|---|
| `service/source/BrewSourceAdapter.ets` | `BrewSourceAdapter` 接口 + `adapterFor(dialect)` 分派 + `BrewCatalogResult` DTO（Task 2 建，Task 3 注册 harmonybrew 分派） |
| `service/source/UpstreamAdapter.ets` | 上游方言（现有行为原样搬迁，**行为零变化**） |
| `service/source/HarmonybrewModels.ets` | `HarmonybrewFormula` 原始源形状（Task 3；Task 4 的 `HarmonybrewMap` 反向 import 它） |
| `service/source/HarmonybrewAdapter.ets` | 本方言：信封解包、目录解析、tag 读取（Task 3）；`fetchDoc` 本地切片（Task 6/7） |
| `service/source/HarmonybrewMap.ets` | **§4 映射表的唯一实现**（纯函数，无 I/O，Task 4） |
| `service/BrewCatalogFile.ets` | 每源目录文件的写/读切片/删（`fileIo`）+ 偏移表读写 |
| `service/BrewJsonScan.ets` | 结构感知的 JSON 文本扫描（找 `formulae` 各 token 的对象边界）—— 纯函数 |

### 修改

| 文件 | 改动 |
|---|---|
| `model/BrewSourceModels.ets` | `BrewSource` 加 `dialect`；`BrewSource` 构造函数加参 |
| `service/BrewSourceStore.ets` | `normalizeRegistry` 迁移 `dialect`；`dialectOf(sourceId)` |
| `service/BrewSourceProbe.ets` | 按方言分派 `probe()`（**现有 11 类错误分类保留**） |
| `service/BrewMetaSync.ets` | `syncKind` 走 `fetchCatalog`；`metaScanTask` 仅上游方言使用 |
| `service/BrewService.ets` | `getLiveDoc` / `conditionalFetch` 的取数走 `fetchDoc`；`datasetProbe` 走 adapter |
| `service/BrewCatalogAlgo.ets` | `catalogSources()` 按 `supportsAnalytics` 返回空 |
| `service/BrewCacheAdmin.ets` | `clear` / `drop` 连带删目录文件与偏移表 |
| `service/BrewSourceDiagnostics.ets` | 自检加方言用例（映射表断言） |
| `constant/BrewSourceConstants.ets` | 方言常量、Harmonybrew 端点与默认 tag |
| `features/brewcommon/Index.ets` | 导出新符号 |
| `features/mine/.../viewmodel/BrewSourceSettingVM.ets` | 探测时自动识别方言并写回 |
| `features/mine/src/main/resources/{base,zh_CN,en_US}/element/string.json` | 新文案 |
| `docs/brew-api-design.md`、`docs/brew-handover.md` | 回写 §1 的实测结论 |

---

### Task 1: 方言字段与持久化迁移

**Files:**
- Modify: `features/brewcommon/src/main/ets/model/BrewSourceModels.ets`
- Modify: `features/brewcommon/src/main/ets/service/BrewSourceStore.ets`
- Modify: `features/brewcommon/src/main/ets/constant/BrewSourceConstants.ets`

- [ ] `BrewSourceConstants.ets` 加常量：`BREW_DIALECT_UPSTREAM = 'upstream'`、`BREW_DIALECT_HARMONYBREW = 'harmonybrew'`、`BREW_HARMONYBREW_DEFAULT_TAG = 'arm64_ohos'`、`BREW_HARMONYBREW_CATALOG_PATH(tag)`、`BREW_HARMONYBREW_RANGE_PROBE_BYTES = 1024`。
- [ ] `BrewSource` 加 `public dialect: string`，构造函数追加末位参数（**末位**，避免现有 2 个调用点（`BrewSourceStore.ets:112` / `:295`）的实参错位）。字段注释写清「`id`/`baseUrl` 解耦不变，dialect 只描述形状」。
- [ ] `BrewSourceStore.normalizeRegistry` 里对每个源补 `dialect`：空串/`undefined` → `BREW_DIALECT_UPSTREAM`。**内置源显式写 `'upstream'`**（`baseUrl` 是 `formulae.brew.sh`）。
- [ ] `BrewSourceStore` 加 `public static dialectOf(sourceId: string): string`，读会话快照。
- [ ] 编译 + 真机验证：设置页能正常打开、列表不空、健康状态正常（迁移没把注册表读坏）。
- [ ] 提交：`feat(brew): 数据源加 dialect 字段与存量迁移`

### Task 2: adapter 接口 + UpstreamAdapter（纯重构）

**Files:**
- Create: `features/brewcommon/src/main/ets/service/source/BrewSourceAdapter.ets`
- Create: `features/brewcommon/src/main/ets/service/source/UpstreamAdapter.ets`
- Modify: `BrewSourceProbe.ets`、`BrewMetaSync.ets`、`BrewService.ets`

- [ ] 定义接口与 `BrewCatalogResult`（字段与现有 `MetaScanResult` 对齐：`ok` / `notModified` / `stamp` / `indexJson` / `pairs` / `skips` / `detail`）。
- [ ] `UpstreamAdapter` 把现有实现**原样搬入**：`probe` = `/formula/wget.json` + 现有 `checkShape`；`fetchCatalog` = 现有 `metaScanTask` 的调用；`fetchDoc` = `BrewHttp.request(join(base, path), …)`。
- [ ] 三个调用点改为 `adapterFor(BrewSourceStore.dialectOf(...)).xxx(...)`，**不改变任何默认行为**。
- [ ] **回归判据（关键）**：内置源（upstream）冷启动后，日志里的 `meta sync [formula]` / `meta sync [cask]` 行与改动前逐字段一致（`ok` / `code` / `pairs` / `notModified`），详情页 hydrate 汇总行一致。
- [ ] 提交：`refactor(brew): 抽 BrewSourceAdapter，上游方言行为不变`

### Task 3: Harmonybrew 取数、信封解包与目录解析

> **本任务只做「取数 + 解析 + 接线」，不碰映射。** 归一化 doc 的产出是 Task 6 的事；
> §4 映射表是 Task 4 的唯一产出。原因：`HarmonybrewMap` 是 Task 4 才新增的文件，
> 让 Task 3 调它会形成**前向依赖**。

**Files:**
- Create: `features/brewcommon/src/main/ets/service/source/HarmonybrewAdapter.ets`
- Create: `features/brewcommon/src/main/ets/service/source/HarmonybrewModels.ets`（`HarmonybrewFormula` 原始形状）
- Create: `features/brewcommon/src/main/ets/service/BrewJsonScan.ets`
- Modify: `features/brewcommon/src/main/ets/service/source/BrewSourceAdapter.ets`（注册 harmonybrew 分派）

- [ ] `HarmonybrewModels.ets` 声明 `HarmonybrewFormula`：**原始源对象**的形状（`bottle_rebuild?: number`、`stable_version?: string`、`deprecate_args?: Record<string, string>` 等；**`*_args` 一律声明成 `Object[]` 再逐项窄化**，因为同一字段有「数组」与「对象」两种形态）。
      **这个接口归 Task 3**（它描述的是解析器抽出来的东西），Task 4 的 `HarmonybrewMap` 反过来 import 它。
- [ ] `BrewJsonScan.formulaeRanges(payloadJson: string): Record<string, number[]>`：**结构感知**扫描（跟踪字符串字面量、`\` 转义、嵌套深度），返回 `token → [start, end]`，只认 `formulae` 下的**第一层**对象键。**禁止 `indexOf`**（Review Focus #3）。
- [ ] `HarmonybrewAdapter.probe(baseUrl)`：**本任务就完整实现** —— `GET .jws.json` + `Range: bytes=0-1023` → 判 `206`/`200`、`Content-Type` 含 `json`、body 以 `{"payload":"` 开头、正则取出 `metadata.bottle_tag`。这属于「解析」，不是 Task 5 的活（Task 5 只剩自动识别链与 tag 回写）。端点名先用 `BREW_HARMONYBREW_DEFAULT_TAG` 试，成功后用响应里的 tag 覆盖。
- [ ] `HarmonybrewAdapter.fetchCatalog`：完整实现到「信封解包 → `formulaeRanges` → 产出 `token → desc` 索引」为止。`GET .jws.json`（`If-None-Match: <stamp>`）→ `304` 则 `notModified`；`200` 则 `JSON.parse` 信封 → 取 `payload`（**必须 `typeof === 'string'` 校验**，Review Focus #2）→ `JSON.parse(payload)` → 取 `metadata.bottle_tag` 与 `formulae` → 产出索引。**不要调 `HarmonybrewMap`、不要产出归一化 doc** —— `BrewCatalogResult` 目前只承载 `indexJson`/`pairs`/`skips`，够用。
- [ ] `HarmonybrewAdapter.fetchDoc`：返回 `{code: 404}`，并打一行明确日志说明「本地目录在 Task 6 接入」。**不要伪造 200**，也不要留静默 stub。
- [ ] `BrewSourceAdapter.adapterFor` 注册 harmonybrew 分派（否则本任务的 adapter 没人调用、也无法自测）。
- [ ] **不要新建 `HarmonybrewMap.ets`、不要在 Task 3 写任何映射规则。**
- [ ] 判据：真机日志打 `dialect=harmonybrew pairs=4761 skips=0 tag=arm64_ohos envelope=3973524B payload=3659172B`。**`pairs` 必须是 4761**；`skips > 0` 或 `pairs === 0` 都要能被现有 `pairs === 0` 判据拦住。
- [ ] 提交：`feat(brew): Harmonybrew 目录取数、信封解包与结构感知扫描`

### Task 4: 字段映射（§4 的唯一实现）

**Files:**
- Create: `features/brewcommon/src/main/ets/service/source/HarmonybrewMap.ets`

- [ ] 实现 `formulaToLive(token: string, tag: string, src: HarmonybrewFormula): LiveFormulaDoc`，严格按 §4 表。`HarmonybrewFormula` **从 Task 3 的 `HarmonybrewModels.ets` import**，不要在本文件重复声明。
- [ ] 三个陷阱各写一条断言式注释（引用 §1.6 的实测值），并在自检里覆盖：
  - `keg_only`：`apr`（`:provided_by_macos`）→ `false` + `keg_only_reason` 非空；`ant@1.9`（`:versioned_formula`）→ `true`。
  - `disabled`：`access`（日期已过）→ `true`；构造一个未来日期的样本 → `false`。
  - `reason` 冒号：`deprecation_reason` 去冒号、`keg_only_reason.reason` 留冒号。
- [ ] `uses_from_macos` 展平、`conflicts_with` 取 `[0]`、`stable_dependencies` 拆 build —— 各一条注释说明「fork 存的是调用参数数组」。
- [ ] 日期比较用**本地日期字符串比较**（`'2026-09-24' >= '2025-07-07'`），不引入 Date 解析（避免时区把「今天」算成昨天）。
- [ ] **本任务不接线**（没人调 `formulaToLive` 是预期的）：交叉验证放到 Task 6 接入之后做。这里只保证纯函数正确且可被单独调用。
- [ ] 提交：`feat(brew): Harmonybrew 字段映射（含 keg_only 平台规则与 disabled 日期判定）`

### Task 5: 探测接入（方言无关的自动识别 + Range 读形状与 tag）

**Files:**
- Modify: `HarmonybrewAdapter.ets`（`probe`）、`BrewSourceProbe.ets`、`model/BrewSourceModels.ets`（`BrewProbeResult`）

> ⚠ **本任务是 Task 2 遗留语义错误的修复点，先读 §3.3.1。** Task 2 提交（`7e91cfe`）里的
> `BrewSourceProbe.check` 按**会话激活源**的方言分派，对当时的代码零回归但语义错 ——
> 被探测的新源还没激活，必须改成方言无关的自动识别。

- [ ] `BrewProbeResult` 加两个字段：`dialect: string`、`tag: string`。构造函数给**默认值**（`BREW_DIALECT_UPSTREAM` / `''`），这样 `UpstreamAdapter` 里已有的 `done()` 调用点不用逐个改。
- [ ] `HarmonybrewAdapter.probe(baseUrl)`：`GET .jws.json` + `Range: bytes=0-1023`（`BREW_HARMONYBREW_RANGE_PROBE_BYTES`）→ 判 `206` 或 `200`、`Content-Type` 含 `json`、body 以 `{"payload":"` 开头、正则取出 `metadata.bottle_tag`；成功时 `dialect = BREW_DIALECT_HARMONYBREW`、`tag = <响应里的 tag>`。端点名先用 `BREW_HARMONYBREW_DEFAULT_TAG` 试，成功后再用响应里的 tag 覆盖（见 §3.3 的鸡生蛋）。
- [ ] `BrewSourceProbe.check(baseUrl)` 改成 §3.3.1 的四步**探测链**：方言无关 URL 校验 → 试上游 → 试 Harmonybrew → 都失败返回上游结果。**不要**再调 `dialectOf(sessionActive().id)`。
- [ ] 沿用现有 11 类错误分类（`http-404` / `not-json` / `html-body` / `shape-mismatch` / `timeout` / `dns` / `tls`），不新增原因码。
- [ ] tag 回写：探测成功且响应里的 tag 与源配置不同 → 更新源的 tag 字段（Task 1 未加 `BrewSource.tag`，本任务补）。
- [ ] 真机验证：设置页「新增数据源」填 `https://harmonybrew.atomgit.com/api` → **应显示连接成功**，日志含 `dialect=harmonybrew tag=arm64_ohos code=206`。
- [ ] 反向验证 1：填 `https://formulae.brew.sh/api` → 判定为 `upstream` 且成功（不能把上游误判成本方言）。
- [ ] 反向验证 2：填一个打错的地址（如 `https://formulae.brew.sh/apii`）→ 仍报 `http-404`（验证「都失败时返回上游原因」这条生效，没退化成模糊提示）。
- [ ] 提交：`feat(brew): 方言无关的探测自动识别 + Range 读形状与 bottle tag`

### Task 6: 全量索引接入 + 目录落盘

> **本任务授权修改 Task 3/4 的文件**（原清单遗漏，是我的排序缺口）：为了让 `catalog.tsv`
> 装的是**归一化 doc**而不是只有 desc，必须让 adapter 能带回 catalog，并让
> `HarmonybrewAdapter` 调 `HarmonybrewMap`。

**Files:**
- Modify: `features/brewcommon/src/main/ets/service/BrewMetaSync.ets`
- Create: `features/brewcommon/src/main/ets/service/BrewCatalogFile.ets`
- Modify: `features/brewcommon/src/main/ets/service/source/BrewSourceAdapter.ets`（`BrewCatalogResult` 加字段）
- Modify: `features/brewcommon/src/main/ets/service/source/HarmonybrewAdapter.ets`（调 `HarmonybrewMap`）

- [ ] `BrewCatalogResult` 加两个**可选**字段：`catalogJson?: string`（归一化后 `Record<token, LiveFormulaDoc>` 的 JSON 文本；上游不设）与 `catalogPairs?: number`。**`catalogPairs` 不能复用 `pairs`** —— Task 3 的循环里 `desc` 为空会 `skips++` 且不进索引，所以索引条数与 catalog 条数可以不等。
- [ ] `HarmonybrewAdapter.fetchCatalog`：在已有逐 token 循环里解析出 `source` 之后**再调** `HarmonybrewMap.formulaToLive(token, tag, source)`，累积后 `JSON.stringify` 成 `catalogJson` 返回。`tag` 用本次 payload 读出的真实 tag，不要用常量。
- [ ] `syncKind` 改为 `adapterFor(dialect).fetchCatalog(...)`；**上游分支完全走原路径**（含 `metaScanTask` 的 `@Concurrent` 流式扫描）。
- [ ] **`fetchCatalog` 拼端点 URL 要改用源上存的 `tag`**（`BrewSource.tag`，空则回落 `BREW_HARMONYBREW_DEFAULT_TAG`）。目前 `HarmonybrewAdapter:92` 写死默认 tag，导致「服务端换 tag」的自动纠正只完成一半（Task 5 已把 tag 存进源，但取数不读）。
- [ ] `BrewCatalogFile`：`write(sourceId, catalogJson)`（解析后逐行写 `token\t<doc JSON>\n`，**边写边记** `token → [start,end]` 偏移并返回）、`readRange(sourceId, token)`、`delete(sourceId)`、`has(sourceId)`；路径 `filesDir + '/brew_src/' + sourceId + '/catalog.tsv'`。
- [ ] 偏移表（`token → [start,end]`）存该源的 Preferences（键名新增，**不改现有六条键**）。
- [ ] 世代号守卫照旧：`epoch` 不匹配时**不写目录文件、不写偏移表**（与 `persistIndex` 同一道守卫，不能绕过）。
- [ ] 上游方言 `catalogJson === undefined` → 不写目录文件、不写偏移表（上游有 per-token 端点，不需要本地目录）。
- [ ] **防截断判据（修正版）**：`ok: pairs > 0` 单独看不够 —— 扫描器部分失效（只解出 100 条）也会覆盖掉好索引。
      但**不要**用 `pairs + skips === Object.keys(formulae).length`：那是**恒等式**（每个 token 要么进索引、要么被 skip，两者互补），永远成立、抓不到任何东西。
      正确做法是把计数器拆开，并让 `ok` 依赖结构性故障数：
      `skips`（保持原语义 = unparsed + emptyDesc，日志判据行不变）、`unparsed`（range 缺失 或 `JSON.parse` 抛错）、`emptyDesc`（解析成功但 desc 为空）。
      `ok: pairs > 0 && unparsed === 0`；`emptyDesc` 非零是良性的，只记数不失败。
- [ ] **ETag 写入顺序（子代理实测发现，必须保留）**：Harmonybrew 必须**先写完整目录、再记 ETag**。若先记 stamp，目录写失败后下次会拿 304 直接跳过重写，详情目录就永远缺失。
- [ ] **ETag 可用前提（同上）**：Harmonybrew 的 ETag 只有在「索引与本地目录都存在」时才能安全发出（`BrewCatalogFile.has(sourceId)`）；否则 304 会让已丢失的 `catalog.tsv` 永远无法重建。上游仍严格保持只看原索引的旧条件。
- [ ] **写进注释与 residualRisks 的性能事实**：Harmonybrew 这条路径的「下载 → 2 次 JSON.parse → 4761 次映射 → 3.4MB stringify」**跑在主线程**（与 Task 3 一致）。上游那条路之所以用 `@Concurrent` 就是因为它有 32MB；这边虽然只有 3.6MB，但仍有可感知卡顿（估 0.5~2s）。**本任务不要改造成 taskpool** —— 那要评估 `@Concurrent` 能否调用其它文件的静态方法，留给后续。
- [ ] 真机验证：激活 Harmonybrew 源 → 冷启动 → 日志 `pairs=4761` + 目录文件大小 ~3.4MB；再冷启动一次 → `notModified=true`（ETag 命中 304）、**不重写目录**。
- [ ] 提交：`feat(brew): Harmonybrew 目录落盘（偏移表 + 本地切片读）`

### Task 7: 详情取数接入（最高风险项）

**Files:**
- Modify: `features/brewcommon/src/main/ets/service/BrewService.ets`、`HarmonybrewAdapter.ets`（`fetchDoc`）

- [ ] `HarmonybrewAdapter.fetchDoc`：`BrewCatalogFile.readRange(sourceId, token)` → `JSON.parse` → 返回 `{code: 200, text: <doc JSON>, headers: {}}`。
      **注意：Task 6 落盘的已经是归一化后的 doc**（`HarmonybrewMap` 已在 Task 6 调用过），所以这里**不要再调一次 `formulaToLive`**，直接回传切片。
- [ ] **错误码必须区分「整体未同步」与「幽灵 token」**（⚠ 本节原先把两者都写成 404，是错的）：
      `getLiveDoc` 的 404/410 分支会调 `BrewService.markMissing(cacheKey)` **永久负缓存**该 token。所以若目录尚未同步就回 404，**每个 token 都会被误标成幽灵 token 且永不重试**。

      | 情况 | 返回 | 理由 |
      |---|---|---|
      | catalog 文件不存在 / 偏移表不存在（整体尚未同步） | **`{code: 503}`** | 非 200 分支里只有 404/410 会负缓存，其余一律 throw 且不记 → 下次照旧重试。这是**暂时性**故障 |
      | catalog 存在但该 token 没有偏移（或切片读失败 / JSON 解析失败） | `{code: 404}` | 真正的幽灵 token，负缓存正确 |

- [ ] `datasetProbe` **不新增 adapter 方法、不给 `BrewMetaSync` 开公开刷新钩子**。Harmonybrew 的 doc 来自本地已落盘的目录，所以「数据集是否新鲜」退化成「本地目录在不在」，而刷新节奏本就由启动时的 meta sync 拥有。
      在 `BrewService.datasetProbe`（私有方法，不需改接口）里按方言分支：
      - 上游：现有 HEAD + `If-Modified-Since` 路径**逐字不动**；
      - Harmonybrew：返回 `BrewCatalogFile.has(sessionActive().id)`。`true` → 现有代码只续期 ts、不碰网络（即计划里「304 → 续期」的意图，只是数据源换成本地状态）；`false` → 落到 `fetchDoc`。
      - Harmonybrew 分支**跳过 `stamp.lastModified` 那套基准逻辑**：它是 IMS 语义，而实测这个服务端**不认 `If-Modified-Since`**，拿它当基准是错的。

      为何不做「200 → 触发目录刷新」：那是**新鲜度优化而非正确性要求**，而中途刷新会引入 `getLiveDoc → refresh → fetchCatalog → epoch/budget` 的重入问题。会话中目录略旧可接受（应用本就有 TTL 缓存并容忍陈旧）。
- [ ] **真机判据**：打开一个 Harmonybrew formula 详情页 → 生命周期/依赖/版本/bottle 标签/许可/executables 段落**都有内容**（不是空骨架）；日志无 `hydrate` 失败；断网后详情页仍能打开（本地目录）。
- [ ] 提交：`feat(brew): Harmonybrew 详情取数走本地目录切片`

### Task 8: 能力降级（casks / analytics）—— **仅数据/算法层**

> **本任务不收窄不碰 UI。** 空态文案属于 §6 未决项「是否隐藏整个 Discover 入口」那个**产品决定**，
> 不应由一个实现任务顺手定下来；而且它要动约 8 个文件、跨 3 个模块的 View/ViewModel/模型/三语言，
> 属 UI 改动、回归最难靠编译发现。→ 文案另作一步（Task 8b 或折进 Task 10），**先由本任务产出一份
> 「空数据时各页面实际渲染什么」的事实报告**（具体到 `文件:行号`）。

**Files:**
- Modify: `features/brewcommon/src/main/ets/service/BrewCatalogAlgo.ets`
- Modify: `features/brewcommon/src/main/ets/service/BrewService.ets`
- Modify: `features/brewcommon/src/main/ets/service/BrewBrowseBuilder.ets`（按需）
- **不改**任何 View / ViewModel / `BrewModels` / `string.json`

- [ ] `catalogSources()`：`supportsAnalytics === false` → 返回空数组，**不发那 4 个必然 404 的请求**。
- [ ] `supportsCasks === false` → cask 相关取数/条目不进算法输入。
- [ ] 确认**不崩、不空转**：空输入下 Discover / Casks 不抛异常、不进无限 loading。
- [ ] ~~「我的」页的 Casks 计数不显示 0 而是隐藏~~ —— **该要求不成立，已撤销**：实测那里是 Formulae+Casks **合计数**，没有独立的 Cask 计数可隐藏。
- [ ] ~~空态文案 `brew_source_empty_no_cask` / `brew_source_empty_no_analytics`~~ —— **本任务不做**，另作一步（见上方说明）。
- [ ] **事实报告（本任务必须交付）**：读代码回答空数据时各页面实际渲染什么，要具体到 `文件:行号`：
      1. Discover 三个榜在 `catalogSources()` 为空时走哪条分支？显示空白 / 无限转圈 / 通用空态 / 错误态？
      2. Casks 分类页在 cask 集合为空时呢？
      3. **有没有哪里会把「空」当成「失败」而显示错误文案**，或会无限转圈？
- [ ] 真机验证（由调用方做）：激活 Harmonybrew 源 → 进 Discover 与 Casks → **不崩、不无限转圈**。
- [ ] 提交：`feat(brew): 按源能力降级 cask 与 analytics`

### Task 9: 方言识别写回（单写者）与设置页

**Files:**
- Modify: `features/mine/src/main/ets/viewmodel/BrewSourceSettingVM.ets`
- Modify: `features/mine/src/main/ets/view/BrewSourceEditView.ets`
- Modify: 三语言 `features/mine/src/main/resources/{base,zh_CN,en_US}/element/string.json`
- Modify: `features/brewcommon/src/main/ets/service/BrewSourceProbe.ets`（摘副作用）
- Modify: `features/brewcommon/src/main/ets/service/BrewSourceStore.ets`（`updateProbeTag` 泛化）
- **不改** `features/mine/src/main/ets/view/BrewSourceSettingView.ets`（列表 View），**不加**任何能力说明文案 key

- [ ] **单写者改造（本任务的核心）**：Task 5 把 `BrewSourceProbe.check` 做成了带副作用（内部调 `updateProbeTag(baseUrl, tag)` → `persistRegistry`）。而保存路径也要写 dialect/tag —— 同一字段两个触发点会出现「探测了某个源却改了另一个源」（它按 baseUrl 匹配）与「探测完用户点了取消、但 tag 已落盘」。改为单一写者：
  - `BrewSourceStore.updateProbeTag(baseUrl, tag)` → `updateProbeIdentity(id: string, dialect: string, tag: string)`：按 **id** 查（不是 baseUrl），两者都写，**仅在值真变化时** persist，`dialect` 为空串时**不覆盖**；
  - `BrewSourceProbe.check` 删掉两处 `updateProbeTag` 调用，恢复成**纯探测**；`BrewSourceStore` 的 import 随之无用一并删（全仓只此两处调用点）；
  - VM 保存路径从保留的探测结果取 dialect/tag，按 id 写。
- [ ] ⚠ **保存时拿不到探测结果（例如只改了名字）→ 保留源上已存的 dialect/tag，不要回落 upstream**。回落会把 Harmonybrew 源静默翻回上游方言，取数立刻全坏，而且看起来像「源挂了」。
- [ ] 编辑页展示方言（**只读展示，不做下拉** —— 自动识别更不容易错）。
- [ ] ~~列表卡片状态区在 Harmonybrew 源上显示「不提供 cask / 安装量」~~ —— **本任务不做**，与 Task 8 推迟的空态文案一起作为独立一步（Task 8b）统一做：它是同一类产品决定，分两处做会各说一套；且属于列表 View 的新 UI 元素，必须真机复核间距对齐。
- [ ] 文案三语言一致、占位符一致（沿用现有校验脚本口径）。
- [ ] 真机验证（由调用方做）：新增 → 探测 → 保存 → 列表出现新卡片且方言正确；编辑页显示正确。
- [ ] 提交：`feat(brew): 探测结果单写者写回方言与 tag`

### Task 10: 自检、文档与收尾

**Files:**
- Modify: `BrewSourceDiagnostics.ets`、`docs/brew-api-design.md`、`docs/brew-handover.md`、`Index.ets`

- [ ] 自检加映射用例（`BREW_SOURCE_VERIFY` 开关，默认关）：§4 表里的 5 个样本 token 的断言（Task 4 的三条陷阱 + 依赖拆分 + 展平）。
- [ ] `docs/brew-api-design.md` 新增一节：Harmonybrew 方言的端点、形状、映射表、以及 §1.2 的响应头能力差异（**ETag 而非 IMS、不支持 gzip**）。
- [ ] `docs/brew-handover.md` 回写：方言机制、目录文件的位置与删除连带、以及**未决项**（§6）。
- [ ] `Index.ets` 导出 `BrewSourceAdapter` / 方言常量。
- [ ] 提交：`docs(brew): 回写 Harmonybrew 方言适配与实测结论`

---

## 6. 未决项（不阻塞本计划，但要在收尾时明确记录）

1. **Cask 与 Discover 的产品取舍** —— Harmonybrew 源下两者皆空。本计划只保证「不崩、文案正确」，是否隐藏整个 Discover 入口需要产品决定。
2. **是否翻默认源** —— 独立一步，不要在本次一起做。若要翻，还要处理：内置源不变量（`builtin: true` 恒存在、`baseUrl` 固定）、第三方域名（`atomgit.com`）作为默认源的可用性与合规风险、以及上游兜底是否保留。
3. **服务端是否补上游形状端点** —— 仍然是最便宜的长期方案（fork 里已有 `generate-formula-api.rb` / `generate-cask-api.rb` / `generate-analytics-api.rb`）。若对方愿意发布 `formula.json` / `formula/<token>.json`，本方言适配即可整体下线。**建议同步向对方提这条**。
4. **未转义的 `packages.arm64_ohos.json` 是否恢复发布** —— 若恢复，Task 3 的信封解包可简化掉（但**不能依赖它**，见 §1.5）。
5. **bottle tag 的长期来源** —— 目前靠探测响应回写。若服务端同时发布多个 tag（`arm64_ohos` / `x86_64_ohos`），需要按设备 ABI 选择。
6. **`bottle_rebuild > 0` 时的 bottle URL**（本计划不消费）—— §1.6 已给出命名规则，若以后详情页要挂 bottle 下载链接再实现。

---

## 完成判据

- `devecocli build` / `run` **BUILD SUCCESSFUL，0 error**。
- 内置源（upstream）行为**逐字段无回归**：Task 2 的日志对账。
- `https://harmonybrew.atomgit.com/api` 能**被添加**、探测通过、方言自动识别为 `harmonybrew`、tag 自动识别为 `arm64_ohos`。
- 激活该源后：目录 `pairs=4761`；详情页各段落有内容；二次冷启动走 304 且不重写目录。
- Casks 与 Discover 在该源下**不崩、不空转**，文案是「不提供」而非「失败」。
- 切换回内置源后一切恢复正常（多源隔离未被破坏）。
- 清空/删除 Harmonybrew 源时，目录文件与偏移表**一并删除**（无残留）。
- 提交信息符合 `type(brew):` 前缀与中文正文约定。
