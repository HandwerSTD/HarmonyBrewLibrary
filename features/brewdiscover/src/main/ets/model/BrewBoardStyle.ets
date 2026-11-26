/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { BrewDiscoverBoardKey } from '@ohos/brewcommon';

// 用 string 常量而不是直接跟枚举成员比：ArkTS 对 `string === StringEnum.Member` 的类型检查
// 比 TS 严，走一层 string 常量既保留枚举作为「合法取值」的声明，又不会引入类型告警。
const TRENDING: string = BrewDiscoverBoardKey.TRENDING;
const ALLTIME: string = BrewDiscoverBoardKey.ALLTIME;
// AI 榜卡不是 BrewDiscoverBoardKey 的成员（它是插进 feed 的虚拟榜，见 d4 spec），
// 但大图卡的来源徽章与 AI 榜 Hero 都走本类取 title，所以这里也有一个 string 常量。
// 视图层（BoardCard/BaseView）判「这张榜是不是 AI 榜」也用它，故 export。
export const AI_BOARD: string = 'ai';

/**
 * 榜单的展示属性（标题 / 符号 / 主题色）。
 *
 * 集中在一处，是因为这些值在三个地方要用：卡片头部、卡片 Hero、二级页标题栏。
 * 分散写必然漂移（本项目已经在 chips 与边距上吃过两次）。
 *
 * 符号与颜色都只用**实测有效**的名字与本模块的 color.json：
 * `sys.symbol.*` 写错会在 `CompileArkTS` 阶段报 `Unknown resource name`，
 * 但只有写成 `$r()` 字面量时才会被校验（见 docs/brew-api-design.md §10.6）。
 */
export class BrewBoardStyle {
  public static titleOf(boardKey: string): Resource {
    if (boardKey === AI_BOARD) {
      return $r('app.string.brew_board_ai');
    }
    if (boardKey === ALLTIME) {
      return $r('app.string.brew_board_alltime');
    }
    if (boardKey === BrewDiscoverBoardKey.FRESH) {
      return $r('app.string.brew_board_fresh');
    }
    return $r('app.string.brew_board_trending');
  }

  /** 右上角水印符号。替代真实图片，给纯色块一点纹理 */
  public static symbolOf(boardKey: string): Resource {
    if (boardKey === AI_BOARD) {
      // sparkle 在 sys.symbol 里未确认存在（实测有效的名字才进本文件，见类注释），
      // lightbulb 已被 ai 分类图标使用（BrewFeaturedArtStyle），语义同源
      return $r('sys.symbol.lightbulb');
    }
    if (boardKey === ALLTIME) {
      return $r('sys.symbol.list_checkmark');
    }
    if (boardKey === BrewDiscoverBoardKey.FRESH) {
      return $r('sys.symbol.plus_square_on_square');
    }
    return $r('sys.symbol.bolt_fill');
  }

  /** 渐变起点（上） */
  public static colorStartOf(boardKey: string): Resource {
    if (boardKey === AI_BOARD) {
      return $r('app.color.brew_board_color_ai_start');
    }
    if (boardKey === ALLTIME) {
      return $r('app.color.brew_board_color_alltime_start');
    }
    if (boardKey === BrewDiscoverBoardKey.FRESH) {
      return $r('app.color.brew_board_color_fresh_start');
    }
    return $r('app.color.brew_board_color_trending_start');
  }

  /**
   * 渐变终点（下）。**文字压在这一端**，所以终点色都取得足够深。
   *
   * 约束：终点色对白色 **≥ 4.5:1**（小字阀值）。
   *
   * 历史上它还兼任「行尾『查看』按钮的文字色」，那条已于 2026-09 解耦
   * （按钮固定用 `sys.color.font_emphasize`，见 `BrewDiscoverRow`）——
   * 所以现在终点色**只服务于卡片渐变**，不再需要在浅色行底上当文字。
   *
   * ⚠️ 选色原则：**不要往棕/橄榄走**。起点是亮色、终点又要深到能压白字，
   * 于是橙色压暗必然变棕、绿色压暗必然变橄榄 —— 棕色落在浅色页上会被读成“脏”。
   * 现在的做法是让终点**偏到不发脏的色相**（日落式：黄→绯红 / 浅蓝→深青蓝 / 薄荷→祖母绿），
   * 而不是沿同色相硬压暗。三个末端的 HSV 彩度统一锁在 0.88。
   *
   * 现网实测（2026-09）：trending 4.58:1、alltime 4.57:1、fresh 4.57:1。
   * AI 榜（2026-11）：ai 5.70:1（#C4B5FD → #7C3AED，紫罗兰——不会压成棕/橄榄，
   * 起点取淡薰衣草保持与其余三套同量级的「亮→深」日落式走向）。
   * **改终点色必须重算这个值**：起点可以随便调亮（它不被文字压），但终点调浅会让字读不出来。
   */
  public static colorEndOf(boardKey: string): Resource {
    if (boardKey === AI_BOARD) {
      return $r('app.color.brew_board_color_ai_end');
    }
    if (boardKey === ALLTIME) {
      return $r('app.color.brew_board_color_alltime_end');
    }
    if (boardKey === BrewDiscoverBoardKey.FRESH) {
      return $r('app.color.brew_board_color_fresh_end');
    }
    return $r('app.color.brew_board_color_trending_end');
  }

  /** 卡片右下角「共 N 条」用的包类型名（Formulae / Casks） */
  public static kindLabelOf(kind: string): Resource {
    return kind === 'cask' ? $r('app.string.brew_tab_casks') : $r('app.string.brew_tab_formulae');
  }
}
