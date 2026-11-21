import SwiftUI

@main
struct ChaiyueApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel()
    @Environment(\.scenePhase) private var phase

    init() {
        FontLibrary.shared.prepare()
        _ = FontStore.shared
        ReaderThemePreset.syncInstalled()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .onOpenURL { url in
                    Task { await app.handleOpenURL(url) }
                }
                .task {
                    #if DEBUG
                    await DebugLaunch.run(app)
                    #endif
                }
        }
        .onChange(of: phase) { _, newPhase in
            switch newPhase {
            case .background:
                app.stats.end()
                app.flush()
            case .active:
                if app.reader != nil { app.stats.begin() }
            default:
                break
            }
        }
    }
}

/// 系统在后台完成语音包下载后唤醒 App 时交回完成回调
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        VoicePackTransfer.shared.handleEvents(identifier, completion: completionHandler)
    }
}
