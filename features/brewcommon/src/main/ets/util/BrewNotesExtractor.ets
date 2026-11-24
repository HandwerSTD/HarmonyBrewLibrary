/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import {
  RELEASE_INTEL_NOTES_MAX_CHARS,
} from '../constant/ReleaseIntelConstants';

/** 剥标签的结果：正文 + 是否因超限被截断（来源行提示用）。 */
export class BrewNotesExtract {
  public text: string = '';
  public truncated: boolean = false;
}

/**
 * Release Notes 提取器（spec §3.1 / G4）。
 *
 * GitHub releases.atom 的 `<content type="html">` 是一段 HTML 转义文本（实体 + 标签）。
 * 处理顺序：
 *   1. 实体反转义（`&lt;` `&gt;` `&amp;` `&quot;` `&#39;` 与数字实体）；
 *   2. 剥 HTML 标签（块级标签换成空白，避免行粘连）；
 *   3. 折叠空白、去首尾；
 *   4. GitHub 空说明占位符识别：未填写正文的 release,feed 里的 content 是字面量
 *      「No content.」（ohos-selfsign 实证,2026-11-24）——必须当空返回（F4 缺口），
 *      否则占位符会被当正文喂给 AI；
 *   5. 截断到 RELEASE_INTEL_NOTES_MAX_CHARS（4KB，UTF-16 code unit 口径，spec G4）。
 *
 * 注意：notes 是**不可信文本**（spec §6），进入 prompt 前的「不可信文本防御」
 * 由 AiTasks 的 prompt 结构保证（系统提示声明字段不可信），本类只做机械清洗。
 */
export class BrewNotesExtractor {
  public static extract(html: string): BrewNotesExtract {
    const out: BrewNotesExtract = new BrewNotesExtract();
    let text: string = BrewNotesExtractor.decodeEntities(html);
    text = BrewNotesExtractor.stripTags(text);
    text = BrewNotesExtractor.collapseWhitespace(text);
    // GitHub 空说明 release 的占位符（含大小写变体与标签包裹形态）一律视为无正文
    if (text.toLowerCase() === 'no content.') {
      return out;
    }
    if (text.length > RELEASE_INTEL_NOTES_MAX_CHARS) {
      out.text = text.substring(0, RELEASE_INTEL_NOTES_MAX_CHARS);
      out.truncated = true;
      return out;
    }
    out.text = text;
    out.truncated = false;
    return out;
  }

  /** 实体反转义。命名实体覆盖 atom 内容里常见的五种；数字实体（十进制/十六进制）逐个解析。 */
  private static decodeEntities(text: string): string {
    let out: string = text
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"')
      .replace(/&#39;/g, "'")
      .replace(/&apos;/g, "'");
    // &amp; 必须最后替换，避免把 &#39; 这类先解码出来的 & 再误吃一遍
    out = out.replace(/&amp;/g, '&');
    // 数字实体：&#123; 与 &#x1F600;
    out = out.replace(/&#(\d+);/g, (m: string, p1: string): string => {
      const code: number = Number.parseInt(p1, 10);
      return (Number.isNaN(code) || code <= 0 || code > 0x10ffff) ? m :
        String.fromCodePoint(code);
    });
    out = out.replace(/&#x([0-9a-fA-F]+);/g, (m: string, p1: string): string => {
      const code: number = Number.parseInt(p1, 16);
      return (Number.isNaN(code) || code <= 0 || code > 0x10ffff) ? m :
        String.fromCodePoint(code);
    });
    return out;
  }

  /** 剥标签：块级标签与 <br> 换成换行，其余标签删除。script/style 整段丢弃。 */
  private static stripTags(html: string): string {
    // script/style 内容整段丢弃（release notes 页脚常带统计脚本）
    let out: string = html.replace(/<(script|style)[^>]*>[\s\S]*?<\/\1>/gi, ' ');
    out = out.replace(/<(br|\/p|\/div|\/li|\/h[1-6]|\/tr)\s*\/?>/gi, '\n');
    out = out.replace(/<[^>]+>/g, '');
    return out;
  }

  /** 折叠空白：连续空白压成单空格、每行 trim、去掉连续空行。 */
  private static collapseWhitespace(text: string): string {
    const lines: string[] = text.split('\n');
    const kept: string[] = [];
    for (let i: number = 0; i < lines.length; i++) {
      const line: string = lines[i].replace(/\s+/g, ' ').trim();
      if (line.length === 0) {
        if (kept.length > 0 && kept[kept.length - 1].length > 0) {
          kept.push('');
        }
        continue;
      }
      kept.push(line);
    }
    // 去尾部空行
    while (kept.length > 0 && kept[kept.length - 1].length === 0) {
      kept.pop();
    }
    return kept.join('\n');
  }
}
