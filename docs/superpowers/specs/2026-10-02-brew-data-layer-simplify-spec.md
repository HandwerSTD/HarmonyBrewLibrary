# brew 数据拉取层精简方案

> 状态：待评审。日期：2026-10-02。
> 范围：`features/brewcommon` 的数据层。不改分类词表、不改榜单算法口径、不改 UI 版式。

---

## 0. 这份文档解决什么

当前数据层有 8 类端点、约 8800 行代码，运行期请求数与「用户进页面几次」成正比：
进一次 Discover 会发 4 个聚合请求 + 60 个单条请求；索引不可信时每进一次 Formulae/Casks 再发 100 个单条。
失败路径分散在多处，页面上看不到原因，也没有重试入口。

本方案把整个 brew 数据面收敛成**一份按 token 的包表**：

- 浏览页、搜索页、榜单全部从表里读，稳态下**零请求**；
- 单条文档只剩详情页一个消费者；
- 端点类别从 8 类减到 4 类；
- 失败状态从两个通道收敛成表的两片，各自可独立判定。

---

## 1. 先认识 Homebrew 的 API

面向不熟悉 Homebrew 的维护者。只讲通用上游（`https://formulae.brew.sh/api`），不涉及 Harmonybrew 镜像的适配层。

### 1.1 整体形态

Homebrew 官方 API 是一个**静态 JSON 站点**（GitHub Pages + Fastly），没有鉴权、没有会话、没有写操作，全部是 GET。
它由 `brew` 命令每天定时生成一次，生成完就是一堆只读 JSON。所以：

- 同一时刻的内容对所有客户端一致；
- 响应可以条件请求（见 1.4）；
- 任何一个包在某一刻的完整信息都是**一个独立的小 JSON**，可以单独取。

### 1.2 五类端点

**A. 单包定义** —— `/formula/<token>.json` 与 `/cask/<token>.json`

一个包的全部字段。formula 侧包含 `versions.stable`、`dependencies`、`bottle`、`license`、`homepage`、`deprecated`、`desc`；cask 侧包含 `version`、`url`、`homepage`、`desc`、`name`（显示名数组）。

体积约 5 KB。`token` 就是包名，`wget`、`git`、`google-chrome`。**这是唯一有「详情」的端点** —— 版本、依赖、许可这些字段只在这里。

**B. 全量清单** —— `/formula.json` 与 `/cask.json`

把所有包排成一个数组，每个元素是 A 类端点返回内容的精简投影。formula 数组的元素以 `name` 字段作为标识（值等于 token），cask 数组的元素以 `token` 字段作为标识。

体积很大：formula 解压后约 32.4 MB、gzip 5.29 MB；cask 的 gzip 约 2.05 MB。**本项目只从中抽 `标识 → desc` 一项**，其余字段全部丢弃。

**C. 安装量聚合** —— `/analytics/install-on-request/homebrew-core/{30d,365d}.json` 与 `/analytics/cask-install/homebrew-cask/{30d,365d}.json`

上游每天按包聚合的安装次数，窗口为滚动 30 天与 365 天。响应形状：

```
{ "category": ..., "total_items": ..., "total_count": ...,
  "start_date": "2026-09-01", "end_date": "2026-09-17",
  "formulae": { "<token>": [ { "formula": "<token>", "count": "62,667" } ] } }
```

cask 的文件里那层字典的 key 也叫 `formulae`（上游的历史遗留）。

四个文件 raw 合计约 1.9 MB、gzip 合计约 358 KB，其中 365 天那两个各约 3.9 MB raw / 750 KB gzip（`BrewConstants` 里两处注释对总体积的记述不一致，实际以实测为准）。**这是唯一能给全量包排序的数字来源。**

**D. 源探测** —— 复用 A 类，取一个固定的小包 `/formula/wget.json`

设置页「测试连接」与切换数据源前用它确认地址可用。`wget` 长期存在、体积小、在任何镜像上都该有。

**E. 数据集探针** —— 对 `/formula.json` 与 `/cask.json` 发 HEAD

**目前项目里没有在用的真实需求**，见 1.5。

### 1.3 条件请求

这四个文件都支持条件请求，命中时返回 304 且响应体 0 字节：

| 头 | 依据 | 实测表现 |
| --- | --- | --- |
| `If-Modified-Since` | 响应头的 `Last-Modified` | 整批一次性生成，跨节点一致，命中率高 |
| `If-None-Match` | 响应头的 `ETag` | 单文件哈希，跨 Fastly 节点不一致，命中率低 |

所以顺序固定为 IMS 优先、ETag 兜底。实测同一 URL 在不同节点上 `Last-Modified` 会差 1 秒（`02:53:14` 与 `02:53:15`）。

### 1.4 两套「全量」的分工

B 类给的是「有哪些包、每个包的一句话说明」，C 类给的是「每个包被装了多少次」。
本项目的列表页、榜单、搜索需要**同时**用到两者：

- 分类（自建词表）要读描述；
- 排序与名次要读安装量；
- 榜单的「历史」「新星」两榜要读 365 天窗口。

两边都以 token 为主键，覆盖的包集合高度重叠。这是本次精简的出发点。

### 1.5 为什么会有数据集探针，以及它为什么该删

现在的设计里，单条文档缓存过期后的判定顺序是：先对 `/formula.json` 发一次 HEAD 探针，探针 304 说明整批没变，于是**整批**缓存零字节续期；探针说变了，才对每个 token 各发一次条件请求。

这套机制是为「一次 hydrate 一百个 token」设计的：探一次 HEAD 省掉 100 个条件请求。
精简后浏览页与榜单都不再 hydrate，单条只剩详情页在用，一次一个 token —— 探针省的正是那 100 个请求，而详情页一次只用 1 个。
条件请求本身就是 0 字节，多加一次 HEAD 只多一次往返。**探针这一层连同它的存储（`brew_live_dataset`）一起删掉。**

---

## 2. 精简前的功能 ↔ 端点对应

| 功能 | 依赖端点 | 调用时机 | 频次 |
| --- | --- | --- | --- |
| Discover 榜单成员、名次、30 天安装量、增速、数据窗口日期 | C 类 4 个 | 进 Discover 页且目录超过 6 小时新鲜窗口 | 每 6 小时 4 个 |
| Discover 榜上 60 条的可读名与描述 | A 类，最多 60 个 | 每次进 Discover 页 | 每次最多 60 个 |
| Formulae / Casks 的分类与行文案（主路径） | B 类 2 个 | 进程启动后台一次 | 每进程 2 个 |
| Formulae / Casks 的分类与行文案（降级路径） | A 类，最多 100 个 | B 类不可信时，每进一次页 | 每次最多 100 个 |
| 搜索页 | 无（读内存里的 B 类与 C 类产物） | — | 0 |
| 详情页 | A 类 1 个 | 每次打开详情，1 小时内命中缓存 | 每小时 1 个 |
| 单条缓存的新鲜判定 | E 类 2 个 | 单条缓存超过 1 小时 | 每 kind 每小时 1 个 |
| 源探测 | D 类 1 个 | 用户点「测试连接」或切换源 | 每次 1 个 |

**端点类别 5 类（8 个 URL 形态）**；稳态下进一次 Discover = 4 + 60 = 64 个请求；索引不可信时每进一次 Formulae/Casks 再加 100 个。

失败处理分散在 8 处：`getCatalog` 的 catch、`hydrate` 的单 token catch、`fetchCatalog` 的 `Promise.all` reject、`buildCatalog` 里的字段缺失、B 类同步的三种结局、单条的非 200 分支、负缓存的 404 判定、详情页的 catch。每处的失败语义与提示都不同。

---

## 3. 新的数据层设计

### 3.1 一个入口，两个读法

现在有两个互不相干的取数触发点：安装量由 `getCatalog()` 在进 Discover 页时触发，描述由 `BrewMetaSync.start()` 在进程启动时后台触发。所以「先看 Formulae」与「先看 Discover」在同一进程里拿到的数据组合不同，失败状态也分裂成两条互不相干的通道。

新设计只有一个取数入口：

```ts
class BrewTable {
  // 读：永远立即返回当前内存表，不等网络
  static current(): BrewTableView

  // 取：进程启动 + 每次页面进入都调它，是否真发请求由它内部比时间戳决定
  static refresh(force?: boolean): Promise<BrewTableView>
}
```

`refresh()` 内部按两片各自的新鲜窗口决定发不发请求，并且**永远 resolve，从不 reject** —— 失败以「某一片的 `ReadyAt` 没被更新」表达，不以异常表达。撞上在途请求时复用同一个 Promise（现在 `catalogInFlight` 的做法，但只有一处）。`force = true` 供重试按钮用，跳过新鲜窗口判定。

新鲜窗口：安装量片 6 小时（沿用 `BREW_CATALOG_FRESH_MS`，因为边缘 `Cache-Control: max-age=600` 比窗口短、条件请求必然回源，实测 17.4 秒）；描述片 12 小时（上游按天生成，命中条件请求时 0 字节）。

### 3.2 两片

| 片 | 内容 | 端点 | 窗口 |
| --- | --- | --- | --- |
| 安装量片 `vol` | 每个包 30 天与 365 天的安装次数 | C 类 4 个 | 6 小时 |
| 描述片 `desc` | 每个包的描述文案 | B 类 2 个 | 12 小时 |

```ts
interface Shard {
  stamps: Record<string, string>   // 端点 URL -> Last-Modified 基准
  readyAt: number                  // 0 = 从未成功过
}
```

两片各自取、各自记条件请求基准、各自标记新鲜度，一片失败不牵连另一片。这一点与现在一致（目录失败时索引仍可用，反之亦然），但判定从「目录有没有 / 索引覆盖够不够」变成「这一片有没有」—— 后者是一次读数字，前者要每次构页遍历 7900 个 token。

安装量片的四个端点各自一份基准（与现在的 `catalog.stamps` 同型）；描述片两个端点各一份（现在的 `brew_meta_stamp`）。

失败语义只有两条：某个端点非 200 且非 304 → 这一片整体不更新，保留盘上旧数据与旧基准；某片全部 304 → 时间戳前进，产物不重算（榜单不重算这条现有行为保留）。

### 3.3 存储形状

写入盘上的只有原始材料，派生结构在内存里算：

```
BrewTable（每个数据源一份，GSKV，单 key）
{
  schemaVersion,            // 结构变了整表作废，避免读到旧形状
  vol:  { [kind]: { [token]: [vol30d, vol365d] } },
  desc: { [kind]: { [token]: string } },
  volStamps, volReadyAt,
  descStamps, descReadyAt,
  boards:    { [kind]: { [boardKey]: CatalogEntry[] } },   // 6 张榜 × 每榜 KEEP 条
  windowEnd: { [kind]: string }                            // 「基于最近可用数据」的日期
}

// 内存视图：从上面派生，读一次算一次
{
  browse: { [kind]: BrewCategoryCard[] },   // 已分组、已排序、已编号
  boards: ...,
  descKeys: { [kind]: Set<string> }         // 描述片的键集合，相交判定用
}
```

体量对比现在的 `brew_catalog`（约 550 KB）+ `brew_meta_index`（约 1 MB），两处缩减：

- 浏览集条目从 6 个数字减到 1 个。现在 `topTokens` 存 `vol30d / vol365d / prior / velocity / score`，而浏览路径只读 `vol30d`：后两个只出现在榜单里（榜单走 `boards`，KEEP=40），`score` 在 `toEntry(row, false)` 里恒为 0，365 天那一片只在算榜单时需要。浏览集因此退化成一份按安装量降序的 token 数组。
- `BrewPackageItem` 删掉 `stableVersion` / `license` / `homepage` / `kegOnly` / `deprecated` / `disabled` / `autoUpdates` / `mediaUrl`。行组件只渲染四项（`BrewPackageRow.ets:62/66/86/94`）：token、描述、分类内名次、30 天安装量。那些字段全仓库只有详情页的 `BrewDetailNormalizer` 读，而详情页本来就重新取单条；`mediaUrl` 从来没被赋过值，`preload()` 里那两个遍历是空转，一并删。

偏好存储从 6 个 key 减到 3 个：`brew_catalog` + `brew_meta_index` + `brew_meta_stamp` + `brew_live_data` + `brew_live_dataset` + `brew_detail_page_data` → `brew_table` + `brew_detail_cache` + `brew_detail_view`。后两个的分工见 3.6。

### 3.4 浏览集的成员规则

现在有两条路径（`BREW_INDEX_MIN_TRUST` 分叉）：主路径取「安装量 ∩ 描述索引」，降级路径取「安装量全量或前 100 个 + 逐条拉」。新设计只剩一条：

```
浏览集 = 安装量片的键 ∩ 描述片的键
```

描述片的键就是「上游当前存在这个包」的权威清单（来自 `formula.json` / `cask.json`），安装量片的键来自滚动窗口统计、天然含历史幽灵。取交集等于一次做完现在靠三样东西拼出来的效果：

- 幽灵 token 直接落选，不发请求，也不需要负缓存；
- cask 那 2645 条 `desc: null` 在落盘时不写空串，自然落选，与现在 `markMissing` 的结果一致；
- 上游新增但统计里还没有的包要等下一次同步才出现 —— 与现在主路径的行为相同，是已被接受的取舍。

`BREW_INDEX_MIN_TRUST`、`BREW_BROWSE_HYDRATE_LIMIT`、`BREW_MISS_TTL_MS` 以及 `splitMissing` / `markMissing` / `isKnownMissing` / `ghostSuffix` 随之消失。

三张榜的算法与门槛一字不改，只是输入从两份文档换成表的两片。

### 3.5 页面构建从遍历全量变成读引用

现在每次构页都要遍历整个宇宙：算覆盖率是一次 7900 元素的 filter，选候选集又一次，`formulaPage` 里再分组一次，然后逐项判分类、逐分类排序。这些在 `BrewService.ets:1150`–`1200` 之间，每次进页面跑一遍。

`browse` 在建表时算好后，构页变成读 `browse.formula`，一次引用。

`BrewBrowseBuilder` 现在有一句警告「不要缓存拼好的页面，目录一变缓存会挡住新结果」。这个顾虑在新设计里不成立：预计算的 `browse` 存在表内部，与表同生共死，表重建时一并重算，不存在「表更新了但页面还是上一次」的时间差。

### 3.6 详情页：唯一还在发单条的地方

浏览页、搜索页、榜单都不再读原始文档，A 类端点只剩详情页一个消费者。两个连带结果：

**数据集探针整层删掉**（`datasetProbe` / `brew_live_dataset` / `probeCache` / `rememberStamp`）。它是给「一次 hydrate 一百个」设计的：探一次 HEAD 省掉 100 个条件请求。详情页一次只用 1 个 token，而条件请求本身就是 0 字节，多加一次 HEAD 只多一次往返。

**详情缓存拆成两个 key**：

```
brew_detail_cache   // 按 kind_token 索引，条目 {ts, schemaVersion, lastModified, data}
                    // data 是原始文档，带 1 小时新鲜窗口 + If-Modified-Since
brew_detail_view    // 按 componentId 索引，存归一后的详情，没有新鲜窗口
```

分开的理由是条件请求的基准必须跟着条目活：`lastModified` 只存在于原始文档的响应头里，归一之后就没有了，而 UI 消费的是归一结果。把两者塞进一个条目就得在归一结果里补一个没有来源的 `lastModified`，或者让 UI 直接吃原始文档。分成两个 key 后，`brew_detail_cache` 专心回答「上游有没有变」（1 小时窗口 + 304 续期），`brew_detail_view` 专心回答「上次成功归一出来的是什么」（现网失败时的回落，无过期时间）。

`brew_detail_view` 就是旧的 `brew_detail_page_data` 换个名字 —— 它本来就是这个角色，换掉的是 `brew_detail_cache` 这一侧。`schemaVersion` 对不上直接当未命中。

### 3.7 一个世代号守卫

现在 `BrewCacheEpoch` 的世代号被 `flushEpoch` / `stampEpoch` / `catalogEpoch` / `BrewMetaSync.epoch` 四个静态字段各自捕获与比对，每个都配一段「为什么不在写入口改写 epoch」的注释。新设计只有两个字段：`BrewTable.epoch` 与 `BrewService.epoch`。两者都只在自己的取数入口捕获（`BrewTable.refresh()` 开头、`BrewService.fetchDoc()` 开头），写入时比对，不一致就丢弃这次的全部产物。

字段记的是「在场这一轮取数是在哪个世代开始的」，因此清空缓存的 `resetMemory` / `resetMemoryCaches` 只重置内存指针，**不改写它**。改成 `BrewCacheEpoch.current()` 就等于把在途那一轮的守卫亲自解除掉，刚清掉的表会被整份写回盘里。

`BrewMetaSync` 的「迟到落盘」（等待预算 90 秒、下载继续跑、结束时才写）原样保留，写入目标从索引文件换成表的两片。它解决的问题与本次精简无关。

### 3.8 健康状态只有两档

两片都成功过才算成功，其余一律「未就绪」。理由：部分失败之后能显示的内容本来就很少（只有一档榜有成员、或列表没有排序数字），为此单独设一个状态并在设置页上区分「哪一片挂了」，成本大于收益。

```ts
healthState(id) = (volReadyAt > 0 && descReadyAt > 0) ? OK : NOT_READY
```

失败原因保留为**诊断行**，不再参与状态判定：

```ts
interface ShardError { at: number, message: string }
record = {
  lastProbeAt, lastProbeOk, lastProbeReason,   // 连通性轴，不动
  volReadyAt, descReadyAt,                     // 由表的写入口写入
  volError: ShardError | null,                 // 纯诊断
  descError: ShardError | null
}
```

错误按片分开存，于是「成功时清掉同类错误」变成表写入口的自然结果 —— 写成功哪片就清哪片的槽，不需要 `noteCatalogOk` / `noteMetaOk` 里的清除逻辑，也不需要时间戳比较（现在那套比较正是为了绕过同毫秒内成功与失败互相覆盖而写的）。`catalogOkAt` / `metaIndexTokensAt` 两个字段随之删除，`noteError` 的三值词表（`catalog` / `meta` / `hydrate`）缩成两值（`vol` / `desc`），`hydrate` 整个消失 —— 精简后没有 hydrate 这条通道。

设置页的数据行当前由 `SHOW_SOURCE_DATA_LINE = false` 关着（`BrewSourceSettingView.ets:46`），所以这次删除对界面零影响：那行本来就没渲染。将来打开时，它只显示「已就绪 / 未就绪」加失败那片的说明文字，不再有第三种取值。

代价说清楚：`PARTIAL` 现在承担的唯一实际功能，是在生产环境让「镜像有单条文档但没有 analytics」这类局面可见。删掉之后它与「还在下载」在状态上无法区分，只能靠诊断行上的文字分辨。

### 3.9 四种组合的可见结果

| 安装量片 | 描述片 | Discover | Formulae / Casks | 搜索 | 健康 |
| --- | --- | --- | --- | --- | --- |
| 就绪 | 就绪 | 六张榜完整 | 完整 | 描述匹配 + 排序 | `OK` |
| 就绪 | 未到 | 六张榜有成员，行里只有 token 与数字 | 「正在建立本地数据」 | 只按 token 匹配 | `NOT_READY` |
| 未到 | 就绪 | 空榜 | 「无法获取数据」 | 描述匹配、无排序 | `NOT_READY` |
| 未到 | 未到 | 空榜 | 「无法获取数据」 | 无结果 | `NOT_READY` |

第二行是首次安装的正常暂态（描述片实测 21.7 秒，慢时到 578 秒），第三、四行只在上游异常时出现。界面呈现见 §6。

### 3.10 功能 ↔ 端点对应

| 功能 | 依赖端点 | 调用时机 | 频次 |
| --- | --- | --- | --- |
| Discover 榜单（成员、名次、安装量、增速、窗口日期） | C 类 4 个 | 进程启动后台一次；超过 6 小时窗口时续期 | 每 6 小时 4 个 |
| Formulae / Casks（分类、成员、名次、行文案） | C 类 4 个 + B 类 2 个 | 同上，两片各自独立 | 与进页面次数无关 |
| 搜索页 | 同上，读内存派生结构 | — | 0 |
| Discover 榜上条目的描述 | B 片 | 同上 | 0 |
| Discover 大图卡的 cask 显示名 | A 类，**至多 2 个** | 每次进 Discover 页 | 每次至多 2 个 |
| 详情页 | A 类 1 个 | 每次打开详情，1 小时内命中缓存 | 每小时 1 个 |
| 源探测 | D 类 1 个 | 用户点「测试连接」或切换源 | 每次 1 个 |

**端点类别 4 类（B、C 各 2 个 + A 按需 + D 探测）**；稳态下「启动 → 切遍五个页签 → 打开一个详情」= 6 + 1 个请求，与操作次数无关。

关于 Discover 的显示名：formula 的 `name` 恒等于 token（上游 formula 数组就是用 `name` 当标识的），所以只有 cask 需要真去取，而大图卡规则（`FEATURED_RULE`）里 cask 只占 2 条 —— 60 个请求降到 2 个。

### 3.11 冷启动时序

```
进程启动
  └─ refresh() 发出 6 个请求（安装量 4 + 描述 2），立即返回

用户 0.5 秒后点进 Formulae
  └─ current() 拿到「安装量可能已到、描述未到」的中间表
  └─ 显示「正在建立本地数据」，订阅表的落地通知

21.7 秒后描述片写入
  └─ 写 browse、算分类、刷盘、通知观察者
  └─ 页面重跑一次加载 → 完整内容

用户此后反复切页签
  └─ refresh() 比时间戳，两片都在窗口内 → 0 请求
```

现在的时序里，这 21.7 秒里进 Formulae 会走降级路径发 100 个单条请求、拖 15 秒、还可能只出零星几条；进 Discover 会发 60 个单条请求。新时序里这段时间只发那 6 个请求。

页面目前是 `aboutToAppear` 派发一次加载、然后等 Promise 返回的单次流程。表落地时如果页面已经在显示「正在建立本地数据」，需要有东西通知它重跑一次，否则这个状态会挂到用户手动切页签。做法是 `BrewTable` 暴露一个观察者列表，浏览页的 VM 在页面出现时订阅、消失时退订，`descReadyAt` 从 0 变成正数时回调一次，VM 重新派发加载。订阅必须成对 —— 现有的两处在途去重已经证明这个页面的生命周期回调会触发不止一次。

---

## 4. 改动清单

### 4.1 新增

- `features/brewcommon/src/main/ets/service/BrewTable.ets`
  表的形状、两片的新鲜度与取数判定、读写、世代号守卫、浏览集的相交规则、榜单与 `browse` 的预计算、落地观察者。
- `common/src/main/ets/view/StatePlaceholderView.ets`
  带文案与可见操作按钮的整页状态视图（见 §6.3）。

### 4.2 删掉

`BrewService.ets`（1616 行）中：

- `datasetProbe`、`rememberStamp`、`ensureStamps`、`conditionalFetch` 的探针分支、`datasetStamps` / `stampsDirty` / `probeCache` 三个字段
- `splitMissing`、`ghostSuffix`、`markMissing`、`isKnownMissing`、`missCache`
- `hydrate`、`noticeLiveDocs`
- `buildFormulaPage` / `buildCaskPage` 里的可信度分支；`formulaPageInFlight` / `caskPageInFlight` 的超时守卫随之删除（在途去重回到「同一次进页面合并两次触发」这个原始理由）
- `LiveFetchStats` 从 9 个计数收敛为两片各 3 个（命中、下载、失败）

`BrewRepository.ets`（850 行）中：`hydratePage`、`applyFormulaEntry`、`applyCaskEntry`、`fillCategoryKeys` 的时序约束、搜索里「目录缺失回落到索引键」的分支。

`BrewConstants.ets` 中 8 个常量：`BREW_INDEX_MIN_TRUST`、`BREW_BROWSE_HYDRATE_LIMIT`、`BREW_BROWSE_HYDRATE_MS`、`BREW_MISS_TTL_MS`、`BREW_HYDRATE_CONCURRENCY`、`BREW_HYDRATE_TIMEOUT_MS`、`BREW_LIVE_DATASET_KEY`、`BREW_PAGE_INFLIGHT_JOIN_MS`。

偏好存储从 6 个 key 减到 3 个：`brew_catalog` + `brew_meta_index` + `brew_meta_stamp` + `brew_live_data` + `brew_live_dataset` + `brew_detail_page_data` → `brew_table` + `brew_detail_cache` + `brew_detail_view`。

`BrewApiMapper.ets` 中：`applyFormulaItem` / `applyFormulaInstalls` / `applyCaskItem` / `applyCaskInstalls` / `rerankCategory` 五个方法全仓库零调用点（浏览页不再拉单条，分类内名次改由 `BrewBrowseBuilder.rankWithin` 在建表时算好）。`tokenId` 保留，它与 `BrewBrowseBuilder.tokenId` 是同一个函数。

`BrewSourcePrefs.ets` 中：`getSubValue` / `setSubValue` 零调用点，它们服务的 `brew_detail_page_data` 组键结构已经不存在。

### 4.3 改

- `BrewMetaSync.ets`（516 行）：从「独立索引同步器」变成「描述片构建器」，产物写进表。`BrewJsonScan`、`taskpool` 下载、迟到写入这些机制原样保留。
- `BrewCatalogAlgo.ets`：`build()` 的输入从两份 30d/365d 文档改为表的两片；新增「只有安装量片时的回落」（`prior` 恒为 0、`vol365d` 恒为 0，三张榜全空、浏览集无成员，因为浏览集由安装量排序驱动）。
- `BrewBrowseBuilder.ets`：`descOf` 简化为只读表；不再接任何 live docs，`formulaPage` / `caskPage` 直接返回分类结构。`formulaItem` / `caskItem` 删掉 `stableVersion` / `license` / `homepage` / `kegOnly` / `deprecated`（全仓库只有详情页的 `BrewDetailNormalizer` 读它们，而详情页本来就重新取单条）。
- `BrewModels.ets`：`BrewPackageItem` 同步删这 5 个字段，外加 `disabled` / `autoUpdates` / `mediaUrl`。
- `BrewCacheAdmin.ets`：`stats` / `clear` 改为按三个 key；`clear` 同时调 `BrewTable.resetMemory()` 与 `BrewService.resetMemoryCaches()`，否则内存里的旧表会在下一次写入时把盘上刚清掉的内容写回去。`clear` 与 `drop` 都要调 `BrewCatalogFile.delete` —— 归一化目录正文（约 3.4MB）在 `filesDir` 而不在 Preferences 里，只清 store 清不掉它，而 `BrewCatalogFile.readRange` 在偏移表缺失时会从残留正文重建索引继续供数。`clear` 在清盘完成之后调 `BrewTable.notifyObservers()`，让已挂载的页面立刻从「有数据」切到空态；这一次通知必须排在 `clearSync()` + `persistNow()` 之后，订阅者收到通知会立刻读盘，早一步通知会把还没被清掉的旧内容重新装进内存副本。
- `BrewSourceStore.ets`：`BrewSourceHealth` 从三值缩成 `OK` / `NOT_READY`；`healthState` 读表的 `volReadyAt` / `descReadyAt`；`noteError` 词表缩成 `vol` / `desc`；`noteCatalogOk` / `noteMetaOk` 合并进表的写入口（`noteVolOk` / `noteDescOk`）；记录里 `lastErrorKind` / `lastErrorMessage` / `lastErrorAt` 换成 `volError` / `descError` 两个分槽；`catalogOkAt` / `metaIndexTokensAt` 删除；`resetDataHealth` 相应简化。
- `BrewSourceSettingView.ets` 与文案：`dataTint` 的判断从「是不是 PARTIAL」改成「有没有分片错误」；`dataText` 的三个错误文案合成按片取；`brew_source_health_err_catalog` / `_meta` / `_hydrate` 换成 `_vol` / `_desc` 两条。`en_US` 必须与 `base`、`zh_CN` 同步改，否则旧 key 变成孤儿资源（这次就漏过一次，干净构建报了 5 条「无 base 资源」）。
- `BrewTable.bootstrapOnce()`：`refresh()` 第一次执行时打一行 `kind=cold_start` 原点日志并触发 `BrewMetaSync.runDiagnostics()`。这两件事原先挂在 `BrewMetaSync.start()` 上，而 `start()` 随索引同步器一起删了。

### 4.4 不动

`BrewHttp`、`BrewJsonScan`、`BrewSourceUrl`、`BrewSourceProbe`、`BrewSourcePrefs`、`BrewCacheEpoch`、`BrewLoadLog`、`BrewNetNotice`。

Harmonybrew 适配层的对外接口不变：它现在已经把两个方言归一到同一个 `CatalogAnalyticsDoc` 形状（`HarmonybrewStats.synth` 产出 `CatalogInput[]`，`BrewCatalogFile` 提供本地描述片），直接落到表的对应两片即可。详情页在 Harmonybrew 源下走的是本地文件读取（`HarmonybrewAdapter.fetchDoc`），也不受影响。

---

## 5. 行为变化

1. **首次安装、描述片还在下载时**，Formulae / Casks 显示「正在建立本地索引」状态，直到描述片写入。
   当前实现在同一段时间里给的是「15 秒等待 + 逐条拉 100 个 + 可能只出零星几条、分类判错」。后者更慢也更难看。
2. **浏览页、搜索页、榜单在稳态下零请求。**
3. **Discover 大图卡的 cask 显示名**改为按需取 2 个单条。
4. **详情页缓存拆成两份**（见 §3.6），条件请求行为不变。
5. **数据就绪状态从三档缩成两档**（见 §3.8）。`PARTIAL` 消失，「部分可用」这种局面不再有单独的表达 —— 一片成功一片失败就是「未就绪」。失败原因保留为分片诊断行。对界面零影响：该行当前由 `SHOW_SOURCE_DATA_LINE = false` 关着。
6. **两片组合只有两种需要区分的情况**。安装量片就绪、描述片未到（首次安装的正常暂态，实测 21.7 秒，慢时到 578 秒）：Discover 六张榜有成员、行里只有 token 与数字；Formulae / Casks 显示「正在建立本地索引」；搜索只按 token 匹配。安装量片未到：浏览集无成员（浏览集由安装量排序驱动），Discover 空榜，Formulae / Casks 显示「无法获取数据」，搜索仍可用（描述片本身就是一份可匹配的表，缺的只是排序数字）。两片都没到：全部无内容。

---

## 6. 失败与空态的界面

### 6.1 现有哪些

`common/src/main/ets/view/` 下有五个，全仓库共 8 处调用：

| 组件 | 形态 | 用在本次的哪一处不合适 |
| --- | --- | --- |
| `LoadingView(breakpoint)` | 居中转圈 | 只有转圈，没有文案。「正在建立本地索引」需要转圈加一句说明 |
| `DelayedLoadingView({breakpoint})` | 延迟 350/400ms 后显示转圈 | 同上；而且它的延迟是为了避开快速加载时闪一下，与本次场景相反 |
| `LoadingFailedView(breakpoint, handleReload?)` | `ic_failure` 图标 + 固定文案 `server_error`（「无法连接服务器，请稍后再试」），整块可点即重试 | 文案写死为「连不上服务器」，表达不了「上游数据源不可用」；重试是整块隐形点击，没有可见按钮；入参无法传文案 |
| `NoNetworkView(breakpoint, handleReload?)` | 同上图标 + `network_error` 文案 + 一个「设置网络」按钮跳系统 Wi-Fi 设置 | 补救动作绑死在网络设置上。用于「数据源地址不可用」会把用户引到错误的设置页 |
| `EmptyContentView(imgSrc, description, handleRefresh?)` | `Column` + 自定义图标 + 自定义文案 + 整块可点 | 形状最接近，可用三成：① 用 `layoutWeight(1)`，不能作为整页根节点填充；② 没有可见的操作按钮；③ 没有「加载中」变体 |

接线方式有两种：`BaseHomeView` / `BaseDetailComponent` 两个共享包装器，加上 5 处手写的同一条四分支判断（`BrewDetailView`、`BrewFormulaCategoryView`、`BrewCaskCategoryView`、`BrewDiscoverBoardView`、`MinePackagesView`，都在 `HdsNavDestination` 里）。

根因在枚举：`LoadingStatus` 里已经有一个 **`EMPTY_DATA`**（`CommonEnums.ets:26`），全仓库只有定义、零引用。「取数失败 → 空态」本来就该用它，现状是三个 brew 首页把它当 SUCCESS 处理，于是空数组一路渲染成空白页。

### 6.2 结论：新增一个，现有三个不动

以 `EmptyContentView` 的形状为准，补齐它的三个缺口后参数化，产出新组件。现有三个视图保持原样。

不合进 `LoadingFailedView` 的原因：它与 `NoNetworkView` 的纵向分布不同 —— 前者把图标与文案垂直居中，后者是「顶部留白块 + 图标文案 + 底部按钮 + SpaceBetween」。合并成一份会改变现有 8 处调用页面的版式，那不在本方案范围内。新组件与它们并存，靠入参语义区分：网络类用旧视图，数据类用新组件。

### 6.3 组件

位置 `common/src/main/ets/view/StatePlaceholderView.ets`，经 `view/index.ets` 导出（`common/Index.ets` 已有 `export * from './src/main/ets/view'`）。

```
StatePlaceholderView({
  kind: 'building' | 'empty' | 'failed',
  message: ResourceStr,          // 文案由调用方给 → common 不依赖 brew 的资源
  actionLabel?: ResourceStr,
  onAction?: () => void
})
```

- `building`：转圈 + 文案；
- `empty` 与 `failed`：`app.media.ic_failure` + 文案；`actionLabel` 与 `onAction` 都给了才渲染按钮；
- 尺寸沿用 `common` 已有的 `failure_size_sm/md/lg`（120 / 160 / 180vp）。

### 6.4 状态枚举

`LoadingStatus` 补一个 `BUILDING = 'building'`（表达「正在建立本地数据中」），`EMPTY_DATA` 直接启用。于是六个状态各自对应：

| 状态 | 呈现 | 用在 |
| --- | --- | --- |
| `SUCCESS` | 页面内容 | 正常 |
| `LOADING` | 转圈 | 快速返回的加载 |
| `BUILDING` | 新组件（building） | 描述片未到 |
| `EMPTY_DATA` | 新组件（failed + 重试按钮） | 安装量片未到 |
| `FAILED` | 新组件（failed） | 构页抛异常 |
| `NO_NETWORK` | `NoNetworkView` | 确实无网 |

`BaseHomeView` 增加 `BUILDING` 与 `EMPTY_DATA` 两个分支。

### 6.5 接线的四处

- `BrewFormulaHomeViewModel` / `BrewCaskHomeViewModel`：按表的两片置 `BUILDING` 或 `EMPTY_DATA`，不再置 SUCCESS 配空数组。
- `BrewDiscoverVM`：安装量片未到时置 `EMPTY_DATA`。
- `BrewDiscoverBoardVM`：榜单二级页同样接三档，另外把「骨架里根本没有这张榜」从 `FAILED` 改成 `EMPTY_DATA`（板块是 `BrewCatalogAlgo` 写死的 6 张，id 找不到说明表没建成）。
- `BrewFormulaCategoryVM` / `BrewCaskCategoryVM`：把 `cards.length > 0 ? SUCCESS : FAILED` 改成按两片判定，顺带拿到可见的重试按钮。
- 重试动作统一调 `BrewTable.refresh(true)` —— 强制刷新，跳过新鲜窗口判定。

三个首页 VM 各有一个 `refreshTable()`，由 `aboutToAppear` 调用。它转调非强制的 `BrewTable.refresh()`，内部按两片各自的新鲜窗口判定要不要真发请求，两片都在窗口内时一个字节都不发。这一条覆盖「上一轮取数失败、这一轮网络恢复」—— 失败的表不会自己复活，只靠 splash 那一次 `refresh()` 是不够的。

分类二级页有一个例外：Casks 的分类页在**不提供 cask 的数据源**下拿不到成员（源探测成功但 `caskInset` 为空）。这时保持 `SUCCESS` 配空列表，因为「这个源没有 cask」不是故障；`BrewCaskCategoryVM` 里 `adapterFor(id).supportsCask()` 那一支负责这件事，不要改成 `EMPTY_DATA`。

### 6.6 文案

common 的 `string.json`（base 与 zh_CN 各一份）新增三条：

- `state_building`：「正在建立本地数据，首次使用需要下载包描述列表」
- `state_no_data`：「无法获取 Homebrew 数据，请检查网络或数据源设置后重试」
- `state_retry`：「重试」

---

## 7. 验收

- 冷启动日志中不再出现 `[load] kind=live_docs`、`reason=degraded-hydrate`、`reason=degraded-prefix`、`kind=catalog_fetch reason=net-200` 之外的 browse 降级行。
- 一次完整操作串（冷启动 → 切遍五个页签 → 打开一个详情 → 返回）之后，`BrewHttp` 的请求行数 = 6（表的两片）+ 1（详情）+ 至多 2（Discover 大图卡）+ 探测若干。
- 断网冷启动：两个浏览页与搜索页有内容，Discover 六张榜有内容，页面底部显示的数据窗口日期与盘上表一致。
- 全新安装且断网：Formulae / Casks 显示 `EMPTY_DATA` 状态，文案说明原因，带可见的「重试」按钮（当前是空白页，见 `docs/brew-handover.md` §446 记录的已知取舍，本次一并处理）。
- 首次安装且有网、描述片未到：Formulae / Casks 显示 `BUILDING` 状态并带说明文字，描述片写入后页面自动重出内容。
- 三个 brew 首页的失败态有可见的重试按钮（当前 `LoadingFailedView` 只有整块隐形点击）。
- 「我的 → 数据源」把 `SHOW_SOURCE_DATA_LINE` 打开后，只出现「已就绪 / 未就绪」两种取值，失败时附上对应那一片的说明文字。
- `BrewSourceDiagnostics.run()`（`BREW_SOURCE_VERIFY=true`）全绿。

---

## 8. 边界

- 不改 `BrewTaxonomy` 的词表与三层判据。
- 不改 `BrewCatalogAlgo` 的门槛、分位数、family 去重口径，`check_algo.py` 的输出应保持一致。
- 不引入任何本地回落数据文件（内置快照已于 2026-10 全部删除，本次不回来）。
- 不碰 UI 版式与文案风格，只把「失败 → 空白页」换成「失败 → 有说明的状态」。