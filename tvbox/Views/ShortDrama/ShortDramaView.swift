import SwiftUI

/// 短剧频道页 ViewModel（番茄短剧式竖屏信息流）。
/// 聚合多个源站的真实"短剧"分类内容，去重后形成信息流。
@MainActor
class ShortDramaViewModel: ObservableObject {
    /// 信息流数据（跨源聚合、按剧名去重）。
    @Published var videos: [Movie.Video] = []
    /// 加载状态。
    @Published var isLoading = false
    /// 错误提示。
    @Published var errorMessage: String?
    /// 是否还有更多（当前第一版不翻页）。
    @Published var hasMore = false
    
    /// 已知含"短剧"分类的源 key（按优先级排序）。
    private let shortDramaSourceKeys = [
        "baofeng",   // 暴风资源：短剧大全
        "dbzy",      // 豆瓣资源：短剧大全
        "tianya",    // 天涯资源：短剧 / AI短剧
        "guangsu",   // 光速资源：短剧
        "modu",      // 魔都资源：短片/短剧
        "modudongman", // 魔都动漫：短片/短剧
        "shandian",  // 闪电资源：爽文短剧
        "niuniu",    // 牛牛点播：爽文短剧
        "suoni",     // 索尼资源：爽文短剧
        "feifan"     // 非凡资源：短剧
    ]
    
    private let sourceService = SourceService.shared
    
    /// 聚合加载各源短剧分类第一页内容。
    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        
        // 只取配置里真实存在的短剧源。
        let beans = shortDramaSourceKeys.compactMap { ApiConfig.shared.getSource(key: $0) }
        guard !beans.isEmpty else {
            errorMessage = "当前配置没有短剧源，请到设置页更换数据源"
            return
        }
        
        let items = await withTaskGroup(of: [Movie.Video].self) { group in
            for bean in beans {
                group.addTask {
                    // 找该源分类中含"短剧/短片"的分类，拉首页数据。
                    guard let sorts = try? await SourceService.shared.getSort(sourceBean: bean) else { return [] }
                    guard let target = sorts.sorts.first(where: { $0.name.contains("短剧") || $0.name.contains("短片") }) else { return [] }
                    guard let videos = try? await SourceService.shared.getList(
                        sourceBean: bean,
                        sortData: target,
                        page: 1,
                        filters: nil
                    ) else { return [] }
                    return videos
                }
            }
            var all: [Movie.Video] = []
            for await batch in group {
                all.append(contentsOf: batch)
            }
            return all
        }
        
        // 按剧名跨源去重（保留先到的，即高优先级源）。
        var seen = Set<String>()
        videos = items.filter { seen.insert($0.name).inserted }
        
        if videos.isEmpty {
            errorMessage = "短剧源暂无可播放内容，请稍后重试"
        }
    }
}

/// 短剧频道页（番茄短剧式竖屏信息流）。
struct ShortDramaView: View {
    @StateObject private var viewModel = ShortDramaViewModel()
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 顶部：标题 + 搜索入口
                HStack {
                    Text("短剧")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(AppTheme.textPrimary)
                    Spacer()
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
                
                // 内容区：竖屏信息流
                content
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
    
    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.videos.isEmpty {
            VStack {
                Spacer()
                ProgressView()
                    .scaleEffect(1.3)
                    .tint(.orange)
                Text("正在全网搜索短剧...")
                    .font(.subheadline)
                    .foregroundColor(AppTheme.textSecondary)
                    .padding(.top, 10)
                Spacer()
            }
        } else if let error = viewModel.errorMessage, viewModel.videos.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "film.stack")
                    .font(.largeTitle)
                    .foregroundColor(AppTheme.textSecondary)
                Text(error)
                    .font(.subheadline)
                    .foregroundColor(AppTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Button("重试") {
                    Task { await viewModel.load() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                Spacer()
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(viewModel.videos) { video in
                        shortDramaCard(video)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
            .refreshable {
                await viewModel.load()
            }
        }
    }
    
    /// 番茄短剧式信息流卡片：左侧竖版海报，右侧标题/更新/标签/简介/观看入口。
    private func shortDramaCard(_ video: Movie.Video) -> some View {
        NavigationLink(value: video) {
            HStack(alignment: .top, spacing: 12) {
                // 竖版海报（2:3，不拉伸）
                VodCardView(video: video)
                    .frame(width: 104)
                
                VStack(alignment: .leading, spacing: 6) {
                    // 标题
                    Text(video.name)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(AppTheme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    
                    // 更新状态（橙）
                    if !video.note.isEmpty {
                        Text(video.note)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.orange)
                    }
                    
                    // 地区 / 类型标签
                    if !video.area.isEmpty || !video.type.isEmpty {
                        HStack(spacing: 6) {
                            if !video.area.isEmpty {
                                shortDramaTag(video.area)
                            }
                            if !video.type.isEmpty && video.type != video.area {
                                shortDramaTag(video.type)
                            }
                        }
                    }
                    
                    // 简介（列表接口通常无正文，取备注兜底）
                    if !video.des.isEmpty {
                        Text(video.des)
                            .font(.system(size: 12))
                            .foregroundColor(AppTheme.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    
                    Spacer(minLength: 0)
                    
                    // 观看入口 + 点赞装饰
                    HStack(spacing: 10) {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 11, weight: .bold))
                            Text("立即观看")
                                .font(.system(size: 12, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.orange)
                        .clipShape(Capsule())
                        
                        Spacer(minLength: 0)
                        
                        Image(systemName: "heart")
                            .font(.system(size: 15))
                            .foregroundColor(AppTheme.textSecondary)
                        
                        Image(systemName: "plus.message")
                            .font(.system(size: 14))
                            .foregroundColor(AppTheme.textSecondary)
                    }
                }
                .frame(minHeight: 104)
            }
            .padding(12)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(AppTheme.divider, lineWidth: 1)
            )
        }
        .buttonStyle(VodCardPressStyle())
    }
    
    private func shortDramaTag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(AppTheme.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.white)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(AppTheme.divider, lineWidth: 1))
    }
}
