# HDS 标题栏模糊：类型、逐场景正确用法与踩坑清单

> 适用对象：`@kit.UIDesignKit` 的 `HdsNavigation` / `HdsNavDestination` 标题栏「随内容区滚动」的动态模糊。
> 结论都在本机真机（HarmonyOS 2in1，API 26 / 6.1.0(23)，侧边栏布局，`statusBarHeight = 0`）上量过。
>
> 相关实现：
> - `features/brewcommon/src/main/ets/util/BrewTitleBar.ets` —— brew 各页共用的模糊入口（区间只在这里定义一份）
> - `features/commonbusiness/src/main/ets/viewmodel/BaseHomeViewModel.setTitleBarStyle()` —— 有 banner 的三个首页
> - `features/brewcommon/src/main/ets/constant/BrewConstants.ets` —— `brewContentTopInset()` / `brewTitleBarTotalHeight()`
>
> 相关文档：`docs/brew-api-design.md` §9.12（本次排查过程与实测数据）、`docs/brew-handover.md` §7.3（症状索引）。
> 官方依据：`devecocli docs read` 的
> `API参考/UI_Design_Kit_UI设计套件/ArkTS组件/HdsNavigation/ui-design-hdsnavigation`、
> `.../HdsNavDestination/ui-design-hdsnavdestination`、
> `开发指南/UI_Design_Kit_UI设计套件/组件导航/设置动态模糊样式/ui-design-navigation-dynamic-blur`、
> `FAQ/UI框架/UI界面/HarmonyOS下HdsNavigation与HdsTabs实现滚动模糊及沉浸光感材质效果的解决方案/faqs-arkui-1095`。

---

## 0. 一页速查（先看这三条）

| 规则 | 内容 |
|---|---|
| **① 区间起点只能是 0** | `blurEffectiveStartOffset` 取值范围 `[0, +∞)`，**越界按默认值（0）处理** —— 传负数等于传 0，不是"负的起点"。区间要做的事只有一件：`end = ramp`。 |
| **② 让位必须写进「内容」** | 顶部/底部让位用**内容里的占位**（WaterFlow 的占位 FlowItem、Scroll 内层 Column 的 `margin`、banner 作为第一项）。**容器上的 `padding`** 会裁剪内容、**`contentStartOffset`** 会把滚动坐标系左移 C —— 两者都会破坏模糊（详见 §5 坑 2 / 坑 3）。 |
| **③ 区间长度别用默认值** | 不写 `blurEffectiveEndOffset` 时默认只有 **8vp**（`GRADUAL_BLUR` 是 56vp），肉眼等于没有渐变。brew 统一用 **104vp**（= `BANNER_CONTENT_HEIGHT(160) − NAVIGATION_HEIGHT(56)`，与组件页同源）。 |

判据（可量）：日志里每页一行

```
[BrewTitleBar], blur ramp: page=formulae start=0 end=104 ramp=104 material=legacy
```

`start` 必须是 `0`、`end − start` 必须是 `104`。出现负数、`end=48`、缺行，都说明这页没接上共用实现。

---

## 1. 四个概念

### 1.1 模糊类型（`ScrollEffectType`）

| 枚举 | 值 | 名称 | 特点 | 起始版本 | 默认 `end` |
|---|---|---|---|---|---|
| `COMMON_BLUR` | 0 | 通用模糊 | 背景均匀模糊、强度一致、边界清晰；滑动内容进出标题栏时**模糊背板与分割线透明渐显/渐隐**。非沉浸式场景（列表型）默认。 | 5.1.0(18) | 8vp |
| `GRADUAL_BLUR` | 1 | 过渡模糊 | 均匀模糊 + 滑动前后标题栏内容**颜色/状态**线性变化。沉浸式图文类。 | 6.0.0(20) | 56vp |
| `GRADIENT_BLUR` | 2 | 渐变模糊 | 模糊在**空间维度**上渐强/渐弱，边界柔和（渐变蒙层）。 | 6.0.0(20) | 8vp |
| `IMMERSIVE_GRADIENT_BLUR` | 3 | 沉浸式渐变模糊 | 同渐变模糊，配合沉浸光感材质使用。 | 6.1.0(23) | 8vp |

补充：
- `GRADIENT_BLUR` / `IMMERSIVE_GRADIENT_BLUR` 才有 `backgroundStyle.blurRadius`（`[0,128]`，默认 0 / 16 / 12，配了 `systemMaterialEffect` 时为 12）与 `maskExtraHeight`（**只有 `GRADIENT_BLUR` 生效**，蒙层超出标题栏的额外高度，默认 32vp）。
- `COMMON_BLUR` / `GRADUAL_BLUR` 的背景色默认透明；`GRADIENT_BLUR` 在 `enableScrollEffect: true` 时 `scrollEffectStyle` 默认 `#99000000`。

### 1.2 材质（沉浸光感，6.1.0(23) 起）

`TitleBarStyleOptions.systemMaterialEffect` 配 `hdsMaterial`：

```typescript
systemMaterialEffect: {
  materialType: hdsMaterial.MaterialType.IMMERSIVE,   // 或 ADAPTIVE(100)
  materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE,  // 推荐：系统按算力自适应
}
```

- `getSystemMaterialTypes()` 查设备支持哪些材质类型：支持 `IMMERSIVE` 才能用好材质（`EXQUISITE`/`GENTLE`），不支持时建议 `SMOOTH` 降卡顿/发热。
- 材质档位与「模糊是否真的生效」相关：`BlurStrategy.ADAPTIVE`（默认）下**只有"精美"档位**才生效模糊，其余档位不生效 —— 排查时别把它当成"代码没写对"。

### 1.3 区间（两个 offset）与两态样式

```
originalStyle      —— 未滚动（偏移量 ≤ start）时的样式
scrollEffectStyle  —— 滚过 end 之后的样式
偏移量 ∈ [start, end] 时两者线性过渡
```

- HDS 说的「内容区滚动的总偏移量」= **滚动容器自报的偏移量**（`Scroller.currentOffset().yOffset`）。容器类型（`Scroll` / `List` / `WaterFlow` / `Grid` / `Web`）**不影响语义**，只影响两件事：① 你用什么容器、② 它的坐标系原点在哪（见 §2 让位）。
- `enableScrollEffect: false`：完全不随滚动变化，只生效 `originalStyle`（有页面刻意这么配，见 §3 场景 G）。

### 1.4 绑定与动态显隐

| 能力 | 说明 |
|---|---|
| `bindToScrollable([scroller])` | 显式绑定可滚动容器，动态模糊/标题栏动态显隐都更稳（6.0.0(20) 起） |
| `bindToNestedScrollable([...])` | 绑嵌套容器；**多个容器绑同一个导航组件时，滚动任一容器都会触发标题栏显隐** |
| 不绑定 | 5.1.0(18) 起 HdsNavDestination 默认支持随内容区滚动，靠自动识别 —— 单容器页面能用，多容器页面有选错风险 |
| `dynamicHideTitleBar({ hideTitleArea, mode: HideMode.SCROLL_UP })` | 标题栏随滚动隐藏；隐藏期间**没有标题栏也就没有模糊**，别和"模糊失效"混为一谈 |

---

## 2. 让位与内缩：只有三种写法，选哪种由容器决定

「让位」= 给浮层标题栏腾出高度（标题栏是浮层，不会把内容顶下去，而 `HdsNavDestination` 用了
`ignoreLayoutSafeArea([SYSTEM], [TOP])`，不手动让位首项会被盖住）。
「内缩」= 内容左右的边距。

| 写法 | 是否裁剪内容 | 静止时 scroller 自报偏移量 | 能用在哪 | 结论 |
|---|---|---|---|---|
| **内容里的占位**（首/尾空白项、banner 首项、内层 `margin`） | 不裁剪 ✅ | **0** ✅ | 全部容器 | **推荐** |
| 容器 `contentStartOffset` / `contentEndOffset` | 不裁剪 ✅ | **−C**（坐标系左移）❌ | Scroll / WaterFlow | ❌ 会留下长度 = C 的空行程 |
| 容器 `padding` | **裁剪** ❌ | 0（但实测可能被推离 0，见过 16vp）❌ | 全部容器 | ❌ 内容到不了标题栏下面，模糊形同虚设 |

### 逐容器对应关系（本项目现行做法）

| 容器 | 让位写法 | 为什么必须这样 |
|---|---|---|
| `WaterFlow`（无 banner，如 Formulae / Discover） | 首尾各一个**空白 `FlowItem`**；VM 的 `sections` = `[spacer, cards, footer]` | WaterFlow **没有内层容器**可以加 margin；容器 `padding` 会裁剪、`contentStartOffset` 会左移坐标系。`sections` 的 `itemsCount` / 顺序必须与子组件严格一致（见坑 10） |
| `WaterFlow` / `List`（有 banner，如组件 / 样例 / 实践） | **banner 作为第一个滚动项**（`FlowItem` / `ListItem`） | 与上同因；banner 随内容滚走，天然就是"内容里的让位块" |
| `List`（无 banner） | 首项空白 `ListItem`，或外层不加 padding、由内层 Column 的 `margin` 让位 | 同 Scroll |
| `Scroll`（详情页 / 榜单二级页 / 我的-本机包 / Casks） | **内层 `Column` 的 `margin`**（上下让位）+ 内层 `padding`（左右内缩） | 与「我的」页 `MineView` 同一口径；容器上不写任何 `padding` |
| `Web`（代码预览 / 文章详情） | 无（Web 自身滚动） | 只把 `WebUtil.getWebScroller(...)` 绑给标题栏 |
| `Grid` | 本项目**没有**把 Grid 当页面主容器（只出现在组件详情页的 Grid 示例里，不参与标题栏模糊） | — |

> 内缩同理：**写在内容上**（内层 `padding` 或 WaterFlow 的 `section.margin`），不要写在滚动容器上 ——
> 容器 `padding` 会连带裁剪内容，而且 ArkUI 的 `padding` 属性是**整体覆盖**（拆成两次会让前一次失效，见 §9.9）。

---

## 3. 逐场景正确用法

### 场景 A：无 banner 的页签首页（WaterFlow）

- 页面：Formulae、Discover（发现）
- 样式来源：覆写 `BaseHomeViewModel.setTitleBarStyle()`，用 `brewBlurScrollEffect(base, 104)` **只补区间**，保留基类选的材质
- 区间：`[0, 104]`
- 让位：首尾空白 `FlowItem`（`sections = [spacer, cards, footer]`）
- 判据：`blur ramp: page=formulae start=0 end=104 ramp=104 material=legacy`

```typescript
// View：内容里的占位块
WaterFlow({ scroller: this.state.scroller, sections: this.state.sections }) {
  FlowItem() {
    Column().width('100%').height(this.globalInfoModel.statusBarHeight + CommonConstants.NAVIGATION_HEIGHT)
  }.width('100%')

  LazyForEach(this.state.cardSource, (item: BrewCategoryCard) => { FlowItem() { /* 卡片 */ }.width('100%') })

  FlowItem() {           // 底部留白
    Column().width('100%').height(this.globalInfoModel.naviIndicatorHeight)
  }.width('100%')
}
// 容器上不写 padding / contentStartOffset；左右内缩由 section.margin 提供
```

```typescript
// ViewModel：sections 顺序必须与子组件一致
private spacerSection: SectionOptions = { itemsCount: 1, crossCount: 1 };
private footerSection: SectionOptions = { itemsCount: 1, crossCount: 1 };
// ...
this.state.sections.splice(0, this.state.sections.length(),
  [this.spacerSection, this.categorySection, this.footerSection]);
```

### 场景 B：无 banner 的 Scroll 页（详情 / 二级页 / 本机包 / Casks）

- 页面：包详情页、榜单二级页、我的-本机包、Casks
- 样式来源：
  - 前三个用 `brewTitleBarStyle('detail' | 'discover-board' | 'mine-packages')`
  - Casks 页走"覆写基类 + 只补区间"
- 区间：`[0, 104]`
- 让位：内层 `Column` 的 `margin`；容器 `padding` 全部去掉

```typescript
Scroll() {
  Column() {
    /* 内容（卡片自带底色/圆角，不需要外层再包一层） */
  }
  .width(CommonConstants.FULL_PERCENT)
  .margin({                                        // ← 上下让位写成内容的 margin
    top: brewContentTopInset(this.globalInfoModel.statusBarHeight, false),
    bottom: this.globalInfoModel.naviIndicatorHeight + CommonConstants.SPACE_24,
  })
  .padding({ left: this.contentLeft(), right: this.contentLeft() })   // ← 左右内缩也在内容上
}
.width('100%').height('100%').scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
```

> 需要把整张卡片包起来时（例如「我的-本机包」的卡片自带 `backgroundColor` + `borderRadius`）：
> 外面套一层**透明** `Column` 专门承载 `margin` / `padding`，别把内缩加到卡片自己身上，
> 否则卡片的底色会铺到窗口边缘。

### 场景 C：有 chips 行的页（Casks / 我的-本机包）

让位量要**加上 chips 行**：标题行 56 + chips 56 → `brewTitleBarTotalHeight(statusBarHeight)`。
`bottomBuilder.height` 必须与这个值同源，否则"标题栏有多高"和"内容让了多少"会不一致（顶部一条空白 / 被盖住）。

### 场景 D：有 banner 的三个首页（组件 / 样例 / 实践）

- 样式来源：`BaseHomeViewModel.setTitleBarStyle()`（**不共用** brew 的常量）
- 区间：由 banner 高度算出来
  - `start = IS_SIDEBAR_LAYOUT ? 0 : (sm/md: bannerHeight − 160 − statusBarHeight; lg/xl: 0)`
  - `end = bannerHeight − statusBarHeight − 56`
  - sm/md 档 → 长度 104；lg/xl 档 → 250；侧边栏 → 282
- 让位：**banner 放在滚动内容里**（WaterFlow 的第一个 `FlowItem` / List 的第一个 `ListItem`），所以内容静止时就压在标题栏上，区间也要相应右移
- 判据：这一组**没有** `blur ramp` 行（它不走 `BrewTitleBar`）

### 场景 E：不绑定 scroller 的页面（我的 / 公告）

- 「我的」`MineView`：`Scroll` + 内层 Column `margin`，样式用 `brewTitleBarStyle('mine')` → `[0,104]` ✅
- 「公告」`BulletinView`：`List` + **外层 Stack 的 `padding`**，样式是内联 `{ enableScrollEffect: true, COMMON_BLUR }`（**没写区间**）
  → 落回默认 `[0,8]`：**一滚就全糊，没有渐变**，且 Stack 上的 padding 会裁剪内容 ⚠️（尚未统一）

### 场景 F：Web 作为内容容器（代码预览 / 文章详情）

`titleBarStyle` 内联（只给材质/类型，**没写区间** → 默认 8vp），绑定用 `WebUtil.getWebScroller(url)`；
同样是"没有渐变"的一类。Web 的滚动偏移由 HDS 从 scroller 拿，语义与原生容器一致。

### 场景 G：刻意关闭模糊（内容上新 / 实践详情）

`scrollEffectOpts: { enableScrollEffect: false }` → 完全不随滚动变化。
**这是原工程的口径，不是漏改**；盘点时不要把它们算成 bug。

### 场景 H：嵌套 HdsTabs（含本项目侧边栏布局）

官方 FAQ 的结论（`faqs-arkui-1095` 场景二）：

1. **每个 Tab 用各自独立的 `Scroller`**，不要共用一个；
2. `bindToScrollable` **只绑当前显示的 Tab 的 scroller**（切页时重新绑）；
3. 用 `onWillHide` 记录、`onAnimationStart` 恢复各 Tab 的滚动位置。

否则会出现"切页后模糊丢失 / 位置串台"。

---

## 4. 三种"内容穿透标题栏"的写法对照

模糊要**看得出效果**，前提是内容能画到标题栏下面去。三种写法差异：

| 写法 | 内容能否穿透 | 说明 |
|---|---|---|
| 容器 `padding({top})` | **不能**（内容被裁在 padding 区外） | 只能看到"模糊背板 + 分割线"渐显；本项目实测需求方原话：「内容区并不会到模糊层下方了，模糊效果现在形同虚设」 |
| `contentStartOffset(C)` | 能穿透 | 但坐标系左移 C，HDS 起点不能为负 → 前 C vp 没有模糊（坑 2） |
| 内容里的 `margin`（+ `clip(false)` + `cachedCount(n, true)`） | 能穿透 ✅ | 官方 `设置动态模糊样式` 示例的写法：`.margin({left,right})` + `.clip(false)` 让内容穿透到标题栏下方，`cachedCount(3, true)` 防止穿透的项被回收 |

> 判定"要哪种"：
> - 想要**内容被模糊**（真正的沉浸效果）→ 内容占位 + 不要让容器裁剪；
> - 只想要**标题栏背板渐显**（列表型、内容不进标题栏）→ 容器 padding 也可以，但要知道代价是内容永远到不了标题栏下面。

---

## 5. 踩坑清单

### 坑 1（最贵）：负的 `blurEffectiveStartOffset` 被静默丢成 0

- **现象**：想"把区间左移 C"，实际变成"起步 C vp 无变化 + 之后很快猛增"。
- **根因**：`blurEffectiveStartOffset` 取值范围 `[0,+∞)`，**超出取值范围时按默认值处理**（= 0）；
  若 `end < start`，`end` 也按默认值（`COMMON_BLUR`/`GRADIENT_BLUR` = 8vp）。全是静默降级：编译过、不报错、无日志。
- **实测**：`start = −56, end = 104 − 56 = 48` → 实际区间 `[0, 48]`。
- **修法**：起点**永远写 0**，只调 `end`；`BrewTitleBar.brewBlurScrollEffect()` 已经把这条固化（含 `ramp < 32` 时的 warn 兜底）。

### 坑 2：`contentStartOffset(C)` 会把滚动坐标系整体左移 C

- **现象**：内容已经在标题栏下钻了 C，却一点模糊都没有；之后在剩下的一小段里猛增（"空行程 ≈ C + 猛增"）。
- **根因**：`contentStartOffset` 把**内容区原点**挪到 +C → 静止时 `scroller.currentOffset().yOffset = −C`（本机实测 **−56**），
  而 HDS 起点不能为负 → 永远够不到"内容刚贴住标题栏下沿"那一刻。
- **判据**：探针打印静止偏移量；为负就命中这条。
- **修法**：让位改成内容里的占位（§2）。

### 坑 3：容器 `padding` 会把内容裁剪在 padding 区域之外

- **现象**：区间配对了，但标题栏下面永远没有内容 —— 只剩一块渐变的背板，模糊"形同虚设"。
- **根因**：滚动容器上的 `padding` 参与裁剪（内容被限制在 padding 盒内）。
- **修法**：`padding` 只用于**内容**（内层 Column）或改用占位项；容器上保持无 `padding`。
- **别被误导**：早期文档写过"用 `margin` 让位会底部溢出，所以必须用 `padding`" —— 那说的是把 `margin`
  写在 **Scroll 容器**上（外层是精确 100% 高度的 `Stack`，整体下移必然溢出）。写在**内层内容**上没有问题
  （「我的」/ 包详情 / 榜单二级 / 本机包现在都是内层 `margin`）。

### 坑 4：不写区间 = 默认 8vp = 没有渐变

- **现象**：一滚就完全模糊（"啪"地一下），没有过渡。
- **根因**：只写了 `enableScrollEffect` + `scrollEffectType`，没写 `blurEffectiveEndOffset`，默认只有 8vp。
- **现状**：公告、组件详情、代码预览、文章详情仍是这一档（见 §6 清单）。
- **修法**：接 `brewTitleBarStyle()` / `brewBlurScrollEffect()`，或显式写 `end`。

### 坑 5：把"有 banner 的公式"套到无 banner 的页上 → 反向区间

- **现象**：标题栏完全不模糊（且不报错）。
- **根因**：`BaseHomeViewModel` 的区间是给 banner 页算的（`end = bannerHeight − statusBar − 56`）；
  brew 页把 `bannerHeight` 覆写成 0 → `end = −(statusBar + 56) < start` → 走坑 1 的默认值/失效。
- **修法**：无 banner 的页不要用基类那组值，覆写 `setTitleBarStyle()`（brew 三个页签页的做法）。

### 坑 6：改模糊时**整份替换** `hdsTitleBarStyle`，顺手丢了标题行内间距

- **现象**：修完模糊，标题行的左右位置变了。
- **根因**：`hdsTitleBarPadding` 在同一个 `TitleBarStyleOptions` 对象里，整份替换会连它一起丢掉。
- **修法**：只改 `style.scrollEffectOpts` 字段（brew 三个页签页都是这么写的），别 `=` 一个新对象。

### 坑 7：把 `enableScrollEffect: false` 当成漏改

- **现象**：这两页怎么改都不动。
- **根因**：`内容上新` / `实践详情` 是原工程刻意关闭的。
- **修法**：改之前先确认需求；不要"顺手打开"。

### 坑 8：嵌套 HdsTabs 共用/绑错 scroller

见 §3 场景 H。表现为"切页后模糊丢失、滚动位置串台"。

### 坑 9：`dynamicHideTitleBar` 期间"没有模糊"

标题栏被隐藏时它本来就不存在；排查时先看当前滚动方向/位置，别误判。

### 坑 10：WaterFlow 的 `sections` 与子组件顺序/数量不一致

- **现象**：布局错乱、卡片错位、占位块吃掉卡片、或占位块根本不显示。
- **根因**：`sections` 按**顺序**切分 `WaterFlow` 的子组件，`itemsCount` 之和必须等于子组件个数。
- **修法**：加了占位 `FlowItem` 就必须同步加 section（`spacer` + `cards` + `footer`），顺序与视图一致。

### 坑 11：区间太短（8 / 48）→ 观感上没有渐变

- **判据**：`end − start` 至少 32vp（本项目 `BREW_TITLEBAR_BLUR_MIN_RAMP` 兜底并打 warn）。
  参考值 104vp（= 160 − 56，组件页同源）。

### 坑 12：模糊"偶尔不生效"——先怀疑系统策略，再怀疑代码

- `BlurStrategy.ADAPTIVE`（默认）：只有系统"精美"档位才生效模糊；
- `thermoCtrl: true`（6.1.0(23)）：高温档位会关闭模糊；
- 设备不支持 `IMMERSIVE` 材质时，`getSystemMaterialTypes()` 会给出可用集合（不支持就别硬用高等级材质）。

---

## 6. 现状盘点（本机：2in1 + 侧边栏布局，`isSupportNewMaterialApi() === false` → 走 `COMMON_BLUR`）

| 页面 | 主容器 | 样式来源 | 区间 | 让位 | 模糊 |
|---|---|---|---|---|---|
| 组件 / 样例 / 实践 三个首页 | WaterFlow / List / List | `BaseHomeViewModel`（banner 派生） | 104（lg/xl 250、侧边栏 282） | banner 首项 | ✅ |
| Formulae | WaterFlow | 覆写基类 + `BrewTitleBar` | `[0,104]` | 首尾占位 FlowItem | ✅ |
| Discover（发现） | WaterFlow | 同上 | `[0,104]` | 首尾占位 FlowItem | ✅ |
| Casks | Scroll | 同上 | `[0,104]` | 内层 Column `margin` | ✅ |
| 包详情页 | `HdsTabs`（只有一页，页签栏 = 底部主操作栏）→ `Scroll` | `brewTitleBarStyle('detail')` + `bindToScrollable([scroller])` | `[0,104]` | 内层 Column `margin`（顶部）+ `Scroll.contentEndOffset`（底部让主操作栏） | ✅ |
| 榜单二级页 | Scroll | `brewTitleBarStyle('discover-board')` | `[0,104]` | 内层 Column `margin` | ✅ |
| 我的-本机包 | Scroll | `brewTitleBarStyle('mine-packages')` | `[0,104]` | 内层 Column `margin`（+ chips 让位 112） | ✅ |
| 我的 `MineView` | Scroll | `brewTitleBarStyle('mine')` | `[0,104]` | 内层 Column `margin` | ✅ |
| 公告 `BulletinView` | List | 内联（无区间） | 默认 `[0,8]` | 外层 Stack `padding` | ⚠️ 无渐变 + 内容被裁剪 |
| 组件详情 / 代码预览 | Scroll / Web | 内联（无区间） | 默认 `[0,8]` | 容器 `padding` | ⚠️ 同上（`getEnableScrollEffect()` 在 sm 档还返回 false） |
| 文章详情 | Web | 内联（无区间） | 默认 `[0,8]` | —（Web 自滚） | ⚠️ 无渐变 |
| 内容上新 / 实践详情 | List | 内联 `enableScrollEffect: false` | — | — | ❌ 刻意关闭 |

包详情页的 `Scroll` 自 2026-10-05 起嵌在单页签 `HdsTabs` 的 `TabContent` 里（页签栏就是底部主操作栏）。
**嵌了 `HdsTabs` 之后，标题栏模糊不再能靠 HDS 自动识别滚动容器，必须显式绑定** ——
页面持有一个 `Scroller` 交给 `Scroll`，并在 `HdsNavDestination` 上写 `.bindToScrollable([this.scroller])`，
否则模糊直接丢失（与 §3 场景 H 同一个原因，官方 FAQ `faqs-arkui-1095` 场景二）。
只有一页，不需要「切页时重新绑」与「存档/恢复滚动位置」那两步。

---

## 7. 怎么验证（不要只靠肉眼"看起来对"）

### 7.1 判据日志（最快）

每页一行 `[BrewTitleBar], blur ramp: page=xxx start=0 end=104 ramp=104 material=legacy`。
接日志：`devecocli log --device <serial> --follow --keyword "BrewTitleBar"`。

### 7.2 探针（量"模糊 vs 滚动"曲线）

在页面里临时加一段逐档滚动 + 打点（**不要提交**）：

```typescript
setTimeout(() => {   // 页面静止时先量一次：contentStartOffset 的坑就靠这一行暴露
  Logger.info('[BrewBlurProbe]', `initial actual=${this.state.scroller?.currentOffset()?.yOffset ?? -1}`);
}, 3000);
[0, 4, 8, 16, 32, 48, 64, 80, 104, 120, 160].forEach((v, i) => {
  setTimeout(() => {
    this.state.scroller?.scrollTo({ xOffset: 0, yOffset: v, animation: false });
    setTimeout(() => Logger.info('[BrewBlurProbe]', `step=${i} target=${v} actual=${...}`), 400);
  }, 20000 + i * 6000);
});
```

配合外部逐档截图（`devecocli ui screenshot --path ...`）比对"内容是否被模糊"。
**注意**：截图抓的是整屏，机型/窗口位置会变，先确认窗口矩形再裁标题栏那条带。

### 7.3 手动

`devecocli ui swipe` / `ui dircfling` 滚到压住标题栏，`ui screenshot` 看图：
有模糊时是内容的柔和拖影；一直是纯色说明内容没到标题栏下面（坑 3）或区间没生效（坑 1/4/5）。

### 7.4 构建与装机

```
devecocli build                      # 或 devecocli run（完整构建 + 装 + 起）
devecocli run --device <serial> --apply changes.txt   # 快迭代（.hvigor/changes.txt 列改动文件）
```

`--apply` 走 `ColdReloadArkTS` 增量；**增量编译失败/改动没生效时直接退回完整 `devecocli run`**。

---

## 8. 附录：API 取值与默认值速查

| 字段 | 类型 | 取值范围 | 默认值 | 越界行为 |
|---|---|---|---|---|
| `enableScrollEffect` | boolean | — | `true` | — |
| `scrollEffectType` | `ScrollEffectType` | 0~3 | `COMMON_BLUR` | — |
| `blurEffectiveStartOffset` | `LengthMetrics` | `[0,+∞)` | `vp(0)` | **按默认值处理** |
| `blurEffectiveEndOffset` | `LengthMetrics` | `[0,+∞)`，且需 ≥ start | `COMMON_BLUR`/`GRADIENT_BLUR` 8vp；`GRADUAL_BLUR` 56vp | **按默认值处理** |
| `enableRefreshOffsetChange` | boolean | — | `true`（6.1.0(23)） | — |
| `backgroundStyle.backgroundColor` | `ResourceColor` | — | 见 §1.1 | — |
| `backgroundStyle.maskExtraHeight` | number | vp | 32（仅 `GRADIENT_BLUR`） | — |
| `backgroundStyle.blurRadius` | number | `[0,128]` | 0 / 16 / 12 | **按默认值处理** |
| `blurStrategy` | `BlurStrategy` | `ENABLE`/`DISABLE`/`ADAPTIVE` | `ADAPTIVE` | — |
| `thermoCtrl` | boolean | — | `false` | — |
| `systemMaterialEffect.materialType` | `hdsMaterial.MaterialType` | `NONE`/`ADAPTIVE`/`IMMERSIVE` | — | — |
| `systemMaterialEffect.materialLevel` | `hdsMaterial.MaterialLevel` | `EXQUISITE`/`GENTLE`/`SMOOTH`/`ADAPTIVE` | 推荐 `ADAPTIVE` | — |

项目常量：`NAVIGATION_HEIGHT = 56`、`BREW_CHIP_BAR_HEIGHT = 56`、
`BANNER_CONTENT_HEIGHT = 160`、`BREW_TITLEBAR_BLUR_RAMP = 104`（启动下限 32）。
