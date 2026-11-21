/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

/**
 * 终端配色的固定色表。
 *
 * 执行 Sheet 永远是黑底（`Color.Black`），所以这套颜色不随主题变化，也就没有放进
 * 资源目录的 `element/color.json`：深浅色两套在这里没有意义，而 ANSI 的 16 色本身
 * 就是一份固定表，放进资源反而要在两处维护同一份十六进制。
 */

/** stdout 的默认前景色 */
export const TERM_TEXT_COLOR: string = '#FFFFFF';

/**
 * stderr 的默认前景色：浅黄。
 *
 * 用浅黄而不是 `sys.color.warning`（偏橙红）：stderr 里绝大多数行是 Warning 与进度提示，
 * 真正出错的是 `Error:` 那几行 —— 而 brew 自己会给 `Error:` 打上红色 SGR（见 `BrewAnsiParser`），
 * 于是「整片红」变成「浅黄的常规输出 + 自己冒出来的红色错误」，层次才分得开。
 */
export const TERM_STDERR_COLOR: string = '#FFE08A';

/** 反显（SGR 7）时的默认底色。与 Sheet 背景同色，交换后看起来才像终端 */
const TERM_BACKGROUND: string = '#000000';

/** ANSI 基本 8 色（SGR 30–37 / 40–47），取 VS Code 终端在深色底上的取值 */
const ANSI_BASE: string[] = ['#000000', '#CD3131', '#0DBC79', '#E5E510', '#2472C8', '#BC3FBC', '#11A8CD', '#E5E5E5'];

/** ANSI 亮色（SGR 90–97 / 100–107） */
const ANSI_BRIGHT: string[] = ['#666666', '#F14C4C', '#23D18B', '#F5F543', '#3B8EEA', '#D670D6', '#29B8DB', '#FFFFFF'];

/** 256 色里 16–231 号立方体的每一级亮度 */
const ANSI_CUBE_LEVELS: number[] = [0, 95, 135, 175, 215, 255];

/** 字面量暗化时保留的亮度比例（SGR 2 的 faint） */
const DIM_FACTOR: number = 0.55;

const ESC: string = '\u001b';
const BEL: string = '\u0007';

/**
 * 一段同一样式的文本。整块日志由这些段拼成，一段对应一个 `Span`。
 *
 * 颜色已经在解析时算好（把默认色、反显、暗化都折进去），渲染层只管照着填 ——
 * 渲染层拿不到「这一行是 stdout 还是 stderr」的上下文，也不该再算一遍。
 */
export class BrewTextSegment {
  /** 全局递增序号。用作 `ForEach` 的键：裁剪掉最旧的行之后，同一个下标会指向不同内容 */
  public id: number;
  /** 来自 stderr 流 */
  public stderr: boolean;
  public text: string;
  /** 前景色，总是有值 */
  public color: string;
  /** 底色，空串表示不铺底 */
  public background: string;
  public bold: boolean;
  public underline: boolean;
  public italic: boolean;
  public strike: boolean;

  public constructor(id: number, stderr: boolean, text: string, color: string,
    background: string, bold: boolean, underline: boolean, italic: boolean, strike: boolean) {
    this.id = id;
    this.stderr = stderr;
    this.text = text;
    this.color = color;
    this.background = background;
    this.bold = bold;
    this.underline = underline;
    this.italic = italic;
    this.strike = strike;
  }
}

/**
 * ANSI 转义序列解析器：把带 SGR 的一段文本切成带样式的段。
 *
 * 每个流（stdout / stderr）各持一个实例，样式状态跨行延续 —— 这是终端的真实行为：
 * 一条 `\033[32m` 之后的所有输出都是绿的，直到出现 `\033[0m`。brew 自己在每段末尾都会 reset，
 * 但把它做成有状态的解析器，才不用赌对方一定守规矩。
 *
 * 只渲染「颜色与字体加成」，光标移动、清屏这类序列照样吃掉不显示 —— 日志区不是真终端，
 * 没有可移动的光标；`\r` 重绘在 `BrewCommandRunner` 里按「只留最后一段」处理。
 */
export class BrewAnsiParser {
  private stderr: boolean;
  /** 空串表示用该流的默认色 */
  private fg: string = '';
  /** 空串表示不铺底色 */
  private bg: string = '';
  private bold: boolean = false;
  private dim: boolean = false;
  private italic: boolean = false;
  private underline: boolean = false;
  private strike: boolean = false;
  private reverse: boolean = false;
  /** 分段序号的发号器。调用方给的起点，每产出一段加一 */
  private cursor: number = 0;

  public constructor(stderr: boolean) {
    this.stderr = stderr;
  }

  /** 回到默认样式。换一条命令时调用 */
  public reset(): void {
    this.fg = '';
    this.bg = '';
    this.bold = false;
    this.dim = false;
    this.italic = false;
    this.underline = false;
    this.strike = false;
    this.reverse = false;
  }

  /**
   * 解析一段已经去掉换行的文本。
   *
   * `firstId` 是本次产出的第一段的序号，调用方按返回段数推进自己的计数器 ——
   * 序号用于 `ForEach` 的键：裁剪掉最旧的行之后，同一个下标会指向不同内容。
   */
  public parse(text: string, firstId: number): BrewTextSegment[] {
    this.cursor = firstId;
    const out: BrewTextSegment[] = [];
    let plain: string = '';
    let i: number = 0;
    while (i < text.length) {
      const ch: string = text.charAt(i);
      if (ch !== ESC) {
        plain += ch;
        i++;
        continue;
      }
      if (plain.length > 0) {
        out.push(this.makeSegment(plain));
        plain = '';
      }
      i = this.consumeEscape(text, i);
    }
    if (plain.length > 0) {
      out.push(this.makeSegment(plain));
    }
    return out;
  }

  /**
   * 只推进样式状态，不产出段。
   *
   * 用于 `\r` 重绘：被覆盖掉的前半段不该显示，但它里面的 SGR 已经把终端改成了新状态，
   * 后半段是在那个状态下画的 —— 所以前半段必须「过一遍」，只是不输出。
   */
  public advance(text: string): void {
    let i: number = 0;
    while (i < text.length) {
      if (text.charAt(i) !== ESC) {
        i++;
        continue;
      }
      i = this.consumeEscape(text, i);
    }
  }

  /** 吃掉一个转义序列，返回它之后的第一个字符下标 */
  private consumeEscape(text: string, start: number): number {
    let i: number = start + 1;
    if (i >= text.length) {
      return i;
    }
    const kind: string = text.charAt(i);
    // CSI：ESC [ 参数字节 中间字节 终止字节
    if (kind === '[') {
      i++;
      let params: string = '';
      while (i < text.length) {
        const code: number = text.charCodeAt(i);
        if (code >= 0x30 && code <= 0x3F) {
          params += text.charAt(i);
          i++;
        } else if (code >= 0x20 && code <= 0x2F) {
          i++;
        } else {
          break;
        }
      }
      if (i >= text.length) {
        return i;
      }
      const final: string = text.charAt(i);
      i++;
      if (final === 'm') {
        this.applySgr(params);
      }
      return i;
    }
    // OSC：ESC ] … BEL 或 ESC \
    if (kind === ']') {
      i++;
      while (i < text.length) {
        const c: string = text.charAt(i);
        if (c === BEL) {
          return i + 1;
        }
        if (c === ESC) {
          return i + 2 > text.length ? text.length : i + 2;
        }
        i++;
      }
      return i;
    }
    // 其余两字节序列（ESC 7、ESC 8 之类）整体吃掉
    return i + 1;
  }

  /** SGR 参数。分号分隔，空参数等价于 0（reset） */
  private applySgr(params: string): void {
    const parts: string[] = params.length === 0 ? ['0'] : params.split(';');
    let i: number = 0;
    while (i < parts.length) {
      const raw: string = parts[i].trim();
      const code: number = raw.length === 0 ? 0 : Number.parseInt(raw, 10);
      if (Number.isNaN(code)) {
        i++;
        continue;
      }
      if (code === 38 || code === 48) {
        // 扩展前景 / 背景色：38;5;n 或 38;2;r;g;b
        const resolved: ExtendedColor = this.readExtendedColor(parts, i);
        if (resolved.color.length > 0) {
          if (code === 38) {
            this.fg = resolved.color;
          } else {
            this.bg = resolved.color;
          }
        }
        i = resolved.next;
        continue;
      }
      this.applySimpleSgr(code);
      i++;
    }
  }

  /** 读扩展色的参数，返回颜色与下一个待处理下标 */
  private readExtendedColor(parts: string[], start: number): ExtendedColor {
    const modeIndex: number = start + 1;
    if (modeIndex >= parts.length) {
      return new ExtendedColor('', parts.length);
    }
    const mode: number = Number.parseInt(parts[modeIndex], 10);
    if (mode === 5) {
      // 256 色：38;5;<n>
      if (modeIndex + 1 >= parts.length) {
        return new ExtendedColor('', parts.length);
      }
      const index: number = Number.parseInt(parts[modeIndex + 1], 10);
      return new ExtendedColor(colorOf256(Number.isNaN(index) ? 0 : index), modeIndex + 2);
    }
    if (mode === 2) {
      // 真彩色：38;2;<r>;<g>;<b>
      if (modeIndex + 3 >= parts.length) {
        return new ExtendedColor('', parts.length);
      }
      const r: number = Number.parseInt(parts[modeIndex + 1], 10);
      const g: number = Number.parseInt(parts[modeIndex + 2], 10);
      const b: number = Number.parseInt(parts[modeIndex + 3], 10);
      return new ExtendedColor(hexOf(r, g, b), modeIndex + 4);
    }
    return new ExtendedColor('', modeIndex + 1);
  }

  private applySimpleSgr(code: number): void {
    if (code === 0) {
      this.reset();
    } else if (code === 1) {
      this.bold = true;
    } else if (code === 2) {
      this.dim = true;
    } else if (code === 3) {
      this.italic = true;
    } else if (code === 4) {
      this.underline = true;
    } else if (code === 7) {
      this.reverse = true;
    } else if (code === 9) {
      this.strike = true;
    } else if (code === 21 || code === 22) {
      this.bold = false;
      this.dim = false;
    } else if (code === 23) {
      this.italic = false;
    } else if (code === 24) {
      this.underline = false;
    } else if (code === 27) {
      this.reverse = false;
    } else if (code === 29) {
      this.strike = false;
    } else if (code >= 30 && code <= 37) {
      this.fg = ANSI_BASE[code - 30];
    } else if (code === 39) {
      this.fg = '';
    } else if (code >= 40 && code <= 47) {
      this.bg = ANSI_BASE[code - 40];
    } else if (code === 49) {
      this.bg = '';
    } else if (code >= 90 && code <= 97) {
      this.fg = ANSI_BRIGHT[code - 90];
    } else if (code >= 100 && code <= 107) {
      this.bg = ANSI_BRIGHT[code - 100];
    }
    // 其余（闪烁 5/6、隐藏 8、下划线样式 53–55 等）在日志区没有对应表现，忽略
  }

  /** 把当前样式折进一段文本 */
  private makeSegment(text: string): BrewTextSegment {
    const base: string = this.stderr ? TERM_STDERR_COLOR : TERM_TEXT_COLOR;
    let color: string = this.fg.length > 0 ? this.fg : base;
    let background: string = this.bg;
    if (this.reverse) {
      const swappedColor: string = this.bg.length > 0 ? this.bg : TERM_BACKGROUND;
      const swappedBackground: string = this.fg.length > 0 ? this.fg : base;
      color = swappedColor;
      background = swappedBackground;
    }
    if (this.dim) {
      color = dimmed(color);
    }
    const segment: BrewTextSegment = new BrewTextSegment(this.cursor, this.stderr, text, color,
      background, this.bold, this.underline, this.italic, this.strike);
    this.cursor++;
    return segment;
  }
}

/** 扩展色的解析结果 */
class ExtendedColor {
  public color: string;
  public next: number;

  public constructor(color: string, next: number) {
    this.color = color;
    this.next = next;
  }
}

/** 256 色索引转十六进制。0–15 取自基本表，16–231 是 6×6×6 立方体，232–255 是灰阶 */
function colorOf256(index: number): string {
  if (index < 0) {
    return '#000000';
  }
  if (index < 8) {
    return ANSI_BASE[index];
  }
  if (index < 16) {
    return ANSI_BRIGHT[index - 8];
  }
  if (index < 232) {
    const cube: number = index - 16;
    const r: number = ANSI_CUBE_LEVELS[Math.floor(cube / 36)];
    const g: number = ANSI_CUBE_LEVELS[Math.floor((cube % 36) / 6)];
    const b: number = ANSI_CUBE_LEVELS[cube % 6];
    return hexOf(r, g, b);
  }
  const gray: number = 8 + (index - 232) * 10;
  return hexOf(gray, gray, gray);
}

function hexOf(r: number, g: number, b: number): string {
  return `#${hexByte(r)}${hexByte(g)}${hexByte(b)}`;
}

function hexByte(value: number): string {
  const clamped: number = Number.isNaN(value) ? 0 : Math.min(255, Math.max(0, Math.round(value)));
  const text: string = clamped.toString(16).toUpperCase();
  return text.length === 1 ? `0${text}` : text;
}

/** SGR 2 的 faint：把字面量按比例压暗 */
function dimmed(color: string): string {
  if (color.length !== 7 || color.charAt(0) !== '#') {
    return color;
  }
  const r: number = Number.parseInt(color.substring(1, 3), 16);
  const g: number = Number.parseInt(color.substring(3, 5), 16);
  const b: number = Number.parseInt(color.substring(5, 7), 16);
  if (Number.isNaN(r) || Number.isNaN(g) || Number.isNaN(b)) {
    return color;
  }
  return hexOf(r * DIM_FACTOR, g * DIM_FACTOR, b * DIM_FACTOR);
}
