/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

/**
 * 更新哨兵的桌面卡片页（二期 W 线整体重写，spec §4/§5）。
 *
 * 三规格（2*2 方卡 / 2*4 宽横条 / 4*4 大方卡，语义 = 行*列）× 四态（引导 / 零更新 /
 * 陈旧 / 正常），iOS 设计语言：hero 大数字 + 纯色徽章、系统字色分层、hairline 分隔。
 *
 * **本文件保持零 import**（一期约定）：postCardAction 是全局函数；数据键与服务侧
 * BrewSentinelService 的 SENTINEL_DATA_* 常量一一对应，两边必须成对修改（键名不一致
 * 就是「推了数据卡片不亮」，编译期发现不了）；规格字符串与 SENTINEL_DIMENSION_* 成对。
 *
 * 规格判定走 binding 单通道：sentinelDimension 由 FormExtensionAbility 在
 * onAddForm/onUpdateForm 写入（DIMENSION_KEY 归一）。spec §6.3 设想的 onAreaChange
 * 兜底通道被编译器直接拦下——卡片（form application）不支持 onAreaChange
 * （错误 11706006），故 resize 后的规格唯一来源是 onUpdateForm 携带的新 DIMENSION_KEY
 * （真机探针 Q1 验证）；若系统不回调，卡片停留旧规格布局（可接受的降级，登记表仍正确）。
 */

let storage = new LocalStorage();

// ---- 数据键（与 service 的 SENTINEL_DATA_* 常量成对维护） ----
const KEY_FORM_ID: string = 'sentinelFormId';
const KEY_DIMENSION: string = 'sentinelDimension';
const KEY_HAS_SNAPSHOT: string = 'sentinelHasSnapshot';
const KEY_COUNT: string = 'sentinelCount';
const KEY_ITEMS: string = 'sentinelItems';
const KEY_AS_OF: string = 'sentinelAsOfText';
const KEY_STALE: string = 'sentinelStale';

// ---- 规格口径（与 service 的 SENTINEL_DIMENSION_* 成对维护） ----
const DIM_2_2: string = '2*2';
const DIM_2_4: string = '2*4';
const DIM_4_4: string = '4*4';

// ---- 展示口径（与 service 的 SENTINEL_TOP_NAMES_LIMIT / SENTINEL_CARD_ITEMS_LIMIT 成对维护） ----
/** 2*2 单行包名与 2*4 右栏版本对的条数上限 */
const TOP_LIMIT: number = 3;
/** 4*4 版本对列表的条数上限（镜像侧最多推 6 条） */
const LIST_LIMIT: number = 6;

/** 版本对行模型（与 service 镜像 items 的 JSON 结构成对维护） */
class CardItem {
  public name: string = '';
  public version: string = '';
  public latestVersion: string = '';
}

@Entry(storage)
@Component
struct BrewSentinelCard {
  @LocalStorageProp(KEY_FORM_ID) formId: string = '';
  @LocalStorageProp(KEY_DIMENSION) dimension: string = '';
  @LocalStorageProp(KEY_HAS_SNAPSHOT) hasSnapshot: boolean = false;
  @LocalStorageProp(KEY_COUNT) count: number = 0;
  @LocalStorageProp(KEY_ITEMS) itemsJson: string = '[]';
  @LocalStorageProp(KEY_AS_OF) asOfText: string = '';
  @LocalStorageProp(KEY_STALE) stale: boolean = false;

  /** 实际生效的规格（binding 单通道归一后的值） */
  @State effectiveDimension: string = DIM_2_2;

  aboutToAppear(): void {
    this.effectiveDimension = this.normalizeDimension(this.dimension);
  }

  private normalizeDimension(value: string): string {
    if (value === DIM_2_2 || value === DIM_2_4 || value === DIM_4_4) {
      return value;
    }
    return DIM_2_2;
  }

  /** 镜像版本对解析。坏数据（JSON 坏/字段缺）按空列表处理，卡片退化为纯计数布局 */
  private parseItems(): CardItem[] {
    const out: CardItem[] = [];
    try {
      const parsed: object[] = JSON.parse(this.itemsJson) as object[];
      if (!Array.isArray(parsed)) {
        return out;
      }
      for (const element of parsed) {
        if (out.length >= LIST_LIMIT) {
          break;
        }
        const item = element as CardItem;
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

  /** 当前规格下要渲染的版本对条数：4*4 六行，其余三行 */
  private displayItems(): CardItem[] {
    const all: CardItem[] = this.parseItems();
    const limit: number = this.effectiveDimension === DIM_4_4 ? LIST_LIMIT : TOP_LIMIT;
    const out: CardItem[] = [];
    for (let i = 0; i < all.length && i < limit; i++) {
      out.push(all[i]);
    }
    return out;
  }

  /** 2*2 单行的包名串：前三个包名「、」连接 */
  private topNames(): string {
    const names: string[] = [];
    const items: CardItem[] = this.parseItems();
    for (let i = 0; i < items.length && i < TOP_LIMIT; i++) {
      names.push(items[i].name);
    }
    return names.join('、');
  }

  /** 页脚：陈旧给降显文案，否则「截至 HH:mm」（G9：诚实口径） */
  private footerResource(): ResourceStr {
    if (this.stale) {
      return $r('app.string.sentinel_card_stale');
    }
    return $r('app.string.sentinel_card_asof', this.asOfText);
  }

  private openPackages(): void {
    postCardAction(this, {
      action: 'router',
      abilityName: 'PcAbility',
      params: { 'sentinel_route': 'MinePackagesView' }
    });
  }

  /** iOS 风格纯色徽章：正常/引导 = 橙底白 ↑，零更新 = 绿底白 ✓（spec §4.1 ①） */
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

  /** hero 行：徽章 + 大数字（2*2/2*4=56fp、4*4=64fp Bold accent） */
  @Builder
  HeroRow() {
    Row({ space: 12 }) {
      this.BadgeGlyph(false)
      Text(this.count.toString())
        .fontSize(this.effectiveDimension === DIM_4_4 ? 64 : 56)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.sentinel_accent'))
    }
    .alignItems(VerticalAlign.Center)
  }

  /** hero 下方的单位说明（body 字阶，font_secondary） */
  @Builder
  UnitLine() {
    Text($r('app.string.sentinel_card_unit'))
      .fontSize(14)
      .fontColor($r('sys.color.font_secondary'))
      .maxLines(1)
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
  PairRow(item: CardItem) {
    Row({ space: 6 }) {
      Text(item.name)
        .fontSize(this.effectiveDimension === DIM_4_4 ? 14 : 12)
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
    .height(this.effectiveDimension === DIM_4_4 ? 32 : 30)
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 引导态（宿主从未成功读过本机包 / 镜像 miss / 一期 v1 旧镜像）：不给 0 假数据（G1）。
   * 2*2/2*4：徽章 + 引导文案单栏居中；4*4 另加标题（spec §5.5 状态矩阵）。
   */
  @Builder
  GuideBody() {
    Column({ space: 12 }) {
      this.BadgeGlyph(false)
      if (this.effectiveDimension === DIM_4_4) {
        Text($r('app.string.sentinel_form_name'))
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_secondary'))
      }
      Text($r('app.string.sentinel_card_empty'))
        .fontSize(13)
        .fontColor($r('sys.color.font_secondary'))
        .textAlign(TextAlign.Center)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /** 零更新态：绿徽章 ✓ + 全部为最新版本 + 页脚（截至/降显）。三规格同一构图居中 */
  @Builder
  ZeroBody() {
    Column({ space: 12 }) {
      this.BadgeGlyph(true)
      Text($r('app.string.sentinel_card_zero'))
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
   * 正常/陈旧态按规格分三种构图（陈旧只换页脚文案，布局不变——spec §5.5）：
   *   - 2*2：hero + 单行包名串，页脚收底；
   *   - 2*4：宽横条双栏——左 hero（含页脚），hairline 竖隔，右栏 3 行版本对 + 引导句；
   *   - 4*4：大方卡——头部 hero，hairline 横隔，6 行版本对列表，页脚（超出部分截断，
   *     滚动列表不在卡片支持组件面里，溢出策略交给探针结论 Q1+ 校准行高）。
   */
  @Builder
  LiveBody() {
    if (this.effectiveDimension === DIM_4_4) {
      Column({ space: 4 }) {
        Row({ space: 12 }) {
          this.BadgeGlyph(false)
          Text(this.count.toString())
            .fontSize(64)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.sentinel_accent'))
          Text($r('app.string.sentinel_card_unit'))
            .fontSize(14)
            .fontColor($r('sys.color.font_secondary'))
            .margin({ bottom: 14 })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        this.Hairline()
        Column() {
          ForEach(this.displayItems(), (item: CardItem) => {
            this.PairRow(item)
          }, (item: CardItem) => item.name)
        }
        .width('100%')
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Row({ space: 6 }) {
          if (this.stale) {
            Text($r('app.string.sentinel_card_stale'))
              .fontSize(11)
              .fontColor($r('sys.color.font_tertiary'))
          } else {
            if (this.count > LIST_LIMIT) {
              Text($r('app.string.sentinel_card_more', this.count - LIST_LIMIT))
                .fontSize(11)
                .fontColor($r('sys.color.font_tertiary'))
            }
            Text($r('app.string.sentinel_card_hint'))
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
    } else if (this.effectiveDimension === DIM_2_4) {
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
          ForEach(this.displayItems(), (item: CardItem) => {
            this.PairRow(item)
          }, (item: CardItem) => item.name)
          Blank()
          Text($r('app.string.sentinel_card_hint'))
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
    } else {
      // 2*2：hero + 单行包名串（top3，「等 N 个」后缀由资源格式化），页脚收底
      Column({ space: 4 }) {
        this.HeroRow()
        this.UnitLine()
        Blank()
        Row({ space: 4 }) {
          Text(this.topNames())
            .fontSize(12)
            .fontColor($r('sys.color.font_tertiary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (this.count > TOP_LIMIT) {
            Text($r('app.string.sentinel_card_more', this.count - TOP_LIMIT))
              .fontSize(12)
              .fontColor($r('sys.color.font_tertiary'))
          }
        }
        .width('100%')
        this.FooterLine()
      }
      .width('100%')
      .height('100%')
    }
  }

  build() {
    Column() {
      if (!this.hasSnapshot) {
        this.GuideBody()
      } else if (this.count === 0) {
        this.ZeroBody()
      } else {
        this.LiveBody()
      }
    }
    .width('100%')
    .height('100%')
    // 外边距：4*4 用 20vp 的大方卡呼吸感，2*2/2*4 用 16vp 保小面积容量（spec §4.1 口径的规格化落地）
    .padding(this.effectiveDimension === DIM_4_4 ? 20 : 16)
    .alignItems(HorizontalAlign.Start)
    // 引导/零更新态由各自 body 自居中；正常态顶对齐 + Blank 把页脚收底
    .justifyContent(this.hasSnapshot && this.count > 0 ? FlexAlign.Start : FlexAlign.Center)
    .onClick(() => {
      this.openPackages()
    })
  }
}
