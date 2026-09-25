import { formProvider } from '@kit.FormKit';
import { Logger } from '@ohos/common';

const TAG: string = '[WidgetVM]'

export class WidgetViewModel {
  public static setAlignRules(verticalName: string, verticalAlign: VerticalAlign,
    horizontalName: string, horizontalAlign: HorizontalAlign): Record<string, AlignParam> {

    let alignRule: Record<string, AlignParam> = {};
    alignRule[verticalName] = { 'anchor': '__container__', 'align': verticalAlign };
    alignRule[horizontalName] = { 'anchor': '__container__', 'align': horizontalAlign };
    return alignRule;
  }

  public static cancelOverFlow(formId: string) {
    formProvider.cancelOverflow(formId)
      .catch((err: BusinessError) => {
        Logger.error(TAG, `Error ${err.code}: Failed to cancelOverflow. Message: ${err.message}`);
      });
  }
}

type AlignParam = Record<string, string | VerticalAlign | HorizontalAlign>;

@Component
export struct WidgetStaticCard {
  build() {
    RelativeContainer() {
      // Fluffy on the left side
      Image($r('app.media.Fluffy_Ori'))
        .height('100%')
        .alignRules(WidgetViewModel.setAlignRules('bottom', VerticalAlign.Bottom, 'middle', HorizontalAlign.Center))
        .translate({
          x: 0,
        })
      // Text
      Row() {
        Column() {
          Text($r('app.string.widget_hmos_coding_title'))
            .minFontSize(8)
            .maxFontSize(12)
            .fontColor(Color.Black)
            .fontWeight(FontWeight.Medium)
            .margin({
              bottom: 2
            })
          Text($r('app.string.widget_hmos_coding_text'))
            .minFontSize(6)
            .maxFontSize(10)
            .fontColor(Color.Gray)
        }
        .alignItems(HorizontalAlign.Start)
      }
      .alignRules({
        'bottom': { 'anchor': '__container__', 'align': VerticalAlign.Bottom },
        'left': { 'anchor': '__container__', 'align': HorizontalAlign.Start },
        'right': { 'anchor': '__container__', 'align': HorizontalAlign.End },
      })
      .backgroundColor('rgba(255, 255, 255, 0.85)')
      .borderRadius(13)
      .padding({
        top: 6,
        bottom: 6,
        left: 13,
        right: 8,
      })
      .id('row')
      .margin(8)
    }
    .width('100%')
    .height('100%')
    .onClick(() => {
      postCardAction(this, {
        action: 'message',
        abilityName: 'PhoneFormAbility',
        params: {
          message: 'requestOverFlow'
        }
      })
    })
  }
}
