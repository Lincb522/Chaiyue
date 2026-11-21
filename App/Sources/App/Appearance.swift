import Observation
import SwiftUI
import UIKit

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "自动"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var style: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }
}

/// 外观：跟随系统 / 浅色 / 深色。通过窗口的 `overrideUserInterfaceStyle` 生效，弹层与系统控件一起切换；
/// 切换时从触点展开圆形揭示新外观（原型 `Q.reveal`）
@Observable
final class AppearanceStore {
    private static let key = "appearance"
    private(set) var mode: AppearanceMode

    init() {
        mode = AppearanceMode(rawValue: UserDefaults.standard.string(forKey: Self.key) ?? "") ?? .system
    }

    /// `origin` 为窗口坐标中的触点
    func set(_ newMode: AppearanceMode, origin: CGPoint? = nil) {
        guard newMode != mode else { return }
        mode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: Self.key)
        guard let window = Self.keyWindow else {
            apply()
            return
        }
        let before = window.traitCollection.userInterfaceStyle
        let after = newMode == .system ? (window.windowScene?.traitCollection.userInterfaceStyle ?? before) : newMode.style
        if before == after || UIAccessibility.isReduceMotionEnabled {
            apply()
            return
        }
        CircularReveal.perform(in: window, origin: origin) { self.apply() }
    }

    /// 恢复备份后重新读取
    func reload() {
        let stored = AppearanceMode(rawValue: UserDefaults.standard.string(forKey: Self.key) ?? "") ?? .system
        guard stored != mode else { return }
        mode = stored
        apply()
    }

    static let defaultsKey = key

    /// 切到指定的深浅外观（阅读器「夜间/日间」、选择另一种外观的阅读主题时调用）
    func force(_ scheme: ColorScheme, origin: CGPoint? = nil) {
        set(scheme == .dark ? .dark : .light, origin: origin)
    }

    func apply() {
        for scene in UIApplication.shared.connectedScenes {
            guard let scene = scene as? UIWindowScene else { continue }
            for window in scene.windows {
                window.overrideUserInterfaceStyle = mode.style
            }
        }
    }

    static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }
}

enum CircularReveal {
    static func perform(in window: UIWindow, origin: CGPoint?, change: () -> Void) {
        guard let snapshot = window.snapshotView(afterScreenUpdates: false) else {
            change()
            return
        }
        snapshot.isUserInteractionEnabled = false
        window.addSubview(snapshot)
        change()

        let bounds = window.bounds
        let center = origin ?? CGPoint(x: bounds.midX, y: 30)
        let radius = hypot(max(center.x, bounds.width - center.x), max(center.y, bounds.height - center.y)) + 8
        let mask = CAShapeLayer()
        mask.fillRule = .evenOdd
        mask.frame = bounds
        let start = holePath(bounds, center: center, radius: 0.1)
        let end = holePath(bounds, center: center, radius: radius)
        mask.path = end
        snapshot.layer.mask = mask

        CATransaction.begin()
        CATransaction.setCompletionBlock { snapshot.removeFromSuperview() }
        let animation = CABasicAnimation(keyPath: "path")
        animation.fromValue = start
        animation.toValue = end
        animation.duration = 0.68
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.2, 1)
        mask.add(animation, forKey: "reveal")
        CATransaction.commit()
    }

    private static func holePath(_ rect: CGRect, center: CGPoint, radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addRect(rect)
        path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        return path
    }
}

/// 记录按钮在窗口中的位置，作为圆形揭示的起点
struct WindowFrameReader: ViewModifier {
    @Binding var frame: CGRect

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
    }
}

extension View {
    func readFrame(_ frame: Binding<CGRect>) -> some View {
        modifier(WindowFrameReader(frame: frame))
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
