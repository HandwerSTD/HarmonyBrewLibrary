/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { common } from '@kit.AbilityKit';
import { TextModifier } from '@kit.ArkUI';
import { HdsListItemCard, PrefixCustomBuilder, SuffixCustomBuilder } from '@kit.UIDesignKit';
import { BreakpointType, CommonConstants, GlobalInfoModel, PageEnum, ResourceUtil, StorageKey } from '@ohos/common';
import { BrewSourceHealth, BrewSourceReach } from '@ohos/brewcommon';
import {
  BrewSourceClearEvent,
  BrewSourceDeleteEvent,
  BrewSourceInitEvent,
  BrewSourceRefreshEvent,
  BrewSourceSettingVM,
} from '../viewmodel/BrewSourceSettingVM';
import { BrewSourceEditParams, BrewSourceRow, BrewSourceSettingState } from '../viewmodel/BrewSourceSettingState';
import { BrewSourceIcon } from '../component/BrewSourceIcon';

/** 卡片内部的左右内缩。与 HDS 列表项的内容内缩同值，保证标题行与下方状态区、操作区左对齐 */
const CARD_INSET: Resource = $r('sys.float.padding_level4');
/**
 * 分割线粗细。`Divider.strokeWidth()` 只收 `number | string`（**不收 `Resource`**，与
 * `List.divider()` 的 `strokeWidth` 不同），所以这里用字面量，取值与 `app.float.mine_divider` 一致。
 */
const DIVIDER_STROKE: string = '0.5px';
/** 胶囊按钮高度。与「我的」页及其它二级页的操作按钮同高 */
const ACTION_BUTTON_HEIGHT: number = 32;
/**
 * 底部悬浮「新增数据源」按钮的让位高度（vp）。
 *
 * 按钮是 `Stack` 里的浮层、不参与 `List` 的布局，所以必须由 `List` 的 `bottom` padding
 * 把这段空间预留出来 —— 否则最后一张卡片会被按钮压住（按钮 40 + 下留白 8 + 呼吸 24）。
 */
const BOTTOM_BUTTON_RESERVE: number = 72;

/**
 * 是否在卡片上渲染**数据就绪行**（两轴里的运行期那一轴）。
 *
 * 暂时关掉：轴本身、判定（`BrewSourceStore.healthState`）、清空路径（`resetDataHealth`）
 * 与自检都在位，只是先不上屏 —— 两行同时出现时卡片明显变高，而数据行的视觉层级
 * （次要色 vs 状态行）还需要再定。
 *
 * 重新打开只需把它改成 `true`：渲染代码与文案都保留着，不需要改其它任何地方。
 */
const SHOW_SOURCE_DATA_LINE: boolean = false;

/**
 * 「我的 - 设置 - 数据源」。
 *
 * ## 卡片结构（自上而下）
 *
 * ```
 * ┌──────────────────────────────────────────┐
 * │ [图标] 名称                    [使用中][内置] │  标题行（HDS 列表项，与其余页面同款）
 * │        地址                                │
 * │ ──────────────────────────────────────── │  分割线
 * │ ✓ 连接正常 · HTTP 200                      │  状态区（探测中 / 探测结果 / 常驻连通性）
 * │ [激活] [测试连接]                    [⋯]   │  操作区（主操作常驻，维护类收进「更多」）
 * └──────────────────────────────────────────┘
 * ```
 *
 * 状态区原本还有第二行「数据：已就绪 / 目录未获取」，现在由 `SHOW_SOURCE_DATA_LINE`
 * 关着（见该常量的注释）——下面第 1 条描述的是打开后的形态。
 *
 * ## 三个刻意的取舍
 *
 * 1. **状态区最多两行，两个正交维度各占一行**：
 *    上行 = **连通性**（探测：测试连接 / 上次测试的持久结论）；
 *    下行 = **数据就绪**（运行期取数：目录 / 全量包 / 单条文档），**只对会话激活源渲染**
 *    （当前由 `SHOW_SOURCE_DATA_LINE` 关着）。
 *    为何拆开：探测与取数是两件不相干的事，挤进一个槽位后，「点测试连接说可用、列表说部分可用」
 *    看起来就是自相矛盾，而用户实际看到的结论取决于他刚才点过什么、进过哪些页面 ——
 *    那是下载进度，不是连通性（见 `BrewSourceReach` / `BrewSourceHealth` 注释）。
 * 2. **常驻状态不加底色**。它每张卡都有，一旦加底色整页就变成一排色块；
 *    只有「探测中 / 探测结果」这两个**临时**状态才用底色条，这样它们才跳得出来。
 * 3. **维护类操作收进「更多」菜单**。六个平铺按钮里，日常只有「激活 / 测试连接」会被用到，
 *    其余三个（编辑 / 清空缓存 / 删除）是低频且危险的（删除、清空不可撤销），
 *    平铺既挤占标题宽度、又让误触成本变高。
 */
@Component
export struct BrewSourceSettingView {
  viewModel: BrewSourceSettingVM = BrewSourceSettingVM.getInstance();
  @State state: BrewSourceSettingState = this.viewModel.getState();
  @StorageProp(StorageKey.GLOBAL_INFO) globalInfoModel: GlobalInfoModel =
    AppStorage.get(StorageKey.GLOBAL_INFO) ?? new GlobalInfoModel();
  private pathStack?: NavPathStack;

  aboutToAppear(): void {
    // 注入 context 提供者：VM 属于数据层、拿不到 `UIAbilityContext`，重启必须由 UI 侧取给它
    this.viewModel.contextProvider = () => {
      return this.getUIContext().getHostContext() as common.UIAbilityContext;
    };
    this.viewModel.sendEvent(new BrewSourceInitEvent());
  }

  private handleOnReady(ctx: NavDestinationContext): void {
    this.pathStack = ctx?.pathStack;
  }

  private openEditor(id: string, name: string, url: string, builtin: boolean): void {
    if (this.pathStack === undefined) {
      return;
    }
    const params: BrewSourceEditParams = {
      id: id,
      name: name,
      url: url,
      builtin: builtin,
    };
    this.pathStack.pushPath({
      name: PageEnum.BREW_SOURCE_EDIT_VIEW,
      param: params,
    });
  }

  /** 内容左右内缩。与「我的」页及其它二级页同一口径（sm 8 / md 12 / lg 16） */
  private contentInset(): Length {
    return new BreakpointType<Length>({
      sm: $r('sys.float.padding_level8'),
      md: $r('sys.float.padding_level12'),
      lg: $r('sys.float.padding_level16'),
    }).getValue(this.globalInfoModel.widthBreakpoint);
  }

  /** 胶囊圆角：侧边栏（2in1）用固定圆角，其余用胶囊 —— 与 chips / 其它操作按钮同一规则 */
  private capsuleRadius(): Length {
    return AppStorage.get<boolean>(StorageKey.IS_SIDEBAR_LAYOUT) ?
      $r('sys.float.corner_radius_level4') : '50%';
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.Bottom }) {
        List({ space: CommonConstants.SPACE_8 }) {
          ForEach(this.state.rows, (row: BrewSourceRow) => {
            ListItem() {
              this.SourceCard(row)
            }
          }, (row: BrewSourceRow) => row.source.id)
        }
        .width(CommonConstants.FULL_PERCENT)
        .height(CommonConstants.FULL_PERCENT)
        .padding({
          left: this.contentInset(),
          right: this.contentInset(),
          top: $r('sys.float.padding_level6'),
          bottom: BOTTOM_BUTTON_RESERVE,
        })

        Column() {
          this.AddButton()
        }
        .width(CommonConstants.FULL_PERCENT)
        .padding({
          left: this.contentInset(),
          right: this.contentInset(),
          bottom: $r('sys.float.padding_level8'),
        })
      }
      .width(CommonConstants.FULL_PERCENT)
      .height(CommonConstants.FULL_PERCENT)
    }
    .title($r('app.string.brew_source_title'))
    .padding({ top: $r('sys.float.padding_level4') })
    .backgroundColor($r('sys.color.background_secondary'))
    .onReady((ctx: NavDestinationContext) => this.handleOnReady(ctx))
    .onShown(() => {
      this.viewModel.sendEvent(new BrewSourceRefreshEvent());
    })
  }

  /**
   * 必须包一层 `@Builder`，不能在 `PrefixCustomBuilder` 的箭头里直接写组件调用
   * （同 `BrewLocalPackageRow.PackageIconBuilder`）。
   *
   * 图标本身是独立 `@Component`（`BrewSourceIcon`），边距也在它内部 —— 两个条件都必需，
   * 否则 `HdsListItemCard` 的前缀槽位量不到 margin、方块会溢出并压住正文，
   * 详见 `BrewSourceIcon` 的文件头注释。
   */
  @Builder
  SourceIconBuilder() {
    BrewSourceIcon()
  }

  /** 小号状态标签（「使用中 / 内置」）。用圆角块而不是纯文字，避免和标题、地址混成一片 */
  @Builder
  StatusPill(label: ResourceStr, background: ResourceColor, fontColor: ResourceColor) {
    Text(label)
      .fontSize($r('sys.float.Body_S'))
      .fontColor(fontColor)
      .maxLines(1)
      .ellipsisMode(EllipsisMode.END)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .padding({
        left: $r('sys.float.padding_level2'),
        right: $r('sys.float.padding_level2'),
        top: $r('sys.float.padding_level1'),
        bottom: $r('sys.float.padding_level1'),
      })
      .borderRadius($r('sys.float.corner_radius_level2'))
      .backgroundColor(background)
  }

  @Builder
  SourceSuffixBuilder(row: BrewSourceRow) {
    Row({ space: CommonConstants.SPACE_4 }) {
      if (row.isSessionActive) {
        this.StatusPill($r('app.string.brew_source_in_use'), $r('sys.color.ohos_id_color_emphasize'),
          $r('sys.color.font_on_primary'))
      }
      if (row.source.builtin) {
        this.StatusPill($r('app.string.brew_source_builtin'), $r('sys.color.comp_background_tertiary'),
          $r('sys.color.font_secondary'))
      }
    }
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  SourceCard(row: BrewSourceRow) {
    Column() {
      HdsListItemCard({
        prefixItem: new PrefixCustomBuilder(() => {
          this.SourceIconBuilder();
        }),
        textItem: {
          primaryText: {
            text: row.source.name,
            modifier: new TextModifier()
              .maxLines(1)
              .ellipsisMode(EllipsisMode.END)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .fontColor($r('sys.color.font_primary')),
          },
          secondaryText: {
            text: row.source.baseUrl,
            modifier: new TextModifier()
              .maxLines(1)
              .ellipsisMode(EllipsisMode.END)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .fontColor($r('sys.color.font_secondary')),
          },
        },
        suffixItem: new SuffixCustomBuilder(() => {
          this.SourceSuffixBuilder(row);
        }),
        cardHeight: 64,
        // 前缀边距给 0：左右边距由 `BrewSourceIcon` 内部给（`boxMarginStart` / `boxMarginEnd`）。
        // 不能改成在这里给 —— `cardPrefixMargin` 只推开槽位起点，不含在槽位测量宽度里，
        // 给了也不会形成「图标 ↔ 正文」的间距。后缀仍用 `CARD_INSET` 以对齐分割线右端。
        cardPrefixMargin: $r('sys.float.padding_level0'),
        cardSuffixMargin: CARD_INSET,
        cardBorderRadius: 0,
        cardBackgroundColor: $r('sys.color.ohos_id_color_background_transparent'),
      })

      // 标题行与状态 / 操作区之间用分割线断开：上面是「这个源是谁」，下面是「它现在怎么样、能做什么」
      Divider()
        .strokeWidth(DIVIDER_STROKE)
        .color($r('sys.color.comp_divider'))
        .margin({ left: CARD_INSET, right: CARD_INSET })

      // 状态区自己带上下内缩与底色，这里只负责左右对齐到卡片内缩
      Column() {
        this.StatusArea(row)
      }
      .width(CommonConstants.FULL_PERCENT)
      .alignItems(HorizontalAlign.Start)
      .padding({
        left: CARD_INSET,
        right: CARD_INSET,
        top: $r('sys.float.padding_level4'),
        bottom: $r('sys.float.padding_level2'),
      })

      this.Actions(row)
    }
    .width(CommonConstants.FULL_PERCENT)
    .backgroundColor($r('sys.color.comp_background_primary'))
    .borderRadius($r('sys.float.corner_radius_level8'))
    .clip(true)
  }

  /**
   * 状态区。**最多两行**（见组件头注释第 1 条）：上行连通性、下行数据就绪。
   *
   * 图标槽只表达**上行**（用户刚做过那个动作的就是连通性）；下行用次要色，
   * 永远不抢图标 —— 否则“数据未就绪”会被误认为“连接失败”。
   * 图标槽在三种上行状态下都占满 `Title_S` 一格，文案的起始位置才不会左右跳。
   */
  @Builder
  StatusArea(row: BrewSourceRow) {
    Row() {
      if (this.isProbing(row)) {
        LoadingProgress()
          .width($r('sys.float.Title_S'))
          .height($r('sys.float.Title_S'))
          .color($r('sys.color.icon_secondary'))
      } else {
        SymbolGlyph(this.statusIcon(row))
          .fontSize($r('sys.float.Title_S'))
          .fontColor([this.statusTint(row)])
      }

      Column({ space: CommonConstants.SPACE_2 }) {
        // ---------- 第一行：连通性（探测） ----------
        if (this.isProbing(row)) {
          Text($r('app.string.brew_source_probing'))
            .fontSize($r('sys.float.Body_S'))
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
            .ellipsisMode(EllipsisMode.END)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        } else if (this.hasProbeResult(row)) {
          // 成功一行说完（带 HTTP 码）；失败把原因和状态码分成两行，原因本身是完整句子、需要换行
          if (this.state.probeResultOk) {
            Text(this.state.probeResultCode > 0 ?
              $r('app.string.brew_source_connect_ok_http', this.state.probeResultCode) :
              $r('app.string.brew_source_test_ok'))
              .fontSize($r('sys.float.Body_S'))
              .fontWeight(FontWeight.Medium)
              .fontColor(this.statusTint(row))
              .maxLines(2)
              .ellipsisMode(EllipsisMode.END)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          } else {
            // 「连接失败：」与原因必须是同一个 Text 的两个 Span：用两个 Text 拼会在
            // 换行处断开成两块、各自独立折行，读起来像两句话
            Text() {
              Span($r('app.string.brew_source_connect_failed_prefix'))
              Span(this.viewModel.probeReasonText())
            }
            .fontSize($r('sys.float.Body_S'))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.statusTint(row))
            .maxLines(2)
            .ellipsisMode(EllipsisMode.END)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        } else if (row.reach === BrewSourceReach.FAILING) {
          // 持久结论：上次测试就没通（本进程没再测过）
          Text() {
            Span($r('app.string.brew_source_connect_failed_prefix'))
            Span(this.viewModel.probeReasonTextOf(row.reachReason))
          }
          .fontSize($r('sys.float.Body_S'))
          .fontWeight(FontWeight.Medium)
          .fontColor(this.statusTint(row))
          .maxLines(2)
          .ellipsisMode(EllipsisMode.END)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        } else {
          Text(this.reachText(row))
            .fontSize($r('sys.float.Body_S'))
            .fontColor(this.statusTint(row))
            .maxLines(1)
            .ellipsisMode(EllipsisMode.END)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }

        if (!this.isProbing(row) && this.hasProbeResult(row) && !this.state.probeResultOk &&
          this.state.probeResultCode > 0) {
          Text($r('app.string.brew_source_probe_http_status', this.state.probeResultCode))
            .fontSize($r('sys.float.Body_S'))
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
            .ellipsisMode(EllipsisMode.END)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }

        // ---------- 第二行：数据就绪（运行期） ----------
        // 只对会话激活源渲染：取数只发给它，别的源从没被请求过，渲染出来只会是误导。
        // 与探测结果**同时**显示（不互斥）—— 这正是本次拆分要的：「刚测过是通的」与
        // 「数据还没取到」是两条独立事实，不是矛盾。
        // `SHOW_SOURCE_DATA_LINE` 暂时关着（见常量注释），打开后本块直接生效。
        if (SHOW_SOURCE_DATA_LINE && row.isSessionActive) {
          Text() {
            Span($r('app.string.brew_source_data_prefix'))
            Span(this.dataText(row))
          }
          .fontSize($r('sys.float.Body_S'))
          .fontColor(this.dataTint(row))
          .maxLines(2)
          .ellipsisMode(EllipsisMode.END)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      // 图标 ↔ 正文用 level4（实测间距 8vp），与列表行同级；原先的 level2（4vp）太贴
      .margin({ left: $r('sys.float.padding_level4') })
    }
    .width(CommonConstants.FULL_PERCENT)
    .alignItems(VerticalAlign.Top)
    .padding({
      left: $r('sys.float.padding_level3'),
      right: $r('sys.float.padding_level3'),
      top: $r('sys.float.padding_level2'),
      bottom: $r('sys.float.padding_level2'),
    })
    .borderRadius($r('sys.float.corner_radius_level6'))
    .backgroundColor(this.statusBackground(row))
  }

  @Builder
  Actions(row: BrewSourceRow) {
    Row({ space: CommonConstants.SPACE_4 }) {
      if (!row.isSessionActive) {
        this.CapsuleButton($r('app.string.brew_source_activate'),
          () => this.confirmActivate(row), !this.isProbing(row))
      }
      this.CapsuleButton($r('app.string.brew_source_test'),
        () => this.viewModel.testConnection(row.source.id), !this.isProbing(row))
      Blank()
      this.MoreButton(row)
    }
    .width(CommonConstants.FULL_PERCENT)
    .alignItems(VerticalAlign.Center)
    .padding({
      left: CARD_INSET,
      right: CARD_INSET,
      top: $r('sys.float.padding_level2'),
      bottom: CARD_INSET,
    })
  }

  /**
   * 主操作胶囊按钮。
   *
   * `enabled` 由调用方给：探测进行中必须同时锁住「激活」与「测试连接」——
   * 两条路径共用 `state.probingId`，重复点会让后一次结果覆盖前一次，用户看到的原因与目标源对不上。
   */
  @Builder
  CapsuleButton(label: ResourceStr, action: () => void, enabled: boolean) {
    Button(label)
      .height(ACTION_BUTTON_HEIGHT)
      .fontSize($r('sys.float.Body_M'))
      .fontWeight(FontWeight.Medium)
      .fontColor($r('sys.color.font_primary'))
      .backgroundColor($r('sys.color.comp_background_tertiary'))
      .borderRadius(this.capsuleRadius())
      .padding({ left: $r('sys.float.padding_level6'), right: $r('sys.float.padding_level6') })
      .enabled(enabled)
      .onClick(action)
  }

  /**
   * 「更多」入口。低频与危险操作（编辑 / 清空缓存 / 删除）收在这里，
   * 让每张卡的主操作只有「激活 / 测试连接」两个。
   */
  @Builder
  MoreButton(row: BrewSourceRow) {
    Button({ type: ButtonType.Normal }) {
      SymbolGlyph($r('sys.symbol.dot_grid_2x2'))
        .fontSize($r('sys.float.Title_S'))
        .fontColor([$r('sys.color.icon_secondary')])
    }
    .height(ACTION_BUTTON_HEIGHT)
    // 正方形：宽度跟高度同值。写成 `+ SPACE_8` 会得到 40×32 的扁矩形，
    // 在一排同高的胶囊按钮旁边很明显（真机实测）
    .width(ACTION_BUTTON_HEIGHT)
    .borderRadius(this.capsuleRadius())
    .backgroundColor($r('sys.color.comp_background_tertiary'))
    .bindMenu(this.moreMenuItems(row))
    .accessibilityText(this.moreAccessibilityLabel())
  }

  /**
   * 「更多」菜单项。
   *
   * 用 `MenuElement[]` 而不是 `Menu()` + `MenuItem` 的 CustomBuilder。后者要靠
   * `.bindMenu(() => this.MoreMenu(row))` 这种「箭头函数包 @Builder」的写法传参，
   * 而 @Builder 只在 build 上下文里会被编译成视图创建代码 —— 包在普通箭头里会退化成
   * 一次空调用：**不报错、也不弹菜单**（真机实测，点下去毫无反应）。
   * `MenuElement[]` 是纯数据，在 build 里现算，没有这层编译期语义。
   *
   * 代价：`MenuElement` 没有 `contentFontColor`，「删除」不能标红。
   * 破坏性提示改由二次确认弹窗承担（它的确认键本来就是 warning 色）。
   */
  private moreMenuItems(row: BrewSourceRow): MenuElement[] {
    const items: MenuElement[] = [];
    items.push({
      value: $r('app.string.brew_source_edit'),
      action: () => this.openEditor(row.source.id, row.source.name, row.source.baseUrl, row.source.builtin),
    });
    items.push({
      value: $r('app.string.brew_source_clear_cache'),
      action: () => this.confirmClearCache(row),
    });
    // 内置源与当前会话激活源都不可删：前者是回退底牌，后者「切走本身就是重启」，重启后再删
    if (!row.source.builtin && !row.isSessionActive) {
      items.push({
        value: $r('app.string.brew_source_delete'),
        action: () => this.confirmDelete(row),
      });
    }
    return items;
  }

  @Builder
  AddButton() {
    Button($r('app.string.brew_source_add'))
      .width(CommonConstants.FULL_PERCENT)
      .height(CommonConstants.SPACE_40)
      .fontSize($r('sys.float.Body_L'))
      .fontWeight(FontWeight.Medium)
      .borderRadius(this.capsuleRadius())
      .onClick(() => this.openEditor('', '', '', false))
  }

  /**
   * 「更多」按钮的无障碍文案。`accessibilityText` 只收 `string`（不接受 `ResourceStr`），
   * 所以这里把资源解成文本；拿不到 context 时返回空串，不阻断渲染。
   */
  private moreAccessibilityLabel(): string {
    const context: Context | undefined = this.getUIContext().getHostContext();
    if (context === undefined) {
      return '';
    }
    return ResourceUtil.getResourceString(context, $r('app.string.brew_source_more'));
  }

  /** 这条卡片是否正在探测（激活与「测试连接」共用） */
  private isProbing(row: BrewSourceRow): boolean {
    return this.state.probingId === row.source.id;
  }

  /**
   * 这条卡片是否有属于自己的探测结果。
   *
   * 必须比对源 id：结果只属于被探测的那一个源，否则激活源 B 失败时所有卡片都会显示同一条原因。
   */
  private hasProbeResult(row: BrewSourceRow): boolean {
    return !this.isProbing(row) && this.state.probeResultId === row.source.id;
  }

  /**
   * 状态图标。只表达**上行**（连通性）：临时探测结果优先，其次上次探测的持久结论。
   * 数据轴不参与 —— 数据未就绪不是“连接失败”，图标不能把它报成错误。
   */
  private statusIcon(row: BrewSourceRow): Resource {
    if (this.hasProbeResult(row)) {
      return this.state.probeResultOk ?
        $r('sys.symbol.checkmark_circle') : $r('sys.symbol.questionmark_circle');
    }
    if (row.reach === BrewSourceReach.OK) {
      return $r('sys.symbol.checkmark_circle');
    }
    if (row.reach === BrewSourceReach.UNKNOWN) {
      return $r('sys.symbol.info_circle');
    }
    return $r('sys.symbol.exclamationmark_circle');
  }

  /**
   * 上行（连通性）主色：失败 / 未验证 / 正常。
   * 已探测过的源才可能拿到 warn 色，没测过的永远中性 —— 否则新源一进来就一片红。
   */
  private statusTint(row: BrewSourceRow): ResourceColor {
    if (this.isProbing(row)) {
      return $r('sys.color.font_secondary');
    }
    if (this.hasProbeResult(row)) {
      return this.state.probeResultOk ? $r('sys.color.brand') : $r('sys.color.warning');
    }
    if (row.reach === BrewSourceReach.OK) {
      return $r('sys.color.brand');
    }
    if (row.reach === BrewSourceReach.UNKNOWN) {
      return $r('sys.color.font_tertiary');
    }
    return $r('sys.color.warning');
  }

  /**
   * 下行（数据就绪）用色。**恒为次要色**，除非当前真站着通道错误才给 warning ——
   * 它永远不抢图标、也不使用 brand 色（“数据已就绪”不是一个需要庆祝的状态）。
   */
  private dataTint(row: BrewSourceRow): ResourceColor {
    return row.dataState === BrewSourceHealth.PARTIAL ?
      $r('sys.color.warning') : $r('sys.color.font_secondary');
  }

  /**
   * 状态条底色。只有**临时**状态（探测中 / 探测结果）给底色，常驻健康状态保持透明 ——
   * 见组件头注释第 2 条。
   */
  private statusBackground(row: BrewSourceRow): ResourceColor {
    if (this.isProbing(row)) {
      return $r('sys.color.comp_background_tertiary');
    }
    if (this.hasProbeResult(row)) {
      return this.state.probeResultOk ? $r('sys.color.comp_background_tertiary') :
        $r('sys.color.comp_background_warning_secondary');
    }
    return Color.Transparent;
  }

  private confirmActivate(row: BrewSourceRow): void {
    // 弹窗要点名目标源（name + baseUrl）：用户可能同时配了好几个镜像，
    // 只说「切换会重启」等于没说是切到哪个（spec §7.2）
    this.getUIContext().showAlertDialog({
      title: $r('app.string.brew_source_activate'),
      message: $r('app.string.brew_source_activate_confirm', row.source.name, row.source.baseUrl),
      primaryButton: {
        value: $r('app.string.brew_source_cancel'),
        action: () => {
        }
      },
      secondaryButton: {
        value: $r('app.string.brew_source_activate_and_restart'),
        action: () => {
          this.viewModel.activate(row.source.id);
        }
      }
    });
  }

  private confirmDelete(row: BrewSourceRow): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.brew_source_delete'),
      message: $r('app.string.brew_source_delete_confirm'),
      primaryButton: {
        value: $r('app.string.brew_source_cancel'),
        action: () => {
        }
      },
      secondaryButton: {
        value: $r('app.string.brew_source_delete'),
        fontColor: $r('sys.color.warning'),
        action: () => this.viewModel.sendEvent(new BrewSourceDeleteEvent(row.source.id))
      }
    });
  }

  /** 清空单个源的缓存。二次确认的理由：它不可撤销，且会重置当前会话的内存缓存 */
  private confirmClearCache(row: BrewSourceRow): void {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.brew_source_clear_cache'),
      message: $r('app.string.brew_source_clear_confirm'),
      primaryButton: {
        value: $r('app.string.brew_source_cancel'),
        action: () => {
        }
      },
      secondaryButton: {
        value: $r('app.string.brew_source_clear_cache'),
        fontColor: $r('sys.color.warning'),
        action: () => this.viewModel.sendEvent(new BrewSourceClearEvent(row.source.id))
      }
    });
  }

  /**
   * 上行（连通性）文案：没测过 / 测过且通。失败情形在 `StatusArea` 里用
   * “连接失败：+ 原因”两个 Span 渲染，不走这里（前缀文案与原因必须同一个 Text）。
   */
  private reachText(row: BrewSourceRow): ResourceStr {
    if (row.reach === BrewSourceReach.OK) {
      return $r('app.string.brew_source_test_ok');
    }
    return $r('app.string.brew_source_reach_unknown');
  }

  /**
   * 下行（数据就绪）文案。**只描述取数结果**，与连通性无关：
   * 失败通路 → “哪条通路挂了”；否则说清楚「还缺什么」，而不是笼统的“不正常”。
   *
   * “还缺什么”必须区分目录与索引：两者分工不同（目录给成员与安装量、全量包给分类用的 desc），
   * 只说“未就绪”会让用户无法判断该不该等下去。
   */
  private dataText(row: BrewSourceRow): ResourceStr {
    if (row.dataErrorKind === 'catalog') {
      return $r('app.string.brew_source_health_err_catalog');
    }
    if (row.dataErrorKind === 'meta') {
      return $r('app.string.brew_source_health_err_meta');
    }
    if (row.dataErrorKind === 'hydrate') {
      return $r('app.string.brew_source_health_err_hydrate');
    }
    if (!row.dataCatalogReady) {
      return $r('app.string.brew_source_data_no_catalog');
    }
    if (!row.dataIndexReady) {
      return $r('app.string.brew_source_data_no_index');
    }
    return $r('app.string.brew_source_data_ready');
  }
}

@Builder
export function BrewSourceSettingBuilder() {
  BrewSourceSettingView()
}
