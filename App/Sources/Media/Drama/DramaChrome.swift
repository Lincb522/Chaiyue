import SwiftUI

// 设计稿按底部安全区 34pt 排版，`foot` 为实际底部安全区（无底部安全区的机型留 20）

private func footInset(_ insets: EdgeInsets) -> CGFloat { max(insets.bottom, 20) }
private func topInset(_ insets: EdgeInsets) -> CGFloat { max(insets.top, 20) }

extension View {
    /// 设计稿 `.glass-d`：画面上的深色毛玻璃
    @ViewBuilder
    func dramaGlass<S: InsettableShape>(_ shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self.background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(.white.opacity(0.12))
                }
            }
            .overlay { shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5) }
        }
    }

    func dramaTextShadow(_ radius: CGFloat = 2) -> some View {
        shadow(color: .black.opacity(0.5), radius: radius, y: 1)
    }
}

enum DramaTime {
    static func text(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds : 0))
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    static func speed(_ value: Float) -> String {
        value == value.rounded() ? "\(Int(value))×" : String(format: "%g×", value)
    }
}

// MARK: - 压暗

struct DramaShades: View {
    let model: DramaModel

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 130)
            Spacer(minLength: 0)
            LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .top, endPoint: .bottom)
                .frame(height: 330)
        }
        .opacity(model.dragging ? 0 : 1)
        .animation(.easeOut(duration: 0.2), value: model.dragging)
        .allowsHitTesting(false)
    }
}

// MARK: - 顶部

struct DramaTopBar: View {
    let model: DramaModel
    let insets: EdgeInsets

    var body: some View {
        ZStack(alignment: .top) {
            if model.boosting {
                HStack(spacing: 3) {
                    Image(icon: "forward.fill").font(.system(size: 9, weight: .bold))
                    Text("2×").font(.num(12, .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .dramaGlass(Capsule())
                .padding(.top, 5)
                .transition(.scale(scale: 0.7).combined(with: .opacity))
            }
            HStack {
                Button { model.onClose?() } label: {
                    Image(icon: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .dramaGlass(Circle(), interactive: true)
                }
                .buttonStyle(.press)
                .opacity(model.dragging ? 0 : 1)
                .allowsHitTesting(!model.dragging)
                Spacer()
            }
        }
        .padding(.top, topInset(insets) + 5)
        .padding(.leading, 16)
        .padding(.trailing, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeOut(duration: 0.2), value: model.dragging)
        .animation(.snappy, value: model.boosting)
    }
}

// MARK: - 左下信息

struct DramaInfo: View {
    let model: DramaModel
    let insets: EdgeInsets

    var body: some View {
        let book = model.session.book
        let intro = book.displayIntro?
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        VStack(alignment: .leading, spacing: 0) {
            Text(book.name.withoutEmoji)
                .font(.serif(17))
                .tracking(1.5)
                .lineLimit(1)
                .dramaTextShadow(3)
            if model.count > 0 {
                Text("第 \(model.index + 1) 集 · 共 \(model.count) 集")
                    .font(.num(11.5, .semibold))
                    .contentTransition(.numericText())
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .dramaGlass(Capsule())
                    .padding(.top, 7)
            }
            if let intro, !intro.isEmpty {
                Text(intro)
                    .font(.ui(12.5))
                    .lineSpacing(4)
                    .lineLimit(2)
                    .opacity(0.85)
                    .dramaTextShadow(3)
                    .padding(.top, 8)
            }
        }
        .foregroundStyle(.white)
        .padding(.leading, 18)
        .padding(.trailing, 78)
        .padding(.bottom, footInset(insets) + 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .opacity(model.dragging || model.scrub != nil ? 0 : 1)
        .animation(.easeOut(duration: 0.2), value: model.dragging || model.scrub != nil)
        .animation(.snappy, value: model.index)
        .allowsHitTesting(false)
    }
}

// MARK: - 右栏

struct DramaRail: View {
    let model: DramaModel
    let insets: EdgeInsets

    var body: some View {
        let hidden = model.dragging || model.scrub != nil
        VStack(spacing: 20) {
            item("选集") {
                DramaEpisodesIcon()
                    .stroke(.white, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                    .frame(width: 20, height: 20)
            } action: {
                model.picking = true
            }
            item("倍速") {
                Text(DramaTime.speed(model.speed))
                    .font(.num(model.speed == model.speed.rounded() ? 13 : 12, .bold))
                    .contentTransition(.numericText())
            } action: {
                UISelectionFeedbackGenerator().selectionChanged()
                withAnimation(.snappy) { model.cycleSpeed() }
            }
            item("书架") {
                ZStack {
                    if model.onShelf {
                        DramaCheckIcon()
                            .stroke(.white, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                            .transition(.scale(scale: 0.3).combined(with: .opacity))
                    } else {
                        DramaPlusIcon()
                            .stroke(.white, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                            .transition(.scale(scale: 0.3).combined(with: .opacity))
                    }
                }
                .frame(width: 20, height: 20)
                .animation(.bouncy, value: model.onShelf)
            } action: {
                model.addToShelf()
            }
        }
        .padding(.trailing, 12)
        .padding(.bottom, footInset(insets) + 116)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .opacity(hidden ? 0 : 1)
        .allowsHitTesting(!hidden)
        .animation(.easeOut(duration: 0.2), value: hidden)
    }

    private func item<Icon: View>(_ title: String, @ViewBuilder icon: () -> Icon, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                icon()
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .dramaGlass(Circle(), interactive: true)
                Text(title)
                    .font(.ui(11, .semibold))
                    .foregroundStyle(.white)
                    .dramaTextShadow()
            }
        }
        .buttonStyle(.press)
    }
}

/// 设计稿「选集」图标：圆角屏幕上方一道横线
struct DramaEpisodesIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 20
        var path = Path(roundedRect: CGRect(x: 3 * s, y: 6 * s, width: 14 * s, height: 11 * s), cornerRadius: 2.5 * s)
        path.move(to: CGPoint(x: 5.5 * s, y: 3.5 * s))
        path.addLine(to: CGPoint(x: 14.5 * s, y: 3.5 * s))
        return path
    }
}

struct DramaPlusIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 20
        var path = Path()
        path.move(to: CGPoint(x: 10 * s, y: 4 * s))
        path.addLine(to: CGPoint(x: 10 * s, y: 16 * s))
        path.move(to: CGPoint(x: 4 * s, y: 10 * s))
        path.addLine(to: CGPoint(x: 16 * s, y: 10 * s))
        return path
    }
}

struct DramaCheckIcon: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 20
        var path = Path()
        path.move(to: CGPoint(x: 4.5 * s, y: 10.5 * s))
        path.addLine(to: CGPoint(x: 8.3 * s, y: 14.2 * s))
        path.addLine(to: CGPoint(x: 15.5 * s, y: 6 * s))
        return path
    }
}

// MARK: - 进度

struct DramaProgress: View {
    let model: DramaModel
    let insets: EdgeInsets
    @State private var base: Double?

    var body: some View {
        let scrubbing = model.scrub != nil
        let foot = footInset(insets)
        let loading = model.count > 0 && model.phase == .loading
            || model.session.tocState == .loading
            || model.phase == .ready && model.buffering && !model.paused
        GeometryReader { geo in
            let width = geo.size.width - (scrubbing ? 36 : 0)
            VStack(spacing: 14) {
                if let scrub = model.scrub {
                    HStack(spacing: 0) {
                        Text(DramaTime.text(scrub * model.duration))
                        Text(" / \(DramaTime.text(model.duration))").fontWeight(.medium).opacity(0.5)
                    }
                    .font(.num(22, .bold))
                    .tracking(1)
                    .foregroundStyle(.white)
                    .dramaTextShadow(4)
                    .transition(.opacity.combined(with: .offset(y: 8)))
                }
                track(width: width, scrubbing: scrubbing, loading: loading && !scrubbing)
            }
            .padding(.horizontal, scrubbing ? 18 : 0)
            .padding(.bottom, scrubbing ? foot - 4 : foot - 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .overlay(alignment: .bottom) {
                Color.clear
                    .frame(height: 44)
                    .contentShape(Rectangle())
                    .padding(.bottom, max(0, foot - 32))
                    .gesture(scrubGesture(width: geo.size.width - 36))
            }
        }
        .opacity(model.dragging ? 0 : 1)
        .animation(.easeOut(duration: 0.2), value: model.dragging)
        .animation(.snappy, value: scrubbing)
    }

    private func track(width: CGFloat, scrubbing: Bool, loading: Bool) -> some View {
        let fraction = model.scrub ?? (model.duration > 0 ? min(1, model.time / model.duration) : 0)
        let height: CGFloat = scrubbing ? 6 : 2
        let shape = RoundedRectangle(cornerRadius: scrubbing ? 3 : 0, style: .continuous)
        return ZStack(alignment: .leading) {
            shape.fill(.white.opacity(scrubbing ? 0.25 : 0.22))
            if loading {
                DramaLoadingLine()
            } else {
                shape.fill(.white.opacity(scrubbing ? 1 : 0.9))
                    .frame(width: max(0, width * fraction))
                    .transaction { if !scrubbing { $0.animation = nil } }
            }
            Circle()
                .fill(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(.white.opacity(0.18)).frame(width: 28, height: 28))
                .offset(x: width * fraction - 8)
                .opacity(scrubbing ? 1 : 0)
                .scaleEffect(scrubbing ? 1 : 0.3)
        }
        .frame(width: max(0, width), height: height)
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard model.phase == .ready, model.duration > 0, !model.dragging else { return }
                if base == nil {
                    let start = min(1, model.time / model.duration)
                    base = start
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    model.scrub = start
                }
                guard let base else { return }
                model.scrub = min(max(base + value.translation.width / max(width, 1), 0), 1)
            }
            .onEnded { value in
                if let scrub = model.scrub, abs(value.translation.width) > 2 { model.seek(to: scrub) }
                base = nil
                model.scrub = nil
            }
    }
}

/// 细加载指示：从中间向两侧扫开并淡出
struct DramaLoadingLine: View {
    @State private var run = false

    var body: some View {
        Rectangle()
            .fill(.white)
            .scaleEffect(x: run ? 1 : 0.04, anchor: .center)
            .opacity(run ? 0 : 0.9)
            .onAppear {
                withAnimation(.easeOut(duration: 0.9).repeatForever(autoreverses: false)) { run = true }
            }
    }
}

// MARK: - 中间

struct DramaPauseBadge: View {
    let model: DramaModel

    var body: some View {
        ZStack {
            if model.paused, model.phase == .ready, !model.dragging {
                Image(icon: "play.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
                    .offset(x: 2)
                    .frame(width: 76, height: 76)
                    .dramaGlass(Circle())
                    .transition(.scale(scale: 1.4).combined(with: .opacity))
            }
        }
        .animation(.bouncy, value: model.paused)
        .allowsHitTesting(false)
    }
}

struct DramaHearts: View {
    let model: DramaModel

    var body: some View {
        ZStack {
            ForEach(model.hearts) { heart in
                DramaHeartPop(heart: heart) { model.hearts.removeAll { $0.id == heart.id } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

private struct DramaHeartPop: View {
    let heart: DramaModel.Heart
    let done: () -> Void
    @State private var stage = 0

    var body: some View {
        Image(icon: "heart.fill")
            .font(.system(size: 84))
            .foregroundStyle(LinearGradient(colors: [Color(hex: 0xFFE45C), Tok.accent], startPoint: .top, endPoint: .bottom))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            .scaleEffect(stage == 0 ? 0.3 : stage == 1 ? 1 : 1.3)
            .opacity(stage == 2 ? 0 : 1)
            .offset(y: stage == 2 ? -70 : 0)
            .rotationEffect(.degrees(heart.tilt))
            .position(x: heart.point.x, y: heart.point.y - 30)
            .task {
                withAnimation(.bouncy) { stage = 1 }
                try? await Task.sleep(for: .milliseconds(460))
                withAnimation(.easeIn(duration: 0.36)) { stage = 2 }
                try? await Task.sleep(for: .milliseconds(380))
                done()
            }
    }
}

/// 目录失败、没有剧集、本集取链失败
struct DramaStatusOverlay: View {
    let model: DramaModel

    var body: some View {
        ZStack {
            switch model.session.tocState {
            case .failed(let message) where model.count == 0:
                panel(message) {
                    button("返回", accent: false) { model.onClose?() }
                    button("重试", accent: true) { Task { await model.reopen() } }
                }
            case .ready where model.count == 0:
                panel("没有剧集") {
                    button("返回", accent: false) { model.onClose?() }
                }
            default:
                if case .failed(let message) = model.phase, !model.dragging {
                    panel(message) {
                        button("重试", accent: true) { model.retry() }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
        }
        .animation(.snappy, value: model.phase)
    }

    private func panel<Buttons: View>(_ message: String, @ViewBuilder buttons: () -> Buttons) -> some View {
        VStack(spacing: 18) {
            Text(message)
                .font(.ui(14))
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .dramaTextShadow(4)
                .padding(.horizontal, 40)
            HStack(spacing: 12) { buttons() }
        }
    }

    private func button(_ title: String, accent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.ui(15, accent ? .semibold : .medium))
                .foregroundStyle(accent ? Tok.onAccent : .white)
                .frame(width: 96, height: 44)
                .background(accent ? AnyShapeStyle(Tok.accent) : AnyShapeStyle(.white.opacity(0.12)), in: Capsule())
        }
        .buttonStyle(.press)
    }
}
