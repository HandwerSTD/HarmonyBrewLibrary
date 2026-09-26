/*
 * Copyright (c) 2026 即刻鸟网络科技（青岛）有限公司. Licensed under the Apache License, Version 2.0.
 */

import { preferences } from '@kit.ArkData';
import { Logger } from '@ohos/common';
import { BREW_OFFICIAL_SOURCE_ID, BREW_SOURCE_VERIFY } from '../constant/BrewSourceConstants';
import {
  BrewProbeResult,
  BrewSource,
  BrewSourceCacheStats,
  BrewSourceHealth,
  BrewSourceReach,
} from '../model/BrewSourceModels';
import { BrewSourceStore } from './BrewSourceStore';
import { BrewSourceUrlCheck, BrewSourceUrl } from './BrewSourceUrl';
import { BrewSourcePrefs } from './BrewSourcePrefs';
import { BrewSourceProbe } from './BrewSourceProbe';
import { BrewCacheAdmin } from './BrewCacheAdmin';
import { HarmonybrewMap } from './source/HarmonybrewMap';
import type { HarmonybrewFormula } from './source/HarmonybrewModels';
import type { LiveFormulaDoc } from './BrewApiMapper';

const TAG: string = '[BrewSource]';

/**
 * 源子系统的自检。**默认关**（`BREW_SOURCE_VERIFY`），只在验证改动时开一次。
 *
 * 与 `BREW_META_VERIFY` 同一模式：本项目不用 ohosTest，所以把「一次性验证」做成
 * 一条开关 + 一组 `[BrewSource] verify …` 判据行。Task 5 / Task 6 会往这里追加用例。
 *
 * 输出格式固定：`[BrewSource] verify <用例> … ok=<bool>` —— 一条 grep 就能对账。
 */
export class BrewSourceDiagnostics {
  public static run(): void {
    if (!BREW_SOURCE_VERIFY) {
      return;
    }
    BrewSourceDiagnostics.registryCases();
    BrewSourceDiagnostics.urlCases();
    BrewSourceDiagnostics.prefsCases();
    BrewSourceDiagnostics.probeCases();
    BrewSourceDiagnostics.harmonybrewMapCases();
    BrewSourceDiagnostics.cacheCases();
  }

  private static registryCases(): void {
    const sources: BrewSource[] = BrewSourceStore.listSources();
    const officialFirst: boolean = sources.length > 0 && sources[0].id === BREW_OFFICIAL_SOURCE_ID;
    const officialCount: number =
      sources.filter((one: BrewSource) => one.id === BREW_OFFICIAL_SOURCE_ID).length;
    Logger.info(TAG, `verify registry n=${sources.length} active=${BrewSourceStore.activeId()} ` +
      `officialFirst=${officialFirst} officialCount=${officialCount} ` +
      `ok=${officialFirst && officialCount === 1}`);
    const session: BrewSource = BrewSourceStore.sessionActive();
    Logger.info(TAG, `verify session id=${session.id} base=${session.baseUrl} ok=${session.baseUrl.length > 0}`);
  }

  /**
   * 一条「应被拒绝」的 URL 用例。
   *
   * **原因码必须精确匹配**：只打印 `reason` 不算判据 —— 原先写的是 `ok=${!check.ok}`，
   * 那个断言对**任何**拒绝理由都成立，所以 `https://` 被误报成 `scheme` 时它照样打 `ok=true`。
   */
  private static expectReject(raw: string, expected: string): void {
    const check: BrewSourceUrlCheck = BrewSourceUrl.check(raw);
    const ok: boolean = !check.ok && check.reason === expected;
    Logger.info(TAG, `verify url reject raw="${raw}" ok=${ok} ` +
      `reason=${check.reason} expected=${expected}`);
  }

  /** 一条「应被接受并归一化成 `expected`」的用例 */
  private static expectNormalized(raw: string, expected: string): void {
    const check: BrewSourceUrlCheck = BrewSourceUrl.check(raw);
    const ok: boolean = check.ok && check.normalized === expected;
    Logger.info(TAG, `verify url accept raw="${raw}" ok=${ok} ` +
      `value=${check.normalized} expected=${expected}`);
  }

  private static urlCases(): void {
    // 用例 1：合法 + 去尾斜杠
    const good: BrewSourceUrlCheck = BrewSourceUrl.check('  https://formulae.brew.sh/api/  ');
    Logger.info(TAG, `verify url normalize ok=${good.ok && good.normalized === 'https://formulae.brew.sh/api'} ` +
      `value=${good.normalized}`);
    // 用例 2：带路径前缀的镜像必须原样保留路径段
    const prefixed: BrewSourceUrlCheck = BrewSourceUrl.check('https://host/homebrew/api');
    const joined: string = BrewSourceUrl.join(prefixed.normalized, '/formula/wget.json');
    Logger.info(TAG, `verify url prefix ok=${joined === 'https://host/homebrew/api/formula/wget.json'} ` +
      `value=${joined}`);
    // 用例 3：非法输入各自的原因码（精确断言，不是只打印）
    BrewSourceDiagnostics.expectReject('', 'empty');
    BrewSourceDiagnostics.expectReject('ftp://host/api', 'scheme');
    BrewSourceDiagnostics.expectReject('notaurl', 'scheme');
    BrewSourceDiagnostics.expectReject('https:', 'scheme');
    // ⚠ 这一条曾经误报成 `scheme`：`normalize` 无限剥尾斜杠会把 `//` 分隔符也剥掉
    //（`https://` → `https:`），于是 `validate` 的 scheme 判定失败。
    // 用户输入 `https://` 却被告知「必须以 http:// 或 https:// 开头」，而他确实写了。
    // 它们缺的是**主机名**，期望值本来就该是 `host`。
    BrewSourceDiagnostics.expectReject('https://', 'host');
    BrewSourceDiagnostics.expectReject('http://', 'host');
    BrewSourceDiagnostics.expectReject('https://host/api?a=1', 'query');
    BrewSourceDiagnostics.expectReject('https://host/api#x', 'fragment');
    // 用例 4：尾斜杠归一化 —— 只剥 authority 之后的斜杠，不碰分隔符与空 authority
    BrewSourceDiagnostics.expectNormalized('https://host/', 'https://host');
    BrewSourceDiagnostics.expectNormalized('https://host////', 'https://host');
    BrewSourceDiagnostics.expectNormalized('https://user@host/api/', 'https://user@host/api');
  }

  private static prefsCases(): void {
    // 只验证「能开、能读写、键名不变」。clear/drop 的用例在 Task 6 追加。
    const sessionId: string = BrewSourceStore.sessionActive().id;
    const name: string = BrewSourcePrefs.storeNameOf(sessionId);
    const probeKey: string = 'brew_verify_probe';
    BrewSourcePrefs.set<string>(probeKey, 'hello');
    const back: string | null = BrewSourcePrefs.get<string>(probeKey);
    const store: preferences.Preferences | null = BrewSourcePrefs.openFor(sessionId);
    let hasKey: boolean = false;
    try {
      hasKey = store !== null && store.hasSync(probeKey);
    } catch (err) {
      hasKey = false;
    }
    Logger.info(TAG, `verify prefs storeName=${name} writeBack=${back} hasKey=${hasKey} ` +
      `ok=${back === 'hello' && hasKey}`);
    // 清掉探针键，别把垃圾留在真实 store 里
    if (store !== null) {
      try {
        store.deleteSync(probeKey);
      } catch (err) {
        Logger.error(TAG, 'verify prefs cleanup failed');
      }
    }
  }

  private static probeCases(): void {
    // 用例 1：合法地址（会话激活源）→ 期望 ok
    BrewSourceProbe.check(BrewSourceStore.activeBaseUrl())
      .then((r: BrewProbeResult) => Logger.info(TAG,
        `verify probe ok-case ok=${r.ok} reason=${r.reason} code=${r.httpCode} ms=${r.tookMs}`))
      .catch(() => Logger.error(TAG, 'verify probe ok-case threw'));
    // 用例 2：格式非法 → invalid-url（不发请求）
    BrewSourceProbe.check('notaurl')
      .then((r: BrewProbeResult) => Logger.info(TAG,
        `verify probe invalid ok=${!r.ok && r.reason === 'invalid-url'} reason=${r.reason}`))
      .catch(() => Logger.error(TAG, 'verify probe invalid threw'));
    // 用例 3：DNS 必然失败 → dns / network-unknown
    BrewSourceProbe.check('https://nonexistent-host-for-verify.invalid/api')
      .then((r: BrewProbeResult) => Logger.info(TAG,
        `verify probe dns ok=${!r.ok} reason=${r.reason}`))
      .catch(() => Logger.error(TAG, 'verify probe dns threw'));
    // 用例 4：不存在的 token → http-404
    // （直接构造 URL：之前这里先对激活源发一次 check 再把返回值丢掉，等于白发一个请求）
    BrewSourceProbe.check(
      BrewSourceUrl.join(BrewSourceStore.activeBaseUrl(), '/formula/zzz-not-a-real-token-verify.json'))
      .then((r: BrewProbeResult) => Logger.info(TAG,
        `verify probe 404 ok=${!r.ok && r.reason === 'http-404'} reason=${r.reason} code=${r.httpCode}`))
      .catch(() => Logger.error(TAG, 'verify probe 404 threw'));
  }

  /**
   * Harmonybrew 映射的固定样本断言。数据形状取自 2026-09-24 的 JWS 实测 payload；
   * 这里不从网络取样本，保证验证离线可重复，也能单独覆盖 fork DSL 的反解规则。
   */
  private static harmonybrewMapCases(): void {
    const tag: string = 'arm64_ohos';

    // 样本 1 apr：:provided_by_macos 在非 macOS 上不是 keg-only，但 reason 不能丢。
    const aprSource: HarmonybrewFormula = BrewSourceDiagnostics.harmonySample(
      '{"stable_version":"1.7.6","bottle_checksum":"sha256-apr",' +
      '"keg_only_args":[":provided_by_macos","Apple\'s CLT provides apr"],' +
      '"stable_dependencies":["util-linux"],"stable_uses_from_macos":[["libxcrypt"]]}');
    const apr: LiveFormulaDoc = HarmonybrewMap.formulaToLive('apr', tag, aprSource);
    const aprReason: string | undefined = apr.keg_only_reason?.reason;
    const aprFiles: Record<string, Object> | undefined = apr.bottle?.stable?.files;
    const aprOk: boolean = apr.versions?.stable === '1.7.6' && apr.versions?.head === undefined &&
      apr.tap === undefined && apr.keg_only === false && aprReason === ':provided_by_macos' &&
      aprFiles !== undefined && Object.keys(aprFiles).indexOf(tag) >= 0;
    Logger.info(TAG, `verify harmonybrew-map token=apr stable=${apr.versions?.stable} ` +
      `kegOnly=${apr.keg_only} reason=${aprReason} ok=${aprOk}`);

    // 样本 2 ant@1.9：只有 :versioned_formula 才把 keg_only 判为 true。
    const antSource: HarmonybrewFormula = BrewSourceDiagnostics.harmonySample(
      '{"stable_version":"1.9.16","bottle_checksum":"sha256-ant",' +
      '"keg_only_args":[":versioned_formula"],"stable_dependencies":["openjdk"]}');
    const ant: LiveFormulaDoc = HarmonybrewMap.formulaToLive('ant@1.9', tag, antSource);
    const antOk: boolean = ant.keg_only === true && ant.keg_only_reason?.reason === ':versioned_formula';
    Logger.info(TAG, `verify harmonybrew-map token=ant@1.9 kegOnly=${ant.keg_only} ` +
      `reason=${ant.keg_only_reason?.reason} ok=${antOk}`);

    // 样本 3 access：过期日期生效，deprecation reason 去冒号。
    const accessSource: HarmonybrewFormula = BrewSourceDiagnostics.harmonySample(
      '{"deprecate_args":{":date":"2024-07-07",":because":":unmaintained"},' +
      '"disable_args":{":date":"2025-07-07",":because":":unmaintained"},' +
      '"stable_version":"0.10.13","bottle_checksum":"sha256-access",' +
      '"stable_dependencies":[{"go":":build"}]}');
    const access: LiveFormulaDoc = HarmonybrewMap.formulaToLive('access', tag, accessSource);
    const accessOk: boolean = access.deprecated === true && access.disabled === true &&
      access.deprecation_reason === 'unmaintained' && access.disable_reason === 'unmaintained';
    Logger.info(TAG, `verify harmonybrew-map token=access deprecated=${access.deprecated} ` +
      `disabled=${access.disabled} deprecationReason=${access.deprecation_reason} ok=${accessOk}`);

    // 日期存在不等于已生效；2999 的构造样本必须仍为 false。
    const futureSource: HarmonybrewFormula = BrewSourceDiagnostics.harmonySample(
      '{"deprecate_args":{":date":"2998-01-01",":because":":future"},' +
      '"disable_args":{":date":"2999-01-01",":because":":future"}}');
    const future: LiveFormulaDoc = HarmonybrewMap.formulaToLive('future-disable-verify', tag, futureSource);
    const futureOk: boolean = future.deprecated === false && future.disabled === false;
    Logger.info(TAG, `verify harmonybrew-map token=future-disable-verify ` +
      `deprecated=${future.deprecated} disabled=${future.disabled} ok=${futureOk}`);

    // 样本 4 aliddns：stable_dependencies 的 DSL 调用参数对象要拆成 build dependency，
    // service_run_args[0] 则原样作为 service.run。
    const aliddnsSource: HarmonybrewFormula = BrewSourceDiagnostics.harmonySample(
      '{"stable_version":"0.0.23","bottle_checksum":"sha256-aliddns",' +
      '"stable_dependencies":[{"go":":build"}],' +
      '"service_run_args":[["$HOMEBREW_PREFIX/opt/aliddns/bin/aliddns","-c",' +
      '"$HOMEBREW_PREFIX/etc/aliddns/aliddns.yaml"]]}');
    const aliddns: LiveFormulaDoc = HarmonybrewMap.formulaToLive('aliddns', tag, aliddnsSource);
    const aliddnsBuild: Object[] | undefined = aliddns.build_dependencies as Object[] | undefined;
    const aliddnsRun: Object | undefined = aliddns.service?.run;
    const aliddnsOk: boolean = aliddns.dependencies?.length === 0 && aliddnsBuild?.length === 1 &&
      aliddnsBuild[0] === 'go' && Array.isArray(aliddnsRun) &&
      (aliddnsRun as Object[])[0] === '$HOMEBREW_PREFIX/opt/aliddns/bin/aliddns';
    Logger.info(TAG, `verify harmonybrew-map token=aliddns runtime=${aliddns.dependencies?.length} ` +
      `build=${aliddnsBuild?.length} service=${aliddnsRun !== undefined} ok=${aliddnsOk}`);

    // 样本 5 apr-util：stable_uses_from_macos 是调用参数数组的数组，只展平一层。
    const aprUtilSource: HarmonybrewFormula = BrewSourceDiagnostics.harmonySample(
      '{"stable_version":"1.6.5","bottle_checksum":"sha256-apr-util",' +
      '"stable_dependencies":["apr","openssl@3","unixodbc"],' +
      '"stable_uses_from_macos":[["expat"],["libxcrypt"],["sqlite"]]}');
    const aprUtil: LiveFormulaDoc = HarmonybrewMap.formulaToLive('apr-util', tag, aprUtilSource);
    const aprUtilUses: Object[] | undefined = aprUtil.uses_from_macos as Object[] | undefined;
    const aprUtilOk: boolean = aprUtilUses !== undefined && aprUtilUses.length === 3 &&
      aprUtilUses[0] === 'expat' && aprUtilUses[1] === 'libxcrypt' && aprUtilUses[2] === 'sqlite';
    Logger.info(TAG, `verify harmonybrew-map token=apr-util uses=${aprUtilUses?.length} ok=${aprUtilOk}`);
  }

  private static harmonySample(json: string): HarmonybrewFormula {
    try {
      return JSON.parse(json) as HarmonybrewFormula;
    } catch (error) {
      Logger.error(TAG, `verify harmonybrew-map sample parse failed: ${error}`);
      const empty: HarmonybrewFormula = {};
      return empty;
    }
  }

  private static cacheCases(): void {
    // 用一次性 throwaway 源走完整链路：新增 → 写垃圾 → stats → clear → drop → 确认 store 已删。
    // 全程不碰真实源，所以可以在任何设备上反复跑。
    const created: BrewSource | undefined = BrewSourceStore.addSource(
      'verify-throwaway', 'https://verify-throwaway.invalid/api');
    if (created === undefined) {
      Logger.error(TAG, 'verify cache setup failed (addSource returned undefined)');
      return;
    }
    const id: string = created.id;
    // 直接往该源的 store 里塞两个键
    const store: preferences.Preferences | null = BrewSourcePrefs.openFor(id);
    if (store === null) {
      Logger.error(TAG, 'verify cache setup failed (store null)');
      return;
    }
    try {
      // 直接写 JSON 字符串，不用 `JSON.stringify({...})`：
      // ArkTS 的 `arkts-no-untyped-obj-literals` 不允许把无类型对象字面量当实参传出去。
      // 形状与真实缓存一致：live_data = 3 个 doc，meta_index = formula 1 条 + cask 0 条。
      store.putSync('brew_live_data', '{"a":1,"b":2,"c":3}');
      store.putSync('brew_meta_index',
        '{"ts":' + Date.now() + ',"formula":{"x":"d"},"cask":{}}');
    } catch (err) {
      Logger.error(TAG, 'verify cache setup putSync failed');
    }
    BrewSourcePrefs.releaseFor(id);

    const stats1: BrewSourceCacheStats = BrewCacheAdmin.stats(id);
    Logger.info(TAG, `verify cache stats keys=${stats1.keys} entries=${stats1.entries} ` +
      `bytes=${stats1.approxBytes} ok=${stats1.keys === 2 && stats1.entries === 4}`);

    BrewCacheAdmin.clear(id).then(() => {
      // 这一步现在是**持久化断言**：`clear()` 末尾的 `persistNow()` 把该源实例移出了内存、
      // 并作废了句柄，所以 `stats()` 里的 `openFor()` 必须重新 `getPreferencesSync` 读盘。
      // `keys=0` 意味着「磁盘上真的空了」，而不只是「内存里空了」。
      const stats2: BrewSourceCacheStats = BrewCacheAdmin.stats(id);
      Logger.info(TAG, `verify cache cleared keys=${stats2.keys} ok=${stats2.keys === 0} ` +
        '(经persistNow踢出内存后重新读盘)');
      return BrewCacheAdmin.drop(id);
    }).then(() => {
      // drop 之后再开同名 store 应该是空的（文件已删 → 重新创建）
      const stats3: BrewSourceCacheStats = BrewCacheAdmin.stats(id);
      const gone: boolean = BrewSourceStore.find(id) === undefined;
      Logger.info(TAG, `verify cache dropped registryGone=${gone} keysAfterDrop=${stats3.keys} ` +
        `ok=${gone && stats3.keys === 0}`);
      // Review Focus #4：删掉后立刻用**同名但新 id** 新增，不能复用旧缓存。
      // 复用会体现在「新源的 store 一开就有键」—— 因为 store 名带 id，所以这里必须是 0。
      const again: BrewSource | undefined = BrewSourceStore.addSource(
        'verify-throwaway', 'https://verify-throwaway.invalid/api');
      if (again === undefined) {
        Logger.error(TAG, 'verify cache re-add failed');
        return Promise.resolve();
      }
      const fresh: BrewSourceCacheStats = BrewCacheAdmin.stats(again.id);
      const distinct: boolean = again.id !== id;
      Logger.info(TAG, `verify cache re-added newId=${distinct} keys=${fresh.keys} ` +
        `ok=${distinct && fresh.keys === 0}`);
      return BrewCacheAdmin.drop(again.id);
    }).then(() => {
      // Review Focus #2 / 2026-09-25 拆分：健康状态机。不碰网络，直接构造运行期记录。
      //
      // **断言的核心是两条轴互不影响**（改动前 `healthState` 先读 `lastProbe*`，
      // 于是「探测失败」会把数据状态一起拉成 FAILING，卡片上就出现
      // 「刚点测试连接说可用、列表说部分可用」这种看起来自相矛盾的状态）：
      //   - 数据轴 `healthState`：只由 catalog / meta / hydrate 三个写入点决定；
      //   - 连通性轴 `reachState`：只由 `noteProbe` 决定。
      // 另外覆盖「没取到数据 ≠ 正常」（`UNKNOWN`）与「清缓存后数据轴作废、连通性保留」。
      // 自检在 `BrewMetaSync.start()` 里、早于真实 sync 与目录取数，所以这里改过的记录
      // 随后会被真实事件覆盖，不会掩盖真问题。
      const id2: string = BrewSourceStore.sessionActive().id;
      BrewSourceStore.noteProbe(id2, true, 'ok');
      const rOk: BrewSourceReach = BrewSourceStore.reachState(id2);
      const sNotReady: BrewSourceHealth = BrewSourceStore.healthState(id2);
      BrewSourceStore.noteCatalogOk(id2);
      const sCatalogOnly: BrewSourceHealth = BrewSourceStore.healthState(id2);
      BrewSourceStore.noteMetaOk(id2, 100);
      const sOk: BrewSourceHealth = BrewSourceStore.healthState(id2);

      BrewSourceStore.noteError(id2, 'meta', 'verify-meta');
      const sMetaErr: BrewSourceHealth = BrewSourceStore.healthState(id2);

      BrewSourceStore.noteMetaOk(id2, 100);
      const sMetaOk: BrewSourceHealth = BrewSourceStore.healthState(id2);

      BrewSourceStore.noteError(id2, 'catalog', 'verify-catalog');
      const sCatalogErr: BrewSourceHealth = BrewSourceStore.healthState(id2);

      BrewSourceStore.noteCatalogOk(id2);
      const sCatalogOk: BrewSourceHealth = BrewSourceStore.healthState(id2);

      // 探测失败：连通性轴转 FAILING，**数据轴必须原样不动**（=OK）
      BrewSourceStore.noteProbe(id2, false, 'http-404');
      const rFailing: BrewSourceReach = BrewSourceStore.reachState(id2);
      const sAfterProbeFail: BrewSourceHealth = BrewSourceStore.healthState(id2);

      // 清空缓存路径：数据轴记录作废 → 回到「未就绪」，但连通性结论（远端地址的属性）保留
      BrewSourceStore.resetDataHealth(id2);
      const sAfterReset: BrewSourceHealth = BrewSourceStore.healthState(id2);
      const rAfterReset: BrewSourceReach = BrewSourceStore.reachState(id2);

      const allOk: boolean = rOk === BrewSourceReach.OK && rFailing === BrewSourceReach.FAILING &&
        rAfterReset === BrewSourceReach.FAILING &&
        sNotReady === BrewSourceHealth.UNKNOWN && sCatalogOnly === BrewSourceHealth.UNKNOWN &&
        sOk === BrewSourceHealth.OK && sMetaErr === BrewSourceHealth.PARTIAL &&
        sMetaOk === BrewSourceHealth.OK && sCatalogErr === BrewSourceHealth.PARTIAL &&
        sCatalogOk === BrewSourceHealth.OK && sAfterProbeFail === BrewSourceHealth.OK &&
        sAfterReset === BrewSourceHealth.UNKNOWN;
      Logger.info(TAG, `verify health axisSplit reach=${rOk}/${rFailing}/${rAfterReset} ` +
        `data notReady=${sNotReady} catalogOnly=${sCatalogOnly} ok=${sOk} metaErr=${sMetaErr} ` +
        `metaOk=${sMetaOk} catalogErr=${sCatalogErr} catalogOk=${sCatalogOk} ` +
        `afterProbeFail=${sAfterProbeFail} afterReset=${sAfterReset} allOk=${allOk}`);

      // 复原：别把自检造出来的失败记录留在真实源上
      BrewSourceStore.noteProbe(id2, true, 'ok');
      BrewSourceStore.noteCatalogOk(id2);
      BrewSourceStore.noteMetaOk(id2, 100);
    }).catch(() => Logger.error(TAG, 'verify cache chain threw'));
  }
}
