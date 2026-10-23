import Foundation
#if os(iOS)
import ActivityKit
#endif

/// 灵动岛 / 锁屏 Live Activity 的播放状态属性。
/// 该文件同时被主 App target 与 tvboxLiveActivity（Widget Extension）target 编译，
/// 保证两端 ActivityAttributes 类型一致。
#if os(iOS)
struct PlayerActivityAttributes: ActivityAttributes {
    /// 播放中可变状态（Activity 内容每次更新替换）。
    public struct ContentState: Codable, Hashable {
        /// 显示标题。
        var title: String = ""
        /// 副标题（来源/频道等）。
        var subtitle: String = ""
        /// 播放进度 0...1（直播为 0）。
        var progress: Double = 0
        /// 当前播放秒数。
        var currentTime: Double = 0
        /// 总时长秒数（直播为 0）。
        var duration: Double = 0
        /// 是否播放中。
        var isPlaying: Bool = true
        /// 是否直播。
        var isLive: Bool = false
    }

    /// 静态属性（创建 Activity 时固定）。
    var title: String = ""
    var coverURL: String = ""
}
#endif
