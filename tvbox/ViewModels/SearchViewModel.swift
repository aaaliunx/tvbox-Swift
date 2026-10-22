import Foundation
import SwiftUI

/// 搜索结果条目：给每条结果一个稳定唯一 id（避免多源同剧 id 相同
/// 导致列表滑动时行复用错乱、条目消失），并附带来源站点名。
struct SearchResultItem: Identifiable, Equatable {
    let id: UUID
    let video: Movie.Video
    let sourceName: String
    
    init(video: Movie.Video, sourceName: String) {
        self.id = UUID()
        self.video = video
        self.sourceName = sourceName
    }
    
    static func == (lhs: SearchResultItem, rhs: SearchResultItem) -> Bool {
        lhs.id == rhs.id
    }
}

/// 搜索 ViewModel
@MainActor
class SearchViewModel: ObservableObject {
    /// 搜索关键词输入。
    @Published var keyword: String = ""
    /// 当前结果列表。
    @Published var results: [SearchResultItem] = []
    /// 搜索加载状态，用于控制进度指示器。
    @Published var isSearching = false
    /// 本地搜索历史（最近在前）。
    @Published var searchHistory: [String] = []
    /// 搜索失败或空结果提示。
    @Published var errorMessage: String?
    
    /// 源数据服务（负责多源并发搜索）。
    private let sourceService = SourceService.shared
    /// 搜索请求序号（用于丢弃过期异步结果）。
    private var latestSearchRequestId: UUID = UUID()
    /// 已成功加载封面的记录：剧名|年份 -> 可用封面 URL。
    /// 用于把能加载出来的封面复用到同名其他结果上，避免失效源封面一直转圈。
    private var loadedPosterByKey: [String: String] = [:]
    
    /// 初始化时同步加载本地历史记录，确保搜索页首次渲染即可展示。
    init() {
        loadSearchHistory()
    }
    
    /// 封面加载成功回调：把已加载成功的封面复用到同剧（同名同年）其它结果上，
    /// 这样即使某些站点的封面 URL 失效，搜索结果仍显示同剧封面而不是一直加载。
    func registerLoadedPoster(for item: SearchResultItem, url: URL) {
        let key = "\(item.video.name)|\(item.video.year)"
        let urlString = url.absoluteString
        // 只记录首次成功，避免同剧多源反复覆盖。
        if loadedPosterByKey[key] == nil {
            loadedPosterByKey[key] = urlString
        }
        // 同剧其它结果若封面不同，替换为已加载成功的封面。
        var changed = false
        for index in results.indices {
            let k = "\(results[index].video.name)|\(results[index].video.year)"
            if k == key, results[index].video.pic != urlString {
                results[index].video.pic = urlString
                changed = true
            }
        }
        if changed {
            objectWillChange.send()
        }
    }
    
    /// 执行搜索（流式：每个源完成立即追加显示，不等全部源搜完）。
    func search() async {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let requestId = UUID()
        latestSearchRequestId = requestId
        
        isSearching = true
        errorMessage = nil
        results = []
        
        // 搜索一旦触发就先落历史，保持行为与移动端常见搜索体验一致。
        addToHistory(trimmed)
        
        // 走多源流式并发搜索：每完成一个源立即显示该源结果，并带上源站点名。
        await sourceService.searchAllStreaming(keyword: trimmed) { [weak self] sourceName, batch in
            Task { @MainActor in
                guard let self, requestId == self.latestSearchRequestId else { return }
                // 直接追加，保留各源全部结果（与安卓版一致）；封面重复请求由磁盘缓存消除。
                // 追加时若同剧已有成功加载的封面，直接复用，避免先渲染坏封面。
                let items = batch.map { video -> SearchResultItem in
                    var v = video
                    let key = "\(v.name)|\(v.year)"
                    if let loaded = self.loadedPosterByKey[key], !loaded.isEmpty {
                        v.pic = loaded
                    }
                    return SearchResultItem(video: v, sourceName: sourceName)
                }
                self.results.append(contentsOf: items)
            }
        }
        guard requestId == latestSearchRequestId else { return }
        
        if results.isEmpty {
            errorMessage = "未找到相关内容"
        }
        
        isSearching = false
    }
    
    /// 在指定源搜索
    func searchInSource(_ source: SourceBean) async {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let requestId = UUID()
        latestSearchRequestId = requestId
        
        isSearching = true
        errorMessage = nil
        
        do {
            let videos = try await sourceService.search(sourceBean: source, keyword: trimmed)
            guard requestId == latestSearchRequestId else { return }
            self.results = videos.map { SearchResultItem(video: $0, sourceName: source.name) }
        } catch {
            guard requestId == latestSearchRequestId else { return }
            errorMessage = error.localizedDescription
        }
        
        isSearching = false
    }
    
    // MARK: - 搜索历史
    
    /// 从本地读取历史。
    private func loadSearchHistory() {
        searchHistory = UserDefaults.standard.stringArray(forKey: HawkConfig.SEARCH_HISTORY) ?? []
    }
    
    /// 新增历史项并去重，最多保留 20 条。
    private func addToHistory(_ keyword: String) {
        searchHistory.removeAll { $0 == keyword }
        searchHistory.insert(keyword, at: 0)
        if searchHistory.count > 20 {
            searchHistory = Array(searchHistory.prefix(20))
        }
        UserDefaults.standard.set(searchHistory, forKey: HawkConfig.SEARCH_HISTORY)
    }
    
    /// 清空历史。
    func clearHistory() {
        searchHistory = []
        UserDefaults.standard.removeObject(forKey: HawkConfig.SEARCH_HISTORY)
    }
    
    /// 删除单条历史。
    func removeFromHistory(_ keyword: String) {
        searchHistory.removeAll { $0 == keyword }
        UserDefaults.standard.set(searchHistory, forKey: HawkConfig.SEARCH_HISTORY)
    }
}
