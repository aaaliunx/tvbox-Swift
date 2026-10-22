import SwiftUI

/// 首页 - 对应 Android 版 HomeActivity + UserFragment
struct HomeView: View {
    @StateObject private var viewModel = HomeViewModel()
    @EnvironmentObject var appState: AppState
    @State private var categoryScrollAnchorId: String?
    /// 分类筛选面板状态。
    @State private var showFilterSheet = false
    
    // 网格布局（腾讯视频式：一屏 2 张大卡）
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
                // 顶部栏
                headerBar
                
                // 分类标签栏
                if !viewModel.sorts.isEmpty {
                    categoryTabBar
                }
                
                // 内容区
                contentArea
            }
            .background(AppTheme.primaryGradient)
        }
        .task {
            await viewModel.loadSorts()
            if let first = viewModel.sorts.first {
                viewModel.selectSort(first)
            }
        }
    }
    
    // MARK: - 顶部栏（源选择器）
    
    private var headerBar: some View {
        HStack(spacing: 12) {
            // 源切换按钮
            Menu {
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
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.tv.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.orange)
                    Text(ApiConfig.shared.homeSourceBean?.name ?? "TVBox")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            
            Spacer()
            
            // 腾讯视频式搜索框入口：点击直达搜索页
            Button {
                NotificationCenter.default.post(name: .switchToSearchTab, object: nil)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.45))
                    Text("搜索影视、电视剧、动漫")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.45))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.08))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
    
    // MARK: - 分类标签栏
    
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
                                VStack(spacing: 6) {
                                    Text(sort.name)
                                        .font(.system(size: 14, weight: viewModel.selectedSort?.id == sort.id ? .bold : .regular))
                                        .foregroundColor(viewModel.selectedSort?.id == sort.id ? .orange : .white.opacity(0.6))
                                    
                                    // 底部指示条（腾讯视频式：橙色短条）
                                    RoundedRectangle(cornerRadius: 1.5)
                                        .fill(Color.orange)
                                        .frame(width: 20, height: 3)
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
            
            // 分类筛选按钮（当前分类支持筛选时显示）
            if let sort = viewModel.selectedSort,
               sort.id != "home",
               !sort.filters.isEmpty {
                Button {
                    showFilterSheet = true
                } label: {
                    Image(systemName: viewModel.activeFilters.isEmpty ? "slider.horizontal.3" : "slider.horizontal.3.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(viewModel.activeFilters.isEmpty ? .white.opacity(0.7) : .orange)
                        .frame(width: 36, height: 36)
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
                        .foregroundColor(.secondary)
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
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    
                    // 如果是不支持的源类型，显示类型信息
                    if let source = ApiConfig.shared.homeSourceBean, !source.isSupportedInSwift {
                        Text("当前源类型: \(source.typeDescription)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Button("重试") {
                        Task { await viewModel.refresh() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    Spacer()
                }
            } else {
                let videos = viewModel.selectedSort?.id == "home"
                    ? viewModel.homeVideos
                    : viewModel.categoryVideos
                
                ScrollView {
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
                    .padding(.horizontal, 20)
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
        .navigationDestination(for: Movie.Video.self) { video in
            DetailView(video: video)
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

