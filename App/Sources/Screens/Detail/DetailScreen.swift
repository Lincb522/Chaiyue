import ReaderModels
import ReaderServices
import SwiftUI

struct DetailScreen: View {
    let input: DetailInput

    @Environment(AppModel.self) private var app
    @State private var info: Book?
    @State private var loading = false
    @State private var loadError: String?
    @State private var introOpen = false
    @State private var tracker = ScrollTracker()
    @State private var titleShown = false
    @State private var sheet: DetailSheet?
    @State private var chapters: [BookChapter] = []
    @State private var tocState: ReaderSession.TocState = .idle
    @State private var shown = false
    @State private var reloadAfterLogin = false

    private enum DetailSheet: String, Identifiable {
        case toc, source, login, edit, split
        var id: String { rawValue }
    }

    private var loginSource: BookSource? {
        guard !book.isLocal, let source = app.library.sources.source(for: book.origin), source.hasLogin else { return nil }
        return source
    }

    private var book: Book {
        let base = info ?? input.book
        return app.library.shelf.book(base.bookUrl) ?? base
    }

    private var onShelf: Bool { app.library.shelf.contains(book.bookUrl) }

    var body: some View {
        let book = book
        ZStack(alignment: .top) {
            ScreenBackground()
            DetailBackdrop(book: book, tracker: tracker)
            ScrollView {
                VStack(spacing: 0) {
                    header(book)
                    let kind = app.mediaKind(of: book)
                    AccentButton(title: kind.actionTitle(for: book), icon: kind.symbol,
                                 detail: book.hasStarted && kind != .video ? book.chapterLabel : nil, wide: true) {
                        app.openReader(book, coverKey: "detail-\(book.bookUrl)")
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 28)
                    .entrance(shown, delay: 0.12, rise: 16)
                    tools(book)
                        .padding(.horizontal, 10)
                        .padding(.top, 24)
                        .entrance(shown, delay: 0.16, rise: 16)
                    intro(book)
                        .entrance(shown, delay: 0.2, rise: 16)
                    rows(book)
                        .padding(.horizontal, 16)
                        .padding(.top, 22)
                        .entrance(shown, delay: 0.24, rise: 16)
                }
                .padding(.top, 42)
                .padding(.bottom, 56)
            }
            .scrollIndicators(.hidden)
            .track(tracker)
            .trackScroll($titleShown, threshold: 330)
            PageBar(title: book.name.withoutEmoji, scrolled: titleShown) {
                if app.customButtonSource(for: book) != nil { customButton(book) }
                moreMenu(book)
            }
        }
        .modifier(ZoomDestination(id: input.sourceID))
        .sheet(item: $sheet, onDismiss: {
            guard reloadAfterLogin else { return }
            reloadAfterLogin = false
            Task { await loadInfo() }
        }) { which in
            switch which {
            case .toc:
                TocSheet(chapters: chapters, current: book.durChapterIndex, bookUrl: book.bookUrl, state: tocState,
                         onRetry: { Task { await loadToc(refresh: true) } }) { index in
                    sheet = nil
                    read(from: index)
                }
                .qSheet([.fraction(0.76), .large])
                .environment(app)
            case .source:
                ChangeSourceSheet(book: book) { newBook in
                    info = newBook
                    chapters = []
                    tocState = .idle
                }
                .qSheet([.fraction(0.76), .large])
                .environment(app)
            case .login:
                if let source = loginSource {
                    SourceLoginSheet(source: source).environment(app)
                }
            case .edit:
                BookEditSheet(book: book).environment(app)
            case .split:
                TxtSplitSheet(book: book) { _ in
                    chapters = []
                    tocState = .idle
                }
                .environment(app)
            }
        }
        .task {
            shown = true
            await loadInfo()
            // 聚合书源在目录脚本里才标出听书、漫画、短剧，提前取目录（走缓存）好让主按钮换成对应的样子
            if !book.isLocal, tocState == .idle { await loadToc(refresh: false) }
            await debugAction()
        }
    }

    private func debugAction() async {
        #if DEBUG
        guard let action = DebugLaunch.flag("detailAction") else { return }
        try? await Task.sleep(for: .milliseconds(800))
        switch action {
        case "read": app.openReader(book, coverKey: "detail-\(book.bookUrl)")
        case "source": sheet = .source
        case "toc":
            sheet = .toc
            await loadToc(refresh: false)
        case "shelf": if !onShelf { app.addToShelf(book) }
        case "login": if loginSource != nil { sheet = .login }
        case "edit": if onShelf { sheet = .edit }
        case "split": if app.canResplit(book) { sheet = .split }
        default: break
        }
        #endif
    }

    // MARK: - 头部

    private func header(_ book: Book) -> some View {
        VStack(spacing: 0) {
            DetailCover(book: book) {
                app.openReader(book, coverKey: "detail-\(book.bookUrl)")
            }
            Text(book.name.withoutEmoji)
                .font(.serif(30))
                .tracking(1)
                .foregroundStyle(Tok.fg)
                .multilineTextAlignment(.center)
                .padding(.top, 30)
                .entrance(shown, delay: 0.06, rise: 12)
            if !book.author.isEmpty {
                Text(book.author.withoutEmoji)
                    .font(.ui(15))
                    .foregroundStyle(Tok.fg2)
                    .padding(.top, 8)
                    .entrance(shown, delay: 0.08, rise: 12)
            }
            let meta = metaItems(book)
            if !meta.isEmpty {
                Text(meta.joined(separator: "  ·  "))
                    .font(.ui(13))
                    .foregroundStyle(Tok.fg3)
                    .lineLimit(1)
                    .padding(.top, 10)
                    .entrance(shown, delay: 0.1, rise: 12)
            }
        }
        .padding(.horizontal, 24)
    }

    private func metaItems(_ book: Book) -> [String] {
        var items: [String] = []
        if let kind = book.kind?.withoutEmoji {
            let parts = kind.split(whereSeparator: { ",，;；| ".contains($0) }).map(String.init).filter { !$0.isEmpty }
            items += parts.prefix(2)
        }
        if let words = book.wordCount?.withoutEmoji, !words.isEmpty { items.append(words) }
        if book.isLocal { items.append("本地") }
        return items
    }

    // MARK: - 工具

    private func tools(_ book: Book) -> some View {
        let task = app.library.downloads.task(for: book.bookUrl)
        return HStack(spacing: 0) {
            DetailTool(icon: onShelf ? "checkmark" : "plus", label: onShelf ? "已在书架" : "加入书架", on: onShelf) {
                if onShelf {
                    app.removeFromShelf(book)
                } else {
                    app.addToShelf(book)
                }
            }
            DetailTool(icon: "list.bullet", label: "目录") {
                sheet = .toc
                if chapters.isEmpty { Task { await loadToc(refresh: false) } }
            }
            DetailTool(icon: cacheIcon(task), label: cacheLabel(task), on: task?.state == .finished,
                       progress: task.map { $0.state == .downloading || $0.state == .waiting ? $0.fractionCompleted : nil } ?? nil) {
                cache(book, task: task)
            }
            .disabled(book.isLocal)
            .opacity(book.isLocal ? 0.4 : 1)
            DetailTool(icon: "arrow.triangle.2.circlepath", label: "换源") { sheet = .source }
                .disabled(book.isLocal)
                .opacity(book.isLocal ? 0.4 : 1)
        }
    }

    private func cacheIcon(_ task: CacheTask?) -> String {
        switch task?.state {
        case .finished: "checkmark"
        case .downloading, .waiting: "pause.fill"
        case .paused: "play.fill"
        default: "arrow.down.to.line"
        }
    }

    private func cacheLabel(_ task: CacheTask?) -> String {
        switch task?.state {
        case .finished: "已缓存"
        case .downloading, .waiting: "\(task?.cachedCount ?? 0)/\(task?.chapterCount ?? 0)"
        case .paused: "已暂停"
        default: "缓存"
        }
    }

    private func cache(_ book: Book, task: CacheTask?) {
        let downloads = app.library.downloads
        switch task?.state {
        case .downloading, .waiting:
            downloads.pause(book.bookUrl)
        case .paused:
            downloads.resume(book.bookUrl)
        case .finished:
            app.island.show("arrow.down.circle", "已缓存 \(task?.cachedCount ?? 0) 章")
        default:
            guard !onShelf else { return app.cacheBook(book) }
            app.confirmShelfAdd(book) { [app] replacing in
                if let replacing { app.library.shelf.replace(replacing, with: book) } else { app.library.shelf.add(book) }
                app.cacheBook(book)
            }
        }
    }

    // MARK: - 简介与信息

    @ViewBuilder
    private func intro(_ book: Book) -> some View {
        let text = Self.cleanIntro(book.displayIntro)
        if let text {
            Text(text)
                .font(.ui(15))
                .lineSpacing(9)
                .foregroundStyle(Tok.fg2)
                .lineLimit(introOpen ? nil : 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 26)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.soft) { introOpen.toggle() } }
        } else if loading {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule().fill(Tok.fill).frame(height: 10).frame(maxWidth: i == 2 ? 180 : .infinity)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 30)
            .modifier(Shimmer())
        } else if let loadError {
            Button {
                Task { await loadInfo() }
            } label: {
                HStack(spacing: 8) {
                    Image(icon: "arrow.clockwise")
                    Text(loadError).lineLimit(1)
                }
                .font(.ui(13))
                .foregroundStyle(Tok.fg3)
                .padding(.horizontal, 16)
                .frame(height: 36)
                .background(Tok.fill, in: Capsule())
            }
            .buttonStyle(.press)
            .padding(.top, 26)
            .padding(.horizontal, 24)
        }
    }

    static func cleanIntro(_ raw: String?) -> String? {
        guard let raw = raw?.withoutEmoji else { return nil }
        let lines = raw.replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\u{3000}"))) }
            .filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func rows(_ book: Book) -> some View {
        CardGroup(separatorInset: 16) {
            if let latest = book.latestChapterTitle, !latest.isEmpty {
                InfoRow(key: "最新", value: latest.withoutEmoji, trailing: TimeText.since(book.latestChapterTime), chevron: false) {
                    sheet = .toc
                    if chapters.isEmpty { Task { await loadToc(refresh: false) } }
                }
            }
            InfoRow(key: "来源", value: book.isLocal ? "本地文件" : SourceName.full(book.originName.isEmpty ? book.origin : book.originName),
                    trailing: input.alternatives.count > 1 ? "\(input.alternatives.count) 个源" : nil,
                    chevron: !book.isLocal) {
                if !book.isLocal { sheet = .source }
            }
        }
    }

    private func moreMenu(_ book: Book) -> some View {
        Menu {
            Button("刷新", icon: "arrow.clockwise") {
                Task {
                    await loadInfo()
                    await loadToc(refresh: true)
                    app.island.show("arrow.clockwise", loadError == nil ? "已刷新" : "刷新失败", danger: loadError != nil)
                }
            }
            .disabled(book.isLocal)
            if loginSource != nil {
                Button("登录", icon: "key") {
                    reloadAfterLogin = true
                    sheet = .login
                }
            }
            Button("复制书名", icon: "doc.on.doc") {
                UIPasteboard.general.string = book.name
                app.island.show("doc.on.doc", "已复制")
            }
            if !book.isLocal {
                Button("复制链接", icon: "link") {
                    UIPasteboard.general.string = book.bookUrl
                    app.island.show("link", "已复制")
                }
            }
            if onShelf {
                Button("编辑信息", icon: "pencil") { sheet = .edit }
                if app.canResplit(book) {
                    Button("重新分章", icon: "list.number") { sheet = .split }
                }
                if !book.isLocal {
                    Button("清除缓存", icon: "xmark.bin") { app.clearCache(book) }
                }
                let groups = app.library.shelf.groups
                if !groups.isEmpty {
                    Menu("分组", icon: "folder") {
                        ForEach(groups) { group in
                            let member = book.group & group.groupId != 0
                            Button {
                                let mask = member ? book.group & ~group.groupId : book.group | group.groupId
                                app.library.shelf.setGroup(mask, for: [book.bookUrl])
                            } label: {
                                if member { Label(group.groupName, icon: "checkmark") } else { Text(group.groupName) }
                            }
                        }
                    }
                }
                Divider()
                Button("移出书架", icon: "trash", role: .destructive) { app.removeFromShelf(book) }
            }
        } label: {
            Image(icon: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Tok.fg)
                .glassCircle(40)
        }
    }

    /// 书源自定义按钮：点按、长按分别发 clickCustomButton、longClickCustomButton（详情页没有当前章节）
    private func customButton(_ book: Book) -> some View {
        Image(icon: "wand.and.stars")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Tok.fg)
            .glassCircle(40)
            .contentShape(Circle())
            .onTapGesture {
                app.library.callBack(.clickCustomButton, book: book)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            .onLongPressGesture(minimumDuration: 0.5) {
                app.library.callBack(.longClickCustomButton, book: book)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("书源按钮")
    }

    // MARK: - 加载

    private func loadInfo() async {
        let current = book
        guard !current.isLocal else { return }
        loading = true
        loadError = nil
        do {
            info = try await app.library.loadBookInfo(current)
        } catch {
            loadError = error.localizedDescription
        }
        loading = false
    }

    private func loadToc(refresh: Bool) async {
        let current = book
        tocState = .loading
        do {
            let result = try await app.library.contentService(for: current).chapters(for: current, refresh: refresh)
            if onShelf { app.library.shelf.mergeMetadata(from: result.book) } else { info = result.book }
            chapters = result.chapters
            tocState = .ready
        } catch {
            tocState = .failed(error.localizedDescription)
        }
    }

    private func read(from index: Int) {
        var target = book
        let title = chapters.indices.contains(index) ? chapters[index].title : nil
        if onShelf {
            app.library.shelf.saveProgress(bookUrl: target.bookUrl, chapterIndex: index, chapterPos: 0, chapterTitle: title)
        }
        target.durChapterIndex = index
        target.durChapterPos = 0
        target.durChapterTitle = title
        app.openReader(target, coverKey: "detail-\(target.bookUrl)")
    }
}

// MARK: - 组件

/// 详情页背景：封面放大高斯模糊，向下渐隐，随滚动轻微视差（原型 `.d-backdrop`）
struct DetailBackdrop: View {
    let book: Book
    let tracker: ScrollTracker
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let light = scheme == .light
        GeometryReader { proxy in
            let size = proxy.size
            CoverFill(book: book)
                .frame(width: size.width * 1.7, height: size.height * 0.8)
                .clipped()
                .blur(radius: 50)
                .saturation(light ? 1.35 : 1.5)
                .brightness(light ? 0.12 : -0.15)
                .opacity(light ? 0.5 : 0.9)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0.42), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .offset(x: -size.width * 0.35, y: -size.height * 0.12 - min(tracker.offset, 600) * 0.3)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// 只铺满图片（无书脊、颗粒），用于模糊背景
struct CoverFill: View {
    let book: Book
    @Environment(AppModel.self) private var app
    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    GeneratedCover(design: CoverDesign(seed: book.name + "\u{1}" + book.author), title: "", author: "", showsText: false)
                        .scaledToFill()
                }
            }
            .task(id: book.displayCover) {
                guard let url = book.displayCover else { return }
                if let cached = ImagePipeline.shared.cached(url) {
                    image = cached
                    return
                }
                image = await ImagePipeline.shared.image(for: url, book: book, app: app, maxPixel: 360)
            }
    }
}

/// 详情封面：轻点开始阅读；按住后拖动，封面随手指 3D 倾斜，高光跟随（原型 tilt）
private struct DetailCover: View {
    let book: Book
    let onTap: () -> Void
    @GestureState private var touch: CGPoint?

    private let size = CGSize(width: 170, height: 170 * 172 / 120)

    var body: some View {
        let nx: Double = touch.map { Double(min(max($0.x / size.width, 0), 1)) - 0.5 } ?? 0
        let ny: Double = touch.map { Double(min(max($0.y / size.height, 0), 1)) - 0.5 } ?? 0
        BookCover(book: book, maxPixel: 520)
            .frame(width: size.width)
            .overlay {
                if let touch {
                    RadialGradient(colors: [.white.opacity(0.32), .clear], center: UnitPoint(x: touch.x / size.width, y: touch.y / size.height),
                                   startRadius: 0, endRadius: size.height * 0.58)
                        .blendMode(.softLight)
                        .clipShape(RoundedRectangle(cornerRadius: Metrics.coverRadius, style: .continuous))
                        .allowsHitTesting(false)
                }
            }
            .coverShadow(lifted: true)
            .rotation3DEffect(.degrees(nx * 16), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .rotation3DEffect(.degrees(-ny * 16), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            .scaleEffect(touch == nil ? 1 : 1.03)
            .animation(touch == nil ? .soft : .interactiveSpring(response: 0.18, dampingFraction: 0.9), value: touch)
            .coverFrame("detail-\(book.bookUrl)")
            .onTapGesture(perform: onTap)
            .gesture(
                LongPressGesture(minimumDuration: 0.2)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .updating($touch) { value, state, _ in
                        if case .second(true, let drag) = value {
                            state = drag?.location ?? CGPoint(x: size.width / 2, y: size.height / 2)
                        }
                    }
            )
            .sensoryFeedback(.impact(weight: .light), trigger: touch != nil) { _, new in new }
    }
}

private struct DetailTool: View {
    let icon: String
    let label: String
    var on = false
    var progress: Double?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 9) {
                ZStack {
                    Image(icon: icon)
                        .font(.system(size: 19, weight: .medium))
                        .contentTransition(.symbolEffect(.replace))
                    if let progress {
                        Circle()
                            .trim(from: 0, to: max(0.02, progress))
                            .stroke(Tok.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .padding(1.5)
                            .animation(.out, value: progress)
                    }
                }
                .foregroundStyle(on ? Tok.accentInk : Tok.fg)
                .frame(width: 56, height: 56)
                .background {
                    if on {
                        Circle().fill(Tok.accentSoft)
                    } else {
                        Circle().fill(Tok.raise).modifier(RaisedShadow())
                    }
                }
                Text(label)
                    .font(.num(12))
                    .foregroundStyle(Tok.fg2)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(ToolPressStyle())
        .animation(.bouncy, value: on)
    }
}

private struct ToolPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(configuration.isPressed ? .easeOut(duration: 0.12) : .bouncy, value: configuration.isPressed)
    }
}

private struct RaisedShadow: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .overlay(Circle().strokeBorder(scheme == .dark ? Color.white.opacity(0.08) : Color(hex: 0x5A3C1E, alpha: 0.06), lineWidth: 0.5))
            .shadow(color: scheme == .dark ? .clear : Color(hex: 0x5A3C1E).opacity(0.12), radius: 7, y: 4)
    }
}

struct InfoRow: View {
    let key: String
    let value: String
    var trailing: String?
    var chevron = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text(key)
                    .font(.ui(14))
                    .foregroundStyle(Tok.fg3)
                    .frame(width: 32, alignment: .leading)
                Text(value)
                    .font(.ui(15))
                    .foregroundStyle(Tok.fg)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let trailing {
                    Text(trailing).font(.num(13)).foregroundStyle(Tok.fg3)
                }
                if chevron {
                    Image(icon: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Tok.fg3)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
        }
        .buttonStyle(.row)
    }
}

/// 加载占位的流光
struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .mask {
                GeometryReader { proxy in
                    LinearGradient(colors: [.black.opacity(0.35), .black, .black.opacity(0.35)], startPoint: .leading, endPoint: .trailing)
                        .frame(width: proxy.size.width * 2)
                        .offset(x: phase * proxy.size.width)
                }
            }
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 0 }
            }
    }
}
