#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Homebrew 应用市场 · mock 数据生成器

从 formulae.brew.sh 拉取精选包的真实数据，转换成 App 需要的 JSON 形状。

用法:
    python3 generate.py              # 增量（复用 .brewgen/cache 缓存）
    python3 generate.py --refresh    # 强制重新拉取
    python3 generate.py --check      # 只校验 token 是否存在，不产出

产出（common/src/main/resources/rawfile/mockdata/）:
    brew-discover-page.json       Discover 六张榜的**回落快照**（成员/数字现由设备端现算）
    brew-local-formulae.json      本机已安装 formulae
    brew-local-casks.json         本机已安装 casks
    brew-local-outdated.json      本机可升级的包

不再产出：page / details / banner（C 档删除，首页成员由「目录 + 词表」现算、详情由现网单条渲染）
与本地 overview / taps / services（无 UI 调用点，对应 TriggerEnums 成员已一并删除）。

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
OUT_DIR = os.path.join(ROOT, 'common', 'src', 'main', 'resources', 'rawfile', 'mockdata')
CACHE_DIR = os.path.join(ROOT, '.brewgen', 'cache')
API = 'https://formulae.brew.sh/api'
BASE_ANALYTICS = API + '/analytics'
UA = {'User-Agent': 'brew-mockgen/1.0'}

# id 不再由这里分配：用 `token_id()`（FNV-1a，与设备端 `BrewBrowseBuilder.tokenId` 同值）。
# 分类卡的 `styleType` 节奏也不再在这里定义 —— 它是设备端 `BrewBrowseBuilder.STYLE_CYCLE`。

_CTX = ssl.create_default_context()


# ---------------------------------------------------------------- io helpers

def token_id(token):
    """token -> 稳定 id（FNV-1a 32 位 + 抹掉符号位）。

    **必须与 ArkTS 的 `BrewBrowseBuilder.tokenId()` 逐位一致** —— 两边算出的 id 不一致时，
    榜单（生成器产出）点进去的详情页（设备端算 id）会错位。改这里必须同步改那边。
    """
    h = 0x811c9dc5
    for ch in token:
        h ^= ord(ch)
        h = (h * 0x01000193) & 0xFFFFFFFF
    return (h % 2000000000) + 1


def load_json(name):
    with open(os.path.join(HERE, name), 'r', encoding='utf-8') as fp:
        return json.load(fp)


def cache_path(kind, token):
    safe = token.replace('/', '_')
    return os.path.join(CACHE_DIR, kind, safe + '.json')


def fetch(kind, token, refresh=False):
    """拉取单个 formula/cask。返回 (doc, error)。"""
    path = cache_path(kind, token)
    if os.path.exists(path) and not refresh:
        with open(path, 'r', encoding='utf-8') as fp:
            return json.load(fp), None
    seg = 'formula' if kind == 'formula' else 'cask'
    url = '{}/{}/{}.json'.format(API, seg, token)
    req = urllib.request.Request(url, headers={'User-Agent': 'brew-mockgen/1.0'})
    try:
        with urllib.request.urlopen(req, timeout=30, context=_CTX) as resp:
            raw = resp.read().decode('utf-8')
    except urllib.error.HTTPError as exc:
        return None, 'HTTP {}'.format(exc.code)
    except Exception as exc:                                  # noqa: BLE001
        return None, str(exc)
    try:
        doc = json.loads(raw)
    except ValueError as exc:
        return None, 'bad json: {}'.format(exc)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as fp:
        json.dump(doc, fp, ensure_ascii=False)
    time.sleep(0.05)                                          # 轻量节流
    return doc, None


def dump(name, payload, envelope=False):
    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, name)
    if envelope:
        payload = {'success': True, 'code': '0000', 'msg': 'success', 'body': payload}
    with open(path, 'w', encoding='utf-8') as fp:
        json.dump(payload, fp, ensure_ascii=False, indent=2)
        fp.write('\n')
    size = os.path.getsize(path)
    print('  wrote {:<28} {:>8.1f} KB'.format(name, size / 1024.0))


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


# ---------------------------------------------------------------- transform

# 为什么不再产出 brew-{formula,cask}-page.json（浏览页数据）
#
# 那两个文件就是"分类 + 成员"的一次冻结快照。C 档之后两样东西设备端都能自己算：
#   成员 = 目录（聚合端点）里按 30d 安装量降序的前 100；
#   分类 = `BrewTaxonomy.ets`（tokens.json 策展覆盖 → lexicon.json 关键词 → 兜底）。
# 于是"能浏览的包"不再被那 240 个内置条目锁死。设备端"拿不到目录"时返回空页而不是回落快照
# （真无网时确实无内容可渲染），所以这份产物没有存在意义了。
#
# 保留 `classify()` 与 `_discover_*` 注释：前者是分类口径的**参考实现**
# （设备端 `BrewTaxonomy.classify` 必须与它一致），后者记录了当初的选取过程。
#
# 为什么不再产出 brew-{formula,cask}-details.json 与 brew-*-banner.json
#
# 详情页需要快照提供的只有三样官方 API 里没有的东西：本地 id、categoryKey、分类内名次 ——
# 而这三样 page 的条目里本来就有（原来详情就是从同一个 item 派生的），其余字段 100% 由现网单条覆盖；
# 实测确认详情页与归一化器对 contentType / recommendList 零引用。
# banner 更早就没有 UI 调用点（两个首页的 bannerHeight 被固定为 0）。
# 所以这两类产物连同构件代码（service_run / artifacts / zap 路径数 / installCommand 等）一并删除 ——
# 删掉的是 443 KB 数据与一条死路径。要恢复的话，git log 里有完整的 build_detail。
#
# ------------------------------------------------------------------- builders

# --------------------------------------------------------------------- discover

DISCOVER_TOP_N = 10
DISCOVER_CACHE = os.path.join(ROOT, '.brewgen', 'discover')

# 榜单定义：(boardKey, 在 check_algo.build() 结果里的键)。顺序即展示顺序。
DISCOVER_BOARDS = (('trending', 'rising'), ('alltime', 'alltime'), ('fresh', 'fresh'))

# 「单 App 大图卡」的选取规则：从哪些榜上各取前几名。
#
# 这是**编辑口径**，所以写在生成器里落进数据，而不是让 UI 去猜 —— 与三张榜本身同理：
# UI 只做渲染，换规则只改这里。需求方指定：趋势榜取 2 个 Formulae + 1 个 Casks，
# 新星榜取 1 个 Formulae + 1 个 Casks（共 5 张）。新星榜本来就没几条，所以取 1 个。
FEATURED_RULE = (
    ('formula', 'trending', 2),
    ('cask', 'trending', 1),
    ('formula', 'fresh', 1),
    ('cask', 'fresh', 1),
)


def fetch_analytics(local_name, url, refresh=False):
    """拉聚合端点并缓存。

    与 fetch() 的每包端点不同：这是**全量宇宙**的安装量统计，趋势榜必须用它。
    实测拿现有 100 个精选包排趋势榜，92/100 都能入选而榜首全是 vel≈1 的稳态大包 ——
    「精选热门包」这个切片天然没有趋势信号（详见 docs/brew-discover-algo.md §7.1）。

    `local_name` / `url` 都取自 check_algo.SOURCES（那里是端点契约的唯一出处），
    不在这里重新拼 URL —— 之前手拼漏了 `.json` 后缀直接吃到 404。
    """
    path = os.path.join(DISCOVER_CACHE, local_name)
    if os.path.exists(path) and not refresh:
        with open(path, 'r', encoding='utf-8') as fp:
            return json.load(fp)
    os.makedirs(DISCOVER_CACHE, exist_ok=True)
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=180, context=_CTX) as resp:
        doc = json.loads(resp.read().decode('utf-8'))
    with open(path, 'w', encoding='utf-8') as fp:
        json.dump(doc, fp, ensure_ascii=False)
    time.sleep(0.2)
    return doc


def build_discover(refresh=False, top_n=DISCOVER_TOP_N):
    """算出 Formulae / Casks 各三张榜，产出 Discover 数据（**只当回落用**）。

    算法本身不在这里 —— 复用 check_algo（docs/brew-discover-algo.md 的可执行形式），
    避免「文档一套、生成器一套」。改口径只改 check_algo。

    设备端会自己用聚合端点现算同一份榜（`BrewCatalogAlgo.ets`），所以这份快照现在只是
    「目录拿不到时的回落」：`id` 用 `token_id()` 与设备端算同一个值，`name`/`desc`/`categoryKey`
    留空 —— 它们在设备端 hydrate 时会被现网值覆盖，而生成器这边为了它们去拉每包端点不值得。
    """
    import check_algo as algo

    exc_path = os.path.join(HERE, 'family_exceptions.json')
    exceptions = load_json('family_exceptions.json') if os.path.exists(exc_path) else {}

    boards, meta = [], {}
    featured = []
    for kind in ('formula', 'cask'):
        files = {win: algo.SOURCES[kind][win] for win in ('30d', '365d')}
        a30, m30 = algo.parse_counts(fetch_analytics(files['30d'][0], files['30d'][1], refresh))
        a365, _ = algo.parse_counts(fetch_analytics(files['365d'][0], files['365d'][1], refresh))
        res = algo.build(kind, a30, a365, exceptions)

        rows_by_board = {}
        for board_key, rows_key in DISCOVER_BOARDS:
            entries = []
            for rank, row in enumerate(res[rows_key][:top_n], start=1):
                rows_by_board[board_key] = res[rows_key][:top_n]
                entries.append({
                    'rank': rank,
                    'id': token_id(row['token']),
                    'token': row['token'],
                    # 以下三项留空：设备端 hydrate 会用现网 doc 覆盖（desc/name 来自单条，
                    # categoryKey 还要靠 desc 算分类）。留空比填错好 —— 填错会被当成"数据已经对了"
                    'desc': '',
                    'name': row['token'],
                    'categoryKey': '',
                    'installs30d': row['vol30d'],
                    'installs365d': row['vol365d'],
                    'priorMonthly': round(row['prior'], 1),
                    'velocity': round(row['velocity'], 2) if row['velocity'] else 0,
                    # score 只在趋势榜算过；三张榜引用的是同一批 dict 对象，直接透传会让
                    # 「历史榜」里那些恰好也在趋势榜的条目带上一个无意义的 score。
                    'score': round(row.get('score', 0), 2) if board_key == 'trending' else 0.0,
                })
            boards.append({
                'id': len(boards) + 1,
                'kind': kind,
                'boardKey': board_key,
                'sequence': len(boards) + 1,
                'entryCount': len(entries),
                'entries': entries,
            })
        # 单 App 大图卡：按 FEATURED_RULE 从各榜取前几名，补上来源榜别（kind / boardKey）
        for f_kind, f_board, f_count in FEATURED_RULE:
            if f_kind != kind:
                continue
            for idx, row in enumerate(rows_by_board.get(f_board, [])[:f_count], start=1):
                token = row['token']
                featured.append({
                    'rank': idx,
                    'id': token_id(token),
                    'token': token,
                    'desc': '',
                    'name': token,
                    'categoryKey': '',
                    'kind': kind,
                    'boardKey': f_board,
                    'installs30d': row['vol30d'],
                    'installs365d': row['vol365d'],
                    'priorMonthly': round(row['prior'], 1),
                    'velocity': round(row['velocity'], 2) if row['velocity'] else 0,
                    'score': round(row.get('score', 0), 2) if f_board == 'trending' else 0.0,
                })

        meta[kind] = {
            'windowStart': m30.get('window_start') or '',
            'windowEnd': m30.get('window_end') or '',
            'totalItems': m30.get('total_items') or 0,
            'totalCount': m30.get('total_count') or 0,
            'rawTokens': res['raw_tokens'],
            'families': res['families'],
            'candidates': len(res['rising']),
            'thresholds': algo.CONFIG[kind],
        }

    # 用数据窗口的结束日而不是墙钟时间：这个文件是要提交进仓库的产物，
    # 带时间戳会让「同输入重复生成字节级一致」这条性质失效（我们靠它判断
    # 重产出有没有意外改到别的文件）。真要 build 时刻，git 里有。
    payload = {
        'snapshotDate': meta['formula']['windowEnd'],
        'topN': top_n,
        'meta': meta,
        'boards': boards,
        'featured': featured,
    }
    return payload


# ------------------------------------------------------------------------ local

# 本机状态 mock 的固定参数（纯 Mock，未来由 brew 命令输出替换）
LOCAL_INSTALLED_FORMULAE = 42
LOCAL_INSTALLED_CASKS = 18
LOCAL_OUTDATED = 8
LOCAL_INSTALL_BASE_TS = 1726000000     # 固定基准时间，保证可重现


def installed_entry(detail, kind, index, outdated=False):
    """把一个包详情转成“已安装”条目。"""
    latest = detail.get('stableVersion') or ''
    version = latest
    if outdated:
        # 构造一个可重现的“旧版本”：从最后一段往前找可减的位
        parts = re.split(r'[.\-]', latest or '1.0')
        version = ''
        for pos in range(len(parts) - 1, -1, -1):
            if parts[pos].isdigit() and int(parts[pos]) > 0:
                parts[pos] = str(int(parts[pos]) - 1)
                version = '.'.join(parts)
                break
        if not version:
            version = (latest or '1.0') + '-old'
        if version == latest:
            version = (latest or '1.0') + '-old'
    return {
        'name': detail['token'],
        'fullName': detail['token'],
        'version': version,
        'latestVersion': latest,
        'installedOnRequest': index % 3 != 2,
        'installedAsDependency': index % 3 == 2,
        'pouredFromBottle': True,
        'installedAt': LOCAL_INSTALL_BASE_TS - index * 86400 * 3,
        'autoUpdates': bool(detail.get('autoUpdates')),
        'outdated': outdated,
        'kind': kind,
    }


def curated_items(kind, refresh=False):
    """按 `tokens.json` 的**策展顺序**取出包，再拉每包文档补齐本机 mock 需要的几个字段。

    为什么不再读 page 文件：page 产物在 C 档已删除（浏览改由设备端用目录 + 词表现算）。
    本机 mock 需要的只有 token / 版本号 / autoUpdates，所以只要 tokens.json 的顺序 + 每包文档，
    不必先造一份 page。拉取走 `fetch()` 的磁盘缓存，重复运行不会重复联网。
    """
    tokens = load_json('tokens.json')
    items = []
    for _key, tokens_in_cat in tokens[kind].items():
        for token in tokens_in_cat:
            doc, err = fetch(kind, token, refresh=refresh)
            if err or not doc:
                continue
            version = ((doc.get('versions') or {}).get('stable') if kind == 'formula' else doc.get('version')) or ''
            items.append({
                'token': token,
                'stableVersion': version,
                'autoUpdates': bool(doc.get('auto_updates')),
                'deprecated': bool(doc.get('deprecated')),
                'disabled': bool(doc.get('disabled')),
            })
    return items


def build_local(refresh=False):
    """从策展清单 + 每包文档派生本机状态 mock（可重现，不依赖随机数）。"""
    fdet = curated_items('formula', refresh)
    cdet = curated_items('cask', refresh)

    # 跳过 deprecated/disabled，本机装的多半是正常包
    fdet = [x for x in fdet if not x['deprecated'] and not x['disabled']]
    cdet = [x for x in cdet if not x['deprecated'] and not x['disabled']]

    req_f = min(LOCAL_INSTALLED_FORMULAE, len(fdet))
    req_c = min(LOCAL_INSTALLED_CASKS, len(cdet))
    installed_f = [installed_entry(fdet[i], 'formula', i) for i in range(req_f)]
    installed_c = [installed_entry(cdet[i], 'cask', i) for i in range(req_c)]

    # 可升级：从已安装里挑固定的几个
    outdated = []
    for i in range(0, req_f, max(1, req_f // (LOCAL_OUTDATED // 2 + 1))):
        if len(outdated) >= LOCAL_OUTDATED // 2:
            break
        outdated.append(installed_entry(fdet[i], 'formula', i, outdated=True))
    for i in range(0, req_c, max(1, req_c // (LOCAL_OUTDATED // 2 + 1))):
        if len(outdated) >= LOCAL_OUTDATED:
            break
        outdated.append(installed_entry(cdet[i], 'cask', i, outdated=True))

    dump('brew-local-formulae.json', installed_f, envelope=True)
    dump('brew-local-casks.json', installed_c, envelope=True)
    dump('brew-local-outdated.json', outdated, envelope=True)
    print('  本机 mock: formulae={} casks={} outdated={}'.format(
        len(installed_f), len(installed_c), len(outdated)))


# ------------------------------------------------------------------------ main

def main():
    argv = sys.argv[1:]
    refresh = '--refresh' in argv
    check_only = '--check' in argv

    categories = load_json('categories.json')
    tokens = load_json('tokens.json')
    lexicon = load_json('lexicon.json')
    token_map = {k: v for k, v in tokens.items() if not k.startswith('_')}

    total = sum(len(v) for kind in token_map.values() for v in kind.values())
    print('Homebrew mock generator — {} 个精选包'.format(total))

    report_all = {}
    if not check_only:
        print('\n[discover]')
        discover = build_discover(refresh=refresh)
        dump('brew-discover-page.json', discover, envelope=True)
        for kind, meta in discover['meta'].items():
            print('  {} 窗口 {} ~ {}  候选 {} -> 每榜 Top{}'.format(
                kind, meta['windowStart'], meta['windowEnd'], meta['candidates'],
                discover['topN']))

        print('\n[local]')
        build_local(refresh=refresh)

    print('\n===== 报告 =====')
    bad = False
    for kind, rep in report_all.items():
        if rep['missing']:
            bad = True
            print('[{}] 拉取失败 {} 条:'.format(kind, len(rep['missing'])))
            for one in rep['missing']:
                print('   - ' + one)
        if rep['fallback']:
            print('[{}] 兜底分类 {} 条:'.format(kind, len(rep['fallback'])))
            for one in rep['fallback']:
                print('   - ' + one)
    if not bad:
        print('全部 token 拉取成功。')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
