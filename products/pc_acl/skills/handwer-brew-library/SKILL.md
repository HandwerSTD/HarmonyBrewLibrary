---
name: handwer-brew-library
description: >-
  Harmonybrew 的软件包技能：按关键词查找 Homebrew 软件包、查询安装状态与版本、
  预演安装会带入哪些依赖。可响应「找找能下载视频的工具」「ffmpeg 装了没有」
  「装个 ffmpeg」「装 ffmpeg 会带哪些东西」等意图。
  不适用于卸载软件包、更新系统或系统应用、管理图形应用、查询 brew 资讯；
  绝不直接执行安装——安装由用户在 Harmonybrew 应用内亲手确认。
---

# Harmonybrew 软件包技能

提供 `searchPackages`（找包）、`queryPackage`（查状态）、`previewInstall`（预演）、
`requestInstall`（发起安装，只预演不执行）四项能力。本技能**只提供设备侧 exec-cli 通道**，
不存在云端 invoke 工具。

## 调用方式（exec-cli / ohos-arkTSScript）

**第一步：先把全部业务参数压成一个字符串。** 构造业务参数对象，执行一次
`JSON.stringify(params)` 得到 `payload`，作为**唯一**参数传入（`argv.length === 1`，
argv[0] 是可解析的 JSON 对象字符串）。禁止把字段拆成多个位置参数，禁止 `Object.values`。

**第二步：exec-cli 命令行中把内部双引号转义为 `\"`。** 即把 `"` 写成 `\"`，再将完整内容
作为 `--args` 的唯一参数。本技能的 ETS 入口会先尝试直接解析，失败后再将收到的 `\"`
还原为 `"` 并解析，两种形态都接受。

```text
序列化后的 payload：{"query":"下载视频"}
B 命令中的参数：--args '{\"query\":\"下载视频\"}'
```

```bash
exec-cli(command: ohos-arkTSScript --skillName 'handwer-brew-library' --scriptPath 'scripts/BrewSkill.ets' --functionName 'searchPackages' --args '{\"query\":\"下载视频\"}'
)
```

## 返回结果与错误处理

只有返回 `status: "success"` 才表示业务成功。

- `ERR_INVALID_PARAMS` 且 `errMsg` 以「参数传递格式错误」开头：按调用方式一节重新压参，
  自动重试**一次**；不要等用户提醒。
- `ERR_INVALID_PARAMS`（业务字段缺失，如 token 为空）：向用户问清缺失的参数再调用。
- `ERR_NOT_FOUND`：目录里没有这个名字。**不要**用同一参数重试，改用 `searchPackages`
  确认名字后再继续；绝不猜包名、不改写、不「纠正成相近包名」。
- `ERR_INTERNAL`：停止并如实转述 errMsg 与 suggestion，不自动重试。
- `previewInstall` 与 `requestInstall` 无论结果如何都**不自动重放**：预演是只读的可以手动
  再要一次，但发起安装只能由用户在应用内完成。

## 运行条件与业务约定

- 依赖设备上已安装 Harmonybrew 且完成 brew 探测；未安装或未就绪时按 `ERR_INTERNAL` 的
  suggestion 转述。
- 首次调用可能触发软件包目录刷新（应用冷启动时稍慢，属正常），不要因此中断流程。
- `queryPackage` 的安装状态来自**本机快照**（冻结口径）：`asOf` 是快照时刻（epoch 毫秒，
  0 表示从未读取过本机包），转述时应带上「数据截至」含义，不把旧数据说成实时。
- `previewInstall` / `requestInstall` 走真实 `brew install --dry-run`（只读、不动盘），
  需要网络，最长约两分钟。
- **安装永远由用户在 Harmonybrew 内打开软件包详情页、亲手点「安装」完成**；本技能不执行
  安装、升级、卸载，也不要在用户口头确认后代为执行。

## 触发场景

当用户表达**查找软件包**、**查询软件包状态**或**安装软件包（预演）**意图时调用。典型话术：

- "帮我找找能下载视频的命令行工具"、"有没有类似 grep 的工具" → searchPackages
- "ffmpeg 装了没有"、"gh 现在是什么版本"、"ripgrep 有没有新版本" → queryPackage
- "装 ffmpeg 会带哪些东西"、"先预演一下装 wget"、"装 docker 要占多少东西" → previewInstall
- "装个 ffmpeg"、"帮我安装 ripgrep"、"把 jq 装上" → requestInstall

不调用的情况：

- 用户说"更新系统"、"检查系统更新"——系统软件更新不是 Homebrew 软件包，应走系统能力。
- 用户说"卸载 XX 应用"——本技能不提供卸载，也不管理图形应用。
- 用户问"brew 是什么"、"Homebrew 新闻"——资讯类问题，不是对软件包的操作。
- 用户只是闲聊，没有明确的软件包指向（如"命令行真好用"）。
- 用户说"调大音量"、"打开蓝牙"——系统能力，与软件包无关。

### 场景1：按关键词查找软件包（searchPackages）

**触发**：用户说"帮我找找能下载视频的工具""有没有类似 grep 的命令"等。

**成功后的动作**：从 `data.rows` 逐条转述（name / kind / desc）；`matchedCount` 是本次
返回的条数。用户想要更多结果时，引导其在 Harmonybrew 内搜索，不要虚构目录里不存在的包名。

执行参数：

```bash
exec-cli(command: ohos-arkTSScript --skillName 'handwer-brew-library' --scriptPath 'scripts/BrewSkill.ets' --functionName 'searchPackages' --args '{\"query\":\"下载视频\"}'
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

```bash
exec-cli(command: ohos-arkTSScript --skillName 'handwer-brew-library' --scriptPath 'scripts/BrewSkill.ets' --functionName 'queryPackage' --args '{\"token\":\"wget\"}'
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

```json
{
    "type": "result",
    "status": "failed",
    "errCode": "ERR_INTERNAL",
    "errMsg": "brew is unavailable",
    "suggestion": "先在 Harmonybrew 里把 brew 探测跑通，再让我来。"
}
```

Schema 与场景1同构（成功要求 data；失败要求 errCode/errMsg/suggestion；errCode 枚举为
ERR_INVALID_PARAMS / ERR_NOT_FOUND / ERR_INTERNAL）。

### 场景3：预演安装（previewInstall）

**触发**：用户说"装 ffmpeg 会带哪些东西""先预演一下装 wget"等。

**成功后的动作**：转述 `data.wouldInstall` 清单与 `data.cmdline`；说明这是 dry-run 预演、
还没有安装任何东西。**不要**把预演结果转述成「已安装」。

执行参数：

```bash
exec-cli(command: ohos-arkTSScript --skillName 'handwer-brew-library' --scriptPath 'scripts/BrewSkill.ets' --functionName 'previewInstall' --args '{\"token\":\"wget\"}'
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

```bash
exec-cli(command: ohos-arkTSScript --skillName 'handwer-brew-library' --scriptPath 'scripts/BrewSkill.ets' --functionName 'requestInstall' --args '{\"token\":\"ffmpeg\"}'
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
