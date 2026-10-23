import SwiftUI
import Combine

/// 短剧频道页 ViewModel（腾讯视频式：短剧分类分组横滑）。
@MainActor
class ShortDramaViewModel: ObservableObject {
    /// 分组横滑数据。
    @Published var sections: [HomeSectionGroup] = []
    /// 加载状态。
    @Published var isLoading = false
    /// 错误提示。
    @Published var errorMessage: String?
    
    private let sourceService = SourceService.shared
    
    /// 加载短剧相关分类的分组横滑内容。
    func load() async {
        guard let source = ApiConfig.shared.homeSourceBean else { return }
        isLoading = true
        defer { isLoading = false }
        
        guard let sortResult = try? await sourceService.getSort(sourceBean: source) else {
            errorMessage = "加载失败，请检查网络或数据源"
            return
        }
        
        // 优先短剧分类，无则回退到"剧/片"类分类。
        var candidates = sortResult.sorts.filter { $0.name.contains("短剧") }
        if candidates.isEmpty {
            candidates = sortResult.sorts.filter { $0.name.contains("剧") || $0.name.contains("片") }
        }
        let picks = Array(candidates.prefix(6))
        guard !picks.isEmpty else {
            errorMessage = "当前数据源暂无短剧内容"
            return
        }
        
        let groups = await withTaskGroup(of: HomeSectionGroup?.self) { group in
            for sort in picks {
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
        sections = groups
    }
}

/// 短剧频道页（腾讯视频式）。
struct ShortDramaView: View {
    @StateObject private var viewModel = ShortDramaViewModel()
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 顶部标题
                HStack {
                    Text("短剧")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(AppTheme.textPrimary)
                    Spacer()
                    // 搜索入口
                    Button {
                        NotificationCenter.default.post(name: .switchToSearchTab, object: nil)
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(AppTheme.textPrimary)
                            .frame(width: 34, height: 34)
                            .background(Color.white)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(AppTheme.divider, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 8)
                
                // 内容区
                Group {
                    if viewModel.isLoading && viewModel.sections.isEmpty {
                        VStack {
                            Spacer()
                            ProgressView()
                                .scaleEffect(1.3)
                                .tint(.orange)
                            Text("加载中...")
                                .font(.subheadline)
                                .foregroundColor(AppTheme.textSecondary)
                                .padding(.top, 10)
                            Spacer()
                        }
                    } else if let error = viewModel.errorMessage, viewModel.sections.isEmpty {
                        VStack(spacing: 12) {
                            Spacer()
                            Image(systemName: "film.stack")
                                .font(.largeTitle)
                                .foregroundColor(AppTheme.textSecondary)
                            Text(error)
                                .font(.subheadline)
                                .foregroundColor(AppTheme.textSecondary)
                            Spacer()
                        }
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) {
                                ForEach(viewModel.sections) { section in
                                    VStack(alignment: .leading, spacing: 10) {
                                        HStack(spacing: 6) {
                                            Text(section.title)
                                                .font(.system(size: 16, weight: .bold))
                                                .foregroundColor(AppTheme.textPrimary)
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundColor(AppTheme.textSecondary)
                                        }
                                        .padding(.horizontal, 16)
                                        
                                        ScrollView(.horizontal, showsIndicators: false) {
                                            HStack(alignment: .top, spacing: 12) {
                                                ForEach(section.videos) { video in
                                                    NavigationLink(value: video) {
                                                        VodCardView(video: video)
                                                            .frame(width: 118)
                                                    }
                                                    .buttonStyle(VodCardPressStyle())
                                                }
                                            }
                                            .padding(.horizontal, 16)
                                            .padding(.bottom, 4)
                                        }
                                    }
                                }
                            }
                            .padding(.bottom, 20)
                        }
                        .refreshable {
                            await viewModel.load()
                        }
                    }
                }
            }
            .background(AppTheme.pageBackground)
            .navigationDestination(for: Movie.Video.self) { video in
                DetailView(video: video)
            }
        }
        .task {
            await viewModel.load()
        }
    }
}
