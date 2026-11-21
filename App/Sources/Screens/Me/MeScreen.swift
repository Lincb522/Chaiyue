import AVFoundation
import ReaderModels
import SwiftUI

/// 我的（原型 `.view-me`）：阅读统计与本周柱状图，下面三组设置入口。每次切到这一页数字重新滚动、柱子重新长出
struct MeScreen: View {
    @Environment(AppModel.self) private var app
    @State private var tracker = ScrollTracker()
    @State private var scrolled = false
    @State private var replay = 0
    @State private var cacheSize: Int64?

    var body: some View {
        let visible = app.tab == .me && !app.searching
        ZStack(alignment: .top) {
            ScreenBackground()
            MeAmbient(tracker: tracker)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        LargeTitle(title: "我的").id("top")
                        StatsRow(replay: replay)
                        WeekChart(replay: replay)
                        CardGroup {
                            navRow("square.stack.3d.up", "书源", value: "\(app.library.sources.sources.count)", route: .sources)
                            navRow("wand.and.stars", "替换净化", value: "\(app.library.replaceRules.rules.count)", route: .replaceRules)
                            VoiceRow()
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        CardGroup {
                            navRow("icloud", "备份与同步", value: BackupClock.lastText, route: .backup)
                            CacheRow(size: $cacheSize)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        CardGroup {
                            AppearanceRow()
                            navRow("Aa", "阅读设置", value: nil, route: .reading)
                            navRow("paintpalette", "阅读主题", value: ReaderThemeStore.shared.theme(app.settings.customTheme)?.name ?? "内置", route: .readerThemes)
                            navRow("info.circle", "关于", value: nil, route: .about)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                    }
                }
                .scrollIndicators(.hidden)
                .contentMargins(.top, 6, for: .scrollContent)
                .contentMargins(.bottom, 124, for: .scrollContent)
                .track(tracker)
                .trackScroll($scrolled)
                .onReceive(NotificationCenter.default.publisher(for: .scrollToTop)) { note in
                    guard note.object as? MainTab == .me else { return }
                    withAnimation(.soft) { proxy.scrollTo("top", anchor: .top) }
                }
            }
            CompactHeader(title: "我的", visible: scrolled)
        }
        .onChange(of: visible, initial: true) { _, shown in
            guard shown else { return }
            replay += 1
            Task { cacheSize = await CacheRow.measure(app) }
        }
    }

    private func navRow(_ icon: String, _ title: String, value: String?, route: Route) -> some View {
        Button {
            app.push(route)
        } label: {
            SettingRow(icon: icon, title: title) {
                if let value { Text(value) }
            }
        }
        .buttonStyle(.row)
    }
}

private struct MeAmbient: View {
    let tracker: ScrollTracker
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        AmbientGlow(first: Color(hex: dark ? 0x3A2A1F : 0xC98F66), second: Color(hex: dark ? 0x20262A : 0x7896A5),
                    opacity: dark ? 0.7 : 0.9)
            .offset(y: -min(tracker.offset, 500) * 0.4)
            .ignoresSafeArea()
    }
}

// MARK: - 统计

private struct StatsRow: View {
    let replay: Int
    @Environment(AppModel.self) private var app

    var body: some View {
        let finished = app.library.shelf.books.filter(\.isFinished).count
        HStack(alignment: .top, spacing: 0) {
            stat(Double(app.stats.todayMinutes), decimals: 0, unit: "分钟", label: "今日", index: 0)
            stat(app.stats.weekHours, decimals: 1, unit: "小时", label: "本周", index: 1)
            stat(Double(finished), decimals: 0, unit: "本", label: "读完", index: 2)
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
    }

    private func stat(_ value: Double, decimals: Int, unit: String, label: String, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                CountUp(value: value, decimals: decimals, replay: replay, delay: Double(index) * 0.08)
                    .font(.system(size: 42, weight: .light))
                    .monospacedDigit()
                    .tracking(-1.2)
                    .foregroundStyle(Tok.fg)
                Text(unit).font(.ui(13)).foregroundStyle(Tok.fg2)
            }
            Text(label).font(.ui(12)).foregroundStyle(Tok.fg3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 从 0 滚到目标值（原型 Q.countTo）
private struct CountUp: View {
    let value: Double
    let decimals: Int
    let replay: Int
    let delay: Double
    @State private var shown: Double = 0

    var body: some View {
        CountingText(value: shown, decimals: decimals)
            .onChange(of: replay, initial: true) { _, _ in
                var reset = Transaction()
                reset.disablesAnimations = true
                withTransaction(reset) { shown = 0 }
                Task {
                    try? await Task.sleep(for: .milliseconds(30))
                    withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 1.1).delay(delay)) { shown = value }
                }
            }
            .onChange(of: value) { _, newValue in
                withAnimation(.snappy) { shown = newValue }
            }
    }
}

private struct CountingText: View, Animatable {
    var value: Double
    let decimals: Int

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(decimals == 0 ? "\(Int(value.rounded()))" : String(format: "%.\(decimals)f", value))
    }
}

/// 本周每天的阅读分钟（原型 `.me-week`）：今天明黄，没读的日子只画一个空心短条
private struct WeekChart: View {
    let replay: Int
    @Environment(AppModel.self) private var app
    @State private var grown = false

    private static let days = Array("一二三四五六日")

    var body: some View {
        let minutes = app.stats.weekMinutes
        let today = app.stats.todayIndex
        let top = max(minutes.max() ?? 0, 1)
        HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { index in
                let value = minutes[index]
                VStack(spacing: 8) {
                    GeometryReader { proxy in
                        let fraction = value > 0 ? max(0.08, Double(value) / Double(top)) : 0.08
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(value == 0 ? Color.clear : (index == today ? Tok.accent : Tok.fill2))
                                .overlay {
                                    if value == 0 {
                                        RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Tok.fill2, lineWidth: 1)
                                    }
                                }
                                .frame(width: 8, height: proxy.size.height * fraction)
                                .scaleEffect(x: 1, y: grown ? 1 : 0.001, anchor: .bottom)
                                .animation(.soft.delay(0.12 + Double(index) * 0.045), value: grown)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    Text(String(Self.days[index]))
                        .font(.ui(11, index == today ? .semibold : .regular))
                        .foregroundStyle(index == today ? Tok.fg : Tok.fg3)
                }
                .frame(width: 26)
                if index < 6 { Spacer(minLength: 0) }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .frame(height: 128)
        .cardSurface()
        .padding(.horizontal, 16)
        .padding(.top, 24)
        .padding(.bottom, 6)
        .onChange(of: replay, initial: true) { _, _ in
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) { grown = false }
            Task {
                try? await Task.sleep(for: .milliseconds(30))
                grown = true
            }
        }
    }
}

// MARK: - 行

/// 朗读：直接在菜单里换语音（原型 popover）
private struct VoiceRow: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let settings = app.settings
        let voices = app.voices.voices
        let engines = app.library.httpTTS.enabledEngines
        let engine = app.selectedEngine
        let local = app.usesLocalVoice
        let system = engine == nil && !local
        let name = app.voiceName
        Menu {
            Button("朗读设置", icon: "slider.horizontal.3") { app.push(.speech) }
            Divider()
            if app.localVoiceReady {
                Section("本地神经语音") {
                    let speaker = settings.localVoice >= 0 ? settings.localVoice : LocalVoice.defaultSpeaker
                    option(LocalVoice.name(of: speaker), selected: local) {
                        settings.speechEngine = nil
                        settings.localVoice = speaker
                    }
                }
            }
            if !engines.isEmpty {
                Section("在线朗读") {
                    ForEach(engines) { tts in
                        option(tts.name.isEmpty ? "未命名" : tts.name.withoutEmoji, selected: engine?.id == tts.id) {
                            settings.speechEngine = tts.id
                        }
                    }
                }
            }
            Menu {
                option("默认", selected: system && settings.speechVoice == nil) {
                    settings.speechVoice = nil
                    settings.speechEngine = nil
                    settings.localVoice = -1
                }
                ForEach(voices) { voice in
                    option(voice.name, selected: system && settings.speechVoice == voice.id) {
                        settings.speechVoice = voice.id
                        settings.speechEngine = nil
                        settings.localVoice = -1
                    }
                }
            } label: {
                Label(system ? "系统语音 · \(name)" : "系统语音", icon: system ? "checkmark" : "waveform")
            }
        } label: {
            SettingRow(icon: "headphones", title: "朗读") {
                RollingText(text: name)
            }
        }
        .menuOrder(.fixed)
        .task { app.voices.load() }
    }

    private func option(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            app.applyVoiceChange()
        } label: {
            if selected { Label(title, icon: "checkmark") } else { Text(title) }
        }
    }
}

/// 缓存：菜单里直接清除（原型 popover），或进入缓存管理
private struct CacheRow: View {
    @Binding var size: Int64?
    @Environment(AppModel.self) private var app

    var body: some View {
        Menu {
            Button("清除缓存", icon: "trash", role: .destructive) {
                Task { await clear() }
            }
            Button("缓存管理", icon: "internaldrive") { app.push(.cache) }
        } label: {
            SettingRow(icon: "internaldrive", title: "缓存") {
                RollingText(text: size.map(Formats.size) ?? " ")
            }
        }
    }

    static func measure(_ app: AppModel) async -> Int64 {
        let store = app.library.chapterStore
        let chapters = await Task.detached(priority: .utility) { store.totalSize() }.value
        return chapters + (await app.library.images.totalSize())
    }

    private func clear() async {
        let freed = await Self.measure(app)
        let store = app.library.chapterStore
        await Task.detached(priority: .userInitiated) { store.clearAll() }.value
        await app.library.images.clear()
        ImagePipeline.shared.clearMemory()
        size = 0
        app.island.show("trash", "已清除 \(Formats.size(freed))", danger: true)
    }
}

/// 外观三段（原型 `.ap-seg`）：从点中的那一段圆形揭示新外观
private struct AppearanceRow: View {
    @Environment(AppModel.self) private var app
    @Namespace private var ns
    @State private var frames: [AppearanceMode: CGRect] = [:]

    var body: some View {
        let mode = app.appearance.mode
        SettingRow(icon: "circle.lefthalf.filled", title: "外观", chevron: false) {
            HStack(spacing: 0) {
                ForEach(AppearanceMode.allCases) { item in
                    let on = item == mode
                    Button {
                        guard !on else { return }
                        UISelectionFeedbackGenerator().selectionChanged()
                        app.appearance.set(item, origin: frames[item]?.center)
                    } label: {
                        Text(item.title)
                            .font(.ui(13, on ? .semibold : .regular))
                            .foregroundStyle(on ? Tok.fg : Tok.fg2)
                            .frame(width: 50, height: 28)
                            .background {
                                if on {
                                    Capsule()
                                        .fill(Tok.segBg)
                                        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                                        .matchedGeometryEffect(id: "appearance", in: ns)
                                }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .readFrame(Binding(get: { frames[item] ?? .zero }, set: { frames[item] = $0 }))
                }
            }
            .padding(3)
            .background(Tok.fill, in: Capsule())
            .padding(.trailing, -4)
            .animation(.snappy, value: mode)
        }
    }
}

/// 最近一次备份的时间（备份页写入）
enum BackupClock {
    static let key = "backup.lastTime"

    static var last: Date? {
        let value = UserDefaults.standard.double(forKey: key)
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }

    static var lastText: String? { last.map { Formats.relative($0) } }

    static func mark() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: key)
    }
}
