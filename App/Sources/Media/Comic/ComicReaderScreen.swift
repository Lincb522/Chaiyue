import ReaderModels
import SwiftUI

/// 漫画阅读页（设计稿 design/media-players.html「漫画」）
struct ComicReaderScreen: View {
    @Environment(AppModel.self) private var app
    let launch: MediaLaunch

    @State private var model: ComicModel?
    @State private var progress: CGFloat = 0
    @State private var flight: CGRect?
    @State private var drag: CGFloat = 0
    @State private var closing = false
    @State private var savedBrightness: CGFloat?

    private var insets: EdgeInsets {
        let raw = AppearanceStore.keyWindow?.safeAreaInsets ?? UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
        return EdgeInsets(top: raw.top, leading: raw.left, bottom: raw.bottom, trailing: raw.right)
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let pulled = min(1, drag / max(size.width, 1))
            ZStack {
                Color.black.opacity(0.42 * progress * (1 - pulled))
                    .allowsHitTesting(false)
                if let model {
                    ComicContent(model: model, insets: insets, close: close,
                                 onEdgeDrag: { drag = $0 },
                                 onEdgeEnd: { dx, velocity in edgeEnded(dx, velocity, width: size.width) },
                                 setBrightness: setBrightness)
                        .frame(width: size.width, height: size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 44 * min(1, drag / 60), style: .continuous))
                        .scaleEffect(1 - 0.08 * pulled)
                        .offset(x: drag)
                        .modifier(ComicFlight(progress: progress, origin: flight, size: size, book: launch.book))
                        .allowsHitTesting(progress >= 1 && !closing)
                }
            }
        }
        .ignoresSafeArea()
        .onAppear(perform: start)
    }

    private func validFrame(_ rect: CGRect?) -> CGRect? {
        guard let rect, rect.width > 20, rect.height > 20 else { return nil }
        return UIScreen.main.bounds.intersects(rect) ? rect : nil
    }

    private func start() {
        guard model == nil else { return }
        let model = ComicModel(session: app.library.mediaSession(for: launch.book))
        self.model = model
        flight = validFrame(launch.origin)
        Task { await model.start() }
        withAnimation(.timingCurve(0.62, 0, 0.22, 1, duration: flight == nil ? 0.38 : 0.72)) {
            progress = 1
        }
        UIApplication.shared.isIdleTimerDisabled = app.settings.keepScreenOn
    }

    private func edgeEnded(_ dx: CGFloat, _ velocity: CGFloat, width: CGFloat) {
        if velocity >= 0, dx > width * 0.32 || velocity > 700 {
            close()
        } else {
            withAnimation(.snappy) { drag = 0 }
        }
    }

    private func setBrightness(_ value: Double) {
        if savedBrightness == nil { savedBrightness = UIScreen.main.brightness }
        UIScreen.main.brightness = CGFloat(value)
    }

    private func close() {
        guard let model, !closing else { return }
        closing = true
        withAnimation(.snappy) { model.menuVisible = false }
        model.close()
        UIApplication.shared.isIdleTimerDisabled = false
        if let savedBrightness { UIScreen.main.brightness = savedBrightness }
        withAnimation(.timingCurve(0.5, 0, 0.2, 1, duration: flight == nil ? 0.28 : 0.6)) {
            progress = 0
            drag = 0
        } completion: {
            app.closeMedia()
        }
    }
}

// MARK: - 打开动画

/// 从封面位置放大成全屏：裁切框从封面框长到全屏，内容等比铺满裁切框，封面在前半程淡出
private struct ComicFlight: ViewModifier, Animatable {
    var progress: CGFloat
    let origin: CGRect?
    let size: CGSize
    let book: Book

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let p = min(max(progress, 0), 1)
        if let origin, size.width > 0, size.height > 0 {
            let rect = CGRect(x: origin.minX * (1 - p), y: origin.minY * (1 - p),
                              width: origin.width + (size.width - origin.width) * p,
                              height: origin.height + (size.height - origin.height) * p)
            let fill = max(origin.width / size.width, origin.height / size.height)
            let scale = fill + (1 - fill) * p
            let radius = p >= 1 ? 0 : Metrics.coverRadius + (44 - Metrics.coverRadius) * p
            content
                .scaleEffect(scale)
                .frame(width: rect.width, height: rect.height)
                .overlay {
                    if p < 0.5 {
                        BookCover(book: book, maxPixel: 600)
                            .frame(width: rect.width, height: rect.height)
                            .opacity(Double(1 - p / 0.5))
                            .allowsHitTesting(false)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .position(x: rect.midX, y: rect.midY)
        } else {
            content
                .scaleEffect(0.94 + 0.06 * p)
                .opacity(Double(p))
        }
    }
}

// MARK: - 阅读区

private struct ComicContent: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: ComicModel
    let insets: EdgeInsets
    let close: () -> Void
    let onEdgeDrag: (CGFloat) -> Void
    let onEdgeEnd: (CGFloat, CGFloat) -> Void
    let setBrightness: (Double) -> Void

    @State private var showingToc = false

    var body: some View {
        ZStack {
            Tok.bg
            if model.isReady {
                ComicStage(model: model, mode: model.mode, onCenterTap: toggleMenu, onEdgeDrag: onEdgeDrag, onEdgeEnd: onEdgeEnd)
                    .id("\(model.mode.rawValue)-\(model.generation)")
                    .transition(.opacity)
            } else {
                ComicPlaceholder(model: model, close: close)
                    .onTapGesture(perform: toggleMenu)
                    .transition(.opacity)
            }
            ComicChrome(model: model, insets: insets, close: close, showingToc: $showingToc, setBrightness: setBrightness)
        }
        .animation(.easeInOut(duration: 0.24), value: model.isReady)
        .animation(.easeInOut(duration: 0.24), value: model.mode)
        .statusBarHidden(!model.menuVisible)
        .persistentSystemOverlays(model.menuVisible ? .automatic : .hidden)
        .sheet(isPresented: $showingToc) {
            let session = model.session
            TocSheet(chapters: session.chapters, current: model.current.chapter, bookUrl: model.book.bookUrl,
                     state: session.tocState,
                     onRetry: { Task { await model.retryToc() } },
                     onPick: { index in
                         showingToc = false
                         model.menuVisible = false
                         model.jump(chapter: index)
                     })
                .qSheet([.fraction(0.76), .large])
                .environment(app)
        }
    }

    private func toggleMenu() {
        withAnimation(model.menuVisible ? .easeIn(duration: 0.2) : .snappy) {
            model.menuVisible.toggle()
        }
    }
}

/// 目录或本章加载中、失败
private struct ComicPlaceholder: View {
    let model: ComicModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            if let message {
                Text(message)
                    .font(.ui(14))
                    .foregroundStyle(Tok.fg2)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .padding(.horizontal, 40)
                HStack(spacing: 12) {
                    Button(action: close) {
                        Text("返回").font(.ui(15, .medium)).foregroundStyle(Tok.fg)
                            .frame(width: 96, height: 44)
                            .background(Tok.fill2, in: Capsule())
                    }
                    .buttonStyle(.press)
                    if canRetry {
                        Button(action: retry) {
                            Text("重试").font(.ui(15, .semibold)).foregroundStyle(Tok.onAccent)
                                .frame(width: 96, height: 44)
                                .background(Tok.accent, in: Capsule())
                        }
                        .buttonStyle(.press)
                    }
                }
            } else {
                ProgressView().tint(Tok.fg3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    private var message: String? {
        let session = model.session
        switch session.tocState {
        case .failed(let text): return text
        case .ready where session.chapters.isEmpty: return "没有章节"
        case .ready:
            if case .failed(let text) = model.chapters[model.current.chapter] { return text }
            return nil
        default: return nil
        }
    }

    private var canRetry: Bool {
        if case .ready = model.session.tocState { return !model.session.chapters.isEmpty }
        return true
    }

    private func retry() {
        if case .failed = model.session.tocState {
            Task { await model.retryToc() }
        } else {
            model.jump(chapter: model.current.chapter, page: model.current.page)
        }
    }
}
