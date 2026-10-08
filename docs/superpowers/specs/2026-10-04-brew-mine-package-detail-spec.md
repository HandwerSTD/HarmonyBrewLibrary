# brew「我的」本机包点进包详情页 · 设计

> 日期：2026-10-04。状态：待评审。评审通过后由 `writing-plans` 产出实施计划。
> 范围：`features/mine` 的三处本机包行接上点击进入详情页；`features/brewcommon` 的详情取数层
> 区分「数据源里没有这个包」与「取数失败」；`features/brewdetail` 增加「未找到」整页占位。
> 相关文档：[`brew-api-design.md`](../../brew-api-design.md) §10.4 / §12、
> [`brew-handover.md`](../../brew-handover.md) §6.2 / §6.3。

---

## 1. 现状

| 位置 | 现状 |
| --- | --- |
| `features/brewcommon/src/main/ets/component/BrewLocalPackageRow.ets` | 行组件只有图标、包名、版本、安装来源。文件头注释写明「没有箭头、不可点击：本机包数据里只有 token，没有商店目录里的包 id，无法据此打开详情页」 |
| `features/mine/src/main/ets/component/MinePackageCard.ets` | 「待更新」「已更新」两张卡片各预览 3 行，行不可点，只有卡内「查看全部」能进二级页 |
| `features/mine/src/main/ets/view/MinePackagesView.ets` | 本机包二级页的行同样不可点 |
| `features/brewcommon/src/main/ets/model/BrewModels.ets:302` | `BrewDetailParams = { kind, title, id, token, categoryKey }`；`id` 一直由目录条目给出 |
| `features/brewcommon/src/main/ets/model/BrewRepository.ets:137` | `getFormulaDetail(componentId, token)`：派生出来的 id 只用于构造展示数据，缓存写入与读取用的是传进来的 `componentId` |
| `features/brewcommon/src/main/ets/model/BrewRepository.ets:154` | 取数失败一律走回退，顺序是「上一次成功归一过的详情 → 只剩骨架的 base」 |
| `features/brewcommon/src/main/ets/service/BrewService.ets:159` | 非 200 一律 `throw new Error('unexpected status N')`，404 与 500 在调用方看来是同一件事 |
| `features/brewdetail/src/main/ets/view/BrewDetailView.ets:90` | 重试只在 `params.id > 0` 时执行 |

设备上的本机包来自设备上的 harmonybrew（`brew info --json=v2 --installed`），其中可能有
自定义 tap 的 formula；应用的激活数据源是官方源（`formulae.brew.sh`）或 harmonybrew 镜像。
token 不在数据源目录里时，单条取数返回 404，现有的回退把 404 当作普通失败，页面显示的是
「只剩 token 与 `brew install <token>` 的骨架」。这个页面既看不出「数据源里没有这个包」，
也没有任何失败提示。

---

## 2. 成功判据

| # | 判据 | 可观测证据 |
| --- | --- | --- |
| G1 | 「我的」页「待更新」「已更新」两张卡片的预览行都能点进详情页 | 真机点击 |
| G2 | 本机包二级页三个筛选下的每一行都能点进详情页 | 真机点击 |
| G3 | token 在激活源里存在时，详情页与从浏览页 / 搜索页进入时完全相同（含「同分类其他包」） | 真机对照 |
| G4 | token 不在激活源里时，详情页显示「未找到」整页占位，并给出包名与可能来源 | `[brew-load] kind=detail_doc reason=absent`、`[BrewDetailVM] load absent …` |
| G5 | 取数失败且本地没有该包的历史详情时走失败态并能重试成功；有历史详情时显示历史详情 | 断网后点击，恢复网络后点重试 |
| G6 | 不同本机包不共用详情缓存槽 | 有网打开包 A 之后断网打开包 B，B 显示失败态 |
| G7 | 构建通过 | `devecocli build` 输出 `BUILD SUCCESSFUL`，`ERROR` 计数为 0 |

---

## 3. 取数结局与详情页的对应关系

| 取数结局 | 判据 | 详情页显示 |
| --- | --- | --- |
| 数据源里有这个包 | 单条取数 200；或 304 且本地有条目 | 正常内容（与从其它页面进入完全相同） |
| 数据源里没有这个包 | 单条取数 404 / 410 | 「未找到」整页占位（新增） |
| 取数失败，本地有这个包的历史详情 | 其它异常，缓存命中 | 历史详情 |
| 取数失败，本地没有历史详情 | 其它异常，缓存未命中 | 网络错误页 / 加载失败页，可重试 |
| 路由参数里 token 为空 | —— | 骨架（现状保留，本次从本机包进入时不可达） |

判定只由单条取数的应答给出。上游方言是 HTTP 状态码；Harmonybrew 方言的单条来自设备上的
归一化目录文件（`BrewCatalogFile.readRange`），文件里没有这个 token 就返回 404，
目录文件本身不存在返回 503 —— 503 属于取数失败，不属于「数据源里没有」。

点击前不预查目录：目录的两片都不完整 —— 安装量片只有统计窗口里出现过的 token，
Harmonybrew 方言的描述片还会略过描述为空的条目。用它们判定「源里有没有」，会把数据源里
确实存在、只是窗口内没有安装量或没有描述的包误判成「没有」。单条取数的应答才是权威的。

---

## 4. 路由参数

`BrewDetailParams` 的字段集合不变，`id` 的含义扩为「0 表示调用方没有目录 id」：

```ts
export interface BrewDetailParams {
  /** 包类型 */
  kind: BrewKind;
  /** 标题栏标题（先展示列表里已有的信息，详情回来后再覆写） */
  title: string;
  /** 目录里的稳定 id。**可以是 0**：本机包没有目录 id，取数层用 `tokenId(token)` 派生 */
  id: number;
  /** API 路径里的 token。本机包用 `brew info --json=v2` 输出里的 `name` 字段 */
  token: string;
  categoryKey: string;
}
```

本机包到路由参数的转换收在 `MinePackagesUtil.detailParamsOf(pkg)` 一处，两个点击入口共用：

```ts
public static detailParamsOf(pkg: BrewInstalledPackage): BrewDetailParams {
  return {
    kind: BrewFormat.brewKindOf(pkg.kind),
    title: pkg.name,
    id: 0,
    token: pkg.name,
    categoryKey: ''
  };
}
```

- **token 取 `BrewInstalledPackage.name`**：`brew info --json=v2` 的 `name` 是不带 tap 前缀的包名，
  与 `formulae.brew.sh` 单条接口路径里的 token 相同；`fullName` 只在带 tap 前缀时与它不同，
  不参与导航。自定义 tap 的包在官方源里没有对应条目，会走到「未找到」页。
- **title 用同一个值**：详情页在数据回来前先用它填标题栏（`BrewDetailView.handleOnReady` 的现有逻辑），
  「未找到」页的标题栏显示的也是它。
- **categoryKey 留空**：由取数层按词表补算（见 §6.3），算不出来就不显示「同分类其他包」。
- **id 传 0**：展示数据里的 id 由 `tokenId(token)` 派生，与目录条目派生出的 id 是同一个函数，
  同一份详情在两条入口上共用同一个缓存键；缓存的写入与读取必须跟着派生后的 id 走（见 §6.2）。

---

## 5. 三个点击入口与导航

| 入口 | 渲染位置 | 点击后 |
| --- | --- | --- |
| 「我的」页「待更新」卡片预览行 | `MinePackageCard.PreviewBuilder` | `MinePageVM.jumpToPackageDetail(pkg)` |
| 「我的」页「已更新」卡片预览行 | 同上 | 同上 |
| 本机包二级页的行 | `MinePackagesView.ContentBuilder` | `MinePackagesView.openDetail(pkg)` |

### 5.1 行组件给出可点击的外观

`BrewLocalPackageRow` 在安装来源文字后面增加右侧箭头，样式与 `BrewPackageRow.HeatBuilder`
相同（`SymbolGlyph($r('sys.symbol.chevron_right'))`、`Title_M`、`icon_secondary`、左间距
`padding_level4`）。行高与副标题（版本）的摆位不变，尾部在来源文字的右侧多一个箭头。

组件本身不持有导航逻辑：点击由调用方用 `.onClick()` 挂在组件调用上，与 `BrewPackageRow`
各处调用点的既有办法相同（`BrewDiscoverRow` 的注释把这条写成了统一规则：`.onClick()` 挂在
自定义组件调用上，命中区域就是该行的根节点）。参数式的点击回调在这个组件族里会被
`HdsListItemCard` 丢掉（`BrewPackageRow` 的历史注释记录过这次踩坑：无编译错误、无运行时报错，
行就是点不动）。文件头注释里「没有箭头、不可点击」那段改写为「箭头表示可点击，导航由调用方
挂 `onClick`」。

### 5.2 `MinePackageCard`

新增回调属性：

```ts
handlePackageClick?: (pkg: BrewInstalledPackage) => void;
```

预览行接上 `.onClick(() => this.handlePackageClick?.(pkg))`；卡头与「查看全部」的行为不变。
`MineView` 传入 `(pkg) => this.viewModel.jumpToPackageDetail(pkg)`。

### 5.3 `MinePageVM`

把「取哪个页面上下文」这段抽成一个私有方法，`jumpToPackagesPage` 与新增的
`jumpToPackageDetail` 共用：

```ts
private packagePageContext(): PageContext | undefined {
  return AppStorage.get<boolean>(StorageKey.IS_SIDEBAR_LAYOUT) ?
    AppStorage.get<PageContext>(StorageKey.MINE_PAGE_CONTEXT) :
    AppStorage.get<PageContext>(StorageKey.HOME_PAGE_CONTEXT);
}

public jumpToPackageDetail(pkg: BrewInstalledPackage): void {
  this.packagePageContext()?.openPage({
    routerName: PageEnum.BREW_DETAIL_VIEW,
    param: MinePackagesUtil.detailParamsOf(pkg),
  }, true);
}
```

### 5.4 `MinePackagesView`

本页与详情页在同一条 `NavPathStack` 上（二级页由 `MINE_PACKAGES_VIEW` 进入），
用页面自己 `onReady` 保存的 `pathStack` 继续 pushPath，返回时回到本机包页：

```ts
private openDetail(pkg: BrewInstalledPackage): void {
  this.pathStack?.pushPath({
    name: PageEnum.BREW_DETAIL_VIEW,
    param: MinePackagesUtil.detailParamsOf(pkg)
  }, true);
}
```

三处入口都不加点击节流：全仓库其它跳详情页的入口（Formulae / Casks / Discover / 搜索）
都没有节流，只在这里加会造出第二种行为。

---

## 6. 取数层（`features/brewcommon`）

### 6.1 单条取数的失败分类

`BrewService` 新增并导出：

```ts
/** 数据源确认没有这个包（404 / 410）。详情页据此显示「未找到」，不再回退到骨架。 */
export class BrewDocAbsentError extends Error {
  public readonly kind: string;
  public readonly token: string;
  public readonly status: number;

  public constructor(kind: string, token: string, status: number) {
    super('doc absent: kind=' + kind + ' token=' + token + ' status=' + status);
    this.name = 'BrewDocAbsentError';
    this.kind = kind;
    this.token = token;
    this.status = status;
  }
}
```

`fetchDoc` 的状态码分支改为：

| 状态 | 处理 |
| --- | --- |
| 200 | 解析、写入缓存（不变） |
| 304 且本地有条目 | 推进时间戳并返回缓存（不变） |
| 404 / 410 | 抛出 `BrewDocAbsentError`，保留现有的 `BrewLoadLog.warn('detail_doc', 'absent', …)` 一行 |
| 其余非 200 | 抛 `Error('unexpected status N')`（不变） |

`fetchDoc` 尾部那个汇总用的 `.catch`（现在做 `failures++`、`Logger.error('fetch failed')`、
`BrewLoadLog.warn('detail_doc', 'fetch-failed')`）必须对 `BrewDocAbsentError` 直接重新抛出：
「数据源里没有这个包」是一个确定结论，把它计进 `failures` 会让 `statsLine()` 的 `failed=` 把
「源里没有这个包」与「取数失败」算成同一类，并多打一行 `fetch-failed`。

### 6.2 `BrewRepository` 的回退顺序

`getFormulaDetail` 与 `getCaskDetail` 两处同步改：

```ts
public getFormulaDetail(componentId: number, token: string): Promise<BrewFormulaDetail> {
  const id: number = componentId > 0 ? componentId : BrewBrowseBuilder.tokenId(token);
  if (token.length === 0) {
    return Promise.resolve(this.degradedFormula(token, id));
  }
  return BrewService.fetchFormulaDoc(token)
    .then((doc: LiveFormulaDoc) => {
      const categoryKey: string = BrewTaxonomy.categoryOf(BrewKindText.FORMULA, token, doc.desc ?? '');
      const base: BrewFormulaDetail = BrewApiMapper.formulaBase(token, id, categoryKey,
        BrewService.catalogInstallsOf(BrewKindText.FORMULA, token));
      return BrewApiMapper.mergeFormula(base, doc);
    })
    .then((merged: BrewFormulaDetail) => {
      BrewService.saveDetail(id, merged);
      Logger.info(TAG, `getFormulaDetail live ok, token=${token}, v=${merged.stableVersion}`);
      return merged;
    })
    .catch((error: Error) => {
      if (error instanceof BrewDocAbsentError) {
        Logger.info(TAG, `getFormulaDetail absent, token=${token}, status=${error.status}`);
        throw error;
      }
      Logger.error(TAG, `getFormulaDetail live failed, fallback to cache. token=${token}, ${error.message}`);
      const cached: BrewFormulaDetail | null = BrewService.cachedDetail<BrewFormulaDetail>(id);
      if (cached !== null) {
        return cached;
      }
      throw error;
    });
}
```

三个要点：

1. **缓存键统一用派生后的 `id`**（现状写的是传进来的 `componentId`）。不改时，传 0 的本机包
   共用一个缓存槽：先在有网时打开包 A 会写入键 `0`，此后断网打开包 B 会显示 A 的内容。
2. **「数据源里没有」不回退到骨架**，异常直接交给详情页。
3. **「取数失败」只回退到历史详情**；没有历史详情时把异常交给详情页，由详情页走失败态。
   骨架分支只留给 token 为空的参数错误。`cachedFormulaDetail` 与 `cachedCaskDetail` 两个私有方法
删除（缓存读取写在 catch 里）。

文件头注释里「降级也不报错」那段的现有表述与实现同时改写：失败态现在承担两件事 ——
「数据源里没有这个包」（`NOT_FOUND`）与「取数失败且没有历史详情」（`FAILED` / `NO_NETWORK`）。

### 6.3 分类的补算

formula 与 cask 各新增一个方法，供详情页在路由参数没带分类时使用：

```ts
/**
 * 目录描述片里有这个 token 时按词表算出分类；没有描述就算不出分类，返回空串。
 */
public categoryKeyOf(token: string): string {
  const desc: string = BrewTable.descOf(BrewKindText.FORMULA, token);
  return desc.length === 0 ? '' : BrewTaxonomy.categoryOf(BrewKindText.FORMULA, token, desc);
}
```

只有描述片里有这个 token 才去算：描述是词表的输入，没有描述时词表会返回兜底分类，
从兜底分类里取 6 个包当「同分类其他包」没有意义。

### 6.4 导出

`features/brewcommon/Index.ets` 增加 `BrewDocAbsentError` 的值导出。

---

## 7. 详情页（`features/brewdetail`）

### 7.1 新增状态

`common/src/main/ets/constant/CommonEnums.ets` 的 `LoadingStatus` 增加一个取值：

```ts
/** 数据源里没有这个包。与 FAILED（取数失败）分开：两者的日志、文案与重试含义都不同 */
NOT_FOUND = 'not_found',
```

### 7.2 `BrewDetailViewModel.load`

catch 分支按顺序判定；三个状态都通过 `setStatus` 写入：

```ts
.catch((error: Error) => {
  if (error instanceof BrewDocAbsentError) {
    this.setStatus(state, LoadingStatus.NOT_FOUND);
    Logger.info(TAG, `load absent, kind=${param.kind} token=${param.token} status=${error.status}`);
    return;
  }
  const err: BusinessError = error as BusinessError;
  this.setStatus(state, err.code === RequestErrorCode.NETWORK_CONNECT_FAILED ?
    LoadingStatus.NO_NETWORK : LoadingStatus.FAILED);
  Logger.error(TAG, `load failed. ${err.code} ${err.message}`);
});
```

「未找到」用 `info`：这是数据源给出的确定结论，属于正常结果。

**状态要整体替换 `loadingModel`，不能写 `loadingModel.loadingStatus`**：页面用 `@State detailState`
持有 `BrewDetailState`，而状态管理 V1 对 `@State` 对象只观察**第一层属性**。写第二层属性时
日志里有状态、页面一帧不变 —— 失败态与「未找到」态内容区永远空白，连重试按钮都出不来；
成功路径一直正常是因为 `state.data = data` 是第一层赋值，它触发的重渲染顺带把状态读了出来。
`setStatus` 内部是 `state.loadingModel = new LoadingModel(status)`。

`loadSiblings` 使用的分类改为「参数里非空就用参数，否则用 `categoryKeyOf(param.token)`」，
两个 model 各调一个（`kind` 决定用哪个）。空串会让「同分类其他包」保持为空，与现状相同。

### 7.3 `BrewDetailView`

`build()` 增加一个分支：

```ts
} else if (this.detailState.loadingModel.loadingStatus === LoadingStatus.NOT_FOUND) {
  StatePlaceholderView({
    kind: StatePlaceholderKind.EMPTY,
    message: $r('app.string.brew_detail_absent', this.detailState.params.token),
    actionLabel: $r('app.string.state_retry'),
    onAction: () => {
      this.retry();
    },
  })
}
```

`StatePlaceholderView` 与 `StatePlaceholderKind` 来自 `@ohos/common`，两张分类二级页与榜单二级页的
`EMPTY_DATA` 分支用的是同一个组件，版式一致。

重试条件放宽到「有 token 也可以」：

```ts
private retry(): void {
  const params: BrewDetailParams = this.detailState.params;
  if (params.id > 0 || params.token.length > 0) {
    this.viewModel.load(params, this.detailState);
  }
}
```

不改时，从本机包进入（id 传 0）的详情页在失败态与「未找到」页上点重试没有任何反应。

---

## 8. 文案

`features/brewcommon/src/main/resources/{base,en_US,zh_CN}/element/string.json` 增加一条：

| 资源名 | base / en_US | zh_CN |
| --- | --- | --- |
| `brew_detail_absent` | `%s is not in the current data source. It may come from a custom tap.` | `当前数据源中没有「%s」这个包，它可能来自自定义 tap` |

重试按钮复用 `common` 的 `app.string.state_retry`（「重试」），与分类二级页、榜单二级页相同。

来源用「可能」：本机包只给出包名与安装位置，判断不了它从哪个 tap 装进来。

---

## 9. 改动清单

### 9.1 新增

- 本文件。

### 9.2 修改

| 文件 | 改动 |
| --- | --- |
| `common/src/main/ets/constant/CommonEnums.ets` | `LoadingStatus` 增加 `NOT_FOUND` |
| `features/brewcommon/src/main/ets/service/BrewService.ets` | 新增并导出 `BrewDocAbsentError`；`fetchDoc` 的 404 / 410 分支改为抛出它 |
| `features/brewcommon/src/main/ets/model/BrewRepository.ets` | `getFormulaDetail` / `getCaskDetail`：缓存键改用派生 id，区分「数据源里没有」与「取数失败」，失败时不再回退到骨架；新增 `categoryKeyOf`；改写文件头注释 |
| `features/brewcommon/Index.ets` | 导出 `BrewDocAbsentError` |
| `features/brewcommon/src/main/ets/model/BrewModels.ets` | `BrewDetailParams` 的 `id` / `token` 注释写明 0 的含义与 token 的来源 |
| `features/brewcommon/src/main/ets/component/BrewLocalPackageRow.ets` | 安装来源文字后增加右侧箭头；文件头注释改写 |
| `features/brewcommon/src/main/resources/base/element/string.json` | 增加 `brew_detail_absent` |
| `features/brewcommon/src/main/resources/en_US/element/string.json` | 同上 |
| `features/brewcommon/src/main/resources/zh_CN/element/string.json` | 同上 |
| `features/mine/src/main/ets/util/MinePackagesUtil.ets` | 增加 `detailParamsOf(pkg)` |
| `features/mine/src/main/ets/component/MinePackageCard.ets` | 增加 `handlePackageClick`，预览行接上点击 |
| `features/mine/src/main/ets/view/MineView.ets` | 把 `handlePackageClick` 接到 `MinePageVM.jumpToPackageDetail` |
| `features/mine/src/main/ets/view/MinePackagesView.ets` | 行接上点击，新增 `openDetail(pkg)` |
| `features/mine/src/main/ets/viewmodel/MinePageVM.ets` | 新增 `packagePageContext()` 与 `jumpToPackageDetail(pkg)`；`jumpToPackagesPage` 改用 `packagePageContext()` |
| `features/mine/src/main/ets/viewmodel/MinePackagesVM.ets` | 加载状态改为整体替换 `loadingModel`（失败路径没有一级属性赋值跟着触发重渲染，原先会一直停在转圈） |
| `features/brewdetail/src/main/ets/viewmodel/BrewDetailViewModel.ets` | `load` 区分「未找到」并把三个状态都改为整体替换 `loadingModel`；`loadSiblings` 用补算后的分类 |
| `features/brewdetail/src/main/ets/viewmodel/BrewDetailState.ets` | 注释写明 `loadingModel` 由 VM 整体替换的原因 |
| `features/brewdetail/src/main/ets/view/BrewDetailView.ets` | 「未找到」分支；`retry` 条件放宽 |
| `docs/brew-api-design.md` | §11 把「本机包行不可点击」一行改为已完成；§12.1 补上三个点击入口与路由参数口径；§7.4 的「我的（本机包）」一行改正为读设备上的 brew 安装记录，包详情页一行与 §10.4 补上「未找到 / 失败态 / 历史详情」的分流 |
| `docs/brew-handover.md` | 把「本机包行不可点」一行改为已完成；§6.2 的回退顺序改写为「历史详情 → 失败态」并补上「未找到」；§6.3 补上三个点击入口与 id 传 0 的口径 |

### 9.3 不动

- `BrewInstalledPackage`、`BrewInstalledLoader`、`BrewInstalledParser`：本机包字段与取数方式不变。
- `BrewDetailParams` 的字段集合。
- `MinePackagesVM`、`MinePackagesState`、`MinePageState`、`MinePackageSets`：列表与筛选口径不变。
- `StatePlaceholderView`：不改公共组件。
- 三处本机包入口里的「查看全部」与「已安装」行的现有跳转。

---

## 10. 上机验证

1. **构建**：`devecocli build`，`ERROR` 计数为 0。
2. **卡片预览行**：「我的」页「待更新」卡片预览的第一行点进详情页并能返回；「已更新」卡片同样。
3. **二级页**：「已安装」入口进本机包二级页，三个 chips 下各点一行，都能进详情页。
4. **源里存在的包**（例如 `wget`）：详情页的标题、描述、版本、安装命令、各分区与从搜索页进入时相同，
   「同分类其他包」非空。
5. **源里不存在的包**：从 `brew info --json=v2 --installed` 的输出里找一个 `name` 不在激活源目录里的包
   （自定义 tap 安装的 formula 就是这种情况）。点击后应看到
   「当前数据源中没有「X」这个包，它可能来自自定义 tap」，页面没有安装命令与分区；
   hilog 里有 `[brew-load] kind=detail_doc reason=absent` 与
   `[BrewDetailVM] load absent, kind=formula token=X status=404`；点重试仍停在该页；返回键回到本机包页。
   设备上没有这样的包时，临时用自定义 tap 安装一个小 formula 作为验证对象（真实安装，不使用假数据）。
6. **缓存槽不共用**：有网时打开本机包 A（详情正常），断网后打开本机包 B —— B 显示失败态，
   不能出现 A 的内容。
7. **失败态与重试**：飞行模式下点一个从未打开过的源内包，页面走 `NoNetworkView`；
   恢复网络后点重试，内容出现。断网打开已打开过的包，显示上一次的详情。
8. **回归**：搜索页、Formulae、Casks、Discover 的列表行进详情页的行为不变。

---

## 11. 已知取舍

| 项 | 说明 |
| --- | --- |
| 「未找到」页的重试范围 | 只重新取单条，不触发目录刷新。Harmonybrew 方言的单条来自设备上的目录文件，文件陈旧时重试会得到同样的结论；目录刷新由包表的两个新鲜窗口（`BREW_VOL_FRESH_MS` / `BREW_DESC_FRESH_MS`）决定 |
| cask 的详情侧 | 本机包列表里的 cask 行与 formula 行走同一条导航路径（`MinePackagesUtil.detailParamsOf` 按 `kind` 分流）。cask 的详情由 cask 数据源提供，目录里没有这个 token 时同样进「未找到」占位页 |
| 「未找到」页不展示本机事实 | 版本、安装时刻、安装来源都在点击前的那一行上显示过；详情页要显示它们需要把本机包数据一并传进路由参数，两处口径会各自演化。占位页只负责说明「数据源里没有这个包」 |
| 骨架分支的保留 | 只用于 token 为空的参数错误，从本机包进入时不可达 |
