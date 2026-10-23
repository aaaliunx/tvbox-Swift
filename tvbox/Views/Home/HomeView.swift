import SwiftUI

/// 首页 - 腾讯视频 iOS 式布局
struct HomeView: View {
    @StateObject private var viewModel = HomeViewModel()
    @EnvironmentObject var appState: AppState
    @State private var categoryScrollAnchorId: String?
    /// 分类筛选面板状态。
    @State private var showFilterSheet = false
    
    // 网格布局（分类频道页：腾讯视频式一屏 2 张大卡）
    #if os(iOS)
    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]
    #else
    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 16)
    ]
    #endif
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 顶部搜索框 + 筛选
                headerBar
                
                // 分类频道导航栏
                if !viewModel.sorts.isEmpty {
                    categoryTabBar
                }
                
                // 内容区
                contentArea
            }
            .background(AppTheme.pageBackground)
        }
        .task {
            await viewModel.loadSorts()
            if let first = viewModel.sorts.first {
                viewModel.selectSort(first)
            }
            // sorts 就绪后再加载首页分组（避免并发时 sorts 为空导致分组永不加载）。
            await viewModel.loadHomeSections()
        }
    }
    
    // MARK: - 顶部栏（搜索框 + 筛选）
    
    private var headerBar: some View {
        HStack(spacing: 10) {
            // 腾讯视频式胶囊搜索框
            Button {
                NotificationCenter.default.post(name: .switchToSearchTab, object: nil)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(AppTheme.textSecondary)
                    Text("搜索影视、电视剧、动漫")
                        .font(.system(size: 14))
                        .foregroundColor(AppTheme.textSecondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.white)
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(AppTheme.divider, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            
            // 腾讯视频式"筛选"按钮（内含数据源切换）
            Menu {
                Section("数据源") {
                    ForEach(ApiConfig.shared.sourceBeanList.filter { $0.isSupportedInSwift }) { source in
                        Button {
                            ApiConfig.shared.setHomeSource(source)
                            Task { await viewModel.refresh() }
                        } label: {
                            HStack {
                                Text(source.name)
                                if source.key == ApiConfig.shared.homeSourceBean?.key {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 14, weight: .semibold))
                    Text("筛选")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(AppTheme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.white)
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(AppTheme.divider, lineWidth: 1)
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
    
    // MARK: - 分类频道导航栏
    
    private var categoryTabBar: some View {
        HStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(viewModel.sorts) { sort in
                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    viewModel.selectSort(sort)
                                }
                                categoryScrollAnchorId = sort.id
                                scrollCategoryBar(to: sort.id, proxy: proxy)
                            } label: {
                                VStack(spacing: 5) {
                                    Text(sort.name)
                                        .font(.system(size: 15, weight: viewModel.selectedSort?.id == sort.id ? .bold : .regular))
                                        .foregroundColor(viewModel.selectedSort?.id == sort.id ? .orange : AppTheme.textSecondary)
                                    
                                    // 底部指示条（腾讯视频式：橙色短条）
                                    RoundedRectangle(cornerRadius: 1.5)
                                        .fill(Color.orange)
                                        .frame(width: 18, height: 3)
                                        .opacity(viewModel.selectedSort?.id == sort.id ? 1 : 0)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            .id(sort.id)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .onAppear {
                    syncCategoryScrollAnchorIfNeeded()
                    scrollCategoryBar(to: categoryScrollAnchorId, proxy: proxy, animated: false)
                }
                .onChange(of: viewModel.sorts.map(\.id)) { oldValue, newValue in
                    syncCategoryScrollAnchorIfNeeded()
                    scrollCategoryBar(to: categoryScrollAnchorId, proxy: proxy, animated: false)
                }
                .onChange(of: viewModel.selectedSort?.id) { oldId, newId in
                    guard let newId else { return }
                    categoryScrollAnchorId = newId
                    scrollCategoryBar(to: newId, proxy: proxy)
                }
            }
            
            // 当前分类筛选按钮（该分类支持筛选时显示）
            if let sort = viewModel.selectedSort,
               sort.id != "home",
               !sort.filters.isEmpty {
                Button {
                    showFilterSheet = true
                } label: {
                    Image(systemName: viewModel.activeFilters.isEmpty ? "slider.horizontal.3" : "slider.horizontal.3.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(viewModel.activeFilters.isEmpty ? AppTheme.textSecondary : .orange)
                        .frame(width: 34, height: 34)
                        .background(Color.white)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(AppTheme.divider, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .sheet(isPresented: $showFilterSheet) {
            if let sort = viewModel.selectedSort {
                filterPanel(sort: sort)
            }
        }
    }
    
    private func filterPanel(sort: MovieSort.SortData) -> some View {
        CategoryFilterPanel(
            sort: sort,
            initialFilters: viewModel.activeFilters,
            onApply: { viewModel.applyFilters($0) },
            onClear: { viewModel.clearFilters() }
        )
    }
    
    private func syncCategoryScrollAnchorIfNeeded() {
        guard !viewModel.sorts.isEmpty else {
            categoryScrollAnchorId = nil
            return
        }
        
        if let selectedId = viewModel.selectedSort?.id,
           viewModel.sorts.contains(where: { $0.id == selectedId }) {
            categoryScrollAnchorId = selectedId
            return
        }
        
        if let anchorId = categoryScrollAnchorId,
           viewModel.sorts.contains(where: { $0.id == anchorId }) {
            return
        }
        
        categoryScrollAnchorId = viewModel.sorts.first?.id
    }
    
    private func scrollCategoryBar(to id: String?, proxy: ScrollViewProxy, animated: Bool = true) {
        guard let id else { return }
        
        if animated {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(id, anchor: .center)
            }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }
    
    // MARK: - 内容区
    
    private var contentArea: some View {
        Group {
            if viewModel.isLoading && viewModel.categoryVideos.isEmpty && viewModel.homeVideos.isEmpty {
                VStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.orange)
                    Text("加载中...")
                        .font(.subheadline)
                        .foregroundColor(AppTheme.textSecondary)
                        .padding(.top, 12)
                    Spacer()
                }
            } else if let error = viewModel.errorMessage, viewModel.categoryVideos.isEmpty && viewModel.homeVideos.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.subheadline)
                        .foregroundColor(AppTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    
                    // 如果是不支持的源类型，显示类型信息
                    if let source = ApiConfig.shared.homeSourceBean, !source.isSupportedInSwift {
                        Text("当前源类型: \(source.typeDescription)")
                            .font(.caption)
                            .foregroundColor(AppTheme.textSecondary)
                    }
                    
                    Button("重试") {
                        Task { await viewModel.refresh() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    Spacer()
                }
            } else if viewModel.selectedSort?.id == "home" {
                // 首页频道：腾讯视频式（推荐列表 + 分组横滑）
                homeFeed
            } else {
                // 分类频道页：2 列大卡网格
                categoryGrid
            }
        }
        .navigationDestination(for: Movie.Video.self) { video in
            DetailView(video: video)
        }
    }
    
    // MARK: - 首页频道流（腾讯视频式）
    
    private var homeFeed: some View {
        ScrollView {
            VStack(spacing: 18) {
                // 推荐列表（腾讯视频式：第一板块即推荐横滑，不做拉伸横幅）
                if !viewModel.homeVideos.isEmpty {
                    homeSection(
                        title: "推荐",
                        videos: Array(viewModel.homeVideos.prefix(12))
                    )
                }
                
                // 分组横滑（真实分类）
                if viewModel.isLoadingSections && viewModel.homeSections.isEmpty {
                    ProgressView("正在加载推荐...")
                        .tint(.orange)
                        .padding(.top, 30)
                }
                
                ForEach(viewModel.homeSections) { section in
                    homeSection(title: section.title, videos: section.videos)
                }
            }
            .padding(.bottom, 20)
        }
        .refreshable {
            await viewModel.refresh()
            await viewModel.reloadHomeSections()
        }
    }
    
    /// 腾讯视频式分组横滑。
    private func homeSection(title: String, videos: [Movie.Video]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(title)
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
                    ForEach(videos) { video in
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
    
    // MARK: - 分类频道网格
    
    private var categoryGrid: some View {
        let videos = viewModel.selectedSort?.id == "home"
            ? viewModel.homeVideos
            : viewModel.categoryVideos
        
        return ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(videos) { video in
                    NavigationLink(value: video) {
                        VodCardView(video: video)
                    }
                    #if os(iOS)
                    .buttonStyle(VodCardPressStyle())
                    #else
                    .buttonStyle(.plain)
                    #endif
                    .onAppear {
                        Task { await viewModel.loadMoreIfNeeded(currentItem: video) }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            
            // 加载更多
            if viewModel.selectedSort?.id != "home" && viewModel.hasMore {
                ProgressView()
                    .padding()
            }
        }
        .refreshable {
            await viewModel.refresh()
        }
    }
}

/// 分类筛选面板（对齐安卓版分类筛选交互）。
/// 展示分类的所有筛选维度，每维度单选一个值。
private struct CategoryFilterPanel: View {
    let sort: MovieSort.SortData
    let initialFilters: [String: String]
    let onApply: ([String: String]) -> Void
    let onClear: () -> Void
    
    @Environment(\.dismiss) private var dismiss
    /// 各筛选维度的当前选中值（key → value 的 v 字段）。
    @State private var selection: [String: String] = [:]
    /// 维度 key → 展示名。
    @State private var displayNames: [String: String] = [:]
    /// 维度 key → 选项列表。
    @State private var options: [String: [MovieSort.SortFilter.SortFilterValue]] = [:]
    
    var body: some View {
        NavigationStack {
            Form {
                ForEach(sort.filters, id: \.key) { filter in
                    Section(filter.name) {
                        // "全部" 表示该维度不限。
                        Picker("", selection: Binding(
                            get: { selection[filter.key] ?? "" },
                            set: { selection[filter.key] = $0 }
                        )) {
                            Text("全部").tag("")
                            ForEach(filter.values, id: \.v) { value in
                                Text(value.n).tag(value.v)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                }
            }
            .navigationTitle("筛选")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("清除") {
                        onClear()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确定") {
                        onApply(selection.filter { !$0.value.isEmpty })
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            // 回填当前激活的筛选。
            for filter in sort.filters {
                selection[filter.key] = initialFilters[filter.key] ?? ""
                displayNames[filter.key] = filter.name
                options[filter.key] = filter.values
            }
        }
    }
}
