import SwiftUI

/// 根视图：导航栈（标签页为根，推入的页面盖住标签栏）+ 阅读器覆盖层 + 灵动岛提示
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Namespace private var hero

    var body: some View {
        @Bindable var app = app
        ZStack {
            NavigationStack(path: $app.path) {
                MainTabsView()
                    .toolbar(.hidden, for: .navigationBar)
                    .navigationDestination(for: Route.self) { route in
                        RouteDestination(route: route)
                            .toolbar(.hidden, for: .navigationBar)
                    }
            }
            .environment(\.heroNamespace, hero)

            ReaderLayer()
                .zIndex(2)

            MediaLayer()
                .zIndex(2.5)

            WelcomeOverlay()
                .zIndex(3)
        }
        .tint(Tok.accentInk)
        // 朗读胶囊展开时隐藏状态栏，胶囊两侧不露出时间和电量图标
        .statusBarHidden(IslandOverlay.hasIsland && (app.speech.isActive && app.reader == nil || app.audio.isActive && app.media == nil))
        .task {
            app.appearance.apply()
            IslandWindow.install(app)
        }
    }
}

/// 阅读器覆盖层：单独观察 `app.reader`，开合阅读器时不重算导航栈。
/// 常驻一个透明底：iOS 26 上初始为空的视图盖在导航栈（UIKit 平台视图）之上时，之后插入的内容不会显示
private struct ReaderLayer: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack {
            Color.clear
                .allowsHitTesting(false)
            if let launch = app.reader {
                ReaderContainer(launch: launch)
                    .id(launch.id)
            }
        }
        .ignoresSafeArea()
    }
}

/// 三个标签页与搜索页：切换时交叉淡入淡出（原型 160ms 线性），访问过的标签保留滚动位置
struct MainTabsView: View {
    @Environment(AppModel.self) private var app
    @State private var visited: Set<MainTab> = [.shelf]

    var body: some View {
        let barHidden = app.tabBarHidden || !app.launched
        ZStack {
            ScreenBackground()
            Group {
                ForEach(MainTab.allCases) { tab in
                    if visited.contains(tab) {
                        let shown = app.tab == tab && !app.searching
                        page(tab)
                            .opacity(shown ? 1 : 0)
                            .allowsHitTesting(shown)
                            .accessibilityHidden(!shown)
                    }
                }
                if app.searching {
                    SearchScreen()
                        .transition(.opacity)
                }
            }
            .scaleEffect(app.launched ? 1 : 0.9)
            .opacity(app.launched ? 1 : 0)
        }
        .overlay(alignment: .bottom) {
            TabBar()
                .offset(y: barHidden ? 130 : 0)
                .opacity(barHidden ? 0 : 1)
                .allowsHitTesting(!barHidden)
                .animation(.snappy, value: app.tabBarHidden)
                .animation(.spring(duration: 0.6, bounce: 0.22).delay(0.12), value: app.launched)
        }
        .animation(.linear(duration: 0.16), value: app.tab)
        .animation(.linear(duration: 0.16), value: app.searching)
        .onChange(of: app.tab, initial: true) { _, tab in visited.insert(tab) }
    }

    @ViewBuilder
    private func page(_ tab: MainTab) -> some View {
        switch tab {
        case .shelf: ShelfScreen()
        case .explore: ExploreScreen()
        case .me: MeScreen()
        }
    }
}

struct RouteDestination: View {
    let route: Route

    var body: some View {
        switch route {
        case .detail(let input): DetailScreen(input: input)
        case .sources: SourcesScreen()
        case .replaceRules: ReplaceRulesScreen()
        case .tocRules: TocRulesScreen()
        case .cache: CacheScreen()
        case .reading: ReadingSettingsScreen()
        case .fonts: FontsScreen()
        case .readerThemes: ReaderThemesScreen()
        case .readerThemeEditor(let id): ReaderThemeEditorScreen(id: id)
        case .speech: SpeechSettingsScreen()
        case .backup: BackupScreen()
        case .about: AboutScreen()
        case .exploreList(let sourceUrl, let url, let title): ExploreListScreen(sourceUrl: sourceUrl, url: url, title: title)
        case .sourceEditor(let url): SourceEditorScreen(url: url)
        }
    }
}
