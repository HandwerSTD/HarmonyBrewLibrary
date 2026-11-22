# hmkit-ai (vendored)

本模块是 [`@hmkit/ai`](https://github.com/lxshwyan/hmkit-ai) v2.0.0 的 **vendor 源码引入**
（upstream 仓库 `https://github.com/lxshwyan/hmkit-ai`，MIT License，见 LICENSE / CHANGELOG.md）。

## 为什么 vendor（2026-11-22 决策）

用户真机接自建 OpenAI 兼容端点（one-api 类网关）时，流式 chunk 携带 `"usage": null`
（OpenAI 协议允许 usage 缺省，`stream_options.include_usage` 只保证最后一个 chunk 带
usage），upstream `OpenAIStreamDecoder.consumeEvent` 只拦 `undefined` 不拦 `null`，
`consumeUsage(null)` 读 `null.prompt_tokens` 崩出 PROTOCOL 错误。该缺陷在包形态下只能
绕行（非流式直连），需求方指示改为源码引入直接修复——本目录即 upstream `ai/` 模块
原样拷贝，仅做工程接线（deviceTypes 对齐本工程、删除 upstream 的 src/test、本 NOTICE）。

## 本地修改（相对 upstream 2.0.0）

全部修改集中在本文件登记，方便日后升级 upstream 时 rebase：

1. `src/main/ets/protocol/OpenAIStreamDecoder.ets`：
   - `consumeEvent`：`chunk.model` / `chunk.usage` / `chunk.choices` 判空补 `!== null`
     （`"usage": null` 崩溃根因修复）；`choice` / `tool_calls[i]` 元素也判空跳过；
   - `consumeUsage` 入口 `undefined || null` 判空兜底；
   - `consumeDelta`：`delta.tool_calls` 判空补 `!== null`。
2. `src/main/ets/responses/ResponsesDecoder.ets`：同款 JSON null 陷阱预防——
   `event.item` / `event.response` / `response.usage` 判空补 `!== null`。
2. `src/main/ets/responses/ResponsesDecoder.ets`：同款 JSON null 陷阱预防——
   `event.item` / `event.response` / `response.usage` 判空补 `!== null`。
3. `src/main/module.json5`：deviceTypes 增加 `default` / `2in1`（本工程 PC 形态）。
4. 删除 `src/test/`（本工程未启用该 HAR 的 ohosTest target）。
5. 本 NOTICE 与 oh-package.json5 描述。

其余文件与 upstream 2.0.0 一致；升级时以 upstream 为准重新对diff。
