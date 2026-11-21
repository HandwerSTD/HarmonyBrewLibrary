# BrewLibrary

<p align="center"><img src="docs/icon/icon_1024.png" width="120" alt="BrewLibrary"></p>

BrewLibrary 是一个面向 **HarmonyOS PC（2in1）** 的 Homebrew 包浏览器：用桌面端布局浏览 Homebrew 的 formulae / casks，支持榜单发现、离线全文搜索、包详情与本机安装状态查看。

* 设备形态：仅 2in1（PC），最小窗口 1080 × 608

* 编译目标：HarmonyOS 6.1.0（API 23），hvigor 模型 5.0.0

* 版本：1.3.0

## 功能

| 页签       | 说明                                                       |
| -------- | -------------------------------------------------------- |
| Discover | 六个榜单推荐。榜单成员与数字在设备端现算，目录不可用时显示空态                          |
| Formulae | formulae 目录：分类 chips + 列表 + 详情页                          |
| Casks    | casks 目录，与 formulae 共用同一套组件与详情页                          |
| Search   | 本地搜索引擎（零依赖纯函数引擎 + 词表打分），离线可搜                             |
| Me       | 本机已安装 / 可升级包（列表页可按 chip 隐藏作为依赖安装的包）、数据源切换与连通性状态、页面可选区块开关 |

> 两个 entry 版本的功能差别只有「本机包」这一块：`pc_acl` 在「我的」页展示本机包三块，并读取设备上的 Homebrew 安装记录；`pc_normal` 不申请 `CUSTOM_SANDBOX` 与 `READ_WRITE_USER_FILE`，`PcAbility` 向 `AppStorage` 注入 `StorageKey.BREW_CLI_ENABLED = false`，「我的」页改为展示「激活本机包管理功能」卡片（点击把开源仓库地址 `https://gitcode.com/handwer/HarmonyBrewLibrary` 交给系统浏览器），本机包取数静默返回空集合。其余页签与页面在两个版本上表现一致。

## 数据来源

| 来源                                                    | 用途                                |
| ----------------------------------------------------- | --------------------------------- |
| formulae.brew.sh/api（官方上游）                            | 包详情现网数据、per-token 索引              |
| harmonybrew.atomgit.com（Harmonybrew 镜像）               | 归一化全量目录 + 统计快照                    |
| 设备上的 brew 命令（features/pcnative + BrewInstalledLoader） | 「我的」页的本机已安装 / 可升级包（仅 pc_acl 版本提供） |

两条方言由 `features/brewcommon/src/main/ets/service/source/BrewSourceAdapter.ets` 抽象（`UpstreamAdapter` / `HarmonybrewAdapter`），数据源地址与探活结果可在「我的」页切换查看。分类体系与榜单算法是本项目自建的，不是官方 API 字段——见 `docs/brew-marketplace-content-plan.md`、`docs/brew-discover-algo.md`。

## 工程结构

```
AppScope/                 应用级资源（分层图标、应用名、权限文案）
common/                   通用 UI 原子与工具（@ohos/common）
features/
  pcui/                   首页框架：侧边栏 + HdsTabs + 各页容器
  commonbusiness/         业务通用能力（枚举、状态、通用组件）
  brewcommon/             数据层：HTTP、数据源适配、目录同步、搜索引擎、模型
  brewdiscover/           发现页
  brewformulae/           formulae 页
  brewcasks/              casks 页
  brewdetail/             包详情页（formula / cask 共用）
  brewsearch/             搜索页
  mine/                   我的页
products/pc_acl/          entry 模块（完整版）：PcAbility、启动页、主页面
products/pc_normal/       entry 模块（普通版）：PcAbility、启动页、主页面
docs/                     设计文档、交接说明与实测笔记（knowledge/）
hmosword-build/
  brew-mockgen/           策展清单校验与榜单算法校验脚本（Python）
  brew-search/            搜索引擎的可执行检查（Node）
keys/                     本机签名材料（已 gitignore，不入库）
```

## 环境要求

* DevEco Studio 6.x（HarmonyOS 6.1.0 / API 23 SDK）

* 2in1（PC）设备或 DevEco 预览器

* Node 24+：仅运行搜索引擎检查脚本时需要

* Python 3：仅校验策展清单 / 榜单算法不变量时需要

## 构建与运行

```bash
devecocli build --product default    # 产出 pc_acl（完整版 HAP）
devecocli build --product pc_normal  # 产出 pc_normal（普通版 HAP）
devecocli build --modules pc_acl     # 只编 pc_acl entry 模块
devecocli run --module pc_normal     # 编译 + 安装 + 启动（需已连接设备；两个 entry 模块需显式指定）
```

工程级 `build-profile.json5` 里有两个 product：`default` 对应模块 `pc_acl`，`pc_normal` 对应模块 `pc_normal`。

`devecocli` 是 DevEco CLI（内部调用 hvigor / ohpm / hdc）；在 DevEco Studio 里直接打开工程 → Sync → Run 也可以。工程未内置 `hvigorw` 包装脚本。

> **签名**：product `default` 使用 `default` / `release` 两套签名配置；product `pc_normal` 使用 `normal_debug` / `normal_release` 两套签名配置，其中 `normal_debug` 的 profile 是 `keys/brewdebugDebug.p7b`，`normal_release` 的 profile 是 `keys/brewreleaseRelease.p7b`。四套配置的证书与私库都指向 `./keys/` 下的 `.cer` / `.p12`。`keys/` 是本机签名材料、**不入库**（已加入 `.gitignore`），因此 clone 后需要用 DevEco Studio 的自动签名，或自备证书后改这两套配置，否则无法产出签名 HAP。

## 开发自检

```bash
# 校验策展清单 tokens.json（分类/token 是否合法、是否还在上游）
python3 hmosword-build/brew-mockgen/generate.py            # 命中 .brewgen/cache 时零请求
python3 hmosword-build/brew-mockgen/generate.py --refresh  # 忽略缓存，重新拉一遍
python3 hmosword-build/brew-mockgen/generate.py --local    # 只做结构校验，完全不联网

python3 hmosword-build/brew-mockgen/check_algo.py --fetch --data .brewgen/analytics   # 榜单算法不变量

node hmosword-build/brew-search/check_engine.mjs           # 搜索引擎可执行检查
devecocli check lint                                       # ArkTS 代码检查
```

`features/*/src/ohosTest/` 下是基于 hypium 的单元测试，需连接设备后运行。
应用不内置任何 brew 数据快照（2026-10 起），数据只来自设备端目录（聚合端点）与现网单条，所以本仓库里没有「重新生成数据」这一步。榜单算法口径的权威实现在 `hmosword-build/brew-mockgen/check_algo.py` + `docs/brew-discover-algo.md`；改动 `BrewApiMapper.ets` 的归一化规则时，只需让分类口径与 `generate.py` 里的 `classify()`（以及设备端 `BrewTaxonomy.ets`）保持一致。

## 文档

| 文档                                    | 内容                       |
| ------------------------------------- | ------------------------ |
| docs/brew-api-design.md               | 数据层设计：数据源、归一化、缓存、错误分类    |
| docs/brew-discover-algo.md            | Discover 榜单算法（现网口径，唯一权威） |
| docs/brew-catalog-fullsync-spec.md    | 全量目录同步规范                 |
| docs/brew-marketplace-content-plan.md | 内容与分类体系规划                |
| docs/hds-titlebar-blur.md             | 标题栏模糊效果说明                |
| docs/brew-handover.md                 | 交接说明：环境、命令、脚本与注意事项       |
| docs/knowledge/                       | 散装实测笔记：缓存归属、环境路径、探针做法     |

## 许可

Apache License 2.0，见 [LICENSE](LICENSE)；开源合规声明见 [OAT.xml](OAT.xml)。
