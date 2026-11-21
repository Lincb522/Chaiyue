import AVKit
import ReaderModels
import ReaderServices
import SwiftUI

/// 听书播放页（设计稿 design/media-players.html「听书」）
struct AudioPlayerScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    let launch: MediaLaunch

    @State private var appeared = false
    @State private var started = false
    @State private var closing = false
    @State private var drag: CGFloat = 0
    @State private var coverFrame: CGRect = .zero
    @State private var toolFrames: [AudioTool: CGRect] = [:]
    @State private var menu: AudioTool?
    @State private var showChapters = false

    private var player: AudioBookPlayer { app.audio }
    /// 播放器里是这本书时才读它的状态（换书的第一帧还是上一本）
    private var isCurrent: Bool { player.book?.bookUrl == launch.book.bookUrl }
    private var book: Book { isCurrent ? player.book ?? launch.book : launch.book }
    private var playing: Bool { isCurrent && player.isPlaying }

    private var insets: EdgeInsets {
        let raw = AppearanceStore.keyWindow?.safeAreaInsets ?? UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
        return EdgeInsets(top: raw.top, leading: raw.left, bottom: raw.bottom, trailing: raw.right)
    }

    private var origin: CGRect? {
        guard let rect = launch.origin, rect.width > 20, rect.height > 20, UIScreen.main.bounds.intersects(rect) else { return nil }
        return rect
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let scale = 1 - min(drag / max(size.height, 1), 1) * 0.08
            let offset = appeared || origin != nil ? drag : size.height
            ZStack(alignment: .topLeading) {
                page(size)
                    .clipShape(RoundedRectangle(cornerRadius: drag > 0 ? min(44, drag * 0.5) : 0, style: .continuous))
                    .scaleEffect(scale)
                    .offset(y: offset)
                    .opacity(appeared || origin == nil ? 1 : 0)
                    .gesture(dismissDrag(size), including: menu == nil && !closing ? .all : .subviews)
                hero(size: size, scale: scale, offset: offset)
            }
        }
        .ignoresSafeArea()
        .onAppear { player.open(launch.book) }
        .sheet(isPresented: $showChapters) {
            AudioChapterSheet(player: player) { showChapters = false }
                .qSheet([.fraction(0.68), .large])
        }
    }

    // MARK: - 页面

    private func page(_ size: CGSize) -> some View {
        let side = max(160, min(size.width - 80, size.height - insets.top - insets.bottom - 470))
        return ZStack(alignment: .topLeading) {
            AudioBackdrop(book: book, image: isCurrent ? player.artwork : nil, size: size)
            VStack(spacing: 0) {
                topBar
                    .padding(.top, insets.top + 5)
                Spacer(minLength: 26)
                Color.clear
                    .frame(width: side, height: side)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frame in
                        coverFrame = frame
                        if !started, frame.width > 0 { open() }
                    }
                    .frame(maxWidth: .infinity)
                titleBlock
                    .padding(.top, 30)
                    .frame(height: 104, alignment: .top)
                AudioProgress(player: player, active: isCurrent)
                    .frame(height: 48, alignment: .top)
                controls
                    .frame(height: 74)
                tools
                    .padding(.top, 36)
                Spacer(minLength: 0)
                    .frame(maxHeight: 40)
                Color.clear.frame(height: insets.bottom + 19)
            }
            .foregroundStyle(Tok.fg)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 24)
            if let menu, let frame = toolFrames[menu] {
                menuLayer(menu, anchor: frame, size: size)
            }
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(.named(Self.space))
        .animation(.snappy, value: menu)
    }

    nonisolated private static let space = "audio.page"

    private var topBar: some View {
        ZStack {
            Text(BookText.join(book.originName, book.author))
                .font(.ui(11.5))
                .tracking(1)
                .lineLimit(1)
                .opacity(0.6)
                .padding(.horizontal, 50)
            HStack {
                Button(action: close) {
                    Image(icon: "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(chromeFill, in: Circle())
                }
                .buttonStyle(.press)
                Spacer()
                Menu {
                    if isCurrent, let session = player.session, !session.isOnShelf {
                        Button("加入书架", icon: "plus") { player.addToShelf() }
                    }
                    Button("刷新目录", icon: "arrow.clockwise") { player.refreshToc() }
                } label: {
                    Image(icon: "ellipsis")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 34, height: 34)
                        .background(chromeFill, in: Circle())
                }
                .buttonStyle(.press)
            }
        }
        .padding(.horizontal, 22)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(book.name.withoutEmoji)
                .font(.serif(22))
                .tracking(3)
                .lineLimit(1)
            Text(isCurrent ? player.chapterTitle : book.durChapterTitle ?? "")
                .font(.ui(13))
                .lineLimit(1)
                .opacity(0.62)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.25), value: player.chapterTitle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
    }

    private var controls: some View {
        let failed = isCurrent && player.error != nil
        return HStack {
            controlButton("gobackward.15", size: 24) { player.skip(-15) }
            Spacer(minLength: 0)
            controlButton("backward.end.fill", size: 22) { player.previous() }
                .opacity(player.hasPrevious ? 1 : 0.35)
            Spacer(minLength: 0)
            Button {
                if failed { player.retry() } else if isCurrent { player.toggle() } else { player.open(launch.book) }
            } label: {
                ZStack {
                    if isCurrent && player.isLoading && player.isPlaying {
                        ProgressView().tint(playInk).transition(.opacity)
                    } else {
                        Image(icon: failed ? "arrow.clockwise" : playing ? "pause.fill" : "play.fill")
                            .font(.system(size: failed ? 24 : 26, weight: .bold))
                            .offset(x: playing || failed ? 0 : 2)
                            .contentTransition(.symbolEffect(.replace.downUp))
                    }
                }
                .foregroundStyle(playInk)
                .frame(width: 74, height: 74)
                .background(playFill, in: Circle())
                .animation(.snappy, value: player.isLoading)
            }
            .buttonStyle(PressStyle(scale: 0.9))
            .sensoryFeedback(.impact(weight: .light), trigger: player.isPlaying)
            Spacer(minLength: 0)
            controlButton("forward.end.fill", size: 22) { player.next() }
                .opacity(player.hasNext ? 1 : 0.35)
            Spacer(minLength: 0)
            controlButton("goforward.15", size: 24) { player.skip(15) }
        }
        .padding(.horizontal, 22)
    }

    private func controlButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(icon: symbol)
                .font(.system(size: size, weight: .regular))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(PressStyle(scale: 0.86))
    }

    private var tools: some View {
        HStack {
            toolItem(.rate) {
                Text(AudioTool.rateText(player.rate) + "×")
                    .font(.ui(14, .bold))
                    .contentTransition(.numericText())
                    .animation(.snappy, value: player.rate)
            } caption: {
                Text("倍速")
            }
            Spacer(minLength: 0)
            toolItem(.sleep, on: player.sleep != nil) {
                Image(icon: "moon.fill").font(.system(size: 17))
            } caption: {
                SleepCaption(player: player)
            }
            Spacer(minLength: 0)
            toolItem(.chapters) {
                Image(icon: "list.bullet").font(.system(size: 17, weight: .medium))
            } caption: {
                Text("章节")
            }
            Spacer(minLength: 0)
            toolItem(.route) {
                Image(icon: "airplayaudio").font(.system(size: 17, weight: .medium))
            } caption: {
                Text("隔空")
            }
            .overlay { RoutePicker() }
        }
        .padding(.horizontal, 30)
    }

    private func toolItem(_ tool: AudioTool, on: Bool = false, @ViewBuilder icon: () -> some View,
                          @ViewBuilder caption: () -> some View) -> some View {
        Button {
            switch tool {
            case .rate, .sleep: menu = menu == tool ? nil : tool
            case .chapters: showChapters = true
            case .route: break
            }
        } label: {
            VStack(spacing: 5) {
                icon().frame(height: 20)
                caption()
                    .font(.num(10, .medium))
                    .opacity(0.8)
                    .foregroundStyle(on ? Tok.accentInk : Tok.fg)
            }
            .frame(minWidth: 44)
            .opacity(on || menu == tool ? 1 : 0.72)
        }
        .buttonStyle(.press)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { toolFrames[tool] = $0 }
    }

    // MARK: - 倍速与定时菜单

    private func menuLayer(_ tool: AudioTool, anchor: CGRect, size: CGSize) -> some View {
        ZStack(alignment: .bottomLeading) {
            (scheme == .dark ? Color(hex: 0x0A0B16, alpha: 0.35) : Color(hex: 0xF7F4EF, alpha: 0.25))
                .contentShape(Rectangle())
                .onTapGesture { menu = nil }
                .transition(.opacity)
            AudioMenu(rows: rows(for: tool)) { menu = nil }
                .padding(.leading, min(anchor.minX + 10, size.width - 168 - 16))
                .padding(.bottom, size.height - anchor.minY + 22)
                .transition(.scale(scale: 0.86, anchor: .bottomLeading).combined(with: .opacity))
        }
        .frame(width: size.width, height: size.height)
    }

    private func rows(for tool: AudioTool) -> [AudioMenu.Row] {
        if tool == .rate {
            return AudioBookPlayer.rates.map { value in
                AudioMenu.Row(title: AudioTool.rateText(value) + "×", selected: player.rate == value) { player.setRate(value) }
            }
        }
        let sleep = player.sleep
        var rows = [AudioMenu.Row(title: "本章结束", selected: sleep == .chapterEnd, dividerAfter: true) { player.setSleep(.chapterEnd) }]
        for (i, minutes) in [15, 30, 60, 90].enumerated() {
            rows.append(AudioMenu.Row(title: "\(minutes) 分钟", selected: sleep == .minutes(minutes), dividerAfter: i == 3) {
                player.setSleep(.minutes(minutes))
            })
        }
        rows.append(AudioMenu.Row(title: "关闭定时", selected: false, dimmed: true) { player.setSleep(nil) })
        return rows
    }

    // MARK: - 封面

    /// 封面不随页面一起淡入：从书架封面的位置飞到播放页，收起时飞回去
    private func hero(size: CGSize, scale: CGFloat, offset: CGFloat) -> some View {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let placed = CGRect(x: center.x + (coverFrame.minX - center.x) * scale,
                            y: center.y + (coverFrame.minY - center.y) * scale + offset,
                            width: coverFrame.width * scale, height: coverFrame.height * scale)
        let flying = !appeared && origin != nil
        let frame = flying ? origin ?? placed : placed
        let coverScale: CGFloat = flying ? 1 : showChapters ? 0.62 : playing ? 1 : 0.86
        let dark = scheme == .dark
        return AudioCoverArt(book: book, image: isCurrent ? player.artwork : nil)
            .frame(width: frame.width, height: frame.height)
            .clipShape(RoundedRectangle(cornerRadius: flying ? Metrics.coverRadius : 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: flying ? Metrics.coverRadius : 22, style: .continuous)
                    .strokeBorder(.white.opacity(dark ? 0.12 : 0), lineWidth: 0.5)
            }
            .shadow(color: dark ? .black.opacity(0.5) : Color(hex: 0x282850).opacity(0.38), radius: 22, y: 24)
            .scaleEffect(coverScale, anchor: showChapters ? .top : .center)
            .offset(y: showChapters ? -16 : 0)
            .opacity(showChapters ? 0.55 : 1)
            .position(x: frame.midX, y: frame.midY)
            .opacity(coverFrame.width > 0 ? 1 : 0)
            .animation(.spring(duration: 0.6, bounce: 0.3), value: playing)
            .animation(.soft, value: showChapters)
            .allowsHitTesting(false)
    }

    // MARK: - 开合

    private func open() {
        started = true
        withAnimation(origin == nil ? .soft : .timingCurve(0.62, 0, 0.22, 1, duration: 0.72)) { appeared = true }
    }

    private func close() {
        guard !closing else { return }
        closing = true
        menu = nil
        player.save()
        withAnimation(origin == nil ? .snappy : .timingCurve(0.5, 0, 0.2, 1, duration: 0.6)) {
            appeared = false
            if origin == nil { drag = 0 }
        } completion: {
            app.closeMedia()
        }
    }

    private func dismissDrag(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                guard !closing, value.translation.height > 0 || drag > 0 else { return }
                if drag == 0, abs(value.translation.width) > value.translation.height { return }
                drag = max(0, value.translation.height)
            }
            .onEnded { value in
                guard !closing, drag > 0 else { return }
                if value.translation.height > 140 || value.predictedEndTranslation.height > 420 {
                    close()
                } else {
                    withAnimation(.snappy) { drag = 0 }
                }
            }
    }

    // MARK: - 颜色

    private var chromeFill: Color { scheme == .dark ? .white.opacity(0.1) : Color(hex: 0x14142B, alpha: 0.06) }
    private var playFill: Color { scheme == .dark ? Color(hex: 0xF5F2EC) : Color(hex: 0x14142B) }
    private var playInk: Color { scheme == .dark ? Color(hex: 0x14142B) : Color(hex: 0xF7F4EF) }
}

enum AudioTool: Hashable {
    case rate, sleep, chapters, route

    static func rateText(_ rate: Float) -> String {
        String(format: "%g", rate)
    }
}

/// 分:秒，超过一小时带小时
func audioClock(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "--:--" }
    let total = Int(max(0, seconds).rounded(.down))
    let h = total / 3600, m = total / 60 % 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
}

// MARK: - 背景

/// 封面高斯模糊铺满，再按外观罩一层渐变
private struct AudioBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    let book: Book
    let image: UIImage?
    let size: CGSize

    var body: some View {
        ZStack {
            Tok.bg
            AudioCoverArt(book: book, image: image)
                .frame(width: size.width + 120, height: size.height + 120)
                .blur(radius: 48)
                .saturation(1.35)
                .scaleEffect(1.2)
                .frame(width: size.width, height: size.height)
                .clipped()
            LinearGradient(stops: scheme == .dark ? [
                .init(color: Color(hex: 0x0A0B16, alpha: 0.35), location: 0),
                .init(color: Color(hex: 0x0A0B16, alpha: 0.72), location: 0.6),
                .init(color: Color(hex: 0x0A0B16, alpha: 0.9), location: 1),
            ] : [
                .init(color: Color(hex: 0xF7F4EF, alpha: 0.55), location: 0),
                .init(color: Color(hex: 0xF7F4EF, alpha: 0.82), location: 0.55),
                .init(color: Color(hex: 0xF7F4EF, alpha: 0.95), location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }
}

/// 播放器取到的高清封面；没有时先用书架封面（裁成方形）
private struct AudioCoverArt: View {
    let book: Book
    let image: UIImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else {
                    BookCover(book: book, maxPixel: 600)
                        .frame(width: max(geo.size.width, geo.size.height * 120 / 172))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .animation(.easeOut(duration: 0.3), value: image != nil)
        }
    }
}

// MARK: - 进度条

/// 按住加粗并放大时间，拖动定位，松手回落
private struct AudioProgress: View {
    @Environment(\.colorScheme) private var scheme
    let player: AudioBookPlayer
    let active: Bool

    @State private var scrub: Double?
    @State private var start: Double = 0
    @State private var width: CGFloat = 1

    var body: some View {
        let duration = active ? player.duration : 0
        let value = scrub ?? (active ? player.currentTime : 0)
        let ratio = duration > 0 ? min(1, max(0, value / duration)) : 0
        let held = scrub != nil
        let dark = scheme == .dark
        VStack(spacing: held ? 10 : 8) {
            ZStack(alignment: .leading) {
                Capsule().fill(dark ? Color.white.opacity(0.18) : Color(hex: 0x14142B, alpha: 0.1))
                Capsule().fill(Tok.fg).frame(width: width * ratio)
            }
            .frame(height: held ? 8 : 4)
            .frame(height: 4)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = max(1, $0) }
            if active, let error = player.error {
                Text(error)
                    .font(.ui(11.5))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(0.7)
                    .transition(.opacity)
            } else {
                HStack {
                    Text(audioClock(value))
                    Spacer()
                    Text(duration > 0 ? "-" + audioClock(duration - value) : "--:--")
                }
                .font(.num(held ? 13 : 11, held ? .semibold : .medium))
                .opacity(held ? 0.9 : 0.55)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .padding(.vertical, -10)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    guard duration > 0 else { return }
                    if scrub == nil { start = player.currentTime }
                    scrub = min(duration, max(0, start + Double(drag.translation.width / width) * duration))
                }
                .onEnded { _ in
                    if let scrub { player.seek(to: scrub) }
                    scrub = nil
                }
        )
        .animation(.snappy, value: held)
        .sensoryFeedback(.selection, trigger: held)
    }
}

// MARK: - 工具行

private struct SleepCaption: View {
    let player: AudioBookPlayer

    var body: some View {
        if let left = player.sleepRemaining {
            Text(audioClock(left))
        } else {
            Text("定时")
        }
    }
}

/// 隔空播放：系统选择器盖在自绘图标上，只保留点按
private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .clear
        view.activeTintColor = .clear
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

/// 毛玻璃小菜单（设计稿 `.menu`）
private struct AudioMenu: View {
    struct Row: Identifiable {
        var id: String { title }
        let title: String
        let selected: Bool
        var dimmed = false
        var dividerAfter = false
        let action: () -> Void
    }

    @Environment(\.colorScheme) private var scheme
    let rows: [Row]
    let dismiss: () -> Void

    var body: some View {
        let dark = scheme == .dark
        VStack(spacing: 0) {
            ForEach(rows) { row in
                Button {
                    row.action()
                    dismiss()
                } label: {
                    HStack {
                        Text(row.title)
                        Spacer()
                        if row.selected {
                            Image(icon: "checkmark").font(.system(size: 12, weight: .bold))
                        }
                    }
                    .font(.ui(13.5, row.selected ? .semibold : .regular))
                    .opacity(row.dimmed ? 0.55 : 1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(row.selected ? (dark ? Color.white.opacity(0.1) : Color(hex: 0x14142B, alpha: 0.07)) : .clear,
                                in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressSoft)
                if row.dividerAfter {
                    Rectangle()
                        .fill(dark ? Color.white.opacity(0.12) : Color(hex: 0x14142B, alpha: 0.1))
                        .frame(height: 0.5)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
            }
        }
        .foregroundStyle(Tok.gFg)
        .padding(6)
        .frame(width: 168)
        .glassSurface(RoundedRectangle(cornerRadius: 20, style: .continuous), strong: true)
        .sensoryFeedback(.selection, trigger: rows.map(\.selected))
    }
}

// MARK: - 章节

private struct AudioChapterSheet: View {
    @Environment(\.colorScheme) private var scheme
    let player: AudioBookPlayer
    let dismiss: () -> Void

    var body: some View {
        let session = player.session
        let chapters = session?.chapters ?? []
        let current = session?.index ?? 0
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("章节").font(.serif(17)).tracking(2)
                Spacer()
                if !chapters.isEmpty {
                    Text("共 \(chapters.count) 章 · 已听 \(current) 章")
                        .font(.ui(11.5, .medium))
                        .opacity(0.5)
                }
            }
            .foregroundStyle(Tok.gFg)
            .padding(.horizontal, 20)
            .padding(.top, 30)
            .padding(.bottom, 8)
            if chapters.isEmpty {
                placeholder(session?.tocState)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(chapters.indices, id: \.self) { i in
                                row(chapters[i], index: i, current: current)
                                    .id(i)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 24)
                    }
                    .scrollIndicators(.hidden)
                    .onAppear { proxy.scrollTo(current, anchor: .center) }
                }
            }
        }
    }

    private func row(_ chapter: BookChapter, index: Int, current: Int) -> some View {
        let isCurrent = index == current
        let ink = isCurrent ? Tok.accentInk : Tok.gFg
        return Button {
            player.select(chapter: index)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Group {
                    if isCurrent {
                        ChapterBars(active: player.isPlaying)
                    } else {
                        Text(String(format: "%03d", index + 1))
                            .font(.num(11, .medium))
                            .opacity(0.4)
                    }
                }
                .frame(width: 34, alignment: .leading)
                Text(chapter.title.withoutEmoji)
                    .font(.ui(14))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isCurrent, player.duration > 0 {
                    Text("\(audioClock(player.currentTime)) / \(audioClock(player.duration))")
                        .font(.num(11))
                        .opacity(0.8)
                }
            }
            .foregroundStyle(ink)
            .padding(.vertical, 12)
            .padding(.horizontal, 2)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(scheme == .dark ? Color.white.opacity(0.08) : Color(hex: 0x14142B, alpha: 0.08))
                    .frame(height: 0.5)
            }
            .opacity(index < current ? 0.42 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.glassRow)
    }

    @ViewBuilder
    private func placeholder(_ state: ReaderSession.TocState?) -> some View {
        VStack(spacing: 14) {
            if case .failed(let message) = state {
                Text(message)
                    .font(.ui(13))
                    .foregroundStyle(Tok.gFg2)
                    .multilineTextAlignment(.center)
                Button("重试") { player.retry() }
                    .font(.ui(14, .semibold))
                    .foregroundStyle(Tok.accentInk)
            } else {
                ProgressView()
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 当前章的律动条（设计稿 `.eq`：三根 3pt 宽、最高 12pt）
private struct ChapterBars: View {
    let active: Bool

    var body: some View {
        TimelineView(.animation(paused: !active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    let rest = [0.5, 1, 0.67][i]
                    let value = active ? 0.3 + 0.7 * abs(sin((t * 1.1 + [0, 0.4, 0.75][i]) * .pi)) : rest
                    RoundedRectangle(cornerRadius: 1)
                        .frame(width: 3, height: 12 * value)
                }
            }
            .frame(height: 12, alignment: .bottom)
        }
    }
}
