import Foundation
import SwiftUI
import Combine

/// 首页分组横滑数据（腾讯视频式首页分区）。
struct HomeSectionGroup: Identifiable {
    let id: String
    let title: String
    var videos: [Movie.Video]
}

/// 首页 ViewModel
@MainActor
class HomeViewModel: ObservableObject {
    /// 分类列表（包含手动注入的"推荐"分类）。
    @Published var sorts: [MovieSort.SortData] = []
    /// 当前选中的分类。
    @Published var selectedSort: MovieSort.SortData?
    /// 首页推荐内容（对应"推荐"分类）。
    @Published var homeVideos: [Movie.Video] = []
    /// 普通分类的视频列表（分页加载）。
    @Published var categoryVideos: [Movie.Video] = []
    /// 首页 tab 的分组横滑数据（腾讯视频式"最近在看/上新"分区）。
    @Published var homeSections: [HomeSectionGroup] = []
    /// 首页 tab 分组加载状态。
    @Published var isLoadingSections = false
    /// 页面加载状态（分类加载与分页共用）。
    @Published var isLoading = false
    /// 当前分类的分页页码。
    @Published var currentPage = 1
    /// 是否还有下一页。
    @Published var hasMore = true
    /// 错误提示文案。
    @Published var errorMessage: String?
    /// 当前分类的筛选条件（key → 值）。
    @Published var activeFilters: [String: String] = [:]
    
    /// 源数据访问服务。
    private let sourceService = SourceService.shared
    /// 标记上次加载是否因网络错误失败（用于网络恢复自动重试）。
    private var lastLoadFailedDueToNetwork = false
    private var networkRestoredCancellable: AnyCancellable?
    /// 首页分组是否已加载（避免每次切回首页重复拉取）。
    private var sectionsLoaded = false
    
    init() {
        setupNetworkRestoredAutoRetry()
    }
    
    /// 加载分类列表
    func loadSorts() async {
        guard let source = ApiConfig.shared.homeSourceBean else { return }
        isLoading = true
        errorMessage = nil
        
        do {
            let result = try await sourceService.getSort(sourceBean: source)
            
            // 插入本地"推荐"分类，保持 UI 与 Android 版本习惯一致。
            var allSorts = [MovieSort.SortData.home()]
            allSorts.append(contentsOf: result.sorts)
            
            self.sorts = allSorts
            self.homeVideos = result.homeVideos
            lastLoadFailedDueToNetwork = false
            
            if selectedSort == nil {
                selectedSort = allSorts.first
            }
        } catch {
            errorMessage = error.localizedDescription
            lastLoadFailedDueToNetwork = error.isNetworkConnectionError
        }
        
        isLoading = false
    }
    
    /// 加载首页 tab 的分组横滑内容（腾讯视频式：并发拉取前几个真实分类各一页）。
    func loadHomeSections() async {
        guard !sectionsLoaded, let source = ApiConfig.shared.homeSourceBean else { return }
        sectionsLoaded = true
        isLoadingSections = true
        defer { isLoadingSections = false }
        
        // 在 MainActor 上下文先取出快照（TaskGroup 闭包不能访问 MainActor 隔离属性）。
        let categories = sorts.filter { $0.id != "home" }.prefix(6)
        guard !categories.isEmpty else { return }
        
        let groups = await withTaskGroup(of: HomeSectionGroup?.self) { group in
            for sort in categories {
                group.addTask {
                    guard let videos = try? await SourceService.shared.getList(
                        sourceBean: source,
                        sortData: sort,
                        page: 1,
                        filters: nil
                    ), !videos.isEmpty else { return nil }
                    return HomeSectionGroup(id: sort.id, title: sort.name, videos: Array(videos.prefix(10)))
                }
            }
            var result: [HomeSectionGroup] = []
            for await item in group {
                if let item {
                    result.append(item)
                }
            }
            return result
        }
        homeSections = groups
    }
    
    /// 重新加载首页分组（下拉刷新时）。
    func reloadHomeSections() async {
        sectionsLoaded = false
        homeSections = []
        await loadHomeSections()
    }
    
    /// 网络恢复时，若上次因网络错误导致首页为空，自动重新加载。
    private func setupNetworkRestoredAutoRetry() {
        networkRestoredCancellable = NetworkMonitor.shared.networkRestoredPublisher
            .sink { [weak self] in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.lastLoadFailedDueToNetwork || (self.sorts.isEmpty && self.homeVideos.isEmpty) else { return }
                    await self.refresh()
                }
            }
    }
    
    /// 选择分类
    func selectSort(_ sort: MovieSort.SortData) {
        // 切分类时先重置分页状态，避免旧分类残留数据闪烁。
        selectedSort = sort
        errorMessage = nil
        categoryVideos = []
        currentPage = 1
        hasMore = true
        
        if sort.id == "home" {
            return
        } else {
            Task {
                await loadCategoryVideos(page: 1, sort: sort)
            }
        }
    }
    
    /// 加载分类视频列表
    private func loadCategoryVideos(page: Int, sort: MovieSort.SortData) async {
        guard sort.id != "home" else { return }
        guard let source = ApiConfig.shared.homeSourceBean else { return }
        // 防重复并发加载，避免分页错序。
        guard !isLoading else { return }
        
        isLoading = true
        defer { isLoading = false }
        
        do {
            let videos = try await sourceService.getList(
                sourceBean: source,
                sortData: sort,
                page: page,
                filters: activeFilters.isEmpty ? nil : activeFilters
            )
            
            // 分类切换过程中，丢弃旧请求结果
            guard selectedSort?.id == sort.id else { return }
            
            if page == 1 {
                categoryVideos = videos
            } else {
                categoryVideos.append(contentsOf: videos)
            }
            // 以"返回非空"作为是否继续分页的轻量判断。
            currentPage = page
            hasMore = !videos.isEmpty
        } catch {
            guard selectedSort?.id == sort.id else { return }
            errorMessage = error.localizedDescription
        }
    }
    
    /// 应用筛选条件并重新加载当前分类（对齐安卓版分类筛选）。
    func applyFilters(_ filters: [String: String]) {
        activeFilters = filters
        errorMessage = nil
        categoryVideos = []
        currentPage = 1
        hasMore = true
        guard let sort = selectedSort else { return }
        Task {
            await loadCategoryVideos(page: 1, sort: sort)
        }
    }
    
    /// 清除全部筛选条件。
    func clearFilters() {
        guard !activeFilters.isEmpty else { return }
        activeFilters = [:]
        errorMessage = nil
        categoryVideos = []
        currentPage = 1
        hasMore = true
        guard let sort = selectedSort else { return }
        Task {
            await loadCategoryVideos(page: 1, sort: sort)
        }
    }
    
    /// 加载下一页
    func loadMore() async {
        guard let lastItem = categoryVideos.last else { return }
        await loadMoreIfNeeded(currentItem: lastItem)
    }
    
    /// 当最后一个元素出现时触发加载下一页
    func loadMoreIfNeeded(currentItem: Movie.Video) async {
        guard selectedSort?.id != "home" else { return }
        guard hasMore, !isLoading else { return }
        guard categoryVideos.last?.id == currentItem.id else { return }
        guard let sort = selectedSort else { return }
        
        let nextPage = currentPage + 1
        await loadCategoryVideos(page: nextPage, sort: sort)
    }
    
    /// 刷新
    func refresh() async {
        // 全量刷新时重置分页与错误态，再重新拉分类与当前分类内容。
        currentPage = 1
        hasMore = true
        categoryVideos = []
        errorMessage = nil
        await loadSorts()
        
        guard let sort = selectedSort else { return }
        if sort.id == "home" { return }
        
        if let matchedSort = sorts.first(where: { $0.id == sort.id }) {
            selectedSort = matchedSort
            await loadCategoryVideos(page: 1, sort: matchedSort)
        } else if let firstCategory = sorts.first(where: { $0.id != "home" }) {
            selectedSort = firstCategory
            await loadCategoryVideos(page: 1, sort: firstCategory)
        }
    }
}
