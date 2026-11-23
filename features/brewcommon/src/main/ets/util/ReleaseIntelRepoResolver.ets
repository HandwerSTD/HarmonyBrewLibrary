/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { Logger } from '@ohos/common';

const TAG: string = '[release-intel]';

/**
 * GitHub 仓库解析结果。url 恒为 `https://github.com/{owner}/{repo}` 形态。
 */
export class ReleaseIntelRepo {
  public owner: string = '';
  public repo: string = '';
  public url: string = '';
  /** 来源：archive（urls.stable.url 的 tarball 形态，最可靠）/ homepage（兜底，可能不准） */
  public via: string = '';
}

/**
 * 上游 GitHub 仓库定位（spec §3.1 RepoResolver）。
 *
 * 优先级：
 *   1. `urls.stable.url` 的 GitHub archive 形态
 *      （`https://github.com/{o}/{r}/archive/refs/tags/...` 或
 *      `.../releases/download/...` / `.../archive/{tag}.tar.gz`）——这是 formula 真正的
 *      下载源，归属最可靠；
 *   2. `homepage` 的 `https://github.com/{o}/{r}` 形态——兜底（homepage 可能指向组织页
 *      或带路径，取前两段）。
 * 都不命中 → via=''（调用方落缺口 repo，spec F2）。gitlab/gitee 等一律不解析（G9 不镜像）。
 */
export class ReleaseIntelRepoResolver {
  public static resolve(rawDoc: Object): ReleaseIntelRepo {
    const obj: Record<string, Object> = rawDoc as Record<string, Object>;
    const fromUrl: ReleaseIntelRepo | null =
      ReleaseIntelRepoResolver.fromStableUrl(obj);
    if (fromUrl !== null) {
      return fromUrl;
    }
    const fromHome: ReleaseIntelRepo | null =
      ReleaseIntelRepoResolver.fromHomepage(obj);
    if (fromHome !== null) {
      return fromHome;
    }
    return new ReleaseIntelRepo();
  }

  private static fromStableUrl(obj: Record<string, Object>): ReleaseIntelRepo | null {
    const urls: Object | undefined = obj['urls'];
    if (urls === undefined || urls === null) {
      return null;
    }
    const urlsObj: Record<string, Object> = urls as Record<string, Object>;
    const stable: Object | undefined = urlsObj['stable'];
    if (stable === undefined || stable === null) {
      return null;
    }
    const stableObj: Record<string, Object> = stable as Record<string, Object>;
    const url: Object | undefined = stableObj['url'];
    if (typeof url !== 'string') {
      return null;
    }
    const repo: ReleaseIntelRepo | null = ReleaseIntelRepoResolver.repoFromUrl(url as string);
    if (repo === null) {
      return null;
    }
    repo.via = 'archive';
    return repo;
  }

  private static fromHomepage(obj: Record<string, Object>): ReleaseIntelRepo | null {
    const home: Object | undefined = obj['homepage'];
    if (typeof home !== 'string') {
      return null;
    }
    const repo: ReleaseIntelRepo | null =
      ReleaseIntelRepoResolver.repoFromUrl(home as string);
    if (repo === null) {
      return null;
    }
    repo.via = 'homepage';
    return repo;
  }

  /**
   * 从任意 URL 提取 `{owner}/{repo}`。命中条件：github.com 域 + 路径至少两段。
   * 防御：忽略 `github.com` 裸域、`raw.githubusercontent.com` 等子域与文件路径 URL。
   */
  private static repoFromUrl(url: string): ReleaseIntelRepo | null {
    const httpsPrefix: string = 'https://github.com/';
    const httpPrefix: string = 'http://github.com/';
    let path: string = '';
    if (url.startsWith(httpsPrefix)) {
      path = url.substring(httpsPrefix.length);
    } else if (url.startsWith(httpPrefix)) {
      path = url.substring(httpPrefix.length);
    } else {
      return null;
    }
    const parts: string[] = path.split('/');
    if (parts.length < 2) {
      return null;
    }
    const owner: string = parts[0].trim();
    const repo: string = parts[1].trim().replace(/\.git$/, '');
    if (owner.length === 0 || repo.length === 0) {
      return null;
    }
    const out: ReleaseIntelRepo = new ReleaseIntelRepo();
    out.owner = owner;
    out.repo = repo;
    out.url = `https://github.com/${owner}/${repo}`;
    return out;
  }
}

/**
 * tag ↔ versions.stable 匹配（spec G2：strip v 前缀后**精确相等**，零误报）。
 *
 * 实证（`docs/knowledge/2026-11-23-release-channels-probe.md`）：release feed 混入
 * workspace 子包发布（如 monorepo 里的 crate tag），宽松匹配会把子包情报当主版本——
 * 所以 v1 只收精确匹配，宁可漏报不误报（风险节已声明）。
 */
export class ReleaseIntelTagFilter {
  /** tag 是否对应 versions.stable：剥 `v`/`V` 前缀后与 version 精确相等。 */
  public static matches(tag: string, version: string): boolean {
    return ReleaseIntelTagFilter.normalize(tag) === version;
  }

  /** tag 的归一口径：去首尾空白、剥单个 v/V 前缀（`v8.5` → `8.5`；`v1.13.0-rc1` 只剥 v）。 */
  public static normalize(tag: string): string {
    let out: string = tag.trim();
    if (out.length > 1 && (out.charAt(0) === 'v' || out.charAt(0) === 'V')) {
      const second: string = out.charAt(1);
      if (second >= '0' && second <= '9') {
        out = out.substring(1);
      }
    }
    return out;
  }

  /** 从 atom 的 entry id（`tag:github.com,2008:Repository/{id}/{tag}`）取 tag 段。 */
  public static tagFromEntryId(entryId: string): string {
    const index: number = entryId.lastIndexOf('/');
    if (index < 0 || index === entryId.length - 1) {
      Logger.warn(TAG, `atom entry id without tag segment: ${entryId.substring(0, 64)}`);
      return '';
    }
    return entryId.substring(index + 1);
  }
}
