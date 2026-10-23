import WidgetKit
import SwiftUI
import ActivityKit

/// 播放 Live Activity Widget：切后台后标题/封面/进度显示在灵动岛与锁屏。
@main
struct PlayerLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        PlayerLiveActivityWidget()
    }
}

struct PlayerLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PlayerActivityAttributes.self) { context in
            // 锁屏 / 待机横向通知栏横幅
            LockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                // 灵动岛展开态
                DynamicIslandExpandedView(context: context)
            } compactLeading: {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.orange)
                    .frame(width: 24, height: 24)
            } compactTrailing: {
                if context.state.isLive {
                    Text("直播")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                } else {
                    Text(progressPercent(context.state.progress))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                }
            } minimal: {
                Image(systemName: context.state.isPlaying ? "play.fill" : "pause.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.orange)
            }
        }
    }

    private func progressPercent(_ p: Double) -> String {
        let percent = min(max(p, 0), 1) * 100
        return "\(Int(percent))%"
    }
}

// MARK: - 锁屏横幅

private struct LockScreenView: View {
    let context: ActivityViewContext<PlayerActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 28))
                .foregroundColor(.orange)
                .frame(width: 44, height: 44)
                .background(Color.orange.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text(context.state.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(context.state.subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: context.state.isPlaying ? "play.fill" : "pause.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.secondary)
        }
        .padding(16)
        .activityBackgroundTint(Color.black.opacity(0.6))
        .activitySystemActionForegroundColor(.white)
    }
}

// MARK: - 灵动岛展开态

private struct DynamicIslandExpandedView: View {
    let context: ActivityViewContext<PlayerActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.orange)

                Text(context.state.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(context.state.isPlaying ? "播放中" : "已暂停")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            // 进度条（直播显示"直播中"标识）
            if context.state.isLive {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
                    Text("直播中")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                ProgressView(value: min(max(context.state.progress, 0), 1))
                    .tint(.orange)
                HStack {
                    Text(formatTime(context.state.currentTime))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(formatTime(context.state.duration))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}
