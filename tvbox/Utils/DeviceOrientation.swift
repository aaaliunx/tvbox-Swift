#if os(iOS)
import UIKit

/// iOS 播放器方向控制工具。
/// 用于在播放器全屏时强制横屏、退出时恢复竖屏，
/// 即使系统"自动旋转"关闭也能正常横屏观看。
enum DeviceOrientation {
    static func forceLandscape() {
        apply(.landscape)
    }

    static func forceLandscapeLeft() {
        apply(.landscapeLeft)
    }

    static func forceLandscapeRight() {
        apply(.landscapeRight)
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

        // 1. iOS 16+ 系统几何更新（Info.plist 已声明全部方向，锁定方向时同样生效）。
        if #available(iOS 16.0, *) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
                print("[Orientation] requestGeometryUpdate 失败: \(error.localizedDescription)")
            }
            scene.windows.first(where: { $0.isKeyWindow })?
                .rootViewController?
                .setNeedsUpdateOfSupportedInterfaceOrientations()
        }

        // 2. 双保险：直接设置设备方向（iOS 16+ 多数系统同样生效，未签名 IPA 无审核约束）。
        //    与 requestGeometryUpdate 目标一致，不会互相冲突。
        fallbackSetDeviceOrientation(mask)

        // 3. 延迟补一次旋转落地。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }

    /// 兜底：直接设置设备方向。
    private static func fallbackSetDeviceOrientation(_ mask: UIInterfaceOrientationMask) {
        let rawValue: Int
        switch mask {
        case .portrait, .portraitUpsideDown:
            rawValue = UIInterfaceOrientation.portrait.rawValue
        case .landscapeLeft:
            rawValue = UIInterfaceOrientation.landscapeLeft.rawValue
        case .landscapeRight:
            rawValue = UIInterfaceOrientation.landscapeRight.rawValue
        default:
            // landscape：跟随当前设备朝向选择左右横屏
            if UIDevice.current.orientation == .landscapeLeft {
                rawValue = UIInterfaceOrientation.landscapeLeft.rawValue
            } else {
                rawValue = UIInterfaceOrientation.landscapeRight.rawValue
            }
        }
        UIDevice.current.setValue(rawValue, forKey: "orientation")
        UIViewController.attemptRotationToDeviceOrientation()
    }
}
#endif
