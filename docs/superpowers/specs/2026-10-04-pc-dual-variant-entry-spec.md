# PC 双版本安装包（pc_acl / pc_normal）与 pcui 业务模块 · 设计

> 日期：2026-10-04。状态：待评审。评审通过后由 `writing-plans` 产出实施计划。
> 范围：`products/pc` 划分成两个 entry 模块 `products/pc_acl` 与 `products/pc_normal`；新增 `features/pcui`
> 承载 PC 业务 UI 与 ability 生命周期辅助；本机包能力改由 entry 注入的能力开关控制；桌面卡片链路完整移除。
> 相关文档：[`2026-10-04-brew-installed-packages-spec.md`](2026-10-04-brew-installed-packages-spec.md)、
> [`2026-10-04-brew-mine-package-detail-spec.md`](2026-10-04-brew-mine-package-detail-spec.md)、
> [`../../brew-handover.md`](../../brew-handover.md)。

---

## 1. 目标

同一套业务代码构建出两种 2in1 安装包：

| 版本 | 模块 | `requestPermissions` | 本机包能力 | 用途 |
| --- | --- | --- | --- | --- |
| pc_acl | `products/pc_acl` | INTERNET、GET_NETWORK_INFO、VIBRATE、READ_WRITE_USER_FILE、CUSTOM_SANDBOX | 完整：读设备上的 Homebrew 安装记录并在「我的」页展示 | 正式发布，CUSTOM_SANDBOX 需在 AGC 申请 ACL |
| pc_normal | `products/pc_normal` | INTERNET、GET_NETWORK_INFO、VIBRATE | 关闭：不取数、不展示入口、失败不报错 | 不申请受限权限的版本 |

两个 entry 模块只保留 ability、页面入口外壳与资源；业务 UI 与状态逻辑全部归入 `features/pcui`。
两个 entry 之间除 `module.json5`、权限文案资源与能力开关取值外没有差异。

## 2. 现状

`products/pc`（`src/main` 下 ETS 共 550 行）：

| 文件 | 行数 | 内容 |
| --- | --- | --- |
| `src/main/ets/pcability/PcAbility.ets` | 53 | 生命周期转发；`onCreate` 写 `IS_SIDEBAR_LAYOUT = true` |
| `src/main/ets/page/PcMainPage.ets` | 133 | `HdsNavDestination` + `HdsSideBar` + `GridRow` 断点 + 双击返回退出 |
| `src/main/ets/component/CustomSideBar.ets` | 94 | 侧边栏渲染，读 `abilitycommon` 的 `TABS_LIST` |
| `src/main/ets/page/SplashPage.ets` | 65 | `@Entry` 启动页，`HdsNavigation` + `SplashView` |
| `src/main/ets/pcformability/PcFormAbility.ets` | 83 | 卡片扩展，`module.json5` 未声明 `extensionAbilities`，未被引用 |
| `src/main/ets/widget/pages/*.ets` | 107 | 四张卡片的 `@Entry` 页面，`form_config.json` 的 `src` 指向它们 |
| `src/main/ets/pcbackupability/PcBackupAbility.ets` | 15 | 空实现，未被引用 |

`products/pc` 之外的 PC 业务：

| 位置 | 规模 | 说明 |
| --- | --- | --- |
| `features/abilitycommon` | 960 行 | PC 首页框架：`HomeView` 203、`FormAbilityHelper` 136、`ArticleServiceCardVM` 115、`BaseAbilityHelper` 113、`SplashViewModel` 102、`UpdateFormData` 71、`TabBarModel` 71、`InitCenter` 60、`SplashView` 40、`ContextConfig` 29、`SplashModel` 20 |
| `features/widgetcommon` | 711 行 | 卡片组件与视图模型，只被 `products/pc` 与 `abilitycommon` 依赖 |
| `features/mine` | 3937 行 | 「我的」页；本机包链路 708 行 |
| `features/brewcommon` | 10902 行 | 数据层；本机包读取 422 行（`BrewInstalledLoader` 291 + `BrewInstalledParser` 131） |
| `features/pcnative` | 727 行 | 执行通道（ETS 202 + C++ 525），唯一 ETS 使用点在 `BrewInstalledLoader` |

与本次改造直接相关的既有机制：

| 位置 | 现状 |
| --- | --- |
| `features/mine/src/main/ets/viewmodel/MinePageVM.ets:49` | `MINE_SHOW_LOCAL_PACKAGES = true`，与 `MineFeature.LOCAL_PACKAGE`、`isMineFeatureVisible()` 配合控制本机包三块的显隐 |
| `features/mine/src/main/ets/viewmodel/MinePageVM.ets:177` | `sendEvent` 的 `LOAD_LOCAL_PACKAGES` 分支先看开关再取数 |
| `features/brewcommon/src/main/ets/service/BrewInstalledLoader.ets:80` | `loadSets()` 带 60 秒进程内缓存；失败分类在 `BrewInstalledFailure` |
| `features/mine/src/main/ets/util/MinePackagesUtil.ets:37` | `loadSets()` 把 `BrewInstalledSets` 转成 `MinePackageSets`，失败向上抛 |
| 工程级 `build-profile.json5` | 只有 `default` 一个 product，只有一套 `signingConfig`（`default` / `release`） |
| `products/pc/src/main/module.json5` | 6 条权限；`usedScene.abilities` 写的是 `EntryAbility`，本模块能力名是 `PcAbility`；`GYROSCOPE` 只被卡片链路使用 |

## 3. 模块结构

```
products/
  pc_acl/           entry：PcAbility + 页面入口外壳 + module.json5（含 ACL 两条权限）
  pc_normal/        entry：同构，module.json5 少 ACL 两条权限
features/
  pcui/             HAR：PC 业务 UI、页签容器、启动页容器、ability 生命周期辅助、PC 资源
  abilitycommon/    删除（内容并入 pcui）
  widgetcommon/     删除（卡片链路移除）
```

### 3.1 `features/pcui`

模块名 `@ohos/pcui`，`module.json5` 的 `type` 为 `har`，`deviceTypes` 为 `["2in1"]`。

承载内容：

| 文件 | 来源 |
| --- | --- |
| `src/main/ets/abilityhelper/BaseAbilityHelper.ets` | `abilitycommon` 原文件 |
| `src/main/ets/util/ContextConfig.ets`、`util/InitCenter.ets` | `abilitycommon` 原文件 |
| `src/main/ets/model/SplashModel.ets`、`model/TabBarModel.ets` | `abilitycommon` 原文件 |
| `src/main/ets/viewmodel/SplashViewModel.ets` | `abilitycommon` 原文件 |
| `src/main/ets/view/HomeView.ets`、`view/SplashView.ets` | `abilitycommon` 原文件 |
| `src/main/ets/view/PcSplashPage.ets` | 由 `products/pc/src/main/ets/page/SplashPage.ets` 的 `@Entry` 结构体去掉 `@Entry` 后得到 |
| `src/main/ets/view/PcMainPage.ets` | 由 `products/pc/src/main/ets/page/PcMainPage.ets` 的 `MainPage` 结构体改名后得到 |
| `src/main/ets/component/CustomSideBar.ets` | `products/pc` 原文件 |
| `src/main/resources/**` | `abilitycommon` 的 `start_window_background`、`tab_*` 文案、`rawfile/env.json`；`products/pc` 的侧边栏 `color` / `float` 资源 |

`Index.ets` 对 entry 导出：

```ets
export { BaseAbilityHelper } from './src/main/ets/abilityhelper/BaseAbilityHelper';
export { HomeView } from './src/main/ets/view/HomeView';
export { SplashView } from './src/main/ets/view/SplashView';
export { PcSplashPage } from './src/main/ets/view/PcSplashPage';
export { PcMainPage } from './src/main/ets/view/PcMainPage';
export { DEFAULT_TAB, TabBarData, TABS_LIST } from './src/main/ets/model/TabBarModel';
```

`oh-package.json5` 依赖：`@ohos/common`、`@ohos/commonbusiness`、`@ohos/mine`、`@ohos/brewcommon`、
`@ohos/brewformulae`、`@ohos/brewcasks`、`@ohos/brewdiscover`、`@ohos/brewsearch`、`@ohos/brewdetail`
（沿用 `abilitycommon` 的依赖清单，去掉 `@ohos/widgetcommon`）。

### 3.2 `products/pc_acl` 与 `products/pc_normal`

两个模块同构，`src/main/ets` 只保留四个文件：

| 文件 | 内容 | 预估行数 |
| --- | --- | --- |
| `pcability/PcAbility.ets` | 生命周期转发给 `BaseAbilityHelper`；`onCreate` 写 `IS_SIDEBAR_LAYOUT` 与 `BREW_CLI_ENABLED` | ~50 |
| `page/SplashPage.ets` | `@Entry` 外壳，`build()` 内用全屏 `Stack` 承载 `PcSplashPage()`（`@Entry` 的 `build` 只允许一个容器组件作为根节点） | ~14 |
| `page/PcMainPage.ets` | `@Builder export function MainPageBuilder()`，内部渲染 `PcMainPage()` | ~12 |
| `pcbackupability/PcBackupAbility.ets` | 空实现，按现状保留（与备份能力接线时使用） | 15 |

`SplashPage` 与 `PcMainPage` 的外壳保留在 entry 的原因：`main_pages.json` 的 `pages` 与 `router_map.json`
的 `pageSourceFile` 都是「模块内路径」，页面入口文件必须位于 entry 模块内。

`src/main/resources` 保留：`base/element/string.json`（`module_desc`、权限 `reason`）、
`en_US` 与 `zh_CN` 的 `string.json`、`base/profile/main_pages.json`、
`base/profile/router_map.json`（`MainPage` → `src/main/ets/page/PcMainPage.ets` + `MainPageBuilder`）、
`base/profile/backup_config.json`。

两个 entry 的差异只有三处：`module.json5` 的 `requestPermissions`、`resources` 中的权限文案、
`PcAbility.onCreate` 中 `BREW_CLI_ENABLED` 的取值。`src/main/ets` 行数各不超过 120 行。

## 4. 权限差异

`pc_acl` 的 `module.json5`：

```json5
"requestPermissions": [
  { "name": "ohos.permission.INTERNET", "reason": "$string:internet_reason",
    "usedScene": { "abilities": ["PcAbility"], "when": "inuse" } },
  { "name": "ohos.permission.GET_NETWORK_INFO", "reason": "$string:network_reason",
    "usedScene": { "abilities": ["PcAbility"], "when": "inuse" } },
  { "name": "ohos.permission.VIBRATE", "reason": "$string:vibrator_reason",
    "usedScene": { "abilities": ["PcAbility"], "when": "inuse" } },
  { "name": "ohos.permission.READ_WRITE_USER_FILE", "reason": "$string:read_write_user_file_reason",
    "usedScene": { "abilities": ["PcAbility"], "when": "inuse" } },
  { "name": "ohos.permission.CUSTOM_SANDBOX", "reason": "$string:custom_sandbox_reason",
    "usedScene": { "abilities": ["PcAbility"], "when": "inuse" } }
]
```

`pc_normal` 的同一字段只保留前三条，并且不携带 `read_write_user_file_reason` 与
`custom_sandbox_reason` 文案资源。

同时修正两处现状问题：

1. `usedScene.abilities` 由 `EntryAbility` 改为 `PcAbility`（前三条权限）。
2. 删除 `ohos.permission.GYROSCOPE`：它的唯一使用方是卡片链路（`widgetcommon` 的
   `WidgetLiveFormCodeComponent` 读取传感器），卡片移除后没有使用点。

`reason` 引用的 `internet_reason`、`network_reason`、`vibrator_reason` 来自 `AppScope` 的应用级资源，
两个 entry 都可解析。

## 5. 能力开关与静默失败

### 5.1 开关定义与注入

键名加入 `common/src/main/ets/constant/CommonEnums.ets` 的 `StorageKey`：

```ets
/** 设备执行通道（brew cli）是否可用。由 entry 的 UIAbility 注入，未注入时为 false */
BREW_CLI_ENABLED = 'hmos_world_brewCliEnabled',
```

注入点是两个 entry 的 `PcAbility.onCreate`，与既有的 `IS_SIDEBAR_LAYOUT` 写在同一处：

```ets
// products/pc_acl
AppStorage.setOrCreate<boolean>(StorageKey.BREW_CLI_ENABLED, true);

// products/pc_normal
AppStorage.setOrCreate<boolean>(StorageKey.BREW_CLI_ENABLED, false);
```

`PcAbility.onCreate` 在 `onWindowStageCreate` 之前执行，页面首次构建时开关已经就位。

### 5.2 读取方一：「我的」页入口显隐

`features/mine/src/main/ets/viewmodel/MinePageVM.ets` 的常量改为函数：

```ets
/** 本机包：已安装入口（含数量）+ 待更新 / 已更新预览卡片。由 entry 注入的能力开关决定 */
export function isLocalPackagesEnabled(): boolean {
  return AppStorage.get<boolean>(StorageKey.BREW_CLI_ENABLED) ?? false;
}
```

`isMineFeatureVisible()` 的 `LOCAL_PACKAGE` 分支与 `sendEvent()` 的 `LOAD_LOCAL_PACKAGES` 分支改调
`isLocalPackagesEnabled()`。开关关闭时三块不渲染、不取数，`MineFeature` 枚举与条目定义保持不变，
重新打开开关即可整块恢复。

### 5.3 读取方二：取数层的静默失败

`features/brewcommon/src/main/ets/service/BrewInstalledLoader.ets` 的 `loadSets()` 入口增加判断：

```ets
public static async loadSets(force: boolean = false): Promise<BrewInstalledSets> {
  if (!isBrewCliEnabled()) {
    // 能力关闭：不执行命令、不写日志、不抛异常，调用方拿到空集合
    return new BrewInstalledSets();
  }
  // …既有实现
}
```

`isBrewCliEnabled()` 读 `StorageKey.BREW_CLI_ENABLED`，未注入时为 `false`。开关关闭时的约定：

| 项 | 行为 |
| --- | --- |
| 命令执行 | 不发生，`discoverBrewPath()` 与 `ShellUtils` 都不被调用 |
| 日志 | 不写 `warn` 与 `error`；hilog 中不出现 `[BrewInstalled]` 相关行 |
| 返回值 | `BrewInstalledSets` 空集合，`loadSets()` 正常 resolve |
| 上层表现 | `MinePackagesUtil.loadSets()` resolve 空集；`MinePackagesVM` 若被打开显示空列表，不显示失败态 |

`features/pcnative`、`ShellUtils`、`BrewInstalledParser`、`MinePackagesUtil`、`MinePackagesVM` 的实现
保持不变；`pc_normal` 的安装包内仍包含这些代码与 `libpcnative.so`，只是不会被调用。

## 6. 卡片链路移除

桌面卡片在当前版本没有入口（`module.json5` 无 `extensionAbilities`），本次完整移除。

| 删除对象 | 规模 |
| --- | --- |
| `products/pc/src/main/ets/pcformability/PcFormAbility.ets` | 83 行 |
| `products/pc/src/main/ets/widget/pages/*.ets`（4 个） | 107 行 |
| `products/pc/src/main/resources/base/profile/form_config.json` | 91 行 |
| `features/widgetcommon` 整个模块 | 711 行与 8 个图片资源 |
| `features/abilitycommon/src/main/ets/formabilityhelper/FormAbilityHelper.ets` | 136 行 |
| `features/abilitycommon/src/main/ets/widget/viewmodel/UpdateFormData.ets` | 71 行 |
| `features/abilitycommon/src/main/ets/widget/viewmodel/ArticleServiceCardVM.ets` | 115 行 |
| `features/abilitycommon/src/main/resources/base/media/*.png`（Code_\*、Fluffy_\*） | 15 张，只被 `widgetcommon` 引用 |
| `common/src/main/ets/database/FormRdbHelper.ets` | 只被卡片链路使用 |
| `common/src/main/ets/database/RdbUtils.ets` | 只被 `FormRdbHelper` 使用 |
| `common/src/main/ets/viewmodel/FormInfo.ets` | 只被卡片链路使用 |
| `common/src/main/ets/constant/FormCardConstant.ets` | `PC_ABILITY` 与 `LIVE_CARD_RATIO` 只被卡片链路使用 |
| `common/Index.ets` 与 `common/src/main/ets/constant/index.ets` 对应导出行 | — |
| `products/pc/src/main/resources/*/element/string.json` 的卡片文案 | `widget_display_name`、`ArticleServiceCard_desc`、`PcFormAbility_desc`、`PcFormAbility_label` |
| `features/abilitycommon/src/main/resources/base/element/color.json` 的卡片文字色 | `article_card_font_primary`、`article_card_font_secondary`、`article_card_icon_emphasize` |

`common/src/main/ets/util/VibratorUtils.ets` 同样没有被业务引用，它与卡片无关，本次不动。

## 7. 构建配置

工程级 `build-profile.json5`：

```json5
{
  "app": {
    "signingConfigs": [
      { "name": "default", /* 现状：keys/BrewTestDebugDebug.p7b（debug、含 ACL）+ common_debug.cer */ },
      { "name": "release", /* 现状：keys/brewreleaseRelease.p7b（release、不含 ACL）+ common_sign.cer */ },
      { "name": "normal_debug", /* 新增：keys/brewdebugDebug.p7b（debug、不含 ACL）+ common_debug.cer */ },
      { "name": "normal_release", /* 新增：keys/brewreleaseRelease.p7b（release、不含 ACL）+ common_sign.cer */ }
    ],
    "products": [
      {
        "name": "default",
        "signingConfig": "default",
        "bundleName": "top.handwer.brewlibrary",
        "compatibleSdkVersion": "6.1.0(23)",
        "targetSdkVersion": "6.1.0(23)",
        "runtimeOS": "HarmonyOS"
      },
      {
        "name": "pc_normal",
        "signingConfig": "normal_debug",
        "bundleName": "top.handwer.brewlibrary",
        "compatibleSdkVersion": "6.1.0(23)",
        "targetSdkVersion": "6.1.0(23)",
        "runtimeOS": "HarmonyOS"
      }
    ]
  },
  "modules": [
    { "name": "pc_acl",    "srcPath": "./products/pc_acl",
      "targets": [{ "name": "default", "applyToProducts": ["default"] }] },
    { "name": "pc_normal", "srcPath": "./products/pc_normal",
      "targets": [{ "name": "default", "applyToProducts": ["pc_normal"] }] }
    // 其余 feature 模块记录不变，widgetcommon 与 abilitycommon 记录删除，pcui 记录新增
  ]
}
```

约定：

- product `default` 对应带 ACL 的正式版本，`devecocli build --product default` 与现有命令保持一致。
- 两个 product 使用同一个 `bundleName`（`top.handwer.brewlibrary`），三个现有 profile 都是为它签发的。
  `pc_normal` 的包不带 ACL 的原因在 `module.json5`：它不声明 CUSTOM_SANDBOX 与 READ_WRITE_USER_FILE。
  两个版本的包互相覆盖，同一时间只能安装一个。
- 签名材料的对应关系：`normal_debug` 复用 `default` 的证书与密钥库（`keys/common_debug.cer`、
  `keys/quickysticker_sign.p12`、`keyAlias: QuickySticker`），`normal_release` 复用 `release` 的
  （`keys/common_sign.cer`、同一个 `.p12`）。
- 工程级 `modules` 中两个 entry 只列 `default` target：hvigor 不允许 `ohosTest` target 挂到 product 上
  （sync 阶段报 `00303072 Configuration Error`）。模块级 `build-profile.json5` 的 `targets` 仍保留
  `default` 与 `ohosTest` 两项。
- `signingConfig` 的填法沿用现状：product 的 `signingConfig` 填调试条目名（`default` / `normal_debug`），
  release 构建按 buildMode 选择同名签名条目（`release` / `normal_release`）。
- `.hvigor`、`oh_modules`、`oh-package-lock.json5` 由构建工具重新生成，不手工维护。

## 8. 迁移与删除清单

### 8.1 新增与改写

| 动作 | 路径 |
| --- | --- |
| 新建 | `features/pcui/**`（模块骨架、`Index.ets`、`oh-package.json5`、`build-profile.json5`、`hvigorfile.ts`、`module.json5`） |
| 新建 | `products/pc_normal/**`（从改名后的 `products/pc_acl` 复制，改 `module.json5`、`oh-package.json5`、`build-profile.json5`、`PcAbility.ets` 的开关取值） |
| 改名 | `products/pc` → `products/pc_acl`；`module.json5` 的 `module.name`、`oh-package.json5` 的 `name` 同步改为 `pc_acl` |
| 改写 | 两个 entry 的 `PcAbility.ets`：保留生命周期转发，写入两个 `AppStorage` 键 |
| 改写 | 两个 entry 的 `page/SplashPage.ets`：`@Entry` 外壳渲染 `PcSplashPage()` |
| 改写 | 两个 entry 的 `page/PcMainPage.ets`：`MainPageBuilder()` 渲染 `PcMainPage()` |
| 改写 | `features/mine/src/main/ets/viewmodel/MinePageVM.ets`：`MINE_SHOW_LOCAL_PACKAGES` 改为 `isLocalPackagesEnabled()` |
| 改写 | `features/brewcommon/src/main/ets/service/BrewInstalledLoader.ets`：`loadSets()` 入口判断开关；`@ohos/common` 的导入增加 `StorageKey` |
| 改写 | 两个 entry 的 `oh-package.json5`：依赖改为 `@ohos/common` 与 `@ohos/pcui`，移除 `@ohos/abilitycommon` 与 `@ohos/widgetcommon` |
| 改写 | 工程级 `build-profile.json5`：`products` 增加 `pc_normal`，`signingConfigs` 增加 `normal_debug` 与 `normal_release`，`modules` 更新为 `pc_acl` / `pc_normal` / `pcui` |
| 改写 | `common/src/main/ets/constant/CommonEnums.ets`：`StorageKey` 增加 `BREW_CLI_ENABLED` |

### 8.2 迁移

| 源 | 目标 |
| --- | --- |
| `features/abilitycommon/src/main/ets/abilityhelper/BaseAbilityHelper.ets` | `features/pcui/src/main/ets/abilityhelper/BaseAbilityHelper.ets` |
| `features/abilitycommon/src/main/ets/util/{ContextConfig,InitCenter}.ets` | `features/pcui/src/main/ets/util/` |
| `features/abilitycommon/src/main/ets/model/{SplashModel,TabBarModel}.ets` | `features/pcui/src/main/ets/model/` |
| `features/abilitycommon/src/main/ets/viewmodel/SplashViewModel.ets` | `features/pcui/src/main/ets/viewmodel/SplashViewModel.ets` |
| `features/abilitycommon/src/main/ets/view/{HomeView,SplashView}.ets` | `features/pcui/src/main/ets/view/` |
| `features/abilitycommon/src/main/resources/base/element/{color,string}.json` | `features/pcui/src/main/resources/base/element/`（删卡片文字色） |
| `features/abilitycommon/src/main/resources/{dark,en_US,zh_CN}/element/*.json` | `features/pcui/src/main/resources/` 对应目录 |
| `features/abilitycommon/src/main/resources/rawfile/env.json` | `features/pcui/src/main/resources/rawfile/env.json` |
| `features/abilitycommon/src/main/resources/base/profile/router_map.json`（空表） | `features/pcui/src/main/resources/base/profile/router_map.json` |
| `products/pc/src/main/ets/component/CustomSideBar.ets` | `features/pcui/src/main/ets/component/CustomSideBar.ets` |
| `products/pc/src/main/ets/page/PcMainPage.ets` 的 `MainPage` 结构体 | `features/pcui/src/main/ets/view/PcMainPage.ets`（导出 `PcMainPage`） |
| `products/pc/src/main/ets/page/SplashPage.ets` 的页面主体 | `features/pcui/src/main/ets/view/PcSplashPage.ets`（导出 `PcSplashPage`） |
| `products/pc/src/main/resources/base/element/{color,float}.json` | `features/pcui/src/main/resources/base/element/`（侧边栏颜色与尺寸） |
| `products/pc/src/main/resources/{en_US,zh_CN}/element/string.json` 的权限文案 | 两个 entry 各自的 `resources` |

### 8.3 删除

按 §6 的清单执行，另外：

| 删除对象 | 说明 |
| --- | --- |
| `features/abilitycommon/**`（迁移完成后） | 模块记录从工程级 `build-profile.json5` 移除 |
| `features/widgetcommon/**` | 模块记录与 `oh-package.json5` 依赖同步移除 |
| `products/pc/**`（改名后不再存在） | 由 `products/pc_acl` 取代 |
| `README.md` 第 21 行的卡片说明文字 | 卡片代码已移除 |

## 9. 文档同步

| 文档 | 改动 |
| --- | --- |
| `README.md` / `README.en.md` | 删除卡片说明；工程结构表中 `abilitycommon` 改为 `pcui`，删除 `widgetcommon`；`products/pc` 改为 `products/pc_acl` 与 `products/pc_normal`；构建命令改为 `devecocli build --product default` 与 `devecocli build --product pc_normal` |
| `docs/brew-handover.md` | 更新第 106 至 110 行的模块表与第 86 至 91 行的产物路径（`products/pc` → `products/pc_acl`） |
| `docs/brew-api-design.md` | 第 738 行引用的 `abilitycommon/oh-package.json5` 改为 `pcui/oh-package.json5` |
| `docs/brew-marketplace-content-plan.md` | 第 91、116、135、463 行引用 `abilitycommon` 的路径改为 `pcui` |

## 10. 验收判据

| # | 判据 | 可观测证据 |
| --- | --- | --- |
| G1 | 两个 product 都能构建 | `devecocli build --product default` 与 `devecocli build --product pc_normal` 均输出 `BUILD SUCCESSFUL`，`ERROR` 计数为 0 |
| G2 | 权限集合符合预期 | 构建产物中 `pc_acl` 的 `module.json5` 含 `CUSTOM_SANDBOX` 与 `READ_WRITE_USER_FILE`；`pc_normal` 的产物不含这两条，也不含 `GYROSCOPE` |
| G3 | 卡片链路已移除 | 工程内不再存在 `features/widgetcommon` 与 `features/abilitycommon`；`form_config.json` 不存在；两个 HAP 的 `module.json5` 中无 `extensionAbilities` |
| G4 | pc_acl 的本机包功能不变 | 真机安装后「我的」页出现本机包三块，包名与数量与改造前一致 |
| G5 | pc_normal 无本机包痕迹 | 真机安装后「我的」页不出现本机包三块；hilog 中无 `[BrewInstalled]`、`brew-not-found`、`shell-unavailable`、`[MinePackagesVM]` 行 |
| G6 | 两个版本其余功能一致 | 启动页、侧边栏五个页签、搜索、详情页在 `pc_acl` 与 `pc_normal` 上表现一致 |
| G7 | entry 保持薄壳 | 两个 entry 的 `src/main/ets` 各不超过 120 行；`diff -r products/pc_acl/src/main/ets products/pc_normal/src/main/ets` 只显示 `PcAbility.ets` 的一行差异 |
| G8 | 构建命令可用 | `devecocli build --product pc_normal` 不需要改动任何源码即可产出第二个安装包 |

## 11. 非目标

- 不改 `features/brewcommon` 的数据层、`features/mine` 的页面结构与 `features/brewdetail` 的展示。
- 不把 `features/pcnative` 从依赖中移除；`pc_normal` 的包内仍包含执行通道代码与 `libpcnative.so`。
- 不修改 `ShellUtils` 与 C++ 侧的实现，也不改变 `pc_acl` 在设备能力不足时的既有失败表现。
- 不恢复卡片能力，不新建 `extensionAbilities` 声明。
- 不调整 `mine` 的其它区块开关（`USER_EXPERIENCE` 与 `FEEDBACK` 保持现状）。
- 不动 `common/src/main/ets/util/VibratorUtils.ets`。

## 12. 外部前置条件与已知未知

外部材料：

1. `keys/` 下现有三个 profile 即可满足本次构建：`BrewTestDebugDebug.p7b`（debug、含 ACL）、
   `brewdebugDebug.p7b`（debug、不含 ACL）、`brewreleaseRelease.p7b`（release、不含 ACL）。
2. `pc_acl` 的 release profile（`brewreleaseRelease.p7b`）当前不含 ACL 授权；发布正式版本时需要按
   AGC 流程重新申请带 CUSTOM_SANDBOX 的发布 Profile，本次不阻塞构建。
3. 若将来要让两个版本的包同时安装，需要第二个 `bundleName` 与对应的 Profile。

需要在第一次构建时验证的点：

1. 同一工程内两个 entry 模块分别通过 `applyToProducts` 绑定不同 product 的构建行为（官方示例是同一模块的多个 target 绑定不同 product）。
2. `pcui` 的 HAR 资源（`start_window_background`、`tab_*`）被两个 entry 的 `module.json5` 与页面正常解析。
3. `pcui` 的 `router_map.json`（空表）与两个 entry 的 `router_map.json` 合并时不产生重名冲突。

## 13. 上机验证顺序

1. 构建 `default` product，检查 `pc_acl` 产物的 `module.json5` 权限集合与产物文件清单（G2、G3）。
2. 真机安装 `pc_acl`，走「我的」页与「本机包」二级页，与本设计前的表现对照（G4）。
3. 构建并安装 `pc_normal`，检查「我的」页不含本机包三块，抓取 hilog 确认无相关错误行（G5）。
4. 在 `pc_normal` 上走启动页、五个页签、搜索与详情页，确认与 `pc_acl` 一致（G6）。
5. 对两个 entry 的 `src/main/ets` 做行数统计与差异对照（G7）。
