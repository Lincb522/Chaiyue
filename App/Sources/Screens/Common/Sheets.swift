import ReaderModels
import ReaderServices
import SwiftUI

extension View {
    /// 统一的弹层外观：iOS 26 用系统玻璃，更早的系统用材质底
    func qSheet(_ detents: Set<PresentationDetent> = [.large]) -> some View {
        presentationDetents(detents)
            .presentationDragIndicator(.visible)
            .modifier(SheetBackground())
    }
}

private struct SheetBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
        } else {
            content
                .presentationBackground(.regularMaterial)
                .presentationCornerRadius(38)
        }
    }
}

/// 弹层标题行（原型 `.sheet-head`）
struct SheetHeader<Trailing: View>: View {
    let title: String
    var count: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.serif(22)).foregroundStyle(Tok.gFg)
            if let count {
                Text(count)
                    .font(.num(14))
                    .foregroundStyle(Tok.gFg3)
                    .contentTransition(.numericText())
            }
            Spacer()
            trailing
        }
        .padding(.leading, 24)
        .padding(.trailing, 16)
        .padding(.top, 26)
        .padding(.bottom, 12)
    }
}

extension SheetHeader where Trailing == EmptyView {
    init(title: String, count: String? = nil) {
        self.title = title
        self.count = count
        trailing = EmptyView()
    }
}

/// 2pt 进度线，完成后淡出
struct ProgressLine: View {
    var value: Double
    var done: Bool

    var body: some View {
        Hairline(value: value, track: Tok.gFill, tint: Tok.accent, height: 2)
            .animation(.out, value: value)
            .opacity(done ? 0 : 1)
            .animation(.easeOut(duration: 0.4).delay(done ? 0.4 : 0), value: done)
    }
}

// MARK: - 换源

struct ChangeSourceSheet: View {
    let book: Book
    let onChanged: (Book) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model: ChangeSourceModel?
    @State private var switching: String?
    @State private var spin = 0.0

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "换源", count: model.map { "\($0.candidates.count)" }) {
                Button {
                    withAnimation(.out.speed(0.75)) { spin += 360 }
                    model?.refresh()
                } label: {
                    Image(icon: "arrow.clockwise")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Tok.gFg2)
                        .rotationEffect(.degrees(spin))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.press)
            }
            if let model {
                ProgressLine(value: model.total > 0 ? Double(model.completed) / Double(model.total) : 0,
                             done: !model.isSearching)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.candidates) { candidate in
                            row(candidate)
                                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 14)), removal: .opacity))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 22)
                    .animation(.soft, value: model.candidates.map(\.id))
                }
                .overlay {
                    if model.candidates.isEmpty, !model.isSearching {
                        Image(icon: "rectangle.stack.badge.minus")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(Tok.gFg3)
                    }
                }
            } else {
                Spacer()
            }
        }
        .task {
            let model = app.library.changeSourceModel(for: book)
            self.model = model
            model.start()
        }
        .onDisappear { model?.cancel() }
    }

    private func row(_ candidate: SourceCandidate) -> some View {
        let on = candidate.isCurrent
        return Button {
            pick(candidate)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(SourceName.full(candidate.book.originName.isEmpty ? candidate.book.origin : candidate.book.originName))
                        .font(.ui(16, .medium))
                        .foregroundStyle(on ? Tok.gAccent : Tok.gFg)
                        .lineLimit(1)
                    if let latest = candidate.book.latestChapterTitle, !latest.isEmpty {
                        Text(latest.withoutEmoji)
                            .font(.ui(12))
                            .foregroundStyle(Tok.gFg3)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if switching == candidate.id {
                    ProgressView().controlSize(.small)
                } else if candidate.book.respondTime > 0 {
                    Text("\(candidate.book.respondTime) ms")
                        .font(.num(12))
                        .foregroundStyle(Tok.gFg3)
                }
                Image(icon: "checkmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Tok.gAccent)
                    .frame(width: 22)
                    .opacity(on ? 1 : 0)
                    .scaleEffect(on ? 1 : 0.2)
                    .animation(.bouncy, value: on)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 66)
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(RowPressStyle(color: Tok.gFill))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .disabled(switching != nil)
    }

    private func pick(_ candidate: SourceCandidate) {
        guard !candidate.isCurrent, switching == nil else { return }
        switching = candidate.id
        Task {
            do {
                let result = try await app.library.changeSource(of: book, to: candidate.book)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onChanged(result.book)
                app.island.show("arrow.triangle.2.circlepath", "已切换到 \(SourceName.display(candidate.book.originName))")
                try? await Task.sleep(for: .milliseconds(320))
                dismiss()
            } catch {
                app.island.show("exclamationmark.triangle", error.localizedDescription, danger: true)
            }
            switching = nil
        }
    }
}

// MARK: - 目录

struct TocSheet: View {
    let chapters: [BookChapter]
    let current: Int
    var bookUrl: String
    var bookmarks: [Bookmark]?
    var state: ReaderSession.TocState = .ready
    var onRetry: (() -> Void)?
    let onPick: (Int) -> Void
    var onBookmark: ((Bookmark) -> Void)?
    var onDeleteBookmark: ((Bookmark) -> Void)?

    @Environment(AppModel.self) private var app
    @State private var tab = 0
    @State private var reversed = false
    @State private var cached: Set<String> = []

    private struct Section: Identifiable {
        let id: Int
        let title: String?
        let items: [BookChapter]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if bookmarks != nil {
                    SegmentedChips(items: ["目录", "书签"], selection: $tab, height: 32, font: .ui(14), itemWidth: 96, inset: 3, glass: true)
                } else {
                    Text("目录").font(.serif(22)).foregroundStyle(Tok.gFg)
                    Text("\(chapters.count)").font(.num(14)).foregroundStyle(Tok.gFg3)
                }
                Spacer()
                if tab == 0 {
                    Button {
                        withAnimation(.soft) { reversed.toggle() }
                    } label: {
                        Image(icon: "arrow.up.arrow.down")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(reversed ? Tok.gAccent : Tok.gFg2)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.press)
                }
            }
            .padding(.leading, bookmarks != nil ? 20 : 24)
            .padding(.trailing, 14)
            .padding(.top, 24)
            .padding(.bottom, 10)

            ZStack {
                if tab == 0 {
                    chapterList.transition(.move(edge: .leading).combined(with: .opacity))
                } else {
                    bookmarkList.transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.soft, value: tab)
        }
        .task(id: chapters.count) {
            let store = app.library.chapterStore
            let url = bookUrl
            cached = await Task.detached(priority: .utility) { store.cachedFileNames(bookUrl: url) }.value
        }
    }

    @ViewBuilder
    private var chapterList: some View {
        switch state {
        case .loading where chapters.isEmpty, .idle where chapters.isEmpty:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message) where chapters.isEmpty:
            VStack(spacing: 14) {
                Text(message)
                    .font(.ui(14))
                    .foregroundStyle(Tok.gFg3)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                if let onRetry {
                    Button("重试", action: onRetry)
                        .font(.ui(15, .semibold))
                        .foregroundStyle(Tok.gAccent)
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections) { section in
                            SwiftUI.Section {
                                ForEach(section.items, id: \.index) { chapter in
                                    chapterRow(chapter).id(chapter.index)
                                }
                            } header: {
                                if let title = section.title {
                                    Text(title)
                                        .font(.ui(12))
                                        .tracking(1)
                                        .foregroundStyle(Tok.gFg3)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 24)
                                        .padding(.top, 12)
                                        .padding(.bottom, 8)
                                        .background(.ultraThinMaterial.opacity(0.9))
                                }
                            }
                        }
                    }
                    .padding(.bottom, 24)
                }
                .onAppear { proxy.scrollTo(current, anchor: .center) }
                .onChange(of: reversed) { proxy.scrollTo(current, anchor: .center) }
            }
        }
    }

    private var sections: [Section] {
        var result: [Section] = []
        var title: String?
        var items: [BookChapter] = []
        var sectionID = 0
        for chapter in chapters {
            if chapter.isVolume {
                if !items.isEmpty || title != nil {
                    result.append(Section(id: sectionID, title: title, items: reversed ? items.reversed() : items))
                }
                sectionID += 1
                title = chapter.title
                items = []
            } else {
                items.append(chapter)
            }
        }
        if !items.isEmpty || title != nil {
            result.append(Section(id: sectionID, title: title, items: reversed ? items.reversed() : items))
        }
        return reversed ? result.reversed() : result
    }

    private func chapterRow(_ chapter: BookChapter) -> some View {
        let on = chapter.index == current
        return Button {
            onPick(chapter.index)
        } label: {
            HStack(spacing: 10) {
                Text("\(chapter.index + 1)")
                    .font(.num(12))
                    .foregroundStyle(on ? Tok.gAccent : Tok.gFg3)
                    .frame(width: 42, alignment: .leading)
                Text(chapter.title.withoutEmoji)
                    .font(.ui(15, on ? .semibold : .regular))
                    .foregroundStyle(on ? Tok.gAccent : Tok.gFg)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if chapter.isVip, !chapter.isPay {
                    Image(icon: "lock.fill").font(.system(size: 10)).foregroundStyle(Tok.gFg3)
                }
                if cached.contains(ChapterStore.fileName(for: chapter)) {
                    Circle().fill(Tok.gFg3).frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 24)
            .frame(height: 50)
            .overlay(alignment: .leading) {
                if on {
                    Capsule().fill(Tok.accent).frame(width: 3, height: 18).padding(.leading, 11)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPressStyle(color: Tok.gFill))
    }

    @ViewBuilder
    private var bookmarkList: some View {
        let marks = bookmarks ?? []
        if marks.isEmpty {
            Image(icon: "bookmark")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Tok.gFg3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(marks) { mark in
                    Button {
                        onBookmark?(mark)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(mark.chapterName)
                                .font(.ui(12))
                                .foregroundStyle(Tok.gFg3)
                                .lineLimit(1)
                            Text(mark.bookText)
                                .font(.serif(15, bold: false))
                                .foregroundStyle(Tok.gFg)
                                .lineLimit(2)
                            if !mark.content.isEmpty {
                                Text(mark.content).font(.ui(13)).foregroundStyle(Tok.gFg2).lineLimit(2)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(Tok.gLine)
                    .swipeActions {
                        Button("删除", icon: "trash", role: .destructive) { onDeleteBookmark?(mark) }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }
}

// MARK: - 编辑书籍信息

/// 书名、作者、封面与简介（留空即用书源提供的），以及是否参与书架更新检查
struct BookEditSheet: View {
    let book: Book
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var author: String
    @State private var cover: String
    @State private var intro: String
    @State private var canUpdate: Bool

    init(book: Book) {
        self.book = book
        _name = State(initialValue: book.name)
        _author = State(initialValue: book.author)
        _cover = State(initialValue: book.displayCover ?? "")
        _intro = State(initialValue: book.displayIntro ?? "")
        _canUpdate = State(initialValue: book.canUpdate)
    }

    private var preview: Book {
        var value = book
        value.name = name
        value.author = author
        let link = cover.trimmingCharacters(in: .whitespaces)
        value.customCoverUrl = link.isEmpty ? nil : link
        return value
    }

    private var valid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "编辑信息") {
                Button(action: save) {
                    Image(icon: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Tok.onAccent)
                        .frame(width: 36, height: 36)
                        .background(Tok.accent, in: Circle())
                }
                .buttonStyle(.press)
                .disabled(!valid)
                .opacity(valid ? 1 : 0.4)
            }
            ScrollView {
                VStack(spacing: 12) {
                    HStack(alignment: .top, spacing: 14) {
                        BookCover(book: preview)
                            .frame(width: 80)
                            .coverShadow()
                        VStack(spacing: 10) {
                            field("书名", text: $name)
                            field("作者", text: $author)
                        }
                    }
                    .padding(.bottom, 6)
                    field("封面链接", text: $cover)
                        .keyboardType(.URL)
                    TextField("简介", text: $intro, axis: .vertical)
                        .font(.serif(15, bold: false))
                        .foregroundStyle(Tok.gFg)
                        .lineLimit(4...12)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 15)
                        .background(Tok.gFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    if !book.isLocal {
                        CardGroup(separatorInset: 14) {
                            ToggleRow(title: "检查更新", isOn: $canUpdate)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
        .environment(\.onGlass, true)
        .qSheet([.large])
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .font(.ui(16))
            .foregroundStyle(Tok.gFg)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 18)
            .frame(height: 50)
            .background(Tok.gFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func save() {
        guard valid else { return }
        var edited = app.library.shelf.book(book.bookUrl) ?? book
        edited.name = name.trimmingCharacters(in: .whitespaces)
        edited.author = author.trimmingCharacters(in: .whitespaces)
        let coverValue = cover.trimmingCharacters(in: .whitespaces)
        edited.customCoverUrl = coverValue.isEmpty || coverValue == book.coverUrl ? nil : coverValue
        let introValue = intro.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceIntro = (book.intro ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        edited.customIntro = introValue.isEmpty || introValue == sourceIntro ? nil : introValue
        edited.canUpdate = canUpdate
        app.library.shelf.update(edited)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }
}

// MARK: - 时间

enum TimeText {
    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f
    }()

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f
    }()

    /// 毫秒时间戳：一周内显示「3小时前」，更早显示日期
    static func since(_ millis: Int64) -> String? {
        guard millis > 0 else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
        if Date().timeIntervalSince(date) < 7 * 86400 {
            return relative.localizedString(for: date, relativeTo: Date())
        }
        return day.string(from: date)
    }
}
