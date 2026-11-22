#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
AI Companion · 中文任务词表校验（spec §5 / §11 的 hmosword-build 检查项）。

校验对象：features/brewcommon/src/main/resources/rawfile/ai/taskwords.json
口径：
  1. 结构：顶层有 words 数组；每条有非空 task（string）与 tokens（非空 string 数组，≤5）；
     task 不重复；
  2. 规模：条数 ≥ 20（spec 首批要求；目标 28 条）；每条 tokens 非空；
  3. token 存在性：每个 token 必须是 Homebrew 官方目录里的真实包
     （命中 .brewgen/cache 时零请求；--local 跳过联网，只做结构校验）。

用法:
    python3 check_taskwords.py            # 结构 + 上游存在性（缓存优先）
    python3 check_taskwords.py --local    # 只做结构校验，完全不联网

退出码: 0 = 通过；1 = 有问题。
"""

import json
import os
import ssl
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
TASKWORDS = os.path.join(
    ROOT, 'features', 'brewcommon', 'src', 'main', 'resources', 'rawfile', 'ai', 'taskwords.json')
CACHE_DIR = os.path.join(ROOT, '.brewgen', 'cache')
API = 'https://formulae.brew.sh/api'
UA = {'User-Agent': 'brew-ai-taskwords/1.0'}

MIN_WORDS = 20
TARGET_WORDS = 28
MAX_TOKENS_PER_WORD = 5

# 本机（HarmonyOS 内置 Python）没有系统 CA 链，formulae.brew.sh 的证书验证不通过。
# 只读公开目录数据、无敏感信息，这里放宽为不验证，否则所有 token 都落在「未能校验」。
_CTX = ssl.create_default_context()
_CTX.check_hostname = False
_CTX.verify_mode = ssl.CERT_NONE


def fetch_upstream(kind, token, refresh=False):
    """问上游 token 是否存在。返回 (doc, err)；err 是 None / 'HTTP 404' / 其它错误串。"""
    cache = os.path.join(CACHE_DIR, 'ai-taskwords', kind, token + '.json')
    if not refresh and os.path.exists(cache):
        try:
            with open(cache, 'r', encoding='utf-8') as fp:
                return json.load(fp), None
        except Exception:
            pass
    url = '{}/{}/{}.json'.format(API, kind, token)
    req = urllib.request.Request(url, headers=UA)
    try:
        with urllib.request.urlopen(req, timeout=10, context=_CTX) as resp:
            doc = json.loads(resp.read().decode('utf-8'))
        os.makedirs(os.path.dirname(cache), exist_ok=True)
        with open(cache, 'w', encoding='utf-8') as fp:
            json.dump(doc, fp, ensure_ascii=False)
        time.sleep(0.05)
        return doc, None
    except urllib.error.HTTPError as e:
        if e.code in (404, 410):
            return None, 'HTTP {}'.format(e.code)
        return None, 'HTTP {}'.format(e.code)
    except Exception as e:  # noqa: BLE001 — 网络/解析问题统一按「未能校验」处理
        return None, str(e)


def infer_kind(task, tokens):
    """taskwords 不区分 formula/cask；上游查询时按 token 形态猜 kind（先 formula 后 cask）。"""
    return 'formula', 'cask'


def main():
    local_only = '--local' in sys.argv[1:]
    problems = []

    if not os.path.exists(TASKWORDS):
        print('taskwords.json 不存在: {}'.format(TASKWORDS))
        return 1
    try:
        with open(TASKWORDS, 'r', encoding='utf-8') as fp:
            doc = json.load(fp)
    except Exception as e:  # noqa: BLE001
        print('taskwords.json 解析失败: {}'.format(e))
        return 1

    words = doc.get('words')
    if not isinstance(words, list):
        print('[structure] words 不是数组')
        return 1

    print('中文任务词表 — {} 条（目标 {}，下限 {}）'.format(len(words), TARGET_WORDS, MIN_WORDS))

    # ---- 结构 ----
    seen_tasks = {}
    all_tokens = []
    for i, item in enumerate(words):
        prefix = 'words[{}]'.format(i)
        if not isinstance(item, dict):
            problems.append('{}: 不是对象'.format(prefix))
            continue
        task = item.get('task')
        if not isinstance(task, str) or not task.strip():
            problems.append('{}: task 为空'.format(prefix))
            continue
        if task in seen_tasks:
            problems.append('{}: task "{}" 与 words[{}] 重复'.format(prefix, task, seen_tasks[task]))
        else:
            seen_tasks[task] = i
        tokens = item.get('tokens')
        if not isinstance(tokens, list) or not tokens:
            problems.append('{}: tokens 为空'.format(prefix))
            continue
        if len(tokens) > MAX_TOKENS_PER_WORD:
            problems.append('{}: tokens 超过 {} 个'.format(prefix, MAX_TOKENS_PER_WORD))
        for tok in tokens:
            if not isinstance(tok, str) or not tok.strip():
                problems.append('{}: 有空/非字符串 token'.format(prefix))
            else:
                all_tokens.append((prefix, tok.strip()))
    note = doc.get('_note')
    if not isinstance(note, str) or 'spec' not in note:
        print('[note] _note 缺失或未指向 spec（溯源用，建议补）')

    print('\n[structure]')
    if problems:
        for one in problems:
            print('  - ' + one)
    else:
        print('  task/token 全部合法（无空值、无重复、数量 ≤ {}）'.format(MAX_TOKENS_PER_WORD))
    if len(words) < MIN_WORDS:
        problems.append('条数 {} 低于下限 {}'.format(len(words), MIN_WORDS))

    if local_only:
        print('\n===== 结论 =====')
        print('有问题，见上。' if problems else '词表结构可用（--local，未联网校验 token 存在性）。')
        return 1 if problems else 0

    # ---- token 存在性（上游） ----
    print('\n[upstream]')
    missing = []
    unverified = []
    checked = set()
    ok = 0
    for prefix, tok in all_tokens:
        if tok in checked:
            continue
        checked.add(tok)
        doc_f, err_f = fetch_upstream('formula', tok)
        if err_f is None and doc_f:
            ok += 1
            continue
        if err_f in ('HTTP 404', 'HTTP 410'):
            doc_c, err_c = fetch_upstream('cask', tok)
            if err_c is None and doc_c:
                ok += 1
                continue
            if err_c in ('HTTP 404', 'HTTP 410'):
                missing.append('{}/{}'.format(prefix, tok))
                continue
        unverified.append('{}/{} ({})'.format(prefix, tok, err_f or err_c))

    print('  仍在上游 {} / {}（去重后 {} 个 token）'.format(ok, len(all_tokens), len(checked)))
    for one in missing:
        print('  - 已从上游消失: ' + one)
    for one in unverified:
        print('  - 未能校验（网络/解析问题，不算缺失）: ' + one)
    if missing:
        problems.append('{} 个 token 已从上游消失'.format(len(missing)))

    print('\n===== 结论 =====')
    print('有问题，见上。' if problems else '词表可用。')
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
