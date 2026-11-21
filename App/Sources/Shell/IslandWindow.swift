import SwiftUI

/// 灵动岛提示与朗读胶囊所在的独立透明窗口：盖在 sheet、全屏弹层和状态栏图标之上。
/// 只在提示与朗读胶囊的区域接收点按，其余点按穿透到下面的窗口（键盘仍可点）
@MainActor
enum IslandWindow {
    private static var window: PassthroughWindow?
    private static var host: UIViewController?
    private static var observer: NSObjectProtocol?

    /// 高于常见 sheet / 键盘容器（约 1e7），点按仍靠 PassthroughWindow 穿透
    private static let floor = UIWindow.Level(rawValue: 10_000_100)

    static func install(_ app: AppModel) {
        #if DEBUG
        if DebugLaunch.flag("noIslandWindow") != nil { return }
        #endif
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let window = PassthroughWindow(windowScene: scene)
        let host = UIHostingController(rootView: IslandOverlay().environment(app))
        host.view.backgroundColor = .clear
        host.view.frame = window.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // 不设 rootViewController：有根控制器的高层级窗口会接管状态栏的显示与隐藏
        window.addSubview(host.view)
        window.backgroundColor = .clear
        window.isHidden = false
        self.window = window
        self.host = host
        raise()
        observe()
        app.appearance.apply()
    }

    /// 每次出提示或场景里出现新窗口时抬到最前，避免后弹出的 sheet 盖住
    static func raise() {
        guard let window, let scene = window.windowScene else { return }
        window.windowLevel = overlayLevel(in: scene)
        window.isHidden = false
    }

    private static func overlayLevel(in scene: UIWindowScene) -> UIWindow.Level {
        let skip: Set<String> = [
            "UIRemoteKeyboardWindow",
            "UITextEffectsWindow",
            "UIRemoteInputViewHostWindow",
            "UIKeyboardSizingView",
        ]
        let top = scene.windows
            .filter { $0 !== window && !skip.contains(String(describing: type(of: $0))) }
            .map(\.windowLevel.rawValue)
            .max() ?? 0
        return .init(rawValue: max(floor.rawValue, top + 1))
    }

    private static func observe() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UIWindow.didBecomeVisibleNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { raise() }
        }
    }
}

/// 灵动岛窗口里可点按的区域（全局坐标），由 IslandOverlay 上报
@MainActor
final class IslandHitArea {
    static let shared = IslandHitArea()
    var live: CGRect?
    /// 按提示 id 记录：新提示出现时旧提示还在做移除动画
    var toasts: [AnyHashable: CGRect] = [:]

    func contains(_ point: CGPoint) -> Bool {
        live?.contains(point) == true || toasts.values.contains { $0.contains(point) }
    }
}

final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard IslandHitArea.shared.contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }
}
