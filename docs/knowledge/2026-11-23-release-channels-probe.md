# 更新情报通道探测记录(2026-11-23)

> Y 更新情报中心(Release Intelligence)前置调研。所有探测于 2026-11-23 经代理池出口执行,**设备侧(中国网络)可达性未经真机验证**,须在实现时立 Stage-0 探针门。

## 1. GitHub REST API(api.github.com)

| 探测 | 结果 |
|---|---|
| `GET https://api.github.com/repos/Homebrew/homebrew-core/commits?path=Formula/w/wget.rb&per_page=3` | **HTTP 403** `API rate limit exceeded for 101.32.189.54` |
| `GET https://api.github.com/advisories?affects=curl&per_page=2` | **HTTP 403** `API rate limit exceeded for 199.182.234.55`(不同出口 IP,同样烧穿) |

**结论:无认证 GitHub REST 不可作为依赖通道**(共享出口 IP 下 60 req/h 配额不可控)。带 GitHub PAT 可解,但与项目 BYOK 民营化立场叠加后配置负担过重,v1 不做,列为 P2 可选项。

## 2. Releases Atom Feed(主通道,已验证可用)

`GET https://github.com/{owner}/{repo}/releases.atom` → **HTTP 200,免 token**。

实测样例(ripgrep)entry 结构:

```xml
<entry>
  <id>tag:github.com,2008:Repository/{repoId}/{tag}</id>
  <updated>2026-11-22T22:59:48Z</updated>
  <title>14.1.1</title>            <!-- = tag -->
  <content type="html">&lt;p&gt;完整 release notes HTML…&lt;/p&gt;</content>
  <author><name>github-actions[bot]</name></author>
</entry>
```

关键发现:

1. **feed 混入子包发布**:ripgrep 的 feed 含 `ignore-0.4.34`、`globset-0.4.21` 等 workspace 子 crate 的 tag。必须按 tag ↔ formula 目标版本精确匹配过滤,否则会把子包发布当主程序情报。
2. **content 为 HTML**:需剥标签后才能喂 AI;要在 spec 定截断上限。
3. **仅覆盖 GitHub 托管项目**:wget(GNU/gitlab 托管)没有 GitHub repo → 信息缺口;须从 formula 元数据判定。
4. author 常为 `github-actions[bot]`,不能当作者署名展示。

## 3. 镜像可达性

| 通道 | 结果 |
|---|---|
| `https://ghfast.top/https://raw.githubusercontent.com/Homebrew/homebrew-core/HEAD/Formula/w/wget.rb` | **HTTP 200**,完整 formula Ruby 源文 |
| `https://ghfast.top/https://github.com/BurntSushi/ripgrep/releases.atom` | **HTTP 403 `Invalid input`** —— **镜像不代理 releases.atom** |
| `https://ghproxy.net/...`(同类) | 网络层失败(fetch failed) |

**结论:atom 只能直连 github.com**;raw formula 文件可用 ghfast.top 作为镜像备选(v1 用不上,formula diff 走 API JSON 见 §5)。镜像稳定性整体不可靠,任何直连失败即走信息缺口,不做镜像轮询兜底(v1)。

## 4. 漏洞库通道(OSV)

| 探测 | 结果 |
|---|---|
| `GET https://api.osv.dev/v1/vulns/CVE-2023-38545` | **HTTP 200**,完整 JSON(details/aliases/affected ranges/versions/CVSS_V3/references) |
| `GET https://api.osv.dev/v1/ecosystems` | **HTTP 404**(无此端点) |
| `raw.githubusercontent.com/ossf/osv-schema/{main,master}/ecosystems.md` | 均 404(文档路径变更,未复核到生态清单) |

**结论:OSV「按 ID 查详情」免认证可用,但未能证实存在按包名枚举的免认证通道,且 Homebrew 生态覆盖未确认**。GitHub advisories API 需 token(§1)。v1 安全修复识别降级为「release notes 文本自述分类 + 来源标注」,漏洞库接入列为 P2/未决。

## 5. formula 级变更对比(「差在哪」)

不依赖 GitHub commits API。方案:**新版 formula JSON(`/api/formula/<token>.json`,~5KB)vs 本地缓存的旧版 JSON**(详情页取数时已在 `brew_src_<id>` store 留存上次成功详情)。

可结构化 diff 的字段:`dependencies` / `build_dependencies` / `uses_from_macos` 增删、`caveats` 变化(文本 diff)、`revision`、`urls.stable.url/scheme`、`versions.stable`。全程零 AI、零新增网络通道。

## 6. 体积预测数据缺口

bottle 体积不在 formula API(`bottle.stable.files` 仅 sha256);`brew info` 的 size 仅覆盖**已安装**包(`BrewInfoSizeParser`)。未安装的新版本体积不可得 → 体积差显示「未知」,round6 愿景 demo 的「+38MB」不作为 v1 承诺。

## 7. 通道决策汇总

| 情报 | v1 通道 | 降级 |
|---|---|---|
| Release notes | `releases.atom` 直连(免 token) | 非 GitHub 项目 / 无匹配 tag / notes 空 → 信息缺口三级文案 |
| formula 变更 | 新旧 formula JSON 结构化 diff | 无旧缓存 → 只显示版本号变化 |
| 大版本识别 | semver 比较(结构化) | — |
| 安全修复 | notes 文本自述 + 来源标注 | 无声明 → 不显示;漏洞库 P2 |
| 中文摘要 | AI(复用一期 BYOK 底座) | 无 Key / AI 失败 → 结构化部分照常显示,AI 区不出现 |
| 体积差 | 不可得 | 显示「未知」 |

## 8. v1.1 增补:AtomGit 打包通道(2026-11-24,harmonybrew 源专用)

**背景**:用户实测反馈「上游不是 GitHub 就获取不了,而 harmonybrew 的上游本来就不是 GitHub」。harmonybrew 源的打包上游是 AtomGit 仓库,formula 的 homepage 是原始项目页——RepoResolver 全部落 F2,AI 区恒空。

探测(全部 2026-11-24,代理池出口):

| 探测 | 结果 |
|---|---|
| `https://atomgit.com/Harmonybrew`(组织页) | **200**:「核心 tap,大部分 formula 搬迁自上游 Homebrew/homebrew-core」;另有 Harmonybrew/brew(brew 客户端鸿蒙移植)、formula-migration-tool、custom-tap-example |
| `https://atomgit.com/Harmonybrew/homebrew-core` 仓库页 | 200,commit 活跃(当天有更新);目录为 homebrew-core 惯例 `Formula/<首字母>/<token>.rb` 分片 |
| AtomGit API 文档([commits](https://atomgit-api-doc.atomgit.com/6.commit/130.get_all_repository_commits.html)) | **允许匿名**:`GET https://api.atomgit.com/api/v5/repos/{owner}/{repo}/commits?path=<file>&per_page≤100`,支持 path 按文件过滤(GitHub v5 兼容响应形状);另有 release 接口(body=markdown) |
| `GET .../api/v5/repos/Harmonybrew/homebrew-core/releases`(匿名) | **HTTP 429** `{"error_code":429,...,"Threshold: 10W times per user per hour. Limited account:p_repoRobot"}` |
| `GET .../api/v5/repos/Harmonybrew/homebrew-core/commits?path=Formula/a/apr.rb&per_page=5`(匿名) | **HTTP 429**(同上;匿名请求共享 p_repoRobot 机器人账号的时配额,时忙时闲) |
| `https://atomgit.com/Harmonybrew/homebrew-core/raw/main/Formula/a/apr.rb` | 返回 HTML 页壳而非裸文件——**raw 直链不可用** |

**结论与设计落点(v1.1,spec §11)**:

1. harmonybrew 包的「打包更新记录」通道 = commits API 按 formula 文件路径过滤;GitHub 上游通道保留(部分包 homepage 本身是 GitHub 托管,双通道并行)。
2. **429 必须一等公民化**:匿名共享配额,任何失败(429/404/网络/解析)静默降级为不渲染打包记录组,不重试轰炸;`access_token` query 参数文档支持,BYOK 形态列 P2。
3. 本地 git log 通道(读 tap 工作区)违反 G12 审计零执行设计,不做。
4. verdict/diff 对 harmonybrew 包本就可用(HarmonybrewMap 映射后是 official 形状),v1.1 只补上游情报通道。

## 9. v1.2 增补:打包通道实证失败并移除;GitHub 数据质量两例(2026-11-24)

**打包通道移除**:临时关 AI 放出打包记录组真机观察,结论=**AtomGit tap 提交流全是机器人提交(迁移 bot),对用户无信息量**。通道整段拆除(spec §12,G14/F8 撤销);本节探测记录保留作教训——「提交列表」形态的情报对 tap 类流水线仓库无效,评估同类通道前先抽样看 message 质量。

**GitHub releases 数据质量(两例实证)**:

| 仓库 | releases.atom 实况 | 对 Y 的含义 |
|---|---|---|
| `hqzing/ohos-selfsign` | 10 条 release,tag 齐全(v3.1.1→v1.1.0),但 **8/10 正文是字面量 `No content.`** 占位符,只有 v3.0.0/v2.0.0 各一句真实说明 | 空说明占位符必须识别为空 → F4「该版本未填写发布说明」,否则占位符会被当正文喂给 AI(v1.2 已修:NotesExtractor 识别 `No content.`) |
| `OpenPrinting/cups` | v2.4.20 正文完整(CVE-2026-55480 等 7 个 CVE 清单 + What's Changed),v2.4.13–2.4.19 每篇有内容——**通道没问题** | 用户误判「抓不到」的真因=更新日志只经 AI 摘要渲染,AI 关/无 Key 时卡片不渲染 notes 原文 → v1.2 增 `notesPreview`(≤700 字符原文节选),card=null 时渲染「原始发布说明(节选)」,零编造 |
| 同仓 `commits.atom` | 匿名可用,人类中文提交质量高(「修复 --force 重签时丢失 .codesign 段之后内容的问题」) | 「无 release notes 仓库」的候选兜底通道,但与打包通道同属提交列表形态——**暂不实施**(先看打包通道教训;若接,只接 notes 为空时兜底 + 过滤 bot 作者,P2) |
