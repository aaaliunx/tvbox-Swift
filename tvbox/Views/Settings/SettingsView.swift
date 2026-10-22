import SwiftUI
import UniformTypeIdentifiers

/// 设置页 - 对应 Android 版 SettingActivity + ModelSettingFragment
struct SettingsView: View {
    enum ApiInputType {
        case vod
        case live
        
        var title: String {
            switch self {
            case .vod: return "点播接口地址"
            case .live: return "直播接口地址"
            }
        }
        
        var placeholder: String {
            switch self {
            case .vod: return "请输入点播接口地址"
            case .live: return "请输入直播接口地址（可留空跟随点播）"
            }
        }
    }
    
    @StateObject private var viewModel = SettingsViewModel()
    @StateObject private var apiConfig = ApiConfig.shared
    @EnvironmentObject var appState: AppState
    @State private var showApiInput = false
    @State private var editingApiType: ApiInputType = .vod
    @State private var showAbout = false
    @State private var sourceSearchText = ""
    @State private var showingPicker: PickerType = .none
    /// 源站点检测状态。
    @State private var isCheckingSources = false
    @State private var checkedCount = 0
    @State private var totalCount = 0
    /// 遥控服务状态。
    @StateObject private var remoteControl = RemoteControlService.shared
    /// 备份导出文件（ShareLink 用）。
    @State private var backupExportURL: URL?
    /// 备份导入文件选择器。
    @State private var showImportImporter = false
    
    enum PickerType {
        case none
        case vodPlayer
        case livePlayer
        case decode
        case vlcBuffer
        case playTimeStep
        case historyLimit
        case playScale
    }
    
    /// 源检测状态文案。
    private var detectionStatusText: String {
        if isCheckingSources {
            return "检测中 \(checkedCount)/\(totalCount)"
        }
        let blocked = apiConfig.blockedSourceKeys.count
        if blocked > 0 {
            return "已屏蔽 \(blocked) 个失效站点"
        }
        return "全部站点正常"
    }
    
    /// 开始检测全部源站点：失败自动屏蔽、成功解除。
    private func startSiteCheck() {
        guard !isCheckingSources else { return }
        isCheckingSources = true
        checkedCount = 0
        totalCount = apiConfig.sourceBeanList.filter { $0.isHttpApi }.count
        Task {
            await apiConfig.checkAllSources { done, total, _, ok in
                checkedCount = done
                totalCount = total
            }
            isCheckingSources = false
        }
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // API 配置
                    SectionCard(title: "数据源") {
                        SettingsRow(
                            icon: "film",
                            title: "点播接口地址",
                            value: viewModel.vodApiUrl.isEmpty ? "未配置" : viewModel.vodApiUrl
                        ) {
                            editingApiType = .vod
                            showApiInput = true
                        }
                        Divider().background(Color.white.opacity(0.1))
                        SettingsRow(
                            icon: "tv",
                            title: "直播接口地址",
                            value: viewModel.liveApiUrl.isEmpty ? "跟随点播接口" : viewModel.liveApiUrl
                        ) {
                            editingApiType = .live
                            showApiInput = true
                        }
                        Divider().background(Color.white.opacity(0.1))
                        if !apiConfig.sourceBeanList.isEmpty {
                            NavigationLink {
                                sourcePickerView
                            } label: {
                                SettingsRow(icon: "server.rack", title: "主页数据源", value: apiConfig.homeSourceBean?.name ?? "", action: nil)
                            }
                            Divider().background(Color.white.opacity(0.1))
                            // 源站点检测：失效站点自动屏蔽，搜索/列表自动跳过。
                            SettingsRow(
                                icon: "antenna.radiowaves.left.and.right",
                                title: "检测源站点",
                                value: detectionStatusText,
                                action: startSiteCheck
                            )
                            .disabled(isCheckingSources)
                            if isCheckingSources {
                                ProgressView(value: Float(checkedCount), total: Float(max(totalCount, 1)))
                                    .progressViewStyle(.linear)
                                    .tint(.orange)
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 10)
                            }
                        }
                    }
                    
                    // 播放设置
                    SectionCard(title: "播放设置") {
                        SettingsRow(icon: "play.rectangle", title: "点播播放器", value: viewModel.vodPlayerEngine.title) {
                            if viewModel.playerEngineOptions.count > 1 {
                                showingPicker = .vodPlayer
                            }
                        }
                        Divider().background(Color.white.opacity(0.1))
                        SettingsRow(icon: "dot.radiowaves.left.and.right", title: "直播播放器", value: viewModel.livePlayerEngine.title) {
                            if viewModel.playerEngineOptions.count > 1 {
                                showingPicker = .livePlayer
                            }
                        }
                        Divider().background(Color.white.opacity(0.1))
                        // 直播自动换线：关闭后播放失败只提示，不再自动切换线路（避免正常直播突然换源）。
                        SettingsRow(icon: "arrow.triangle.2.circlepath", title: "直播自动换线", value: viewModel.liveAutoSwitchLine ? "开启" : "关闭") {
                            viewModel.liveAutoSwitchLine.toggle()
                            UserDefaults.standard.set(viewModel.liveAutoSwitchLine, forKey: HawkConfig.LIVE_AUTO_SWITCH_LINE)
                        }
                        Divider().background(Color.white.opacity(0.1))
                        SettingsRow(icon: "cpu", title: "视频解码", value: viewModel.decodeMode.title) {
                            showingPicker = .decode
                        }
                        if PlayerEngine.isVLCAvailable {
                            Divider().background(Color.white.opacity(0.1))
                            SettingsRow(icon: "externaldrive.badge.wifi", title: "VLC缓冲", value: viewModel.vlcBufferMode.title) {
                                showingPicker = .vlcBuffer
                            }
                        }
                        Divider().background(Color.white.opacity(0.1))
                        SettingsRow(icon: "forward", title: "快进步长", value: "\(viewModel.playTimeStep)秒") {
                            showingPicker = .playTimeStep
                        }
                        Divider().background(Color.white.opacity(0.1))
                        SettingsRow(icon: "rectangle.dashed", title: "画面缩放", value: viewModel.playScale.rawValue) {
                            showingPicker = .playScale
                        }
                        if PlayerEngine.isVLCAvailable {
                            Divider().background(Color.white.opacity(0.1))
                            SettingsRow(icon: "wand.and.stars", title: "M3U8净化", value: viewModel.m3u8Clean ? "开启" : "关闭") {
                                viewModel.m3u8Clean.toggle()
                                UserDefaults.standard.set(viewModel.m3u8Clean, forKey: HawkConfig.M3U8_CLEAN)
                            }
                        }
                    }
                    
                    // 功能
                    SectionCard(title: "功能") {
                        SettingsRow(icon: "list.number", title: "历史条数", value: "\(viewModel.historyLimit)条") {
                            showingPicker = .historyLimit
                        }
                        Divider().background(Color.white.opacity(0.1))
                        NavigationLink {
                            HistoryView()
                        } label: {
                            SettingsRow(icon: "clock", title: "播放历史", value: "", action: nil)
                        }
                        Divider().background(Color.white.opacity(0.1))
                        NavigationLink {
                            FavoritesView()
                        } label: {
                            SettingsRow(icon: "heart", title: "我的收藏", value: "", action: nil)
                        }
                    }
                    
                    // 遥控
                    SectionCard(title: "遥控服务") {
                        SettingsRow(icon: "antenna.radiowaves.left.and.right", title: "局域网遥控", value: remoteControl.isRunning ? "已开启" : "已关闭") {
                            if remoteControl.isRunning {
                                remoteControl.stop()
                            } else {
                                remoteControl.start()
                            }
                        }
                        if remoteControl.isRunning, !remoteControl.accessURL.isEmpty {
                            Divider().background(Color.white.opacity(0.1))
                            VStack(alignment: .leading, spacing: 4) {
                                Text("访问地址（同一 Wi-Fi 下用浏览器打开）")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.5))
                                Text(remoteControl.accessURL)
                                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.orange)
                                    .textSelection(.enabled)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                        }
                    }
                    
                    // 备份 / 恢复
                    SectionCard(title: "备份与恢复") {
                        SettingsRow(icon: "square.and.arrow.up", title: "导出配置", value: "") {
                            if let data = viewModel.buildBackupJSON() {
                                let url = FileManager.default.temporaryDirectory
                                    .appendingPathComponent("tvbox_backup.json")
                                try? data.write(to: url)
                                backupExportURL = url
                            }
                        }
                        if let backupExportURL {
                            Divider().background(Color.white.opacity(0.1))
                            ShareLink(item: backupExportURL) {
                                SettingsRow(icon: "square.and.arrow.up.circle", title: "分享备份文件", value: "", action: nil)
                            }
                        }
                        Divider().background(Color.white.opacity(0.1))
                        SettingsRow(icon: "square.and.arrow.down", title: "导入配置", value: "") {
                            showImportImporter = true
                        }
                    }
                    
                    // 缓存
                    SectionCard(title: "缓存") {
                        SettingsRow(icon: "trash", title: "清除缓存", value: viewModel.cacheSizeString) {
                            viewModel.clearCache()
                        }
                    }
                    
                    // 关于
                    SectionCard(title: "关于") {
                        SettingsRow(icon: "info.circle", title: "版本", value: "1.0.0", action: nil)
                        Divider().background(Color.white.opacity(0.1))
                        SettingsRow(icon: "globe", title: "站点数量", value: "\(apiConfig.sourceBeanList.count)", action: nil)
                        Divider().background(Color.white.opacity(0.1))
                        SettingsRow(icon: "wand.and.stars", title: "解析数量", value: "\(apiConfig.parseBeanList.count)", action: nil)
                        Divider().background(Color.white.opacity(0.1))
                        SettingsRow(icon: "tv", title: "直播分组", value: "\(apiConfig.liveChannelGroupList.count)", action: nil)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
            .background(AppTheme.primaryGradient.ignoresSafeArea())
            .navigationTitle("设置")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            #endif
            .sheet(isPresented: $showApiInput) {
                apiInputSheet
            }
        }
        .overlay(pickerOverlay)
        .fileImporter(
            isPresented: $showImportImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first,
                      let data = try? Data(contentsOf: url) else { return }
                if viewModel.restoreBackup(json: data) {
                    // 恢复成功后刷新源列表。
                    Task {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        await viewModel.loadConfig()
                    }
                }
            case .failure:
                break
            }
        }
    }
    
    // MARK: - 选择器 Overlay
    
    @ViewBuilder
    private var pickerOverlay: some View {
        switch showingPicker {
        case .vodPlayer:
            SelectionModal(
                title: "选择点播播放器",
                icon: "play.rectangle.fill",
                items: viewModel.playerEngineOptions,
                selectedItem: viewModel.vodPlayerEngine,
                itemTitle: { $0.title },
                onSelect: { engine in
                    viewModel.setVodPlayerEngine(engine)
                    showingPicker = .none
                },
                onCancel: { showingPicker = .none }
            )
        case .livePlayer:
            SelectionModal(
                title: "选择直播播放器",
                icon: "dot.radiowaves.left.and.right",
                items: viewModel.playerEngineOptions,
                selectedItem: viewModel.livePlayerEngine,
                itemTitle: { $0.title },
                onSelect: { engine in
                    viewModel.setLivePlayerEngine(engine)
                    showingPicker = .none
                },
                onCancel: { showingPicker = .none }
            )
        case .decode:
            SelectionModal(
                title: "视频解码模式",
                icon: "cpu.fill",
                items: viewModel.decodeModeOptions,
                selectedItem: viewModel.decodeMode,
                itemTitle: { $0.title },
                onSelect: { mode in
                    viewModel.setDecodeMode(mode)
                    showingPicker = .none
                },
                onCancel: { showingPicker = .none }
            )
        case .vlcBuffer:
            SelectionModal(
                title: "VLC 缓冲策略",
                icon: "externaldrive.fill",
                items: viewModel.vlcBufferModeOptions,
                selectedItem: viewModel.vlcBufferMode,
                itemTitle: { $0.title },
                onSelect: { mode in
                    viewModel.setVLCBufferMode(mode)
                    showingPicker = .none
                },
                onCancel: { showingPicker = .none }
            )
        case .playTimeStep:
            SelectionModal(
                title: "快进步长",
                icon: "forward.fill",
                items: viewModel.playTimeStepOptions,
                selectedItem: viewModel.playTimeStep,
                itemTitle: { "\($0) 秒" },
                onSelect: { step in
                    viewModel.setPlayTimeStep(step)
                    showingPicker = .none
                },
                onCancel: { showingPicker = .none }
            )
        case .historyLimit:
            SelectionModal(
                title: "历史记录条数",
                icon: "list.number",
                items: viewModel.historyLimitOptions,
                selectedItem: viewModel.historyLimit,
                itemTitle: { "\($0) 条" },
                onSelect: { limit in
                    viewModel.historyLimit = limit
                    UserDefaults.standard.set(limit, forKey: HawkConfig.HISTORY_NUM)
                    showingPicker = .none
                },
                onCancel: { showingPicker = .none }
            )
        case .playScale:
            SelectionModal(
                title: "画面缩放",
                icon: "rectangle.dashed",
                items: SettingsViewModel.PlayScaleOption.allCases,
                selectedItem: viewModel.playScale,
                itemTitle: { $0.rawValue },
                onSelect: { option in
                    viewModel.playScale = option
                    UserDefaults.standard.set(option.rawValue, forKey: HawkConfig.PLAY_SCALE)
                    showingPicker = .none
                },
                onCancel: { showingPicker = .none }
            )
        case .none:
            EmptyView()
        }
    }
    
    // MARK: - API 输入弹窗
    
    private var apiInputSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                HStack {
                    Image(systemName: "link")
                        .foregroundColor(.secondary)
                    TextField(editingApiType.placeholder, text: currentApiBinding)
                        .textFieldStyle(.plain)
                        #if os(iOS)
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                        #endif
                }
                .padding()
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(10)
                
                // 粘贴按钮
                HStack {
                    Button {
                        if let text = readPasteboardText() {
                            currentApiBinding.wrappedValue = text
                        }
                    } label: {
                        Label("粘贴", systemImage: "doc.on.clipboard")
                            .font(.subheadline)
                    }
                    
                    Spacer()
                }
                
                // 历史记录
                if !viewModel.apiHistory.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("历史记录")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        ForEach(viewModel.apiHistory, id: \.self) { url in
                            HStack {
                                Button {
                                    currentApiBinding.wrappedValue = url
                                } label: {
                                    HStack {
                                        Image(systemName: "clock")
                                            .font(.caption)
                                        Text(url)
                                            .font(.caption)
                                            .lineLimit(1)
                                    }
                                    .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                                
                                Button {
                                    viewModel.removeApiHistory(url)
                                } label: {
                                    Image(systemName: "xmark.circle")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                            }
                        }
                    }
                }
                
                if let error = viewModel.configError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
                
                Spacer()
            }
            .padding()
            .navigationTitle(editingApiType.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showApiInput = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            await viewModel.loadConfig()
                            if viewModel.configSuccess {
                                appState.applyLoadedConfigState()
                                showApiInput = false
                            }
                        }
                    } label: {
                        if viewModel.isLoadingConfig {
                            ProgressView()
                        } else {
                            Text("确认")
                        }
                    }
                    .disabled(
                        viewModel.isLoadingConfig
                        || viewModel.vodApiUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
        }
        .overlay(multiRepoSelectionOverlay)
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }
    
    @ViewBuilder
    private var multiRepoSelectionOverlay: some View {
        if let pending = viewModel.pendingMultiRepoSelection {
            SelectionModal(
                title: "选择\(pending.target.title)仓库",
                icon: "list.bullet.rectangle.portrait.fill",
                items: pending.options,
                selectedItem: nil,
                itemTitle: { $0.name },
                onSelect: { option in
                    Task {
                        await viewModel.selectPendingMultiRepoOption(option)
                        if viewModel.configSuccess {
                            appState.applyLoadedConfigState()
                            showApiInput = false
                        }
                    }
                },
                onCancel: {
                    viewModel.cancelPendingMultiRepoSelection()
                }
            )
        }
    }
    
    private var currentApiBinding: Binding<String> {
        switch editingApiType {
        case .vod:
            return $viewModel.vodApiUrl
        case .live:
            return $viewModel.liveApiUrl
        }
    }
    
    private func readPasteboardText() -> String? {
        #if os(iOS)
        UIPasteboard.general.string
        #else
        NSPasteboard.general.string(forType: .string)
        #endif
    }
    
    // MARK: - 源选择
    
    private var filteredSources: [SourceBean] {
        let sources = apiConfig.sourceBeanList
        if sourceSearchText.isEmpty {
            return sources
        } else {
            return sources.filter { $0.name.localizedCaseInsensitiveContains(sourceSearchText) || $0.api.localizedCaseInsensitiveContains(sourceSearchText) }
        }
    }

    private var sourcePickerView: some View {
        VStack(spacing: 0) {
            // 搜索栏
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("搜索数据源", text: $sourceSearchText)
                    .textFieldStyle(.plain)
                if !sourceSearchText.isEmpty {
                    Button(action: { sourceSearchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .glassCard(cornerRadius: 12)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(filteredSources) { source in
                        Button {
                            apiConfig.setHomeSource(source)
                            appState.currentSourceKey = source.key
                        } label: {
                            HStack(alignment: .center, spacing: 16) {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 8) {
                                        Text(source.name)
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor(source.isSupportedInSwift ? .white : .white.opacity(0.5))
                                        
                                        // 类型标签
                                        Text(source.typeDescription)
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(source.isSupportedInSwift ? .orange : .gray)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(
                                                Capsule().fill(
                                                    source.isSupportedInSwift ? Color.orange.opacity(0.2) : Color.gray.opacity(0.2)
                                                )
                                            )
                                        
                                        if !source.isSupportedInSwift {
                                            // jar:// 为安卓 App 内置 jar 包协议，iOS 无对应 jar 文件；
                                            // http(s) 的 .jar/.js 脚本源已在 SpiderService 支持（zip 解包 JS）。
                                            Text(source.api.hasPrefix("jar://") ? "安卓内置" : "暂不支持")
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundColor(.red.opacity(0.8))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 3)
                                                .background(Capsule().fill(Color.red.opacity(0.15)))
                                        }
                                    }
                                    
                                    Text(source.api)
                                        .font(.system(size: 12))
                                        .foregroundColor(.white.opacity(0.5))
                                        .lineLimit(1)
                                }
                                
                                Spacer()
                                
                                HStack(spacing: 12) {
                                    if source.isSearchable {
                                        Image(systemName: "magnifyingglass")
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundColor(.green.opacity(0.8))
                                    }
                                    
                                    if source.key == apiConfig.homeSourceBean?.key {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 20))
                                            .foregroundColor(.orange)
                                    } else {
                                        Circle()
                                            .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                                            .frame(width: 20, height: 20)
                                    }
                                }
                            }
                            .padding(16)
                            .glassCard(cornerRadius: 16)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(
                                        source.key == apiConfig.homeSourceBean?.key ? Color.orange.opacity(0.5) : Color.clear,
                                        lineWidth: 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .background(AppTheme.primaryGradient.ignoresSafeArea())
        .navigationTitle("选择数据源")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - 辅助组件

struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.bold)
                .foregroundColor(.white.opacity(0.6))
                .padding(.leading, 8)
            
            VStack(spacing: 0) {
                content()
            }
            .glassCard(cornerRadius: 16)
        }
    }
}

struct SettingsRow: View {
    let icon: String
    let title: String
    let value: String
    let action: (() -> Void)?
    
    var body: some View {
        Group {
            if let action = action {
                Button(action: action) {
                    rowContent
                }
                .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
    }
    
    private var rowContent: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.orange)
                .frame(width: 24)
            
            Text(title)
                .font(.body)
                .foregroundColor(.white.opacity(0.9))
            
            Spacer()
            
            Text(value)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.5))
                .lineLimit(1)
            
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white.opacity(0.3))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}
