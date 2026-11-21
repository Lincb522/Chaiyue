import ReaderModels
import SwiftUI

/// 短剧播放页（设计稿 design/media-players.html「短剧」）：从封面展开 → 竖向一集一屏 → 收回封面
struct DramaPlayerScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    let launch: MediaLaunch

    @State private var model: DramaModel?
    @State private var progress: CGFloat = 0
    @State private var backX: CGFloat = 0
    @State private var flight: CGRect?
    @State private var closing = false

    /// 窗口安全区（容器忽略了安全区，GeometryReader 读不到）
    private var insets: EdgeInsets {
        let raw = AppearanceStore.keyWindow?.safeAreaInsets ?? UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
        return EdgeInsets(top: raw.top, leading: raw.left, bottom: raw.bottom, trailing: raw.right)
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.5 * Double(progress) * Double(1 - min(1, backX / max(size.width, 1))))
                    .allowsHitTesting(false)
                if let model {
                    DramaStage(model: model, insets: insets)
                        .modifier(DramaFlight(progress: progress, drag: backX, origin: flight, size: size))
                        .allowsHitTesting(progress >= 1 && !closing)
                }
                if let flight, progress < 1 {
                    DramaFlightCover(book: launch.book, progress: progress, drag: backX, origin: flight, size: size)
                        .allowsHitTesting(false)
                }
            }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear(perform: start)
        .onDisappear {
            model?.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model?.wake() } else { model?.save() }
        }
    }

    private func validFrame(_ rect: CGRect?) -> CGRect? {
        guard let rect, rect.width > 20, rect.height > 20 else { return nil }
        return UIScreen.main.bounds.intersects(rect) ? rect : nil
    }

    private func start() {
        guard model == nil else { return }
        let model = DramaModel(app: app, book: launch.book)
        model.onClose = { close() }
        model.onBackDrag = { dx, velocity, ended in backDrag(dx, velocity: velocity, ended: ended) }
        self.model = model
        flight = validFrame(launch.origin)
        UIApplication.shared.isIdleTimerDisabled = true
        Task { await model.start() }
        withAnimation(.timingCurve(0.62, 0, 0.22, 1, duration: flight == nil ? 0.46 : 0.72)) {
            progress = 1
        }
    }

    private func backDrag(_ dx: CGFloat, velocity: CGFloat, ended: Bool) {
        guard !closing else { return }
        guard ended else {
            backX = max(0, dx)
            return
        }
        let width = UIScreen.main.bounds.width
        if dx > width * 0.32 || (velocity > 700 && dx > 24) {
            close()
        } else {
            withAnimation(.snappy) { backX = 0 }
        }
    }

    private func close() {
        guard let model, !closing else { return }
        closing = true
        model.picking = false
        model.stop()
        model.onClose = nil
        model.onBackDrag = nil
        UIApplication.shared.isIdleTimerDisabled = false
        flight = validFrame(launch.origin)
        // 没有封面位置时：边缘右滑就顺势滑出，否则落回底部
        if flight == nil, backX > 0 {
            withAnimation(.timingCurve(0.3, 0.6, 0.3, 1, duration: 0.32)) {
                backX = UIScreen.main.bounds.width
            } completion: {
                app.closeMedia()
            }
            return
        }
        withAnimation(.timingCurve(0.5, 0, 0.2, 1, duration: flight == nil ? 0.34 : 0.62)) {
            progress = 0
            backX = 0
        } completion: {
            app.closeMedia()
        }
    }
}

// MARK: - 展开与收起

/// 播放页的可见区域：从封面位置放大到全屏（无位置时从底部上推）；边缘右滑时跟手右移并略缩小
private func dramaFrame(progress: CGFloat, drag: CGFloat, origin: CGRect?, size: CGSize) -> (rect: CGRect, radius: CGFloat) {
    let p = min(max(progress, 0), 1)
    let full = CGRect(origin: .zero, size: size)
    var rect: CGRect
    if let origin {
        rect = CGRect(x: origin.minX + (full.minX - origin.minX) * p,
                      y: origin.minY + (full.minY - origin.minY) * p,
                      width: origin.width + (full.width - origin.width) * p,
                      height: origin.height + (full.height - origin.height) * p)
    } else {
        rect = full.offsetBy(dx: 0, dy: size.height * (1 - p))
    }
    let t = size.width > 0 ? min(max(drag / size.width, 0), 1) : 0
    let shrink = 1 - 0.1 * t
    rect = CGRect(x: rect.minX + drag + rect.width * (1 - shrink) / 2,
                  y: rect.minY + rect.height * (1 - shrink) / 2,
                  width: rect.width * shrink,
                  height: rect.height * shrink)
    let radius = max((origin == nil ? 40 : Metrics.coverRadius + 4) * (1 - p), 42 * min(1, t * 8))
    return (rect, radius)
}

private struct DramaFlight: ViewModifier, Animatable {
    var progress: CGFloat
    var drag: CGFloat
    let origin: CGRect?
    let size: CGSize

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(progress, drag) }
        set {
            progress = newValue.first
            drag = newValue.second
        }
    }

    func body(content: Content) -> some View {
        let frame = dramaFrame(progress: progress, drag: drag, origin: origin, size: size)
        let rect = frame.rect
        let scale = size.width > 0 ? max(rect.width / size.width, rect.height / size.height) : 1
        content
            .frame(width: size.width, height: size.height)
            .scaleEffect(scale)
            .frame(width: rect.width, height: rect.height)
            .clipShape(RoundedRectangle(cornerRadius: frame.radius, style: .continuous))
            .position(x: rect.midX, y: rect.midY)
    }
}

/// 展开初段叠着原封面，过渡到模糊底与画面
private struct DramaFlightCover: View, Animatable {
    let book: Book
    var progress: CGFloat
    var drag: CGFloat
    let origin: CGRect
    let size: CGSize

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(progress, drag) }
        set {
            progress = newValue.first
            drag = newValue.second
        }
    }

    var body: some View {
        let frame = dramaFrame(progress: progress, drag: drag, origin: origin, size: size)
        BookCover(book: book, maxPixel: 600)
            .frame(width: frame.rect.width, height: frame.rect.height)
            .position(x: frame.rect.midX, y: frame.rect.midY)
            .opacity(Double(max(0, 1 - progress / 0.45)))
    }
}

// MARK: - 播放区

struct DramaStage: View {
    @Bindable var model: DramaModel
    let insets: EdgeInsets

    var body: some View {
        ZStack {
            DramaPager(model: model)
            DramaShades(model: model)
            DramaStatusOverlay(model: model)
            DramaPauseBadge(model: model)
            DramaHearts(model: model)
            DramaInfo(model: model, insets: insets)
            DramaRail(model: model, insets: insets)
            DramaProgress(model: model, insets: insets)
            DramaTopBar(model: model, insets: insets)
        }
        .background(.black)
        .sheet(isPresented: $model.picking) {
            DramaEpisodeSheet(model: model)
                .qSheet([.height(420)])
                .preferredColorScheme(.dark)
        }
    }
}
