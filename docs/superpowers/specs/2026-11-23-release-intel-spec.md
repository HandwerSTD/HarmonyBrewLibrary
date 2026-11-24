# Y · 更新情报中心(Release Intelligence)Spec

日期:2026-11-23 · 优先级:round6 优先深化项 · 前置:H 更新哨兵 spec(`docs/superpowers/specs/2026-11-22-sentinel-update-spec.md`)、AI Companion 一期(`docs/superpowers/specs/2026-11-22-ai-companion-spec.md`)
通道调研实证:`docs/knowledge/2026-11-23-release-channels-probe.md`(本 spec 全部网络结论均以该记录为准,未验证处显式标注)

## 0. 定位

H 哨兵回答「**有**更新」;Y 回答「这次更新**发生了什么、差在哪、值不值得现在更**」。Y 是详情页情报能力,不是通知通道——通知/卡片只管触达,H 的触达语义(「带我去」不是「替我跑」)不变。与 L 版本时光机互补:Y 在更新前解释、L 在更新后恢复(暂缓 backlog)。不做静默升级;「未发现重大变更」≠「保证安全」。

## 1. 目标与成功判据

- **G1 时效**:情报卡打开时,结构化区(徽章/依赖 diff)同步渲染;AI 摘要冷启动 ≤10s(atom 超时 5s + AI 超时 15s 上限内分级超时,任一环节超时走对应缺口文案,不整体白屏);缓存命中 <1s。
- **G2 tag 过滤零误报**:feed 中非目标版本的 tag(workspace 子包如 `ignore-0.4.34`、`globset-0.4.21`)不得渲染为主程序情报;匹配失败计入日志计数(ripgrep 为验收 fixture)。
- **G3 结构化 diff 零 AI**:依赖增删/uses_from_macos/caveats 变化/revision 全部来自 FormulaDiffer 代码路径,不经任何模型;可审计。
- **G4 AI 摘要 grounding 边界**:prompt 仅含 {token, from, to, 剥标签 notes ≤4KB, diff JSON};摘要文案必须带来源行「来自 {repo} release notes · 数据截至 HH:mm」;禁止输出 notes 与 diff 之外的事实。
- **G5 信息缺口三级**:仓库不可解析 / feed 无匹配 tag / notes 为空,分别有独立文案且**不渲染空 AI 区、不编造**(round6 边界)。
- **G6 策略生效**:「忽略本次版本」「暂停提醒」必须影响 H 哨兵通知计数与卡片「有更新」强调;「固定版本」只生成 `brew pin <token>` 命令文本供复制,**零执行**。
- **G7 档案留存**:更新成功后留档 {token, from, to, at, 情报快照引用},详情页「版本档案」区可见(有档案才显示,空不渲染)。
- **G8 成本护栏**:仅详情页入口懒加载(无后台批量拉取);缓存 TTL 24h + stale-while-revalidate;promptVersion 变更即失效;单包情报 AI 调用显式触发(对齐一期红线)。
- **G9 Stage-0 探针门**:首次进入情报卡前对 `github.com/{repo}/releases.atom` 做设备侧可达性探测(5s 超时);不可达 → 全局缺口卡「情报通道不可达」并显示原因,不做镜像轮询兜底(ghfast 不代理 atom,实证)。
- **G10 pc_normal 不出现**:情报卡依赖本机 outdated 上下文,pc_normal 产品不注册入口与路由。
- **G11 GSKV 硬规**:策略键写后必须 `BrewSourcePrefs.persistNow()`;世代号守卫「入口捕获+写前比对」,严禁 drop 分支改写 epoch(brew-api-design 硬规①②)。
- **G12 审计零执行**:`hmosword-build/brew-sentinel/audit_no_brew_in_touchpoints.mjs` 扩展扫描 ReleaseIntel 全部新文件,Y 触达面不得出现 BrewCommandRunner/BrewCli/ShellUtils 直接调用。
- **G13 隐私披露**:发送内容=包 token/新旧版本号/diff JSON/上游 notes 剥标签文本;不含用户标识;文案表与「我的→声明」同步更新。

## 2. 现状

- H 哨兵已定稿:`BrewInstalledLoader`(brew info --json=v2 --installed)→ `BrewSentinelService` → form + notification;通知去重=outdated fullName 排序哈希;频控 关/每天/每周;三档调度同代码换触发源。
- 一期 AI 底座可用:AiClient/AiCache/AiTasks/AiSettingsStore/BYOK/AiError E1–E6/缓存目录规约/promptVersion 机制(`features/brewcommon`);详情页已有 D1 讲解卡(`features/brewdetail/component/BrewAiExplainCard.ets`)、生命周期 banner(`BrewLifecycleBanner.ets`)。
- 详情页单条数据已有本地留存(`brew_src_<id>` store),为旧版 formula JSON diff 提供基线。
- 官方 API 无 changelog/What's New/包体积/更新时间——本 spec 通道即为此自建(见 §0 调研记录)。

## 3. 数据流 · 调度 · 降级

### 3.1 触发与调度(懒加载,无后台)

```
详情页打开 → outdated 上下文?(BrewInstalledDoc: installed[full_token].installed_version ≠ versions.stable)
  ├─ 否 → 不渲染情报卡(不发起任何请求)
  └─ 是 → 结构化区立即渲染:
       · SemverJudge(from=installed_version, to=versions.stable) → 徽章「大版本升级」
       · FormulaDiffer(newJson=当前单条详情, oldJson=store 缓存旧详情) → diff 区
       · 缓存命中(intelCache,<24h 且 promptVersion 同) → 摘要区直接渲染
       └─ 未命中 → Stage-0 探针(本次会话每 repo 仅一次)
            ├─ 不可达 → G9 缺口卡
            └─ 可达 → AtomFetcher(repo, 5s) → TagFilter → NotesExtractor → AiTasks.releaseIntel
```

- **FormulaDiffer**:新版单条 JSON(实时抓取)vs store 缓存旧版 JSON;对比字段 dependencies/build_dependencies/uses_from_macos/variations/caveats/revision/bottle.stable.rebuild/bottle sha256。「bottle 重打包」(stable 未变、revision/rebuild/sha256 变)单独成行,不冒充版本升级;版本比较遵循 version_scheme(probe 实测 wget=0/openssl@3=1);「有更新」判定元组与 H 保持一致:(versions.stable, revision, rebuild, bottle sha256 / cask sha256)。单条 JSON 抓取沿用 brew-api-design 三级缓存探针;GitHub Pages 瞬时 503 必须重试、404 才判不存在(probe 实测 ffmpeg/versions.json 首次 503、复测 404)。
- **RepoResolver**:homebrew API `homepage` 与 `urls.stable.url`(github archive 形态)双规则提取 owner/repo,规则顺序可解释(archive URL 优先,homepage 兜底);两者皆非 GitHub → 缺口 A。解析结果随情报缓存落盘。
- **AtomFetcher**:直连 `https://github.com/{owner}/{repo}/releases.atom`,5s 超时,entry 按 updated 降序全取(实测 feed 自带数量上限),不翻页。
- **TagFilter**:strip `v` 前缀后与 `versions.stable` **精确相等**才入选;`ignore-*`/`globset-*` 等子包 tag 天然不匹配;入选条目取 latest 单条(用户关心的是「从已装版本 → 最新」这一段)。旧版本段(where from ≥ entry tag)不重拉。
- **NotesExtractor**:content HTML 剥标签 → 折叠空白 → 截断 ≤4KB(截断处标注「已截断」进 prompt,防 AI 把截断当完整);author/时间仅用于展示行,不进 prompt。
- **AiSummarizer**(复用 AiClient;AiTasks 注册 `releaseIntel`):温度 0.2,非流式,输出 JSON schema:
  `{ one_liner:string, new_features:string[≤3], fixes:string[≤3], breaking_changes:[{title,impact,action}≤3], security_claims:[{claim}≤2], gaps:string[], confidence:"full"|"partial"|"none" }`
  - `security_claims` 仅允许转述 notes 原文中的安全自述,UI 强制标注「上游 notes 自述,非漏洞库核验」。
  - AI 失败(E1–E6)按一期降级:结构化区照常,AI 区不出现;无 Key 静默(受 `ai_settings_auto_explain` 同一开关约束,「重新生成」= force 旁路缓存)。
- **缓存**:`filesDir/brew_live/ai/release_intel/<token>/<to>.json`,meta 记 promptVersion(=ri-1)/fetchedAt/repo/etag 缺省;TTL 24h;stale-while-revalidate(先渲旧再拉新);纳入 BrewCacheAdmin 清理。diff 基线:store 旧详情缺失时 diff 区显示「未保留旧版本对照数据」,不影响摘要。

### 3.2 策略与 H 联动(最小侵入)

- `ReleaseIntelPrefs`(GSKV 键 `release_intel_prefs`):`ignored:{token:version}` / `paused:{token:untilTs|0=无限}` / pin 不落盘(pin 状态以 installed JSON `pinned` 字段为准,只读)。写后 persistNow(G11)。
- H 侧唯一改动点:`BrewSentinelService` 通知计数与去重哈希计算前,经 `ReleaseIntelFilter.isSuppressed(token, version)` 过滤(ignored 版本精确匹配、paused 时间窗内);详情页仍可看到被忽略更新(降显)。H spec 的通知哈希公式不变,只是输入列表先过滤。
- 固定版本:生成 `brew pin <token>` / 取消 `brew unpin <token>` 命令文本 → 复制(走 BrewCommandGenerator 与一期执行 Sheet 同路径,保持「下一步只复制不执行」)。

### 3.3 档案

- 更新成功事件(BrewCommandRunner upgrade 成功回调)→ append `{token, from, to, at, intelRef}` 至 `filesDir/brew_live/ai/release_intel/<token>/archive.json`(cap 20 条,超出淘汰最旧)。
- 详情页「版本档案」区:有档案才渲染;每行 from→to/时间,点击展开当时的情报快照(若缓存仍在)。为 L 版本时光机预留数据接口(字段对齐,不实现恢复)。

## 4. 交互与视觉

- 卡片位置:详情页 outdated 时,Hero → 生命周期 banner → **更新情报卡** → 安装命令卡 → 元信息条 → D1 讲解卡 → sections → caveats → **版本档案** → 同分类。情报卡与讲解卡视觉同族(卡片+分组标题),徽章用结构徽章样式(大版本=主题色描边、安全=警示色,均带「结构化判定/上游自述」小字区分)。
- 卡片结构:徽章行(大版本/安全声明数/依赖增删数)→ one_liner → 三分组(重大变更(含 impact/action)→ 修复 → 新功能;空组不渲染)→ 依赖变化行(直述:新增 n 个依赖(x/y…)、移除 m 个)→ caveats 变化行(若有,diff 文本折叠)→ 信息缺口行(三级文案)→ 来源行 + 操作行(固定此版本 ▾ / 忽略本次版本 / 暂停提醒 ▾ / 查看原文(外跳 `github.com/{owner}/{repo}/releases/tag/{tag}`))。
- 忽略/暂停的次级确认:暂停提供 7 天/30 天/无限 三档;被忽略版本在详情页顶部显示一行弱化条「已忽略 {version} 的更新提醒 · 撤销」。
- 「重新生成」入口放摘要区右上(与 D1 一致);无 Key 时整卡仅结构化区,不出现任何 AI 引导(对齐一期「无 Key 恒不自动也不引导」)。

## 5. 失败态分级

| 级 | 触发 | 表现 |
|---|---|---|
| F1 | Stage-0 探针不可达 | 缺口卡「情报通道不可达(网络无法直连 GitHub)」+ 重试按钮 |
| F2 | RepoResolver 无 GitHub 来源 | 「暂无可靠发布情报源(上游非 GitHub 托管)」 |
| F3 | atom 200 但无匹配 tag / feed 空 | 「上游未发布对应版本的说明」 |
| F4 | notes 为空/纯 bot tag | 「上游未附文字说明,仅有版本发布」 |
| F5 | diff 基线缺失 | diff 区「未保留旧版本对照数据」,其余照常 |
| F6 | AI 失败 E1–E6 | 复用一期降级;结构化区照常;E4 截断文案「输出被截断」 |
| F7 | 情报超 24h 且刷新失败 | 来源行加「数据截至 HH:mm(刷新失败,展示缓存)」 |

任何一级都不渲染编造内容;F2–F4 是「信息缺口」而非错误,视觉弱化(非红色)。

## 6. 安全与合规

- notes/caveats 为不可信文本:进 prompt 前视为数据非指令(一期 prompt 注入防御同款);AI 输出 JSON schema 校验,越权字段丢弃。
- 零执行红线全链:G6/G12;固定/忽略/暂停均为本地策略或命令复制。
- 隐私:G13 披露;外跳 release 页为系统浏览器,不带应用内凭据。
- OSV/漏洞库不接入(v1):安全识别仅「上游自述 + 来源标注」,不得表述为核验结论。
- pc_normal 编译门:情报卡代码置于 brewcommon/brewdetail 时须以 product 条件隔离入口(pc_normal 不注册详情页情报区,路由不注册)。

## 7. 文案表(中文)

| key | 文案 |
|---|---|
| release_intel_title | 更新情报 |
| release_intel_major | 大版本升级 |
| release_intel_security | 安全修复(上游自述,非漏洞库核验) |
| release_intel_deps_add | 新增 {n} 个依赖:{list} |
| release_intel_deps_remove | 移除 {n} 个依赖:{list} |
| release_intel_gap_repo | 暂无可靠发布情报源(上游非 GitHub 托管) |
| release_intel_gap_tag | 上游未发布对应版本的说明 |
| release_intel_gap_empty | 上游未附文字说明,仅有版本发布 |
| release_intel_gap_net | 情报通道不可达(网络无法直连 GitHub) |
| release_intel_gap_diff | 未保留旧版本对照数据 |
| release_intel_source | 来自 {repo} release notes · 数据截至 {HH:mm} |
| release_intel_pin | 固定此版本 |
| release_intel_ignore | 忽略本次版本 |
| release_intel_pause | 暂停提醒 |
| release_intel_archive | 版本档案 |
| release_intel_truncated | (上游说明过长,已截断) |
| release_intel_ignored_bar | 已忽略 {version} 的更新提醒 · 撤销 |

## 8. 改动清单

新建:
- `features/brewcommon/src/main/ets/service/ReleaseIntelService.ets`(编排:探针/拉取/过滤/缓存/AI 调用)
- `features/brewcommon/src/main/ets/util/ReleaseIntelRepoResolver.ets`
- `features/brewcommon/src/main/ets/util/BrewNotesExtractor.ets`(HTML 剥标签+截断)
- `features/brewcommon/src/main/ets/util/FormulaDiffer.ets`
- `features/brewcommon/src/main/ets/model/ReleaseIntelModels.ets`
- `features/brewcommon/src/main/ets/constant/ReleaseIntelConstants.ets`(缓存键/TTL/超时/promptVersion)
- `features/brewdetail/src/main/ets/component/BrewReleaseIntelCard.ets`
- `features/brewdetail/src/main/ets/component/BrewReleaseArchiveView.ets`

修改:
- `features/brewcommon/src/main/ets/service/AiTasks.ets`(注册 releaseIntel 任务)、`constant/AiConstants.ets`(常量)、`service/BrewCacheAdmin.ets`(新缓存目录)
- `features/brewcommon/src/main/ets/service/BrewSentinelService.ets`(通知计数前接 `ReleaseIntelFilter.isSuppressed`,哈希公式不变)
- `features/brewdetail/src/main/ets/view/BrewDetailView.ets`、`viewmodel/BrewDetailViewModel.ets`(outdated 上下文装配、档案区)
- `features/brewcommon/src/main/ets/service/BrewCommandRunner.ets`(upgrade 成功回调发档案事件,仅追加 listener,不改执行流)
- `features/mine/src/main/ets/view/StatementView.ets`(隐私披露增补)
- `hmosword-build/brew-sentinel/audit_no_brew_in_touchpoints.mjs`(扫描清单加 ReleaseIntel* 与 BrewReleaseIntelCard/BrewReleaseArchiveView)

不动:hmkit-ai、H 的通知/卡片 UI、form 能力、products/module.json5(无新 ability/权限;网络权限已有)。

## 9. 验证

1. 单测:TagFilter(ripgrep fixture:14.1.1 入选、ignore-0.4.34/globset-0.4.21 拒绝、v 前缀、计数)、RepoResolver(archive URL/homepage/GNU 三类)、FormulaDiffer(增/删依赖、uses_from_macos 变化、caveats 变化、revision bump、基线缺失)、SemverJudge(major/minor/patch/非 semver)、ReleaseIntelFilter(ignored 精确版本、paused 时间窗)。
2. fixture 化网络层:atom 样例 XML 落 `hmosword-build/brew-release-intel/fixtures/`,Service 测试不发真网。
3. 审计:G12 脚本通过(新增文件全绿)。
4. 编译门:`devecocli build --product pc_normal` 通过且情报入口零引用;`--product default` 全量过。
5. 真机 Stage-0:中国网络下探针门行为记录,结论回写 `docs/knowledge/2026-11-23-release-channels-probe.md`(追加设备侧一节)。
6. AI 端到端:配 Key 后对 ffmpeg/ripgrep/wget 三包走全程,核对 G4 来源行、G5 缺口(wget 应落 F2 或 F4,GNU 托管)。
7. 策略联动:忽略某包后哨兵通知计数减一、哈希变化、次日不复发。

## 10. 风险与未决

- **设备侧 github.com 可达性未知**(本调研走代理池):Stage-0 是硬门,若大面积不可达,Y 的 AI 摘要价值塌陷 → 届时评估镜像方案或降低为「仅结构化 diff」版本。**这是本 spec 最大未决。**
- tag ↔ formula 版本命名差异:部分项目 tag 带 `-release`/`v`/平台后缀,精确匹配会漏;v1 接受漏报(缺口文案),不做模糊匹配(防误报优先)。未决:统计 homebrew-core 中 homepage 为 GitHub 的比例与 tag 形态分布(P1 实施前抽样)。
- 体积差(+38MB demo)无数据源:bottle/cask 全链无字节大小字段(probe 实测确认),v1 显示「未知」,不承诺。
- cask 覆盖范围:v1 情报卡仅覆盖 formula;cask 版本变化判定可用 (version, sha256, bundle_version) 元组,但 sha256 可为 `"no_check"`、发布说明通道更弱(homepage 未必 GitHub)→ cask 详情页不渲染情报卡,记为未决。
- OSV 生态覆盖未确认(端点 404、文档迁移):漏洞库通道整体列 P2/未决,含可选 advisory token 的 BYOK 扩展形态。
- feed 深度:releases.atom 条目数由 GitHub 控制(实测约 10 条),高频发布项目可能不覆盖较旧版本段——v1 只解释「已装→最新」一段,不受影响;档案回看更早版本段时可能缺口(记入 F3)。
- archive 快照引用依赖 AI 缓存存活(BrewCacheAdmin 清理后档案只剩元数据行)——接受,文案不承诺全文回看。
- 与 AA Brew Preview(J 装机预演)的关系未梳理:AA 的 dry-run 解读(`BrewDryRunParser` 已存在)与本 spec 的依赖 diff 可能撞车,实施前对齐口径。

## 11. v1.1 增补(2026-11-24):AtomGit 打包通道(G14/F8)

**缺陷来源(用户实测反馈)**:harmonybrew 源的包「上游不是 GitHub 就获取不了」——Harmonybrew 的打包上游本来就不是 GitHub(tap 是 AtomGit 仓库 `Harmonybrew/homebrew-core`),formula 记录的 homepage 是原始项目页,RepoResolver 全部落 F2,AI 区恒空,情报卡只剩缺口。

### 11.1 通道实证(2026-11-24,详见 knowledge 文档 v1.1 一节)

- 打包上游 = AtomGit `Harmonybrew/homebrew-core`(组织页:「核心 tap,大部分 formula 搬迁自上游 Homebrew/homebrew-core」;目录同为 `Formula/<首字母>/<token>.rb` 分片)。
- AtomGit v5 API 文档允许匿名:`GET https://api.atomgit.com/api/v5/repos/{owner}/{repo}/commits?path=<file>&per_page=N`(GitHub v5 兼容形状);**实测匿名 429**(匿名共享 `p_repoRobot` 账号 10W/hour 配额,时忙时闲)。
- `raw` 文件通道不可用(返回 HTML 页壳);本地 git log 通道违反 G12 审计零执行设计,弃。
- 本地 diff/verdict 对 harmonybrew 包**可用**:HarmonybrewMap 已把目录记录映射成 official 形状(versions.stable 等字段齐),v1 卡在此的只有上游通道。

### 11.2 设计:双通道

- **GitHub 上游通道不动**(G9 探针门、TagFilter、NotesExtractor、AI 摘要全照旧);GitHub 托管 homepage 的包双通道并行。
- **新增 AtomGit 打包通道(仅 harmonybrew 源 + formula)**:`fetchPackCommits` 取「动过 `Formula/<x>/<token>.rb` 的最近提交」≤3 条 `{sha7, message 首行≤120, date YYYY-MM-DD, html_url}`;快照增 `packCommits[]`;情报卡增「Harmonybrew 打包记录」结构化组(分区空表整体不渲染)。
- **打包记录不进 AI**:commit message 简短、原样转述即可,AI 归纳价值低且引编造风险(P2 再议)。
- **429/404/网络失败 = 静默降级**:打包记录组不渲染,落一次 info 日志;**不重试轰炸**(匿名配额是共享资源);上游缺口行照旧诚实展示(G5 语义不变)。
- **G14 新增判据**:harmonybrew 源的 formula 详情页(已装且 outdated),情报卡除缺口行外必须呈现打包记录组(通道可达时);非 harmonybrew 源不发起 AtomGit 请求。
- **F8 新增失败态**:AtomGit 打包通道不可达/429 → 打包记录组不渲染(静默,不占缺口行——缺口行语义保留给上游通道)。
- 本地 git log 通道(读 tap 工作区)违反 G12,不做;access_token BYOK 形态列 P2。
- 文案增 `release_intel_pack_title`(Harmonybrew 打包记录);审计清单不变(ReleaseIntelService 仍零命令符号);改动文件:ReleaseIntelConstants/ReleaseIntelModels/ReleaseIntelService/BrewReleaseIntelCard/string.json×3/Index.ets/单测(shard path 两例)。

## 12. v1.2 增补(2026-11-24):打包通道移除 + AI 不可用降级渲染 notes 原文

**G14/F8 撤销(真机实证)**:临时关掉 AI 放出打包记录组观察,结论=**AtomGit tap 提交流全是机器人提交(迁移 bot),对用户完全没有信息量**。v1.1 的打包通道整段移除(constants/models/service/card/string/单测/Index 导出);harmonybrew 源的包回到「结构化 diff + 上游缺口诚实展示」的 v1 行为。通道实验的实证记录保留在 knowledge 文档 §8(不做无谓重试)。

**AI 不可用时的降级渲染(G5 补充)**:调试观察同时暴露第二个缺口——「更新日志」只经 AI 摘要渲染,无 Key/AI 失败/调试期关 AI 时这块整个空掉,用户感知为「抓不到」(cups v2.4.20 实证:release 正文完整存在,CVE 清单,但卡片不显示)。v1.2 起:

- 快照增 `notesPreview`(notes 原文节选 ≤700 字符,`RELEASE_INTEL_NOTES_PREVIEW_CHARS`);`card === null && !aiFailed && notesPreview 非空` 时卡片渲染「原始发布说明(节选)」组——**上游原文直接展示,零编造**(AI 只解释事实;没有 AI 就给事实本身)。
- **GitHub 空说明占位符识别**:未填写正文的 release,feed content 是字面量 `No content.`(ohos-selfsign 实证,10 条 release 里 8 条是占位符)——NotesExtractor 识别为空 → F4「该版本未填写发布说明」,占位符不进 AI、不进节选。
- 文案:`release_intel_pack_title` 删,`release_intel_notes_preview`(原始发布说明(节选))增。
- 「重新生成」按钮改为只在 `card !== null || aiFailed` 时渲染(结构化-only 视图不再有假按钮)。
- 单测:shard path 两例删,`notes_github_no_content_placeholder` 增(占位符→空;真实正文不受影响)。
- commits.atom(匿名可用、人类提交质量高,ohos-selfsign 实证)作为「无 release notes 仓库的候选通道」**暂不实施**——与打包通道同属提交列表形态,先看打包通道的教训;若要接,只接「notes 为空时」的兜底且须过滤 bot 作者,P2 议题。
