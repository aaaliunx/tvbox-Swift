import SwiftUI

/// 搜索页 - 腾讯视频式布局
struct SearchView: View {
    /// 搜索状态与结果管理。
    @StateObject private var viewModel = SearchViewModel()
    /// 搜索框焦点（用于统一收起键盘）。
    @FocusState private var searchFocused: Bool
    /// 大家都在搜热词。
    private let hotKeywords = ["狂飙", "庆余年", "三体", "繁花", "长相思", "莲花楼", "南来北往", "我的阿勒泰", "甄嬛传", "热辣滚烫"]
    /// 结果筛选类型。
    private let filterTypes = ["全部", "电影", "电视剧", "综艺", "动漫", "短剧"]
    
    #if os(iOS)
    /// iOS 卡片网格参数。
    private let columns = [
        GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 12)
    ]
    #else
    /// macOS 卡片网格参数。
    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 16)
    ]
    #endif
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 搜索栏
                searchBar
                
                // 内容：优先显示已搜出的结果（边搜边显示），
                // 无任何结果时才显示转圈/历史/错误提示。
                if !viewModel.results.isEmpty {
                    searchResults
                } else if viewModel.isSearching {
                    Spacer()
                    ProgressView("搜索中...")
                        .tint(.orange)
                    Spacer()
                } else if viewModel.keyword.isEmpty {
                    // 输入为空时显示历史 + 热词推荐（腾讯视频式）。
                    searchIdleSection
                } else if let error = viewModel.errorMessage {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.largeTitle)
                            .foregroundColor(.gray)
                        Text(error)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            }
            .background(AppTheme.pageBackground)
            .navigationTitle("搜索")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }
    
    // MARK: - 搜索栏
    
    /// 顶部搜索输入区（腾讯视频式：简洁灰底圆角，无渐变描边）。
    private var searchBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(AppTheme.textSecondary)
                
                TextField("搜索影片...", text: $viewModel.keyword)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .foregroundColor(AppTheme.textPrimary)
                    .submitLabel(.search)
                    .focused($searchFocused)
                    .onSubmit {
                        searchFocused = false
                        Task { await viewModel.search() }
                    }
                    #if os(iOS)
                    .autocapitalization(.none)
                    #endif
                
                if !viewModel.keyword.isEmpty {
                    Button {
                        searchFocused = false
                        withAnimation {
                            viewModel.keyword = ""
                            viewModel.results = []
                            viewModel.filterType = "全部"
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(AppTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.white)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10).stroke(AppTheme.divider, lineWidth: 1)
            )
            
            Button {
                searchFocused = false
                Task { await viewModel.search() }
            } label: {
                Text("搜索")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(AppTheme.accentGradient)
                    .cornerRadius(10)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }
    
    // MARK: - 空闲页（历史 + 热词）
    
    /// 输入为空时的腾讯视频式空闲页：搜索历史 + 大家都在搜。
    private var searchIdleSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // 搜索历史
                if !viewModel.searchHistory.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("搜索历史")
                                .font(.headline)
                                .foregroundColor(AppTheme.textPrimary)
                            Spacer()
                            Button {
                                viewModel.clearHistory()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "trash")
                                    Text("清空")
                                }
                                .font(.caption)
                                .foregroundColor(.gray)
                            }
                        }
                        
                        FlowLayout(spacing: 8) {
                            ForEach(viewModel.searchHistory, id: \.self) { keyword in
                                Button {
                                    searchFocused = false
                                    viewModel.keyword = keyword
                                    Task { await viewModel.search() }
                                } label: {
                                    Text(keyword)
                                        .font(.subheadline)
                                        .foregroundColor(AppTheme.textPrimary)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 7)
                                        .background(Color.white)
                                        .cornerRadius(16)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 16).stroke(AppTheme.divider, lineWidth: 1)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                
                // 大家都在搜
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 6) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.orange)
                        Text("大家都在搜")
                            .font(.headline)
                            .foregroundColor(AppTheme.textPrimary)
                    }
                    
                    FlowLayout(spacing: 8) {
                        ForEach(hotKeywords, id: \.self) { keyword in
                            Button {
                                searchFocused = false
                                viewModel.keyword = keyword
                                Task { await viewModel.search() }
                            } label: {
                                Text(keyword)
                                    .font(.subheadline)
                                    .foregroundColor(.orange.opacity(0.9))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 7)
                                    .background(Color.orange.opacity(0.1))
                                    .cornerRadius(16)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
        }
    }
    
    // MARK: - 搜索结果
    
    /// 搜索结果：顶部筛选条 + 卡片网格。
    private var searchResults: some View {
        VStack(spacing: 0) {
            // 腾讯视频式筛选条
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(filterTypes, id: \.self) { type in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                viewModel.filterType = type
                            }
                        } label: {
                            Text(type)
                                .font(.system(size: 13, weight: viewModel.filterType == type ? .bold : .regular))
                                .foregroundColor(viewModel.filterType == type ? .orange : AppTheme.textSecondary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(viewModel.filterType == type ? Color.orange.opacity(0.15) : Color.clear)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
            
            ScrollView {
                // 搜索仍在进行时显示轻量提示（结果已开始逐个出现）。
                if viewModel.isSearching {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.orange)
                        Text("正在搜索更多源…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("已出 \(viewModel.results.count) 个结果")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                }
                
                if viewModel.filteredResults.isEmpty && !viewModel.isSearching {
                    VStack(spacing: 8) {
                        Spacer()
                        Text("该分类暂无结果")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                }
                
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(viewModel.filteredResults) { item in
                        NavigationLink(value: item.video) {
                            ZStack(alignment: .topTrailing) {
                                VodCardView(
                                    video: item.video,
                                    onPosterLoaded: { url in
                                        viewModel.registerLoadedPoster(for: item, url: url)
                                    }
                                )
                                // 来源站点名徽标
                                Text(item.sourceName)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Color.black.opacity(0.55))
                                    .clipShape(Capsule())
                                    .padding(6)
                            }
                        }
                        #if os(iOS)
                        .buttonStyle(VodCardPressStyle())
                        #else
                        .buttonStyle(.plain)
                        #endif
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            // 手指在结果区一拖动/滚动立即收起键盘（腾讯视频式交互）。
            // 注：结果较少时内容不满一屏，scrollDismissesKeyboard 不会触发，
            // 因此用拖拽手势兜底，任何拖动都立即收起键盘。
            .scrollDismissesKeyboard(.immediately)
            .simultaneousGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { _ in
                        if searchFocused {
                            searchFocused = false
                        }
                    }
            )
        }
        .navigationDestination(for: Movie.Video.self) { video in
            DetailView(video: video)
        }
    }
}

/// 流式布局
struct FlowLayout: Layout {
    /// 子项间距。
    var spacing: CGFloat = 8
    
    /// 计算整体尺寸。
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangement(proposal: proposal, subviews: subviews)
        return result.size
    }
    
    /// 按计算结果放置子视图。
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangement(proposal: ProposedViewSize(width: bounds.width, height: bounds.height), subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }
    
    /// 核心排版算法：按最大宽度逐个放置，超宽后自动换行。
    private func arrangement(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0
        
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            positions.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            maxX = max(maxX, currentX)
        }
        
        return (CGSize(width: maxX, height: currentY + lineHeight), positions)
    }
}
