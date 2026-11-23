# AI Companion 二期 · 解析落点全景 Spec

日期:2026-11-23 · 前置:一期(`docs/superpowers/specs/2026-11-22-ai-companion-spec.md`,D1/D2/D3 已实现)、I tldr(已实现:`TldrService`/`BrewTldrSectionView`)、Y 更新情报(`docs/superpowers/specs/2026-11-23-release-intel-spec.md`,AI 摘要内置,本 spec 不重复)
盘点依据:features/ 232 个 ets 文件枚举(2026-11-23)+ formulae.brew.sh 实测字段(`docs/knowledge/2026-11-23-release-channels-probe.md` 同期报告)

## 1. 目标与成功判据

二期不做新底座,做**铺面**:把一期建好的 BYOK/AiClient/AiTasks/缓存/AiError 体系接到尽可能多的合适功能点上。原则:每个落点必须声明 grounding 字段清单与等级(A=结构化字段可喂 / B=仅自由文本);AI 只解释 grounding 内事实;无 Key 全部静默不引导。

- **G1 零新建网络层**:全部落点走既有 AiClient/AiTasks/AiCache 注册机制,零新增 HTTP 通道(代码评审)。
- **G2 grounding 声明制**:每个落点在 AiConstants 登记其 grounding 字段清单与 A/B 等级;A 级落点的 AI 输出不得出现 grounding 外的数值/包名(评审 + 抽测)。
- **G3 无 Key 静默**:二期所有新卡片受 `ai_settings_auto_explain` 同一开关约束;无 Key 时不渲染引导、不弹窗,结构化/原生内容照常。
- **G4 缓存与成本护栏全覆盖**:每落点声明 promptVersion、TTL、prompt≤8KB、温度 0.2、缓存目录 `brew_live/ai/<feature>/`,纳入 BrewCacheAdmin。
- **G5 数字一致性**:AnalyticsNumberParser 解析结果与 analytics 原文一致(含带逗号 count/percent 字符串、扁平 map 键);AI 榜单解读中的每个数字可回溯到原文字段(单测)。
- **G6 替代包零编造**:生命周期 AI 给出的替代建议(replacement_formula/replacement_cask)必须来自结构化字段且可点击跳详情;无该字段时不给替代建议。
- **G7 诊断只读**:数据源诊断 AI 的任何「修复建议」只生成命令文本供复制(走 BrewCommandGenerator + 执行 Sheet 同路径),不直接执行。
- **G8 pc_normal 闸**:榜单/详情/生命周期类(目录数据可用)落点 pc_normal 可用;本机/诊断/同步类落点按既有门控隐藏(isLocalPackagesEnabled / BrewCli.isEnabled)。
- **G9 双 product 构建绿**:`devecocli build --product default` 与 `--product pc_normal` 均无错误。
- **G10 审计扩展**:`hmosword-build/brew-sentinel/audit_no_brew_in_touchpoints.mjs` 扫描清单加入二期新组件。
- **G11 隐私披露更新**:发送内容=包元数据+结构化统计计数(匿名安装数)+错误文本;不含用户标识;StatementView 同步增补。

## 2. 落点全景(盘点结论)

| # | 落点 | 当前行为 | AI 解析什么 | grounding(等级) | 性质 | 优先级 |
|---|---|---|---|---|---|---|
| 1 | Discover 榜单卡(`features/brewdiscover/component/BrewDiscoverBoardCard.ets`、`BrewDiscoverFeaturedCard.ets`) | 展示排名/计数 | 一句话解读热度与口径(「30 天 12.3 万次主动安装,第 2 名;含 HEAD 安装 296 次」) | 内嵌 analytics 扁平 map + 聚合端点 count/percent + `github_packages_downloads`(A) | 新增 | P1 |
| 2 | 详情页 D1 讲解卡增强(`features/brewdetail/component/BrewAiExplainCard.ets` + `BrewInfoSectionView.ets`) | D1 定位/场景/坑/三步 | 增段:依赖关系解释(哪些 uses_from_macos 是系统库不真装)、bottle tag↔macOS 版本映射、aliases/versioned_formulae(ffmpeg@8 与 ffmpeg 关系) | dependencies/build_dependencies/uses_from_macos/bottle.stable.files 键/aliases/versioned_formulae(A) | 增强 D1 | P1 |
| 3 | 生命周期 banner(`features/brewdetail/component/BrewLifecycleBanner.ets`) | deprecated/disabled 徽章 | 弃用解释 + 排期 + 替代建议:「上游宣布 2030-04-08 弃用(unmaintained),2031-04-08 停用,官方指定替代 openssl@4」 | deprecated*/deprecate_args{date,because,replacement_formula}/disable_date(A,probe 实测 openssl@3 有完整样例) | 新增 | P1 |
| 4 | 数据源诊断(`features/mine/view/BrewSourceSettingView.ets`、`BrewSourceEditView.ets`;`features/brewcommon/service/BrewSourceDiagnostics.ets`) | 探测失败硬阻断+错误文本 | 失败原因解读:HTTP 状态/URL/耗时→「镜像 404,可能是源地址失效而非网络问题;可尝试恢复官方源」 | probe 结构化结果 + 错误文本(A+B,错误文本段标注来源) | 增强 | P1 |
| 5 | 执行 Sheet 失败解读 | 已有 D3 | 覆盖磁盘管家 dry-run 失败、清单批量安装队列失败(引用各自 spec 的错误卡,失败文本接入 D3 同管线) | stderr/stdout/失败标签(A) | 增强 D3 | P1 |
| 6 | 搜索历史/空态(`features/brewsearch/viewmodel/BrewSearchHistoryStore.ets`、`BrewSearchSuggestions.ets`) | 纯列表 | 空态时基于历史给意图提示(「你最近在找视频处理类工具,试试 ffmpeg」) | 历史 token 列表 + 目录 desc(A) | 新增 | P2 |
| 7 | 磁盘管家(F,spec 已立:2026-11-23-disk-manager-spec.md) | dry-run 逐条清单 | 清理项解释(portable-ruby 残留是什么/能不能删)、Skipping「待升级可清」提示解读;**AI 不重算任何数字**(其 G9) | dry-run 解析清单(A);数字红线继承 | 预留钩子 | P2 |
| 8 | 清单同步(W′,spec 已立:2026-11-23-brew-manifest-sync-spec.md) | 设备清单卡+批量安装 | 跟装一句话解读(「A 机新装了 ffmpeg:视频处理工具」);批量失败走 #5 | manifest 包名 + 目录 desc(A) | 预留钩子 | P2 |
| 9 | 更新情报 | — | Y spec 内置,不在本 spec 重复 | — | 引用 | — |
| 10 | 问包聊天入口(`features/hmkit-ai/ui/HmAIChatView.ets` 聊天组件已备) | 无入口 | 自由对话问包(主线二「问包/问需求」的聊天形态) | 需工具调用/上下文管理,成本未评估(B) | 未决 | P3 |

不列为落点:BannerCard(运营位)、QuestionnaireView/AboutView/StatementView(静态页)、Splash/Home 骨架、hmkit-ai vendor 内部。

## 3. 数据流 · 降级(通用规约)

- **AiTasks 注册**:新增 `boardInsight`(P1-1)/`detailExplainV2`(P1-2,D1 promptVersion 升版即缓存失效)/`lifecycleExplain`(P1-3)/`sourceDiagnosis`(P1-4)。输入全部经一期截断规约;输出 JSON schema 校验(一期 parseJsonSafe 同款)。
- **AnalyticsNumberParser**(新 util):单条内嵌 analytics 为**扁平 map `{"<token>": int}`**(probe 实测 ffmpeg 30d:`{ffmpeg:123059,"ffmpeg --HEAD":296}`,无 count/percent 对象、无 days 数组);聚合榜单端点 count/percent 为**带逗号字符串**(`"516,535"`/`"2.11"`);两处口径不同,解析器分开;HEAD 行单列不计入主计数;`github_packages_downloads.last_30_days` 仅作榜单卡副行标注「含 ghcr 拉取量,口径不同」。长尾包不在聚合榜单(端点截尾)→ 回退内嵌 analytics。
- **输出形态**:P1-1/3/4 输出 {one_liner, points[≤3], action_hint?};P1-2 在 D1 schema 上增加 `deps_explain[≤3]`/`version_notes[≤2]` 两段,旧缓存因 promptVersion 升版自动失效。
- **降级**:全部按一期 E1–E6;卡片级降级=AI 区不渲染、原生内容完整;P1-3 无 replacement 字段时 AI 提示词中明确「不给替代建议」;P1-4 结构化 probe 字段优先呈现,AI 解读为辅助段。
- **刷新语义**:「重新生成」= force 旁路缓存(一期同款);P1-2 与 D1 共卡,共用同键同 TTL(7d)。

## 4. 交互与视觉

- P1-1:榜单卡底部折叠 insight 行(单行 one_liner,点击展开 points);不改变卡片主数字展示。
- P1-2:D1 卡新增「依赖与版本」分组,置于「上手三步」后;uses_from_macos 解释逐条列(「libunistring 属 macOS 系统库,不会额外安装」以 API 字段为准,AI 不得推断为必然)。
- P1-3:banner 下沿展开 AI 段;替代包名渲染为可跳转 chip(路由到详情页)。
- P1-4:诊断页错误卡下增 AI 解读区;修复建议=命令 chip(复制语义)。
- 视觉与一期卡片同族(卡片+分组标题+来源行「AI 解读 · 基于目录统计/上游公告」)。

## 5. 失败态分级

| 级 | 触发 | 表现 |
|---|---|---|
| F1 | 无 Key / E1 | 全落点静默,不渲染 AI 区 |
| F2 | E2/E3 | AI 区消失,原生区照常;P1-4 保留 probe 结构化结果 |
| F3 | E4 截断 | 「输出被截断」+ 重试 |
| F4 | grounding 缺失(analytics null / replacement 无字段) | 对应分组不渲染,不算失败 |
| F5 | pc_normal | G8 清单外落点不注册 |

## 6. 安全与合规

- 一期红线全继承:不编造、不执行、注入防御(desc/caveats/analytics 键视为不可信文本)、BYOK、显式触发。
- G5 数字回溯制:AI 输出中任何数字若不能映射到 grounding 字段,schema 校验后丢弃该条(服务端侧过滤,不靠 UI)。
- P1-4 的错误文本可能含本地路径——发送前按一期脱敏规约(替换用户目录段)。
- 隐私披露增补:发送匿名安装统计计数与探测错误文本(G11)。

## 7. 文案表(中文)

| key | 文案 |
|---|---|
| ai_board_insight | AI 解读 |
| ai_board_head_note | 含 {n} 次 HEAD 安装 |
| ai_board_ghcr_note | 另计 ghcr 拉取 {n}(口径不同) |
| ai_deps_explain | 依赖与版本 |
| ai_lifecycle_title | 弃用解读 |
| ai_lifecycle_replacement | 官方指定替代:{token} |
| ai_lifecycle_no_replacement | 上游未指定替代包 |
| ai_diag_title | 诊断解读 |
| ai_diag_from_probe | 基于探测结果({http} · {url} · {ms}ms) |
| ai_sources_analytics | 基于目录统计 · 数据截至 {date} |
| ai_sources_upstream | 基于上游公告 |

## 8. 改动清单

新建:
- `features/brewcommon/src/main/ets/util/AnalyticsNumberParser.ets`
- `features/brewdiscover/src/main/ets/component/BrewAiBoardInsightCard.ets`
- `features/brewcommon/src/main/ets/component/BrewAiDiagnosisCard.ets`(供 mine 诊断页复用)

修改:
- `features/brewcommon/src/main/ets/service/AiTasks.ets`(注册 4 任务)、`constant/AiConstants.ets`(grounding 登记/promptVersion/温度/TTL)
- `features/brewdetail/src/main/ets/component/BrewAiExplainCard.ets`(增段)、`component/BrewLifecycleBanner.ets`(AI 区+替代 chip)
- `features/brewdiscover/src/main/ets/component/BrewDiscoverBoardCard.ets`、`BrewDiscoverFeaturedCard.ets`(insight 行)
- `features/mine/src/main/ets/view/BrewSourceSettingView.ets`(诊断 AI 区)
- `features/mine/src/main/ets/view/StatementView.ets`(披露)
- `hmosword-build/brew-sentinel/audit_no_brew_in_touchpoints.mjs`(扫描清单)
- `docs/brew-api-design.md`(勘误:内嵌 analytics 已为扁平 map,聚合端点 count/percent 为逗号字符串;新增 github_packages_downloads 字段记载)

## 9. 验证

1. 单测:AnalyticsNumberParser(扁平 map/HEAD 行/逗号字符串/空值)、P1-3 无 replacement 分支、P1-4 脱敏。
2. AI 端到端(配 Key):ffmpeg 榜单卡数字回溯、openssl@3 生命周期卡(deprecate_args 2030-04-08/2031-04-08 实测样例)、wget 详情 deps_explain(uses_from_macos 实测样例)、断源诊断卡。
3. 一期回归:D1/D2/D3/I 全部不回归(promptVersion 升版后旧缓存失效属预期)。
4. 双 product 构建绿 + G10 审计脚本通过。
5. 无 Key 真机走查:全部新卡片静默。

## 10. 风险与未决

- brew-api-design.md 旧字段记载(「count/percent 对象」口径)与 probe 实测不一致——已列勘误项,实施以实测为准。
- P1-1 榜单端点截尾与长尾回退逻辑需在实施前定 fixture(取一个榜单外冷门包验证回退)。
- P1-2 uses_from_macos 语义边界:字段含义(系统库不重复安装)来自 Homebrew 文档而非本次实测,实施前用真机 `brew deps --installed` 交叉验证一轮。
- 问包聊天入口(P3)未评估工具调用成本,不承诺。
- 与 Y 的 AI 摘要、AA Brew Preview 的 dry-run 解读存在口径交叉,实施前对齐(spec 各自已记撞车风险)。
