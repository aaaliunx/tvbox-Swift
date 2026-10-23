import Foundation
#if os(iOS)
import ActivityKit

/// 播放 Live Activity（灵动岛/锁屏）生命周期管理：
/// 前台启动 Activity → 播放进度更新 → 播放结束/退出销毁。
@MainActor
enum PlayerLiveActivityManager {
    /// 当前活动的 Live Activity 实例。
    static var current: Activity<PlayerActivityAttributes>? = nil

    /// 启动 Live Activity（仅前台可用；未授权/不支持时静默失败）。
    static func start(title: String, subtitle: String, coverURL: String, isLive: Bool) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // 已存在则先结束旧的，避免重复活动堆积。
        if let old = current {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
            current = nil
        }
        let attributes = PlayerActivityAttributes(title: title, coverURL: coverURL)
        let initialState = PlayerActivityAttributes.ContentState(
            title: title,
            subtitle: subtitle,
            isPlaying: true,
            isLive: isLive
        )
        do {
            current = try Activity.request(
                attributes: attributes,
                contentState: initialState,
                pushType: nil
            )
        } catch {
            current = nil
        }
    }

    /// 更新播放进度/状态（0.5s 粒度，ActivityKit 自动节流）。
    static func update(title: String, subtitle: String, progress: Double,
                       currentTime: Double, duration: Double,
                       isPlaying: Bool, isLive: Bool) {
        guard let activity = current else { return }
        let state = PlayerActivityAttributes.ContentState(
            title: title,
            subtitle: subtitle,
            progress: progress,
            currentTime: currentTime,
            duration: duration,
            isPlaying: isPlaying,
            isLive: isLive
        )
        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    /// 结束 Live Activity（播放器退出/切换内容时）。
    static func end() {
        guard let activity = current else { return }
        current = nil
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
#endif
