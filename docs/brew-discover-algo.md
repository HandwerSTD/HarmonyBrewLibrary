> **接手请先读 `docs/brew-handover.md`**（交接入口）。本文只管 Discover 推荐算法的现网口径。

# Discover 推荐算法（现网口径）

> 本文定义 **Discover 页签接真实 API 时的推荐算法**，是这套口径的唯一权威来源。
> 样例工程当前读的是**这份算法在某个时间点的一次冻结快照**（构建期生成，见 §7），
> 不是另一套并行实现 —— 所以这里的公式改了，快照要重新生成，不能只改一边。
>
> **修订说明**：本文是初稿的重写。初稿的数据源盘点方向正确、`install` vs `install-on-request`
> 的论证也是对的（已实测证实），但算法主体有几处会直接导致"今日热门"失效的设计错误。
> 全部用真实 API 数据核对过，逐条结论在 §6，**那些规则不要再加回来**。

---

## 1. 数据源

### 1.1 使用的端点（全部实测 200）

| 端点 | 用途 | 窗口 |
|---|---|---|
| `/api/analytics/install-on-request/homebrew-core/{days}.json` | **Formula 唯一口径** | 30d / 90d / 365d |
| `/api/analytics/cask-install/homebrew-cask/{days}.json` | **Cask 唯一口径** | 30d / 90d / 365d |
| `/api/formula.json`、`/api/cask.json` | 元数据（desc / deps / 生命周期） | 快照 |

### 1.2 明确不用的（含实测原因，不要再引回来）

| 不用的东西 | 原因 |
|---|---|
| `/api/analytics/install/homebrew-core/{days}.json` | **含依赖被动安装**。实测被动占比：`ca-certificates` **95.0%**、`aws-c-cal` **99.6%**、`jemalloc` **96.5%**、`s2n` **95.7%**、`llvm@22` **94.7%**。用它算趋势会得到一张**依赖包榜**，不是用户会主动装的工具 |
| `install-on-request/homebrew-cask/*` | **不存在**（实测 404）。Cask 没有 on-request 口径 |
| `install/homebrew-core/7d` | **不存在**（实测 404）。窗口只有 30/90/365 |
| GitHub commit / release 活动 | ① `formula.json` **没有任何发布日期字段**（只有 `deprecation_date` / `disable_date`）；② 未认证 GitHub API 只有 **60 请求/小时**，而 homebrew-core 是单仓库，按文件查 commit 历史撑不起这个用量 |
| 第三方图标源 `appcasks` | **2026-09-21 需求方决定：本轮不接入**（这是**决策，不是实测否决**，详见 §8）。⚠️ 原先写的"Cask 图标目前没有可用来源"**已被证伪**，别再照着它下判断：① `github.com/appcasks` 实测确实是 **404**；② `appfair/appcasks` 确实只是**已 archive 的空 Fork 模板**（`archived=true`、最后 push 2022-03-04、仓库根只有 `README.md`/`index.md`、无图标数据）；③ 但 **`App-Fair/appcasks`（App Fair 官方组织自己那份 fork）未归档**，releases 约 **40 页 × 100 ≈ 4000** 个 `cask-<token>` tag，**部分带 `AppIcon.png` 资产**。**覆盖率未量化**（对全量 7,745 个 cask 的对账没跑完即终止），**图片可用性与授权也未验证**（该仓库 `license: null`） |

**总量层面的对照**：同一个 30d 窗口，`install` 是 **14,612,885**、`install-on-request` 是 **5,742,755** ——
**on-request 只占 39%**，也就是说六成的安装事件是被依赖带进来的。这个比例本身就说明两个口径不能混用。

### 1.3 JSON 的真实结构（照初稿的描述写解析器会崩）

初稿说"每个 JSON 条目包含：包名、事件计数、**百分比**"。实际：

```jsonc
{
  "category": "formula_install",
  "total_items": 11691,          // 注意：与 formulae 的 key 数不同
  "start_date": "2026-08-17",
  "end_date":   "2026-09-16",
  "total_count": 14612885,
  "formulae": {                  // 是「token -> 条目数组」的字典，不是数组
    "a2ps": [ { "formula": "a2ps", "count": "41" } ]
  }
}
```

三个必须处理的坑：

1. **一个 token 可能有多条记录** → 必须求和，不能只取第一条。
   规模：30d 里 Formula **1,349** 个 token 是多条记录，**Cask 是 0 个** ——
   只拿 Cask 试会以为这条坑不存在；
2. **`count` 是带千分位逗号的字符串**（`"62,667"`）→ `int(c.replace(',', ''))`；
3. **没有 `percent` 字段**。

`start_date` / `end_date` / `total_count` / `total_items` **要存进快照元信息**做溯源 —— 页面上"基于最近可用数据的估算"这句话的日期就来自这里。

### 1.4 一条可依赖的结构性质

实测 **30d 的 token 集合是 365d 的子集，0 个缺失**（Formula 7,976 ⊂ 9,821；Cask 6,007 ⊂ 8,533）。所以 `365d − 30d` 可以直接相减，分母不用做缺失补偿。
反向不成立：365d 里有 1808 个 token 在 30d 中不存在（已死的包，`prior` 正常为 0，会被 §4 的规则滤掉）。

---

## 2. 度量口径：全程统一，不混用

初稿最致命的问题是在**同一个算法里混了两个口径**（趋势用 `install`，历史榜用 `install-on-request`）。
本文统一：

| 对象 | 口径 |
|---|---|
| Formula | `install-on-request`（30d / 365d） |
| Cask | `cask-install`（30d / 365d） |

**Cask 为什么可以用 `cask-install` 当"用户主动安装"的近似**：cask 之间几乎不存在依赖关系。
依据：本地 100 个 cask 详情样例中 `dependsOn.cask` 非空的有 **0 个（0.0%）**。
Formula 完全不能这么假设（同口径对比见 §1.2 的被动占比表）。这个依据的样本只有 100/6007，
接真机全量后应重新核一次。

---

## 3. 基础量与 family 去重

```
vol    = 30d 计数
prior  = (365d − 30d) / 11        # 此前 11 个月的月均
vel    = vol / prior              # 只在 prior > 0 时有意义
```

**分母不加 `max(1, ·)`。** 初稿加了，结果是新版本 token 的分母塌到 ~1、`vel` 炸到 **22636**
（实测 `llvm@22`：30d 1631、prior 1.4）。正确做法是把"没有历史"当成一个**独立的类别**，见 §5.3。

### 3.1 family 去重（一级规则，不是括号里的补充说明）

```
family(token) = token.split('@')[0]        # go@1.26 -> go；temurin@17 -> temurin
同 family 只保留 vol 最大的那个 token
```

规模实测：Formula 原始 7976 个 token → **7779** 个 family（80 个多版本 family）；
Cask 6007 → **5799**（152 个多版本 family）。

不做的后果很具体：`python@3.14`(51670) / `python@3.12`(38683) / `python@3.13`(25929) /
`python@3.11`(22562) 会一起挤进榜；`go@1.26` 与 `go@1.25`、`ffmpeg` 与 `ffmpeg@6/7/4` 同理。
用户要装的是 **family**，不是某个版本 token。

**例外**：`@` 后缀不是版本号时（如 `visual-studio-code@insiders`、`claude-code@latest`）
不应当归到主 family。用 `family_exceptions.json` 显式列出 ——
这是**数据归类**的例外表，与初稿 §5 的"人工审核结果白名单"是两件事（见 §6）。

---

## 4. 阈值（用快照分布标定，不写死绝对值后不管）

| 参数 | Formula | Cask | 标定依据（本次快照实测） |
|---|---|---|---|
| `VOL_FLOOR` | **500** | **200** | ≈ 两者 30d 分布的 p89（p90 分别为 610 / 221） |
| `MIN_PRIOR` | **50** | **20** | ≈ `prior` 分布的 p55（p50 分别为 39.3 / 15.9） |
| `NEW_FLOOR` | **300** | **300** | 新星榜下限 |

标定可用性已经验过（`check_algo.py` 实测偏差）：`VOL_FLOOR` vs 快照 p89 为 Formula **1.2%**、Cask **5.0%**；
`MIN_PRIOR` vs p55 为 Formula **2.5%**、Cask **0.9%**。这组数字是量出来的、不是猜的，
但**基数会漂移**，所以：

**每次刷新都要用分位数重算并落盘**，代码里读元信息里的值，而不是信这份文档里的数字 ——
流量基数会漂移，写死的绝对值迟早变成错误的门槛。

**设备端的现状（与上面这句的差距要说清楚）**：`BREW_CATALOG_CONFIG` 里存的是上表这组**标定值**，
设备端**不自动改门槛**，而是每次刷新**现算实际分位并打进日志**（`volFloor=500(p89实测 454, 偏差 9.2%)`）。
这么做的理由：阈值漂移是**需要人看一眼**的信号，静默自适应会把榜单的语义悄悄改掉
（“今日热门”的门槛忽然变了，而没人知道）；而偏差 > 20% 正对应 `check_algo.py` 第 3 条不变量，
两边用同一个判据。要更新标定值，改这一处并同步 `check_algo.py` 的 `CONFIG`。

---

## 5. 三张榜

### 5.1 趋势榜 / 今日热门

```
候选： vol >= VOL_FLOOR  且  prior >= MIN_PRIOR
排序： score = log1p(vel) * log1p(vol)      降序
```

`log1p` 两项相乘，含义是"**涨得快** 且 **本来就大**"，两个量级都被压到可加尺度。

**为什么不能只用 `vel`**：比率天然偏向极小分母。实测只看 `vel` 的榜单会推出
`tuicr`(30d 608)、`zcode`(757)、`android-cli`(620) 这类"几乎没人装"的包上首页。

**为什么不能 cap**：初稿建议 `cap 到 5.0`。实测候选集里 `vel` 的 p99 = **10.0**、max = **22637**，
而 `vel` Top50 **全部 50 个都 > 5.0** —— cap 会把整张榜压成同一个值，**把文档自己的核心功能废掉**。
用 log 压缩即可，排序永不 cap。

**展示可以 clamp，排序不行**：徽标文案可显示为 `↑3.2×`、尾部显示 `>10×`，
但这只影响文案，不影响排序值。

本次快照实测 top5：

| # | Formula | 30d | vel | | Cask | 30d | vel |
|---|---|---|---|---|---|---|---|
| 1 | `gascity` | 1,289 | 24.16 | | `vorssaint` | 16,796 | 36.32 |
| 2 | `sonic` | 13,527 | 7.01 | | `openlogi` | 8,542 | 20.25 |
| 3 | `libsndfile` | 3,791 | 7.35 | | `sentry-cli` | 1,999 | 35.30 |
| 4 | `gotestsum` | 944 | 10.76 | | `unity-cli` | 907 | 24.22 |
| 5 | `tuicr` | 608 | 11.88 | | `caskhub` | 3,751 | 12.59 |

### 5.2 历史榜 / 历史最佳

```
排序： 365d 降序（Formula 用 on-request，Cask 用 cask-install），family 去重
```

用 365d 累计量而非 30d，含义是"长期被主动选择"。**这条论证初稿是对的，实测证实**：
`ca-certificates` 在 `install` 365d 里排 **第 2**，在 `install-on-request` 365d 里排 **第 120** ——
说明它主要靠被依赖上榜，不代表用户主动想装它。

本次快照实测 top5：Formula `gh / node / awscli / uv / ffmpeg`；
Cask `claude-code / codex / gcloud-cli / docker-desktop / visual-studio-code`。

### 5.3 新星榜 / 新上架与上升

```
候选： vol >= NEW_FLOOR  且  prior < MIN_PRIOR      # 可观测的"没有历史"
排序： vol 降序
```

**不用"发布日期"**：API 里没有这个字段，实现不了。而且"365d 内无数据" ≠ "发布不足 12 个月"
（老包也会没数据）。改用"**没有历史但已经有量**"这个可观测量，语义更准且可算。

family 去重是**有意**让版本 token 不单独上榜（`llvm@22` 的 1631 会归到 family `llvm`）——
用户装的是 family。

本次快照实测：Formula **7 个**（`network-doctor` 363、`leaf-markdown-viewer` 354、`tailcat` 345…）；
Cask **4 个**（`cleanmymac-cli` 2053、`grok-bot` 1371、`crisp` 515、`homebrew-app` 382）。

### 5.4 Formula 与 Cask 不混排

口径不同（on-request vs cask-install）、基数也不同（family 7979 vs 5799），
**各自排名后再交错展示**，不放进同一个排序。

---

## 6. 卡片数据契约（不含版式）

每张榜的每个条目输出：

```jsonc
{
  "token": "gascity", "family": "gascity",
  "vol30d": 1289, "onReq365d": 1876, "priorMonthly": 53.4,
  "velocity": 24.16, "score": 81.2, "rank": 1
}
```

快照文件另附元信息（**用于溯源，页面上"基于最近可用数据的估算"就靠它**）：

```jsonc
{ "generatedAt": "...", "windowStart": "2026-08-17", "windowEnd": "2026-09-16",
  "totalItems": 11691, "totalCount": 14612885,
  "thresholds": { "volFloor": 500, "minPrior": 50, "newFloor": 300 } }
```

### 6.1 单 App 大图卡的选取（`featured`）

除了三张榜，快照还产出一个 `featured` 数组 —— **一张卡就是一个包**（初稿 §3.1 里
`[大图卡片] 今日热门 ← 横向滚动 2-3 张` 那一行，§3.2 列的字段也全是单 App 的：
图标 / 名称 / 一句话描述 / 安装量趋势 / 类别标签 / 排名徽章）。

选取规则是**编辑口径**，因此写进生成器落进数据（`generate.py` 的 `FEATURED_RULE`），
UI 不参与挑选、只做渲染 —— 与三张榜同理，换规则只改一处：

```python
FEATURED_RULE = (
    ('formula', 'trending', 2),   # 趋势榜 Formulae 前 2
    ('cask',    'trending', 1),   # 趋势榜 Casks 前 1
    ('formula', 'fresh',    1),   # 新星榜 Formulae 前 1
    ('cask',    'fresh',    1),   # 新星榜 Casks 前 1
)                                 # 共 5 张
```

`featured` 的条目比榜单条目多两个字段：`kind` / `boardKey` —— 用来显示「今日热门 · #1」
这类来源徽章，并决定卡片的主题色（与它来源的那张榜同色）。
榜卡本身**仍列 1-10 名**，所以前几名会在大图卡与榜卡上各出现一次；这是需求方确认的
「共存」选择，不是去重漏了。

> **这次差点永久丢掉这张卡。** 初稿 §3.1/§3.2 定义了它，我在重写本文时把「版式」整段
> 划归 `content-plan §7`（那里只有 `styleType 1/2/4` 分组、没有单 App 卡），
> 后来版式又改成"6 张榜卡平铺" —— 于是它从两份文档里同时消失，直到需求方问
> 「不是写了要分配几个应用作为单 App 大图卡吗」。
> **教训：把一段内容"划归别处"时要逐条清点里面有哪些规则，而不是整段搬走。**
> 版式可以搬，但 §3.2 那张字段表其实是**数据契约**，不是版式。

**版式不归本文管**。卡片长什么样（横向大图卡 / `styleType 1/2/4` 分组 / 大卡片）由
`docs/brew-marketplace-content-plan.md` §7 决定 —— 那里已规划 Discover 复用
`{bannerInfos, discoveryData}` 结构。本文只负责"哪些包、什么顺序、带哪些字段"。

---

## 7. 生成方式：**算法在两端各有一份实现**，设备端现算成员与数字

> **2026-09 更新（第二轮：成员也现网化）**：本节先后写过两版，务必按最新这一版理解。
> 初稿写的是“运行期不发请求”；第一轮改成“成员来自快照、数字来自现网”；
> **当前状态是：成员与数字都来自现网，在设备端**用本节定义的算法现算**。**
>
> - 设备端实现：`features/brewcommon/src/main/ets/service/BrewCatalogAlgo.ets`（算法）
>   + `BrewService.getCatalog()`（取聚合端点、条件请求、落盘、探针）；
> - 参照实现与自检：`hmosword-build/brew-mockgen/check_algo.py`（同一口径的可执行形式）；
> - **两份实现必须同步改**。只改一边的后果不是“差一点”，而是“同一天两个环境算出不同的榜”。
>   对账方式：设备端每次刷新会逐榜打前 10 名（`catalog top <kind>/<boardKey>`），
>   与 `python3 check_algo.py --fetch --print-top 10` 的输出逐名比对 —— 已实测一致（见 §7.4）。
>
> 内置快照（`brew-discover-page.json`）**没有退休**，但角色变了：它是
> ① 取不到目录时的回落；② `id` / `categoryKey` / `desc` 三个字段的**唯一来源**
> （本地主键与分类是自建词表，官方 API 没有）。见 §7.5。

**算法定义在现网 API 上，现在由设备端与生成器双方实现同一份口径。**

- 两端都拉 **4 个聚合端点**（`install-on-request/homebrew-core/{30d,365d}` +
  `cask-install/homebrew-cask/{30d,365d}`）——**只要两个窗口**，90d 只在初稿那个已删掉的
  `recent_installs = 30d − 90d/3` 里用过；
- 生成期的产物（`mockdata/brew-discover-page.json`）仍必须是**确定的**：同一份输入重复生成
  字节级一致 —— “重产出只改了受影响的文件”这条判据靠它；
- 快照的**日期与窗口必须写进文件**，否则页面上说的“最近可用数据”无从核对。
  Discover 产物的 `snapshotDate` 取**数据窗口结束日**，不是墙钟时间 —— 后者会让
  “同输入重复生成字节级一致”这条性质失效。设备端现算出的 `snapshotDate` 是**同一个口径**
  （取聚合文件里的 `end_date`），所以刷新后页面上那个日期会自动从快照日变成当天窗口，
  不会出现“成员是今天的、日期写的是快照日”的自相矛盾。

### 7.1 为什么必须用聚合端点，而不是现有详情数据

生成器现在拉的是**每包**端点 `/api/formula/<token>.json`，它的 `analytics.install_on_request`
**本来就含 30d/90d/365d 三个窗口**，所以现有 100 个包的 `installs30d/90d/365d` 直接可用
（口径也与 §2 一致：formula 走 `install_on_request`、cask 走 `install`）。
**但拿这批数据排不出趋势榜**：实测按 §5.1 的口径在 mock 这 100 个包里排，92/100 都能入选，
而榜首是

| # | 包 | 30d | prior | vel |
|---|---|---|---|---|
| 1 | `dust` | 4,529 | 2,297 | 1.97 |
| 2 | `uv` | 153,560 | 155,243 | 0.99 |
| 3 | `ffmpeg` | 139,822 | 141,453 | 0.99 |

—— 全是**稳态大包**（`vel ≈ 1`），等于把「历史最佳」重排了一遍。
真正的趋势榜首（`gascity` vel 24.16、`sonic` 7.01）**根本不在我们这 100 个里**。
"精选热门包"这个切片天然没有趋势信号，**趋势必须从全量宇宙（7,976 个 family）里算**，
所以要用 §1.1 的聚合端点。

代价是榜上的包可能不在现有详情数据里 → **必须把新出现的包补进详情**，否则点进去没有页面。
所以 Discover 快照的产物是两部分：三张榜 + 为榜上新包补的详情条目。

### 7.2 落地产物与生成器接线

| 产物 | 内容 |
|---|---|
| `mockdata/brew-discover-page.json` | 6 张榜（formula/cask × 趋势/历史/新星），每榜 Top 10；`meta` 带窗口起止、`total_items`/`total_count`、候选数与门槛值；`snapshotDate` = 数据窗口结束日 |
| ~~`mockdata/brew-{formula,cask}-details.json`~~ | **已删除（2026-09）**：当时为了让榜上的新包"点得进去"而补详情；现在详情骨架直接来自首页条目，不需要单独的详情文件 |

接线：`generate.py` 的 `build_discover()` 负责拉聚合端点 + join package id（id/分类/描述从 **page 条目**来），
**算法本身在 `check_algo.py`**，生成器只是调用它 —— 避免"文档一套、生成器一套"。
榜上出现但首页快照里没有的包，生成器会**打印警告**（`unmapped`）—— 设备端遇到同样的情形是
**直接不上屏**（拿不到本地 id 就点不进去），见 §7.5。

那条警告是刻意保留的：它把"榜上有包但点不进去"从运行期问题变成生成期可见的报告项。

**已观察到的固有不稳定性**：新星榜的绝对量很小（本次 306 ~ 2050），窗口滚动一天就会换人
（第一次算出 7 个、第二次只剩 4 个，`whisper.cpp` 进、`leaf-markdown-viewer` 等出）。
它是"确实没有历史、但已经有量"的真实写照，不是 bug；但 `NEW_FLOOR=300` 已经接近噪声底，
若要让这张榜稳定些，应把它也改成按快照分位标定（§4 的做法），而不是继续用绝对值。

### 7.3 自检脚本

`hmosword-build/brew-mockgen/check_algo.py` 校验以下不变量，退出码 0/1（用法见脚本头注释）：

1. 30d 的 token 集合 ⊆ 365d（§1.4）；
2. 候选集里 `prior` 全部 > 0，且**没有任何地方用了 `max(1, ·)`**；
3. `VOL_FLOOR` / `MIN_PRIOR` 与快照实际分位数的偏差 ≤ 20%（防止基数漂移后门槛失效，§4）；
4. 每张榜里**没有同 family 的重复条目**（§3.1）；
5. 趋势榜里**没有 `vol < VOL_FLOOR`** 的条目（§5.1）；
6. 趋势榜的 `score` 单调不增（排序正确）。

本次快照实测 **6 条不变量 × 2 类 = 12 条全部通过**，退出码 0。脚本同时会打印窗口起止日期、
`total_count`、以及"一个 token 多条记录"的个数 —— 这几个数字是 §1.3 那三个坑的现场证据。

### 7.4 设备端实现与实测对账

设备端把上面的算法搬了一份（`BrewCatalogAlgo.ets`，逐函数对应 `check_algo.py`）。
**两份实现要能用同一个判据对账**，所以设备端把 §7.3 那几条不变量需要的数字都打进日志：

```
catalog refreshed, took=1018ms, notModified=0/4 | formula raw=7916 fam=7721 cand=799
  win=2026-08-19~2026-09-18 total=5241086 multi=1278
  volFloor=500(p89实测 454, 偏差 9.2%) minPrior=50(p55实测 49.3, 偏差 1.4%)
  | cask raw=5863 fam=5659 cand=563 win=… multi=0 volFloor=200(p89实测 176, 偏差 12.0%)
catalog top formula/trending: 1.gascity=1170:18.23 2.sonic=11931:5.75 …
```

2026-09-18 窗口实测：**设备端与 `check_algo.py` 逐名一致**（token 顺序与所有整数完全相等，
`raw/fam/cand/fresh`、`total_count`、`multi`、`p89/p55` 全部对上）。
其中 `multi=1,278`（formula）与 `multi=0`（cask）与 §1.3 坑 1 记的数字一致。
两处已知的**显示级**差异（不影响排序）：

- 设备端把 `priorMonthly` 取整到 1 位后再算偏差百分比，所以 `1.4%` vs Python 的 `1.5%`；
- 顺序对等时（Ø 值相同的并列条目）两边的遍历顺序不同 —— 取整/并列只在尾部的实际数据上没出现，
  但换窗口后可能出现，对账时要看 token 而不是只看名次。

### 7.5 内置快照现在承担什么（别把 `brew-discover-page.json` 当废数据删掉）

成员现网化之后，榜单需要从快照里拿的只剩三样东西，而这三样**官方 API 根本没有**：

| 字段 | C 档之前 | C 档之后 |
|---|---|---|
| `id` | 只能来自快照（生成器分配） | **`token_id(token)` 哈希**，生成器与设备端同一个函数 |
| `categoryKey` | 只能来自快照（词表只在构建期跑过） | **`BrewTaxonomy`**（词表已移植到设备端） |
| `desc` | 快照里那份（离线可渲染） | **现网单条**（拿不到就留空，见 §7.5 上面的说明） |

也就是说：**榜单条目现在没有一项必须来自快照**，快照只剩"目录拿不到时的回落"这一个作用。

C 档之后**这条限制已经取消**：`id` 由 `token_id(token)`（FNV-1a）给出，详情页也能只用
现网单条 + `BrewTaxonomy` 渲染，所以榜可以就是**全球前 N**，不再跟任何"能点进去的白名单"求交。
日志里的判据跟着变成一行成员对照（`catalog members vs snapshot: <kind>/<boardKey> live=10 +[…] -[…]`），
它现在的作用是**看这次刷新换了谁**，而不是"能不能切"。

保留这段历史的原因：它记录了"成员曾被白名单锁住"这个阶段，以及当时的实测数字
（六张榜前 N 名 100% 能落到内置详情，所以那次切换是安全的）。

---

## 8. 待定项（明确不做假设）

| 待定 | 现状 |
|---|---|
| **Cask 图标 / 截图** | **本轮暂不接入外部图标源（2026-09-21 需求方决定）**，维持"终端输出风格"的无素材渲染（用真实 `desc`/命令文本画，不依赖图片文件）；快照里 banner 的 `mediaUrl` 仍为空。⚠️ **原结论"无可用来源"是错的**，更正后的实测事实见 §1.2。候选源是 **`App-Fair/appcasks`**，地址可预测：`github.com/App-Fair/appcasks/releases/download/cask-<token>/AppIcon.png`（抽样命中 `cask-zoom` / `cask-zotero` / `cask-zulip` / `cask-zterm` / `cask-mimestream` / `cask-spamsieve` / `cask-eaglefiler` 等）。**重启这件事的第 1 步是对全量 7,745 个 cask 做覆盖率对账，不是重新"找源"**；仍需一并确认图片可用性与商标/授权（该仓库 `license: null`） |
| Discover 版式 | 归 `content-plan` §7。初稿 §3 的 App Store 式横向滚动大图卡与那里已定的 `styleType 1/2/4` 是两套，**必须选一套**，不能两处并存 |
| 主题集合卡 | 方向可用，但要修正表述：**TF-IDF 是加权方案不是聚类算法**，做聚类还得选 k-means/DBSCAN；"多样性"是**集合级**的贪心约束，不能写成单品评分里的 `w4 × diversity_penalty_removed`（那不是可加的项） |
| 自动化边界 | 初稿 §2.4 说"要求完全自动化"、§5 又说缓解手段是"人工审核白名单"，自相矛盾。本文取**全自动**：只用可算的量（分位、家族、数量），把人工介入限制在 `family_exceptions.json` 这种**数据归类**层面，不做结果审核 |
| 依赖相似度推荐（"用了 X 你可能也要 Y"） | 可用（`formula.json` 有 `dependencies`），但排在三条主榜之后 |
| Cask 口径假设复核 | `dependsOn.cask = 0%` 只基于 100/6007 个样例，全量接入后重核（§2） |

---

## 附：初稿被证伪的规则（**不要加回来**）

| 初稿规则 | 实测反驳 | 本文处理 |
|---|---|---|
| `Velocity ≈ 1` = 常态 / `<<1` = 衰退 | 真实**中位数 = 0.50**，只有 **16.8%** 的包 > 1。跟 1.0 比会把大多数稳定包判成衰退 | 改为**同快照内排名**，不跟常数比（§5.1） |
| `cap 到 5.0` | p99 = 10.0、max = 22637，`vel` Top50 **50/50 全部 > 5.0** → 全被压平 | 去掉 cap，用 log 压缩（§5.1） |
| `30d < 100` 只降权不排除 | `vel` Top50 里 **32/50** 的 30d < 100（jcode 81 / leaves 70 / bashly 59） | 改**硬门槛** `VOL_FLOOR`（§4） |
| `TodayScore = 0.6×Velocity + 0.4×normalized(recent)` | 只归一化了 `recent`，没归一化无界的 `Velocity` → β 项被完全盖过。实测 Top50(Velocity) 与 Top50(TodayScore) **重合 50/50**，β 的 0.4 权重是惰性的 | 删掉加权和，改为单一定义的乘积分（§5.1） |
| 趋势用 `install`、历史榜用 `install-on-request` | 口径混用。`install` 榜实测被依赖包占据（被动占比 94.7%~99.6%） | **全程统一** on-request / cask-install（§2） |
| "发布不足 12 个月用自发布月均量" | API **没有发布日期字段**，无法实现 | 改为"无历史但已有量"（§5.3） |
| "只保留最近 30 天有版本更新的包" | 同样没有版本更新时间，`outdated` 不是日期 | 删除；新鲜度由**数据窗口本身**保证 |
| `w4 × diversity_penalty_removed` | 多样性是集合级属性，不能作为单品可加项 | 改为集合级贪心约束（§8） |
| "TF-IDF 关键词聚类" | TF-IDF 是加权方案，不是聚类算法 | 修正表述（§8） |
| "GitHub commit 活动每小时刷新" | 未认证 API 60 请求/小时，homebrew-core 是单仓库 | 删除（§1.2） |
| "每个条目含 percent 字段" | **没有该字段**；且 `count` 是带千分位的字符串、`formulae` 是字典 | 按真实结构写（§1.3） |
| "`appcasks` 提供 Cask 图标/分类/截图" | 初稿**方向不算错，是仓库引错了**：它引的 `github.com/appcasks` 是 404、`appfair/appcasks` 是已 archive 的空模板；而 **`App-Fair/appcasks` 未归档，且确有 `cask-<token>/AppIcon.png`**（§1.2） | **本轮不接入**（需求方决定 2026-09-21）；覆盖率未量化（§8） |
