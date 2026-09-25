import { curves } from '@kit.ArkUI';
import { sensor } from '@kit.SensorServiceKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '@ohos/common';
import { codeList, delayParams } from '../constants/FormCardConstants';

const TAG: string = '[WidgetLiveFormCode]';

@Component
export struct WidgetLiveCardCodeComponent {
  sensor: sensor.Sensor | null = null;
  @State codeSize: number = 200;
  @State tx: TranslateOptions[] = [
    { x: 0, y: 0 },
    { x: 0, y: 0 },
    { x: 0, y: 0 },
    { x: 0, y: 0 },
    { x: 0, y: 0 },
    { x: 0, y: 0 },
    { x: 0, y: 0 },
    { x: 0, y: 0 },
  ];
  @State sx: ScaleOptions[] = [
    { x: 0, y: 0 },
    { x: 0, y: 0 },
    { x: 0, y: 0 },
    { x: 0, y: 0 },
    { x: 0, y: 0 },
    { x: 0, y: 0 },
    { x: 0, y: 0 },
    { x: 0, y: 0 },
  ];
  @State codeList: string[] = codeList;
  @State delayParams: number[] = delayParams;
  private danmakuDirection: number = 8; // the number of clock in which direction code flies.

  build() {
    this.buildCodesAnimate();
  }


  @Builder
  buildCodesAnimate() {
    ForEach(this.codeList, (imageName: string, idx: number) => {
      this.buildCodeImage(imageName, idx);
    })
  }

  @Builder
  buildCodeImage(imageResource: string, tsIdx: number) {
    Image($r(`app.media.${imageResource}`))
      .rotate({
        z: 1,
        angle: 0,
      })
      .width(`${this.codeSize}%`)
      .alignRules(setAlignRules('center', VerticalAlign.Center, 'middle', HorizontalAlign.Center))
      .translate(this.tx[tsIdx])
      .scale(this.sx[tsIdx])
      .opacity(0.65)
      .onAppear(() => {
        Logger.info(TAG, `CodeImage.onAppear ${tsIdx}, ${imageResource}`);
        this.getUIContext().animateTo({
          delay: tsIdx >= 0 && tsIdx < this.delayParams.length ? this.delayParams[tsIdx] : 0,
          duration: 2650,
          playMode: PlayMode.Normal,
          iterations: -1,
          curve: curves.cubicBezierCurve(0.00, 0.50, 1.00, 1.00)
        }, () => {
          Logger.info(TAG, `CodeImage.afterAnimateTo.`);
          this.sx[tsIdx] = { x: 4.5, y: 4.5 };
          this.tx[tsIdx] = this.getTranslateParam();
          this.danmakuDirection = this.danmakuDirection + 7.62;
          /** A idea that can switch the angle randomly for 0~15 degree to the left or right.
           * this.danmakuDirection += Math.random() - 1;
           * */
        })
      })
  }

  private getTranslateParam(): TranslateOptions {
    // DanmakuDirection is the number of clock position.
    // replace this.DanmakuDirection with Math.random() can make code flies to random direction.
    const aParam: number = this.danmakuDirection / 12 * 2 * Math.PI;
    const ret: TranslateOptions = {
      x: 700 * Math.sin(aParam) + 30,
      y: 200 * Math.cos(aParam)
    };
    return ret;
  }
}

type AlignParam = Record<string, string | VerticalAlign | HorizontalAlign>;

function setAlignRules(verticalName: string, verticalAlign: VerticalAlign,
  horizontalName: string, horizontalAlign: HorizontalAlign): Record<string, AlignParam> {

  let alignRule: Record<string, AlignParam> = {};
  alignRule[verticalName] = { 'anchor': '__container__', 'align': verticalAlign };
  alignRule[horizontalName] = { 'anchor': '__container__', 'align': horizontalAlign };
  return alignRule;
}
