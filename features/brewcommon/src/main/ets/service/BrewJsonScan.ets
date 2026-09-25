/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/** JSON 容器扫描状态。只保留解析 formulae 所需的信息，不构造整棵 JSON 树。 */
interface JsonFrame {
  kind: string;
  key: string;
  expectKey: boolean;
  expectValue: boolean;
}

interface StringToken {
  value: string;
  next: number;
}

interface ScanState {
  ranges: Record<string, number[]>;
  formulaeDepth: number;
  directToken: string;
  directStart: number;
  directDepth: number;
}

/**
 * 纯文本结构感知扫描：返回 payload 中 formulae 对象第一层每个 token 的值区间。
 * 返回区间包含值对象两侧的 JSON 花括号，可直接 substring + JSON.parse。
 *
 * 这里刻意不能用 indexOf：formula 的 desc/name 可能包含另一个 token，而且 payload 是
 * 解包后的普通 JSON；扫描器逐字符跟踪字符串与反斜杠转义，才不会把字符串内容误认成键。
 */
export class BrewJsonScan {
  public static formulaeRanges(payloadJson: string): Record<string, number[]> {
    const state: ScanState = {
      ranges: {}, formulaeDepth: -1, directToken: '', directStart: -1, directDepth: -1,
    };
    const frames: JsonFrame[] = [];
    let position: number = 0;
    while (position < payloadJson.length) {
      const code: number = payloadJson.charCodeAt(position);
      if (code === 32 || code === 9 || code === 10 || code === 13) {
        position++;
        continue;
      }
      if (code === 123) { // {
        const key: string = BrewJsonScan.currentKey(frames);
        const depth: number = frames.length + 1;
        const frame: JsonFrame = { kind: 'object', key: key, expectKey: true, expectValue: false };
        frames.push(frame);
        if (key === 'formulae' && frames.length === 2) {
          state.formulaeDepth = depth;
        } else if (state.formulaeDepth > 0 && frames.length === state.formulaeDepth + 1) {
          state.directToken = key;
          state.directStart = position;
          state.directDepth = depth;
        }
        position++;
        continue;
      }
      if (code === 91) { // [
        const key: string = BrewJsonScan.currentKey(frames);
        const frame: JsonFrame = { kind: 'array', key: key, expectKey: false, expectValue: true };
        frames.push(frame);
        position++;
        continue;
      }
      if (code === 125 || code === 93) { // } or ]
        const frame: JsonFrame | undefined = frames.pop();
        if (frame !== undefined && frame.kind === 'object' &&
          state.directDepth === frames.length + 1 && state.directToken.length > 0) {
          const range: number[] = [state.directStart, position + 1];
          state.ranges[state.directToken] = range;
          state.directToken = '';
          state.directStart = -1;
          state.directDepth = -1;
        }
        position++;
        continue;
      }
      if (code === 34) { // quoted string
        const token: StringToken = BrewJsonScan.readString(payloadJson, position);
        const top: JsonFrame | undefined = frames.length > 0 ? frames[frames.length - 1] : undefined;
        if (top !== undefined && top.kind === 'object' && top.expectKey) {
          top.key = token.value;
          top.expectKey = false;
          top.expectValue = true;
        } else if (top !== undefined) {
          top.expectValue = false;
        }
        position = token.next;
        continue;
      }
      if (code === 44) { // ,
        const top: JsonFrame | undefined = frames.length > 0 ? frames[frames.length - 1] : undefined;
        if (top !== undefined && top.kind === 'object') {
          top.expectKey = true;
          top.expectValue = false;
        }
        position++;
        continue;
      }
      if (code === 58) { // :
        const top: JsonFrame | undefined = frames.length > 0 ? frames[frames.length - 1] : undefined;
        if (top !== undefined) {
          top.expectValue = true;
        }
        position++;
        continue;
      }
      // 数字、true、false、null 等标量不需要保存，跳过本字符即可。
      position++;
    }
    return state.ranges;
  }

  private static currentKey(frames: JsonFrame[]): string {
    if (frames.length === 0) {
      return '';
    }
    return frames[frames.length - 1].key;
  }

  private static readString(text: string, start: number): StringToken {
    let position: number = start + 1;
    while (position < text.length) {
      const code: number = text.charCodeAt(position);
      if (code === 92) { // backslash escape
        position += 2;
        continue;
      }
      if (code === 34) { // closing quote
        const raw: string = text.substring(start + 1, position);
        const token: StringToken = { value: JSON.parse('"' + raw + '"') as string, next: position + 1 };
        return token;
      }
      position++;
    }
    // 非法 JSON 不应进入这里；返回末尾位置让调用方停止，不让扫描器死循环。
    const invalid: StringToken = { value: '', next: text.length };
    return invalid;
  }
}
