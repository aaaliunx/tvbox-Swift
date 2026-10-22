import SwiftUI
import SwiftData
import AVFoundation
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
                    startPosition: viewModel.currentPlaybackSeconds(),
                    onProgressChanged: handlePlaybackProgress,
                    onPlaybackEnded: playNextEpisodeIfNeeded,
                    canPlayNext: canPlayNextEpisode,
                    onPlayNext: playNextEpisodeIfNeeded,
                    systemController: sharedSystemController,
                    vlcController: sharedVLCController,
                    onCloseRequested: closeMacFullScreenOverlay
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
                Color.white.opacity(0.05)
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
                Color.white.opacity(0.05)
                Image(systemName: "film.fill").foregroundColor(.white.opacity(0.2))
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
                .foregroundColor(.white)
            
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
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                Group {
                    if isCollected {
                        AppTheme.accentGradient
                    } else {
                        Color.white.opacity(0.08)
                    }
                }
            )
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(isCollected ? 0 : 0.2), lineWidth: 1)
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
                    .foregroundColor(.white.opacity(0.8))
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
                .foregroundColor(.white)
            
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
                .foregroundColor(viewModel.selectedFlag == flag ? .white : .white.opacity(0.6))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    ZStack {
                        if viewModel.selectedFlag == flag {
                            AppTheme.accentGradient
                        } else {
                            Color.white.opacity(0.05)
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
                .foregroundColor(.white)
            
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
                .foregroundColor(viewModel.selectedQualityId == option.id ? .white : .white.opacity(0.6))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    ZStack {
                        if viewModel.selectedQualityId == option.id {
                            AppTheme.accentGradient
                        } else {
                            Color.white.opacity(0.05)
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
                .foregroundColor(.white)
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
                .foregroundColor(.white)
            
            Text(des)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.6))
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
    var startPosition: Double = 0
    var onProgressChanged: ((Double, Double?) -> Void)? = nil
    var onPlaybackEnded: (() -> Void)? = nil
    var canPlayNext: Bool = false
    var onPlayNext: (() -> Void)? = nil
    var systemController: SystemPlayerSessionController? = nil
    var vlcController: VLCPlayerController? = nil
    var onCloseRequested: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    /// 左右横屏方向标记（用于旋转按钮切换 landscapeLeft/Right）。
    @State private var isLandscapeLeft = false
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

            fullScreenPlayerBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            #if os(iOS)
            // 悬浮按钮隐藏时的手势层：水平快进/后退、左亮度右音量、单击唤出、长按倍速。
            if !controlsVisible {
                FullScreenGestureLayer(
                    onBrightness: { translation in
                        // 手势开始时快照基准值，滑动期间用基准+累计偏移，
                        // 避免"读取-设置"闭环导致抖动。
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
                        brightnessGestureStart = nil
                        volumeGestureStart = nil
                        seekStartTime = nil
                        // 兜底：任何拖动手势结束都确保倍速恢复（防止长按任务残留）。
                        endLongPressSpeed(player: systemController?.player)
                    }
                )
            }

            // 亮度/音量/倍速调节提示
            if let osdText {
                Text(osdText)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .opacity(osdOpacity)
                    .allowsHitTesting(false)
            }
            #endif

            // 悬浮按钮（自动隐藏，单击唤出）：播放/暂停 + 左右翻转 + 退出全屏
            VStack {
                HStack(spacing: 16) {
                    #if os(iOS)
                    // 播放/暂停（系统引擎）
                    Button {
                        showControls()
                        togglePlayPauseInFullScreen()
                    } label: {
                        Image(systemName: isFullScreenPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .foregroundColor(.white.opacity(0.8))
                    }
                    // 左右翻转横屏（系统方向请求 + 设备方向兜底）
                    Button {
                        showControls()
                        isLandscapeLeft.toggle()
                        if isLandscapeLeft {
                            DeviceOrientation.forceLandscapeLeft()
                        } else {
                            DeviceOrientation.forceLandscapeRight()
                        }
                    } label: {
                        Image(systemName: "rectangle.landscape.rotate")
                            .font(.title3)
                            .foregroundColor(.white.opacity(0.8))
                    }
                    #endif
                    // 退出全屏
                    Button {
                        if let onCloseRequested {
                            onCloseRequested()
                        } else {
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
                .padding()
                .background(Color.black.opacity(0.35), in: Capsule())
                .opacity(controlsVisible ? 1 : 0)
                .animation(.easeInOut(duration: 0.25), value: controlsVisible)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, 4)
            .allowsHitTesting(controlsVisible)
        }
        .ignoresSafeArea()
        #if os(iOS)
        .statusBarHidden(true)
        // 全屏即横屏：系统几何更新 + 设备方向双保险（Info.plist 已声明横屏）。
        // 自动旋转开启时转动设备画面实时跟随；锁定方向时同样强制横屏。
        .onAppear {
            showControls()
            // 转场期间多次尝试，确保方向落地。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                DeviceOrientation.forceLandscape()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                DeviceOrientation.forceLandscape()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                DeviceOrientation.forceLandscape()
            }
        }
        .onDisappear {
            DeviceOrientation.forcePortrait()
            hideControlsTask?.cancel()
            endLongPressSpeed(player: systemController?.player)
        }
        #endif
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

    /// 长按倍速：2x 起步，按住每 0.9s 提升一档，最高 3x。
    private func beginLongPressSpeed(player: AVPlayer?) {
        guard let player else { return }
        longPressSpeed = 2.0
        player.rate = 2.0
        showOSD("倍速 2.0x")
        longPressSpeedTask?.cancel()
        let task = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 900_000_000)
                guard !Task.isCancelled else { return }
                longPressSpeed = min(longPressSpeed + 1.0, 3.0)
                player.rate = longPressSpeed
                showOSD("倍速 \(String(format: "%.0f", longPressSpeed))x")
            }
        }
        longPressSpeedTask = task
    }

    private func endLongPressSpeed(player: AVPlayer?) {
        longPressSpeedTask?.cancel()
        longPressSpeedTask = nil
        guard let player else { return }
        player.rate = player.defaultRate
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

    /// 全屏播放器主体：iOS 系统引擎用官方 AVPlayerViewController，
    /// VLC 引擎与 macOS 使用页面播放器实例（复用不重新加载）。
    @ViewBuilder
    private var fullScreenPlayerBody: some View {
        #if os(iOS)
        if selectedEngine == .system {
            if let player = systemController?.player {
                AVPlayerViewControllerRepresentable(
                    player: player,
                    onViewAppeared: {
                        // 播放控制器真正呈现后强制横屏（比 SwiftUI onAppear 更可靠）。
                        DeviceOrientation.forceLandscape()
                    }
                )
                .ignoresSafeArea()
            } else {
                Color.black
            }
        } else {
            inlinePlayer
        }
        #else
        inlinePlayer
        #endif
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
