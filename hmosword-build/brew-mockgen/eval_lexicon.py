#!/usr/bin/env python3
"""分类词表实验：在现网全量上比较几种改法的兜底率，用数字决定阶段 4 怎么改。

背景（为什么要这个脚本）：把浏览集放开到目录全量之后，真机实测 formula 7,293 条里
75% 落兜底分类 `system`、cask 68% 落 `systemtool`。兜底说明里的高频结构是
`library for` / `tool for` / `framework for` / `programming language` —— 即长尾主体是
「库/框架/SDK」，而现有 8 个分类里**没有"库"这一类**。所以问题不在关键词多少，
而在分类体系本身；但"加一类"会改 UI（卡片 + chips 从 8 变 9），所以先用离线实验把
几种改法的收益量出来再决定。

口径与设备端严格一致：baseline 直接复用生成器的 `classify()`（generate.py），
override 层复用 `tokens.json` 的 `formula` / `cask` / `_discover_*`。

用法：

    # 用本地已有的两个全量包（.brewgen/ 或 --data 指定）
    python3 eval_lexicon.py --data ../../.pi/logs

    # 没有数据时自己下（走 https_proxy 环境变量）
    python3 eval_lexicon.py --fetch

输出：对比表（stdout）+ 明细 markdown（--out，默认 ./lexicon-eval.md）。
"""

import argparse
import collections
import json
import os
import re
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from generate import classify, form_bucket, load_json, subject_index, subject_match, subject_terms  # noqa: E402

API = 'https://formulae.brew.sh/api'
FALLBACK = {'formula': 'system', 'cask': 'systemtool'}

# --------------------------------------------------------------- 实验用的增量词表

# 方案 B：把「库/框架/SDK/绑定」抽成独立一类（第 9 类，key = `lib`）。
# 只放**结构性**词（它们说明"这是什么形态的东西"），不放领域词（领域词是方案 C 的事）。
LIB_WORDS = [
    'library', 'libraries', 'framework', 'frameworks', 'sdk', 'toolkit', 'bindings', 'binding',
    'c++ library', 'header-only', 'runtime library', 'client library', 'api wrapper', 'wrapper for',
    'module for', 'plugin for', 'parser for', 'implementation of', 'port of', 'language server',
]

# 方案 C：把库按**主题**归入现有分类。键是从现网兜底说明里抽出来的主语词（见 --print-subjects），
# 值必须是该 kind 已有的 categoryKey —— 不新增分类，只补"主题 -> 类"的映射。
LIB_FORM_RE = re.compile(
    r'\b(library|libraries|framework|sdk|toolkit|bindings?|wrapper|module|plugin|parser|'
    r'implementation|port|language server|client library|header-only)\b')


# ---------------------------------------------------------------------- 数据

def load_pack(data_dir, kind, fetch):
    path = os.path.join(data_dir, f'{kind}.json')
    if not os.path.exists(path):
        if not fetch:
            raise SystemExit(f'缺 {path}（用 --fetch 下，或 --data 指向已有目录）')
        os.makedirs(data_dir, exist_ok=True)
        url = f'{API}/{kind}.json'
        print(f'下载 {url} -> {path}', file=sys.stderr)
        with urllib.request.urlopen(url, timeout=600) as resp, open(path, 'wb') as fp:
            fp.write(resp.read())
    with open(path, 'r', encoding='utf-8') as fp:
        return json.load(fp)


def entries_of(docs, kind):
    key = 'name' if kind == 'formula' else 'token'
    return [(d.get(key, ''), d.get('desc') or '') for d in docs]


def curated_of(tokens, kind):
    out = {}
    for group in ('formula', 'cask'):
        if group != kind:
            continue
        for cat, arr in (tokens.get(group) or {}).items():
            if cat.startswith('_'):
                continue
            for tok in arr:
                out[tok] = cat
    for cat, arr in (tokens.get(f'_discover_{kind}') or {}).items():
        for tok in arr:
            out[tok] = cat
    return out


# ---------------------------------------------------------------------- 场景

def run_scenario(rows, kind, lexicon, curated, subjects, with_token=False, token_first=False,
                 with_lib=False, with_lib_fallback=False, with_subject=False, with_form=False):
    """返回 (分布 Counter, 明细 Counter)；口径与设备端一致，只在关键处加实验开关。"""
    cfg = dict(lexicon.get(kind) or {})
    if with_lib:
        cfg = dict(cfg)
        cfg['lib'] = LIB_WORDS + cfg.get('lib', [])
    lex = dict(lexicon)
    lex[kind] = cfg

    dist = collections.Counter()
    how = collections.Counter()
    matched_terms = collections.Counter()
    for token, desc in rows:
        if token in curated:
            dist[curated[token]] += 1
            how['curated'] += 1
            continue
        text = desc
        if with_token:
            text = f'{token} {desc}' if token_first else f'{desc} {token}'
        cat, score, _ = classify(text, kind, lex)
        if cat is not None:
            dist[cat] += 1
            how['keyword'] += 1
            continue
        # 关键词没命中：下面这几个开关决定兜底怎么走，顺序刻意写成「主题 -> 库形态 -> 兜底」，
        # 否则库形态会把本来能被主题归类的条目全吃掉（S5 初版就踩了这个）。
        if with_subject:
            hit, term = subject_match(desc, kind, subjects)
            if hit:
                dist[hit] += 1
                how['subject'] += 1
                matched_terms[f'{term} -> {hit}'] += 1
                continue
        if with_form:
            cat3 = form_bucket(desc, kind, lexicon)
            if cat3:
                dist[cat3] += 1
                how['form'] += 1
                continue
        if (with_lib or with_lib_fallback) and LIB_FORM_RE.search(desc.lower()):
            dist['lib'] += 1
            how['lib-form'] += 1
            continue
        dist[FALLBACK[kind]] += 1
        how['fallback'] += 1
        if not desc:
            how['fallback_nodesc'] += 1
    return dist, how, matched_terms


SCENARIOS = [
    ('S0 现状（overrides + 关键词 + 兜底）', {}),
    ('S1a 匹配串前置 token', {'with_token': True, 'token_first': True}),
    ('S1b 匹配串追加 token', {'with_token': True}),
    ('S2 加第 9 类 lib（只看形态词）', {'with_lib': True}),
    ('S3 不加类：主题归入现有 8 类', {'with_subject': True}),
    ('S4 S1b + S2', {'with_token': True, 'with_lib': True}),
    ('S5 S1b + S3 + S2（主题优先，库形态兜最后）', {'with_token': True, 'with_lib': True, 'with_subject': True}),
    ('**S8 生产方案**：S3 + `_forms` 形态桶（lib，不进打分）', {'with_subject': True, 'with_form': True}),
]


def pct(num, denom):
    return 100.0 * num / denom if denom else 0.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--data', default=os.path.join(HERE, '.brewgen'), help='放着 formula.json / cask.json 的目录')
    ap.add_argument('--fetch', action='store_true', help='缺文件时自动下载（走 https_proxy）')
    ap.add_argument('--out', default=os.path.join(HERE, 'lexicon-eval.md'))
    ap.add_argument('--print-subjects', type=int, default=0, help='打印兜底说明里出现最多的前 N 个主语词')
    ap.add_argument('--print-residual', type=int, default=0,
                    help='打印「加了主题层之后仍然兜底」的条目里最高频的中心词（用于下一轮扩表）')
    args = ap.parse_args()

    lexicon = load_json('lexicon.json')
    subjects = subject_index(lexicon)
    tokens = load_json('tokens.json')
    lines = ['# 分类词表实验（现网全量）', '']

    for kind in ('formula', 'cask'):
        docs = load_pack(args.data, kind, args.fetch)
        rows = entries_of(docs, kind)
        no_desc = sum(1 for _, d in rows if not d)
        curated = curated_of(tokens, kind)
        lines += [f'## {kind}：{len(rows)} 条'
                  + (f'（其中 {no_desc} 条 desc 为空 —— 永远无法分类，是硬上限）' if no_desc else ''), '']
        if args.print_subjects:
            cnt = collections.Counter()
            for token, desc in rows:
                cat, _, _ = classify(desc, kind, lexicon)
                if cat is None and desc:
                    for term in subject_terms(desc):
                        cnt[term] += 1
            lines += ['兜底说明里的高频主语/中心名词（前 %d）：' % args.print_subjects, '']
            lines += ['- ' + ', '.join(f'`{t}`({c})' for t, c in cnt.most_common(args.print_subjects)), '']

        # 两个分母都报：全部条目（= UI 上真实上屏口径）、以及有 desc 的子集（cask 有 2,645 条 null）
        if args.print_residual:
            cnt = collections.Counter()
            for token, desc in rows:
                if token in curated or not desc:
                    continue
                if classify(desc, kind, lexicon)[0] is not None:
                    continue
                if subject_match(desc, kind, subjects)[0]:
                    continue
                for term in subject_terms(desc):
                    cnt[term] += 1
            lines += ['**加了主题层后仍然兜底**的条目里，最高频的中心词（前 %d）：' % args.print_residual, '']
            lines += ['- ' + ', '.join(f'`{t}`({c})' for t, c in cnt.most_common(args.print_residual)), '']

        lines += ['| 方案 | 兜底(全部) | 兜底率(全部) | 兜底率(有 desc) | 关键词 | 主题 | 形态桶 | 库(试) | 策展 |',
                  '|---|---|---|---|---|---|---|---|---|']
        for name, kwargs in SCENARIOS:
            dist, how, _ = run_scenario(rows, kind, lexicon, curated, subjects, **kwargs)
            fb = how['fallback']
            fb_with_desc = fb - how['fallback_nodesc']
            lines.append('| %s | %d | **%.1f%%** | %.1f%% | %d | %d | %d | %d | %d |'
                         % (name, fb, pct(fb, len(rows)), pct(fb_with_desc, len(rows) - no_desc),
                            how['keyword'], how['subject'], how['form'], how['lib-form'], how['curated']))
        lines.append('')
        dist, how, matched = run_scenario(rows, kind, lexicon, curated, subjects, **SCENARIOS[-1][1])
        lines += ['S5 的分类分布：' + json.dumps({k: v for k, v in dist.most_common()}, ensure_ascii=False), '']
        lines += ['S5 里主题映射实际命中的词（前 20）：'
                  + ', '.join(f'`{t}`({c})' for t, c in matched.most_common(20)), '']

    report = '\n'.join(lines)
    print(report)
    with open(args.out, 'w', encoding='utf-8') as fp:
        fp.write(report + '\n')
    print(f'\n明细已写入 {args.out}', file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main())
