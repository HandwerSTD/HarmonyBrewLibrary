/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  SemverJudge,
  FormulaDiffer,
  BrewNotesExtractor,
  ReleaseIntelRepoResolver,
  ReleaseIntelService,
  ReleaseIntelTagFilter,
} from '../../../../Index';

/**
 * Y · 更新情报中心（Release Intelligence）单测——spec §9 验证项的 TagFilter /
 * RepoResolver / FormulaDiffer / SemverJudge / NotesExtractor 部分。
 *
 * 契约背景（docs/superpowers/specs/2026-11-23-release-intel-spec.md）：
 *   - G2 tag 过滤零误报：releases.atom 混入 workspace 子包发布（ripgrep feed 含
 *     ignore-0.4.34），只允许 strip v 前缀后与 versions.stable **精确相等** 的 tag；
 *   - G3 diff 零 AI：FormulaDiffer 只做本地字段对比，防御式抽取不抛错；
 *   - 结构化区不依赖 AI：SemverJudge 的 unknown 不阻塞渲染，只改徽章文案（G1）。
 * ReleaseIntelFilter/Prefs 的行为依赖 GSKV + 应用 Context（真机路径），不在单测范围，
 * 由审计脚本（G6 唯一入口断言）与真机验收覆盖。
 */

/** ripgrep releases.atom 的片段 fixture（2026-11-23 实测样例的精简形态）。 */
const ATOM_SAMPLE: string = `<feed xmlns="http://www.w3.org/2005/Atom">
<entry>
  <id>tag:github.com,2008:Repository/748118/v15.2.0</id>
  <updated>2026-11-22T22:59:48Z</updated>
  <title>v15.2.0</title>
  <content type="html">&lt;p&gt;15.2.0 is a new release with &amp;amp; fixes&lt;/p&gt;
&lt;script&gt;alert(1)&lt;/script&gt;</content>
</entry>
<entry>
  <id>tag:github.com,2008:Repository/748118/ignore-0.4.34</id>
  <updated>2026-10-01T00:00:00Z</updated>
  <title>ignore-0.4.34</title>
  <content type="html">workspace crate release</content>
</entry>
</feed>`;

/** FormulaDiffer 用旧配方快照（基线形态：已装版本的 raw API JSON）。 */
function oldFormulaRaw(): Object {
  return JSON.parse('{"versions":{"stable":"1.25.0"},"dependencies":["pcre2"],"build_dependencies":[],' +
    '"uses_from_macos":[{"formula":"zlib"}],"caveats":"Old caveats.",' +
    '"bottle":{"stable":{"rebuild":0}}}') as Object;
}

/** FormulaDiffer 用新配方现网 JSON：新增 zstd 依赖、caveats 变化、重打包。 */
function newFormulaRaw(): Object {
  return JSON.parse('{"versions":{"stable":"1.25.0"},"dependencies":["zstd","pcre2"],"build_dependencies":["rust"],' +
    '"uses_from_macos":[{"formula":"zlib"}],"caveats":"New caveats.",' +
    '"bottle":{"stable":{"rebuild":1}}}') as Object;
}

export default function releaseIntelTest() {
  describe('ReleaseIntelTest', () => {
    // ---------------- TagFilter（G2 零误报） ----------------

    it('tagfilter_v_prefix_exact', 0, () => {
      expect(ReleaseIntelTagFilter.matches('v15.2.0', '15.2.0')).assertTrue();
      expect(ReleaseIntelTagFilter.matches('15.2.0', '15.2.0')).assertTrue();
    });

    it('tagfilter_rejects_subpackage', 0, () => {
      // feed 混入 workspace 子包发布：ignore-0.4.34 不是 ripgrep 15.2.0 的 release
      expect(ReleaseIntelTagFilter.matches('ignore-0.4.34', '15.2.0')).assertFalse();
    });

    it('tagfilter_rejects_suffix_and_loose', 0, () => {
      // strip v 之后必须精确相等，预发布/带后缀一律不算命中
      expect(ReleaseIntelTagFilter.matches('v15.2.0-beta', '15.2.0')).assertFalse();
      expect(ReleaseIntelTagFilter.matches('release-15.2.0', '15.2.0')).assertFalse();
    });

    it('tagfilter_normalize_strips_v_only', 0, () => {
      // 只剥紧贴版本号的 v/V 前缀，release- 这类词头不动
      expect(ReleaseIntelTagFilter.normalize('v15.2.0')).assertEqual('15.2.0');
      expect(ReleaseIntelTagFilter.normalize('V2.1.0')).assertEqual('2.1.0');
      expect(ReleaseIntelTagFilter.normalize('release-15.2.0')).assertEqual('release-15.2.0');
    });

    it('tagFromEntryId_extracts_tag', 0, () => {
      // fixture（实测样例精简形态）必须包含该 entry id，防样例漂移
      expect(ATOM_SAMPLE.indexOf('tag:github.com,2008:Repository/748118/v15.2.0') >= 0).assertTrue();
      expect(ReleaseIntelTagFilter.tagFromEntryId('tag:github.com,2008:Repository/748118/v15.2.0'))
        .assertEqual('v15.2.0');
    });

    // ---------------- RepoResolver ----------------

    it('resolver_prefers_archive_url', 0, () => {
      const raw: Object = JSON.parse('{"urls":{"stable":{"url":"https://github.com/BurntSushi/ripgrep/archive/refs/tags/15.2.0.tar.gz"}},' +
        '"homepage":"https://github.com/BurntSushi/ripgrep"}') as Object;
      const repo = ReleaseIntelRepoResolver.resolve(raw);
      expect(repo.owner).assertEqual('BurntSushi');
      expect(repo.repo).assertEqual('ripgrep');
      expect(repo.via).assertEqual('archive');
    });

    it('resolver_falls_back_to_homepage', 0, () => {
      const raw: Object = JSON.parse('{"urls":{"stable":{"url":"https://example.com/dist/rg-1.0.tar.gz"}},' +
        '"homepage":"https://github.com/BurntSushi/ripgrep"}') as Object;
      const repo = ReleaseIntelRepoResolver.resolve(raw);
      expect(repo.owner).assertEqual('BurntSushi');
      expect(repo.repo).assertEqual('ripgrep');
      expect(repo.via).assertEqual('homepage');
    });

    it('resolver_non_github_yields_empty', 0, () => {
      const raw: Object = JSON.parse('{"urls":{"stable":{"url":"https://ftp.gnu.org/gnu/wget/wget-1.25.0.tar.gz"}},' +
        '"homepage":"https://www.gnu.org/software/wget/"}') as Object;
      const repo = ReleaseIntelRepoResolver.resolve(raw);
      expect(repo.owner).assertEqual('');
      expect(repo.url).assertEqual('');
    });

    // ---------------- SemverJudge（G1：unknown 不阻塞渲染） ----------------

    it('semver_major_minor_patch', 0, () => {
      expect(SemverJudge.judge('7.0.0', '8.0.0').kind).assertEqual('major');
      expect(SemverJudge.judge('1.25.0', '1.26.0').kind).assertEqual('minor');
      expect(SemverJudge.judge('1.25.0', '1.25.1').kind).assertEqual('patch');
    });

    it('semver_revision_for_equal_and_bump', 0, () => {
      // from===to 与数值段相等（含 _2 后缀被丢弃）都判 revision（重打包口径）
      expect(SemverJudge.judge('1.25.0', '1.25.0').kind).assertEqual('revision');
      expect(SemverJudge.judge('1.25.0', '1.25.0_2').kind).assertEqual('revision');
    });

    it('semver_unknown_when_no_numeric_segment', 0, () => {
      expect(SemverJudge.judge('latest', '8.0.0').kind).assertEqual('unknown');
    });

    // ---------------- FormulaDiffer（G3 零 AI） ----------------

    it('differ_detects_dep_and_caveat_and_repack', 0, () => {
      const diff = FormulaDiffer.diff(oldFormulaRaw(), newFormulaRaw());
      expect(diff.baselineAvailable).assertTrue();
      expect(diff.depsAdded.length).assertEqual(1);
      expect(diff.depsAdded[0]).assertEqual('zstd');
      expect(diff.depsRemoved.length).assertEqual(0);
      expect(diff.buildDepsAdded.length).assertEqual(1);
      expect(diff.buildDepsAdded[0]).assertEqual('rust');
      expect(diff.caveatsChanged).assertTrue();
      expect(diff.bottleRepacked).assertTrue();
    });

    it('differ_detects_removed_dep', 0, () => {
      const diff = FormulaDiffer.diff(newFormulaRaw(), oldFormulaRaw());
      expect(diff.depsRemoved.length).assertEqual(1);
      expect(diff.depsRemoved[0]).assertEqual('zstd');
    });

    it('differ_ignores_order_drift', 0, () => {
      // 顺序漂移不该报成依赖变化（norm 去重排序）
      const a: Object = JSON.parse('{"dependencies":["pcre2","zstd"]}') as Object;
      const b: Object = JSON.parse('{"dependencies":["zstd","pcre2"]}') as Object;
      const diff = FormulaDiffer.diff(a, b);
      expect(diff.depsAdded.length).assertEqual(0);
      expect(diff.depsRemoved.length).assertEqual(0);
      expect(diff.caveatsChanged).assertFalse();
      expect(diff.bottleRepacked).assertFalse();
    });

    it('differ_missing_fields_do_not_throw', 0, () => {
      // 防御式抽取：空对象互比不抛错、不误报
      const a: Object = JSON.parse('{}') as Object;
      const b: Object = JSON.parse('{}') as Object;
      const diff = FormulaDiffer.diff(a, b);
      expect(diff.depsAdded.length).assertEqual(0);
      expect(diff.depsRemoved.length).assertEqual(0);
      expect(diff.buildDepsAdded.length).assertEqual(0);
      expect(diff.caveatsChanged).assertFalse();
      expect(diff.bottleRepacked).assertFalse();
    });

    // ---------------- BrewNotesExtractor（G4：剥 HTML 截断） ----------------

    it('extractor_strips_tags_script_entities', 0, () => {
      const extract = BrewNotesExtractor.extract(
        '<p>15.2.0 is a new release with &amp; fixes</p><script>alert(1)</script>');
      expect(extract.text.indexOf('15.2.0 is a new release with & fixes') >= 0).assertTrue();
      expect(extract.text.indexOf('alert') < 0).assertTrue();
      expect(extract.truncated).assertFalse();
    });

    it('extractor_marks_truncation', 0, () => {
      // 超长正文截 4096 并标注 truncated（G4 / F4 口径）
      let long: string = '';
      for (let i: number = 0; i < 900; i++) {
        long += '<p>0123456789abcdef</p>';
      }
      const extract = BrewNotesExtractor.extract(long);
      expect(extract.text.length).assertEqual(4096);
      expect(extract.truncated).assertTrue();
    });

    // ---------------- 打包通道路径分片（v1.1 G14） ----------------

    it('shard_path_letters', 0, () => {
      // homebrew-core 惯例分片：Formula/<首字母小写>/<token>.rb
      expect(ReleaseIntelService.formulaShardPath('wget')).assertEqual('Formula/w/wget.rb');
      expect(ReleaseIntelService.formulaShardPath('Ant@1.9')).assertEqual('Formula/a/Ant@1.9.rb');
    });

    it('shard_path_empty_token', 0, () => {
      expect(ReleaseIntelService.formulaShardPath('')).assertEqual('');
      expect(ReleaseIntelService.formulaShardPath('   ')).assertEqual('');
    });
  });
}
