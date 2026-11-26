/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

/**
 * FNV-1a 32 位哈希，输出 8 位 hex 字符串。
 *
 * 用途：D4（AI 发现流）的 cacheKey 里压缩「安装集签名」——排序小写 token 逗号连接
 * 后哈希，安装集一变 key 就变（spec §3.4）。不引入 crypto / hash 模块依赖，
 * 碰撞概率 2^-32 对「换一批要不要重新生成」的判定足够。
 *
 * 乘法用 `Math.imul`：32 位乘法若直接 `hash * 16777619` 会超出 double 精度
 * （≈4.3e9 × 1.7e7 = 7.3e16 > 2^53），高位丢失后不再是 FNV。
 */
export function fnv1a32(text: string): string {
  let hash: number = 0x811c9dc5;
  for (let i: number = 0; i < text.length; i++) {
    hash ^= text.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193);
  }
  // >>>0 归到无符号区间（imul 结果带符号），再补零到 8 位
  hash = hash >>> 0;
  let hex: string = hash.toString(16);
  while (hex.length < 8) {
    hex = `0${hex}`;
  }
  return hex;
}
