# 磁盘管家（F）· 设计

> 日期：2026-11-23。状态：评审即实施（需求方 AFK 授权自行决策，按决策账构建顺序第 2 位开工）。
> 范围：`features/brewcommon` 新增磁盘采样服务与解析器；`features/mine` 新增入口与磁盘管家页；
> `hmosword-build/brew-disk` 新增解析器检查脚本。执行通道**复用**既有 `BrewCommandRunner` + 执行 Sheet。
> 叙事定位：主线三「平时」第二拍——「brew 替用户看见磁盘」（H 是第一拍「主动说话」）。
> 排序依据：decisions.md 第一梯队第 11 条（F）+ 第 14 条（F+ 挂 F 同页同数据，本 spec 预留挂点不实现）。
> 采样依据：2026-11-23 设备实测（brew 7.0.9_7），原始样本见 §2——决策账里「先采样再写 spec」的欠账已清。

---

## 1. 目标与成功判据

brew 清出来的磁盘从不被看见；本页把 `cleanup / autoremove` 的 dry-run 结果翻译成**逐条可勾选的释放清单**：用户勾选、确认、走既有执行通道，释放了什么一清二楚。**护栏一致性：dry-run 只读、执行确认权在人、执行范围绝不超出用户勾选。**

| # | 判据 | 可观测证据 |
| --- | --- | --- |
| G1 | 「我的」页新增「磁盘管家」入口行（`isLocalPackagesEnabled` 门控，与更新哨兵同款），点击进 `DiskManagerView` | 真机 |
| G2 | 进入页面并行执行 `cleanup --dry-run` + `autoremove --dry-run`（两条只读命令），渲染两节清单 | `[disk]` 日志 |
| G3 | 摘要卡：brew 原文总量行（`approximately 320.4MB`）+ 已选合计（实时）+ 数据截至时刻 + 刷新按钮 | 真机 |
| G4 | cleanup 节按 **formula 勾选**（同 formula 多版本/`.tmp` 聚合为一卡，勾选即整卡）；节内全选；已选合计实时更新 | 真机 |
| G5 | 执行护栏：「释放所选」→ 确认弹层（列出 formula 名单与预计释放）→ `brew cleanup <names>` 走 `BrewCommandRunner` 执行 Sheet；执行完成自动重采样 | 真机 |
| G6 | autoremove 节为**整段开关**（设备实测 autoremove 不收参数）：零候选时显示「当前没有可自动清理的依赖」；有候选时清单只读展示 + 「自动清理依赖」按钮 → 确认 → `brew autoremove` | 真机 |
| G7 | brew 内部残留（portable-ruby 旧版本等）**展示但不可勾选**，标注「随全量清理处理」；「全量清理」为独立按钮 + 明确范围提示（清所有旧版本与缓存，范围大于逐条勾选） | 真机 |
| G8 | dry-run 失败分级：超时 / 命令失败（stderr 尾部进错误卡）+ 重试；`Skipping` 警告聚合成「N 个待升级包升级后可清」提示条 | 真机 |
| G9 | 数据诚实：一切数字来自 dry-run 原文（千分位逗号解析），合计为原文体积串求和换算，不估算、不编造 | 代码评审 |
| G10 | pc_normal 无入口（`isLocalPackagesEnabled` 门控，模块零改动）；双 product 构建通过 | `devecocli build` 双 product，ERROR 0 |
| G11 | 解析器检查脚本全绿（`node hmosword-build/brew-disk/check_disk_parser.mjs`，用例全部来自 §2 实测样本） | node |
| G12 | 执行完成后快照失效（`BrewInstalledLoader.invalidate()`）+ 重采样，卡片/详情页数据不陈旧 | 真机 |

## 2. 现状与采样事实（2026-11-23 设备实测，brew 7.0.9_7）

### 2.1 `brew cleanup --dry-run`（exit 0，58 行）

三段结构：

```
Warning: Skipping cups: most recent version 2.4.20 not installed
（…待升级包逐行，共 N 条——升级前不可清）

Would remove: /storage/Users/currentUser/.harmonybrew/Cellar/brotli/1.2.0_1 (33 files, 1.9MB)
Would remove: /storage/Users/currentUser/.harmonybrew/Cellar/openssl@4/4.0.3_1.tmp (6,820 files, 26.1MB)
Would remove: /storage/Users/currentUser/.harmonybrew/Homebrew/Library/Homebrew/vendor/portable-ruby/4.0.7_2 (1,700 files, 40.2MB)
（…逐行，共 M 条）

==> This operation would free approximately 320.4MB of disk space.
```

关键形态：文件数带**千分位逗号**（`6,820` / `1,700`）；同一 formula 多版本多行（lz4 两行、ca-certificates 两行）；`.tmp` 目录行；portable-ruby 内部组件行（非 formula）；路径不含空格。

### 2.2 `brew cleanup --dry-run lz4`（按名清理实测）

```
Would remove: /…/Cellar/lz4/1.10.0_1 (24 files, 806.5KB)
Would remove: /…/Cellar/lz4/1.10.0_2 (28 files, 823.8KB)
==> This operation would free approximately 1.6MB of disk space.
```

**cleanup 支持按名清理** → 勾选粒度 = formula，执行 = `brew cleanup <选中名>`，一次命令多名。

### 2.3 `brew autoremove --dry-run`（exit 0，零输出）与参数边界

- 设备当前零候选 → 空输出 exit 0（空态真实存在）。
- `brew autoremove --dry-run foo` → `Usage: brew autoremove [--dry-run]` → **autoremove 不收参数**，无条目粒度，整段开关。

## 3. 数据流与执行语义

```
进入 DiskManagerView（并行，互不阻塞）
  ├─ cleanup --dry-run  → BrewCleanupParser → CleanupItem[]（formula 分组）+ skipCount + totalText
  └─ autoremove --dry-run → BrewAutoremoveParser → 名称[]（空 = 空态）
        │
        ▼ 用户勾选（formula 粒度）
执行（走 BrewCommandRunner 执行 Sheet，确认权在人）：
  ├─ 释放所选：brew cleanup <选中 formula 名单>          （勾选粒度，范围=所选）
  ├─ 自动清理依赖：brew autoremove                        （整段开关）
  └─ 全量清理：brew cleanup                               （独立按钮，范围提示明确）
执行完成 → BrewInstalledLoader.invalidate()（快照失效）→ 自动重采样 → 清单刷新
```

- **解析器**：`BrewCleanupParser` / `BrewAutoremoveParser`（`features/brewcommon/src/main/ets/util/`，零 import、字符串常量、无模板字符串——`hmosword-build/brew-disk/check_disk_parser.mjs` 按 skill 线 .mts 技术跑真源码）。千分位逗号文件数（`[\d,]+` 去逗号）、体积串换算字节（`548.2KB` / `1.9MB` / `2.4GB` → bytes，供合计求和）、`Would remove:` 行按路径归类：
  - `/Cellar/<name>/<version>`（含 `.tmp` 尾）→ formula 条目；
  - `/Homebrew/Library/Homebrew/vendor/portable-ruby/…` → internal 条目；
  - 其余路径 → other 条目（展示为「其它残留」，随全量清理）。
- **条目模型**：`CleanupItem { kind, formula, path, version, files, sizeText, sizeBytes }`——`sizeBytes` 与 `path` 为 F+ Treemap 预留（同页同数据，本期不画图）。
- **执行命令拼装**：`BrewCommandGenerator.cleanupArgs(names: string[])`（`cleanup <空格连接的名>`，复用 `isSafeName` 校验）——与展示同一份拼装，防漂移。
- **超时**：dry-run 采样 120s（首次可能触发 API 元数据下载，设备实测）；执行命令走 `BrewCommandRunner` 既有超时与轮询。

## 4. UX 设计（本 spec 重点）

### 4.1 信息架构与入口

- 「我的」页在「更新哨兵」入口行**上方**新增「磁盘管家」行（HmosListItem 同款；`isLocalPackagesEnabled()` 门控，pc_normal 天然无此行）→ `PageEnum.DISK_MANAGER_VIEW = 'DiskManagerView'` → router_map 注册。
- 为什么放我的页：磁盘管家是「本机状态」类功能，与「本机包」同属设备侧；放设置页层级太深。

### 4.2 页面结构（自上而下）

1. **摘要卡**（常驻顶部）：
   - 主数字：brew 总量行原文（`约可释放 320.4MB`，来自 `approximately` 行，随最近一次采样）；
   - 次行：`已选 N 项 · 约 X`（X = 勾选项 sizeBytes 求和换算的人读串，实时跟随勾选）；
   - 角标：`数据截至 HH:mm` + 刷新图标按钮（重采样，转圈态）。
2. **旧版本残留节（cleanup）**：节标题 `旧版本残留` + 行内「全选」文本按钮；按 formula 分组的卡片列表，**每卡**：
   - 左：Checkbox（勾选粒度 = 整卡）；
   - 中：formula 名（Title_M）+ 版本 chips（该 formula 的全部待清版本，`1.10.0_1` `1.10.0_2`；`.tmp` 并入不单独展示）+ `N files · 1.6MB`（卡内求和）；
   - 卡片选中态：边框强调色 + 背景微变（复用 `comp_background_primary` / 强调色 token）。
3. **brew 内部残留节（internal，默认折叠）**：节标题 + 条数与合计；展开为只读行（无 Checkbox），行尾灰字「随全量清理」；节尾独立文本按钮「全量清理」。
4. **可自动清理依赖节（autoremove）**：空态（当前设备实测）显示一行说明「当前没有可自动清理的依赖」；有候选时：名称列表（只读，brew 整段判定不可逐条）+ 「自动清理依赖」按钮。
5. **底部悬浮操作栏**（复用 `BrewActionBar` 高度/遮罩语言）：
   - 主按钮 `释放所选（N 项 · 约 X）`——N=0 时置灰；
   - 点击 → **确认弹层**（AlertDialog）：标题「确认释放」、正文逐行列出所选 formula 与各自体积、尾行合计；「取消 / 确认释放」；
   - 确认 → `BrewCommandRunner` 发起 → **既有执行 Sheet** 接管（用户在 Sheet 里看进度与退出码——执行通道既有护栏原样生效）；
   - Sheet 报成功 → 关 Sheet 后页面自动重采样 + toast「已释放约 X」。
6. **「全量清理」与「自动清理依赖」**共用确认弹层模板，正文明确范围：全量清理文案必须写明「除所选外，还将清理所有旧版本与下载缓存」——范围不蔓延红线在文案层也要可见。

### 4.3 状态机（页面级）

- **加载骨架**：两节各一张骨架卡（首次进入）；
- **空态**：cleanup 零条目 + autoremove 零候选 → 居中「磁盘很干净，没有可释放的内容」；
- **陈旧态**：最近一次成功采样超 24h → 摘要卡降显「数据已过期，点击刷新」（对齐哨兵 G9 诚实口径）；
- **失败态**：dry-run 失败 → 对应节错误卡（分级文案 + stderr 尾部 + 重试按钮）；单边失败不影响另一节渲染；
- **执行互斥**：执行 Sheet 打开期间页面重采样按钮置灰；同一时刻只允许一个写命令在途（BrewCommandRunner 单飞既有约束）。

### 4.4 视觉基调

全部复用既有 token：卡片底 `comp_background_list_card` / 圆角 `corner_radius_level8` / 内边距 `padding_level4` / 字号 `Title_M` `Body_M` `Body_S`；强调色用系统 `font_emphasize` 与 `sys.color.brand`——**不引入新主题**。Checkbox 用系统 `Checkbox` 组件默认形态。

### 4.5 文案（§7 全表进 string.json ×3）

| 键 | zh |
| --- | --- |
| `disk_entry_row` | 磁盘管家 |
| `disk_summary_reclaimable` | 约可释放 %s |
| `disk_summary_selected` | 已选 %d 项 · 约 %s |
| `disk_asof` | 数据截至 %s |
| `disk_section_cleanup` | 旧版本残留 |
| `disk_section_internal` | brew 内部残留 |
| `disk_section_autoremove` | 可自动清理依赖 |
| `disk_select_all` | 全选 |
| `disk_release_selected` | 释放所选（%d 项 · 约 %s） |
| `disk_full_cleanup` | 全量清理 |
| `disk_autoremove_run` | 自动清理依赖 |
| `disk_internal_hint` | brew 自身组件旧版本，随全量清理处理 |
| `disk_autoremove_empty` | 当前没有可自动清理的依赖 |
| `disk_confirm_title` | 确认释放 |
| `disk_full_scope_hint` | 全量清理将清理所有旧版本与下载缓存，范围大于逐条勾选 |
| `disk_clean_done` | 已释放约 %s |
| `disk_empty_page` | 磁盘很干净，没有可释放的内容 |
| `disk_stale` | 数据已过期，点击刷新 |
| `disk_skipping_hint` | %d 个待升级包升级后才能清理旧版本 |

## 5. 失败态分级

| 场景 | 表现 |
| --- | --- |
| cleanup dry-run 超时（120s） | cleanup 节错误卡「采样超时」+ 重试；autoremove 节照常 |
| dry-run 命令失败 | 错误卡带 stderr 尾部 200 字 + 重试 |
| 采样时 brew 不可用 | 页面级错误态「设备上没有可用的 brew」+ 引导 |
| 执行失败 | 执行 Sheet 既有失败态（退出码/日志），页面不动清单，Sheet 关闭后可重采样 |
| 勾选后清单被刷新（重采样结果变化） | 保留仍存在的勾选、移除消失项，合计重算——不做静默全清 |

## 6. 安全与合规

- **护栏三线**：dry-run 只读（页面采样永不带执行语义）；执行范围 = 用户勾选（cleanup 按名；autoremove/全量清理为显式整段动作且有范围文案）；执行确认权在人（Sheet 既有确认 + 页面确认弹层双重）。
- 执行走 `BrewCommandRunner` 既有通道（单飞、日志、中断），**不新增执行路径**；dry-run 走 `BrewDiskService` 内部 `ShellUtils.run + BrewCli.commandLine`（只读命令白名单 `cleanup --dry-run` / `autoremove --dry-run`，拼装集中一处）。
- 快照：执行完成 `BrewInstalledLoader.invalidate()`——不新增数据文件。

## 7. 改动清单

| 文件 | 改动 |
| --- | --- |
| `features/brewcommon/src/main/ets/service/BrewDiskService.ets` | 双 dry-run 采样（并发合并、120s 超时）、条目模型、执行命令拼装白名单 |
| `features/brewcommon/src/main/ets/util/BrewCleanupParser.ets` | `Would remove` 行 + Skipping 计数 + approximately 总量；千分位/体积换字节 |
| `features/brewcommon/src/main/ets/util/BrewAutoremoveParser.ets` | 候选名列表（空输出 = 空态） |
| `features/brewcommon/src/main/ets/util/BrewCommandGenerator.ets` | +`cleanupArgs(names)`（isSafeName 校验） |
| `features/brewcommon/src/main/ets/constant/DiskConstants.ets` | 超时、条目上限、陈旧阈值 |
| `features/brewcommon/Index.ets` | 导出 |
| `features/mine/src/main/ets/view/DiskManagerView.ets` | 页面（§4 全部交互） |
| `features/mine/src/main/ets/view/MineHomeView.ets` / `MineSettingView.ets` 宿主处 | 入口行 |
| `common/src/main/ets/model/PageEnum.ets` + `features/mine/router_map.json` | 路由 |
| `features/{brewcommon,mine}/src/main/resources/{base,zh_CN,en_US}/element/string.json` | §4.5 文案 |
| `hmosword-build/brew-disk/check_disk_parser.mjs` | 解析器检查脚本（§2 实测样本为用例） |

## 8. 验证

1. **静态**：`node hmosword-build/brew-disk/check_disk_parser.mjs` 全绿（用例=§2 实测样本 + 千分位 + 多空格 + .tmp + internal 归类 + autoremove 空态）。
2. **构建**：双 product `devecocli build` ERROR 0（G10）。
3. **真机**：G1–G9/G12 逐条；关键路径：进入页面 → 勾选 lz4 + openssl@4 → 释放所选 → 确认 → Sheet 执行 → 完成后清单重采样为空（这几项已清）→ 总量下降约 1.6MB+26.1MB。

## 9. 风险与未决

- **F+ Treemap 挂点**：`CleanupItem.path/sizeBytes` 已备，treemap 数据源 = 本页同一次采样（含已装包当前占用可另加 `brew info` 补测——skill 线已有解析器可复用）；本期不画图，spec 不锁定 treemap 视觉。
- autoremove 空态是设备当前状态，非功能缺陷；有候选的形态（`Would uninstall`?）未采样到——解析器按「非空输出逐行取名」宽容处理，真机遇到新形态按 G11 用例补。
- cleanup 的 Skipping 块与 upgrade 联动（升级前不可清）——提示条只聚合计数，不做跳转升级的引导（避免跨功能耦合，升级入口在「待更新」页）。
- 体积串求和的单位换算覆盖 KB/MB/GB/B；brew 若出新单位按 G11 用例补。
