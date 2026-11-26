/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

/**
 * 「关注更新」桌面卡片页（F 线新增，spec：用户裁定 2026-11-26 双卡并存）。
 *
 * 与原哨兵卡（BrewSentinelCard）的关系：**同一份快照、两种口径**——
 *   - 原卡（三规格）：推荐更新口径，展示全部主动安装的待更新包；
 *   - 本卡（2*4 / 4*4 两规格）：只展示**关注中的**待更新包；一个关注都没有时给
 *     「关注空态」引导，不冒充「全部最新」（G1 的 F 线版本：不给假结论）。
 *
 * 视觉语言与原卡同一套（hero 大数字 + 纯色徽章、系统字色分层、hairline 分隔、
 * 版本对行），只是没有 2*2 构图、多一个关注空态。
 *
 * **本文件保持零 import**（一期约定）：postCardAction 是全局函数；数据键与服务侧
 * BrewSentinelService 的 SENTINEL_DATA_* 常量一一对应（两卡共用同一组键名，各自
 * LocalStorage 相互独立），两边必须成对修改（键名不一致就是「推了数据卡片不亮」，
 * 编译期发现不了）；规格字符串与 SENTINEL_DIMENSION_* 成对。
 *
 * 规格判定走 binding 单通道：sentinelDimension 由 FormExtensionAbility 在
 * onAddForm/onUpdateForm 写入（DIMENSION_KEY 归一）。本卡 form_config 只登记
 * 2*4/4*4，规格来源之外的值一律按 2*4 兜底渲染。
 */

let followStorage = new LocalStorage();

// ---- 数据键（与 service 的 SENTINEL_DATA_* 常量成对维护；与原卡共用键名，各自独立） ----
// 常量名加 F 前缀：ArkTS 卡片页在同一模块作用域编译，模块级标识符与原卡页重名会直接编译冲突
const FKEY_FORM_ID: string = 'sentinelFormId';
const FKEY_DIMENSION: string = 'sentinelDimension';
const FKEY_HAS_SNAPSHOT: string = 'sentinelHasSnapshot';
const FKEY_FOLLOW_EMPTY: string = 'sentinelFollowEmpty';
const FKEY_COUNT: string = 'sentinelCount';
const FKEY_ITEMS: string = 'sentinelItems';
const FKEY_AS_OF: string = 'sentinelAsOfText';
const FKEY_STALE: string = 'sentinelStale';

// ---- 规格口径（与 service 的 SENTINEL_DIMENSION_* 成对维护；本卡没有 2*2） ----
const FDIM_2_4: string = '2*4';
const FDIM_4_4: string = '4*4';

// ---- 展示口径（与 service 的 SENTINEL_CARD_ITEMS_LIMIT 成对维护） ----
/** 2*4 右栏版本对的条数上限 */
const FTOP_LIMIT: number = 3;
/** 4*4 版本对列表的条数上限（镜像侧最多推 6 条） */
const FLIST_LIMIT: number = 6;

/** 版本对行模型（与 service 镜像 items 的 JSON 结构成对维护；命名与原卡页错开） */
class FollowCardItem {
  public name: string = '';
  public version: string = '';
  public latestVersion: string = '';
}

@Entry(followStorage)
@Component
struct BrewFollowCard {
  @LocalStorageProp(FKEY_FORM_ID) formId: string = '';
  @LocalStorageProp(FKEY_DIMENSION) dimension: string = '';
  @LocalStorageProp(FKEY_HAS_SNAPSHOT) hasSnapshot: boolean = false;
  @LocalStorageProp(FKEY_FOLLOW_EMPTY) followEmpty: boolean = false;
  @LocalStorageProp(FKEY_COUNT) count: number = 0;
  @LocalStorageProp(FKEY_ITEMS) itemsJson: string = '[]';
  @LocalStorageProp(FKEY_AS_OF) asOfText: string = '';
  @LocalStorageProp(FKEY_STALE) stale: boolean = false;

  /** 实际生效的规格（binding 单通道归一后的值） */
  @State effectiveDimension: string = FDIM_2_4;

  aboutToAppear(): void {
    this.effectiveDimension = this.normalizeDimension(this.dimension);
  }

  private normalizeDimension(value: string): string {
    if (value === FDIM_2_4 || value === FDIM_4_4) {
      return value;
    }
    return FDIM_2_4;
  }

  /** 镜像版本对解析。坏数据（JSON 坏/字段缺）按空列表处理，卡片退化为纯计数布局 */
  private parseItems(): FollowCardItem[] {
    const out: FollowCardItem[] = [];
    try {
      const parsed: object[] = JSON.parse(this.itemsJson) as object[];
      if (!Array.isArray(parsed)) {
        return out;
      }
      for (const element of parsed) {
        if (out.length >= FLIST_LIMIT) {
          break;
        }
        const item = element as FollowCardItem;
        if (typeof item.name === 'string' && item.name.length > 0 &&
          typeof item.version === 'string' && typeof item.latestVersion === 'string') {
          out.push(item);
        }
      }
      return out;
    } catch (err) {
      return out;
    }
  }

  /** 当前规格下要渲染的版本对条数：4*4 六行，其余（2*4）三行 */
  private displayItems(): FollowCardItem[] {
    const all: FollowCardItem[] = this.parseItems();
    const limit: number = this.effectiveDimension === FDIM_4_4 ? FLIST_LIMIT : FTOP_LIMIT;
    const out: FollowCardItem[] = [];
    for (let i = 0; i < all.length && i < limit; i++) {
      out.push(all[i]);
    }
    return out;
  }

  /** 页脚：陈旧给降显文案，否则「截至 HH:mm」（G9：诚实口径） */
  private footerResource(): ResourceStr {
    if (this.stale) {
      return $r('app.string.follow_card_stale');
    }
    return $r('app.string.follow_card_asof', this.asOfText);
  }

  private openPackages(): void {
    postCardAction(this, {
      action: 'router',
      abilityName: 'PcAbility',
      params: { 'sentinel_route': 'MinePackagesView' }
    });
  }

  /** iOS 风格纯色徽章：正常/引导 = 橙底白 ↑，零更新 = 绿底白 ✓（与原卡同一构图） */
  @Builder
  BadgeGlyph(isSuccess: boolean) {
    Column() {
      Text(isSuccess ? '✓' : '↑')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(Color.White)
    }
    .width(32)
    .height(32)
    .borderRadius(8)
    .backgroundColor(isSuccess ? $r('app.color.sentinel_success') : $r('app.color.sentinel_accent'))
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /** hero 行：徽章 + 大数字（2*4=56fp、4*4=64fp Bold accent） */
  @Builder
  HeroRow() {
    Row({ space: 12 }) {
      this.BadgeGlyph(false)
      Text(this.count.toString())
        .fontSize(this.effectiveDimension === FDIM_4_4 ? 64 : 56)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.sentinel_accent'))
    }
    .alignItems(VerticalAlign.Center)
  }

  /** hero 下方的单位说明（body 字阶，font_secondary）。允许换到 2 行：窄规格下长文案截断成一行会丢口径 */
  @Builder
  UnitLine() {
    Text($r('app.string.follow_card_unit'))
      .fontSize(14)
      .fontColor($r('sys.color.font_secondary'))
      .maxLines(2)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
  }

  /** 页脚小字（caption 字阶 11fp，font_tertiary） */
  @Builder
  FooterLine() {
    Text(this.footerResource())
      .fontSize(11)
      .fontColor($r('sys.color.font_tertiary'))
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
  }

  /** hairline 分隔线（sys comp_divider，1vp） */
  @Builder
  Hairline() {
    Row()
      .width('100%')
      .height(1)
      .backgroundColor($r('sys.color.comp_divider'))
      .margin({ top: 6, bottom: 6 })
  }

  /** 版本对行：包名 / 旧版本 / ↑ / 新版本（accent）。行高按规格收放 */
  @Builder
  PairRow(item: FollowCardItem) {
    Row({ space: 6 }) {
      Text(item.name)
        .fontSize(this.effectiveDimension === FDIM_4_4 ? 14 : 12)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text(item.version)
        .fontSize(12)
        .fontColor($r('sys.color.font_tertiary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text('↑')
        .fontSize(12)
        .fontColor($r('sys.color.font_tertiary'))
      Text(item.latestVersion)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.sentinel_accent'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(this.effectiveDimension === FDIM_4_4 ? 32 : 30)
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 引导态（宿主从未成功读过本机包 / 镜像 miss / 一期 v1 旧镜像）：不给 0 假数据（G1）。
   * 2*4：徽章 + 引导文案单栏居中；4*4 另加标题（spec §5.5 状态矩阵）。
   */
  @Builder
  GuideBody() {
    Column({ space: 12 }) {
      this.BadgeGlyph(false)
      if (this.effectiveDimension === FDIM_4_4) {
        Text($r('app.string.sentinel_follow_form_name'))
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_secondary'))
      }
      Text($r('app.string.follow_card_none'))
        .fontSize(13)
        .fontColor($r('sys.color.font_secondary'))
        .textAlign(TextAlign.Center)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * 关注空态（F 线）：镜像有效但用户一个关注都没有。与引导态分开而不复用，
   * 是因为文案语义不同——这里用户已经能看到数据了，缺的是「关注」这个动作。
   * 不冒充零更新态（绿 ✓ 全部最新）：没有关注时那个结论是假的。
   */
  @Builder
  FollowEmptyBody() {
    Column({ space: 12 }) {
      this.BadgeGlyph(false)
      Text($r('app.string.follow_card_none'))
        .fontSize(13)
        .fontColor($r('sys.color.font_secondary'))
        .textAlign(TextAlign.Center)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /** 零更新态（关注语义：关注中的包都已是最新）：绿徽章 ✓ + 页脚（截至/降显）。两规格同一构图居中 */
  @Builder
  ZeroBody() {
    Column({ space: 12 }) {
      this.BadgeGlyph(true)
      Text($r('app.string.follow_card_zero'))
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
      this.FooterLine()
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * 正常/陈旧态按规格分两种构图（陈旧只换页脚文案，布局不变——spec §5.5）：
   *   - 2*4：宽横条双栏——左 hero（含页脚），hairline 竖隔，右栏 3 行版本对 + 引导句；
   *   - 4*4：大方卡——头部 hero，hairline 横隔，6 行版本对列表，页脚（超出部分截断，
   *     滚动列表不在卡片支持组件面里，溢出策略交给探针结论 Q1+ 校准行高）。
   */
  @Builder
  LiveBody() {
    if (this.effectiveDimension === FDIM_4_4) {
      Column({ space: 4 }) {
        Row({ space: 12 }) {
          this.BadgeGlyph(false)
          Text(this.count.toString())
            .fontSize(64)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.sentinel_accent'))
          Text($r('app.string.follow_card_unit'))
            .fontSize(14)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ bottom: 14 })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        this.Hairline()
        Column() {
          ForEach(this.displayItems(), (item: FollowCardItem) => {
            this.PairRow(item)
          }, (item: FollowCardItem) => item.name)
        }
        .width('100%')
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Row({ space: 6 }) {
          if (this.stale) {
            Text($r('app.string.follow_card_stale'))
              .fontSize(11)
              .fontColor($r('sys.color.font_tertiary'))
          } else {
            if (this.count > FLIST_LIMIT) {
              Text($r('app.string.follow_card_more', this.count - FLIST_LIMIT))
                .fontSize(11)
                .fontColor($r('sys.color.font_tertiary'))
            }
            Text($r('app.string.follow_card_hint'))
              .fontSize(11)
              .fontColor($r('sys.color.font_tertiary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .height('100%')
    } else {
      // 2*4：宽横条双栏——左 hero（含页脚），hairline 竖隔，右栏 3 行版本对 + 引导句
      Row() {
        Column({ space: 4 }) {
          this.HeroRow()
          this.UnitLine()
          Blank()
          this.FooterLine()
        }
        .width('38%')
        .height('100%')
        .alignItems(HorizontalAlign.Start)
        Column()
          .width(1)
          .height('100%')
          .backgroundColor($r('sys.color.comp_divider'))
          .margin({ left: 12, right: 12 })
        Column({ space: 2 }) {
          ForEach(this.displayItems(), (item: FollowCardItem) => {
            this.PairRow(item)
          }, (item: FollowCardItem) => item.name)
          Blank()
          Text($r('app.string.follow_card_hint'))
            .fontSize(11)
            .fontColor($r('sys.color.font_tertiary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .height('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height('100%')
      .alignItems(VerticalAlign.Center)
    }
  }

  build() {
    Column() {
      if (!this.hasSnapshot) {
        this.GuideBody()
      } else if (this.followEmpty) {
        this.FollowEmptyBody()
      } else if (this.count === 0) {
        this.ZeroBody()
      } else {
        this.LiveBody()
      }
    }
    .width('100%')
    .height('100%')
    // 外边距：4*4 用 20vp 的大方卡呼吸感，2*4 用 16vp 保小面积容量（spec §4.1 口径的规格化落地）
    .padding(this.effectiveDimension === FDIM_4_4 ? 20 : 16)
    .alignItems(HorizontalAlign.Start)
    // 引导/关注空态/零更新态由各自 body 自居中；正常态顶对齐 + Blank 把页脚收底
    .justifyContent(this.hasSnapshot && this.count > 0 && !this.followEmpty ? FlexAlign.Start : FlexAlign.Center)
    .onClick(() => {
      this.openPackages()
    })
  }
}
