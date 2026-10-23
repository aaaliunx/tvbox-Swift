import SwiftUI

// MARK: - VodCard Press Style

/// 按压缩放动画样式 - 为 VodCard 提供按压反馈效果
struct VodCardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// 视频卡片组件
struct VodCardView: View {
    /// 卡片对应的视频数据。
    let video: Movie.Video
    /// 封面加载成功回调（搜索结果同剧封面复用用）。
    var onPosterLoaded: ((URL) -> Void)? = nil
    /// 悬停状态（主要用于 macOS 悬停放大动效）。
    @State private var isHovered = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 封面图
            ZStack(alignment: .bottomLeading) {
                CachedAsyncImage(url: URL.posterURL(from: video.pic), onLoaded: onPosterLoaded) { image in
                    image
                        .resizable()
                        .aspectRatio(2/3, contentMode: .fill)
                } placeholder: {
                    placeholderImage
                        .overlay(ProgressView().tint(.white))
                }
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardRadius))
                .shadow(color: .black.opacity(0.4), radius: 6, x: 0, y: 3)
                
                // 底部渐变（保护角标文字）
                LinearGradient(
                    colors: [.black.opacity(0.75), .clear],
                    startPoint: .bottom,
                    endPoint: .center
                )
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardRadius))
                
                // 备注角标（腾讯视频式：海报底部黑底白字，如"更新至23集/全16集"）
                if !video.note.isEmpty {
                    Text(video.note)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.45))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(.bottom, 6)
                        .padding(.leading, 8)
                }
            }
            // 悬停缩放只增强视觉反馈，不影响点击命中区域。
            .scaleEffect(isHovered ? 1.05 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
            
            // 标题 + 副标题（腾讯视频式）
            VStack(alignment: .leading, spacing: 3) {
                Text(video.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppTheme.textPrimary)
                    .lineLimit(1)
                
                if !video.type.isEmpty {
                    Text(video.type)
                        .font(.system(size: 10))
                        .foregroundColor(AppTheme.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 2)
        }
        #if os(iOS)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        #endif
    }
    
    /// 海报占位图，避免图片加载失败导致卡片高度塌陷。
    private var placeholderImage: some View {
        RoundedRectangle(cornerRadius: AppTheme.cardRadius)
            .fill(AppTheme.divider)
            .aspectRatio(2/3, contentMode: .fill)
            .overlay(
                Image(systemName: "film.fill")
                    .font(.system(size: 30))
                    .foregroundColor(AppTheme.textSecondary.opacity(0.5))
            )
    }
}
