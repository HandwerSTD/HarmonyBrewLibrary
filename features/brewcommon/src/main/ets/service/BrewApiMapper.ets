/*
 * Copyright (c) 2025 Huawei Device Co., Ltd.
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

import type {
  BrewArch,
  BrewArtifact,
  BrewCaskDependsOn,
  BrewCaskDetail,
  BrewDependency,
  BrewFormulaDetail,
  BrewKegOnlyReason,
  BrewPackageItem,
  BrewRequirement,
} from '../model/BrewModels';
import { BrewKind } from '../model/BrewModels';

/**
 * formulae.brew.sh 现网 JSON → 应用模型。
 *
 * **本文件是 mockgen `generate.py` 的 ArkTS 移植**（`build_detail()` 及其 helper）：
 * 快照是同一份数据在生成时被压成的形状，所以「快照字段」与「现网字段」必须由同一套
 * 归一化规则产出 —— 否则同一个包在「打开详情页（现网）」与「列表卡片（快照）」上
 * 会显示成两种样子。改动这里时**必须同步改 `hmosword-build/brew-mockgen/generate.py`**。
 *
 * 为什么是「合并」而不是「转换」：官方 API 里没有分类、分类内排名、分类内总数、本地 id
 * 这些字段（分类体系是本项目自建的，见 docs/brew-marketplace-content-plan.md §1.2），
 * 所以详情页的对象必须**以内置快照为底座**，再用现网值覆盖官方字段。
 * 好处：现网缺字段/请求失败时不会把页面变成残缺态，而是回落到快照值。
 *
 * 下面每个 `Live*` 接口都按**实测**的现网形状声明（不是照文档猜的）：
 * `curl .brewgen/live-formula-*.json` / `live-cask-*.json` 可复现。
 */

// ---------------------------------------------------------------- 现网 JSON 形状

export interface LiveVersions {
  stable?: string;
  /** 恒为字符串 'HEAD'（无 head 版本时也是它，实测），所以空值判断要排除 'HEAD' */
  head?: string;
  bottle?: boolean;
}

export interface LiveBottleStable {
  rebuild?: number;
  files?: Record<string, Object>;
}

export interface LiveBottle {
  stable?: LiveBottleStable;
}

export interface LiveDepObj {
  name?: string;
  full_name?: string;
}

export interface LiveRequirement {
  name?: string;
  version?: string;
  contexts?: string[];
}

/** service.run 实测三种形态：string ｜ string[] ｜ { <platform>: string[] }（见 serviceRun） */
export interface LiveService {
  run?: string | string[] | Record<string, string | string[]>;
  run_type?: string;
}

export interface LiveAnalytics {
  install?: Record<string, Record<string, number>>;
  install_on_request?: Record<string, Record<string, number>>;
}

export interface LiveFormulaDoc {
  token?: string;
  name?: string;
  full_name?: string;
  tap?: string;
  desc?: string;
  homepage?: string;
  license?: string;
  versions?: LiveVersions;
  bottle?: LiveBottle;
  keg_only?: boolean;
  keg_only_reason?: BrewKegOnlyReason | null;
  deprecated?: boolean;
  deprecation_date?: string;
  deprecation_reason?: string;
  deprecation_replacement_formula?: string;
  deprecation_replacement_cask?: string;
  disabled?: boolean;
  disable_date?: string;
  disable_reason?: string;
  versioned_formulae?: string[];
  aliases?: string[];
  executables?: string[];
  requirements?: Array<string | LiveRequirement>;
  caveats?: string | null;
  dependencies?: Array<string | LiveDepObj>;
  build_dependencies?: Array<string | LiveDepObj>;
  optional_dependencies?: Array<string | LiveDepObj>;
  recommended_dependencies?: Array<string | LiveDepObj>;
  /** 实测是 string[]，但文档允许带 since 的对象，统一按 dep 归一化 */
  uses_from_macos?: Array<string | LiveDepObj>;
  conflicts_with?: string[];
  analytics?: LiveAnalytics;
  service?: LiveService | null;
}

export interface LiveCaskDependsOn {
  formula?: Array<string | LiveDepObj>;
  cask?: Array<string | LiveDepObj>;
  macos?: Record<string, string[]>;
  arch?: Array<LiveDepObj | string>;
}

export interface LiveCaskDoc {
  token?: string;
  full_token?: string;
  name?: string[];
  tap?: string;
  desc?: string;
  homepage?: string;
  version?: string;
  auto_updates?: boolean;
  supported_platforms?: string[];
  /** 实测两种形态：多数是 int（7977.83 这种点分版本号），少数是 string */
  bundle_version?: string | number;
  depends_on?: LiveCaskDependsOn;
  conflicts_with?: Record<string, string[]> | null;
  artifacts?: Array<Record<string, Object>>;
  caveats?: string | null;
  deprecated?: boolean;
  deprecation_date?: string;
  deprecation_reason?: string;
  deprecation_replacement_formula?: string;
  deprecation_replacement_cask?: string;
  disabled?: boolean;
  disable_date?: string;
  disable_reason?: string;
  analytics?: LiveAnalytics;
}

/** cask artifacts 里算「安装产物」的类型白名单（与 generate.py 的 ARTIFACT_TYPES 一致） */
const ARTIFACT_TYPES: string[] = [
  'app', 'pkg', 'binary', 'font', 'colorpicker', 'qlplugin', 'installer', 'manpage',
  'prefpane', 'suite', 'service', 'dictionary', 'input_method', 'keyboard_layout',
  'screen_saver', 'sounds', 'artifact', 'stage_only',
];

// ---------------------------------------------------------------- 归一化

/**
 * 首页快照的条目 -> 详情页的**骨架**。
 *
 * 为什么不再读 `brew-{formula,cask}-details.json`：详情页需要快照提供的只有
 * **官方 API 里不存在的字段** —— 本地 `id`、`categoryKey`、`categoryRank/categorySize`，
 * 而这些字段**首页快照的条目里本来就有**（生成器写详情时就是从同一个 item 派生的）。
 * 剩下的一切（版本/依赖/bottle/artifacts/caveats/生命周期/热度）都由现网单条覆盖。
 * 实测：详情页与归一化器对 `contentType` / `recommendList` **零引用**，所以它们一并删掉。
 *
 * 代价（写成事实，不当成意外）：`BREW_DATA_MODE=SNAPSHOT` 或现网失败时，
 * 详情页降级成骨架里这几个字段（依赖/artifacts/caveats 那些段落直接不渲染）——
 * 归一化器本来就是按“字段为空就不加这一段”写的，所以降级是完整可渲染的页面，不是错误页。
 */
export class BrewApiMapper {
  /**
   * 首页快照的条目 -> 详情页的**骨架**。
   *
   * 详情页需要**本地才有**的只有三样：`id`（路由参数与缓存键）、`categoryKey`、`categoryRank/categorySize`。
   * C 档之后这三样都由设备端算：id = `BrewBrowseBuilder.tokenId(token)`、
   * 分类 = `BrewTaxonomy`（策展覆盖 → 关键词 → 兜底）、名次 = 浏览集内的名次。
   * 其余一切（版本/依赖/bottle/artifacts/caveats/生命周期/热度/描述）都由现网单条覆盖。
   *
   * 代价（写成事实，不当成意外）：`BREW_DATA_MODE=SNAPSHOT` 或现网失败时，
   * 详情页只剩骨架字段（依赖/artifacts/caveats 那些段落直接不渲染）——
   * 归一化器本来就是按“字段为空就不加这一段”写的，所以降级后是完整可渲染的页面，不是错误页。
   */
  public static formulaBase(token: string, id: number, categoryKey: string, installs30d: number): BrewFormulaDetail {
    const base: BrewFormulaDetail = {
      id: id,
      token: token,
      fullToken: token,
      tap: '',
      name: token,
      desc: '',
      homepage: '',
      license: '',
      stableVersion: '',
      headVersion: '',
      versionedFormulae: [],
      aliases: [],
      kegOnly: false,
      kegOnlyReason: null,
      serviceSupported: false,
      serviceRun: [],
      serviceRunType: '',
      executables: [],
      requirements: [],
      caveats: '',
      bottleAvailable: false,
      bottleTags: [],
      bottleRebuild: 0,
      dependencies: [],
      buildDependencies: [],
      optionalDependencies: [],
      recommendedDependencies: [],
      usesFromMacos: [],
      conflictsWith: [],
      installs30d: installs30d,
      installs90d: 0,
      installs365d: 0,
      categoryRank: 0,
      categorySize: 0,
      installCommand: '',
      categoryKey: categoryKey,
      deprecated: false,
      deprecationDate: '',
      deprecationReason: '',
      deprecationReplacementFormula: '',
      deprecationReplacementCask: '',
      disabled: false,
      disableDate: '',
      disableReason: '',
    };
    return base;
  }

  /** 同 `formulaBaseOf`（cask 骨架的字段差异：version / autoUpdates / dependsOn 等） */
  public static caskBase(token: string, id: number, categoryKey: string, installs30d: number): BrewCaskDetail {
    // macos 是 Record<string, string[]>（ArkTS 不允许把它写成数组字面量），先给一个显式类型的空表
    const noMacos: Record<string, string[]> = {};
    const dependsOn: BrewCaskDependsOn = { formula: [], cask: [], macos: noMacos, arch: [] };
    const base: BrewCaskDetail = {
      id: id,
      token: token,
      fullToken: token,
      tap: '',
      name: token,
      names: [],
      desc: '',
      homepage: '',
      version: '',
      autoUpdates: false,
      supportedPlatforms: [],
      macosRequirement: '',
      bundleVersion: '',
      artifacts: [],
      zapPathCount: 0,
      dependsOn: dependsOn,
      conflictsWith: [],
      caveats: '',
      installs30d: installs30d,
      installs90d: 0,
      installs365d: 0,
      categoryRank: 0,
      categorySize: 0,
      installCommand: '',
      categoryKey: categoryKey,
      deprecated: false,
      deprecationDate: '',
      deprecationReason: '',
      deprecationReplacementFormula: '',
      deprecationReplacementCask: '',
      disabled: false,
      disableDate: '',
      disableReason: '',
    };
    return base;
  }

  // -------------------------------------------------- formula

  /**
   * 用现网值覆盖快照里的官方字段，返回同一个 `base` 对象（原地合并）。
   *
   * **不覆盖**：id / categoryKey / categoryRank / categorySize
   * —— 这些是本地清单与推荐算法产出的，官方 API 里没有，覆盖会把页面打回残缺态。
   */
  public static mergeFormula(base: BrewFormulaDetail, doc: LiveFormulaDoc): BrewFormulaDetail {
    const token: string = doc.token ?? base.token;
    const versions: LiveVersions = doc.versions ?? {};
    const bottle: LiveBottleStable = doc.bottle?.stable ?? {};
    const service: LiveService | null = doc.service ?? null;

    base.token = token;
    base.fullToken = doc.full_name ?? token;
    base.tap = doc.tap ?? base.tap;
    base.name = doc.name ?? token;
    base.desc = doc.desc ?? '';
    base.homepage = doc.homepage ?? '';
    base.license = doc.license ?? '';
    base.stableVersion = versions.stable ?? '';
    // 实测无 head 版本时 `versions.head` 也是字符串 'HEAD'，不能直接透传
    base.headVersion = (versions.head !== undefined && versions.head !== 'HEAD') ? versions.head : '';
    base.versionedFormulae = doc.versioned_formulae ?? [];
    base.aliases = doc.aliases ?? [];
    base.kegOnly = doc.keg_only ?? false;
    base.kegOnlyReason = doc.keg_only_reason ?? null;
    base.serviceSupported = service !== null;
    base.serviceRun = BrewApiMapper.serviceRun(service);
    base.serviceRunType = service?.run_type ?? '';
    base.executables = doc.executables ?? [];
    base.requirements = BrewApiMapper.requirementList(doc);
    base.caveats = doc.caveats ?? '';
    base.bottleAvailable = versions.bottle ?? false;
    // 不用 `Object.keys(bottle.files ?? {})`：ArkTS 禁止无类型对象字面量（arkts-no-untyped-obj-literals）
    const bottleFiles: Record<string, Object> | undefined = bottle.files;
    base.bottleTags = bottleFiles === undefined ? [] : Object.keys(bottleFiles).sort();
    base.bottleRebuild = bottle.rebuild ?? 0;
    base.dependencies = BrewApiMapper.depList(doc.dependencies);
    base.buildDependencies = BrewApiMapper.depList(doc.build_dependencies);
    base.optionalDependencies = BrewApiMapper.depList(doc.optional_dependencies);
    base.recommendedDependencies = BrewApiMapper.depList(doc.recommended_dependencies);
    base.usesFromMacos = BrewApiMapper.nameList(doc.uses_from_macos);
    base.conflictsWith = doc.conflicts_with ?? [];
    BrewApiMapper.applyLifecycle(base, doc.deprecated, doc.deprecation_date, doc.deprecation_reason,
      doc.deprecation_replacement_formula, doc.deprecation_replacement_cask,
      doc.disabled, doc.disable_date, doc.disable_reason);
    // formula 的安装量取 install_on_request（用户主动点名安装的次数），cask 取 install —— 与 generate.py 一致
    const bucket: LiveAnalytics = doc.analytics ?? {};
    base.installs30d = BrewApiMapper.installCount(bucket.install_on_request?.['30d'], token);
    base.installs90d = BrewApiMapper.installCount(bucket.install_on_request?.['90d'], token);
    base.installs365d = BrewApiMapper.installCount(bucket.install_on_request?.['365d'], token);
    base.installCommand = BrewApiMapper.installCommand(BrewKind.FORMULA, token, base.tap);
    return base;
  }

  // -------------------------------------------------- cask

  /** 同 mergeFormula。额外把 artifacts / dependsOn / zap 路径数一起覆盖。 */
  public static mergeCask(base: BrewCaskDetail, doc: LiveCaskDoc): BrewCaskDetail {
    const token: string = doc.token ?? base.token;
    const names: string[] = doc.name ?? [token];
    const dependsOn: LiveCaskDependsOn = doc.depends_on ?? {};

    base.token = token;
    base.fullToken = doc.full_token ?? token;
    base.tap = doc.tap ?? base.tap;
    base.name = names.length > 0 ? names[0] : token;
    base.names = names;
    base.desc = doc.desc ?? '';
    base.homepage = doc.homepage ?? '';
    base.version = doc.version ?? '';
    base.autoUpdates = doc.auto_updates ?? false;
    base.supportedPlatforms = doc.supported_platforms ?? [];
    base.macosRequirement = BrewApiMapper.macosRequirement(dependsOn.macos);
    base.bundleVersion = doc.bundle_version === undefined ? '' : `${doc.bundle_version}`;
    base.artifacts = BrewApiMapper.artifactSummary(doc.artifacts);
    base.zapPathCount = BrewApiMapper.zapPathCount(doc.artifacts);
    const depends: BrewCaskDependsOn = {
      formula: BrewApiMapper.depList(dependsOn.formula),
      cask: BrewApiMapper.depList(dependsOn.cask),
      macos: dependsOn.macos ?? {},
      arch: BrewApiMapper.archList(dependsOn.arch),
    };
    base.dependsOn = depends;
    base.conflictsWith = doc.conflicts_with?.['cask'] ?? [];
    base.caveats = doc.caveats ?? '';
    BrewApiMapper.applyLifecycle(base, doc.deprecated, doc.deprecation_date, doc.deprecation_reason,
      doc.deprecation_replacement_formula, doc.deprecation_replacement_cask,
      doc.disabled, doc.disable_date, doc.disable_reason);
    const bucket: LiveAnalytics = doc.analytics ?? {};
    base.installs30d = BrewApiMapper.installCount(bucket.install?.['30d'], token);
    base.installs90d = BrewApiMapper.installCount(bucket.install?.['90d'], token);
    base.installs365d = BrewApiMapper.installCount(bucket.install?.['365d'], token);
    base.installCommand = BrewApiMapper.installCommand(BrewKind.CASK, token, base.tap);
    return base;
  }

  // -------------------------------------------------- 生命周期

  /** deprecated / disabled 三态。两个模型都有这几个字段，抽出来避免两处漂移。 */
  private static applyLifecycle(target: BrewFormulaDetail | BrewCaskDetail,
    deprecated: boolean | undefined, deprecationDate: string | undefined,
    deprecationReason: string | undefined, replacementFormula: string | undefined,
    replacementCask: string | undefined, disabled: boolean | undefined,
    disableDate: string | undefined, disableReason: string | undefined): void {
    target.deprecated = deprecated ?? false;
    target.deprecationDate = deprecationDate ?? '';
    target.deprecationReason = deprecationReason ?? '';
    target.deprecationReplacementFormula = replacementFormula ?? '';
    target.deprecationReplacementCask = replacementCask ?? '';
    target.disabled = disabled ?? false;
    target.disableDate = disableDate ?? '';
    target.disableReason = disableReason ?? '';
  }

  // -------------------------------------------------- 列表条目（卡片）

  /**
   * 把现网值填进列表条目（原地修改 `item`）。
   *
   * 只覆盖**包自身属性**：desc / 版本 / 依赖 / bottle / 生命周期 / 许可 / 主页。
   * **不碰 `id` / `categoryKey` / `categoryRank` / `categorySize`** ——
   * 前两个是本地清单的主键，后两个是排序结果，由 Repository 在 hydrate 完成后
   * 统一按「当前可见的安装量」重算（见 BrewFormulaModel.rerankCategory）。
   *
   * `installs30d` 单独用 `applyFormulaInstalls` 写，原因同上：
   * 先把一个分类的安装量全部写完再重排名次，否则会拿一半新一半旧的数据排名。
   */
  public static applyFormulaItem(item: BrewPackageItem, doc: LiveFormulaDoc): void {
    const versions: LiveVersions = doc.versions ?? {};
    item.token = doc.token ?? item.token;
    // title / subTitle 是卡片展示槽位：title 放 desc，subTitle 放 token（见 BrewModels 文件头）
    item.title = doc.desc ?? item.title;
    item.subTitle = item.token;
    item.stableVersion = versions.stable ?? item.stableVersion;
    item.license = doc.license ?? item.license;
    item.homepage = doc.homepage ?? item.homepage;
    item.kegOnly = doc.keg_only ?? item.kegOnly;
    item.deprecated = doc.deprecated ?? false;
    item.disabled = doc.disabled ?? false;
    // 刻意不碰 mediaUrl / version / sequence / tagIds：
    // 它们是原样例卡片引擎的展示字段（图标、序号、标签），与官方 API 无关，
    // 交给内置清单管。
  }

  /** 列表条目的安装量（现网 `install_on_request`，与 generate.py 同口径） */
  public static applyFormulaInstalls(item: BrewPackageItem, doc: LiveFormulaDoc): void {
    const bucket: LiveAnalytics = doc.analytics ?? {};
    item.installs30d = BrewApiMapper.installCount(bucket.install_on_request?.['30d'], item.token);
  }

  /** 同 applyFormulaItem；cask 的安装量口径是 `install` */
  public static applyCaskItem(item: BrewPackageItem, doc: LiveCaskDoc): void {
    item.token = doc.token ?? item.token;
    item.title = doc.desc ?? item.title;
    item.subTitle = item.token;
    item.stableVersion = doc.version ?? item.stableVersion;
    item.homepage = doc.homepage ?? item.homepage;
    item.autoUpdates = doc.auto_updates ?? item.autoUpdates;
    item.deprecated = doc.deprecated ?? false;
    item.disabled = doc.disabled ?? false;
  }

  /** 同 applyFormulaInstalls（cask 用 `install`） */
  public static applyCaskInstalls(item: BrewPackageItem, doc: LiveCaskDoc): void {
    const bucket: LiveAnalytics = doc.analytics ?? {};
    item.installs30d = BrewApiMapper.installCount(bucket.install?.['30d'], item.token);
  }

  /**
   * 列表条目按「当前可见的安装量」重算分类内排名与总数。
   *
   * 只在**原数组的副本上**排序，不重排 `items` 本身：卡片的条目顺序是生成期调过的
   * 版面节奏（`sequence`），而 `categoryRank` 只是一个展示值。两者混在一起会把版面改掉。
   *
   * 口径与 generate.py 一致：同分类成员按 `installs30d` 降序，1 起算。
   * 这里用的是「hydrate 后的安装量」，因此**名次永远与卡片上的数字自洽** ——
   * 不会出现“安装量是现网的、排名还是旧快照”这种看得到的矛盾。
   */
  public static rerankCategory(items: BrewPackageItem[]): void {
    const sorted: BrewPackageItem[] = items.slice().sort((a: BrewPackageItem, b: BrewPackageItem) =>
      b.installs30d - a.installs30d);
    sorted.forEach((item: BrewPackageItem, index: number) => {
      item.categoryRank = index + 1;
      item.categorySize = sorted.length;
    });
  }

  // -------------------------------------------------- 小工具（与 generate.py 一一对应）

  /**
   * 安装量。官方 analytics 的 key 可能是 `wget`，也可能是 `wget --HEAD`（带参数的变体），
   * 所以按「等于 token」或「token + 空格开头」取最大值 —— 这是实测出来的口径，
   * 只匹配 token 会让带参数安装的包少算。
   *
   * public：Repository 拼 banner 文案（`N installs / 30d`）时也要用同一个口径。
   */
  public static installCount(bucket: Record<string, number> | undefined, token: string): number {    if (bucket === undefined) {
      return 0;
    }
    let best: number = 0;
    Object.keys(bucket).forEach((key: string) => {
      if (key === token || key.startsWith(`${token} `)) {
        const value: number = bucket[key];
        if (value > best) {
          best = value;
        }
      }
    });
    return best;
  }

  /**
   * service.run 的三种实测形态 → string[]。
   * 平台字典（如 podman 的 `{linux: [...]}`）把平台名当前缀保留，
   * 避免丢掉「这条命令是哪个平台的」这个信息。
   */
  private static serviceRun(service: LiveService | null): string[] {
    const run: string | string[] | Record<string, string | string[]> | undefined = service?.run;
    if (run === undefined) {
      return [];
    }
    if (typeof run === 'string') {
      return [run];
    }
    if (Array.isArray(run)) {
      return (run as string[]).map((one: string) => `${one}`);
    }
    const commands: string[] = [];
    const dict: Record<string, string | string[]> = run as Record<string, string | string[]>;
    Object.keys(dict).forEach((platform: string) => {
      const command: string | string[] = dict[platform];
      commands.push(Array.isArray(command) ? `${platform}: ${(command as string[]).join(' ')}` :
        `${platform}: ${command}`);
    });
    return commands;
  }

  /** requirements 实测是对象数组，但允许裸字符串（旧数据） */
  private static requirementList(doc: LiveFormulaDoc): BrewRequirement[] {
    const out: BrewRequirement[] = [];
    (doc.requirements ?? []).forEach((one: string | LiveRequirement) => {
      if (typeof one === 'string') {
        out.push({ name: one, version: '', contexts: [] });
        return;
      }
      const item: LiveRequirement = one as LiveRequirement;
      out.push({
        name: item.name ?? '',
        version: item.version ?? '',
        contexts: item.contexts ?? [],
      });
    });
    return out;
  }

  /** `[{name, full_name}] | string[] | [{name: ...}]` → BrewDependency[]（与 generate.py dep_list 一致） */
  private static depList(value: Array<string | LiveDepObj> | undefined): BrewDependency[] {
    const out: BrewDependency[] = [];
    (value ?? []).forEach((one: string | LiveDepObj) => {
      if (typeof one === 'string') {
        out.push({ name: one, fullName: one });
        return;
      }
      const item: LiveDepObj = one as LiveDepObj;
      const name: string = item.name ?? '';
      out.push({ name: name, fullName: item.full_name ?? name });
    });
    return out;
  }

  /** 只要名字的列表（uses_from_macos）。实测可能是对象，直接透传会在 UI 上显示 [object Object]。 */
  private static nameList(value: Array<string | LiveDepObj> | undefined): string[] {
    return BrewApiMapper.depList(value).map((one: BrewDependency) => one.name);
  }

  /** cask depends_on.arch 实测是 `[{type: 'arm', bits: 64}, ...]` 或字符串 */
  private static archList(value: Array<LiveDepObj | string> | undefined): BrewArch[] {
    const out: BrewArch[] = [];
    (value ?? []).forEach((one: LiveDepObj | string) => {
      if (typeof one === 'string') {
        out.push({ type: one, bits: 0 });
        return;
      }
      const arch = one as BrewArch;
      out.push({ type: arch.type ?? '', bits: arch.bits ?? 0 });
    });
    return out;
  }

  /** 把 cask 的 depends_on.macos 压成可展示字符串，如 'macOS >= 13' */
  private static macosRequirement(macos: Record<string, string[]> | undefined): string {
    if (macos === undefined) {
      return '';
    }
    let result: string = '';
    Object.keys(macos).forEach((op: string) => {
      if (result.length > 0) {
        return;
      }
      const versions: string[] = macos[op];
      if (versions !== undefined && versions.length > 0) {
        result = `macOS ${op} ${versions.join(', ')}`;
      }
    });
    return result;
  }

  /** cask artifacts → UI 可读的安装内容列表（只保留 ARTIFACT_TYPES 里的类型） */
  private static artifactSummary(artifacts: Array<Record<string, Object>> | undefined): BrewArtifact[] {
    const out: BrewArtifact[] = [];
    (artifacts ?? []).forEach((entry: Record<string, Object>) => {
      Object.keys(entry).forEach((key: string) => {
        if (ARTIFACT_TYPES.indexOf(key) < 0) {
          return;
        }
        const value: Object = entry[key];
        const values: Object[] = Array.isArray(value) ? value as Object[] : [value];
        values.forEach((one: Object) => {
          out.push({
            artifactType: key,
            path: typeof one === 'string' ? one as string : JSON.stringify(one),
          });
        });
      });
    });
    return out;
  }

  /** 卸载残留清理路径数量（zap 下所有 key 的路径数之和） */
  private static zapPathCount(artifacts: Array<Record<string, Object>> | undefined): number {
    let total: number = 0;
    (artifacts ?? []).forEach((entry: Record<string, Object>) => {
      Object.keys(entry).forEach((key: string) => {
        if (key !== 'zap') {
          return;
        }
        const value: Object = entry[key];
        const values: Object[] = Array.isArray(value) ? value as Object[] : [value];
        values.forEach((one: Object) => {
          if (typeof one !== 'object' || one === null || Array.isArray(one)) {
            total += 1;
            return;
          }
          const dict: Record<string, Object> = one as Record<string, Object>;
          Object.keys(dict).forEach((pathKey: string) => {
            const paths: Object = dict[pathKey];
            total += Array.isArray(paths) ? (paths as Object[]).length : 1;
          });
        });
      });
    });
    return total;
  }

  /**
   * 从 banner 的 `N installs / 30d` 里取回数字（重排用）。
   * 文案格式由生成器固定，两边必须一致 —— 否则重排会静默按 0 排序。
   */
  public static installsOf(text: string): number {
    const value: number = Number.parseInt(text, 10);
    return Number.isNaN(value) ? 0 : value;
  }

  /** 非官方 tap 的包要带 tap 前缀（`brew install user/tap/foo`），与 generate.py 同口径 */
  private static installCommand(kind: string, token: string, tap: string): string {
    let name: string = token;
    if (tap.length > 0 && tap !== 'homebrew/core' && tap !== 'homebrew/cask') {
      name = `${tap}/${token}`;
    }
    return kind === BrewKind.FORMULA ? `brew install ${name}` : `brew install --cask ${name}`;
  }
}
