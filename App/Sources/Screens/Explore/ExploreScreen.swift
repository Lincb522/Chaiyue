import ReaderModels
import ReaderServices
import SwiftUI

/// 发现页（原型 `.view-explore`）：顶部横排书源名，下面是该书源的榜单、分类与筛选；
/// 选中分类的前 5 本做成封面流，其余按名次排成列表
struct ExploreScreen: View {
    @Environment(AppModel.self) private var app
    @AppStorage("explore.source") private var selected = ""
    @State private var tracker = ScrollTracker()
    @State private var scrolled = false
    @State private var palette: [Color] = ShelfPalette.fallback

    var body: some View {
        let sources = app.library.sources.exploreSources
        let current = sources.first { $0.bookSourceUrl == selected } ?? sources.first
        ZStack(alignment: .top) {
            ScreenBackground()
            if current != nil {
                ParallaxAmbient(tracker: tracker, first: palette[2], second: palette[0])
            }
            VStack(spacing: 0) {
                if let current {
                    // 书源名固定在滚动区外面，竖向滚动不会把点按抢走
                    SourceBar(sources: sources, current: current.bookSourceUrl) { url in
                        withAnimation(.easeOut(duration: 0.35)) { selected = url }
                    }
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Color.clear.frame(height: 0).id("top")
                            if let current {
                                ExploreSourceView(source: current, palette: $palette)
                                    .id(current.bookSourceUrl)
                                    .transition(.opacity)
                            } else {
                                ExploreEmpty()
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .contentMargins(.top, 6, for: .scrollContent)
                    .contentMargins(.bottom, 124, for: .scrollContent)
                    .track(tracker)
                    .trackScroll($scrolled)
                    .onReceive(NotificationCenter.default.publisher(for: .scrollToTop)) { note in
                        guard note.object as? MainTab == .explore else { return }
                        withAnimation(.soft) { proxy.scrollTo("top", anchor: .top) }
                    }
                    .overlay(alignment: .top) {
                        CompactHeader(title: "", visible: scrolled)
                    }
                }
            }
        }
    }
}

/// 书源名横排：宋体大字，未选中的淡到 26%
private struct SourceBar: View {
    let sources: [BookSource]
    let current: String
    let onSelect: (String) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(sources, id: \.bookSourceUrl) { source in
                        let on = source.bookSourceUrl == current
                        Button {
                            guard !on else { return }
                            UISelectionFeedbackGenerator().selectionChanged()
                            onSelect(source.bookSourceUrl)
                            withAnimation(.soft) { proxy.scrollTo(source.bookSourceUrl, anchor: .leading) }
                        } label: {
                            Text(SourceName.display(source.bookSourceName))
                                .font(.serif(30))
                                .foregroundStyle(Tok.fg)
                                .lineLimit(1)
                                .opacity(on ? 1 : 0.26)
                                .padding(.horizontal, 8)
                                .frame(minHeight: 48)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(source.bookSourceUrl)
                    }
                }
                .padding(.vertical, 4)
            }
            .contentMargins(.horizontal, 20, for: .scrollContent)
            .scrollIndicators(.hidden)
            .onAppear { proxy.scrollTo(current, anchor: .leading) }
        }
    }
}

// MARK: - 单个书源

private struct ExploreSourceView: View {
    let source: BookSource
    @Binding var palette: [Color]
    @Environment(AppModel.self) private var app
    @State private var session: ExploreSession?
    @State private var list: ExploreBookList?
    @State private var selectedURL: String?

    private var storageKey: String { "explore.kind." + source.bookSourceUrl }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let session {
                if !session.kinds.isEmpty {
                    KindBar(session: session, sourceUrl: source.bookSourceUrl, selected: selectedURL,
                            onSelect: { select($0) }, onChanged: reload)
                }
                content(session)
            } else {
                ExploreSkeleton()
            }
        }
        .task { await start() }
        .onChange(of: session?.kinds ?? []) { _, _ in
            if let session { pickDefault(session) }
        }
        .onChange(of: session?.generation ?? 0) { _, generation in
            // 书单还没接上时是首次进入，交给 start()，避免和这里各请求一次
            guard generation > 0, let session, let list else { return }
            if app.library.exploreList(source: source, url: list.url) === list { return }
            let urls = session.kinds.compactMap { kind -> String? in
                if case .category(let url) = kind.role { return url }
                return nil
            }
            if let selectedURL, urls.contains(selectedURL) {
                select(selectedURL, save: false)
            } else {
                pickDefault(session)
            }
        }
    }

    @ViewBuilder
    private func content(_ session: ExploreSession) -> some View {
        if session.kinds.isEmpty {
            if let message = session.errorMessage, !session.isLoading {
                ExploreError(message: message) { Task { await session.load(refresh: true) } }
            } else {
                ExploreSkeleton()
            }
        } else if let url = selectedURL, WolfCenter.isCenter(url), let base = WolfCenter.base(of: url) {
            WolfCenterView(source: source, base: base) {
                Task { await session.reload() }
            }
            .id(url)
            .transition(.opacity)
        } else if let list {
            ExploreBooks(list: list, palette: $palette)
                .id(ObjectIdentifier(list))
                .transition(.opacity)
        }
    }

    private func start() async {
        let session = self.session ?? app.library.exploreSession(for: source)
        self.session = session
        if session.kinds.isEmpty { await session.load() }
        pickDefault(session)
        #if DEBUG
        if let name = DebugLaunch.flag("exploreKind") {
            for kind in session.kinds where kind.title.contains(name) {
                if case .category(let url) = kind.role { select(url, save: false) }
                break
            }
        }
        #endif
    }

    private func pickDefault(_ session: ExploreSession) {
        let urls = session.kinds.compactMap { kind -> String? in
            if case .category(let url) = kind.role { return url }
            return nil
        }
        if let selectedURL, urls.contains(selectedURL), list != nil { return }
        let saved = UserDefaults.standard.string(forKey: storageKey)
        // 个人中心的地址里带着当时的 Cookie，重新登录后地址会变，按条目类型找回
        let center = saved.map(WolfCenter.isCenter) == true ? urls.first(where: WolfCenter.isCenter) : nil
        if let url = urls.first(where: { $0 == saved }) ?? center ?? urls.first {
            select(url, save: false)
        }
    }

    private func select(_ url: String, save: Bool = true) {
        selectedURL = url
        if save { UserDefaults.standard.set(url, forKey: storageKey) }
        let next = app.library.exploreList(source: source, url: url)
        withAnimation(.easeOut(duration: 0.18)) { list = next }
        // 这本书单已经加载过就直接显示，不再从第一页重新请求
        if next.books.isEmpty, !next.isFinished {
            Task { await next.loadMore() }
        }
    }

    /// 筛选值变化后重新加载当前分类。分类地址没变，缓存的书单要清掉再请求
    private func reload() {
        guard let selectedURL else { return }
        let next = app.library.exploreList(source: source, url: selectedURL)
        withAnimation(.easeOut(duration: 0.18)) { list = next }
        Task { await next.reload() }
    }
}

/// 当前分组的分类横排（原型 `.ex-kinds`）；分组多或有筛选时，左侧固定组名，点开看全部分类与筛选
private struct KindBar: View {
    let session: ExploreSession
    let sourceUrl: String
    let selected: String?
    let onSelect: (String) -> Void
    let onChanged: () -> Void
    @Environment(AppModel.self) private var app
    @State private var panel = false
    @State private var pendingAction: ExploreKind?

    var body: some View {
        let layout = ExploreLayout(session.kinds)
        let current = layout.group(containing: selected) ?? layout.groups.first { $0.hasCategory } ?? layout.groups.first
        let items = current?.items ?? []
        HStack(spacing: 0) {
            if layout.needsPanel {
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    panel = true
                } label: {
                    HStack(spacing: 5) {
                        RollingText(text: current?.title ?? current?.section ?? "分类")
                            .font(.ui(14, .semibold))
                            .foregroundStyle(Tok.fg)
                        Image(icon: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Tok.fg3)
                    }
                    .lineLimit(1)
                    .chip(.raised)
                }
                .buttonStyle(.press)
                .padding(.leading, 20)
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, kind in
                            item(kind).id(index)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .contentMargins(.leading, layout.needsPanel ? 10 : 20, for: .scrollContent)
                .contentMargins(.trailing, 20, for: .scrollContent)
                .scrollIndicators(.hidden)
                .onAppear {
                    let index = items.firstIndex { kind in
                        if case .category(let url) = kind.role { return url == selected }
                        return false
                    }
                    if let index, index > 2 { proxy.scrollTo(index, anchor: .center) }
                }
            }
            .id(current?.id)
        }
        .padding(.top, 8)
        // 书源动作常会打开浏览器，等面板收起后再执行，否则会撞上收起动画而弹不出来
        .sheet(isPresented: $panel, onDismiss: {
            guard let kind = pendingAction else { return }
            pendingAction = nil
            Task { await session.press(kind) }
        }) {
            ExploreKindPanel(session: session, selected: selected, onSelect: onSelect, onChanged: onChanged) { pendingAction = $0 }
        }
        #if DEBUG
        .task {
            guard DebugLaunch.flag("explorePanel") != nil, layout.needsPanel else { return }
            try? await Task.sleep(for: .seconds(2))
            panel = true
        }
        #endif
    }

    @ViewBuilder
    private func item(_ kind: ExploreKind) -> some View {
        switch kind.role {
        case .category(let url):
            let on = url == selected
            Button {
                guard !on else { return }
                UISelectionFeedbackGenerator().selectionChanged()
                onSelect(url)
            } label: {
                Text(BookText.label(kind.title))
                    .font(.ui(14, on ? .semibold : .regular))
                    .foregroundStyle(on ? Tok.bg : Tok.fg2)
                    .lineLimit(1)
                    .chip(on ? .solid : .raised)
            }
            .buttonStyle(.press)
            .contextMenu {
                Button("单独打开", icon: "arrow.up.forward.square") {
                    app.push(.exploreList(sourceUrl: sourceUrl, url: url, title: BookText.label(kind.title)))
                }
            }
        case .button, .script:
            Button {
                Task { await session.press(kind) }
            } label: {
                Text(BookText.label(kind.title))
                    .font(.ui(14))
                    .foregroundStyle(Tok.fg2)
                    .lineLimit(1)
                    .chip(.raised)
            }
            .buttonStyle(.press)
        default:
            EmptyView()
        }
    }
}

/// 值变化时新值从下方滚入（原型 Q.roll）
struct RollingText: View {
    let text: String

    var body: some View {
        Text(text)
            .id(text)
            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .move(edge: .top).combined(with: .opacity)))
            .clipped()
            .animation(.snappy, value: text)
    }
}

/// 书源的发现条目整理成筛选控件、说明和分组。没有地址的条目是标题，「--」这类占位跳过；
/// 两个标题挨着时前一个是上级分区，出现在第一个分组之前的则当作说明
struct ExploreLayout {
    struct Group: Identifiable {
        let id: Int
        var section: String?
        var title: String?
        var items: [ExploreKind] = []

        var name: String? {
            let parts = [section, title].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }

        var hasCategory: Bool {
            items.contains { kind in
                if case .category = kind.role { return true }
                return false
            }
        }

        /// Legado 用 flexBasisPercent 表示一行放几个，0.25 即四个
        var columns: Int? {
            guard let basis = items.lazy.compactMap({ $0.style?.layoutFlexBasisPercent }).first(where: { $0 > 0 }) else { return nil }
            return min(4, max(1, Int((1 / basis).rounded(.down))))
        }

        func contains(_ url: String?) -> Bool {
            guard let url else { return false }
            return items.contains { kind in
                if case .category(let value) = kind.role { return value == url }
                return false
            }
        }
    }

    private(set) var controls: [ExploreKind] = []
    private(set) var notes: [String] = []
    private(set) var groups: [Group] = []

    init(_ kinds: [ExploreKind]) {
        var pending: [String] = []
        var section: String?
        for kind in kinds {
            switch kind.role {
            case .title:
                if let label = Self.label(kind.title) { pending.append(label) }
            case .select, .toggle, .text:
                controls.append(kind)
            case .category, .script, .button:
                if groups.isEmpty || !pending.isEmpty {
                    let title = pending.popLast()
                    if !pending.isEmpty {
                        if groups.contains(where: { $0.title != nil }) { section = pending.last } else { notes += pending }
                    }
                    pending.removeAll()
                    groups.append(Group(id: groups.count, section: title == nil ? nil : section, title: title))
                }
                groups[groups.count - 1].items.append(kind)
            }
        }
    }

    var needsPanel: Bool {
        !controls.isEmpty || groups.count > 1 || groups.reduce(0) { $0 + $1.items.count } > 16
    }

    func group(containing url: String?) -> Group? {
        groups.first { $0.contains(url) }
    }

    private static func label(_ raw: String) -> String? {
        let kept = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "[]【】()（）《》<>「」『』"))
        let trimmed = raw.trimmingCharacters(in: kept.inverted)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// 全部分类与筛选：筛选在上，各分组按书源给的列数排成网格，打开时滚到当前分组
private struct ExploreKindPanel: View {
    let session: ExploreSession
    let selected: String?
    let onSelect: (String) -> Void
    let onChanged: () -> Void
    let onAction: (ExploreKind) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let layout = ExploreLayout(session.kinds)
        let current = layout.group(containing: selected)?.id
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SheetHeader(title: "分类") {
                        if session.isLoading || session.isRunningAction {
                            ProgressView()
                        }
                    }
                    if !layout.controls.isEmpty {
                        CardGroup(separatorInset: 20) {
                            ForEach(Array(layout.controls.enumerated()), id: \.offset) { _, kind in
                                control(kind)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    ForEach(layout.notes, id: \.self) { note in
                        Text(note)
                            .font(.ui(12))
                            .foregroundStyle(Tok.gFg3)
                            .padding(.horizontal, 24)
                            .padding(.top, 12)
                    }
                    ForEach(layout.groups) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            if let name = group.name {
                                Text(name)
                                    .font(.ui(13, .medium))
                                    .tracking(0.5)
                                    .foregroundStyle(Tok.gFg2)
                                    .padding(.horizontal, 8)
                            }
                            LazyVGrid(columns: columns(group), spacing: 8) {
                                ForEach(Array(group.items.enumerated()), id: \.offset) { _, kind in
                                    tile(kind)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 22)
                        .id(group.id)
                    }
                }
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .onAppear {
                guard let current, layout.groups.prefix(while: { $0.id != current }).contains(where: \.hasCategory) else { return }
                proxy.scrollTo(current, anchor: .top)
            }
        }
        .environment(\.onGlass, true)
        .qSheet([.medium, .large])
    }

    private func columns(_ group: ExploreLayout.Group) -> [GridItem] {
        if let count = group.columns {
            return Array(repeating: GridItem(.flexible(), spacing: 8), count: count)
        }
        return [GridItem(.adaptive(minimum: 76), spacing: 8)]
    }

    @ViewBuilder
    private func tile(_ kind: ExploreKind) -> some View {
        switch kind.role {
        case .category(let url):
            let on = url == selected
            Button {
                UISelectionFeedbackGenerator().selectionChanged()
                if !on { onSelect(url) }
                dismiss()
            } label: {
                tileLabel(kind.title, on: on)
            }
            .buttonStyle(.press)
        case .script, .button:
            Button {
                onAction(kind)
                dismiss()
            } label: {
                tileLabel(kind.title, on: false)
            }
            .buttonStyle(.press)
        default:
            EmptyView()
        }
    }

    private func tileLabel(_ title: String, on: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Text(BookText.label(title))
            .font(.ui(14, on ? .semibold : .regular))
            .foregroundStyle(on ? Tok.onAccent : Tok.gFg)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(on ? Tok.accent : Tok.gFill, in: shape)
            .contentShape(shape)
    }

    @ViewBuilder
    private func control(_ kind: ExploreKind) -> some View {
        let title = BookText.label(kind.title)
        switch kind.role {
        case .select(let options):
            let value = session.value(for: kind)
            Menu {
                ForEach(options, id: \.self) { option in
                    Button {
                        guard option != value else { return }
                        Task {
                            await session.select(option, for: kind)
                            onChanged()
                        }
                    } label: {
                        if option == value { Label(option, icon: "checkmark") } else { Text(option) }
                    }
                }
            } label: {
                SettingRow(title: title) { RollingText(text: value) }
            }
            .menuOrder(.fixed)
        case .toggle:
            Button {
                UISelectionFeedbackGenerator().selectionChanged()
                Task {
                    await session.toggle(kind)
                    onChanged()
                }
            } label: {
                SettingRow(title: title, chevron: false) { RollingText(text: session.value(for: kind)) }
            }
            .buttonStyle(.row)
        case .text:
            SettingRow(title: title, chevron: false) {
                ExploreTextInput(session: session, kind: kind, onSubmit: onChanged)
            }
        default:
            EmptyView()
        }
    }
}

private struct ExploreTextInput: View {
    let session: ExploreSession
    let kind: ExploreKind
    let onSubmit: () -> Void
    @State private var text = ""

    var body: some View {
        TextField("", text: $text)
            .multilineTextAlignment(.trailing)
            .foregroundStyle(Tok.gFg)
            .frame(maxWidth: 160)
            .submitLabel(.done)
            .onSubmit {
                session.setText(text, for: kind)
                Task {
                    await session.submit(kind)
                    onSubmit()
                }
            }
            .onAppear { text = session.value(for: kind) }
    }
}

// MARK: - 书单

private struct ExploreBooks: View {
    let list: ExploreBookList
    @Binding var palette: [Color]
    @State private var center = 0
    @State private var palettes: [Int: [Color]] = [:]
    @State private var shown = false

    var body: some View {
        let books = list.books
        let flow = Array(books.prefix(5))
        let rest = Array(books.dropFirst(5))
        VStack(spacing: 0) {
            if flow.isEmpty {
                if let message = list.errorMessage, !list.isLoading {
                    ExploreError(message: message) { Task { await list.reload() } }
                } else if list.isFinished {
                    VStack(spacing: 12) {
                        Image(icon: "books.vertical")
                            .font(.system(size: 34, weight: .light))
                        Text("暂无书籍").font(.ui(14))
                    }
                    .foregroundStyle(Tok.fg3)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 120)
                } else {
                    ExploreSkeleton()
                }
            } else {
                CoverFlow(books: flow, center: $center, shown: shown) { index, colors in
                    palettes[index] = colors
                    if index == center { palette = colors }
                }
                .padding(.top, 26)
                CoverInfo(book: flow[min(center, flow.count - 1)])
                LazyVStack(spacing: 0) {
                    ForEach(Array(rest.enumerated()), id: \.element.id) { offset, book in
                        RankRow(book: book, rank: offset + 6)
                            .entrance(shown, delay: 0.12 + Double(min(offset, 12)) * 0.03, rise: 16)
                    }
                    ListFooter(list: list)
                }
                .padding(.top, 22)
            }
        }
        .onChange(of: flow.isEmpty, initial: true) { _, empty in
            if !empty { shown = true }
        }
        .onChange(of: center) { _, index in
            if let colors = palettes[index] { palette = colors }
        }
    }
}

/// 书单底部：继续加载、出错重试
private struct ListFooter: View {
    let list: ExploreBookList

    var body: some View {
        if let message = list.errorMessage, !list.isLoading {
            Button {
                Task { await list.loadMore() }
            } label: {
                VStack(spacing: 6) {
                    Image(icon: "arrow.clockwise").font(.system(size: 15, weight: .semibold))
                    Text(message).font(.ui(11)).lineLimit(1)
                }
                .foregroundStyle(Tok.fg3)
                .padding(.horizontal, 40)
                .frame(height: 72)
            }
            .buttonStyle(.plain)
        } else if !list.isFinished {
            ProgressView()
                .frame(height: 64)
                .onAppear { Task { await list.loadMore() } }
        }
    }
}

/// 封面流下方的书名与作者，切换时淡入上浮
private struct CoverInfo: View {
    let book: SearchBook

    var body: some View {
        ZStack {
            VStack(spacing: 6) {
                Text(book.name.withoutEmoji)
                    .font(.serif(23))
                    .foregroundStyle(Tok.fg)
                    .lineLimit(1)
                Text(BookText.join(book.author, BookText.kind(book.kind)))
                    .font(.ui(13))
                    .foregroundStyle(Tok.fg2)
                    .lineLimit(1)
            }
            .id(book.id)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity))
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.3), value: book.id)
    }
}

// MARK: - 封面流

/// 3D 封面流：横向拖动带越界阻尼，松手按速度吸附；点中间的打开详情，点两侧的转到它
private struct CoverFlow: View {
    let books: [SearchBook]
    @Binding var center: Int
    let shown: Bool
    let onPalette: (Int, [Color]) -> Void
    @Environment(AppModel.self) private var app
    @State private var position: CGFloat = 0
    @State private var dragStart: CGFloat?

    private static let step: CGFloat = 104

    var body: some View {
        let last = CGFloat(max(books.count - 1, 0))
        CoverFlowStage(books: books, position: position, shown: shown, onTap: tap, onPalette: onPalette)
            .frame(maxWidth: .infinity)
            .frame(height: 270, alignment: .top)
            .contentShape(Rectangle())
            .horizontalPan { dx in
                if dragStart == nil { dragStart = position }
                var value = (dragStart ?? 0) - dx / Self.step
                if value < 0 { value = -rubberBand(-value) }
                if value > last { value = last + rubberBand(value - last) }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { position = value }
            } onEnd: { _, velocityX in
                dragStart = nil
                let velocity = -velocityX / Self.step
                snap(to: min(max((position + velocity * 0.16).rounded(), 0), last), velocity: velocity)
            }
    }

    private func snap(to target: CGFloat, velocity: CGFloat = 0) {
        let distance = target - position
        let initial = abs(distance) > 0.001 ? min(max(velocity / distance, -12), 12) : 0
        withAnimation(.interpolatingSpring(stiffness: 210, damping: 25, initialVelocity: initial)) {
            position = target
        }
        let index = Int(target)
        if index != center {
            UISelectionFeedbackGenerator().selectionChanged()
            center = index
        }
    }

    private func tap(_ index: Int) {
        guard books.indices.contains(index) else { return }
        if index == Int(position.rounded()) {
            let book = books[index]
            app.openDetail(book.toBook(), sourceID: "explore-\(book.id)")
        } else {
            snap(to: CGFloat(index))
        }
    }
}

/// 按连续位置逐帧排布：位移、纵深缩放、绕 Y 轴旋转、远处压暗
private struct CoverFlowStage: View, Animatable {
    let books: [SearchBook]
    var position: CGFloat
    let shown: Bool
    let onTap: (Int) -> Void
    let onPalette: (Int, [Color]) -> Void

    var animatableData: CGFloat {
        get { position }
        set { position = newValue }
    }

    var body: some View {
        ZStack(alignment: .top) {
            ForEach(Array(books.enumerated()), id: \.element.id) { index, book in
                let d = CGFloat(index) - position
                let distance = abs(d)
                let x = (d < 0 ? -1 : 1) * (distance < 1 ? distance * 104 : 104 + (distance - 1) * 50)
                let scale = 900 / (900 + min(distance, 2.4) * 120)
                CoverFlowItem(book: book, shade: min(distance * 0.32, 0.6)) { onPalette(index, $0) }
                    .rotation3DEffect(.degrees(Double(-min(max(d, -1), 1) * 46)), axis: (0, 1, 0), perspective: 0.5)
                    .scaleEffect(scale)
                    .offset(x: x * scale)
                    .zIndex(Double(100 - distance * 10))
                    .entrance(shown, delay: Double(index) * 0.05, rise: 30, scale: 0.9)
                    .onTapGesture { onTap(index) }
            }
        }
        .padding(.top, 8)
    }
}

private struct CoverFlowItem: View {
    let book: SearchBook
    let shade: CGFloat
    let onPalette: ([Color]) -> Void

    var body: some View {
        BookCover(title: book.name, author: book.author, url: book.coverUrl, book: book.toBook(), maxPixel: 520,
                  onPalette: onPalette)
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.coverRadius, style: .continuous)
                    .fill(Tok.bg)
                    .opacity(shade)
                    .allowsHitTesting(false)
            }
            .frame(width: 172)
            .coverShadow(lifted: true)
            .background(alignment: .bottom) {
                Ellipse()
                    .fill(RadialGradient(colors: [Tok.shadowWarm.opacity(0.4), .clear], center: .center,
                                         startRadius: 0, endRadius: 66))
                    .frame(width: 132, height: 18)
                    .blur(radius: 3)
                    .offset(y: 16)
            }
            .zoomSource("explore-\(book.id)")
    }
}

// MARK: - 排行行

struct RankRow: View {
    let book: SearchBook
    let rank: Int
    @Environment(AppModel.self) private var app

    var body: some View {
        let id = "explore-\(book.id)"
        Button {
            app.openDetail(book.toBook(), sourceID: id)
        } label: {
            HStack(spacing: 14) {
                Text("\(rank)")
                    .font(.serif(20))
                    .monospacedDigit()
                    .foregroundStyle(Tok.fg3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(width: 26)
                BookCover(search: book)
                    .frame(width: 52)
                    .coverShadow()
                    .zoomSource(id)
                VStack(alignment: .leading, spacing: 4) {
                    Text(book.name.withoutEmoji)
                        .font(.serif(17))
                        .foregroundStyle(Tok.fg)
                        .lineLimit(1)
                    Text(BookText.subtitle(book))
                        .font(.ui(12))
                        .foregroundStyle(Tok.fg2)
                        .lineLimit(1)
                    if let intro = BookText.oneLine(book.intro) {
                        Text(intro)
                            .font(.ui(12))
                            .foregroundStyle(Tok.fg3)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .buttonStyle(.row)
    }
}

// MARK: - 状态

private struct ExploreSkeleton: View {
    @State private var dim = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                ForEach([-1, 1], id: \.self) { side in
                    RoundedRectangle(cornerRadius: Metrics.coverRadius, style: .continuous)
                        .fill(Tok.fill2)
                        .frame(width: 172, height: 246)
                        .rotation3DEffect(.degrees(Double(-side) * 46), axis: (0, 1, 0), perspective: 0.5)
                        .scaleEffect(0.88)
                        .offset(x: CGFloat(side) * 104 * 0.88)
                }
                RoundedRectangle(cornerRadius: Metrics.coverRadius, style: .continuous)
                    .fill(Tok.fill2)
                    .frame(width: 172, height: 246)
            }
            .frame(height: 270, alignment: .top)
            .padding(.top, 34)
            VStack(spacing: 8) {
                Capsule().fill(Tok.fill2).frame(width: 120, height: 18)
                Capsule().fill(Tok.fill).frame(width: 80, height: 11)
            }
            .padding(.top, 26)
        }
        .frame(maxWidth: .infinity)
        .opacity(dim ? 0.45 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(), value: dim)
        .onAppear { dim = true }
    }
}

private struct ExploreError: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(icon: "wifi.exclamationmark")
                .font(.system(size: 30, weight: .light))
            Text(message)
                .font(.ui(13))
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Button(action: retry) {
                Text("重试")
                    .font(.ui(15, .semibold))
                    .foregroundStyle(Tok.fg)
                    .padding(.horizontal, 22)
                    .frame(height: 40)
                    .raisedSurface(Capsule())
            }
            .buttonStyle(.press)
        }
        .foregroundStyle(Tok.fg3)
        .padding(.horizontal, 40)
        .padding(.top, 110)
        .frame(maxWidth: .infinity)
    }
}

private struct ExploreEmpty: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 16) {
            Image(icon: "safari")
                .font(.system(size: 34, weight: .light))
            Button {
                app.push(.sources)
            } label: {
                Text("书源管理")
                    .font(.ui(15, .semibold))
                    .foregroundStyle(Tok.fg)
                    .padding(.horizontal, 20)
                    .frame(height: 40)
                    .raisedSurface(Capsule())
            }
            .buttonStyle(.press)
        }
        .foregroundStyle(Tok.fg3)
        .frame(maxWidth: .infinity)
        .padding(.top, 220)
    }
}

// MARK: - 单独打开的书单

struct ExploreListScreen: View {
    let sourceUrl: String
    let url: String
    let title: String
    @Environment(AppModel.self) private var app
    @State private var list: ExploreBookList?

    var body: some View {
        PageScaffold(title: title) {
            LazyVStack(spacing: 0) {
                if let list {
                    ForEach(Array(list.books.enumerated()), id: \.element.id) { offset, book in
                        RankRow(book: book, rank: offset + 1)
                    }
                    if list.books.isEmpty, let message = list.errorMessage, !list.isLoading {
                        ExploreError(message: message) { Task { await list.reload() } }
                    } else if list.books.isEmpty, list.isFinished {
                        VStack(spacing: 12) {
                            Image(icon: "books.vertical")
                                .font(.system(size: 34, weight: .light))
                            Text("暂无书籍").font(.ui(14))
                        }
                        .foregroundStyle(Tok.fg3)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 120)
                    } else {
                        ListFooter(list: list)
                    }
                }
            }
        }
        .task {
            guard list == nil, let source = app.library.sources.source(for: sourceUrl) else { return }
            let next = app.library.exploreList(source: source, url: url)
            list = next
            await next.loadMore()
        }
    }
}
