import SwiftUI
import AVKit
#if os(macOS)
import AppKit
#endif

/// 直播页 - 对应 Android 版 LivePlayActivity
struct LiveView: View {
    /// 退出直播回调（iOS 用于返回首页并显示 TabBar）。
    var onExit: (() -> Void)? = nil
    /// 直播频道与选中状态管理。
    @StateObject private var viewModel = LiveViewModel()
    /// 全局应用状态（用于 macOS 全屏时调整分栏布局）。
    @EnvironmentObject var appState: AppState
    /// 系统播放器实例（仅在选择系统内核时使用）。
    @State private var avPlayer: AVPlayer?
    /// 直播播放器内核配置（新字段）。
    @AppStorage(HawkConfig.PLAY_TYPE_LIVE) private var livePlayTypeRaw = -1
    /// 兼容旧版本单播放器字段。
    @AppStorage(HawkConfig.PLAY_TYPE) private var legacyPlayTypeRaw = PlayerEngine.system.rawValue
    /// 是否展示左侧频道抽屉。
    @State private var showChannelDrawer = true
    #if os(iOS)
    /// iOS 全屏频道覆盖层是否显示。
    @State private var showChannelOverlay = false
    /// iOS 直播全屏横屏播放是否显示。
    @State private var showLiveFullScreen = false
    #endif
    /// 当前窗口是否处于全屏。
    @State private var isWindowFullScreen = false
    /// 底部频道信息卡最大宽度。
    private let currentChannelInfoMaxWidth: CGFloat = 600
    /// AVPlayer 状态观察者。
    @State private var itemStatusObserver: NSKeyValueObservation?
    /// 播放失败通知观察者。
    @State private var playbackFailedObserver: NSObjectProtocol?
    /// 播放卡顿通知观察者。
    @State private var playbackStalledObserver: NSObjectProtocol?
    /// 当前频道已失败的线路索引，用于自动切线去重。
    @State private var failedSourceIndices: Set<Int> = []
    /// 当前跟踪的频道 ID（频道切换时重置失败状态）。
    @State private var trackedChannelId: String = ""
    /// 底部频道信息是否显示。
    @State private var showCurrentChannelInfo = true
    /// 顶部返回/频道按钮是否显示（与频道信息卡联动自动隐藏）。
    @State private var showLiveTopBar = true
    /// 直播线路全部失败时的错误提示（非空时显示，含返回按钮，不自动隐藏）。
    @State private var playbackFailureText: String?
    /// 直播共享播放器：普通页与全屏页共用同一实例，避免同时播放产生双声音。
    @StateObject private var livePlayerController = VLCPlayerController()
    /// 自动隐藏频道信息的定时器。
    @State private var channelInfoTimer: Timer?
    /// 频道信息自动隐藏延迟（秒）。
    private let channelInfoAutoHideDelay: TimeInterval = 6.0
    /// 用户交互令牌，递增后可通知 VLC 子视图重置自动隐藏逻辑。
    @State private var vlcInteractionToken = 0
    
    /// 当前实际生效的播放器内核。
    /// 优先读取直播专用字段，再回退老字段，最后使用默认值。
    private var selectedEngine: PlayerEngine {
        let defaults = UserDefaults.standard
        let rawValue: Int
        if defaults.object(forKey: HawkConfig.PLAY_TYPE_LIVE) != nil {
            rawValue = livePlayTypeRaw
        } else if defaults.object(forKey: HawkConfig.PLAY_TYPE) != nil {
            rawValue = legacyPlayTypeRaw
        } else {
            rawValue = PlayerEngine.isVLCAvailable
                ? PlayerEngine.vlc.rawValue
                : PlayerEngine.system.rawValue
        }
        return PlayerEngine.fromStoredValue(rawValue)
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                
                if viewModel.channelGroups.isEmpty {
                    emptyState
                } else {
                    // 播放器
                    if selectedEngine == .vlc {
                        if let urlString = viewModel.currentChannel?.currentUrl, !urlString.isEmpty {
                            VLCLivePlayerView(
                                urlString: urlString,
                                sharedController: livePlayerController,
                                activityToken: vlcInteractionToken,
                                onPlaybackFailed: {
                                    handlePlaybackFailure(trigger: "vlc_error")
                                },
                                onToggleFullScreen: {
                                    toggleWindowFullScreen()
                                },
                                onUserActivity: {
                                    reportUserActivity()
                                }
                            )
                            .ignoresSafeArea()
                            .id("vlc-live-\(urlString)-\(viewModel.currentChannel?.id ?? "")")
                        }
                    } else if let player = avPlayer {
                        PlatformVideoPlayer(player: player)
                            .ignoresSafeArea()
                    }
                    
                    #if os(iOS)
                    // 手势层置于播放器之上、覆盖 UI 之下：
                    // 单击唤出顶部按钮+底部控制条（通过 vlcInteractionToken 通知播放器），
                    // 双击暂停/播放，右侧滑动调音量。覆盖 UI（返回/频道/控制条）在上层，
                    // 按钮可正常点击；空白区域点击穿透到手势层唤出控件。
                    LivePlayerGestureLayer(
                        onTogglePlayPause: {
                            reportUserActivity()
                            livePlayerController.togglePlayback()
                        },
                        onToggleControls: {
                            reportUserActivity()
                        },
                        onVolumeChanged: { delta in
                            let newVol = max(0, min(200, livePlayerController.volume + Int(delta * 200)))
                            livePlayerController.setVolume(newVol)
                        }
                    )
                    #endif
                    
                    // 覆盖 UI（置于手势层之上，按钮优先响应点击）
                    overlayUI
                }
            }
            .navigationTitle("直播")
            #if os(macOS)
            .toolbar(isWindowFullScreen ? .hidden : .visible, for: .windowToolbar)
            #endif
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
            #endif
            #if os(iOS)
            .fullScreenCover(isPresented: $showLiveFullScreen, onDismiss: {
                // 全屏内容自旋转，不依赖系统方向。
            }) {
                LiveFullScreenPlayerView(
                    urlString: viewModel.currentChannel?.currentUrl ?? "",
                    sharedController: livePlayerController,
                    systemPlayer: avPlayer,
                    useSystemEngine: selectedEngine == .system
                )
            }
            #endif
            .onAppear {
                // 首次进入时加载频道并展示频道信息卡。
                viewModel.loadChannels()
                wakeUpCurrentChannelInfo()
            }
            .onChange(of: viewModel.currentChannel?.currentUrl) { _, newValue in
                if selectedEngine == .system {
                    playChannel(url: newValue)
                } else {
                    cleanupPlayer()
                }
                wakeUpCurrentChannelInfo()
            }
            .onChange(of: viewModel.currentChannel?.id) { _, _ in
                // 切台后清空失败线路记录，避免复用上个频道的失败状态。
                resetFailureTracking(for: viewModel.currentChannel)
                playbackFailureText = nil
                wakeUpCurrentChannelInfo()
            }
            .onChange(of: selectedEngine) { _, _ in
                if selectedEngine == .system {
                    playChannel(url: viewModel.currentChannel?.currentUrl)
                } else {
                    cleanupPlayer()
                }
            }
            .onDisappear {
                cleanupPlayer()
                cancelChannelInfoAutoHide()
                playbackFailureText = nil
                #if os(macOS)
                appState.exitPlayerFullScreen()
                isWindowFullScreen = false
                #endif
            }
            #if os(macOS)
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
                isWindowFullScreen = true
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
                isWindowFullScreen = false
                appState.exitPlayerFullScreen()
            }
            .onExitCommand {
                if showChannelDrawer {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showChannelDrawer = false
                    }
                }
            }
            #endif
        }
    }
    
    // MARK: - 空状态
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "tv.slash")
                .font(.system(size: 48))
                .foregroundColor(.gray)
            Text("暂无直播源")
                .font(.headline)
                .foregroundColor(.gray)
            Text("请在设置中配置包含直播源的接口")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
    
    // MARK: - 覆盖 UI
    
    private var overlayUI: some View {
        ZStack(alignment: .leading) {
            #if os(macOS)
            if showChannelDrawer {
                Color.black.opacity(0.22)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showChannelDrawer = false
                        }
                    }
            }
            #endif
            
            VStack(spacing: 0) {
                HStack {
                    #if os(iOS)
                    liveBackButton
                    #endif
                    channelDrawerToggleButton
                    Spacer()
                }
                .padding(.top, 18)
                .padding(.horizontal, 16)
                .opacity(showLiveTopBar ? 1.0 : 0.0)
                .animation(.easeInOut(duration: 0.25), value: showLiveTopBar)
                // 隐藏时禁止点击，避免误触隐藏的返回/频道按钮。
                .allowsHitTesting(showLiveTopBar)
                
                Spacer()
                
                // 线路全部失败提示（含返回按钮，不自动隐藏）
                if let failureText = playbackFailureText {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(failureText)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                        Spacer()
                        #if os(iOS)
                        Button {
                            onExit?()
                        } label: {
                            Text("返回")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(Color.white.opacity(0.18))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        #endif
                    }
                    .padding(14)
                    .glassCard(cornerRadius: 12)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                
                // 底部当前频道信息
                if let channel = viewModel.currentChannel, showCurrentChannelInfo {
                    currentChannelInfo(channel)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            
            #if os(macOS)
            if showChannelDrawer {
                channelDrawer
                    .padding(.leading, 12)
                    .padding(.vertical, 20)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            #endif
        }
        .animation(.easeInOut(duration: 0.2), value: showCurrentChannelInfo)
        #if os(macOS)
        .animation(.easeInOut(duration: 0.2), value: showChannelDrawer)
        #endif
        .simultaneousGesture(
            TapGesture().onEnded {
                reportUserActivity()
            }
        )
        #if os(iOS)
        .fullScreenCover(isPresented: $showChannelOverlay) {
            ChannelOverlayView(
                channelGroups: viewModel.channelGroups,
                selectedGroupIndex: $viewModel.selectedGroupIndex,
                currentChannels: viewModel.currentChannels,
                currentChannel: viewModel.currentChannel,
                onSelectGroup: { viewModel.selectGroup($0) },
                onSelectChannel: { channel in
                    viewModel.selectChannel(channel)
                    HapticManager.shared.mediumImpact()
                    showChannelOverlay = false
                },
                onDismiss: { showChannelOverlay = false }
            )
            // fullScreenCover 自带转场，不叠加 transition/animation（iOS 17 下叠加会导致打开时渲染卡死）。
        }
        #endif
        #if os(macOS)
        .onContinuousHover { phase in
            switch phase {
            case .active(_):
                reportUserActivity()
            case .ended:
                break
            }
        }
        #endif
    }
    
    private var channelDrawer: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("频道菜单", systemImage: "list.bullet.rectangle.portrait")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                
                Spacer()
                
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showChannelDrawer = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.8))
                        .frame(width: 22, height: 22)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.08))
            
            HStack(spacing: 0) {
                channelGroupList
                    .frame(width: 150)
                
                Divider()
                    .overlay(Color.white.opacity(0.1))
                
                channelList
                    .frame(width: 240)
            }
        }
        .frame(width: 390)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassCard(cornerRadius: 14)
    }
    
    #if os(iOS)
    private var liveBackButton: some View {
        Button {
            HapticManager.shared.lightImpact()
            onExit?()
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white.opacity(0.9))
                .frame(width: 38, height: 38)
                .background(Color.black.opacity(0.35))
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }
    #endif
    
    private var channelDrawerToggleButton: some View {
        Button {
            #if os(iOS)
            HapticManager.shared.lightImpact()
            showChannelOverlay = true
            #else
            withAnimation(.easeInOut(duration: 0.2)) {
                showChannelDrawer.toggle()
            }
            #endif
        } label: {
            HStack(spacing: 8) {
                #if os(iOS)
                Image(systemName: "list.bullet")
                    .font(.system(size: 15, weight: .semibold))
                Text("频道")
                    .font(.system(size: 14, weight: .semibold))
                #else
                Image(systemName: showChannelDrawer ? "sidebar.left" : "sidebar.right")
                Text(showChannelDrawer ? "收起菜单" : "频道菜单")
                    .font(.system(size: 13, weight: .semibold))
                #endif
            }
            .foregroundColor(.white.opacity(0.9))
            #if os(iOS)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            #else
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            #endif
            .background(Color.black.opacity(0.35))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .keyboardShortcut("m", modifiers: [.command])
        #endif
    }
    
    private func currentChannelInfo(_ channel: LiveChannelItem) -> some View {
        #if os(iOS)
        // iOS: 紧凑的底部信息栏，适合单手操作
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                // 频道名称
                HStack(spacing: 8) {
                    Circle().fill(Color.orange).frame(width: 8, height: 8)
                    Text(channel.channelName)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
                
                Spacer()
                
                // 线路信息
                if channel.sourceNum > 1 {
                    Text("线路 \(channel.sourceIndex + 1)/\(channel.sourceNum)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            
            // EPG 当前/下一节目（仅当节目单加载到且有数据时展示）
            if let nowProgram = viewModel.epgList.first(where: { $0.isLive }) {
                HStack(spacing: 6) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                    Text("正在播出：\(nowProgram.title)")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(1)
                    Spacer()
                    if let next = viewModel.epgList.first(where: { !$0.isLive }) {
                        Text("\(next.startTime) \(next.title)")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                }
            }
            
            // 操作按钮行
            if channel.sourceNum > 1 {
                HStack(spacing: 12) {
                    Button {
                        HapticManager.shared.mediumImpact()
                        wakeUpCurrentChannelInfo()
                        resetFailureTracking(for: viewModel.currentChannel)
                        viewModel.switchSource()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "shuffle")
                                .font(.system(size: 13))
                            Text("切换线路")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(AppTheme.accentGradient)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 14)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        #else
        // macOS: 保持原有宽屏布局
        HStack(spacing: 15) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Circle().fill(Color.orange).frame(width: 8, height: 8)
                    Text(channel.channelName)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                }
                
                if channel.sourceNum > 1 {
                    Text("正在播放：线路 \(channel.sourceIndex + 1) / \(channel.sourceNum)")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            
            Spacer()
            
            HStack(spacing: 12) {
                if channel.sourceNum > 1 {
                    Button {
                        wakeUpCurrentChannelInfo()
                        resetFailureTracking(for: viewModel.currentChannel)
                        viewModel.switchSource()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "shuffle")
                            Text("切换线路")
                        }
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(AppTheme.accentGradient)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                
                Button {
                    wakeUpCurrentChannelInfo()
                    toggleWindowFullScreen()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                        Text("全屏")
                    }
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Color.white.opacity(0.15))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .glassCard(cornerRadius: AppTheme.glassRadius)
        .frame(maxWidth: currentChannelInfoMaxWidth)
        .frame(maxWidth: .infinity)
        .padding(20)
        #endif
    }
    
    private func wakeUpCurrentChannelInfo() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showCurrentChannelInfo = true
            showLiveTopBar = true
        }
        channelInfoTimer?.invalidate()
        guard viewModel.currentChannel != nil else { return }
        
        channelInfoTimer = Timer.scheduledTimer(withTimeInterval: channelInfoAutoHideDelay, repeats: false) { _ in
            withAnimation(.easeOut(duration: 0.3)) {
                showCurrentChannelInfo = false
                showLiveTopBar = false
            }
        }
    }
    
    private func cancelChannelInfoAutoHide() {
        channelInfoTimer?.invalidate()
        channelInfoTimer = nil
    }
    
    private func reportUserActivity() {
        // 任意交互都刷新显示时间，并触发 VLC 子层同步交互状态。
        wakeUpCurrentChannelInfo()
        vlcInteractionToken &+= 1
    }
    
    // MARK: - 频道分组
    
    private var channelGroupList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(viewModel.channelGroups.enumerated()), id: \.offset) { index, group in
                    Button {
                        withAnimation {
                            viewModel.selectGroup(index)
                        }
                    } label: {
                        Text(group.groupName)
                            .font(.system(size: 14, weight: viewModel.selectedGroupIndex == index ? .bold : .medium))
                            .foregroundColor(viewModel.selectedGroupIndex == index ? .orange : .white.opacity(0.8))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .background(
                                viewModel.selectedGroupIndex == index
                                    ? Color.white.opacity(0.1)
                                    : Color.clear
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
    
    // MARK: - 频道列表
    
    private var channelList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(viewModel.currentChannels.enumerated()), id: \.offset) { index, channel in
                    Button {
                        withAnimation {
                            viewModel.selectedChannelIndex = index
                            viewModel.selectChannel(channel)
                        }
                    } label: {
                        HStack {
                            Text(channel.channelName)
                                .font(.system(size: 14, weight: viewModel.currentChannel?.channelName == channel.channelName ? .bold : .medium))
                                .foregroundColor(viewModel.currentChannel?.channelName == channel.channelName ? .orange : .white.opacity(0.8))
                            Spacer()
                            if channel.sourceNum > 1 {
                                Text("\(channel.sourceNum)")
                                    .font(.system(size: 10))
                                    .foregroundColor(.white.opacity(0.3))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 0.5))
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(
                            viewModel.currentChannel?.channelName == channel.channelName
                                ? Color.orange.opacity(0.15)
                                : Color.clear
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
    
    // MARK: - 播放
    
    private func playChannel(url: String?) {
        guard let urlStr = url, let url = URL(string: urlStr) else {
            handlePlaybackFailure(trigger: "invalid_url")
            return
        }
        
        cleanupPlayer()
        
        // 使用 AVURLAsset 并设置自定义 HTTP 头，解决部分 CDN 拒绝无 User-Agent 请求的问题
        let headers: [String: String] = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        ]
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let playerItem = AVPlayerItem(asset: asset)
        // 直播场景优先实时性，避免过多缓冲导致内存上涨
        playerItem.preferredForwardBufferDuration = 3
        playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        observePlaybackFailure(for: playerItem)
        
        let newPlayer = AVPlayer(playerItem: playerItem)
        newPlayer.play()
        avPlayer = newPlayer
    }
    
    private func cleanupPlayer() {
        // 先移除观察者再释放播放器，避免悬空回调。
        if let observer = playbackFailedObserver {
            NotificationCenter.default.removeObserver(observer)
            playbackFailedObserver = nil
        }
        if let observer = playbackStalledObserver {
            NotificationCenter.default.removeObserver(observer)
            playbackStalledObserver = nil
        }
        itemStatusObserver = nil
        
        avPlayer?.pause()
        avPlayer?.replaceCurrentItem(with: nil)
        avPlayer = nil
    }
    
    private func observePlaybackFailure(for item: AVPlayerItem) {
        // KVO 监听 item 状态失败。
        itemStatusObserver = item.observe(\.status, options: [.new]) { observedItem, _ in
            if observedItem.status == .failed {
                DispatchQueue.main.async {
                    handlePlaybackFailure(trigger: "status_failed")
                }
            }
        }
        
        // 播放到结尾失败回调。
        playbackFailedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            handlePlaybackFailure(trigger: "item_failed")
        }
        
        // 播放卡顿回调。
        playbackStalledObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { _ in
            handlePlaybackFailure(trigger: "playback_stalled")
        }
    }
    
    private func resetFailureTracking(for channel: LiveChannelItem?) {
        failedSourceIndices = []
        trackedChannelId = channel?.id ?? ""
    }
    
    private func handlePlaybackFailure(trigger: String) {
        guard let channel = viewModel.currentChannel else { return }
        // 播放出错时强制唤出顶部返回/频道按钮，避免用户找不到出口。
        wakeUpCurrentChannelInfo()
        showLiveTopBar = true
        cancelChannelInfoAutoHide()
        
        guard channel.sourceNum > 1 else {
            // 单线路频道失败：直接给出错误提示。
            playbackFailureText = "直播源无法播放，请检查线路或稍后重试"
            return
        }
        
        if trackedChannelId != channel.id {
            resetFailureTracking(for: channel)
        }
        
        let failedIndex = channel.sourceIndex
        guard !failedSourceIndices.contains(failedIndex) else { return }
        failedSourceIndices.insert(failedIndex)
        
        guard switchToNextAvailableSource(totalSources: channel.sourceNum) else {
            print("直播线路全部尝试失败: channel=\(channel.channelName), trigger=\(trigger)")
            playbackFailureText = "全部线路均无法播放，请稍后重试或返回"
            return
        }
        // 自动切到新线路成功，清除旧错误提示。
        playbackFailureText = nil
    }
    
    private func switchToNextAvailableSource(totalSources: Int) -> Bool {
        guard failedSourceIndices.count < totalSources else { return false }
        
        // 最多轮询 `totalSources` 次，找到一条尚未失败的线路即返回。
        for _ in 0..<totalSources {
            viewModel.switchSource()
            guard let nextIndex = viewModel.currentChannel?.sourceIndex else { return false }
            if !failedSourceIndices.contains(nextIndex) {
                return true
            }
        }
        
        return false
    }
    
    #if os(macOS)
    private func toggleWindowFullScreen() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let enteringFullScreen = !window.styleMask.contains(.fullScreen)
        if enteringFullScreen {
            isWindowFullScreen = true
            appState.enterPlayerFullScreen()
        }
        window.toggleFullScreen(nil)
    }
    #else
    private func toggleWindowFullScreen() {
        // iOS：打开全屏横屏播放。
        showLiveFullScreen = true
    }
    #endif
}

#if os(iOS)
/// 直播全屏播放器（复用直播页共享播放器，避免双声音；支持系统/VLC 双引擎）。
struct LiveFullScreenPlayerView: View {
    let urlString: String
    /// 与直播页共用的 VLC 播放器实例。
    var sharedController: VLCPlayerController? = nil
    /// 系统播放器引擎时使用的 AVPlayer 实例（与直播页共用，不重新加载）。
    var systemPlayer: AVPlayer? = nil
    /// 当前直播引擎（系统播放器 or VLC）。
    var useSystemEngine: Bool = false
    @Environment(\.dismiss) private var dismiss
    /// 全屏内容旋转角度：90=横屏左，-90=横屏右（与系统方向锁定无关）。
    @State private var landscapeRotation: Double = 90

    var body: some View {
        GeometryReader { geo in
            let screenW = geo.size.width
            let screenH = geo.size.height
            ZStack {
                Color.black

                VStack(spacing: 0) {
                    if useSystemEngine {
                        if let systemPlayer {
                            PlatformVideoPlayer(player: systemPlayer)
                                .ignoresSafeArea()
                        }
                    } else if !urlString.isEmpty {
                        VLCLivePlayerView(
                            urlString: urlString,
                            sharedController: sharedController,
                            onToggleFullScreen: { dismiss() },
                            controlsBottomInset: 20,
                            autoStart: false
                        )
                        .ignoresSafeArea()
                    }
                }
                .rotationEffect(.degrees(landscapeRotation))
                .frame(
                    width: landscapeRotation != 0 ? screenH : screenW,
                    height: landscapeRotation != 0 ? screenW : screenH
                )
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 16) {
                        // 左右翻转横屏
                        Button {
                            landscapeRotation = (landscapeRotation == 90 ? -90 : 90)
                        } label: {
                            Image(systemName: "rectangle.landscape.rotate")
                                .font(.title3)
                                .foregroundColor(.white.opacity(0.8))
                        }
                        // 退出全屏
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }
                    .padding()
                }
            }
        }
        .ignoresSafeArea()
        .statusBarHidden(true)
    }
}
#endif
