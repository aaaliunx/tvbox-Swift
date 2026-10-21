#if os(iOS)
import UIKit

/// iOS 播放器方向控制工具。
/// 用于在播放器全屏时强制横屏、退出时恢复竖屏，
/// 即使系统"自动旋转"关闭也能正常横屏观看。
enum DeviceOrientation {
    static func forceLandscape() {
        apply(.landscape)
    }

    static func forcePortrait() {
        apply(.portrait)
    }

    private static func apply(_ mask: UIInterfaceOrientationMask) {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        guard let scene else { return }

        if #available(iOS 16.0, *) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
                print("[Orientation] 更新失败: \(error.localizedDescription)")
            }
        }

        scene.windows.first(where: { $0.isKeyWindow })?
            .rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()

        // iOS 15 及以下兜底：直接设置设备方向，触发旋转。
        if #unavailable(iOS 16.0) {
            let rawValue: Int
            switch mask {
            case .portrait:
                rawValue = UIInterfaceOrientation.portrait.rawValue
            default:
                rawValue = UIInterfaceOrientation.landscapeRight.rawValue
            }
            UIDevice.current.setValue(rawValue, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }
}
#endif
