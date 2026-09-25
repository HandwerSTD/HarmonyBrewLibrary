#!/usr/bin/env python3
"""mock 数据的字段类型自检。

为什么需要它：`BrewModels.ets` 里每个字段都声明了具体类型，而 JSON 是弱类型的 ——
JSON 里出现与声明不符的形状时，ArkTS 编译**不会报错**（类型检查看的是声明而不是 JSON），
运行期要么被 JS 隐式转换掩盖，要么在比较/运算处悄悄出错。

本脚本用「同一字段在不同条目里的类型是否一致」来发现这类问题：
真实数据里同一个字段出现两种类型，几乎总是意味着模型里的类型假设写错了。

实测抓到过两处（已修）：
  formula.serviceRun   声明 string[]，实际有 str / dict 两种形态
                       （dict 是按平台分的，如 {"linux": [...]}）
  cask.bundleVersion   声明 number，实际有 '15526.9.3' 这类点分字符串

用法：
    python3 check_types.py            # 退出码 0 = 通过，1 = 有类型不一致
                                      # 任意目录下运行均可（路径相对脚本自身解析）
"""

import collections
import glob
import json
import os
import sys

# 相对脚本自身解析，而不是相对当前目录 —— 否则换个目录运行就报"没找到 mock 文件"
HERE = os.path.dirname(os.path.abspath(__file__))
MOCK_DIR = os.path.join(HERE, '..', '..', 'common', 'src', 'main', 'resources',
                        'rawfile', 'mockdata')


def type_name(value):
    if isinstance(value, list):
        return 'list'
    if isinstance(value, dict):
        return 'dict'
    if value is None:
        return 'null'
    if isinstance(value, bool):
        return 'bool'
    return type(value).__name__


def scan(records, prefix=''):
    """返回 [(字段路径, {类型: 出现次数})]，只包含类型不一致的字段。"""
    counters = collections.defaultdict(collections.Counter)
    for record in records:
        if not isinstance(record, dict):
            continue
        for key, value in record.items():
            counters[key][type_name(value)] += 1
    findings = []
    for key, counter in counters.items():
        # null 视为可选字段缺省，不算类型不一致
        real = {name: count for name, count in counter.items() if name != 'null'}
        if len(real) > 1:
            findings.append((prefix + key, real))
    return findings


def collect(records_tree, filename):
    """递归找出所有「对象数组」，逐层检查。"""
    findings = []

    def walk(node, prefix):
        if isinstance(node, list):
            if node and isinstance(node[0], dict):
                findings.extend(scan(node, prefix))
            return
        if isinstance(node, dict):
            for key, value in node.items():
                walk(value, f'{prefix}{key}.')

    walk(records_tree, '')
    return findings


def main():
    pattern = os.path.join(MOCK_DIR, 'brew-*.json')
    files = sorted(glob.glob(pattern))
    if not files:
        print(f'没有找到 mock 文件：{pattern}')
        return 1

    failed = 0
    for path in files:
        with open(path, encoding='utf-8') as handle:
            payload = json.load(handle)
        findings = collect(payload.get('body'), os.path.basename(path))
        if findings:
            failed += 1
            print(f'❌ {os.path.basename(path)}')
            for field, types in findings:
                rendered = '  '.join(f'{name}={count}' for name, count in sorted(types.items()))
                print(f'     {field:48} {rendered}')

    if failed:
        print(f'\n{failed} 个文件存在字段类型不一致 —— 检查 BrewModels.ets 的声明与生成器产出')
        return 1
    print(f'✅ {len(files)} 个 mock 文件字段类型一致')
    return 0


if __name__ == '__main__':
    sys.exit(main())
