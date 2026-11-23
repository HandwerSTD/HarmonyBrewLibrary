import { describe, it, expect } from '@ohos/hypium';
import { AnalyticsNumberParser } from '../../../../Index';

/**
 * AnalyticsNumberParser 单元测试（AI 二期 spec §9 / G4：数字一致性回溯制单测）。
 *
 * 口径基准（2026-11-23 实测，docs/brew-api-design.md 勘误）：
 * - 内嵌 analytics 已是扁平 map `{"<token>": int, "<token> --HEAD": int}`；
 * - 聚合端点 count/percent 是带逗号字符串（"516,535" / "2.11"）。
 */
export default function analyticsNumberParserTest() {
  describe('analyticsNumberParserTest', () => {
    it('parseInlineAnalytics_splitsHeadRow', 0, () => {
      // ArkTS 侧构造 Record：逐键填入（禁无类型对象字面量）
      const map: Record<string, Object> = {};
      map['ffmpeg'] = 123059 as Object;
      map['ffmpeg --HEAD'] = 296 as Object;
      const counts = AnalyticsNumberParser.parseInlineAnalytics(map);
      expect(counts.main).assertEqual(123059);
      expect(counts.head).assertEqual(296);
    });

    it('parseInlineAnalytics_headCaseInsensitive', 0, () => {
      const map: Record<string, Object> = {};
      map['wget'] = 1000 as Object;
      map['wget --head'] = 7 as Object;
      const counts = AnalyticsNumberParser.parseInlineAnalytics(map);
      expect(counts.main).assertEqual(1000);
      expect(counts.head).assertEqual(7);
    });

    it('parseInlineAnalytics_nullAndNonNumeric', 0, () => {
      const empty = AnalyticsNumberParser.parseInlineAnalytics(null);
      expect(empty.main).assertEqual(0);
      expect(empty.head).assertEqual(0);
      const map: Record<string, Object> = {};
      map['a'] = 'not-a-number' as Object;
      const counts = AnalyticsNumberParser.parseInlineAnalytics(map);
      expect(counts.main).assertEqual(0);
    });

    it('parseCommaCount_aggregateEndpoint', 0, () => {
      expect(AnalyticsNumberParser.parseCommaCount('516,535')).assertEqual(516535);
      expect(AnalyticsNumberParser.parseCommaCount('')).assertEqual(0);
      expect(AnalyticsNumberParser.parseCommaCount('abc')).assertEqual(0);
    });

    it('parsePercent_aggregateEndpoint', 0, () => {
      expect(AnalyticsNumberParser.parsePercent('2.11')).assertEqual(2.11);
      expect(AnalyticsNumberParser.parsePercent('2.11%')).assertEqual(2.11);
      expect(AnalyticsNumberParser.parsePercent('')).assertEqual(0);
      expect(AnalyticsNumberParser.parsePercent('n/a')).assertEqual(0);
    });

    it('filterTraceable_rejectsUnbackedNumbers', 0, () => {
      // grounding 里只有 123059；编造的 999999 必须整条丢弃
      const grounding = '{"installs": 123059}';
      const kept = AnalyticsNumberParser.filterTraceable(
        ['月安装 123,059 次', '月安装 999,999 次', '无数字结论'], grounding);
      expect(kept.length).assertEqual(2);
      expect(kept[0]).assertEqual('月安装 123,059 次');
      expect(kept[1]).assertEqual('无数字结论');
    });

    it('filterTraceable_emptyGroundingDropsAll', 0, () => {
      // 空 grounding（缓存命中/诊断路径不回溯）→ 返回空数组。
      // parseInsight 侧已保证空 grounding 不调用本函数（缓存/诊断路径传空串时直接跳过），
      // 这里验证的是「groundingJson 为空串」这一防御分支的双保险。
      const kept = AnalyticsNumberParser.filterTraceable(['foo', 'bar'], '');
      expect(kept.length).assertEqual(0);
    });

    it('filterTraceable_capsAtThree', 0, () => {
      const grounding = '{"a": 1, "b": 2, "c": 3, "d": 4}';
      const kept = AnalyticsNumberParser.filterTraceable(
        ['a 1', 'b 2', 'c 3', 'd 4'], grounding);
      expect(kept.length).assertEqual(3);
    });
  });
}
