---
name: handwer-brew-library
description: Harmonybrew 的软件包技能：按关键词查找 Homebrew 软件包、查询安装状态与版本、预演安装会带入哪些依赖。响应「找包」「装没装」「装个 XX」「预演安装」等软件包类指令。
---

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

能力边界（重要）：本技能**绝不直接执行安装、升级或卸载**。`requestInstall` 只返回 dry-run 预演清单与操作指引；真正的安装由用户在 Harmonybrew 应用内打开对应软件包详情页、亲手点「安装」完成。

### 场景1：按关键词查找软件包（searchPackages）

用户给出用途、描述或关键词，返回目录中最匹配的软件包（名称、类型、一句话描述）。

执行参数：

```bash
exec-cli(command: ohos-arkTSScript --skillName 'handwer-brew-library' --scriptPath 'scripts/BrewSkill.ets' --functionName 'searchPackages' --args '{
    "query": "下载视频"
}'
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

对应的 Schema 约束（顶层分支：成功要求 data.rows 与 data.matchedCount；两类失败要求 errMsg 与 suggestion）：

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

返回包的目录信息与**冻结口径**的安装状态（来自本机快照，asOf 为快照时刻，epoch 毫秒；0 表示从未读取过本机包）。

执行参数：

```bash
exec-cli(command: ohos-arkTSScript --skillName 'handwer-brew-library' --scriptPath 'scripts/BrewSkill.ets' --functionName 'queryPackage' --args '{
    "token": "wget"
}'
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

Schema 与场景1同构（成功要求 data；失败要求 errCode/errMsg/suggestion；errCode 枚举为 ERR_INVALID_PARAMS / ERR_NOT_FOUND / ERR_INTERNAL）。

### 场景3：预演安装（previewInstall）

返回 `brew install --dry-run` 的解析结果：会安装哪些包（含依赖）与命令行原文。**只读，不动盘，不执行安装。**

执行参数：

```bash
exec-cli(command: ohos-arkTSScript --skillName 'handwer-brew-library' --scriptPath 'scripts/BrewSkill.ets' --functionName 'previewInstall' --args '{
    "token": "wget"
}'
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

ERR_INVALID_PARAMS 分支同场景2。

### 场景4：AI 发起安装（requestInstall）

**只预演，不执行、不碰 UI。** 返回与场景3同一份预演清单，`data.status` 为 `needs_confirmation`；由小艺把清单转述给用户，并引导用户在 Harmonybrew 应用内完成确认。真正的安装动作永远发生在 Harmonybrew 应用内、由用户亲手点击。

执行参数：

```bash
exec-cli(command: ohos-arkTSScript --skillName 'handwer-brew-library' --scriptPath 'scripts/BrewSkill.ets' --functionName 'requestInstall' --args '{
    "token": "ffmpeg"
}'
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
