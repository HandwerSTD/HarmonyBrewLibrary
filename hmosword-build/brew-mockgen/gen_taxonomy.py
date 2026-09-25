#!/usr/bin/env python3
"""从 lexicon.json + tokens.json 生成设备端分类器 `BrewTaxonomy.ets`。

为什么需要它：分类口径有两份实现 —— 生成期（Python，`generate.py` 的 `classify()` / `subject_of()`）
与设备端（ArkTS，`BrewTaxonomy`）。两边算出的分类不一致时，症状是"分类卡少一张、成员错位"，
而且**不会报错**（`BrewTaxonomy.ets` 的文件头一直写着"本文件由脚本生成"，但那个脚本当时不在仓库里，
所以词表改动一直是手抄两份）。本脚本就是那个缺失的脚本：改词表只改 JSON，然后跑它。

用法：

    python3 gen_taxonomy.py            # 重新生成 BrewTaxonomy.ets
    python3 gen_taxonomy.py --check    # 只校验磁盘上的 .ets 与 JSON 是否一致（退出码 0/1，给自检用）

自检包含：主题词在同一 kind 内不能跨分类重复（否则"谁后写谁生效"这种隐形优先级）。
"""

import argparse
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
TARGET = os.path.join(REPO_ROOT, 'features', 'brewcommon', 'src', 'main', 'ets', 'constant', 'BrewTaxonomy.ets')

HEADER = '''/*
 * Copyright (c) 2025 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { BrewKind } from '../model/BrewModels';

/**
 * 分类体系：**策展覆盖 + 关键词 + 主题词**三层词表的设备端移植。
 *
 * **本文件由 `hmosword-build/brew-mockgen/gen_taxonomy.py` 生成，不要手改** ——
 * 改词表请改 `lexicon.json` / `tokens.json`，然后跑：
 *   `python3 gen_taxonomy.py && python3 gen_taxonomy.py --check`
 * 生成器与 `generate.py`（生成期参考实现）共用同一份口径，`eval_lexicon.py` 用它在现网全量上量兜底率。
 *
 * 为什么需要它：官方 API **没有任何分类字段** —— 分类一直是自建词表算出来的。
 * 以前这套词表只在构建期跑一次，结果落进 `brew-{formula,cask}-page.json`；
 * 现在目录（全量 1.6 万 token）已经在设备端了，分类也必须在设备端算，否则"能浏览的包"
 * 永远被那 240 个内置条目锁死。
 *
 * 判别顺序（与 `generate.py` 一致）：
 *   1. **策展覆盖**（`tokens.json`）：命中就直接用 —— 这两百多个包是人工确定过分类的；
 *   2. **关键词**（`lexicon.json` 的 `<kind>`）：desc 前 3 个词命中记 3 分、其余位置 1 分，
 *      最高分 ≥ `minScore` 且领先第二名 ≥ `minMargin` 才算命中；
 *   3. **主题词**（`lexicon.json` 的 `_subjects`）：关键词判不出来时，用「中心名词/主语」再查一次表
 *      （`kubernetes` 这类词本身足以判别，所以单词命中即定、不再算分）；
 *   4. **形态兜底桶**（`lexicon.json` 的 `_forms`）：前三层都不中、而描述形态上就是「库/框架/SDK」的，
 *      归到 `lib`（formula）。**不参与打分**，所以不会抢走已有分类；
 *   5. 都不中 → 归到该 kind 的**兜底分类**（formula `system` / cask `systemtool`）。
 *
 * 第 3 层是量出来的（`lexicon-eval.md`）：只加主题词就把 formula 的兜底率从 70.6% 降到 56.7%，
 * 而关键词层**0 条翻转**（它只在关键词层判不出来时生效，因此不可能改坏已有分类）。
 *
 * 分类的英文名与图标不在本文件：UI 侧已经按 categoryKey 自己查
 * （`FORMULA_CATEGORY_NAME` / `getCategorySymbolMap`），键位对齐 `categories.json` 即可。
 */
'''

THRESHOLD = '''
/** 关键词判定的阈值（`lexicon.json` 的 `_threshold`） */
export interface BrewLexiconThreshold {
  minScore: number;
  minMargin: number;
}

export const BREW_LEXICON_THRESHOLD: BrewLexiconThreshold = { minScore: %d, minMargin: %d };
'''

SUBJECT_CODE = '''
/**
 * 主题词的抽取规则（与 `generate.py: subject_terms()` 逐行对应）：
 * 从「desc 头部 2/3-gram、`for <...>`、`<X> library`」三处取候选，返回**按优先级排好**的列表，
 * 调用方取第一个命中的。
 *
 * 形态词紧前面那个词常常是泛化词（`Audio File Library` 里的 `file`），拿它查表会把包归错类
 * （实测：`C++ Audio File Library` 被 `file` 判成 system），所以遇到泛化词要往左继续找。
 */
const SUBJECT_GENERIC: Set<string> = new Set<string>([
  'file', 'files', 'data', 'string', 'strings', 'text', 'tool', 'tools', 'utility', 'utilities',
  'collection', 'set', 'input', 'output', 'process', 'system', 'resource', 'resources', 'client',
  'server', 'wrapper', 'module', 'things', 'stuff', 'general', 'purpose', 'fast', 'simple', 'small',
  'library', 'libraries', 'cross', 'platform', 'command', 'line', 'package', 'program', 'programs',
]);

const SUBJECT_WORD_RE: RegExp = /[a-z0-9]+/g;
const SUBJECT_FOR_RE: RegExp = /\\bfor\\s+([a-z0-9][a-z0-9 +.#/_-]{2,48})/;
const SUBJECT_FORM_RE: RegExp =
  /(?:^|[^a-z0-9])((?:[a-z0-9][a-z0-9+.#_-]*\\s+){0,2})([a-z0-9][a-z0-9+.#_-]*)\\s+(?:library|framework|sdk|toolkit|bindings?|implementation|port)\\b/;

function subjectWords(text: string): string[] {
  return text.match(SUBJECT_WORD_RE) ?? [];
}

function subjectTerms(desc: string): string[] {
  const text: string = (desc ?? '').toLowerCase();
  const words: string[] = subjectWords(text);
  const terms: string[] = [];
  if (words.length >= 3) {
    terms.push(words.slice(0, 3).join(' '));
  }
  if (words.length >= 2) {
    terms.push(words.slice(0, 2).join(' '));
  }
  const forMatch: RegExpMatchArray | null = text.match(SUBJECT_FOR_RE);
  if (forMatch !== null) {
    const sub: string[] = subjectWords(forMatch[1] ?? '');
    terms.push(sub.slice(0, 2).join(' '));
    sub.slice(0, 2).forEach((word: string) => terms.push(word));
  }
  const formMatch: RegExpMatchArray | null = text.match(SUBJECT_FORM_RE);
  if (formMatch !== null) {
    const before: string[] = subjectWords(formMatch[1] ?? '');
    if (before.length > 0) {
      terms.push(before.slice(-2).join(' '));
    }
    for (let i = before.length - 1; i >= 0; i--) {
      if (!SUBJECT_GENERIC.has(before[i])) {
        terms.push(before[i]);
        break;
      }
    }
    before.forEach((word: string) => terms.push(word));
    terms.push(formMatch[2] ?? '');
  }
  const out: string[] = [];
  terms.forEach((term: string) => {
    if (term.length > 0 && out.indexOf(term) < 0) {
      out.push(term);
    }
  });
  return out;
}
'''


def js_array(words):
    return '[' + ', '.join("'" + w.replace('\\', '\\\\').replace("'", "\\'") + "'" for w in words) + ']'


def build_lexicon_block(lexicon):
    lines = ['', '/** 关键词层：`<kind>:<categoryKey>` -> 关键词数组（判别性强的在前，与 JSON 顺序一致） */',
             'function buildLexicon(): Map<string, string[]> {',
             '  const lexicon: Map<string, string[]> = new Map<string, string[]>();']
    for kind in ('formula', 'cask'):
        for cat, words in lexicon[kind].items():
            if cat.startswith('_'):
                continue
            lines.append("  lexicon.set('%s:%s', %s);" % (kind, cat, js_array(words)))
    lines += ['  return lexicon;', '}']
    return '\n'.join(lines)


def build_subjects_block(lexicon):
    lines = ['', '/** 主题词层：`<kind>:<主题词>` -> categoryKey（表在 JSON 里按「分类 -> 词」维护，这里展开成反查表） */',
             'function buildSubjects(): Map<string, string> {',
             '  const subjects: Map<string, string> = new Map<string, string>();',
             '  const table: Record<string, Record<string, string[]>> = {']
    kinds = [k for k in lexicon.get('_subjects', {}) if not k.startswith('_')]
    for kind in kinds:
        lines.append("    '%s': {" % kind)
        for cat, terms in lexicon['_subjects'][kind].items():
            lines.append("      '%s': %s," % (cat, js_array(terms)))
        lines.append('    },')
    lines += ['  };', '  Object.keys(table).forEach((kind: string) => {',
              '    const byCategory: Record<string, string[]> = table[kind];',
              '    Object.keys(byCategory).forEach((categoryKey: string) => {',
              '      byCategory[categoryKey].forEach((term: string) => subjects.set(`${kind}:${term}`, categoryKey));',
              '    });', '  });', '  return subjects;', '}']
    return '\n'.join(lines)


def build_forms_block(lexicon):
    lines = ['', '/** 形态兜底桶：`<kind>:<分类>` -> 形态词（表在 JSON 里按「分类 -> 词」维护，这里展开成反查表） */',
             'function buildForms(): Map<string, string> {',
             '  const forms: Map<string, string> = new Map<string, string>();',
             '  const table: Record<string, Record<string, string[]>> = {']
    for kind, cats in (lexicon.get('_forms') or {}).items():
        if kind.startswith('_'):
            continue
        lines.append("    '%s': {" % kind)
        for cat, words in cats.items():
            lines.append("      '%s': %s," % (cat, js_array(words)))
        lines.append('    },')
    lines += ['  };', '  Object.keys(table).forEach((kind: string) => {',
              '    const byCategory: Record<string, string[]> = table[kind];',
              '    Object.keys(byCategory).forEach((categoryKey: string) => {',
              '      byCategory[categoryKey].forEach((word: string) => forms.set(`${kind}:${word}`, categoryKey));',
              '    });', '  });', '  return forms;', '}']
    return '\n'.join(lines)


def build_overrides_block(tokens):
    lines = ['', '/** 策展覆盖：`<kind>:<categoryKey>` -> token 数组（人工确定过分类的包；含 Discover 榜单补入的那批） */',
             'function buildOverrides(): Map<string, string[]> {',
             '  const overrides: Map<string, string[]> = new Map<string, string[]>();']
    for kind in ('formula', 'cask'):
        cats = [c for c in tokens.get(kind, {}) if not c.startswith('_')]
        discover = tokens.get(f'_discover_{kind}', {}) or {}
        for cat in cats:
            merged = list(tokens[kind][cat]) + list(discover.get(cat, []))
            lines.append("  overrides.set('%s:%s', %s);" % (kind, cat, js_array(merged)))
    lines += ['  return overrides;', '}']
    return '\n'.join(lines)


def build_rest(lexicon, tokens):
    th = lexicon['_threshold']
    kinds = [k for k in lexicon.get('_subjects', {}) if not k.startswith('_')]
    subject_keys = ', '.join("'%s'" % k for k in kinds)
    return (THRESHOLD % (th.get('minScore', 2), th.get('minMargin', 2))
            + build_lexicon_block(lexicon)
            + build_subjects_block(lexicon)
            + build_forms_block(lexicon)
            + build_overrides_block(tokens)
            + '''

const BREW_LEXICON: Map<string, string[]> = buildLexicon();
const BREW_SUBJECTS: Map<string, string> = buildSubjects();
const BREW_FORMS: Map<string, string> = buildForms();
const BREW_OVERRIDES_BY_KEY: Map<string, string[]> = buildOverrides();

/**
 * `<kind>:<token>` -> categoryKey 的扁平表（构造时展开一次，查询 O(1)）。
 *
 * 注意 key 的拼法：源表的 key 是 `<kind>:<categoryKey>`，展开时要**拆开**再拼成
 * `<kind>:<token>` —— 直接拼 `源 key + ':' + token` 会得到 `formula:devtools:uv` 这种
 * 永远查不到的键（这个错犯过一次：240 个策展分类全废，只剩关键词在猜，
 * 表现是"分类卡少一张、兜底档塞了 73 个包"）。
 */
function buildOverrideIndex(): Map<string, string> {
  const index: Map<string, string> = new Map<string, string>();
  BREW_OVERRIDES_BY_KEY.forEach((tokens: string[], kindKey: string) => {
    const sep: number = kindKey.indexOf(':');
    const kind: string = kindKey.substring(0, sep);
    const categoryKey: string = kindKey.substring(sep + 1);
    tokens.forEach((token: string) => index.set(`${kind}:${token}`, categoryKey));
  });
  return index;
}

const BREW_OVERRIDE_INDEX: Map<string, string> = buildOverrideIndex();

/** 兜底分类：三层都判不出来时归到这一档（两边的 "system" 语义） */
const BREW_CATCH_ALL: Map<string, string> = new Map<string, string>([
  [BrewKind.FORMULA, 'system'],
  [BrewKind.CASK, 'systemtool'],
]);

/** 词表里出现的分类 key（供自检/日志核对） */
export function brewLexiconKeys(): string[] {
  const keys: string[] = [];
  BREW_LEXICON.forEach((words: string[], kindKey: string) => keys.push(`${kindKey}(${words.length})`));
  BREW_SUBJECTS.forEach((categoryKey: string, kindTerm: string) => keys.push(`${kindTerm}->${categoryKey}`));
  return keys;
}

export class BrewTaxonomy {
  /** 取策展覆盖里的分类；没有则 undefined（不要在这里回落到兜底，调用方要看得出"未命中"） */
  public static overrideOf(kind: string, token: string): string | undefined {
    return BREW_OVERRIDE_INDEX.get(`${kind}:${token}`);
  }

  /**
   * 关键词分类。返回 undefined = 判不出来（调用方再走主题层 / 兜底）。
   *
   * 与 `generate.py: classify()` 逐行对应：`head` 取 desc 小写后**前 3 个字母数字片段**
   * （`[a-z0-9]+`），命中词在 head 里记 3 分、否则 1 分；`word in text` 是**子串**判定，
   * 不是分词 —— 所以 `git` 会命中 `github`，这是既有口径，改它会让分类结果与生成器不一致。
   */
  public static classify(kind: string, desc: string): string | undefined {
    const text: string = (desc ?? '').toLowerCase();
    const headWords: string[] = text.match(/[a-z0-9]+/g) ?? [];
    const head: string = headWords.slice(0, 3).join(' ');
    const scores: Map<string, number> = new Map<string, number>();
    BREW_LEXICON.forEach((words: string[], kindKey: string) => {
      const sep: number = kindKey.indexOf(':');
      if (kindKey.substring(0, sep) !== kind) {
        return;
      }
      const key: string = kindKey.substring(sep + 1);
      let total: number = 0;
      words.forEach((word: string) => {
        if (text.indexOf(word) >= 0) {
          total += head.indexOf(word) >= 0 ? 3 : 1;
        }
      });
      if (total > 0) {
        scores.set(key, total);
      }
    });
    if (scores.size === 0) {
      return undefined;
    }
    // 与 Python 的 `sorted(scores.items(), key=-score)` 同序：Map 保持插入顺序，排序稳定
    let topKey: string = '';
    let topScore: number = 0;
    let secondScore: number = 0;
    scores.forEach((score: number, key: string) => {
      if (score > topScore) {
        secondScore = topScore;
        topScore = score;
        topKey = key;
      } else if (score > secondScore) {
        secondScore = score;
      }
    });
    if (topScore >= BREW_LEXICON_THRESHOLD.minScore &&
      (topScore - secondScore) >= BREW_LEXICON_THRESHOLD.minMargin) {
      return topKey;
    }
    return undefined;
  }

  /** 主题层分类：返回 undefined = 主题词没命中 */
  public static subjectOf(kind: string, desc: string): string | undefined {
    const terms: string[] = subjectTerms(desc);
    for (let i = 0; i < terms.length; i++) {
      const hit: string | undefined = BREW_SUBJECTS.get(`${kind}:${terms[i]}`);
      if (hit !== undefined) {
        return hit;
      }
    }
    return undefined;
  }

  /**
   * 形态兜底桶：前三层都判不出来、而描述形态上就是「库/框架/SDK」的，归到 `lib`。
   *
   * 与关键词层的区别：**不参与打分**，只在最后一步生效 —— 所以它不会抢走任何已有分类
   * （把同样这些词放进关键词层实测会造成 9 条翻转，兜底率却只差 0.4pt）。
   */
  public static formBucketOf(kind: string, desc: string): string | undefined {
    const text: string = (desc ?? '').toLowerCase();
    let hit: string | undefined = undefined;
    BREW_FORMS.forEach((categoryKey: string, kindWord: string) => {
      if (hit !== undefined) {
        return;
      }
      const sep: number = kindWord.indexOf(':');
      if (kindWord.substring(0, sep) !== kind) {
        return;
      }
      if (text.indexOf(kindWord.substring(sep + 1)) >= 0) {
        hit = categoryKey;
      }
    });
    return hit;
  }

  /**
   * 最终分类：策展覆盖 → 关键词 → 主题词 → 形态桶 → 兜底。**这是本层唯一该被调用的入口。**
   *
   * 返回值保证是 `categories.json` 里存在的 key，所以调用方不必再校验。
   */
  public static categoryOf(kind: string, token: string, desc: string): string {
    const curated: string | undefined = BrewTaxonomy.overrideOf(kind, token);
    if (curated !== undefined) {
      return curated;
    }
    const byKeyword: string | undefined = BrewTaxonomy.classify(kind, desc);
    if (byKeyword !== undefined) {
      return byKeyword;
    }
    const bySubject: string | undefined = BrewTaxonomy.subjectOf(kind, desc);
    if (bySubject !== undefined) {
      return bySubject;
    }
    const byForm: string | undefined = BrewTaxonomy.formBucketOf(kind, desc);
    if (byForm !== undefined) {
      return byForm;
    }
    return BREW_CATCH_ALL.get(kind) ?? 'system';
  }
}
''')


def check_category_en(categories):
    """`BrewBrowseBuilder.CATEGORY_EN` 是 `categories.json` 的 `en` 字段的**手抄副本**。

    实测踩过：加第 9 类 `lib` 时改了 categories.json / 三张 ArkTS 映射表与资源，**漏了这张表** ——
    分类卡片的英文名直接显示成 `lib`（`categoryEn()` 的兜底是返回 categoryKey）。
    这类"抄一份不报错"的地方就该被机器盯着，所以在这里查。
    """
    path = os.path.join(REPO_ROOT, 'features', 'brewcommon', 'src', 'main', 'ets', 'service',
                        'BrewBrowseBuilder.ets')
    with open(path, encoding='utf-8') as fp:
        text = fp.read()
    found = dict(re.findall(r"names\.set\('([a-z]+:[a-z]+)', '([^']*)'\)", text))
    problems = []
    for kind, items in categories.items():
        if kind.startswith('_'):
            continue
        for item in items:
            key = f"{kind}:{item['key']}"
            if key not in found:
                problems.append(f'CATEGORY_EN 缺少 `{key}`（categories.json 里的 en = "{item["en"]}"）')
            elif found[key] != item['en']:
                problems.append(f'CATEGORY_EN 里 `{key}` 是 "{found[key]}"，'
                                f'categories.json 里是 "{item["en"]}"')
    for key in found:
        kind, _, category = key.partition(':')
        if not any(i['key'] == category for i in categories.get(kind, [])):
            problems.append(f'CATEGORY_EN 里有 `{key}`，但 categories.json 里没有这个分类')
    return problems


def check_duplicates(lexicon):
    problems = []
    for kind, cats in (lexicon.get('_subjects') or {}).items():
        if kind.startswith('_'):
            continue
        seen = {}
        for cat, terms in cats.items():
            for term in terms:
                if term in seen and seen[term] != cat:
                    problems.append(f'主题词 `{term}` 同时属于 {kind}:{seen[term]} 与 {kind}:{cat}')
                seen[term] = cat
    return problems


def generate():
    with open(os.path.join(HERE, 'lexicon.json'), encoding='utf-8') as fp:
        lexicon = json.load(fp)
    with open(os.path.join(HERE, 'tokens.json'), encoding='utf-8') as fp:
        tokens = json.load(fp)
    with open(os.path.join(HERE, 'categories.json'), encoding='utf-8') as fp:
        categories = json.load(fp)
    problems = check_duplicates(lexicon) + check_category_en(categories)
    return HEADER + SUBJECT_CODE + build_rest(lexicon, tokens), problems


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--check', action='store_true', help='只校验磁盘上的 .ets 与 JSON 是否一致')
    args = ap.parse_args()

    text, problems = generate()
    if problems:
        print('词表/分类定义自检未通过：', file=sys.stderr)
        for one in problems:
            print('  - ' + one, file=sys.stderr)
        return 1

    with open(TARGET, encoding='utf-8') as fp:
        current = fp.read()
    if args.check:
        if current == text:
            print(f'{os.path.relpath(TARGET, REPO_ROOT)} 与词表一致')
            return 0
        print(f'{os.path.relpath(TARGET, REPO_ROOT)} 与词表**不一致**：跑 `python3 gen_taxonomy.py` 重新生成',
              file=sys.stderr)
        return 1
    with open(TARGET, 'w', encoding='utf-8') as fp:
        fp.write(text)
    print(f'已生成 {os.path.relpath(TARGET, REPO_ROOT)}（{len(text.splitlines())} 行）')
    return 0


if __name__ == '__main__':
    sys.exit(main())
