---
name: handwer-brew-library
description: >-
  Harmonybrew 的软件包技能：按关键词查找 Homebrew 软件包、查询安装状态与版本、
  列出已装与待更新清单、查包详情与用法示例、看热门榜单与分类、自检 brew 状态，
  并可只读预演安装、升级、卸载会改动什么。可响应「找找能下载视频的工具」
  「ffmpeg 装了没有」「装个 ffmpeg」「有什么要升级的」「卸载 wget 会影响什么」
  「最近什么工具火」「wget 怎么用」等意图。
  不适用于直接执行安装、升级或卸载——一律只做只读预演，真正执行由用户在 Harmonybrew
  应用内亲手完成；也不适用于更新系统或系统应用、管理图形应用、查询 brew 资讯。
---

# Harmonybrew 软件包技能

十四项能力，两类：

**只读查询**（不执行任何命令）：`searchPackages`（找包）、`queryPackage`（查状态）、
`listInstalled`（已装清单）、`listOutdated`（待更新清单）、`packageDetail`（包详情）、
`packageUsage`（用法示例）、`listTrending`（热门榜单）、`listCategories`（分类）、
`checkBrew`（brew 状态自检）。

**写操作的只读预演**：`previewInstall`（预演安装）、`requestInstall`（发起安装，只预演不执行）、
`previewUpgrade`（预演升级单包）、`previewUpgradeAll`（预演批量升级）、
`previewUninstall`（卸载影响评估）。绝不直接执行安装——真正的安装/升级/卸载只发生在
Harmonybrew 应用内、由用户亲手操作。

本技能只提供设备侧 exec-cli（ohos-arktsscript）通道，由设备上的小艺 Work 直接调用应用内脚本。

## 调用方式（小艺 Work 的 exec → ohos-arktsscript）

> **先读这里（重要）**：应用安装后，系统会把 skill 与 ArkTS script 解出并暴露给
> `ohos-arktsscript` 这个工具；小艺 Work 用自己的 `exec` 工具调用它，即完成应用接入。
> 但系统**不会把本 SKILL.md 的文本暴露给小艺 Work**，小艺 Work 也**不能安装本地 skill**——
> 所以使用前必须把整份 SKILL.md 发到小艺 Work 对话框里让它读完，它才能写出正确的调用。

**已实测成功的调用形态（照抄，只换 functionName 与 args）**：

```text
exec(
  command: "ohos-arkTSScript --skillName 'handwer-brew-library' --scriptPath 'scripts/BrewSkill.ets' --functionName 'searchPackages' --args '{\"query\":\"python\"}'",
  timeout_ms: 60000
)
```

**第一步：先把全部业务参数压成一个字符串。** 构造业务参数对象，执行一次
`JSON.stringify(params)` 得到 `payload`，作为**唯一**参数传入（`argv.length === 1`，
argv[0] 是可解析的 JSON 对象字符串）。禁止把字段拆成多个位置参数，禁止 `Object.values`。

**第二步：把内部双引号转义为 `\"`。** 即把 `"` 写成 `\"`，再将完整内容放进 `--args`。
本技能的 ETS 入口会先尝试直接解析，失败后再将收到的 `\"` 还原为 `"` 并解析，
两种形态都接受。

```text
序列化后的 payload：{"query":"下载视频"}
命令中的参数：--args '{\"query\":\"下载视频\"}'
```

**timeout_ms 怎么给（三档）**：

- **60000**——内存级查询：`searchPackages` / `queryPackage` / `listInstalled` /
  `listOutdated` / `listTrending` / `listCategories`；
- **120000**——要走网络（首次可能下载）：`packageDetail` / `packageUsage`；
- **180000**——要执行真实 brew 命令（只读，依赖解析可能触发元数据刷新，最长约两分钟）：
  `previewInstall` / `requestInstall` / `previewUpgrade` / `previewUpgradeAll` /
  `previewUninstall` / `checkBrew`。

超时不是失败重试的信号，结果以回包为准。

## 返回结果与错误处理

只有返回 `status: "success"` 才表示业务成功。

- `ERR_INVALID_PARAMS` 且 `errMsg` 以「参数传递格式错误」开头：按调用方式一节重新压参，
  自动重试**一次**；不要等用户提醒。
- `ERR_INVALID_PARAMS`（业务字段缺失或取值非法，如 token 为空、filter 拼错）：向用户
  问清缺失的参数再调用；suggestion 里写明了合法取值。
- `ERR_NOT_FOUND`：目录里没有这个名字。**不要**用同一参数重试，改用 `searchPackages`
  确认名字后再继续；绝不猜包名、不改写、不「纠正成相近包名」。
- `ERR_INTERNAL`：停止并如实转述 errMsg 与 suggestion，不自动重试。
- 所有预演函数（`previewInstall` / `requestInstall` / `previewUpgrade` /
  `previewUpgradeAll` / `previewUninstall`）无论结果如何都**不自动重放**：预演是只读的
  可以手动再要一次，但安装/升级/卸载只能由用户在应用内完成。
- 预演回包的 `data.status` 是业务语义，不是顶层 status：`preview`（预演完成）、
  `needs_confirmation`（等用户在应用内动手）、`nothing_to_upgrade`（已是最新）、
  `not_installed`（没有安装记录）——转述时把语义说清楚，不要把预演说成已执行。

## 运行条件与业务约定

- 依赖设备上已安装 Harmonybrew 且完成 brew 探测；未安装或未就绪时按 `ERR_INTERNAL` 的
  suggestion 转述。
- 首次调用可能触发软件包目录刷新（应用冷启动时稍慢，属正常），不要因此中断流程。
- `queryPackage` / `listInstalled` / `listOutdated` / `previewUninstall` 的安装状态来自
  **本机快照**（冻结口径）：`asOf` 是快照时刻（epoch 毫秒，0 表示从未读取过本机包），
  转述时应带上「数据截至」含义，不把旧数据说成实时。
- `packageDetail` / `packageUsage` 首次查询要走网络，之后有缓存；`packageUsage` 是
  增强层，`found=false` 表示示例库里没有这个命令的页面，属正常，不要报错。
- `previewInstall` / `requestInstall` / `previewUpgrade` / `previewUpgradeAll` 走真实
  brew dry-run（只读、不动盘），需要网络，最长约两分钟；`previewUninstall` 不执行任何
  卸载命令，只做只读推导（安装事实 + 反向依赖）。
- **安装、升级、卸载永远由用户在 Harmonybrew 应用内亲手完成**；本技能不执行任何写命令，
  也不要在用户口头确认后代为执行。

## 触发场景

当用户表达**查找软件包**、**查询软件包状态**、**查看本机已装/待更新**、**了解某个包**、
**看热门/分类**、**检查 brew**，或**安装/升级/卸载的预演**意图时调用。典型话术：

- "帮我找找能下载视频的命令行工具"、"有没有类似 grep 的工具" → searchPackages
- "ffmpeg 装了没有"、"gh 现在是什么版本"、"ripgrep 有没有新版本" → queryPackage
- "装 ffmpeg 会带哪些东西"、"先预演一下装 wget"、"装 docker 要占多少东西" → previewInstall
- "装个 ffmpeg"、"帮我安装 ripgrep"、"把 jq 装上" → requestInstall
- "我都装了些什么"、"装了哪些命令行工具"、"有没有装 curl" → listInstalled
- "有什么要升级的"、"哪些包过时了" → listOutdated
- "把 wget 升上去会怎样"、"先预演升级 ffmpeg" → previewUpgrade
- "全部升级会动哪些包"、"批量升级前先看看" → previewUpgradeAll
- "卸载 wget 会影响什么"、"我想卸掉 docker，先看看影响" → previewUninstall
- "ffmpeg 依赖什么"、"wget 的主页是什么"、"这个包还维护吗" → packageDetail
- "wget 怎么用"、"给我几个 curl 的例子" → packageUsage
- "最近什么工具火"、"cask 里什么最热" → listTrending
- "都有哪些分类"、"游戏类里有什么" → listCategories
- "brew 好使吗"、"brew 什么版本" → checkBrew

不调用的情况：

- 用户说"更新系统"、"检查系统更新"——系统软件更新不是 Homebrew 软件包，应走系统能力。
- 用户说"卸载 XX 应用"（指图形应用/App 或系统应用）——本技能只管 brew 生态的软件包；
  brew 包的卸载先走 previewUninstall 预演，图形 App 不归它管。
- 用户问"brew 是什么"、"Homebrew 新闻"——资讯类问题，不是对软件包的操作。
- 用户只是闲聊，没有明确的软件包指向（如"命令行真好用"）。
- 用户说"调大音量"、"打开蓝牙"——系统能力，与软件包无关。

### 场景1：按关键词查找软件包（searchPackages）

**触发**：用户说"帮我找找能下载视频的工具""有没有类似 grep 的命令"等。

**成功后的动作**：从 `data.rows` 逐条转述（name / kind / desc）；`matchedCount` 是本次
返回的条数。用户想要更多结果时，引导其在 Harmonybrew 内搜索，不要虚构目录里不存在的包名。

执行参数：

```text
exec(
  command: "ohos-arkTSScript --skillName 'handwer-brew-library' --scriptPath 'scripts/BrewSkill.ets' --functionName 'searchPackages' --args '{\"query\":\"下载视频\"}'",
  timeout_ms: 60000
)
```

```json
"args": {
  "type": "object",
  "properties": {
    "query": {
      "type": "string",
      "description": "搜索关键词，可以是用途描述（如\"下载视频\"）或包名片段（如\"wget\"）"
    }
  },
  "required": ["query"]
}
```

执行返回值：

```json
{
    "type": "result",
    "status": "success",
    "data": {
        "query": "下载视频",
        "matchedCount": 2,
        "rows": [
            { "name": "yt-dlp", "kind": "formula", "desc": "A youtube-dl fork with additional features and fixes" },
            { "name": "you-get", "kind": "formula", "desc": "A tiny command-line utility to download media from websites" }
        ]
    },
    "suggestion": "以上是最匹配的软件包，想装哪个告诉我，我先给你预演一下。"
}
```

```json
{
    "type": "result",
    "status": "failed",
    "errCode": "ERR_INVALID_PARAMS",
    "errMsg": "参数传递格式错误：argv[0] 必须是可解析的 JSON 对象字符串。",
    "suggestion": "请先对完整参数对象执行 JSON.stringify，再把结果作为唯一参数传入；命令行调用时转义内部双引号。"
}
```

```json
{
    "type": "result",
    "status": "failed",
    "errCode": "ERR_INVALID_PARAMS",
    "errMsg": "keyword is empty",
    "suggestion": "你想找什么类型的工具？"
}
```

```json
{
    "type": "result",
    "status": "failed",
    "errCode": "ERR_INTERNAL",
    "errMsg": "catalog refresh failed",
    "suggestion": "先打开一次 Harmonybrew，让软件包目录就绪。"
}
```

对应的 Schema 约束（顶层分支：成功要求 data；失败要求 errCode / errMsg / suggestion）：

```json
{
  "type": "object",
  "required": ["type", "status"],
  "properties": {
    "type":   { "type": "string", "const": "result" },
    "status": { "type": "string", "enum": ["success", "failed"] },
    "data":   { "type": "object" },
    "errCode": { "type": "string", "enum": ["ERR_INVALID_PARAMS", "ERR_INTERNAL"] },
    "errMsg":     { "type": "string", "minLength": 1 },
    "suggestion": { "type": "string", "minLength": 1 }
  },
  "oneOf": [
    { "properties": { "status": { "const": "success" } }, "required": ["data"] },
    { "properties": { "status": { "const": "failed" } }, "required": ["errCode", "errMsg", "suggestion"] }
  ]
}
```

### 场景2：查询软件包状态（queryPackage）

**触发**：用户说"ffmpeg 装了没有""gh 是什么版本"等。

**成功后的动作**：从 `data` 读取状态转述。`installed=true` 且 `outdated=true` 时，建议用户
在 Harmonybrew 内升级；`asOf` 为 0 时如实说明「还没有本机安装记录」。本场景不执行任何命令。

执行参数：

```text
exec(
  command: "ohos-arkTSScript --skillName 'handwer-brew-library' --scriptPath 'scripts/BrewSkill.ets' --functionName 'queryPackage' --args '{\"token\":\"wget\"}'",
  timeout_ms: 60000
)
```

```json
"args": {
  "type": "object",
  "properties": {
    "token": {
      "type": "string",
      "description": "软件包名，如 wget、ffmpeg。必须是目录里存在的名字；不确定时先用 searchPackages 查"
    }
  },
  "required": ["token"]
}
```

执行返回值：

```json
{
    "type": "result",
    "status": "success",
    "data": {
        "token": "wget",
        "kind": "formula",
        "desc": "Internet file retriever",
        "installed": true,
        "version": "1.25.0_2",
        "latestVersion": "1.25.0_2",
        "outdated": false,
        "asOf": 1763800000000
    }
}
```

```json
{
    "type": "result",
    "status": "failed",
    "errCode": "ERR_NOT_FOUND",
    "errMsg": "token not found in catalog",
    "data": { "searchedKeywords": ["wgat"] },
    "suggestion": "软件包目录里没有「wgat」，要不要说说你想做什么，我帮你找找？"
}
```

```json
{
    "type": "result",
    "status": "failed",
    "errCode": "ERR_INVALID_PARAMS",
    "errMsg": "token is empty or invalid",
    "suggestion": "你想查哪个包？"
}
```

Schema 与场景1同构（成功要求 data；失败要求 errCode/errMsg/suggestion；errCode 枚举为
ERR_INVALID_PARAMS / ERR_NOT_FOUND / ERR_INTERNAL）。

### 场景3：预演安装（previewInstall）

**触发**：用户说"装 ffmpeg 会带哪些东西""先预演一下装 wget"等。

**成功后的动作**：转述 `data.wouldInstall` 清单与 `data.cmdline`；说明这是 dry-run 预演、
还没有安装任何东西。**不要**把预演结果转述成「已安装」。清单可能包含两类条目：将新增的
软件包与会被连带升级的依赖（brew 7 实测形态；依赖条目的 `kind` 可能为空）。

执行参数：

```text
exec(
  command: "ohos-arkTSScript --skillName 'handwer-brew-library' --scriptPath 'scripts/BrewSkill.ets' --functionName 'previewInstall' --args '{\"token\":\"wget\"}'",
  timeout_ms: 180000
)
```

```json
"args": {
  "type": "object",
  "properties": {
    "token": {
      "type": "string",
      "description": "要预演安装的软件包名"
    }
  },
  "required": ["token"]
}
```

执行返回值：

```json
{
    "type": "result",
    "status": "success",
    "data": {
        "token": "wget",
        "status": "preview",
        "cmdline": "brew install --dry-run wget",
        "declaredCount": 1,
        "wouldInstall": [
            { "name": "wget", "version": "1.25.0_2", "kind": "formula" }
        ]
    },
    "suggestion": "清单在上面。想在 Harmonybrew 里装的话，打开这个包的详情页点安装就行。"
}
```

```json
{
    "type": "result",
    "status": "failed",
    "errCode": "ERR_NOT_FOUND",
    "errMsg": "token not found in catalog",
    "data": { "searchedKeywords": ["wgat"] },
    "suggestion": "软件包目录里没有「wgat」，要不要说说你想做什么，我帮你找找？"
}
```

```json
{
    "type": "result",
    "status": "failed",
    "errCode": "ERR_INTERNAL",
    "errMsg": "no Would install line in output",
    "suggestion": "这次没成，稍后再试试。"
}
```

ERR_INVALID_PARAMS 分支（形态错误与字段缺失两种）同场景1。

### 场景4：AI 发起安装（requestInstall）

**触发**：用户说"装个 ffmpeg""帮我安装 ripgrep"等。

**成功后的动作**：`data.status` 为 `needs_confirmation`——把 `data.wouldInstall` 清单转述
给用户，并引导「在 Harmonybrew 里打开这个包的详情页，点安装才算数」。用户口头说"好的装吧"
**也不要**再次调用本技能、不要尝试执行任何安装命令；真正的安装只发生在 Harmonybrew
应用内、由用户亲手点击。本场景与场景3是同一份预演实现，仅回包语义与指引不同。

执行参数：

```text
exec(
  command: "ohos-arkTSScript --skillName 'handwer-brew-library' --scriptPath 'scripts/BrewSkill.ets' --functionName 'requestInstall' --args '{\"token\":\"ffmpeg\"}'",
  timeout_ms: 180000
)
```

```json
"args": {
  "type": "object",
  "properties": {
    "token": {
      "type": "string",
      "description": "用户想安装的软件包名；不确定时先用 searchPackages 确认"
    }
  },
  "required": ["token"]
}
```

执行返回值：

```json
{
    "type": "result",
    "status": "success",
    "data": {
        "token": "ffmpeg",
        "status": "needs_confirmation",
        "cmdline": "brew install --dry-run ffmpeg",
        "declaredCount": 3,
        "wouldInstall": [
            { "name": "ffmpeg", "version": "7.1.1_1", "kind": "formula" },
            { "name": "aom", "version": "3.9.1", "kind": "formula" },
            { "name": "dav1d", "version": "1.5.0", "kind": "formula" }
        ]
    },
    "suggestion": "预演完成，请在 Harmonybrew 里打开这个包的详情页，点安装才算数。"
}
```

失败分支（ERR_INVALID_PARAMS / ERR_NOT_FOUND / ERR_INTERNAL）与场景3完全一致。

### 场景5：查看已装清单（listInstalled）

**触发**：用户说"我都装了些什么""装了哪些命令行工具""有没有装 curl"等。

**成功后的动作**：按 `data.rows` 转述；`total` / `formulaCount` / `caskCount` /
`outdatedCount` 是全量统计，`rows` 是按 `limit` 截断的清单（默认 20 条）。`asOf` 是快照
时刻，转述时带上「数据截至」。要找某个具体包时优先用 queryPackage。

执行参数：

```text
exec(
  command: "ohos-arkTSScript --skillName 'handwer-brew-library' --scriptPath 'scripts/BrewSkill.ets' --functionName 'listInstalled' --args '{\"filter\":\"formula\",\"query\":\"\",\"limit\":10}'",
  timeout_ms: 60000
)
```

```json
"args": {
  "type": "object",
  "properties": {
    "filter": {
      "type": "string",
      "enum": ["all", "formula", "cask", "outdated", "updated"],
      "description": "筛选：全部 / formula / cask / 待更新 / 已是最新。可省略，默认 all"
    },
    "query": {
      "type": "string",
      "description": "按包名子串过滤，如 \"git\"。可省略"
    },
    "limit": {
      "type": "number",
      "description": "返回条数上限（1–50）。可省略，默认 20"
    }
  },
  "required": []
}
```

执行返回值：

```json
{
    "type": "result",
    "status": "success",
    "data": {
        "filter": "formula",
        "query": "",
        "hasSnapshot": true,
        "asOf": 1763800000000,
        "total": 38,
        "formulaCount": 38,
        "caskCount": 4,
        "outdatedCount": 3,
        "rows": [
            { "name": "git", "kind": "formula", "version": "2.51.0", "latestVersion": "2.51.0", "outdated": false, "installedAsDependency": false },
            { "name": "wget", "kind": "formula", "version": "1.25.0_2", "latestVersion": "1.26.0", "outdated": true, "installedAsDependency": false }
        ]
    }
}
```

```json
{
    "type": "result",
    "status": "failed",
    "errCode": "ERR_INVALID_PARAMS",
    "errMsg": "filter must be all/formula/cask/outdated/updated",
    "suggestion": "filter 取值是 all / formula / cask / outdated / updated，你想看哪一类？"
}
```

```json
{
    "type": "result",
    "status": "failed",
    "errCode": "ERR_INTERNAL",
    "errMsg": "brew is unavailable",
    "suggestion": "设备上还没有可用的 brew。先在 Harmonybrew 里完成 brew 探测，再让我来。"
}
```

### 场景6：查看待更新清单（listOutdated）

**触发**：用户说"有什么要升级的""哪些包过时了"等。

**成功后的动作**：转述 `data.rows`（每行 name / version → latestVersion）；`asOf` 是快照
时刻。升级动作本身不要发起——想升哪个，用 previewUpgrade 先预演。

执行参数：

```text
exec(
  command: "ohos-arkTSScript --skillName 'handwer-brew-library' --scriptPath 'scripts/BrewSkill.ets' --functionName 'listOutdated' --args '{}'",
  timeout_ms: 60000
)
```

```json
"args": {
  "type": "object",
  "properties": {},
  "required": []
}
```

执行返回值：

```json
{
    "type": "result",
    "status": "success",
    "data": {
        "hasSnapshot": true,
        "asOf": 1763800000000,
        "total": 2,
        "rows": [
            { "name": "wget", "kind": "formula", "version": "1.25.0_2", "latestVersion": "1.26.0", "outdated": true, "installedAsDependency": false },
            { "name": "jq", "kind": "formula", "version": "1.7.1", "latestVersion": "1.8.0", "outdated": true, "installedAsDependency": false }
        ]
    }
}
```

失败分支与场景5一致（ERR_INTERNAL / ERR_INVALID_PARAMS）。

### 场景7：预演升级单包（previewUpgrade）

**触发**：用户说"把 wget 升上去会怎样""先预演升级 ffmpeg"等。

**成功后的动作**：转述 `data.wouldUpgrade`（fromVersion → version）与 `data.cmdline`；
说明这是 dry-run 预演、还没有升级。`data.status` 为 `not_installed` 时说明这个包还没装
（想装走 previewInstall）；`nothing_to_upgrade` 时说明已是最新。

执行参数：

```text
exec(
  command: "ohos-arkTSScript --skillName 'handwer-brew-library' --scriptPath 'scripts/BrewSkill.ets' --functionName 'previewUpgrade' --args '{\"token\":\"wget\"}'",
  timeout_ms: 180000
)
```

```json
"args": {
  "type": "object",
  "properties": {
    "token": {
      "type": "string",
      "description": "要预演升级的软件包名；最好先用 queryPackage 确认它已安装且过时"
    }
  },
  "required": ["token"]
}
```

执行返回值：

```json
{
    "type": "result",
    "status": "success",
    "data": {
        "token": "wget",
        "status": "preview",
        "cmdline": "brew upgrade wget --dry-run",
        "declaredCount": 1,
        "wouldUpgrade": [
            { "name": "wget", "fromVersion": "1.25.0_2", "version": "1.26.0", "kind": "formula" }
        ]
    },
    "suggestion": "预演清单在上面。升级请在 Harmonybrew 里打开这个包的详情页操作。"
}
```

```json
{
    "type": "result",
    "status": "success",
    "data": {
        "token": "wget",
        "status": "not_installed"
    },
    "suggestion": "这个包还没有安装记录。想装的话告诉我，我先给你预演安装。"
}
```

```json
{
    "type": "result",
    "status": "success",
    "data": {
        "token": "git",
        "status": "nothing_to_upgrade",
        "cmdline": "brew upgrade git --dry-run"
    },
    "suggestion": "它已经是最新版本，没有可升级的。"
}
```

失败分支（ERR_NOT_FOUND / ERR_INTERNAL / ERR_INVALID_PARAMS）与场景3一致。

### 场景8：预演批量升级（previewUpgradeAll）

**触发**：用户说"全部升级会动哪些包""批量升级前先看看"等。

**成功后的动作**：转述 `data.wouldUpgrade` 清单（可能很长，`declaredCount` 是 brew 报的
总数）与 `data.cmdline`；说明这是 dry-run 预演。`nothing_to_upgrade` 表示没有待升级的包。
真正的批量升级在 Harmonybrew 的「我的 - 待更新」页。

执行参数：

```text
exec(
  command: "ohos-arkTSScript --skillName 'handwer-brew-library' --scriptPath 'scripts/BrewSkill.ets' --functionName 'previewUpgradeAll' --args '{\"scope\":\"all\"}'",
  timeout_ms: 180000
)
```

```json
"args": {
  "type": "object",
  "properties": {
    "scope": {
      "type": "string",
      "enum": ["all", "formula", "cask"],
      "description": "升级范围。可省略，默认 all"
    }
  },
  "required": []
}
```

执行返回值：

```json
{
    "type": "result",
    "status": "success",
    "data": {
        "scope": "all",
        "status": "preview",
        "cmdline": "brew upgrade --dry-run",
        "declaredCount": 2,
        "wouldUpgrade": [
            { "name": "wget", "fromVersion": "1.25.0_2", "version": "1.26.0", "kind": "formula" },
            { "name": "jq", "fromVersion": "1.7.1", "version": "1.8.0", "kind": "formula" }
        ]
    },
    "suggestion": "预演清单在上面。升级请在 Harmonybrew 的「我的 - 待更新」页操作。"
}
```

失败分支与场景3一致（ERR_INTERNAL / ERR_INVALID_PARAMS）。

### 场景9：卸载影响评估（previewUninstall）

**触发**：用户说"卸载 wget 会影响什么""我想卸掉 docker，先看看影响"等。

**成功后的动作**：`data.status` 为 `needs_confirmation` 时，转述包信息、`dependents`
（有多少已安装包依赖它，formula 才查）与展示用 `plannedCommand`；强调卸载要在
Harmonybrew 的「我的 - 本机包」里亲手操作。`not_installed` 说明没有安装记录、无需卸载。
**绝不**自己执行任何卸载命令。

执行参数：

```text
exec(
  command: "ohos-arkTSScript --skillName 'handwer-brew-library' --scriptPath 'scripts/BrewSkill.ets' --functionName 'previewUninstall' --args '{\"token\":\"wget\"}'",
  timeout_ms: 180000
)
```

```json
"args": {
  "type": "object",
  "properties": {
    "token": {
      "type": "string",
      "description": "想卸载的软件包名；不确定时先用 queryPackage 确认它已安装"
    }
  },
  "required": ["token"]
}
```

执行返回值：

```json
{
    "type": "result",
    "status": "success",
    "data": {
        "token": "wget",
        "status": "needs_confirmation",
        "kind": "formula",
        "version": "1.25.0_2",
        "plannedCommand": "brew uninstall wget",
        "dependents": [],
        "usesOk": true,
        "asOf": 1763800000000
    },
    "suggestion": "卸载请打开 Harmonybrew 的「我的 - 本机包」，对这个包亲手操作卸载才算数。"
}
```

```json
{
    "type": "result",
    "status": "success",
    "data": {
        "token": "docker",
        "status": "not_installed"
    },
    "suggestion": "这个包没有安装记录，无需卸载。"
}
```

失败分支（ERR_NOT_FOUND / ERR_INTERNAL / ERR_INVALID_PARAMS）与场景3一致。

### 场景10：查询包详情（packageDetail）

**触发**：用户说"ffmpeg 依赖什么""wget 的主页是什么""这个包还维护吗"等。

**成功后的动作**：转述描述、版本、主页、依赖清单、热度（installs30d）与生命周期状态；
`deprecated` / `disabled` 为 true 时如实说明弃用/停用原因。`installed` / `installedVersion`
来自本机快照（`asOf` 数据截至）。`outdated=true` 时可以顺势建议预演升级。

执行参数：

```text
exec(
  command: "ohos-arkTSScript --skillName 'handwer-brew-library' --scriptPath 'scripts/BrewSkill.ets' --functionName 'packageDetail' --args '{\"token\":\"wget\"}'",
  timeout_ms: 120000
)
```

```json
"args": {
  "type": "object",
  "properties": {
    "token": {
      "type": "string",
      "description": "软件包名；不确定时先用 searchPackages 确认"
    }
  },
  "required": ["token"]
}
```

执行返回值：

```json
{
    "type": "result",
    "status": "success",
    "data": {
        "token": "wget",
        "kind": "formula",
        "desc": "Internet file retriever",
        "version": "1.26.0",
        "homepage": "https://www.gnu.org/software/wget/",
        "license": "GPL-3.0-or-later",
        "categoryKey": "network",
        "installs30d": 18200,
        "dependencies": ["openssl@3", "libidn2"],
        "caveats": "",
        "deprecated": false,
        "deprecationReason": "",
        "disabled": false,
        "disableReason": "",
        "installed": true,
        "installedVersion": "1.25.0_2",
        "outdated": true,
        "asOf": 1763800000000
    },
    "suggestion": "这个包有新版本。想升级的话告诉我，我先给你预演一下。"
}
```

失败分支（ERR_NOT_FOUND / ERR_INTERNAL / ERR_INVALID_PARAMS）与场景3一致。

### 场景11：查询用法示例（packageUsage）

**触发**：用户说"wget 怎么用""给我几个 curl 的例子"等。

**成功后的动作**：转述 `data.examples`（desc 是示例说明，code 是命令原文）；`code` 里的
`{{占位符}}` 要提醒用户替换成自己的值。`found=false` 表示示例库没有这个命令的页面，
属正常（增强层），如实说明即可，不要编造示例。

执行参数：

```text
exec(
  command: "ohos-arkTSScript --skillName 'handwer-brew-library' --scriptPath 'scripts/BrewSkill.ets' --functionName 'packageUsage' --args '{\"token\":\"wget\"}'",
  timeout_ms: 120000
)
```

```json
"args": {
  "type": "object",
  "properties": {
    "token": {
      "type": "string",
      "description": "命令名，如 wget、curl、tar"
    }
  },
  "required": ["token"]
}
```

执行返回值：

```json
{
    "type": "result",
    "status": "success",
    "data": {
        "token": "wget",
        "found": true,
        "locale": "zh",
        "summary": "wget 是从网络下载文件的命令行工具，支持断点续传与递归下载。",
        "examples": [
            { "desc": "下载一个网页到当前目录", "code": "wget https://example.com", "hasPlaceholder": false },
            { "desc": "断点续传下载大文件", "code": "wget -c {{url}}", "hasPlaceholder": true }
        ]
    }
}
```

```json
{
    "type": "result",
    "status": "success",
    "data": {
        "token": "no-such-page",
        "found": false
    },
    "suggestion": "tldr 示例库里没有这个命令的页面（增强层，缺失属正常）。"
}
```

失败分支（ERR_INVALID_PARAMS / ERR_INTERNAL）与场景1一致。

### 场景12：查看热门榜单（listTrending）

**触发**：用户说"最近什么工具火""cask 里什么最热""有哪些新冒出来的包"等。

**成功后的动作**：按 `data.rows` 转述名次与包名；`score` 仅 trending 榜有意义；
`windowStart` / `windowEnd` 是数据窗口，转述时带上「基于最近可用数据」的含义。
榜单数据来自包表（零请求），目录未就绪时 rows 为空并附 suggestion。

执行参数：

```text
exec(
  command: "ohos-arkTSScript --skillName 'handwer-brew-library' --scriptPath 'scripts/BrewSkill.ets' --functionName 'listTrending' --args '{\"board\":\"trending\",\"kind\":\"formula\",\"limit\":5}'",
  timeout_ms: 60000
)
```

```json
"args": {
  "type": "object",
  "properties": {
    "board": {
      "type": "string",
      "enum": ["trending", "alltime", "fresh"],
      "description": "趋势榜 / 历史累计榜 / 新星榜。可省略，默认 trending"
    },
    "kind": {
      "type": "string",
      "enum": ["formula", "cask"],
      "description": "包类型。可省略，默认 formula"
    },
    "limit": {
      "type": "number",
      "description": "返回条数上限（1–50）。可省略，默认 10"
    }
  },
  "required": []
}
```

执行返回值：

```json
{
    "type": "result",
    "status": "success",
    "data": {
        "board": "trending",
        "kind": "formula",
        "state": "ready",
        "windowStart": "2026-10-24",
        "windowEnd": "2026-11-22",
        "rows": [
            { "rank": 1, "token": "yt-dlp", "desc": "A youtube-dl fork with additional features and fixes", "installs30d": 41000, "installs365d": 512000, "score": 3.42 },
            { "rank": 2, "token": "ripgrep", "desc": "Search tool like grep and The Silver Searcher", "installs30d": 38500, "installs365d": 470000, "score": 2.11 }
        ]
    }
}
```

```json
{
    "type": "result",
    "status": "failed",
    "errCode": "ERR_INVALID_PARAMS",
    "errMsg": "board must be trending/alltime/fresh; kind must be formula/cask",
    "suggestion": "board 取值是 trending / alltime / fresh，kind 取值是 formula / cask。"
}
```

### 场景13：查看分类清单（listCategories）

**触发**：用户说"都有哪些分类""游戏类里有什么"等。

**成功后的动作**：转述两类分类（key / name / 包数）；想看某分类下的包时，引导用户在
Harmonybrew 内浏览，或用 searchPackages 按关键词找。目录未就绪时两个清单为空并附 suggestion。

执行参数：

```text
exec(
  command: "ohos-arkTSScript --skillName 'handwer-brew-library' --scriptPath 'scripts/BrewSkill.ets' --functionName 'listCategories' --args '{}'",
  timeout_ms: 60000
)
```

```json
"args": {
  "type": "object",
  "properties": {},
  "required": []
}
```

执行返回值：

```json
{
    "type": "result",
    "status": "success",
    "data": {
        "state": "ready",
        "formula": [
            { "categoryKey": "terminal", "name": "Terminal & Shell", "itemCount": 186 },
            { "categoryKey": "network", "name": "Network & Transfer", "itemCount": 240 }
        ],
        "cask": [
            { "categoryKey": "browser", "name": "Browser", "itemCount": 42 },
            { "categoryKey": "devide", "name": "Development & IDE", "itemCount": 95 }
        ]
    }
}
```

失败分支与场景1一致（ERR_INTERNAL / ERR_INVALID_PARAMS）。

### 场景14：brew 状态自检（checkBrew）

**触发**：用户说"brew 好使吗""brew 什么版本""为什么装不了东西"等。

**成功后的动作**：转述 `ready`（能不能干活）、`version`（brew 版本）与 `prefix`；`ready=false`
时如实转述 `failureMessage` 并建议先在 Harmonybrew 里完成 brew 探测。本场景只跑一条只读的
`brew config`，不改任何状态。

执行参数：

```text
exec(
  command: "ohos-arkTSScript --skillName 'handwer-brew-library' --scriptPath 'scripts/BrewSkill.ets' --functionName 'checkBrew' --args '{}'",
  timeout_ms: 180000
)
```

```json
"args": {
  "type": "object",
  "properties": {},
  "required": []
}
```

执行返回值：

```json
{
    "type": "result",
    "status": "success",
    "data": {
        "ready": true,
        "enabled": true,
        "shellAvailable": true,
        "brewPath": "/data/harmonybrew/bin/brew",
        "prefix": "/data/harmonybrew",
        "version": "4.6.9",
        "configOk": true,
        "failureMessage": ""
    }
}
```

```json
{
    "type": "result",
    "status": "success",
    "data": {
        "ready": false,
        "enabled": true,
        "shellAvailable": true,
        "brewPath": "",
        "prefix": "",
        "version": "",
        "configOk": false,
        "failureMessage": "brew executable not found"
    },
    "suggestion": "设备上还没有可用的 brew。先在 Harmonybrew 里完成 brew 探测，再让我来。"
}
```

本场景回包永远 `status: "success"`，问题由 data 字段承载。
