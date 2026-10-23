import SwiftUI
import SwiftData
import AVFoundation
#if os(iOS)
import AVKit
#endif
#if os(macOS)
import AppKit
#endif

/// 详情页 - 对应 Android 版 DetailActivity
struct DetailView: View {
    let video: Movie.Video
    @StateObject private var viewModel = DetailViewModel()
    @StateObject private var sharedSystemController = SystemPlayerSessionController()
    @StateObject private var sharedVLCController = VLCPlayerController()
    @EnvironmentObject var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @State private var showFullScreen = false
    /// VLC 全屏退出动画期间为 true，防止内联播放器与全屏播放器同时争抢 drawable
    @State private var isFullScreenDismissing = false
    #if os(macOS)
    @State private var pendingMacWindowFullScreen = false
    #endif
    @State private var lastPersistedProgress: Double = 0
    @State private var isCollected = false
    /// 嗅探重试状态：防止失败回调循环触发。
    @State private var isSniffing = false
    /// 已嗅探/已解析过的地址集合（避免重复尝试）。
    @State private var sniffedUrls: Set<String> = []
    
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // 播放器区域
                playerSection
                
                // 视频信息
                videoInfoSection
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                
                // 线路选择
                if viewModel.flags.count > 1 {
                    flagSelector
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                }
                
                // 清晰度选择
                if viewModel.hasQualityChoices {
                    qualitySelector
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                }
                
                // 剧集列表
                if !viewModel.currentEpisodes.isEmpty {
                    episodeSection
                        .padding(.top, 16)
                }
                
                // 简介
                if let info = viewModel.vodInfo, !info.des.isEmpty {
                    descriptionSection(info.des)
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                }
            }
            .padding(.bottom, 40)
        }
        .background(AppTheme.primaryGradient)
        .navigationTitle(video.name)
        #if os(macOS)
        .toolbar((showFullScreen || pendingMacWindowFullScreen) ? .hidden : .visible, for: .windowToolbar)
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: "\(video.sourceKey)-\(video.id)") {
            await viewModel.loadDetail(video: video)
            restorePlaybackFromHistory()
            refreshCollectState()
        }
        .onReceive(NotificationCenter.default.publisher(for: RemoteControlService.playRequestNotification)) { notification in
            // 局域网遥控：播放指定地址。
            if let url = notification.userInfo?["url"] as? String {
                viewModel.playSniffed(url: url)
            }
        }
        .onDisappear {
            viewModel.commitPlaybackProgressSnapshot()
            persistHistoryIfNeeded(force: true)
            showFullScreen = false
            sharedSystemController.stop()
            sharedVLCController.stop()
            #if os(macOS)
            pendingMacWindowFullScreen = false
            appState.exitPlayerFullScreen()
            #endif
        }
        #if os(macOS)
        .overlay {
            if showFullScreen, let url = viewModel.playUrl {
                FullScreenPlayerView(
                    urlString: url,
                    title: video.name,
                    startPosition: viewModel.currentPlaybackSeconds(),
                    onProgressChanged: handlePlaybackProgress,
                    onPlaybackEnded: playNextEpisodeIfNeeded,
                    canPlayNext: canPlayNextEpisode,
                    onPlayNext: playNextEpisodeIfNeeded,
                    systemController: sharedSystemController,
                    vlcController: sharedVLCController,
                    onCloseRequested: closeMacFullScreenOverlay,
                    sourceNames: viewModel.flags,
                    selectedSourceIndex: viewModel.flags.firstIndex(of: viewModel.selectedFlag) ?? 0,
                    onSelectSource: { index in
                        let flags = viewModel.flags
                        guard index >= 0, index < flags.count else { return }
                        viewModel.selectFlag(flags[index])
                    },
                    episodeNames: viewModel.currentEpisodes.map { $0.name },
                    selectedEpisodeIndex: viewModel.selectedEpisodeIndex,
                    onSelectEpisode: { index in
                        viewModel.selectEpisode(index: index)
                    }
                )
                .ignoresSafeArea()
                .transition(.opacity)
                .zIndex(2)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            guard pendingMacWindowFullScreen else { return }
            pendingMacWindowFullScreen = false
            showFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            pendingMacWindowFullScreen = false
            if showFullScreen {
                showFullScreen = false
            }
            appState.exitPlayerFullScreen()
        }
        #endif
        #if os(iOS)
        .fullScreenCover(isPresented: $showFullScreen, onDismiss: {
            isFullScreenDismissing = false
        }) {
            if let url = viewModel.playUrl {
                FullScreenPlayerView(
                    urlString: url,
                    title: video.name,
                    startPosition: viewModel.currentPlaybackSeconds(),
                    onProgressChanged: handlePlaybackProgress,
                    onPlaybackEnded: playNextEpisodeIfNeeded,
                    canPlayNext: canPlayNextEpisode,
                    onPlayNext: playNextEpisodeIfNeeded,
                    systemController: sharedSystemController,
                    vlcController: sharedVLCController,
                    onCloseRequested: {
                        isFullScreenDismissing = true
                        showFullScreen = false
                    },
                    sourceNames: viewModel.flags,
                    selectedSourceIndex: viewModel.flags.firstIndex(of: viewModel.selectedFlag) ?? 0,
                    onSelectSource: { index in
                        let flags = viewModel.flags
                        guard index >= 0, index < flags.count else { return }
                        viewModel.selectFlag(flags[index])
                    },
                    episodeNames: viewModel.currentEpisodes.map { $0.name },
                    selectedEpisodeIndex: viewModel.selectedEpisodeIndex,
                    onSelectEpisode: { index in
                        viewModel.selectEpisode(index: index)
                    }
                )
            }
        }
        #endif
    }
    
    // MARK: - 视频信息
    
    #if os(iOS)
    /// 播放器区域（独立计算属性，降低 body 类型推断复杂度）。
    @ViewBuilder
    private var playerSection: some View {
        if !showFullScreen, !isFullScreenDismissing, viewModel.isPlaying, let url = viewModel.playUrl {
            PlayerView(
                urlString: url,
                startPosition: viewModel.currentPlaybackSeconds(),
                onProgressChanged: handlePlaybackProgress,
                onPlaybackEnded: playNextEpisodeIfNeeded,
                onPlaybackFailed: {
                    handlePlaybackFailed()
                },
                onToggleFullScreen: {
                    openFullScreenPlayer()
                },
                canPlayNext: canPlayNextEpisode,
                onPlayNext: playNextEpisodeIfNeeded,
                systemController: sharedSystemController,
                vlcController: sharedVLCController
            )
            .id("\(viewModel.selectedFlag)-\(viewModel.selectedEpisodeIndex)-\(url)")
            .aspectRatio(16/9, contentMode: .fit)
            .background(Color.black)
            .onTapGesture(count: 2) {
                openFullScreenPlayer()
            }
        }
    }
    #else
    @ViewBuilder
    private var playerSection: some View {
        if !showFullScreen, viewModel.isPlaying, let url = viewModel.playUrl {
            PlayerView(
                urlString: url,
                startPosition: viewModel.currentPlaybackSeconds(),
                onProgressChanged: handlePlaybackProgress,
                onPlaybackEnded: playNextEpisodeIfNeeded,
                onPlaybackFailed: {
                    handlePlaybackFailed()
                },
                onToggleFullScreen: {
                    openFullScreenPlayer()
                },
                canPlayNext: canPlayNextEpisode,
                onPlayNext: playNextEpisodeIfNeeded,
                systemController: sharedSystemController,
                vlcController: sharedVLCController
            )
            .id("\(viewModel.selectedFlag)-\(viewModel.selectedEpisodeIndex)-\(url)")
            .aspectRatio(16/9, contentMode: .fit)
            .background(Color.black)
            .onTapGesture(count: 2) {
                openFullScreenPlayer()
            }
        }
    }
    #endif
    
    #if os(iOS)
    @ViewBuilder
    private var videoInfoSection: some View {
        VStack(spacing: 16) {
            // Poster centered, height capped to 30% of screen
            let posterHeight = UIScreen.main.bounds.height * 0.30
            CachedAsyncImage(url: URL.posterURL(from: video.pic)) { image in
                image.resizable().aspectRatio(2/3, contentMode: .fit)
            } placeholder: {
                AppTheme.divider
                    .aspectRatio(2/3, contentMode: .fit)
            }
            .frame(maxHeight: posterHeight)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardRadius))

            // Info below poster
            videoDetails

            // Action buttons with 48pt height
            HStack(spacing: 12) {
                playButton
                collectButton
            }
            .frame(minHeight: 48)
        }
        .padding(15)
        .glassCard(cornerRadius: AppTheme.glassRadius)
    }
    #else
    @ViewBuilder
    private var videoInfoSection: some View {
        HStack(alignment: .top, spacing: 20) {
            videoPoster
            
            videoDetails
            
            Spacer()
        }
        .padding(15)
        .glassCard(cornerRadius: AppTheme.glassRadius)
    }
    #endif

    @ViewBuilder
    private var videoPoster: some View {
        CachedAsyncImage(url: URL.posterURL(from: video.pic)) { image in
            image.resizable().aspectRatio(2/3, contentMode: .fill)
        } placeholder: {
            ZStack {
                AppTheme.divider
                Image(systemName: "film.fill").foregroundColor(AppTheme.textSecondary.opacity(0.5))
            }
            .aspectRatio(2/3, contentMode: .fill)
        }
        .frame(width: 130)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardRadius))
        .shadow(color: .black.opacity(0.5), radius: 10, x: 0, y: 5)
    }

    @ViewBuilder
    private var videoDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(viewModel.vodInfo?.name ?? video.name)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(AppTheme.textPrimary)
            
            if let info = viewModel.vodInfo {
                VStack(alignment: .leading, spacing: 6) {
                    infoRow("年份", info.year)
                    infoRow("地区", info.area)
                    infoRow("类型", info.typeName)
                    infoRow("导演", info.director)
                    infoRow("演员", info.actor)
                }
            }
            
            #if os(macOS)
            Spacer(minLength: 10)
            
            HStack(spacing: 10) {
                playButton
                collectButton
            }
            #endif
        }
    }

    @ViewBuilder
    private var playButton: some View {
        if !viewModel.isPlaying && viewModel.vodInfo != nil {
            Button {
                viewModel.selectEpisode(index: 0)
                saveHistoryForCurrentEpisode()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                    Text("立即播放")
                }
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .background(AppTheme.accentGradient)
                .clipShape(Capsule())
                .shadow(color: .red.opacity(0.4), radius: 10, x: 0, y: 5)
            }
            .buttonStyle(.plain)
        }
    }
    
    private var collectButton: some View {
        Button {
            toggleCollect()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isCollected ? "heart.fill" : "heart")
                Text(isCollected ? "已收藏" : "收藏")
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(AppTheme.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                Group {
                    if isCollected {
                        AppTheme.accentGradient
                    } else {
                        Color.white
                    }
                }
            )
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(AppTheme.divider, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
    
    @ViewBuilder
    private func infoRow(_ label: String, _ value: String) -> some View {
        if !value.isEmpty {
            HStack(alignment: .top, spacing: 4) {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.gray)
                    .frame(width: 36, alignment: .leading)
                Text(value)
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)
                    .lineLimit(2)
            }
        }
    }
    
    // MARK: - 线路选择
    
    @ViewBuilder
    private var flagSelector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("播放线路")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(AppTheme.textPrimary)
            
            flagScrollView
        }
        .padding(15)
        .glassCard(cornerRadius: AppTheme.glassRadius)
    }

    @ViewBuilder
    private var flagScrollView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(viewModel.flags, id: \.self) { flag in
                    flagButton(flag)
                }
            }
        }
    }

    @ViewBuilder
    private func flagButton(_ flag: String) -> some View {
        Button {
            withAnimation {
                viewModel.selectFlag(flag)
            }
            if viewModel.isPlaying {
                saveHistoryForCurrentEpisode()
            }
        } label: {
            Text(flag)
                .font(.system(size: 14, weight: viewModel.selectedFlag == flag ? .bold : .medium))
                .foregroundColor(viewModel.selectedFlag == flag ? .orange : AppTheme.textSecondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    ZStack {
                        if viewModel.selectedFlag == flag {
                            AppTheme.accentGradient
                        } else {
                            AppTheme.divider
                        }
                    }
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - 清晰度选择
    
    @ViewBuilder
    private var qualitySelector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("视频清晰度")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(AppTheme.textPrimary)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(viewModel.qualityOptions) { option in
                        qualityButton(option)
                    }
                }
            }
        }
        .padding(15)
        .glassCard(cornerRadius: AppTheme.glassRadius)
    }
    
    @ViewBuilder
    private func qualityButton(_ option: PlaybackQualityOption) -> some View {
        Button {
            withAnimation {
                viewModel.selectQuality(option)
            }
            if viewModel.isPlaying {
                saveHistoryForCurrentEpisode()
            }
        } label: {
            Text(option.name)
                .font(.system(size: 14, weight: viewModel.selectedQualityId == option.id ? .bold : .medium))
                .foregroundColor(viewModel.selectedQualityId == option.id ? .orange : AppTheme.textSecondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    ZStack {
                        if viewModel.selectedQualityId == option.id {
                            AppTheme.accentGradient
                        } else {
                            AppTheme.divider
                        }
                    }
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - 剧集列表
    
    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选集播放")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(AppTheme.textPrimary)
                .padding(.horizontal, 20)
            
            EpisodeListView(
                episodes: viewModel.currentEpisodes,
                selectedIndex: viewModel.selectedEpisodeIndex,
                onSelect: { index in
                    withAnimation {
                        viewModel.selectEpisode(index: index)
                    }
                    saveHistoryForCurrentEpisode()
                }
            )
        }
    }
    
    // MARK: - 简介
    
    private func descriptionSection(_ des: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("影片简介")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(AppTheme.textPrimary)
            
            Text(des)
                .font(.system(size: 14))
                .foregroundColor(AppTheme.textSecondary)
                .lineSpacing(4)
                .lineLimit(nil)
        }
        .padding(15)
        .glassCard(cornerRadius: AppTheme.glassRadius)
    }

    private var canPlayNextEpisode: Bool {
        viewModel.selectedEpisodeIndex + 1 < viewModel.currentEpisodes.count
    }
    
    private func saveHistoryForCurrentEpisode(progressOverride: Double? = nil) {
        let episodeName = viewModel.vodInfo?.currentEpisode?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let episodeLabel = episodeName.isEmpty ? "第\(viewModel.selectedEpisodeIndex + 1)集" : episodeName
        let progress = max(progressOverride ?? viewModel.currentPlaybackSeconds(), 0)
        let timeLabel = progress > 0 ? Int(progress).durationString : ""
        let playNote = timeLabel.isEmpty ? episodeLabel : "\(episodeLabel) \(timeLabel)"
        
        let playbackState = VodPlaybackState(
            flag: viewModel.selectedFlag,
            episodeIndex: viewModel.selectedEpisodeIndex,
            progressSeconds: progress
        )
        
        Task { @MainActor in
            CacheStore.shared.addRecord(
                video,
                playNote: playNote,
                playbackState: playbackState,
                context: modelContext
            )
        }
    }
    
    private func handlePlaybackProgress(_ seconds: Double, _: Double?) {
        viewModel.updatePlaybackProgress(seconds: seconds)
        persistHistoryIfNeeded(force: false, currentProgress: seconds)
    }
    
    private func persistHistoryIfNeeded(force: Bool, currentProgress: Double? = nil) {
        guard viewModel.isPlaying else { return }
        let progress = max(currentProgress ?? viewModel.currentPlaybackSeconds(), 0)
        guard progress.isFinite else { return }
        
        if !force && abs(progress - lastPersistedProgress) < 20 {
            return
        }
        
        lastPersistedProgress = progress
        saveHistoryForCurrentEpisode(progressOverride: progress)
    }
    
    private func restorePlaybackFromHistory() {
        guard let playbackState = CacheStore.shared.getPlaybackState(
            vodId: video.id,
            sourceKey: video.sourceKey,
            context: modelContext
        ) else { return }
        
        viewModel.applyPlaybackState(playbackState)
        lastPersistedProgress = max(playbackState.progressSeconds, 0)
    }
    
    private func refreshCollectState() {
        isCollected = CacheStore.shared.isCollected(
            vodId: video.id,
            sourceKey: video.sourceKey,
            context: modelContext
        )
    }
    
    private func toggleCollect() {
        if isCollected {
            CacheStore.shared.removeCollect(
                vodId: video.id,
                sourceKey: video.sourceKey,
                context: modelContext
            )
        } else {
            CacheStore.shared.addCollect(video, context: modelContext)
        }
        refreshCollectState()
    }
    
    /// 播放失败自动嗅探/解析：原地址 → 嗅探候选 → 解析器。
    /// 命中新地址后直接切换播放；未命中则交给原失败流程（若有）。
    private func handlePlaybackFailed() {
        guard !isSniffing else { return }
        isSniffing = true
        Task { @MainActor in
            defer { isSniffing = false }
            guard let current = viewModel.playUrl else { return }
            // 该地址已嗅探/解析过，避免死循环。
            if sniffedUrls.contains(current) { return }
            
            // 1) 嗅探候选。
            let candidates = await SniffService.shared.sniff(from: current)
            if let sniffed = candidates.first(where: { !sniffedUrls.contains($0) }),
               sniffed != current {
                sniffedUrls.insert(sniffed)
                viewModel.playSniffed(url: sniffed)
                return
            }
            
            // 2) 尝试解析器（仅 JSON 型解析接口）。
            if let parsed = await SniffService.shared.parseViaParser(
                originalURL: current,
                parseBeans: ApiConfig.shared.parseBeanList
            ), parsed != current {
                sniffedUrls.insert(parsed)
                viewModel.playSniffed(url: parsed)
            }
        }
    }
    
    private func playNextEpisodeIfNeeded() {
        var moved = false
        withAnimation {
            moved = viewModel.playNext()
        }
        
        if moved {
            saveHistoryForCurrentEpisode()
        }
    }
    
    private func openFullScreenPlayer() {
        #if os(iOS)
        showFullScreen = true
        #else
        guard viewModel.playUrl != nil else { return }
        appState.enterPlayerFullScreen()
        
        if let window = NSApp.keyWindow ?? NSApp.mainWindow,
           window.styleMask.contains(.fullScreen) {
            showFullScreen = true
            return
        }
        
        pendingMacWindowFullScreen = requestMacWindowFullScreen(enter: true)
        if !pendingMacWindowFullScreen {
            showFullScreen = true
        }
        #endif
    }
    
    #if os(macOS)
    @discardableResult
    private func requestMacWindowFullScreen(enter: Bool) -> Bool {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return false }
        let isFullScreen = window.styleMask.contains(.fullScreen)
        guard enter != isFullScreen else { return false }
        window.toggleFullScreen(nil)
        return true
    }
    
    private func closeMacFullScreenOverlay() {
        pendingMacWindowFullScreen = false
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        if window?.styleMask.contains(.fullScreen) == true {
            requestMacWindowFullScreen(enter: false)
            return
        }
        showFullScreen = false
        appState.exitPlayerFullScreen()
    }
    #endif
}

/// 全屏播放器
struct FullScreenPlayerView: View {
    let urlString: String
    /// 播放内容标题（腾讯风格顶部标题栏显示）。
    var title: String = ""
    var startPosition: Double = 0
    var onProgressChanged: ((Double, Double?) -> Void)? = nil
    var onPlaybackEnded: (() -> Void)? = nil
    var canPlayNext: Bool = false
    var onPlayNext: (() -> Void)? = nil
    var systemController: SystemPlayerSessionController? = nil
    var vlcController: VLCPlayerController? = nil
    var onCloseRequested: (() -> Void)? = nil
    /// 播放源（线路）名称列表与当前选中下标。
    var sourceNames: [String] = []
    var selectedSourceIndex: Int = 0
    var onSelectSource: ((Int) -> Void)? = nil
    /// 剧集名称列表与当前选中下标。
    var episodeNames: [String] = []
    var selectedEpisodeIndex: Int = 0
    var onSelectEpisode: ((Int) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    /// 切后台再返回时重新应用播放器朝向。
    @Environment(\.scenePhase) private var scenePhase
    /// 全屏系统播放器播放结束观察者（自动连播下一集）。
    @State private var playbackEndObserver: NSObjectProtocol?
    /// 左右横屏方向标记（用于旋转按钮切换 landscapeLeft/Right）。
    @State private var isLandscapeLeft = false
    #if os(iOS)
    /// 全屏播放器控制器（用于手动触发画中画，与切后台自动 PiP 同源）。
    @State private var fullPlayerVC: AVPlayerViewController?
    #endif
    /// 听视频模式状态：开启时关闭播放器 allowsPiP，切后台保持纯音频不弹 PiP 小窗。
    @State private var listenMode = false
    @AppStorage(HawkConfig.PLAY_TYPE_VOD) private var vodPlayTypeRaw = -1
    @AppStorage(HawkConfig.PLAY_TYPE) private var legacyPlayTypeRaw = PlayerEngine.system.rawValue
    
    private var selectedEngine: PlayerEngine {
        let defaults = UserDefaults.standard
        let rawValue: Int
        if defaults.object(forKey: HawkConfig.PLAY_TYPE_VOD) != nil {
            rawValue = vodPlayTypeRaw
        } else if defaults.object(forKey: HawkConfig.PLAY_TYPE) != nil {
            rawValue = legacyPlayTypeRaw
        } else {
            rawValue = PlayerEngine.system.rawValue
        }
        return PlayerEngine.fromStoredValue(rawValue)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            #if os(iOS)
            if selectedEngine == .system {
                // 系统引擎：AVPlayerViewController 渲染画面（关闭系统控制条），
                // 腾讯风格控制条覆盖在播放器内核之上（一体集成）。
                // 控制条无条件渲染：即使播放器实例失效，控制栏仍可唤出操作。
                if let player = systemController?.player {
                    AVPlayerViewControllerRepresentable(
                        player: player,
                        onViewAppeared: {
                            // 播放控制器真正呈现后按视频方向设置朝向（比 SwiftUI onAppear 更可靠）。
                            applyPlayerOrientation(player: player)
                        },
                        onViewControllerReady: { controller in
                            fullPlayerVC = controller
                        },
                        // 听视频模式下关闭自动 PiP：切后台保持纯音频不弹小窗。
                        allowsPiP: !listenMode,
                        // 听视频模式解绑 VC 画面：独立 AVPlayer 后台播放，锁屏不暂停。
                        attachPlayer: !listenMode
                    )
                    .ignoresSafeArea()
                }

                TencentStylePlayerOverlay(
                    player: systemController?.player,
                    title: title,
                    isPlaying: isFullScreenPlaying,
                    onPlayPause: { togglePlayPauseInFullScreen() },
                    onRotate: { rotateFullScreen() },
                    onClose: { closeFullScreen() },
                    onLongPressBegan: { beginLongPressSpeed(player: systemController?.player) },
                    onLongPressEnded: { endLongPressSpeed(player: systemController?.player) },
                    sourceNames: sourceNames,
                    selectedSourceIndex: selectedSourceIndex,
                    onSelectSource: { index in
                        guard index >= 0, index < sourceNames.count else { return }
                        onSelectSource?(index)
                    },
                    episodeNames: episodeNames,
                    selectedEpisodeIndex: selectedEpisodeIndex,
                    onSelectEpisode: { index in
                        onSelectEpisode?(index)
                    },
                    onRequestPip: {
                        #if os(iOS)
                        // 用播放器自带 PiP 控制器手动触发（与切后台自动 PiP 同源，避免外部控制器冲突）。
                        // selector 动态调用：编译期不依赖旧 SDK 的成员声明。
                        if let c = fullPlayerVC?.pipControllerIfAvailable {
                            if c.isPictureInPicturePossible {
                                c.startPictureInPicture()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                    if c.isPictureInPictureActive {
                                        closeFullScreen()
                                    }
                                }
                            }
                        }
                        #endif
                    },
                    onListenModeChanged: { on in
                        listenMode = on
                    }
                )
                // 不忽略安全区：标题栏与底部控制栏自动避开灵动岛/Home 指示条。
                .onChange(of: urlString) { _, newURL in
                    // 切线路/切集后按新地址换流，不重建播放器。
                    reloadSystemPlayer(with: newURL)
                }
            } else {
                // VLC 引擎：保留页面播放器实例 + 自绘控制。
                ZStack {
                    inlinePlayer
                    vlcOverlayControls
                }
            }
            #else
            inlinePlayer
            #endif
        }
        .ignoresSafeArea()
        #if os(iOS)
        .statusBarHidden(true)
        // 全屏朝向跟随视频方向：横版强制横屏、竖版保持竖屏（Info.plist 已声明全部方向）。
        // 自动旋转开启时转动设备画面实时跟随；锁定方向时同样强制目标朝向。
        .onAppear {
            showControls()
            bindPlaybackEndObserver()
            // 转场期间多次尝试，确保方向落地。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                applyPlayerOrientation(player: systemController?.player)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                applyPlayerOrientation(player: systemController?.player)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                applyPlayerOrientation(player: systemController?.player)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // 切后台再返回会恢复竖屏：回到前台时按视频方向重新应用朝向。
            if phase == .active {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    applyPlayerOrientation(player: systemController?.player)
                }
            }
        }
        .onDisappear {
            if let observer = playbackEndObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            DeviceOrientation.forcePortrait()
            hideControlsTask?.cancel()
            endLongPressSpeed(player: systemController?.player)
        }
        #endif
    }

    /// 监听系统播放器播放结束（播放完成自动播放下一集）。
    private func bindPlaybackEndObserver() {
        if let old = playbackEndObserver {
            NotificationCenter.default.removeObserver(old)
            playbackEndObserver = nil
        }
        guard selectedEngine == .system,
              let player = systemController?.player,
              let item = player.currentItem else { return }
        playbackEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            // FullScreenPlayerView 为 struct（值类型），闭包按值捕获，无循环引用风险。
            onPlaybackEnded?()
        }
    }

    // MARK: - VLC 引擎全屏自绘控制（系统引擎已在播放器内核内集成）

    @ViewBuilder
    private var vlcOverlayControls: some View {
        ZStack {
            #if os(iOS)
            if !controlsVisible {
                FullScreenGestureLayer(
                    onBrightness: { translation in
                        if brightnessGestureStart == nil {
                            brightnessGestureStart = UIScreen.main.brightness
                        }
                        let delta = -translation.height / 800.0
                        let target = min(max((brightnessGestureStart ?? 0.5) + delta, 0), 1)
                        UIScreen.main.brightness = target
                        showOSD("亮度 \(Int(target * 100))%")
                    },
                    onVolume: { translation in
                        if volumeGestureStart == nil {
                            volumeGestureStart = SystemVolumeController.shared.currentVolume()
                        }
                        let delta = -translation.height / 800.0
                        let target = min(max((volumeGestureStart ?? 0.5) + Float(delta), 0), 1)
                        SystemVolumeController.shared.setVolume(target)
                        showOSD("音量 \(Int(target * 100))%")
                    },
                    onSeek: { offset in
                        seekInFullScreen(by: offset)
                    },
                    onTap: { showControls() },
                    onLongPressBegan: {
                        beginLongPressSpeed(player: systemController?.player)
                    },
                    onLongPressEnded: {
                        endLongPressSpeed(player: systemController?.player)
                    },
                    onDragEnded: {
                        clearGestureState()
                    }
                )
            }

            if let osdText {
                Text(osdText)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(AppTheme.textPrimary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .opacity(osdOpacity)
                    .allowsHitTesting(false)
            }
            #endif

            // VLC 引擎控制栏（底部）
            VStack {
                Spacer()
                HStack(spacing: 16) {
                    #if os(iOS)
                    Button {
                        showControls()
                        togglePlayPauseInFullScreen()
                    } label: {
                        Image(systemName: isFullScreenPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .foregroundColor(AppTheme.textSecondary)
                    }
                    Button {
                        showControls()
                        rotateFullScreen()
                    } label: {
                        Image(systemName: "rectangle.landscape.rotate")
                            .font(.title3)
                            .foregroundColor(AppTheme.textSecondary)
                    }
                    #endif
                    Button {
                        closeFullScreen()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(AppTheme.textSecondary)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.45), in: Capsule())
                .opacity(controlsVisible ? 1 : 0)
                .animation(.easeInOut(duration: 0.25), value: controlsVisible)
                .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, 16)
            .allowsHitTesting(controlsVisible)
        }
    }

    private func rotateFullScreen() {
        isLandscapeLeft.toggle()
        if isLandscapeLeft {
            DeviceOrientation.forceLandscapeLeft()
        } else {
            DeviceOrientation.forceLandscapeRight()
        }
    }

    private func closeFullScreen() {
        if let onCloseRequested {
            onCloseRequested()
        } else {
            dismiss()
        }
    }

    /// 切线路/切集后按新地址换流（复用同一 AVPlayer，避免重新创建播放器）。
    private func reloadSystemPlayer(with urlString: String) {
        guard selectedEngine == .system,
              let controller = systemController,
              let player = controller.player,
              !urlString.isEmpty,
              controller.mediaURLString != urlString else { return }
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed)
                ?? URL(string: trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") else { return }
        controller.mediaURLString = url.absoluteString
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 0
        let savedRate = player.defaultRate
        player.replaceCurrentItem(with: item)
        player.playImmediately(atRate: savedRate)
        bindPlaybackEndObserver()
    }
    // MARK: - 悬浮按钮显隐

    @State private var controlsVisible = true
    @State private var hideControlsTask: Task<Void, Never>?
    @State private var osdText: String?
    @State private var osdOpacity: Double = 0
    @State private var osdTimer: Timer?
    /// 亮度/音量手势起点快照（滑动期间基准值，避免闭环抖动）。
    @State private var brightnessGestureStart: CGFloat?
    @State private var volumeGestureStart: Float?
    /// 水平 seek 手势起点时间快照。
    @State private var seekStartTime: Double?
    /// 长按倍速递增任务与当前倍速。
    @State private var longPressSpeedTask: Task<Void, Never>?
    @State private var longPressSpeed: Float = 2.0
    /// 播放状态（悬浮按钮图标）。
    @State private var isFullScreenPlaying = true

    // MARK: - 全屏播放控制

    private func togglePlayPauseInFullScreen() {
        guard let player = systemController?.player else { return }
        if player.rate == 0 {
            player.playImmediately(atRate: player.defaultRate)
            isFullScreenPlaying = true
            showOSD("播放")
        } else {
            player.pause()
            isFullScreenPlaying = false
            showOSD("暂停")
        }
    }
    
    /// 手势结束清理：仅清空滑动快照。倍速恢复由手势层在长按激活时自行调用，
    /// 不再在这里触发 endLongPressSpeed，防止双击暂停后松手又被恢复播放。
    private func clearGestureState() {
        brightnessGestureStart = nil
        volumeGestureStart = nil
        seekStartTime = nil
    }

    private func seekInFullScreen(by offset: Double) {
        guard let player = systemController?.player else { return }
        if seekStartTime == nil {
            seekStartTime = player.currentTime().seconds
        }
        let wasPlaying = player.rate != 0
        var target = (seekStartTime ?? 0) + offset
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 {
            target = min(max(target, 0), d)
        }
        player.seek(to: CMTime(seconds: max(target, 0), preferredTimescale: 600)) { _ in
            if wasPlaying {
                player.playImmediately(atRate: player.defaultRate)
            }
        }
        showOSD(formatFullScreenTime(target))
        isFullScreenPlaying = player.timeControlStatus == .playing
    }

    /// 长按画面倍速：固定 2.0x，松手恢复原速。
    private func beginLongPressSpeed(player: AVPlayer?) {
        guard let player else { return }
        longPressSpeedTask?.cancel()
        longPressSpeedTask = nil
        longPressSpeed = 2.0
        player.rate = 2.0
        showOSD("倍速 2.0x")
    }

    private func endLongPressSpeed(player: AVPlayer?) {
        longPressSpeedTask?.cancel()
        longPressSpeedTask = nil
        guard let player else { return }
        if player.rate != player.defaultRate {
            player.rate = player.defaultRate
        }
        isFullScreenPlaying = player.timeControlStatus == .playing
    }

    private func formatFullScreenTime(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    private func showControls() {
        withAnimation(.easeOut(duration: 0.2)) {
            controlsVisible = true
        }
        hideControlsTask?.cancel()
        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.4)) {
                controlsVisible = false
            }
        }
        hideControlsTask = task
    }

    private func showOSD(_ text: String) {
        osdText = text
        withAnimation(.easeInOut(duration: 0.15)) {
            osdOpacity = 1
        }
        osdTimer?.invalidate()
        osdTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
            withAnimation(.easeOut(duration: 0.4)) {
                osdOpacity = 0
            }
        }
    }

    private var inlinePlayer: some View {
        VStack(spacing: 0) {
            PlayerView(
                urlString: urlString,
                startPosition: startPosition,
                onProgressChanged: onProgressChanged,
                onPlaybackEnded: onPlaybackEnded,
                onToggleFullScreen: {
                    if let onCloseRequested {
                        onCloseRequested()
                    } else {
                        dismiss()
                    }
                },
                canPlayNext: canPlayNext,
                onPlayNext: onPlayNext,
                systemController: systemController,
                vlcController: vlcController
            )
            .ignoresSafeArea()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
