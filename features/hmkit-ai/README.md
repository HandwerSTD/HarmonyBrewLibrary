# @hmkit/ai

面向 HarmonyOS NEXT / OpenHarmony 的统一大模型 SDK 与 ArkUI V2 聊天组件。

## 能力

- OpenAI、DeepSeek、通义千问、豆包、智谱及自定义兼容服务。
- 文本、图片、文件和音频多模态消息。
- Chat Completions、Responses API、工具调用和结构化输出。
- 可审批、可中断恢复和可持久化的 Agent Runtime。
- 本地会话、搜索、导入导出、RAG 和引用来源。
- Markdown、语音、Realtime 与商用风格 ArkUI V2 聊天组件。

## 安装

```shell
ohpm install @hmkit/ai
```

## 快速开始

```ets
import { HmAIConversationController, HmAIMessage, HmAIProviders } from '@hmkit/ai';

const provider = HmAIProviders.deepSeek('deepseek-chat');
const client = provider.createChatClient(temporaryApiKey);
const controller = new HmAIConversationController(client);

await controller.sendMessage(HmAIMessage.user('你好，HarmonyOS'));
```

生产环境不要把长期模型 API Key 写进客户端。推荐由服务端代理保存供应商密钥，并向 App 签发短期、最小权限凭据。

完整文档、Demo、API 和测试请访问：

https://github.com/lxshwyan/hmkit-ai

## License

MIT
