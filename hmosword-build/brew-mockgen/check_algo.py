#!/usr/bin/env python3
"""Discover 推荐算法：参考实现 + 不变量自检。

本文档对应的可执行形式：docs/brew-discover-algo.md。
生成器（generate.py）与自检共用这里的口径，避免"文档一套、代码一套"。

用法：

    # 直接拉现网数据并自检（需要联网）
    python3 check_algo.py --fetch --data .brewgen/analytics --print-top 5

    # 用已有快照自检
    python3 check_algo.py --data .brewgen/analytics

退出码：0 = 全部不变量通过；1 = 有不变量失败或数据缺失。

需要的文件（--fetch 会自己下）：
    formula-on-request-30d.json   formula-on-request-365d.json
    cask-install-30d.json         cask-install-365d.json
"""

import argparse
import bisect
import json
import math
import os
import sys
import urllib.request

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
BASE_URL = 'https://formulae.brew.sh/api/analytics'

# 阈值：见文档 §4。这里是「本次标定值」，自检会把它们与快照实际分位数对比。
CONFIG = {
    'formula': {
        'vol_floor': 500,   # ≈ 30d 分布 p89
        'min_prior': 50,    # ≈ prior 分布 p55
        'new_floor': 300,
        'vol_pct': 0.89,
        'prior_pct': 0.55,
    },
    'cask': {
        'vol_floor': 200,   # ≈ 30d 分布 p89
        'min_prior': 20,    # ≈ prior 分布 p55
        'new_floor': 300,
        'vol_pct': 0.89,
        'prior_pct': 0.55,
    },
}
THRESHOLD_TOLERANCE = 0.20   # 门槛与分位数偏差 > 20% 视为漂移，需要重新标定

SOURCES = {
    'formula': {
        '30d': ('formula-on-request-30d.json',
                f'{BASE_URL}/install-on-request/homebrew-core/30d.json'),
        '365d': ('formula-on-request-365d.json',
                 f'{BASE_URL}/install-on-request/homebrew-core/365d.json'),
    },
    'cask': {
        '30d': ('cask-install-30d.json',
                f'{BASE_URL}/cask-install/homebrew-cask/30d.json'),
        '365d': ('cask-install-365d.json',
                 f'{BASE_URL}/cask-install/homebrew-cask/365d.json'),
    },
}


def fetch(data_dir):
    os.makedirs(data_dir, exist_ok=True)
    for kind in SOURCES:
        for win, (name, url) in SOURCES[kind].items():
            path = os.path.join(data_dir, name)
            if os.path.exists(path):
                print(f'  已存在，跳过：{name}')
                continue
            print(f'  下载 {name} …')
            with urllib.request.urlopen(url, timeout=300) as resp:
                blob = resp.read()
            with open(path, 'wb') as fp:
                fp.write(blob)
            print(f'    {len(blob):,} bytes')


def parse_counts(payload):
    """把 analytics JSON 摊成 {token: 安装量}。

    三个坑（文档 §1.3）：条目按 token 分组、一个 token 可有多条、count 带千分位逗号。
    """
    key = 'formulae' if 'formulae' in payload else 'casks'
    out = {}
    multi = 0
    for token, entries in payload[key].items():
        if len(entries) > 1:
            multi += 1
        out[token] = sum(int(e['count'].replace(',', '')) for e in entries)
    return out, {
        'category': payload.get('category'),
        'total_items': payload.get('total_items'),
        'total_count': payload.get('total_count'),
        'window_start': payload.get('start_date'),
        'window_end': payload.get('end_date'),
        'tokens': len(out),
        'tokens_with_multiple_entries': multi,
    }


def family_of(token, exceptions):
    if token in exceptions:
        return exceptions[token]
    return token.split('@')[0]


def percentiles(values, pcts):
    ordered = sorted(values)
    if not ordered:
        return {p: 0 for p in pcts}
    out = {}
    for p in pcts:
        idx = min(len(ordered) - 1, int(len(ordered) * p))
        out[p] = ordered[idx]
    return out


def build(kind, a30, a365, exceptions):
    """算出三张榜 + 本次快照的实际分位数。

    record 不带 rank：`rank` 是输出契约（文档 §6）里的字段，由生成器落盘时按榜补。
    """ 
    cfg = CONFIG[kind]
    shared = set(a30) & set(a365)

    # family 去重：同 family 只留 vol 最大的 token（文档 §3.1）
    keep = {}
    for token in shared:
        fam = family_of(token, exceptions)
        if fam not in keep or a30[token] > a30[keep[fam]]:
            keep[fam] = token

    records = {}
    for token in keep.values():
        prior = (a365[token] - a30[token]) / 11.0
        rec = {'token': token, 'family': family_of(token, exceptions),
               'vol30d': a30[token], 'vol365d': a365[token], 'prior': prior}
        rec['velocity'] = (a30[token] / prior) if prior > 0 else None
        records[token] = rec

    rising = [r for r in records.values()
              if r['vol30d'] >= cfg['vol_floor'] and r['prior'] >= cfg['min_prior']]
    for r in rising:
        r['score'] = math.log1p(r['velocity']) * math.log1p(r['vol30d'])
    rising.sort(key=lambda r: -r['score'])

    alltime = sorted(records.values(), key=lambda r: -r['vol365d'])

    fresh = sorted([r for r in records.values()
                    if r['vol30d'] >= cfg['new_floor'] and r['prior'] < cfg['min_prior']],
                   key=lambda r: -r['vol30d'])

    actual = percentiles([r['vol30d'] for r in records.values()], [cfg['vol_pct']])
    actual_prior = percentiles([r['prior'] for r in records.values() if r['prior'] > 0],
                               [cfg['prior_pct']])
    return {
        'kind': kind, 'raw_tokens': len(shared), 'families': len(records),
        'rising': rising, 'alltime': alltime, 'fresh': fresh,
        'actual_vol_p': actual[cfg['vol_pct']],
        'actual_prior_p': actual_prior[cfg['prior_pct']],
    }


def check(results, a30, a365):
    """文档 §7.1 的六条不变量。返回 (通过数, 失败列表)。"""
    passed, failures = 0, []

    def ok(cond, label, detail=''):
        nonlocal passed
        if cond:
            passed += 1
            print(f'  [ok]   {label}' + (f'  {detail}' if detail else ''))
        else:
            failures.append(f'{label}  {detail}')
            print(f'  [FAIL] {label}  {detail}')

    print('\n不变量自检')
    ok(set(a30) <= set(a365), '1. 30d 的 token 集合 ⊆ 365d',
       f'(30d {len(a30):,} ⊂ 365d {len(a365):,}，缺失 {len(set(a30) - set(a365))})')

    cfg = CONFIG[results['kind']]
    bad_prior = [r['token'] for r in results['rising'] if not r['prior'] > 0]
    ok(not bad_prior, '2. 候选集 prior 全部 > 0（未使用 max(1,·) 掩盖）',
       f'(候选 {len(results["rising"]):,})')

    dv = abs(results['actual_vol_p'] - cfg['vol_floor']) / max(1.0, cfg['vol_floor'])
    dp = abs(results['actual_prior_p'] - cfg['min_prior']) / max(1.0, cfg['min_prior'])
    ok(dv <= THRESHOLD_TOLERANCE and dp <= THRESHOLD_TOLERANCE,
       '3. 门槛与快照分位数偏差 ≤ 20%（防止基数漂移后门槛失效）',
       f'(vol_floor {cfg["vol_floor"]} vs p{int(cfg["vol_pct"]*100)}={results["actual_vol_p"]:,} '
       f'偏差 {dv:.1%}；min_prior {cfg["min_prior"]} vs p{int(cfg["prior_pct"]*100)}='
       f'{results["actual_prior_p"]:.1f} 偏差 {dp:.1%})')

    dup = None
    for name in ('rising', 'alltime', 'fresh'):
        fams = [r['family'] for r in results[name]]
        if len(fams) != len(set(fams)):
            dup = name
    ok(dup is None, '4. 三张榜均无同 family 重复', '' if dup is None else f'({dup} 有重复)')

    low = [r['token'] for r in results['rising'] if r['vol30d'] < cfg['vol_floor']]
    ok(not low, '5. 趋势榜无 vol < VOL_FLOOR 的条目', f'(VOL_FLOOR={cfg["vol_floor"]})')

    scores = [r['score'] for r in results['rising']]
    ok(all(scores[i] >= scores[i + 1] for i in range(len(scores) - 1)),
       '6. 趋势榜 score 单调不增', f'(n={len(scores):,})')

    return passed, failures


def show(results, top_n):
    print(f"\n{results['kind'].upper()}  原始 token {results['raw_tokens']:,} "
          f"-> family {results['families']:,}  "
          f"趋势候选 {len(results['rising']):,}  新星 {len(results['fresh']):,}")
    # 名次在这里现算：三张榜引用的是同一批 record 对象，把 rank 写回对象会让
    # 「历史榜」的条目显示成它在趋势榜里的名次
    for label, rows, extra in (
            ('趋势榜 / 今日热门', results['rising'], lambda r: f"vel={r['velocity']:.2f}"),
            ('历史榜 / 历史最佳', results['alltime'], lambda r: f"365d={r['vol365d']:,}"),
            ('新星榜 / 新上架与上升', results['fresh'], lambda r: f"prior={r['prior']:.1f}")):
        print(f'  {label}：')
        for i, r in enumerate(rows[:top_n], 1):
            print(f"    {i:>2}. {r['token']:<26} "
                  f"30d={r['vol30d']:>8,}  {extra(r)}")


def main():
    ap = argparse.ArgumentParser(description='Discover 推荐算法自检')
    ap.add_argument('--data', default=os.path.join(REPO_ROOT, '.brewgen', 'analytics'),
                    help='快照目录')
    ap.add_argument('--fetch', action='store_true', help='先从现网下载缺失的快照')
    ap.add_argument('--print-top', type=int, default=0, help='打印各榜前 N 条')
    args = ap.parse_args()

    if args.fetch:
        print(f'拉取现网数据到 {args.data}')
        fetch(args.data)

    exc_path = os.path.join(os.path.dirname(__file__), 'family_exceptions.json')
    exceptions = json.load(open(exc_path, encoding='utf-8')) if os.path.exists(exc_path) else {}

    all_failures = []
    for kind in ('formula', 'cask'):
        paths = {}
        for win, (name, _) in SOURCES[kind].items():
            p = os.path.join(args.data, name)
            if not os.path.exists(p):
                print(f'缺少 {p}\n先跑一次：python3 check_algo.py --fetch --data {args.data}')
                return 1
            paths[win] = p
        a30, meta30 = parse_counts(json.load(open(paths['30d'], encoding='utf-8')))
        a365, _ = parse_counts(json.load(open(paths['365d'], encoding='utf-8')))
        print(f"\n=== {kind.upper()} ===")
        print(f"  窗口 {meta30['window_start']} ~ {meta30['window_end']}  "
              f"category={meta30['category']}  total_count={meta30['total_count']:,}  "
              f"一个 token 多条记录的有 {meta30['tokens_with_multiple_entries']:,} 个")
        results = build(kind, a30, a365, exceptions)
        if args.print_top:
            show(results, args.print_top)
        _, failures = check(results, a30, a365)
        all_failures += [f'{kind}: {f}' for f in failures]

    print('\n' + '=' * 60)
    if all_failures:
        print(f'FAILED（{len(all_failures)} 条）')
        for f in all_failures:
            print(f'  - {f}')
        return 1
    print('PASSED：全部不变量通过')
    return 0


if __name__ == '__main__':
    sys.exit(main())
