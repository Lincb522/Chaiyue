import ReaderModels
import ReaderServices
import SwiftUI
import UniformTypeIdentifiers

enum ShelfFilter: Hashable {
    case all, reading, local
    case group(Int64)
}

enum ShelfSort: String, CaseIterable, Identifiable {
    case recent, update, title

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recent: "最近阅读"
        case .update: "最近更新"
        case .title: "书名"
        }
    }
}

struct ShelfScreen: View {
    @Environment(AppModel.self) private var app
    @State private var tracker = ScrollTracker()
    @State private var filter: ShelfFilter = .all
    @AppStorage("shelf.sort") private var sort: ShelfSort = .recent
    @State private var scrolled = false
    @State private var refreshing = false
    @State private var appeared = false
    @State private var palette: [Color] = ShelfPalette.fallback
    @State private var importing = false
    @State private var importingFolder = false
    @State private var naming = false
    @State private var renaming = false
    @State private var groupName = ""
    @State private var selecting = false
    @State private var selection: Set<String> = []
    @State private var removing = false
    @State private var bookSheet: ShelfBookSheet?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: 3)

    var body: some View {
        let shelf = app.library.shelf
        let all = shelf.books
        let hero = all.max { $0.durChapterTime < $1.durChapterTime }
        let filters = filterItems(all)
        let books = sorted(filtered(all))

        ZStack(alignment: .top) {
            ScreenBackground()
            if hero != nil {
                ParallaxAmbient(tracker: tracker, first: palette[2], second: palette[0])
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: refreshing ? 60 : 0).id("top")
                        LargeTitle(title: "书架") {
                            moreMenu
                                .opacity(selecting ? 0 : 1)
                                .allowsHitTesting(!selecting)
                        }
                        .entrance(appeared, rise: 12)
                        if let hero, !selecting {
                            HeroCard(book: hero, palette: $palette) {
                                app.openDetail(hero, sourceID: "hero-\(hero.bookUrl)")
                            } onRead: {
                                app.openReader(hero, coverKey: "hero-\(hero.bookUrl)")
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 2)
                            .padding(.bottom, 22)
                            .entrance(appeared, delay: 0.09, rise: 34, scale: 0.96)
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                        }
                        if all.isEmpty {
                            ShelfEmpty(importing: $importing)
                                .padding(.top, 60)
                        } else {
                            if filters.count > 1 {
                                ScrollView(.horizontal) {
                                    SegmentedChips(items: filters.map(\.0), selection: filterIndex(filters))
                                        .padding(.horizontal, 20)
                                }
                                .scrollIndicators(.hidden)
                                .padding(.bottom, 20)
                                .entrance(appeared, delay: 0.22, rise: 0)
                            }
                            LazyVGrid(columns: columns, spacing: 24) {
                                ForEach(Array(books.enumerated()), id: \.element.bookUrl) { index, book in
                                    ShelfGridItem(book: book, pinned: shelf.pinned.contains(book.bookUrl),
                                                  selecting: selecting, selected: selection.contains(book.bookUrl),
                                                  onSheet: { bookSheet = $0 }) {
                                        UISelectionFeedbackGenerator().selectionChanged()
                                        if selection.contains(book.bookUrl) {
                                            selection.remove(book.bookUrl)
                                        } else {
                                            selection.insert(book.bookUrl)
                                        }
                                    }
                                    .entrance(appeared, delay: 0.26 + Double(min(index, 14)) * 0.042)
                                    .transition(.scale(scale: 0.82).combined(with: .opacity))
                                }
                            }
                            .padding(.horizontal, 20)
                            .animation(.soft, value: books.map(\.bookUrl))
                            if books.isEmpty {
                                Image(icon: "books.vertical")
                                    .font(.system(size: 34, weight: .light))
                                    .foregroundStyle(Tok.fg3)
                                    .padding(.top, 80)
                            }
                        }
                    }
                    .animation(.soft, value: refreshing)
                }
                .scrollIndicators(.hidden)
                .contentMargins(.top, 6, for: .scrollContent)
                .contentMargins(.bottom, 124, for: .scrollContent)
                .track(tracker)
                .trackScroll($scrolled)
                .pullToRefresh(tracker, refreshing: $refreshing) { await refresh() }
                .onReceive(NotificationCenter.default.publisher(for: .scrollToTop)) { note in
                    guard note.object as? MainTab == .shelf else { return }
                    withAnimation(.soft) { proxy.scrollTo("top", anchor: .top) }
                }
            }
            PullIndicator(tracker: tracker, refreshing: refreshing)
            CompactHeader(title: selecting ? "已选 \(selection.count) 本" : "书架", visible: scrolled)
            if selecting {
                CircleButton(systemName: "checkmark") { endSelecting() }
                    .padding(.top, 19)
                    .padding(.trailing, 20)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                ShelfBatchBar(count: selection.count, allSelected: !books.isEmpty && selection.isSuperset(of: books.map(\.bookUrl)),
                              groups: shelf.groups, currentGroup: currentGroup) { action in
                    perform(action, visible: books)
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: selecting)
        .onChange(of: selecting) { _, on in app.tabBarHidden = on }
        .onAppear { appeared = true }
        .task { await debugSelect() }
        .confirmationDialog("移出 \(selection.count) 本书", isPresented: $removing, titleVisibility: .visible) {
            Button("移出书架", role: .destructive) {
                let count = selection.count
                withAnimation(.soft) { app.library.removeBooks(selection) }
                endSelecting()
                app.island.show("trash", "已移出 \(count) 本", danger: true)
            }
        } message: {
            Text("本地书的文件和已缓存的章节会一并删除")
        }
        .sheet(item: $bookSheet) { sheet in
            switch sheet {
            case .edit(let book):
                BookEditSheet(book: book).environment(app)
            case .source(let book):
                ChangeSourceSheet(book: book) { _ in }
                    .qSheet([.fraction(0.76), .large])
                    .environment(app)
            case .split(let book):
                TxtSplitSheet(book: book).environment(app)
            }
        }
        .alert("重命名分组", isPresented: $renaming) {
            TextField("分组名", text: $groupName)
            Button("取消", role: .cancel) { groupName = "" }
            Button("确定") {
                let name = groupName.trimmingCharacters(in: .whitespaces)
                groupName = ""
                guard !name.isEmpty, let id = currentGroup else { return }
                shelf.renameGroup(id, to: name)
            }
        }
        .onChange(of: importing) { _, on in
            guard on else { return }
            importing = false
            FilePicker.present([.plainText, .epub, .json] + AppModel.bookImportTypes + AppModel.mediaImportTypes, multiple: true) { urls in
                Task { await app.importFiles(urls) }
            }
        }
        .onChange(of: importingFolder) { _, on in
            guard on else { return }
            importingFolder = false
            FilePicker.present([.folder], asCopy: false) { urls in
                Task { await app.importMedia(urls) }
            }
        }
        .alert("新建分组", isPresented: $naming) {
            TextField("分组名", text: $groupName)
            Button("取消", role: .cancel) { groupName = "" }
            Button("创建") {
                let name = groupName.trimmingCharacters(in: .whitespaces)
                groupName = ""
                guard !name.isEmpty, let group = shelf.addGroup(name) else { return }
                if selecting, !selection.isEmpty {
                    addSelection(to: group.groupId)
                    app.island.show("folder", "已移入「\(name)」")
                    endSelecting()
                } else {
                    withAnimation(.soft) { filter = .group(group.groupId) }
                }
            }
        }
    }

    private var currentGroup: Int64? {
        if case .group(let id) = filter { id } else { nil }
    }

    // MARK: - 多选

    private func endSelecting() {
        selecting = false
        selection = []
    }

    private func addSelection(to groupId: Int64) {
        let shelf = app.library.shelf
        withAnimation(.soft) {
            for url in selection {
                guard let book = shelf.book(url) else { continue }
                shelf.setGroup(book.group | groupId, for: [url])
            }
        }
    }

    private func perform(_ action: ShelfBatchAction, visible: [Book]) {
        let shelf = app.library.shelf
        switch action {
        case .selectAll:
            let urls = Set(visible.map(\.bookUrl))
            selection = selection.isSuperset(of: urls) ? selection.subtracting(urls) : selection.union(urls)
        case .group(let id):
            addSelection(to: id)
            let name = shelf.groups.first { $0.groupId == id }?.groupName ?? ""
            app.island.show("folder", "已移入「\(name)」")
            endSelecting()
        case .newGroup:
            naming = true
        case .ungroup:
            guard let id = currentGroup else { return }
            withAnimation(.soft) {
                for url in selection {
                    guard let book = shelf.book(url) else { continue }
                    shelf.setGroup(book.group & ~id, for: [url])
                }
            }
            app.island.show("folder", "已移出分组")
            endSelecting()
        case .pin:
            let unpinned = selection.filter { !shelf.pinned.contains($0) }
            withAnimation(.soft) {
                for url in unpinned.isEmpty ? selection : unpinned { shelf.togglePin(url) }
            }
            app.island.show(unpinned.isEmpty ? "pin.slash" : "pin", unpinned.isEmpty ? "已取消置顶" : "已置顶")
            endSelecting()
        case .cache:
            let books = selection.compactMap { shelf.book($0) }.filter { !$0.isLocal }
            for book in books { _ = app.library.downloads.enqueue(book) }
            app.island.show("arrow.down.circle", books.isEmpty ? "本地书无需缓存" : "开始缓存 \(books.count) 本")
            endSelecting()
        case .remove:
            removing = true
        }
    }

    private func debugSelect() async {
        #if DEBUG
        guard DebugLaunch.flag("shelfSelect") != nil else { return }
        try? await Task.sleep(for: .milliseconds(1500))
        selecting = true
        selection = Set(app.library.shelf.books.prefix(2).map(\.bookUrl))
        #endif
    }

    private var moreMenu: some View {
        Menu {
            Picker("排序", selection: $sort.animation(.soft)) {
                ForEach(ShelfSort.allCases) { Text($0.title).tag($0) }
            }
            Divider()
            if !app.library.shelf.books.isEmpty {
                Button("选择", icon: "checkmark.circle") { selecting = true }
            }
            Button("导入本地书籍", icon: "folder") { importing = true }
            Button("导入有声书文件夹", icon: "headphones") { importingFolder = true }
            Button("新建分组", icon: "folder.badge.plus") { naming = true }
            if case .group(let id) = filter {
                Button("重命名分组", icon: "pencil") {
                    groupName = app.library.shelf.groups.first { $0.groupId == id }?.groupName ?? ""
                    renaming = true
                }
                Button("删除当前分组", icon: "trash", role: .destructive) {
                    withAnimation(.soft) {
                        filter = .all
                        app.library.shelf.deleteGroup(id)
                    }
                }
            }
        } label: {
            Image(icon: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Tok.fg)
                .glassCircle(40)
        }
        .menuOrder(.fixed)
    }

    // MARK: - 筛选与排序

    private func filterItems(_ books: [Book]) -> [(String, ShelfFilter)] {
        var items: [(String, ShelfFilter)] = [("全部", .all)]
        if books.contains(where: { $0.hasStarted && !$0.isFinished }) { items.append(("在读", .reading)) }
        if books.contains(where: \.isLocal) { items.append(("本地", .local)) }
        items += app.library.shelf.groups.map { ($0.groupName, .group($0.groupId)) }
        return items
    }

    private func filterIndex(_ items: [(String, ShelfFilter)]) -> Binding<Int> {
        Binding {
            items.firstIndex { $0.1 == filter } ?? 0
        } set: { index in
            guard items.indices.contains(index) else { return }
            withAnimation(.soft) { filter = items[index].1 }
        }
    }

    private func filtered(_ books: [Book]) -> [Book] {
        switch filter {
        case .all: books
        case .reading: books.filter { $0.hasStarted && !$0.isFinished }
        case .local: books.filter(\.isLocal)
        case .group(let id): books.filter { $0.group & id != 0 }
        }
    }

    private func sorted(_ books: [Book]) -> [Book] {
        let pinned = app.library.shelf.pinned
        return books.sorted { a, b in
            let pa = pinned.contains(a.bookUrl), pb = pinned.contains(b.bookUrl)
            if pa != pb { return pa }
            switch sort {
            case .recent:
                if a.durChapterTime != b.durChapterTime { return a.durChapterTime > b.durChapterTime }
            case .update:
                if a.lastCheckCount != b.lastCheckCount { return a.lastCheckCount > b.lastCheckCount }
                if a.latestChapterTime != b.latestChapterTime { return a.latestChapterTime > b.latestChapterTime }
            case .title:
                break
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private func refresh() async {
        let report = await app.library.refreshShelf()
        if report.checked == 0 {
            app.island.show("books.vertical", "没有可更新的书")
        } else if !report.updated.isEmpty {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            app.island.show("arrow.clockwise", "\(report.updated.count) 本有更新")
        } else if !report.failed.isEmpty {
            app.island.show("exclamationmark.triangle", "\(report.failed.count) 本更新失败", danger: true)
        } else {
            app.island.show("checkmark", "已是最新")
        }
    }
}

// MARK: - 网格项

/// 书籍菜单里需要弹层的操作（弹层挂在书架页上）
enum ShelfBookSheet: Identifiable {
    case edit(Book), source(Book), split(Book)

    var id: String {
        switch self {
        case .edit(let book): "edit-\(book.bookUrl)"
        case .source(let book): "source-\(book.bookUrl)"
        case .split(let book): "split-\(book.bookUrl)"
        }
    }
}

struct ShelfGridItem: View {
    let book: Book
    let pinned: Bool
    var selecting = false
    var selected = false
    var onSheet: (ShelfBookSheet) -> Void = { _ in }
    var onToggle: () -> Void = {}
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if selecting {
                    onToggle()
                } else {
                    app.openDetail(book, sourceID: "grid-\(book.bookUrl)")
                }
            } label: {
                BookCover(book: book)
                    .coverShadow()
                    .overlay(alignment: .topTrailing) { badge.opacity(selecting ? 0 : 1) }
                    .overlay(alignment: .bottomLeading) {
                        HStack(spacing: 4) {
                            if pinned {
                                Image(icon: "pin.fill")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 20, height: 20)
                                    .background(.black.opacity(0.35), in: Circle())
                            }
                            let kind = app.mediaKind(of: book)
                            if let label = kind.badge {
                                MediaBadge(symbol: kind.symbol, label: label)
                            }
                        }
                        .padding(6)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if selecting {
                            SelectMark(on: selected)
                                .padding(7)
                                .transition(.scale(scale: 0.4).combined(with: .opacity))
                        }
                    }
                    .scaleEffect(selected ? 0.93 : 1)
                    .animation(.bouncy, value: selected)
            }
            .buttonStyle(.pressSoft)
            .zoomSource("grid-\(book.bookUrl)")
            .coverFrame("grid-\(book.bookUrl)")
            .contextMenu {
                if !selecting { menu }
            } preview: {
                BookCover(book: book, maxPixel: 600)
                    .frame(width: 220)
                    .environment(app)
            }

            Text(book.name.withoutEmoji)
                .font(.ui(13, .medium))
                .foregroundStyle(Tok.fg)
                .lineLimit(1)
                .padding(.top, 10)
            if book.hasStarted, !book.isFinished {
                Hairline(value: book.readProgress, track: Tok.fill2, tint: Tok.fg2)
                    .padding(.top, 8)
            } else {
                Text(book.isFinished ? "读完" : "未读")
                    .font(.ui(11))
                    .foregroundStyle(Tok.fg3)
                    .padding(.top, 5)
            }
        }
    }

    @ViewBuilder
    private var badge: some View {
        if book.lastCheckCount > 0 {
            Text("\(book.lastCheckCount)")
                .font(.num(11, .bold))
                .foregroundStyle(Tok.onAccent)
                .padding(.horizontal, 6)
                .frame(minWidth: 21, minHeight: 21)
                .background(Tok.accent, in: Capsule())
                .overlay(Capsule().stroke(Tok.bg, lineWidth: 2.5))
                .offset(x: 7, y: -7)
                .transition(.scale.combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var menu: some View {
        Section {
            Button(book.hasStarted ? "继续阅读" : "开始阅读", icon: "book") {
                app.openReader(book, coverKey: "grid-\(book.bookUrl)")
            }
            Button("书籍详情", icon: "info.circle") {
                app.openDetail(book, sourceID: "grid-\(book.bookUrl)")
            }
        }
        Section {
            Button(pinned ? "取消置顶" : "置顶", icon: pinned ? "pin.slash" : "pin") {
                withAnimation(.soft) { app.library.shelf.togglePin(book.bookUrl) }
                if !pinned { app.island.show("pin", "已置顶") }
            }
            let groups = app.library.shelf.groups
            if !groups.isEmpty {
                Menu("分组", icon: "folder") {
                    ForEach(groups) { group in
                        let member = book.group & group.groupId != 0
                        Button {
                            let mask = member ? book.group & ~group.groupId : book.group | group.groupId
                            withAnimation(.soft) { app.library.shelf.setGroup(mask, for: [book.bookUrl]) }
                        } label: {
                            if member {
                                Label(group.groupName, icon: "checkmark")
                            } else {
                                Text(group.groupName)
                            }
                        }
                    }
                }
            }
            Button("编辑信息", icon: "pencil") { onSheet(.edit(book)) }
            if app.canResplit(book) {
                Button("重新分章", icon: "list.number") { onSheet(.split(book)) }
            }
        }
        if !book.isLocal {
            Section {
                Button("刷新目录", icon: "arrow.clockwise") { app.refreshToc(book) }
                Button("缓存全本", icon: "arrow.down.circle") { app.cacheBook(book) }
                Button("换源", icon: "arrow.triangle.2.circlepath") { onSheet(.source(book)) }
                Button("清除缓存", icon: "xmark.bin") { app.clearCache(book) }
            }
        }
        Button("移出书架", icon: "trash", role: .destructive) {
            withAnimation(.soft) { app.removeFromShelf(book) }
        }
    }
}

/// 多选勾选圈：未选为白色细环，选中填明黄并弹出对勾
private struct SelectMark: View {
    let on: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(on ? Tok.accent : .black.opacity(0.22))
            Circle()
                .strokeBorder(.white.opacity(on ? 0 : 0.9), lineWidth: 1.5)
            Image(icon: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Tok.onAccent)
                .scaleEffect(on ? 1 : 0.2)
                .opacity(on ? 1 : 0)
        }
        .frame(width: 24, height: 24)
        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
        .animation(.bouncy, value: on)
    }
}

enum ShelfBatchAction {
    case selectAll, group(Int64), newGroup, ungroup, pin, cache, remove
}

/// 书架多选的底部操作栏（位置与标签栏相同）
private struct ShelfBatchBar: View {
    let count: Int
    let allSelected: Bool
    let groups: [BookGroup]
    let currentGroup: Int64?
    let onAction: (ShelfBatchAction) -> Void

    var body: some View {
        HStack(spacing: 0) {
            item(allSelected ? "取消全选" : "全选", allSelected ? "circle.dashed" : "checklist", .selectAll, enabled: true)
            Menu {
                ForEach(groups) { group in
                    Button(group.groupName) { onAction(.group(group.groupId)) }
                }
                Divider()
                Button("新建分组", icon: "folder.badge.plus") { onAction(.newGroup) }
                if currentGroup != nil {
                    Button("移出当前分组", icon: "folder.badge.minus") { onAction(.ungroup) }
                }
            } label: {
                label("分组", "folder")
            }
            .menuOrder(.fixed)
            .disabled(count == 0)
            .opacity(count == 0 ? 0.4 : 1)
            item("置顶", "pin", .pin, enabled: count > 0)
            item("缓存", "arrow.down.circle", .cache, enabled: count > 0)
            item("移出", "trash", .remove, enabled: count > 0, tint: Tok.accentInk)
        }
        .padding(.horizontal, 8)
        .frame(height: 62)
        .glassSurface(Capsule(), strong: true)
        .padding(.horizontal, 16)
        .padding(.bottom, 22)
        .ignoresSafeArea(.container, edges: .bottom)
    }

    private func item(_ title: String, _ symbol: String, _ action: ShelfBatchAction, enabled: Bool, tint: Color = Tok.gFg) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onAction(action)
        } label: {
            label(title, symbol, tint: tint)
        }
        .buttonStyle(.press)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    private func label(_ title: String, _ symbol: String, tint: Color = Tok.gFg) -> some View {
        VStack(spacing: 4) {
            Image(icon: symbol)
                .font(.system(size: 18, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
            Text(title).font(.ui(10, .medium)).lineLimit(1)
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity, minHeight: 52)
        .contentShape(Rectangle())
    }
}

/// 空书架：图标里的柴犬弹出来摇尾巴，点一下再弹一次 + 找书 / 导入
private struct ShelfEmpty: View {
    @Binding var importing: Bool
    @Environment(AppModel.self) private var app
    @State private var risen = false
    @State private var start = Date()

    var body: some View {
        VStack(spacing: 34) {
            ShibaMark(start: start)
                .frame(width: 190, height: 164)
                .scaleEffect(risen ? 1 : 0.6, anchor: .bottom)
                .opacity(risen ? 1 : 0)
                .contentShape(Rectangle())
                .onTapGesture {
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    withAnimation(.easeIn(duration: 0.14)) { risen = false } completion: {
                        start = Date()
                        withAnimation(.spring(duration: 0.7, bounce: 0.45)) { risen = true }
                    }
                }
                .accessibilityHidden(true)
            HStack(spacing: 12) {
                AccentButton(title: "找书", icon: "magnifyingglass") { app.searching = true }
                Button {
                    importing = true
                } label: {
                    Label("导入", icon: "folder")
                        .font(.ui(16, .semibold))
                        .foregroundStyle(Tok.fg)
                        .padding(.horizontal, 22)
                        .frame(height: 46)
                        .raisedSurface(Capsule())
                }
                .buttonStyle(.press)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            withAnimation(.spring(duration: 0.7, bounce: 0.45).delay(0.2)) { risen = true }
        }
    }
}
