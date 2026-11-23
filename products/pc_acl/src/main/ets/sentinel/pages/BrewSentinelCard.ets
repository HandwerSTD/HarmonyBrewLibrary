// postCardAction 是卡片页的全局函数（ArkUI 声明），不 import

let storage = new LocalStorage()

/**
 * 更新哨兵的桌面卡片（2*2，spec §4）。
 *
 * 数据全部来自 FormBindingData 的 LocalStorageProp（BrewSentinelService 推送），卡片页
 * **零命令调用**——唯一的交互是 postCardAction 的 router 事件，把用户「带去」升级队列，
 * 绝不执行命令（G4/G5；`hmosword-build/brew-sentinel/audit_no_brew_in_touchpoints.mjs` 扫描对象）。
 *
 * 三态（G1/G9）：
 *   - 引导态（无快照）：提示添加后自动跟踪，不显示 0 假数据；
 *   - 陈旧态（快照超 24h）：保留数字但降显「打开应用刷新」，不假装实时；
 *   - 正常态：待升级数大字 + 前 3 个包名（多则「等 N-3 个」）+ 底部「截至 HH:mm」。
 */
@Entry(storage)
@Component
struct BrewSentinelCard {
  @LocalStorageProp('sentinelFormId') formId: string = ''
  @LocalStorageProp('sentinelHasSnapshot') hasSnapshot: boolean = false
  @LocalStorageProp('sentinelCount') count: number = 0
  @LocalStorageProp('sentinelTopNames') topNames: string = ''
  @LocalStorageProp('sentinelAsOfText') asOfText: string = ''
  @LocalStorageProp('sentinelStale') stale: boolean = false

  /** 数量行文案：0 也照常显示（引导态由 hasSnapshot 分支负责，不在这里再判） */
  private countText(): ResourceStr {
    return $r('app.string.sentinel_card_count', this.count)
  }

  /** 「等 N-3 个」。不超过 3 个时返回 undefined，不渲染后缀 */
  private moreText(): ResourceStr | undefined {
    if (this.count <= 3) {
      return undefined
    }
    return $r('app.string.sentinel_card_more', this.count - 3)
  }

  /** 点卡片直达升级队列（G2）。路由参数消费端在 MineHomeView（经 PcAbility 落 AppStorage） */
  private openPackages(): void {
    postCardAction(this, {
      action: 'router',
      abilityName: 'PcAbility',
      params: {
        'sentinel_route': 'MinePackagesView'
      }
    })
  }

  @Builder
  GuideBody() {
    Text($r('app.string.sentinel_card_empty'))
      .fontSize($r('sys.float.Body_M'))
      .fontColor($r('sys.color.font_secondary'))
      .textAlign(TextAlign.Center)
      .padding({ left: $r('sys.float.padding_level4'), right: $r('sys.float.padding_level4') })
  }

  @Builder
  CountBody() {
    Text(this.countText())
      .fontSize($r('sys.float.Title_XL'))
      .fontWeight(FontWeight.Bold)
      .fontColor($r('sys.color.font_primary'))
      .maxLines(2)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
    Text($r('app.string.sentinel_card_stale'))
      .fontSize($r('sys.float.Body_S'))
      .fontColor($r('sys.color.font_tertiary'))
      .margin({ top: $r('sys.float.padding_level1') })
  }

  @Builder
  LiveBody() {
    Text(this.countText())
      .fontSize($r('sys.float.Title_XL'))
      .fontWeight(FontWeight.Bold)
      .fontColor($r('sys.color.font_primary'))
      .maxLines(2)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
    Row({ space: 4 }) {
      Text(this.topNames)
        .fontSize($r('sys.float.Body_S'))
        .fontColor($r('sys.color.font_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (this.moreText() !== undefined) {
        Text(this.moreText())
          .fontSize($r('sys.float.Body_S'))
          .fontColor($r('sys.color.font_tertiary'))
      }
    }
    .width('100%')
    .margin({ top: $r('sys.float.padding_level1') })
    Text($r('app.string.sentinel_card_asof', this.asOfText))
      .fontSize($r('sys.float.Body_XS'))
      .fontColor($r('sys.color.font_tertiary'))
      .margin({ top: $r('sys.float.padding_level2') })
  }

  build() {
    Column() {
      if (!this.hasSnapshot) {
        this.GuideBody()
      } else if (this.stale) {
        this.CountBody()
      } else {
        this.LiveBody()
      }
    }
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .width('100%')
    .height('100%')
    .padding($r('sys.float.padding_level6'))
    .onClick(() => {
      this.openPackages()
    })
  }
}
