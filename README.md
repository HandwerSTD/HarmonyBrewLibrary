# BrewLibrary

<p align="center"><img src="docs/icon/icon_1024.png" width="120" alt="BrewLibrary"></p>

BrewLibrary 是一个面向 **HarmonyOS PC（2in1）** 的 Homebrew 包浏览器：用桌面端布局浏览 Homebrew 的 formulae / casks，支持榜单发现、离线全文搜索、包详情与本机安装状态查看。

- 设备形态：仅 2in1（PC），最小窗口 1080 × 608
- 编译目标：HarmonyOS 6.1.0（API 23），hvigor 模型 5.0.0
- 技术栈：ArkTS / ArkUI（Stage 模型），单 entry 模块 `products/pc`

## 功能

| 页签 | 说明 |
| --- | --- |
| **Discover** | 六个榜单推荐。榜单成员与数字在设备端现算，并内置回落快照，断网也能出内容 |
| **Formulae** | formulae 目录：分类 chips + 列表 + 详情页 |
| **Casks** | casks 目录，与 formulae 共用同一套组件与详情页 |
| **Search** | 本地搜索引擎（零依赖纯函数引擎 + 词表打分），离线可搜 |
| **Me** | 本机已安装 / 可升级包、数据源切换与连通性状态、页面可选区块开关 |

桌面卡片相关代码（`features/widgetcommon`、`products/pc/src/main/ets/widget/pages/`、`PcFormAbility.ets`、`resources/base/profile/form_config.json`）仍在仓库中，但 form 扩展入口（`products/pc/src/main/module.json5` 的 `extensionAbilities`）已在当前版本移除，因此系统「添加卡片」列表里不会再出现本应用；需要恢复时把那段声明加回 `module.json5` 即可。

## 数据来源

| 来源 | 用途 |
| --- | --- |
| `formulae.brew.sh/api`（官方上游） | 包详情现网数据、per-token 索引 |
| `harmonybrew.atomgit.com`（Harmonybrew 镜像） | 归一化全量目录 + 统计快照 |
| 内置快照 `common/src/main/resources/rawfile/mockdata/` | 首启、断网或请求失败时的回落 |

两条方言由 `features/brewcommon/src/main/ets/service/source/BrewSourceAdapter.ets` 抽象（`UpstreamAdapter` / `HarmonybrewAdapter`），数据源地址与探活结果可在「我的」页切换查看。分类体系与榜单算法是本项目自建的，不是官方 API 字段——见 `docs/brew-marketplace-content-plan.md`、`docs/brew-discover-algo.md`。

## 工程结构

```
AppScope/                 应用级资源（分层图标、应用名、权限文案）
common/                   通用 UI 原子与工具（@ohos/common）
features/
  abilitycommon/          首页框架：侧边栏 + HdsTabs + 各页容器
  commonbusiness/         业务通用能力（枚举、状态、通用组件）
  widgetcommon/           桌面卡片组件（2×2 / 2×4 / 锁屏卡）
  brewcommon/             数据层：HTTP、数据源适配、目录同步、搜索引擎、模型
  brewdiscover/           发现页
  brewformulae/           formulae 页
  brewcasks/              casks 页
  brewdetail/             包详情页（formula / cask 共用）
  brewsearch/             搜索页
  mine/                   我的页
products/pc/              entry 模块：PcAbility、启动页、侧边栏、表单
docs/                     设计文档与交接说明
hmosword-build/
  brew-mockgen/           mock 数据生成器与离线校验脚本（Python）
  brew-search/            搜索引擎的可执行检查（Node）
keys/                     本机签名材料（已 gitignore，不入库）
```

## 环境要求

- DevEco Studio 6.x（HarmonyOS 6.1.0 / API 23 SDK）
- 2in1（PC）设备或 DevEco 预览器
- Node 24+：仅运行搜索引擎检查脚本时需要
- Python 3：仅重新生成 mock 数据时需要

## 构建与运行

```bash
devecocli build --product default   # 整个 product
devecocli build --modules pc        # 只编 entry 模块
devecocli run                       # 编译 + 安装 + 启动（需已连接设备）
```

`devecocli` 是 DevEco CLI（内部调用 hvigor / ohpm / hdc）；在 DevEco Studio 里直接打开工程 → Sync → Run 也可以。工程未内置 `hvigorw` 包装脚本。

> **签名**：`build-profile.json5` 的 `default` / `release` 两套配置指向 `./keys/` 下的 `.cer` / `.p7b` / `.p12`。`keys/` 是本机签名材料、**不入库**（已加入 `.gitignore`），因此 clone 后需要用 DevEco Studio 的自动签名，或自备证书后改这两套配置，否则无法产出签名 HAP。

## 开发自检

```bash
# 重新生成 mock 数据（从 formulae.brew.sh 拉真数据 → rawfile/mockdata）
python3 hmosword-build/brew-mockgen/generate.py            # 增量，复用 .brewgen/cache
python3 hmosword-build/brew-mockgen/generate.py --refresh  # 强制重新拉取
python3 hmosword-build/brew-mockgen/generate.py --check    # 只校验 token，不产出

python3 hmosword-build/brew-mockgen/check_types.py         # 字段类型一致性（退出码 0/1）
python3 hmosword-build/brew-mockgen/check_algo.py --data .brewgen/discover   # 榜单算法不变量

node hmosword-build/brew-search/check_engine.mjs           # 搜索引擎可执行检查
devecocli check lint                                       # ArkTS 代码检查
```

`features/*/src/ohosTest/` 下是基于 hypium 的单元测试，需连接设备后运行。
改动 `features/brewcommon/src/main/ets/service/BrewApiMapper.ets` 时，必须同步改 `hmosword-build/brew-mockgen/generate.py`——快照与现网字段由同一套归一化规则产出，两边不一致会让同一个包在列表与详情页显示成两种样子。

## 文档

| 文档 | 内容 |
| --- | --- |
| [docs/brew-api-design.md](docs/brew-api-design.md) | 数据层设计：数据源、归一化、缓存、错误分类 |
| [docs/brew-discover-algo.md](docs/brew-discover-algo.md) | Discover 榜单算法（现网口径，唯一权威） |
| [docs/brew-catalog-fullsync-spec.md](docs/brew-catalog-fullsync-spec.md) | 全量目录同步规范 |
| [docs/brew-marketplace-content-plan.md](docs/brew-marketplace-content-plan.md) | 内容与分类体系规划 |
| [docs/hds-titlebar-blur.md](docs/hds-titlebar-blur.md) | 标题栏模糊效果说明 |
| [docs/brew-handover.md](docs/brew-handover.md) | 交接说明：环境、命令、脚本与注意事项 |

## 许可

Apache License 2.0，见 [LICENSE](LICENSE)；开源合规声明见 [OAT.xml](OAT.xml)。
