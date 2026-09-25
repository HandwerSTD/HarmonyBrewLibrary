# 分类词表实验（现网全量）

## formula：8611 条

| 方案 | 兜底(全部) | 兜底率(全部) | 兜底率(有 desc) | 关键词 | 主题 | 形态桶 | 库(试) | 策展 |
|---|---|---|---|---|---|---|---|---|
| S0 现状（overrides + 关键词 + 兜底） | 6080 | **70.6%** | 70.6% | 2412 | 0 | 0 | 0 | 119 |
| S1a 匹配串前置 token | 6164 | **71.6%** | 71.6% | 2328 | 0 | 0 | 0 | 119 |
| S1b 匹配串追加 token | 6000 | **69.7%** | 69.7% | 2492 | 0 | 0 | 0 | 119 |
| S2 加第 9 类 lib（只看形态词） | 4655 | **54.1%** | 54.1% | 3075 | 0 | 0 | 762 | 119 |
| S3 不加类：主题归入现有 8 类 | 4883 | **56.7%** | 56.7% | 2412 | 1197 | 0 | 0 | 119 |
| S4 S1b + S2 | 4579 | **53.2%** | 53.2% | 3152 | 0 | 0 | 761 | 119 |
| S5 S1b + S3 + S2（主题优先，库形态兜最后） | 3973 | **46.1%** | 46.1% | 3152 | 935 | 0 | 432 | 119 |
| **S8 生产方案**：S3 + `_forms` 形态桶（lib，不进打分） | 4145 | **48.1%** | 48.1% | 2412 | 1197 | 738 | 0 | 119 |

S5 的分类分布：{"system": 4595, "devtools": 984, "terminal": 954, "lib": 738, "network": 329, "media": 314, "data": 284, "ai": 221, "cloudnative": 192}

S5 里主题映射实际命中的词（前 20）：`c -> devtools`(212), `command line -> terminal`(104), `command line tool -> terminal`(77), `c++ -> devtools`(53), `command line interface -> terminal`(46), `python -> devtools`(37), `terminal -> terminal`(30), `data -> data`(25), `git -> devtools`(22), `testing -> devtools`(21), `rust -> devtools`(20), `java -> devtools`(19), `kubernetes -> cloudnative`(16), `files -> system`(13), `ai -> ai`(13), `audio -> media`(12), `javascript -> devtools`(11), `image processing -> media`(10), `pdf -> media`(10), `json -> data`(10)

## cask：7745 条（其中 2645 条 desc 为空 —— 永远无法分类，是硬上限）

| 方案 | 兜底(全部) | 兜底率(全部) | 兜底率(有 desc) | 关键词 | 主题 | 形态桶 | 库(试) | 策展 |
|---|---|---|---|---|---|---|---|---|
| S0 现状（overrides + 关键词 + 兜底） | 5431 | **70.1%** | 54.6% | 2193 | 0 | 0 | 0 | 121 |
| S1a 匹配串前置 token | 5479 | **70.7%** | 58.6% | 2145 | 0 | 0 | 0 | 121 |
| S1b 匹配串追加 token | 5272 | **68.1%** | 54.6% | 2352 | 0 | 0 | 0 | 121 |
| S2 加第 9 类 lib（只看形态词） | 5349 | **69.1%** | 53.0% | 2212 | 0 | 0 | 63 | 121 |
| S3 不加类：主题归入现有 8 类 | 5244 | **67.7%** | 51.0% | 2193 | 187 | 0 | 0 | 121 |
| S4 S1b + S2 | 5189 | **67.0%** | 52.9% | 2372 | 0 | 0 | 63 | 121 |
| S5 S1b + S3 + S2（主题优先，库形态兜最后） | 5012 | **64.7%** | 49.5% | 2372 | 189 | 0 | 51 | 121 |
| **S8 生产方案**：S3 + `_forms` 形态桶（lib，不进打分） | 5244 | **67.7%** | 51.0% | 2193 | 187 | 0 | 0 | 121 |

S5 的分类分布：{"systemtool": 5723, "devide": 504, "av": 317, "aivm": 309, "productivity": 289, "design": 268, "comm": 207, "browser": 128}

S5 里主题映射实际命中的词（前 20）：`remote desktop -> comm`(18), `command line -> devide`(16), `markdown editor -> productivity`(12), `ai -> aivm`(10), `music -> av`(9), `audio -> av`(8), `developers -> devide`(8), `quick look -> systemtool`(8), `3d -> design`(6), `coding -> devide`(5), `menu bar -> systemtool`(5), `code -> devide`(5), `mail -> comm`(5), `unity -> devide`(4), `image editor -> design`(3), `development -> devide`(3), `sql client -> devide`(3), `terminal -> devide`(3), `game engine -> devide`(3), `web -> browser`(3)

