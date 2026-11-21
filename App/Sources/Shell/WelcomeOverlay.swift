import SwiftUI

/// 冷启动欢迎页：接在系统启动屏（同底色）之后，图标弹入 → 光环一绕化成「柴阅」字标 → 星芒一闪，
/// 随后字标继续向前放大虚化、底色溶解，主界面同时从远处放大落位，像镜头穿过字标进入书架
struct WelcomeOverlay: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @State private var shown = true
    @State private var entered = false
    @State private var leaving = false
    @State private var start = Date.distantFuture

    /// 弹入期间先停在第 0 帧，落稳后再开始过场
    private let lead = 0.25

    var body: some View {
        if shown {
            ZStack {
                Tok.bg.ignoresSafeArea()
                    .opacity(leaving ? 0 : 1)
                WelcomeIntro(start: start, ink: Tok.fg, dark: scheme == .dark)
                    .frame(width: 300)
                    .scaleEffect(entered ? (leaving ? 1.6 : 1) : 0.72)
                    .offset(y: entered ? 0 : 18)
                    .offset(y: -12)
                    .blur(radius: leaving ? 10 : 0)
                    .opacity(entered && !leaving ? 1 : 0)
            }
            .allowsHitTesting(!leaving)
            .accessibilityHidden(true)
            .task {
                #if DEBUG
                if DebugLaunch.flag("noWelcome") != nil {
                    app.launched = true
                    shown = false
                    return
                }
                #endif
                start = Date().addingTimeInterval(lead)
                withAnimation(.spring(duration: 0.6, bounce: 0.38)) { entered = true }
                var hold = lead + WelcomeScene.duration + 0.35
                #if DEBUG
                hold = DebugLaunch.flag("welcomeHold").flatMap(Double.init) ?? hold
                #endif
                try? await Task.sleep(for: .seconds(hold))
                withAnimation(.spring(duration: 0.7, bounce: 0.12)) { app.launched = true }
                withAnimation(.easeOut(duration: 0.42)) { leaving = true } completion: { shown = false }
            }
        }
    }
}
