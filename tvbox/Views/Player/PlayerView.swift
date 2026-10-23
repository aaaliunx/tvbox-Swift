import SwiftUI
import AVKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 跨平台播放器：macOS 使用 AVPlayerView，避免 SwiftUI.VideoPlayer 在 macOS 的崩溃问题
struct PlatformVideoPlayer: View {
    let player: AVPlayer
    
    var body: some View {
        #if os(macOS)
        MacOSPlayerView(player: player)
        #else
        VideoPlayer(player: player)
            // VideoPlayer 默认保持视频固有比例尺寸，不铺满时旋转/全屏会只占部分画面。
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }
}

#if os(iOS)
import AVKit

/// 官方 AVPlayerViewController 画面容器（全屏播放内核）：
/// 关闭系统控制条，画面由 AVPlayerViewController 渲染，
/// 腾讯风格控制条以覆盖层形式叠放在内核之上（iOS 无 customOverlay API，
/// 采用内核容器 + 一体覆盖控制条实现"控制条集成进播放器"）。
struct AVPlayerViewControllerRepresentable: UIViewControllerRepresentable {
    let player: AVPlayer?
    /// 播放控制器视图已加入窗口、转场基本完成后回调（用于方向强制落地）。
    var onViewAppeared: (() -> Void)? = nil

    final class Coordinator {
        var onViewAppeared: (() -> Void)?
        init(onViewAppeared: (() -> Void)?) {
            self.onViewAppeared = onViewAppeared
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onViewAppeared: onViewAppeared)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.showsPlaybackControls = false
        vc.allowsPictureInPicturePlayback = false
        // 转场动画（约 0.4s）完成后通知 SwiftUI 侧做方向兜底，
        // 比 SwiftUI onAppear 更可靠（此时控制器已真实呈现在窗口上）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            context.coordinator.onViewAppeared?()
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if uiViewController.player !== player {
            uiViewController.player = player
        }
        uiViewController.showsPlaybackControls = false
        context.coordinator.onViewAppeared = onViewAppeared
    }
}

import MediaPlayer

/// 全屏页手势层：水平滑动快进/快退、左侧垂直滑动调亮度、右侧垂直滑动调音量、
/// 单击唤出悬浮按钮、长按画面 2 倍速（松手恢复）。
/// 采用单个自管理 DragGesture：位移 >12pt 立即进入拖动模式（绝不再触发长按倍速），
/// 按压后启动 Timer，静止 0.7s 触发倍速（手指轻微抖动不影响），短按松手视为点击。
/// 仅在悬浮按钮隐藏时叠加，避免遮挡播放器控制条。
struct FullScreenGestureLayer: View {
    let onBrightness: (CGSize) -> Void
    let onVolume: (CGSize) -> Void
    /// 水平滑动快进/快退偏移（秒），直播无 seek 时传 nil。
    var onSeek: ((Double) -> Void)? = nil
    let onTap: () -> Void
    /// 双击回调（播放/暂停），nil 时不启用双击。
    var onDoubleTap: (() -> Void)? = nil
    let onLongPressBegan: () -> Void
    let onLongPressEnded: () -> Void
    let onDragEnded: () -> Void

    @State private var pressStartTime: Date?
    @State private var dragStartX: CGFloat = 0
    @State private var isSpeedActive = false
    @State private var longPressTimer: Timer?
    /// 单击延迟判定（区分双击）：第一次短按等 0.25s，期间再来一次即双击。
    @State private var isPendingTap = false
    @State private var pendingTapTimer: Timer?

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if pressStartTime == nil {
                                pressStartTime = Date()
                                dragStartX = value.startLocation.x
                                startLongPressTimer()
                            }
                            let absW = abs(value.translation.width)
                            let absH = abs(value.translation.height)
                            let moved = max(absW, absH)

                            if isSpeedActive {
                                // 倍速已激活：保持，松手在 onEnded 恢复。
                                return
                            }

                            if moved > 12 {
                                // 进入拖动模式：取消长按，之后不再触发倍速。
                                cancelLongPressTimer()
                                // 水平需显著主导（≥1.5倍）才走快进，上下滑动略微带斜不再误触发。
                                if absW > absH * 1.5 {
                                    if let onSeek {
                                        let offset = Double(value.translation.width / geometry.size.width) * 180.0
                                        onSeek(offset)
                                    }
                                } else if absH > absW * 1.5 {
                                    if dragStartX < geometry.size.width * 0.5 {
                                        onBrightness(value.translation)
                                    } else {
                                        onVolume(value.translation)
                                    }
                                }
                            }
                            // 静止或微动（<12pt）：等待 Timer 判定长按。
                        }
                        .onEnded { value in
                            cancelLongPressTimer()
                            if isSpeedActive {
                                isSpeedActive = false
                                onLongPressEnded()
                            } else if let start = pressStartTime {
                                let elapsed = Date().timeIntervalSince(start)
                                let moved = max(abs(value.translation.width), abs(value.translation.height))
                                if elapsed < 0.6 && moved < 12 {
                                    // 短按：延迟 0.25s 判定双击/单击（腾讯逻辑：双击暂停，单击唤出）。
                                    if isPendingTap {
                                        isPendingTap = false
                                        pendingTapTimer?.invalidate()
                                        pendingTapTimer = nil
                                        if let onDoubleTap {
                                            onDoubleTap()
                                        } else {
                                            onTap()
                                        }
                                    } else {
                                        isPendingTap = true
                                        pendingTapTimer?.invalidate()
                                        pendingTapTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { _ in
                                            Task { @MainActor in
                                                isPendingTap = false
                                                pendingTapTimer = nil
                                                onTap()
                                            }
                                        }
                                    }
                                }
                            }
                            pressStartTime = nil
                            onDragEnded()
                        }
                )
        }
    }

    /// 按压后启动 0.7s 长按判定：期间未进入拖动模式即触发倍速。
    /// 用 Timer 而不是等待 onChanged，解决手指静止时不再回调导致倍速不触发的问题。
    private func startLongPressTimer() {
        longPressTimer?.invalidate()
        longPressTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { _ in
            Task { @MainActor in
                if !isSpeedActive {
                    isSpeedActive = true
                    onLongPressBegan()
                }
            }
        }
    }

    private func cancelLongPressTimer() {
        longPressTimer?.invalidate()
        longPressTimer = nil
    }
}

/// 系统音量控制器：MPVolumeView 必须挂载到窗口后才同步系统音量，
/// 离屏创建的 slider 设置 value 无效。全局单例 + 挂载一次。
final class SystemVolumeController {
    static let shared = SystemVolumeController()

    private let volumeView = MPVolumeView()
    private var slider: UISlider? {
        volumeView.subviews.compactMap { $0 as? UISlider }.first
    }
    /// 节流：避免拖动期间高频设置触发系统音量 HUD 频闪与卡顿。
    private var lastSetTime: TimeInterval = 0

    private func attachIfNeeded() {
        guard volumeView.superview == nil,
              let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first?.windows.first else { return }
        volumeView.frame = CGRect(x: -100, y: -100, width: 0, height: 0)
        volumeView.alpha = 0.01
        window.addSubview(volumeView)
    }

    func currentVolume() -> Float {
        slider?.value ?? 0.5
    }

    func setVolume(_ value: Float) {
        let now = Date().timeIntervalSince1970
        guard now - lastSetTime > 0.05 else { return }
        lastSetTime = now
        attachIfNeeded()
        slider?.value = min(max(value, 0), 1)
    }
}

// MARK: - 腾讯风格全屏播放器控制条（集成在播放器内核之上）

/// 覆盖在播放器内核上的腾讯视频风格控制条：
/// - 顶部标题栏（返回 + 标题）
/// - 底部控制栏：进度条行（时间 + 进度条 + 总时长）+ 按钮行
///   （左：后退10s/播放暂停/快进10s；右：倍速菜单/旋转/退出）
/// - 单击唤出/隐藏控制栏，双击播放/暂停
/// - 左右滑动快进/快退，左侧上下滑亮度，右侧上下滑音量
/// - 长按画面 2 倍速，松手恢复
/// - 倍速按钮弹出腾讯风格倍速菜单（1x/1.25x/1.5x/2x）
struct TencentStylePlayerOverlay: View {
    let player: AVPlayer?
    /// 播放内容标题（腾讯视频顶部标题栏同款）。
    var title: String = ""
    var isPlaying: Bool = true
    var onPlayPause: (() -> Void)? = nil
    var onRotate: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil
    var onLongPressBegan: (() -> Void)? = nil
    var onLongPressEnded: (() -> Void)? = nil
    /// 播放源（线路）名称列表；为空时不显示"线路"按钮。
    var sourceNames: [String] = []
    var selectedSourceIndex: Int = 0
    var onSelectSource: ((Int) -> Void)? = nil
    /// 剧集名称列表；为空时不显示"选集"按钮。
    var episodeNames: [String] = []
    var selectedEpisodeIndex: Int = 0
    var onSelectEpisode: ((Int) -> Void)? = nil
    /// 直播频道名称列表；为空时不显示"频道"按钮。
    var channelNames: [String] = []
    var selectedChannelIndex: Int = 0
    var onSelectChannel: ((Int) -> Void)? = nil
    /// 频道分组名称列表；为空时不显示分组条。
    var groupNames: [String] = []
    var selectedGroupIndex: Int = 0
    var onSelectGroup: ((Int) -> Void)? = nil
    /// 是否为直播：隐藏倍速与 10s 快进/后退按钮，左右滑动不做进度调节。
    var isLive: Bool = false
    /// 播放失败等场景下保持控制栏常显（不自动隐藏）。
    var keepControlsVisible: Bool = false

    @State private var controlsVisible = true
    @State private var hideControlsTask: Task<Void, Never>?
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isDraggingProgress = false
    @State private var draggingSeconds: Double = 0
    @State private var rate: Float = 1.0
    @State private var showRateMenu = false
    @State private var showEpisodePanel = false
    @State private var showSourcePanel = false
    @State private var showChannelPanel = false
    @State private var osdText: String?
    @State private var osdOpacity: Double = 0
    @State private var osdTimer: Timer?
    @State private var progressTimer: Timer?
    @State private var brightnessGestureStart: CGFloat?
    @State private var volumeGestureStart: Float?
    @State private var seekStartTime: Double?
    /// 锁屏状态：开启后禁用滑动/双击/长按等全部手势控制。
    @State private var isLocked = false
    /// 锁定态单击唤出的"仅锁按钮"浮层（腾讯逻辑：锁定时不显示完整控制栏）。
    @State private var showLockHint = false

    private static let playbackRates: [Float] = [1.0, 1.25, 1.5, 2.0]

    /// 读取窗口安全区顶部高度（灵动岛/刘海机型竖屏时约 47-59pt，
    /// 横屏时约 0-21pt），供标题栏避让使用。父容器 ignoresSafeArea 后
    /// SwiftUI 的 safeAreaPadding 拿不到真实值，需直接查 UIWindow。
    private static func safeTopInset() -> CGFloat {
        #if os(iOS)
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first else { return 0 }
        return window.safeAreaInsets.top
        #else
        return 0
        #endif
    }

    /// 读取窗口安全区底部高度（Home 指示条高度），供底部控制栏避让。
    private static func safeBottomInset() -> CGFloat {
        #if os(iOS)
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first else { return 0 }
        return window.safeAreaInsets.bottom
        #else
        return 0
        #endif
    }

    var body: some View {
        ZStack {
            Color.clear

            // 手势层常驻（播放失败黑屏时同样可单击唤出控制栏）。
            // 控制栏显示期由上层 topBar/controlsBar 拦截按钮点击；隐藏期手势层全屏响应。
            FullScreenGestureLayer(
                onBrightness: { translation in
                    guard !isLocked else { return }
                    if brightnessGestureStart == nil {
                        brightnessGestureStart = UIScreen.main.brightness
                    }
                    let delta = -translation.height / 800.0
                    let target = min(max((brightnessGestureStart ?? 0.5) + delta, 0), 1)
                    UIScreen.main.brightness = target
                    showOSD("亮度 \(Int(target * 100))%")
                },
                onVolume: { translation in
                    guard !isLocked else { return }
                    if volumeGestureStart == nil {
                        volumeGestureStart = SystemVolumeController.shared.currentVolume()
                    }
                    let delta = -translation.height / 800.0
                    let target = min(max((volumeGestureStart ?? 0.5) + Float(delta), 0), 1)
                    SystemVolumeController.shared.setVolume(target)
                    showOSD("音量 \(Int(target * 100))%")
                },
                onSeek: { offset in
                    // 直播无进度概念：左右滑动不调节进度；锁定时手势禁用。
                    guard !isLive, !isLocked else { return }
                    seekBy(offset)
                },
                onTap: {
                    // 锁定时单击仅显示"锁按钮"浮层，不显示完整控制栏。
                    if isLocked {
                        withAnimation(.easeOut(duration: 0.2)) {
                            showLockHint = true
                        }
                        return
                    }
                    if controlsVisible {
                        hideControlsNow()
                    } else {
                        showControls()
                    }
                },
                onDoubleTap: {
                    // 锁定时双击不响应。
                    guard !isLocked else { return }
                    onPlayPause?()
                },
                onLongPressBegan: {
                    guard !isLocked else { return }
                    onLongPressBegan?()
                },
                onLongPressEnded: {
                    guard !isLocked else { return }
                    onLongPressEnded?()
                },
                onDragEnded: {
                    brightnessGestureStart = nil
                    volumeGestureStart = nil
                    seekStartTime = nil
                    // 注意：不再在此调用 onLongPressEnded——手势层仅在长按确实激活
                    // （isSpeedActive）时于 onEnded 中恢复倍速，避免双击暂停等操作
                    // 松手时把 rate 恢复成播放导致"暂停不生效"。
                }
            )

            // OSD（快进/后退时间、亮度、音量、倍速提示）
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

            // 顶部标题栏（腾讯视频同款）：返回 + 标题
            VStack {
                HStack(spacing: 8) {
                    Button {
                        onClose?()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Text(title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                // 直接用窗口安全区顶部高度避让灵动岛/状态栏（父容器 ignoresSafeArea 后
                // safeAreaPadding 不生效），保证标题与返回键不被遮挡。
                .padding(.top, max(Self.safeTopInset(), 8))
                .padding(.bottom, 10)
                .background(
                    LinearGradient(
                        colors: [.black.opacity(0.55), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(controlsVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.25), value: controlsVisible)
            .allowsHitTesting(controlsVisible)

            // 底部控制栏（腾讯视频同款）
            VStack {
                Spacer()
                controlsBar
                    .opacity(controlsVisible ? 1 : 0)
                    .animation(.easeInOut(duration: 0.25), value: controlsVisible)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(controlsVisible)

            // 锁定态浮层：仅显示解锁按钮（腾讯逻辑——锁定时不显示完整控制栏）
            if isLocked && showLockHint {
                ZStack {
                    Color.black.opacity(0.001).ignoresSafeArea()
                        .onTapGesture { showLockHint = false }
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Button {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    isLocked = false
                                    showLockHint = false
                                    showControls()
                                }
                            } label: {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundColor(.white)
                                    .frame(width: 60, height: 60)
                                    .background(Color.black.opacity(0.6))
                                    .clipShape(Circle())
                            }
                            .padding(.trailing, 28)
                            .padding(.bottom, 32)
                        }
                        Spacer()
                    }
                }
                .transition(.opacity)
            }
        }
        .onAppear {
            showControls()
            startProgressTimer()
        }
        .onDisappear {
            hideControlsTask?.cancel()
            progressTimer?.invalidate()
            osdTimer?.invalidate()
        }
    }

    /// 立即隐藏控制条（腾讯逻辑：控制条显示期点画面空白处隐藏）。
    private func hideControlsNow() {
        hideControlsTask?.cancel()
        withAnimation(.easeOut(duration: 0.3)) {
            controlsVisible = false
        }
    }

    // MARK: - 底部控制栏（腾讯布局）

    private var controlsBar: some View {
        VStack(spacing: 10) {
            // 频道面板（直播全屏切频道）
            if showChannelPanel {
                channelPanel
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // 选集面板（腾讯风格弹层）
            if showEpisodePanel {
                episodePanel
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // 线路面板（腾讯风格弹层）
            if showSourcePanel {
                sourcePanel
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // 倍速菜单（腾讯风格：点击倍速后向上弹出选项）
            if showRateMenu {
                HStack(spacing: 8) {
                    ForEach(Self.playbackRates, id: \.self) { r in
                        Button {
                            setRate(r)
                        } label: {
                            Text(r == rate ? "\(String(format: "%.2g", r))x" : String(format: "%.2g", r) + "x")
                                .font(.system(size: 12, weight: r == rate ? .bold : .regular))
                                .foregroundColor(r == rate ? .black : .white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(r == rate ? Color.white : Color.white.opacity(0.2))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // 进度条行：当前时间 / 进度条 / 总时长
            HStack(spacing: 10) {
                Text("\(formatTime(currentTime))/\(formatTime(duration))")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(minWidth: 74, alignment: .leading)

                Slider(
                    value: Binding(
                        get: { isDraggingProgress ? draggingSeconds : currentTime },
                        set: { draggingSeconds = $0 }
                    ),
                    in: 0...max(duration, max(currentTime, 1)),
                    onEditingChanged: { editing in
                        isDraggingProgress = editing
                        showControls()
                        if !editing {
                            seek(to: draggingSeconds)
                        }
                    }
                )
                .accentColor(.white)
                .disabled(duration <= 0)
            }

            // 按钮行：左播放控制固定 / 右功能按钮组（窄屏可横向滚动，防止竖屏溢出文字不显示）
            HStack(spacing: 16) {
                HStack(spacing: 20) {
                    // 直播无进度条：隐藏 10s 快进/后退按钮。
                    if !isLive {
                        Button {
                            showControls()
                            seekBy(-10)
                            showOSD("后退 10s")
                        } label: {
                            Image(systemName: "gobackward.10")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundColor(.white)
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        showControls()
                        onPlayPause?()
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)

                    if !isLive {
                        Button {
                            showControls()
                            seekBy(10)
                            showOSD("快进 10s")
                        } label: {
                            Image(systemName: "goforward.10")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundColor(.white)
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // 直播"频道"按钮固定显示（播放控制右侧，不依赖右侧滚动区）。
                if isLive && channelNames.count > 0 {
                    Button {
                        showControls()
                        withAnimation(.easeOut(duration: 0.2)) {
                            showChannelPanel.toggle()
                            showEpisodePanel = false
                            showSourcePanel = false
                            showRateMenu = false
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "list.bullet")
                                .font(.system(size: 12, weight: .semibold))
                            Text("频道")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(showChannelPanel ? Color.white.opacity(0.25) : Color.white.opacity(0.15))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 8)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        // 直播频道按钮（固定位置已提供，滚动区不再重复）
                        if !isLive && channelNames.count > 1 {
                            Button {
                                showControls()
                                withAnimation(.easeOut(duration: 0.2)) {
                                    showChannelPanel.toggle()
                                    showEpisodePanel = false
                                    showSourcePanel = false
                                    showRateMenu = false
                                }
                            } label: {
                                Text("频道")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(showChannelPanel ? Color.white.opacity(0.25) : Color.white.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }

                        // 选集按钮（腾讯视频底部右侧"选集"同款）
                        if episodeNames.count > 1 {
                            Button {
                                showControls()
                                withAnimation(.easeOut(duration: 0.2)) {
                                    showEpisodePanel.toggle()
                                    showChannelPanel = false
                                    showSourcePanel = false
                                    showRateMenu = false
                                }
                            } label: {
                                Text("选集")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(showEpisodePanel ? Color.white.opacity(0.25) : Color.white.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }

                        // 线路（播放源）按钮
                        if sourceNames.count > 1 {
                            Button {
                                showControls()
                                withAnimation(.easeOut(duration: 0.2)) {
                                    showSourcePanel.toggle()
                                    showChannelPanel = false
                                    showEpisodePanel = false
                                    showRateMenu = false
                                }
                            } label: {
                                Text("线路")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(showSourcePanel ? Color.white.opacity(0.25) : Color.white.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }

                        // 倍速按钮（直播无加速概念，隐藏）
                        if !isLive {
                            Button {
                                showControls()
                                withAnimation(.easeOut(duration: 0.2)) {
                                    showRateMenu.toggle()
                                    showChannelPanel = false
                                    showEpisodePanel = false
                                    showSourcePanel = false
                                }
                            } label: {
                                Text("倍速")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(showRateMenu ? Color.white.opacity(0.25) : Color.white.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }

                        Button {
                            showControls()
                            onRotate?()
                        } label: {
                            Image(systemName: "rectangle.landscape.rotate")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundColor(.white)
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.plain)

                        // 锁屏按钮：开启后禁用全部手势控制，单击画面仅显示解锁按钮。
                        Button {
                            isLocked.toggle()
                            showLockHint = false
                            if isLocked {
                                hideControlsNow()
                            } else {
                                showControls()
                            }
                        } label: {
                            Image(systemName: isLocked ? "lock.fill" : "lock.open")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(isLocked ? Color.orange : .white)
                                .frame(width: 40, height: 40)
                        }
                        .buttonStyle(.plain)

                        Button {
                            onClose?()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 21))
                                .foregroundColor(.white)
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        // 直接读取窗口安全区底部高度避让 Home 指示条（safeAreaPadding 在 ignoresSafeArea 容器内不生效）。
        .padding(.bottom, Self.safeBottomInset())
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.72)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .environment(\.colorScheme, .dark)
    }

    // MARK: - 频道面板（直播全屏）

    private var channelPanel: some View {
        VStack(spacing: 10) {
            Text("频道")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)

            // 分组横条：点击切换分组
            if groupNames.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(groupNames.indices, id: \.self) { gi in
                            Button {
                                onSelectGroup?(gi)
                                showControls()
                            } label: {
                                Text(groupNames[gi])
                                    .font(.system(size: 12, weight: gi == selectedGroupIndex ? .bold : .regular))
                                    .foregroundColor(gi == selectedGroupIndex ? .black : .white)
                                    .lineLimit(1)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(gi == selectedGroupIndex ? Color.white : Color.white.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(channelNames.indices, id: \.self) { i in
                        Button {
                            selectChannel(i)
                        } label: {
                            HStack {
                                Text(channelNames[i])
                                    .font(.system(size: 12, weight: i == selectedChannelIndex ? .bold : .regular))
                                    .foregroundColor(i == selectedChannelIndex ? .black : .white)
                                    .lineLimit(1)
                                Spacer()
                                if i == selectedChannelIndex {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.black)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(i == selectedChannelIndex ? Color.white : Color.white.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .padding(12)
        .background(Color.black.opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 选集面板

    private var episodePanel: some View {
        VStack(spacing: 10) {
            Text("选集")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(episodeNames.indices, id: \.self) { i in
                        Button {
                            selectEpisode(i)
                        } label: {
                            Text(episodeNames[i])
                                .font(.system(size: 12, weight: i == selectedEpisodeIndex ? .bold : .regular))
                                .foregroundColor(i == selectedEpisodeIndex ? .black : .white)
                                .lineLimit(1)
                                .frame(maxWidth: 110)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(i == selectedEpisodeIndex ? Color.white : Color.white.opacity(0.2))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 96)
        }
        .padding(12)
        .background(Color.black.opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 线路面板

    private var sourcePanel: some View {
        VStack(spacing: 10) {
            Text("播放线路")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(sourceNames.indices, id: \.self) { i in
                        Button {
                            selectSource(i)
                        } label: {
                            Text(sourceNames[i])
                                .font(.system(size: 12, weight: i == selectedSourceIndex ? .bold : .regular))
                                .foregroundColor(i == selectedSourceIndex ? .black : .white)
                                .lineLimit(1)
                                .frame(maxWidth: 140)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(i == selectedSourceIndex ? Color.white : Color.white.opacity(0.2))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 40)
        }
        .padding(12)
        .background(Color.black.opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 控制与状态

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in
                guard let player = player else { return }
                let cur = player.currentTime().seconds
                if cur.isFinite, cur >= 0 {
                    currentTime = cur
                    if !isDraggingProgress {
                        draggingSeconds = cur
                    }
                }
                if let d = player.currentItem?.duration.seconds, d.isFinite, d >= 0 {
                    duration = d
                }
            }
        }
    }

    private func seek(to seconds: Double) {
        guard let player else { return }
        let wasPlaying = player.rate != 0
        player.seek(to: CMTime(seconds: max(seconds, 0), preferredTimescale: 600)) { _ in
            if wasPlaying {
                player.playImmediately(atRate: player.defaultRate)
            }
        }
    }

    private func seekBy(_ offset: Double) {
        guard let player else { return }
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
        showOSD(formatTime(target))
    }

    private func setRate(_ r: Float) {
        guard let player else { return }
        rate = r
        showRateMenu = false
        player.defaultRate = r
        if player.rate > 0 {
            player.rate = r
        }
        showOSD("倍速 \(String(format: "%.2g", r))x")
        showControls()
    }

    /// 选择剧集：关闭面板并通知父级切集。
    private func selectEpisode(_ index: Int) {
        guard index != selectedEpisodeIndex else {
            showEpisodePanel = false
            showControls()
            return
        }
        showEpisodePanel = false
        onSelectEpisode?(index)
        showControls()
    }

    /// 选择直播频道：关闭面板并通知父级切台。
    private func selectChannel(_ index: Int) {
        guard index != selectedChannelIndex else {
            showChannelPanel = false
            showControls()
            return
        }
        showChannelPanel = false
        onSelectChannel?(index)
        showControls()
    }

    /// 选择线路：关闭面板并通知父级切源。
    private func selectSource(_ index: Int) {
        guard index != selectedSourceIndex else {
            showSourcePanel = false
            showControls()
            return
        }
        showSourcePanel = false
        onSelectSource?(index)
        showControls()
    }

    private func showControls() {
        withAnimation(.easeOut(duration: 0.2)) {
            controlsVisible = true
        }
        hideControlsTask?.cancel()
        // 播放失败等场景：控制栏常显，不自动隐藏。
        guard !keepControlsVisible else { return }
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

    private func formatTime(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - 视频方向检测与全屏朝向

/// 异步读取 AVAsset 首个视频轨道的自然尺寸（用于判断横/竖版）。
func videoTrackNaturalSize(_ asset: AVAsset) async -> CGSize {
    guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
        return .zero
    }
    return (try? await track.load(.naturalSize)) ?? .zero
}

/// 根据当前播放内容的视频方向决定全屏朝向：
/// 竖版内容（高>宽）保持竖屏全屏，横版/未知内容强制横屏。
/// 解决"全屏下观看竖版视频被强制横屏"的问题。
func applyPlayerOrientation(player: AVPlayer?) {
    guard let player else {
        DeviceOrientation.forceLandscape()
        return
    }
    let size = player.currentItem?.presentationSize ?? .zero
    if size.height > size.width + 1 {
        DeviceOrientation.forcePortrait()
    } else if size.width > size.height + 1 {
        DeviceOrientation.forceLandscape()
    } else {
        // 尺寸未知（播放器尚未解析完成）：先按横屏处理，异步解析后再校正。
        DeviceOrientation.forceLandscape()
        if let asset = player.currentItem?.asset {
            Task { @MainActor in
                let natural = await videoTrackNaturalSize(asset)
                guard natural.height > 0, natural.width > 0 else { return }
                if natural.height > natural.width + 1 {
                    DeviceOrientation.forcePortrait()
                }
            }
        }
    }
}
#endif

#if os(macOS)
private struct MacOSPlayerView: NSViewRepresentable {
    let player: AVPlayer
    
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.showsFullScreenToggleButton = false
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }
    
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
    
    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player = nil
    }
}
#endif

/// 系统播放器会话控制器：用于在页面内联与全屏视图间复用同一 AVPlayer，避免重复拉流
@MainActor
final class SystemPlayerSessionController: ObservableObject {
    var player: AVPlayer?
    var mediaURLString: String?
    
    func setPlayer(_ newPlayer: AVPlayer, urlString: String) {
        if player !== newPlayer {
            player?.pause()
            player?.replaceCurrentItem(with: nil)
        }
        player = newPlayer
        mediaURLString = urlString
    }
    
    func stop() {
        let stoppingPlayer = player
        player?.pause()
        player = nil
        mediaURLString = nil
        // AVPlayer.replaceCurrentItem(with: nil) 在播放网络流时会同步阻塞主线程数秒。
        // 将其移到后台执行，闭包持有 AVPlayer 强引用防止提前 dealloc。
        if let stoppingPlayer {
            DispatchQueue.global(qos: .utility).async {
                stoppingPlayer.replaceCurrentItem(with: nil)
            }
        }
    }
}

/// 视频播放器组件 - 对应 Android 版 PlayFragment
struct PlayerView: View {
    let urlString: String
    var startPosition: Double = 0
    var onProgressChanged: ((Double, Double?) -> Void)? = nil
    var onPlaybackEnded: (() -> Void)? = nil
    var onPlaybackFailed: (() -> Void)? = nil
    var onToggleFullScreen: (() -> Void)? = nil
    var canPlayNext: Bool = false
    var onPlayNext: (() -> Void)? = nil
    var systemController: SystemPlayerSessionController? = nil
    var vlcController: VLCPlayerController? = nil
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
        Group {
            switch selectedEngine {
            case .system:
                AVPlayerContentView(
                    urlString: urlString,
                    startPosition: startPosition,
                    onProgressChanged: onProgressChanged,
                    onPlaybackEnded: onPlaybackEnded,
                    onPlaybackFailed: onPlaybackFailed,
                    onToggleFullScreen: onToggleFullScreen,
                    canPlayNext: canPlayNext,
                    onPlayNext: onPlayNext,
                    sharedController: systemController
                )
            case .vlc:
                VLCVodPlayerView(
                    urlString: urlString,
                    startPosition: startPosition,
                    onProgressChanged: onProgressChanged,
                    onPlaybackEnded: onPlaybackEnded,
                    onPlaybackFailed: onPlaybackFailed,
                    onToggleFullScreen: onToggleFullScreen,
                    canPlayNext: canPlayNext,
                    onPlayNext: onPlayNext,
                    sharedController: vlcController
                )
            }
        }
        .id(selectedEngine.rawValue)
        .onAppear {
            if selectedEngine != .system {
                systemController?.stop()
            }
            if selectedEngine != .vlc {
                vlcController?.stop()
            }
        }
        .onChange(of: selectedEngine) { _, newValue in
            if newValue != .system {
                systemController?.stop()
            }
            if newValue != .vlc {
                vlcController?.stop()
            }
        }
    }
}

/// 基于系统 AVPlayer 的点播播放器实现
struct AVPlayerContentView: View {
    private static let supportedPlaybackRates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    let urlString: String
    var startPosition: Double = 0
    var onProgressChanged: ((Double, Double?) -> Void)? = nil
    var onPlaybackEnded: (() -> Void)? = nil
    var onPlaybackFailed: (() -> Void)? = nil
    var onToggleFullScreen: (() -> Void)? = nil
    var canPlayNext: Bool = false
    var onPlayNext: (() -> Void)? = nil
    var sharedController: SystemPlayerSessionController? = nil
    @AppStorage(HawkConfig.PLAY_SPEED) private var savedPlaybackRate = 1.0
    @State private var player: AVPlayer?
    @State private var playbackEndObserver: NSObjectProtocol?
    @State private var timeObserverToken: Any?
    
    // UI 状态
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var volume: Double = 1.0
    @State private var rate: Float = 1.0
    @State private var isPreparing = true
    @State private var playbackError: String?
    @State private var showControls = true
    @State private var controlsTimer: Timer?
    @State private var hideControlsTask: Task<Void, Never>?
    @State private var osdIcon: String?
    @State private var osdOpacity: Double = 0
    @State private var osdTimer: Timer?
    @State private var isDraggingProgress = false
    @State private var draggingSeconds: Double = 0
    @State private var playerObservers: [NSKeyValueObservation] = []
    
    @State private var videoZoomScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            Group {
                if let player = player {
                    PlatformVideoPlayer(player: player)
                        #if os(iOS)
                        .scaleEffect(videoZoomScale)
                        #endif
                } else {
                    ZStack {
                        Color.black
                        ProgressView()
                            .tint(.white)
                    }
                }
            }
            #if !os(iOS)
            .onTapGesture(count: 2) {
                onToggleFullScreen?()
            }
            .onTapGesture(count: 1) {
                togglePlayPauseWithOSD()
            }
            #endif

            if isPreparing {
                ProgressView()
                    .tint(.white)
            }
            
            if let error = playbackError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.yellow)
                    Text("播放失败")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
                .padding()
            }

            if let osdIcon = osdIcon {
                Image(systemName: osdIcon)
                    .font(.system(size: 60, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(30)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
                    .opacity(osdOpacity)
                    .allowsHitTesting(false)
            }
        }
        #if os(iOS)
        .overlay {
            PlayerGestureLayer(
                onSeek: { offset in seek(by: offset) },
                onTogglePlayPause: { togglePlayPauseWithOSD() },
                onToggleControls: { toggleControls() },
                onZoomChanged: { scale in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        videoZoomScale = scale
                    }
                },
                currentTime: currentTime,
                duration: duration
            )
        }
        #endif
        .overlay(alignment: .bottom) {
            GeometryReader { proxy in
                if player != nil {
                    playbackControls(containerWidth: proxy.size.width)
                        .opacity(showControls ? 1.0 : 0.0)
                        .animation(.easeInOut(duration: 0.3), value: showControls)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
        .overlay {
            SystemPlayerKeyboardCaptureView(
                onLeft: { seek(by: -seekStep) },
                onRight: { seek(by: seekStep) },
                onTogglePlayPause: { togglePlayPause() },
                onToggleFullScreen: { onToggleFullScreen?() },
                onVolumeDown: { wakeUpControls(); adjustVolume(by: -volumeStep) },
                onVolumeUp: { wakeUpControls(); adjustVolume(by: volumeStep) }
            )
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .allowsHitTesting(false)
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(_): wakeUpControls()
            case .ended: break
            }
        }
        .onAppear {
            syncRateFromSettings()
            setupPlayer()
            wakeUpControls()
        }
        .onChange(of: urlString) { _, _ in
            syncRateFromSettings()
            setupPlayer()
            wakeUpControls()
        }
        .onDisappear {
            cleanupPlayer(keepSharedPlayer: sharedController != nil)
            controlsTimer?.invalidate()
            hideControlsTask?.cancel()
            hideControlsTask = nil
            osdTimer?.invalidate()
        }
        .onReceive(NotificationCenter.default.publisher(for: RemoteControlService.pauseRequestNotification)) { _ in
            if isPlaying {
                player?.pause()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: RemoteControlService.resumeRequestNotification)) { _ in
            if !isPlaying, let player {
                player.playImmediately(atRate: rate)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: RemoteControlService.volumeRequestNotification)) { notification in
            if let level = notification.userInfo?["level"] as? Int {
                player?.volume = Float(level) / 100.0
            }
        }
    }
    
    private func setupPlayer() {
        guard let url = Self.sanitizedURL(from: urlString) else {
            print("[AVPlayer] URL sanitization failed for: \(urlString)")
            return
        }
        let targetURLString = url.absoluteString
        let preferredRate = normalizedSavedPlaybackRate
        rate = preferredRate
        playbackError = nil
        
        if let sharedController,
           sharedController.mediaURLString == targetURLString,
           let sharedPlayer = sharedController.player {
            cleanupPlayer(keepSharedPlayer: true)
            // 强制重新关联 AVPlayerItem，修复从全屏退出后 VideoPlayer 黑屏问题。
            // SwiftUI.VideoPlayer 在复用已有 AVPlayer 时可能无法正确连接视频渲染层，
            // 通过 replaceCurrentItem 触发内部 layer 重新绑定。
            #if os(iOS)
            if let currentItem = sharedPlayer.currentItem {
                let currentTime = sharedPlayer.currentTime()
                let wasPlaying = sharedPlayer.rate != 0
                sharedPlayer.replaceCurrentItem(with: nil)
                sharedPlayer.replaceCurrentItem(with: currentItem)
                sharedPlayer.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                    if wasPlaying {
                        sharedPlayer.playImmediately(atRate: self.normalizedSavedPlaybackRate)
                    }
                }
            }
            #endif
            player = sharedPlayer
            applyPreferredPlaybackRate(to: sharedPlayer)
            bindPlayerObservers(for: sharedPlayer)
            reportProgress(for: sharedPlayer)
            return
        }
        
        // 清理旧播放器
        cleanupPlayer()
        
        // 使用 AVURLAsset 并设置自定义 HTTP 头，解决部分 CDN 拒绝无 User-Agent 请求的问题
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(nil, queue: nil)
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = 0
        let newPlayer = AVPlayer(playerItem: playerItem)
        newPlayer.defaultRate = preferredRate
        if let sharedController {
            sharedController.setPlayer(newPlayer, urlString: targetURLString)
        }
        
        player = newPlayer
        bindPlayerObservers(for: newPlayer)
        startPlayback(for: newPlayer)
    }
    
    /// 将原始 URL 字符串转换为合法的 URL，处理未编码的特殊字符。
    private static func sanitizedURL(from urlString: String) -> URL? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed) {
            return url
        }
        // 尝试对整个字符串进行百分号编码（保留已编码部分）
        if let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: encoded) {
            return url
        }
        return nil
    }
    
    private func bindPlayerObservers(for player: AVPlayer) {
        playerObservers = [
            player.observe(\.timeControlStatus, options: [.new]) { p, _ in
                let status = p.timeControlStatus
                DispatchQueue.main.async { isPlaying = status == .playing }
            },
            player.observe(\.reasonForWaitingToPlay, options: [.new]) { p, _ in
                let reason = p.reasonForWaitingToPlay
                DispatchQueue.main.async { isPreparing = reason != nil }
            },
            player.observe(\.volume, options: [.new]) { p, _ in
                let vol = Double(p.volume)
                DispatchQueue.main.async { volume = vol }
            },
            player.observe(\.rate, options: [.new]) { p, _ in
                let currentRate = p.rate
                guard currentRate > 0 else { return }
                let normalized = Self.normalizedPlaybackRate(from: currentRate)
                DispatchQueue.main.async {
                    rate = normalized
                    if abs(savedPlaybackRate - Double(normalized)) > 0.001 {
                        savedPlaybackRate = Double(normalized)
                    }
                }
            }
        ]
        // 监听 AVPlayerItem 状态，捕获加载失败的具体原因
        if let item = player.currentItem {
            let itemObserver = item.observe(\.status, options: [.new]) { observedItem, _ in
                if observedItem.status == .failed {
                    let errorDesc = observedItem.error?.localizedDescription ?? "未知错误"
                    DispatchQueue.main.async {
                        isPreparing = false
                        playbackError = errorDesc
                        onPlaybackFailed?()
                    }
                } else if observedItem.status == .readyToPlay {
                    DispatchQueue.main.async {
                        playbackError = nil
                    }
                }
            }
            playerObservers.append(itemObserver)
        }
        observePlaybackProgress(for: player)
        observePlaybackEnd(for: player)
        isPlaying = player.timeControlStatus == .playing
        isPreparing = player.reasonForWaitingToPlay != nil
        volume = Double(player.volume)
        rate = normalizedSavedPlaybackRate
    }
    
    private func detachPlayerObservers() {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        if let observer = playbackEndObserver {
            NotificationCenter.default.removeObserver(observer)
            playbackEndObserver = nil
        }
        playerObservers.forEach { $0.invalidate() }
        playerObservers.removeAll()
    }
    
    private func cleanupPlayer(keepSharedPlayer: Bool = false) {
        let currentPlayer = player
        detachPlayerObservers()
        
        guard let currentPlayer else { return }
        if keepSharedPlayer, sharedController?.player === currentPlayer {
            player = nil
            return
        }
        
        currentPlayer.pause()
        if sharedController?.player === currentPlayer {
            sharedController?.player = nil
            sharedController?.mediaURLString = nil
        }
        player = nil
        // replaceCurrentItem(with: nil) 在播放网络流时会阻塞主线程，移到后台
        DispatchQueue.global(qos: .utility).async {
            currentPlayer.replaceCurrentItem(with: nil)
        }
    }
    
    private func startPlayback(for player: AVPlayer) {
        let target = max(startPosition, 0)
        
        if target > 0 {
            let seekTime = CMTime(seconds: target, preferredTimescale: 600)
            player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                reportProgress(for: player)
                playAtPreferredRate(player)
            }
        } else {
            playAtPreferredRate(player)
        }
    }
    
    private func togglePlayPause() {
        guard let player = player else { return }
        if player.rate == 0 {
            playAtPreferredRate(player)
        } else {
            player.pause()
        }
    }
    
    private func togglePlayPauseWithOSD() {
        togglePlayPause()
        showOSD(icon: isPlaying ? "pause.fill" : "play.fill")
    }
    
    /// 单击切换控制层显示/隐藏。
    private func toggleControls() {
        if showControls {
            hideControlsTask?.cancel()
            hideControlsTask = nil
            withAnimation(.easeOut(duration: 0.3)) {
                showControls = false
            }
        } else {
            wakeUpControls()
        }
    }
    
    private func wakeUpControls() {
        withAnimation { showControls = true }
        hideControlsTask?.cancel()
        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.5)) {
                showControls = false
            }
        }
        hideControlsTask = task
    }
    
    private func showOSD(icon: String) {
        osdIcon = icon
        osdOpacity = 1.0
        osdTimer?.invalidate()
        osdTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
            withAnimation(.easeOut(duration: 0.5)) {
                osdOpacity = 0.0
            }
        }
    }
    
    private func observePlaybackEnd(for player: AVPlayer) {
        guard let item = player.currentItem else { return }
        
        playbackEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            onPlaybackEnded?()
        }
    }
    
    private func observePlaybackProgress(for player: AVPlayer) {
        let interval = CMTime(seconds: 1, preferredTimescale: 2)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { _ in
            reportProgress(for: player)
        }
    }
    
    private func reportProgress(for player: AVPlayer?) {
        guard let player else { return }
        let current = player.currentTime().seconds
        guard current.isFinite, current >= 0 else { return }
        
        if !isDraggingProgress {
            self.currentTime = current
            self.draggingSeconds = current
        }
        
        let rawDuration = player.currentItem?.duration.seconds
        if let rawDuration, rawDuration.isFinite, rawDuration >= 0 {
            self.duration = rawDuration
        }
        onProgressChanged?(current, duration > 0 ? duration : nil)
    }
    
    private var seekStep: Double {
        let saved = UserDefaults.standard.integer(forKey: HawkConfig.PLAY_TIME_STEP)
        return Double(saved > 0 ? saved : 10)
    }

    private var volumeStep: Double { 0.1 }
    
    private var progressUpperBound: Double {
        max(duration, max(currentTime, 1))
    }

    private func playbackControls(containerWidth: CGFloat) -> some View {
        #if os(iOS)
        let controlWidth = containerWidth * 1.0
        #else
        let controlWidth = containerWidth * 0.7
        #endif

        return VStack(spacing: 0) {
            #if os(iOS)
            // iOS: 紧凑单行布局 — 进度条在上，按钮在下紧贴
            // 进度条行
            HStack(spacing: 8) {
                Text(currentTime.durationString)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
                
                Slider(
                    value: Binding(
                        get: { isDraggingProgress ? draggingSeconds : currentTime },
                        set: { 
                            draggingSeconds = $0
                            wakeUpControls()
                        }
                    ),
                    in: 0...progressUpperBound,
                    onEditingChanged: { editing in
                        isDraggingProgress = editing
                        wakeUpControls()
                        if !editing {
                            seek(to: draggingSeconds)
                        }
                    }
                )
                .accentColor(.white)
                .disabled(duration <= 0)
                
                Text(duration.durationString)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
            
            // 控制按钮行 — 紧凑排列
            HStack(spacing: 0) {
                // 左：倍速
                playbackRateMenu
                    .frame(minWidth: 36, alignment: .leading)
                
                Spacer()
                
                // 中间：主控按钮
                HStack(spacing: 20) {
                    Button {
                        wakeUpControls()
                        seek(by: -seekStep)
                        showOSD(icon: "gobackward.\(Int(seekStep))")
                    } label: {
                        Image(systemName: "gobackward.\(Int(seekStep))")
                            .font(.system(size: 16, weight: .medium))
                            .frame(minWidth: 36, minHeight: 36)
                    }
                    .buttonStyle(.plain)
                    
                    Button {
                        wakeUpControls()
                        togglePlayPauseWithOSD()
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 20, weight: .bold))
                            .frame(minWidth: 36, minHeight: 36)
                    }
                    .buttonStyle(.plain)
                    
                    Button {
                        wakeUpControls()
                        seek(by: seekStep)
                        showOSD(icon: "goforward.\(Int(seekStep))")
                    } label: {
                        Image(systemName: "goforward.\(Int(seekStep))")
                            .font(.system(size: 16, weight: .medium))
                            .frame(minWidth: 36, minHeight: 36)
                    }
                    .buttonStyle(.plain)

                    if let onPlayNext {
                        Button {
                            guard canPlayNext else { return }
                            wakeUpControls()
                            onPlayNext()
                            showOSD(icon: "forward.end.fill")
                        } label: {
                            Image(systemName: "forward.end.fill")
                                .font(.system(size: 16, weight: .medium))
                                .frame(minWidth: 36, minHeight: 36)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canPlayNext)
                        .opacity(canPlayNext ? 1 : 0.4)
                    }
                }
                
                Spacer()
                
                // 右：全屏
                if let onToggleFullScreen {
                    Button {
                        wakeUpControls()
                        onToggleFullScreen()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 14, weight: .bold))
                            .frame(minWidth: 36, minHeight: 36)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            #else
            // macOS: 保持两行布局
            HStack(spacing: 12) {
                Text(currentTime.durationString)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)
                    .frame(width: 62, alignment: .leading)
                
                Slider(
                    value: Binding(
                        get: { isDraggingProgress ? draggingSeconds : currentTime },
                        set: { 
                            draggingSeconds = $0
                            wakeUpControls()
                        }
                    ),
                    in: 0...progressUpperBound,
                    onEditingChanged: { editing in
                        isDraggingProgress = editing
                        wakeUpControls()
                        if !editing {
                            seek(to: draggingSeconds)
                        }
                    }
                )
                .accentColor(.white)
                .disabled(duration <= 0)
                
                Text(duration.durationString)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)
                    .frame(width: 62, alignment: .trailing)
            }
            .padding(.horizontal, 4)
            
            HStack(spacing: 0) {
                HStack(spacing: 16) {
                    playbackRateMenu
                }
                .frame(width: 150, alignment: .leading)
                
                Spacer()
                
                HStack(spacing: 24) {
                    Button {
                        wakeUpControls()
                        seek(by: -seekStep)
                        showOSD(icon: "gobackward.\(Int(seekStep))")
                    } label: {
                        Image(systemName: "gobackward.\(Int(seekStep))")
                            .font(.system(size: 18, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    
                    Button {
                        wakeUpControls()
                        togglePlayPauseWithOSD()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.15))
                                .frame(width: 38, height: 38)
                            
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 18, weight: .bold))
                        }
                    }
                    .buttonStyle(.plain)
                    
                    Button {
                        wakeUpControls()
                        seek(by: seekStep)
                        showOSD(icon: "goforward.\(Int(seekStep))")
                    } label: {
                        Image(systemName: "goforward.\(Int(seekStep))")
                            .font(.system(size: 18, weight: .medium))
                    }
                    .buttonStyle(.plain)

                    if let onPlayNext {
                        Button {
                            guard canPlayNext else { return }
                            wakeUpControls()
                            onPlayNext()
                            showOSD(icon: "forward.end.fill")
                        } label: {
                            Image(systemName: "forward.end.fill")
                                .font(.system(size: 18, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .disabled(!canPlayNext)
                        .opacity(canPlayNext ? 1 : 0.4)
                    }
                }
                
                Spacer()
                
                HStack(spacing: 14) {
                    HStack(spacing: 6) {
                        Button {
                            wakeUpControls()
                            let newVolume = volume > 0 ? 0.0 : 1.0
                            player?.volume = Float(newVolume)
                            showOSD(icon: newVolume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        } label: {
                            Image(systemName: volumeIconName)
                                .font(.system(size: 14, weight: .bold))
                                .frame(width: 20)
                        }
                        .buttonStyle(.plain)

                        Slider(
                            value: Binding(
                                get: { volume },
                                set: {
                                    player?.volume = Float($0)
                                    wakeUpControls()
                                }
                            ),
                            in: 0...1.0
                        )
                        .accentColor(.white.opacity(0.8))
                        .frame(width: 80)
                    }
                    
                    if let onToggleFullScreen {
                        Button {
                            wakeUpControls()
                            onToggleFullScreen()
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 15, weight: .bold))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 150, alignment: .trailing)
            }
            .padding(.top, 8)
            #endif
        }
        #if os(iOS)
        .padding(.vertical, 2)
        .foregroundColor(.white)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.6)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .padding(.bottom, 0)
        .frame(width: controlWidth)
        #else
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .foregroundColor(.white)
        .glassCard(cornerRadius: 18)
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
        .frame(width: controlWidth)
        #endif
        .environment(\.colorScheme, .dark)
    }

    private var playbackRateMenu: some View {
        Menu {
            ForEach(Self.supportedPlaybackRates, id: \.self) { r in
                Button {
                    wakeUpControls()
                    setPlaybackRate(r)
                    showOSD(icon: "speedometer")
                } label: {
                    HStack {
                        Text("\(String(format: "%.1f", r))x")
                        if r == rate {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("\(String(format: "%.1f", rate))x")
                Image(systemName: "chevron.up")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.12))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var volumeIconName: String {
        if volume <= 0 { return "speaker.slash.fill" }
        if volume < 0.5 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }

    private var normalizedSavedPlaybackRate: Float {
        Self.normalizedPlaybackRate(from: Float(savedPlaybackRate))
    }

    private static func normalizedPlaybackRate(from raw: Float) -> Float {
        guard !supportedPlaybackRates.isEmpty else { return 1.0 }
        return supportedPlaybackRates.min(by: { abs($0 - raw) < abs($1 - raw) }) ?? 1.0
    }

    private func syncRateFromSettings() {
        rate = normalizedSavedPlaybackRate
    }

    private func setPlaybackRate(_ value: Float) {
        let normalized = Self.normalizedPlaybackRate(from: value)
        rate = normalized
        savedPlaybackRate = Double(normalized)
        guard let player else { return }
        player.defaultRate = normalized
        if player.rate > 0 {
            player.rate = normalized
        }
    }

    private func applyPreferredPlaybackRate(to player: AVPlayer) {
        let normalized = normalizedSavedPlaybackRate
        rate = normalized
        player.defaultRate = normalized
        if player.rate > 0 {
            player.rate = normalized
        }
    }

    private func playAtPreferredRate(_ player: AVPlayer) {
        let normalized = normalizedSavedPlaybackRate
        rate = normalized
        player.defaultRate = normalized
        player.playImmediately(atRate: normalized)
    }

    private func seek(to seconds: Double) {
        guard let player = player else { return }
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }
    
    private func seek(by offset: Double) {
        guard let player else { return }
        
        let current = player.currentTime().seconds
        guard current.isFinite else { return }
        let wasPlaying = player.rate != 0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        
        var target = max(current + offset, 0)
        if let duration = player.currentItem?.duration.seconds, duration.isFinite {
            target = min(target, duration)
        }
        
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { _ in
            reportProgress(for: player)
            if wasPlaying {
                playAtPreferredRate(player)
            }
        }
    }

    private func adjustVolume(by delta: Double) {
        guard let player else { return }
        let current = Double(player.volume)
        let target = min(max(current + delta, 0), 1)
        player.volume = Float(target)
        showOSD(icon: target <= 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
    }
}

#if os(macOS)
private struct SystemPlayerKeyboardCaptureView: NSViewRepresentable {
    let onLeft: () -> Void
    let onRight: () -> Void
    let onTogglePlayPause: () -> Void
    let onToggleFullScreen: () -> Void
    let onVolumeDown: () -> Void
    let onVolumeUp: () -> Void
    
    func makeNSView(context: Context) -> SystemPlayerKeyCaptureNSView {
        let view = SystemPlayerKeyCaptureNSView(frame: .zero)
        applyCallbacks(to: view)
        DispatchQueue.main.async {
            view.activate()
        }
        return view
    }
    
    func updateNSView(_ nsView: SystemPlayerKeyCaptureNSView, context: Context) {
        applyCallbacks(to: nsView)
        DispatchQueue.main.async {
            nsView.activate()
        }
    }
    
    private func applyCallbacks(to view: SystemPlayerKeyCaptureNSView) {
        view.onLeft = onLeft
        view.onRight = onRight
        view.onTogglePlayPause = onTogglePlayPause
        view.onToggleFullScreen = onToggleFullScreen
        view.onVolumeDown = onVolumeDown
        view.onVolumeUp = onVolumeUp
    }
}

private final class SystemPlayerKeyCaptureNSView: NSView {
    var onLeft: (() -> Void)?
    var onRight: (() -> Void)?
    var onTogglePlayPause: (() -> Void)?
    var onToggleFullScreen: (() -> Void)?
    var onVolumeDown: (() -> Void)?
    var onVolumeUp: (() -> Void)?
    
    override var acceptsFirstResponder: Bool { true }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        activate()
    }
    
    func activate() {
        window?.makeFirstResponder(self)
    }
    
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty == false {
            super.keyDown(with: event)
            return
        }
        
        switch event.keyCode {
        case 123: // left
            onLeft?()
            return
        case 124: // right
            onRight?()
            return
        case 125: // down
            onVolumeDown?()
            return
        case 126: // up
            onVolumeUp?()
            return
        case 49: // space
            onTogglePlayPause?()
            return
        default: break
        }
        
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch key {
        case "k": onTogglePlayPause?()
        case "f": onToggleFullScreen?()
        default: super.keyDown(with: event)
        }
    }
}
#else
private struct SystemPlayerKeyboardCaptureView: UIViewRepresentable {
    let onLeft: () -> Void
    let onRight: () -> Void
    let onTogglePlayPause: () -> Void
    let onToggleFullScreen: () -> Void
    let onVolumeDown: () -> Void
    let onVolumeUp: () -> Void
    
    func makeUIView(context: Context) -> SystemPlayerKeyCaptureUIView {
        let view = SystemPlayerKeyCaptureUIView(frame: .zero)
        applyCallbacks(to: view)
        DispatchQueue.main.async {
            view.activate()
        }
        return view
    }
    
    func updateUIView(_ uiView: SystemPlayerKeyCaptureUIView, context: Context) {
        applyCallbacks(to: uiView)
        DispatchQueue.main.async {
            uiView.activate()
        }
    }
    
    private func applyCallbacks(to view: SystemPlayerKeyCaptureUIView) {
        view.onLeft = onLeft
        view.onRight = onRight
        view.onTogglePlayPause = onTogglePlayPause
        view.onToggleFullScreen = onToggleFullScreen
        view.onVolumeDown = onVolumeDown
        view.onVolumeUp = onVolumeUp
    }
}

private final class SystemPlayerKeyCaptureUIView: UIView {
    var onLeft: (() -> Void)?
    var onRight: (() -> Void)?
    var onTogglePlayPause: (() -> Void)?
    var onToggleFullScreen: (() -> Void)?
    var onVolumeDown: (() -> Void)?
    var onVolumeUp: (() -> Void)?
    
    override var canBecomeFirstResponder: Bool { true }
    
    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(handleLeft)),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(handleRight)),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(handleVolumeDown)),
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(handleVolumeUp)),
            UIKeyCommand(input: " ", modifierFlags: [], action: #selector(handleTogglePlayPause)),
            UIKeyCommand(input: "k", modifierFlags: [], action: #selector(handleTogglePlayPause)),
            UIKeyCommand(input: "f", modifierFlags: [], action: #selector(handleToggleFullScreen))
        ]
    }
    
    override func didMoveToWindow() {
        super.didMoveToWindow()
        activate()
    }
    
    func activate() {
        becomeFirstResponder()
    }
    
    @objc private func handleLeft() { onLeft?() }
    @objc private func handleRight() { onRight?() }
    @objc private func handleVolumeDown() { onVolumeDown?() }
    @objc private func handleVolumeUp() { onVolumeUp?() }
    @objc private func handleTogglePlayPause() { onTogglePlayPause?() }
    @objc private func handleToggleFullScreen() { onToggleFullScreen?() }
}
#endif
