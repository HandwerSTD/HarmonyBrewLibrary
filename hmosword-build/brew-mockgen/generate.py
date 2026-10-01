#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Homebrew 应用市场 · 策展清单校验器（原「mock 数据生成器」）

**2026-10：不再产出任何数据文件。** 内置 brew 数据快照
（`common/src/main/resources/rawfile/mockdata/*.json`）与整条 Mock 请求链路
（`TriggerEnums` / `MockRequest`）已删除，App 的数据只来自设备端目录（聚合端点）与现网单条。
于是本脚本从「生成 4 份 JSON」收敛为「校验 `tokens.json` 这份策展清单」——
它仍然是 `BrewTaxonomy.ets`（设备端分类）的**策展层数据源**，所以要有人看着它。

用法:
    python3 generate.py              # 校验策展 token 是否还在上游（命中 .brewgen/cache 时零请求）
    python3 generate.py --refresh    # 忽略缓存，重新拉一遍
    python3 generate.py --local      # 只做结构校验，完全不联网

退出码: 0 = 全部通过（可能有未能校验的项，见 stdout）；1 = 有 token 确认已从上游消失。

## 停产过的产物（以及为什么，这里留着，免得有人再让它们复活）

| 产物 | 为什么删 |
|---|---|
| `brew-discover-page.json` | Discover 的成员唯一来源已是设备端目录现算（`BrewCatalogAlgo.ets`），快照只剩「目录拿不到时的回落」；回落删除后骨架改为代码构造（`BrewRepository.emptyDiscoverPage`），榜算法口径的权威实现在 `check_algo.py` + `docs/brew-discover-algo.md` |
| `brew-local-{formulae,casks,outdated}.json` | HarmonyOS 上没有 brew，也没有可执行的本机包管理接口，纯属虚构数据；`MinePackagesUtil.loadSets` 改为返回空集（空态保壳） |
| `brew-{formula,cask}-page.json` | 「分类 + 成员」的冻结快照：成员 = 目录里按 30d 降序，分类 = `BrewTaxonomy.ets`（策展 → 关键词 → 兜底），两样都设备端现算 |
| `brew-{formula,cask}-details.json` | 详情页需要快照提供的只有本地 `id`、`categoryKey`、分类内名次，而这三样都能设备端算（`BrewApiMapper.formulaBase`）；其余 100% 由现网单条覆盖 |
| `brew-*-banner.json` | 早就没有 UI 调用点（两个首页的 `bannerHeight` 被固定为 0） |
| 本地 overview / taps / services | 无 UI 调用点，对应 `TriggerEnums` 成员已一并删除 |

要恢复某一份产物：git log 里有完整的 `build_discover()` / `build_local()` / `build_detail()`。
**别只恢复文件** —— 读它的那条链路（`MockRequest` / `TriggerEnums`）也必须一起回来，否则运行期静默失败。

## 本文件里**不要删**的部分

`classify()` / `subject_terms()` / `subject_index()` / `form_bucket()` / `subject_match()` /
`subject_of()` 是分类口径的**参考实现**：`eval_lexicon.py` 直接 import 它们，
设备端 `BrewTaxonomy.ets` 也必须与它们逐行一致（改了这里要同步改那边）。
"""

import json
import os
import re
import ssl
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
CACHE_DIR = os.path.join(ROOT, '.brewgen', 'cache')
API = 'https://formulae.brew.sh/api'
UA = {'User-Agent': 'brew-mockgen/1.0'}

_CTX = ssl.create_default_context()


# ---------------------------------------------------------------- io helpers

def load_json(name):
    with open(os.path.join(HERE, name), 'r', encoding='utf-8') as fp:
        return json.load(fp)


def cache_path(kind, token):
    safe = token.replace('/', '_')
    return os.path.join(CACHE_DIR, kind, safe + '.json')


def fetch(kind, token, refresh=False):
    """拉取单个 formula/cask 文档，落 `.brewgen/cache` 缓存。返回 (doc, error)。

    命中缓存就**不发请求**（返回 `(doc, None)`），所以重复跑校验几乎零成本。
    `error` 为字符串时分三种，只有第一种是「上游确认没有」：
      - `HTTP 404` / `HTTP 410`  → 确定被删/下架；
      - `net: …`（超时、TLS、解析失败） → 这次没验成，**不算缺失**；
      - 空 doc → 上游返回了空对象，同样当「没验成」。
    """
    path = cache_path(kind, token)
    if os.path.exists(path) and not refresh:
        with open(path, 'r', encoding='utf-8') as fp:
            return json.load(fp), None
    seg = 'formula' if kind == 'formula' else 'cask'
    url = '{}/{}/{}.json'.format(API, seg, token)
    req = urllib.request.Request(url, headers=UA)
    try:
        with urllib.request.urlopen(req, timeout=30, context=_CTX) as resp:
            raw = resp.read().decode('utf-8')
    except urllib.error.HTTPError as exc:
        return None, 'HTTP {}'.format(exc.code)
    except Exception as exc:                                  # noqa: BLE001
        return None, 'net: {}'.format(exc)
    try:
        doc = json.loads(raw)
    except ValueError as exc:
        return None, 'net: bad json: {}'.format(exc)
    if not doc:
        return None, 'net: empty doc'
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as fp:
        json.dump(doc, fp, ensure_ascii=False)
    time.sleep(0.05)                                          # 轻量节流
    return doc, None


def curated_tokens(tokens):
    """`tokens.json` 里按 kind 展开的「分类 -> [token]」（跳过 `_` 开头的注记层）。"""
    out = {}
    for kind, cats in tokens.items():
        if kind.startswith('_'):
            continue
        out[kind] = [(cat, tok) for cat, toks in cats.items() for tok in toks]
    return out


# ---------------------------------------------------------------- validation

def check_structure(tokens, categories):
    """结构校验（不联网）：分类 key 在 `categories.json` 里存在、token 非空且同一 kind 内不重复。"""
    problems = []
    known = {kind: {one['key'] for one in categories.get(kind, [])} for kind in ('formula', 'cask')}
    for kind, pairs in sorted(curated_tokens(tokens).items()):
        if kind not in known:
            problems.append('{}: 未知的 kind（categories.json 里没有）'.format(kind))
            continue
        seen = {}
        for cat, tok in pairs:
            if cat not in known[kind]:
                problems.append('{}: 分类 {} 不在 categories.json 里'.format(kind, cat))
            if not isinstance(tok, str) or not tok.strip():
                problems.append('{}: 分类 {} 下有空/非字符串 token'.format(kind, cat))
                continue
            if tok in seen:
                problems.append('{}: token {} 同时挂在 {} 与 {}'.format(kind, tok, seen[tok], cat))
            else:
                seen[tok] = cat
    return problems


def check_upstream(tokens, refresh=False):
    """逐个 token 问上游「还在吗」。返回 (missing, unverified, ok) 三个列表。"""
    missing, unverified, ok = [], [], 0
    for kind, pairs in sorted(curated_tokens(tokens).items()):
        for _cat, tok in pairs:
            doc, err = fetch(kind, tok, refresh=refresh)
            if err is None and doc:
                ok += 1
            elif err in ('HTTP 404', 'HTTP 410'):
                missing.append('{}/{} ({})'.format(kind, tok, err))
            else:
                unverified.append('{}/{} ({})'.format(kind, tok, err))
    return missing, unverified, ok


def main():
    argv = sys.argv[1:]
    refresh = '--refresh' in argv
    local_only = '--local' in argv

    categories = load_json('categories.json')
    tokens = load_json('tokens.json')
    load_json('lexicon.json')              # 顺带确认它还是合法 JSON（设备端兜底层的数据源）

    pairs = curated_tokens(tokens)
    total = sum(len(v) for v in pairs.values())
    print('Homebrew 策展清单 — {} 个 token（{}）'.format(
        total, ' + '.join('{} {}'.format(k, len(v)) for k, v in sorted(pairs.items()))))

    print('\n[structure]')
    problems = check_structure(tokens, categories)
    if problems:
        for one in problems:
            print('  - ' + one)
    else:
        print('  分类 key 与 token 全部合法（无空值、无重复）')
    bad = bool(problems)

    if not local_only:
        print('\n[upstream]')
        missing, unverified, ok = check_upstream(tokens, refresh=refresh)
        print('  仍在上游 {} / {}'.format(ok, total))
        for one in missing:
            print('  - 已从上游消失: ' + one)
        for one in unverified:
            print('  - 未能校验（网络/解析问题，不算缺失）: ' + one)
        if missing:
            bad = True

    print('\n===== 结论 =====')
    print('有问题，见上。' if bad else '策展清单可用。')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())


# ------------------------------------------------------------- classification

TOKEN_RE = re.compile(r'[a-z0-9]+')
STOP = {'a', 'an', 'the', 'and', 'or', 'for', 'of', 'to', 'with', 'in', 'on', 'from', 'your', 'that', 'is', 'it'}


def classify(desc, kind, lexicon):
    """兜底关键词聚类。返回 (category_key, score, matched[])。

    仅在包不在 tokens.json（override 层）时使用。
    权重：命中词出现在 desc 前 3 个词内记 3 分，否则 1 分。
    """
    cfg = lexicon.get(kind, {})
    th = lexicon.get('_threshold', {})
    min_score = th.get('minScore', 2)
    min_margin = th.get('minMargin', 2)

    text = (desc or '').lower()
    head = ' '.join(TOKEN_RE.findall(text)[:3])
    scores = {}
    matched = {}
    for key, words in cfg.items():
        total = 0
        hits = []
        for word in words:
            if word in text:
                total += 3 if word in head else 1
                hits.append(word)
        if total:
            scores[key] = total
            matched[key] = hits
    if not scores:
        return None, 0, []
    ranked = sorted(scores.items(), key=lambda kv: -kv[1])
    top_key, top_score = ranked[0]
    second = ranked[1][1] if len(ranked) > 1 else 0
    if top_score >= min_score and (top_score - second) >= min_margin:
        return top_key, top_score, matched[top_key]
    return None, top_score, matched[top_key]


# 主题层：关键词判不出来时，用「中心名词/主语」再查一次表。
# 为什么单独一层而不是把主题词并进关键词表：主题词在 desc 里的位置**不在前 3 个词**
# （典型是 "A C library for parsing XML" 里的 XML），并进关键词表后按权重只能拿 1 分，
# 达不到 minScore=2；而「kubernetes -> cloudnative」这种单个词本身已经足够判别。
SUBJECT_FOR_RE = re.compile(r'\bfor\s+([a-z0-9][a-z0-9 +.#/_-]{2,48})')
SUBJECT_FORM_RE = re.compile(
    r'(?:^|[^a-z0-9])((?:[a-z0-9][a-z0-9+.#_-]*\s+){0,2})([a-z0-9][a-z0-9+.#_-]*)\s+'
    r'(?:library|framework|sdk|toolkit|bindings?|implementation|port)\b')

# 形态词紧前面那个词常常是泛化词（"Audio File Library" 里的 `file`、"data toolkit" 里的 `data`），
# 拿它去查表会把包归错类（实测：`C++ Audio File Library` 被 `file` 判成 system）。
# 所以遇到泛化词就继续往左看，直到找到一个有判别力的词。
SUBJECT_GENERIC = {
    'file', 'files', 'data', 'string', 'strings', 'text', 'tool', 'tools', 'utility', 'utilities',
    'collection', 'set', 'input', 'output', 'process', 'system', 'resource', 'resources', 'client',
    'server', 'wrapper', 'module', 'things', 'stuff', 'general', 'purpose', 'fast', 'simple', 'small',
    'library', 'libraries', 'cross', 'platform', 'command', 'line', 'package', 'program', 'programs',
}


def subject_terms(desc):
    """抽候选主语/中心名词。formula 长尾是「X library for Y」，cask 长尾是「Menu bar app for Y」——
    两类形态不同，所以头部 2/3-gram、`for <...>`、`<X> library` 三处都取。
    **必须与设备端 `BrewTaxonomy.subjectTerms()` 逐行一致。**"""
    text = (desc or '').lower()
    words = TOKEN_RE.findall(text)
    terms = []
    if len(words) >= 3:
        terms.append(' '.join(words[:3]))
    if len(words) >= 2:
        terms.append(' '.join(words[:2]))
    m = SUBJECT_FOR_RE.search(text)
    if m:
        sub = TOKEN_RE.findall(m.group(1))
        terms.append(' '.join(sub[:2]))
        terms += sub[:2]
    m2 = SUBJECT_FORM_RE.search(text)
    if m2:
        before = TOKEN_RE.findall(m2.group(1) or '')
        if before:
            terms.append(' '.join(before[-2:]))
        # 形态词前的那串词从右往左看，跳过泛化词；再退回把整串按原序也试一遍
        for w in reversed(before):
            if w not in SUBJECT_GENERIC:
                terms.append(w)
                break
        terms += before
        terms.append(m2.group(2))
    out = []
    for t in terms:
        if t and t not in out:
            out.append(t)
    return out


def subject_index(lexicon):
    """把 `_subjects` 从「分类 -> 主题词」反成「主题词 -> 分类」。

    表按「分类 -> 词」写是为了人工维护（与关键词层同构、便于按类审阅），
    查询需要反查，所以在加载期建一次索引 —— 设备端 `BrewTaxonomy.buildSubjectIndex()` 同款。
    """
    idx = {}
    for kind, cats in (lexicon.get('_subjects') or {}).items():
        if kind.startswith('_'):
            continue
        table = {}
        for cat, terms in cats.items():
            for term in terms:
                table[term] = cat
        idx[kind] = table
    return idx


def form_bucket(desc, kind, lexicon):
    """形态兜底桶（对应设备端 `BrewTaxonomy.formBucketOf`）。

    与关键词层的区别：**不参与打分**，只在「策展/关键词/主题」都判不出来时生效 ——
    所以它不可能抢走已有分类（实测：把同样这些词放进关键词层会造成 9 条翻转，
    其中 `C++ client library for ClickHouse` 这类会因为 `cli` 是 `client` 的子串而被判成 terminal；
    写成兜底桶是 0 条翻转，而兜底率几乎一样：46.5% vs 46.1%）。
    """
    table = (lexicon.get('_forms') or {}).get(kind) or {}
    text = (desc or '').lower()
    for category, words in table.items():
        for word in words:
            if word in text:
                return category
    return None


def subject_match(desc, kind, index):
    """主题层：返回 (categoryKey, 命中的词) 或 (None, None)。`index` 来自 `subject_index()`。"""
    table = index.get(kind) or {}
    for term in subject_terms(desc):
        hit = table.get(term)
        if hit:
            return hit, term
    return None, None


def subject_of(desc, kind, index):
    """同 `subject_match`，只要分类（对应设备端 `BrewTaxonomy.subjectOf`）。"""
    return subject_match(desc, kind, index)[0]


