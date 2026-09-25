export { BrewDiscoverHomeView } from './src/main/ets/view/BrewDiscoverHomeView';

// BrewDiscoverHomeView 是页签入口；二级页（BrewDiscoverBoardView）通过
// module.json5 的 routerMap 进入编译图，不需要在这里再导出一次。
//
// 榜单模型（BrewDiscoverBoard / BrewDiscoverEntry / BrewDiscoverPageData）、
// 数据仓库（BrewDiscoverModel）与共享 UI 原子统一从 @ohos/brewcommon 导出。
