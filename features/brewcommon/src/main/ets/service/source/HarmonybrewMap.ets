/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import type {
  LiveBottle,
  LiveBottleStable,
  LiveFormulaDoc,
  LiveService,
  LiveVersions,
} from '../BrewApiMapper';
import type { BrewKegOnlyReason } from '../../model/BrewModels';
import type { HarmonybrewFormula } from './HarmonybrewModels';

/** Harmonybrew 原始 formula → 应用现有的 LiveFormulaDoc 形状。 */
export class HarmonybrewMap {
  public static formulaToLive(token: string, tag: string, src: HarmonybrewFormula): LiveFormulaDoc {
    const versions: LiveVersions = {
      stable: src.stable_version,
      head: src.head_url_args !== undefined ? 'HEAD' : undefined,
      bottle: src.bottle_checksum !== undefined,
    };

    // §4 只要求 bottle tag 键存在；应用不消费 URL，因此不合成 bottle 文件名或 sha256。
    const bottleFiles: Record<string, Object> = {};
    const bottleFile: Record<string, Object> = {};
    bottleFiles[tag] = bottleFile;
    const bottleStable: LiveBottleStable = {
      rebuild: src.bottle_rebuild ?? 0,
      files: bottleFiles,
    };
    const bottle: LiveBottle = { stable: bottleStable };

    // §1.6 实测：apr 的 :provided_by_macos → false，但 reason 仍须非空；
    // ant@1.9 的 :versioned_formula → true。不能把「keg_only_args 存在」当作 true。
    const kegReason: BrewKegOnlyReason | null = HarmonybrewMap.kegOnlyReason(src.keg_only_args);
    const kegOnly: boolean = src.keg_only_args !== undefined && src.keg_only_args.length > 0 &&
      src.keg_only_args[0] === ':versioned_formula';

    const today: string = HarmonybrewMap.localDate();
    const deprecateMap: Record<string, string> = HarmonybrewMap.argumentMap(src.deprecate_args);
    const disableMap: Record<string, string> = HarmonybrewMap.argumentMap(src.disable_args);
    const deprecateDate: string = deprecateMap[':date'] ?? '';
    const disableDate: string = disableMap[':date'] ?? '';
    // §1.6 实测：access 的 2025-07-07 已过 → true；未来日期 → false。
    // existence 不是 disabled，必须把本地 YYYY-MM-DD 与服务端日期直接作字符串比较。
    const deprecated: boolean = deprecateDate.length > 0 && today >= deprecateDate;
    const disabled: boolean = disableDate.length > 0 && today >= disableDate;

    const dependencies: string[] = [];
    const buildDependencies: string[] = [];
    // fork 存的是 stable_dependencies 的调用参数数组；每项是名称或 {name: ':build'}。
    // 不能把它当普通对象：例如 wget 是 [{'pkgconf': ':build'}, 'openssl@3', ...]。
    const stableDependencyArgs: Object[] = src.stable_dependencies ?? [];
    stableDependencyArgs.forEach((argument: Object) => {
      if (typeof argument === 'string') {
        dependencies.push(argument);
        return;
      }
      if (typeof argument !== 'object' || argument === null || Array.isArray(argument)) {
        return;
      }
      const namedDependency: Record<string, string> = argument as Record<string, string>;
      Object.keys(namedDependency).forEach((dependency: string) => {
        if (namedDependency[dependency] === ':build') {
          buildDependencies.push(dependency);
        }
      });
    });

    // fork 存的是 uses_from_macos 的调用参数数组；展平一层后同时提取字符串与 build 参数键。
    const usesFromMacos: string[] = [];
    (src.stable_uses_from_macos ?? []).forEach((callArguments: Object) => {
      if (!Array.isArray(callArguments)) {
        return;
      }
      const argumentsList: Object[] = callArguments as Object[];
      argumentsList.forEach((argument: Object) => {
        if (typeof argument === 'string') {
          usesFromMacos.push(argument);
          return;
        }
        if (typeof argument !== 'object' || argument === null || Array.isArray(argument)) {
          return;
        }
        const namedArgument: Record<string, string> = argument as Record<string, string>;
        Object.keys(namedArgument).forEach((name: string) => usesFromMacos.push(name));
      });
    });

    // fork 存的是 conflicts 的调用参数数组；每项只取第一个 formula 名。
    const conflictsWith: string[] = [];
    (src.conflicts ?? []).forEach((callArguments: Object) => {
      if (!Array.isArray(callArguments) || callArguments.length === 0) {
        return;
      }
      const first: Object = (callArguments as Object[])[0];
      if (typeof first === 'string') {
        conflictsWith.push(first);
      }
    });

    const service: LiveService | null = HarmonybrewMap.service(src.service_run_args);
    const doc: LiveFormulaDoc = {
      token: token,
      name: token,
      full_name: token,
      desc: src.desc,
      homepage: src.homepage,
      license: src.license,
      versions: versions,
      bottle: bottle,
      keg_only: kegOnly,
      keg_only_reason: kegReason,
      deprecated: deprecated,
      deprecation_date: deprecateDate,
      // §1.6 实测：deprecation reason 去冒号，而 keg-only reason 保留冒号。
      deprecation_reason: HarmonybrewMap.withoutLeadingColon(deprecateMap[':because']),
      deprecation_replacement_formula: deprecateMap[':replacement_formula'],
      deprecation_replacement_cask: deprecateMap[':replacement_cask'],
      disabled: disabled,
      disable_date: disableDate,
      disable_reason: HarmonybrewMap.withoutLeadingColon(disableMap[':because']),
      versioned_formulae: src.versioned_formulae ?? [],
      aliases: src.aliases ?? [],
      executables: src.executables ?? [],
      requirements: [],
      caveats: src.caveats,
      dependencies: dependencies,
      build_dependencies: buildDependencies,
      optional_dependencies: [],
      recommended_dependencies: [],
      uses_from_macos: usesFromMacos,
      conflicts_with: conflictsWith,
      service: service,
    };
    return doc;
  }

  private static kegOnlyReason(args: Object[] | undefined): BrewKegOnlyReason | null {
    if (args === undefined) {
      return null;
    }
    const reason: string = args.length > 0 && typeof args[0] === 'string' ? args[0] as string : '';
    const explanation: string = args.length > 1 && typeof args[1] === 'string' ? args[1] as string : '';
    const out: BrewKegOnlyReason = { reason: reason, explanation: explanation };
    return out;
  }

  /**
   * `deprecate_args` / `disable_args` 是**哈希**（键带前导冒号），直接取用即可。
   *
   * 早先它们被误声明成 `Object[]`（把「凡 `*_args` 皆数组」的规则用得过宽），
   * 于是这里不得不写一段数组兼容分支。类型修正后该分支已删除 —— 保留它只会
   * 掩盖真实形状、让后来人以为这两个字段有第二种形态。
   */
  private static argumentMap(args: Record<string, string> | undefined): Record<string, string> {
    return args ?? {};
  }

  private static withoutLeadingColon(value: string | undefined): string | undefined {
    if (value === undefined) {
      return undefined;
    }
    return value.startsWith(':') ? value.substring(1) : value;
  }

  private static service(args: Object[] | undefined): LiveService | null {
    if (args === undefined || args.length === 0 || !Array.isArray(args[0])) {
      return null;
    }
    const run: string[] = args[0] as string[];
    const out: LiveService = { run: run };
    return out;
  }

  /** 不用 toISOString（UTC 会让边界日期错一天），也不用 Date 解析服务端日期。 */
  private static localDate(): string {
    const now: Date = new Date();
    const year: string = String(now.getFullYear());
    const month: string = String(now.getMonth() + 1).padStart(2, '0');
    const day: string = String(now.getDate()).padStart(2, '0');
    return `${year}-${month}-${day}`;
  }
}
