/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { Logger } from '@ohos/common';
import { ReleaseIntelArchiveEntry } from '@ohos/brewcommon';

/**
 * Y · 版本档案区（release intel spec §3.3 / §4：更新完成后留档）。
 *
 * 插在详情页 caveats 与「同分类其他包」之间；只渲染当前 token 的条目
 * （装配层已按 token 过滤），每条展示「旧版本 → 新版本 · 完成时间」，
 * 点开可展开当时留下的情报摘要一句话（条目内嵌的 cardJson，自含内容——
 * AI 缓存可能已被 TTL 回收，档案必须不依赖缓存就能回显，G7 加固口径）。
 *
 * 档案是**增益记录**：加载失败保持为空、整区不渲染，不提示错误（spec §3.3）。
 */
@Component
export struct BrewReleaseArchiveView {
  /** 当前 token 的档案条目（时间倒序，`appendArchive` 已保证） */
  @Prop @Require entries: ReleaseIntelArchiveEntry[];

  /** 展开态：当前展开的条目下标（-1 = 全部收起） */
  @State private expandedIndex: number = -1;

  /** 从条目内嵌的 cardJson 里取「一句话」（解析失败/为空 → 空串，不展开） */
  private oneLinerOf(entry: ReleaseIntelArchiveEntry): string {
    if (entry.cardJson.length === 0) {
      return '';
    }
    try {
      const parsed: Object = JSON.parse(entry.cardJson) as Object;
      const rec: Record<string, Object> = parsed as Record<string, Object>;
      const raw: Object | undefined = rec['oneLiner'];
      return typeof raw === 'string' ? raw as string : '';
    } catch (error) {
      Logger.warn(TAG, `release archive cardJson parse failed`);
      return '';
    }
  }

  build() {
    Column({ space: 12 }) {
      this.SectionTitle($r('app.string.release_intel_archive'))
      ForEach(this.entries, (entry: ReleaseIntelArchiveEntry, index: number) => {
        Column({ space: 4 }) {
          Row() {
            Text(`${entry.from} → ${entry.to}`)
              .fontSize($r('sys.float.Body_M'))
              .fontColor($r('sys.color.font_primary'))
              .layoutWeight(1)
            Text(fmtDate(entry.at))
              .fontSize($r('sys.float.Body_S'))
              .fontColor($r('sys.color.font_tertiary'))
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            // 展开切换只在「有可展示内容」时生效；没有 AI 摘要的条目点击只是无操作
            if (this.oneLinerOf(entry).length === 0) {
              return;
            }
            this.expandedIndex = this.expandedIndex === index ? -1 : index;
          })
          if (this.expandedIndex === index) {
            Text(this.oneLinerOf(entry))
              .fontSize($r('sys.float.Body_S'))
              .fontColor($r('sys.color.font_secondary'))
              .width('100%')
              .padding({ left: 10 })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }, (entry: ReleaseIntelArchiveEntry, index: number) => `arc_${entry.to}_${index}`)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .borderRadius($r('sys.float.corner_radius_level8'))
  }

  /** 分区标题：弱化的引导词（与 D1/情报卡同款基调） */
  @Builder
  SectionTitle(label: ResourceStr) {
    Text(label)
      .fontSize($r('sys.float.Body_S'))
      .fontWeight(FontWeight.Normal)
      .fontColor($r('sys.color.font_tertiary'))
      .width('100%')
  }
}

/** 完成时间展示：yyyy-MM-dd（档案粒度到天足够；hh:mm 属于通知/卡片语境） */
function fmtDate(at: number): string {
  if (at <= 0) {
    return '';
  }
  const d: Date = new Date(at);
  const month: string = d.getMonth() + 1 < 10 ? `0${d.getMonth() + 1}` : `${d.getMonth() + 1}`;
  const day: number = d.getDate();
  const dayText: string = day < 10 ? `0${day}` : `${day}`;
  return `${d.getFullYear()}-${month}-${dayText}`;
}

/** 打点 tag */
const TAG: string = '[release-intel]';
