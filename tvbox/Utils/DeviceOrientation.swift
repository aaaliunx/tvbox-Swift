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
                print("[Orientation] requestGeometryUpdate 失败: \(error.localizedDescription)")
                // requestGeometryUpdate 失败时兜底：直接设置设备方向。
                fallbackSetDeviceOrientation(mask)
            }
        }

        scene.windows.first(where: { $0.isKeyWindow })?
            .rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()

        // iOS 16+ 成功路径也补一次 attemptRotation，确保动画落地；
        // iOS 15 及以下直接设置设备方向。
        if #unavailable(iOS 16.0) {
            fallbackSetDeviceOrientation(mask)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                UIViewController.attemptRotationToDeviceOrientation()
            }
        }
    }

    /// 兜底：直接设置设备方向（iOS 16+ 同样生效，未签名 IPA 无审核约束）。
    private static func fallbackSetDeviceOrientation(_ mask: UIInterfaceOrientationMask) {
        let rawValue: Int
        switch mask {
        case .portrait, .portraitUpsideDown:
            rawValue = UIInterfaceOrientation.portrait.rawValue
        case .landscape:
            // 跟随当前设备朝向选择左右横屏
            if UIApplication.shared.statusBarOrientation == .landscapeLeft {
                rawValue = UIInterfaceOrientation.landscapeLeft.rawValue
            } else {
                rawValue = UIInterfaceOrientation.landscapeRight.rawValue
            }
        default:
            rawValue = UIInterfaceOrientation.landscapeRight.rawValue
        }
        UIDevice.current.setValue(rawValue, forKey: "orientation")
        UIViewController.attemptRotationToDeviceOrientation()
    }
}
#endif
