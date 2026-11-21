import ReaderModels
import ReaderServices
import SwiftUI

/// 搜索页（原型 `.view-search`）：空闲时是最近搜索与最近浏览；提交后各书源的结果逐个汇入，
/// 同一本书合并并累计来源数，顶部细进度条随完成的书源推进
struct SearchScreen: View {
    @Environment(AppModel.self) private var app
    @State private var scrolled = false
    @State private var settled = false

    var body: some View {
        let search = app.library.search
        ZStack(alignment: .top) {
            ScreenBackground()
            ScrollView {
                VStack(spacing: 0) {
                    LargeTitle(title: "搜索") { count(search) }
                    if search.keyword.isEmpty {
                        SearchIdle()
                    } else {
                        SearchResults(search: search)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .contentMargins(.top, 6, for: .scrollContent)
            .contentMargins(.bottom, 124, for: .scrollContent)
            .trackScroll($scrolled)
            .id(search.keyword)
            CompactHeader(title: "搜索", visible: scrolled)
            SearchProgress(value: search.total == 0 ? 0 : Double(search.completed) / Double(search.total),
                           running: search.isSearching)
        }
        .onChange(of: app.searchText) { _, text in
            if text.isEmpty { app.library.search.clear() }
        }
        .onChange(of: search.isSearching) { _, running in
            settled = false
            guard !running else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                if !app.library.search.isSearching { settled = true }
            }
        }
    }

    @ViewBuilder
    private func count(_ search: SearchModel) -> some View {
        Group {
            if search.isSearching {
                Text("\(search.completed)/\(search.total)")
                    .contentTransition(.numericText(value: Double(search.completed)))
            } else if settled, !search.results.isEmpty {
                Text("\(search.results.count) 本")
            }
        }
        .font(.num(13))
        .foregroundStyle(Tok.fg3)
        .animation(.snappy, value: search.completed)
    }
}

/// 顶部细进度条（原型 `.s-progress`）
private struct SearchProgress: View {
    let value: Double
    let running: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Tok.fill)
                Capsule().fill(Tok.accent).frame(width: proxy.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 2)
        .padding(.horizontal, 20)
        .padding(.top, -3)
        .opacity(running ? 1 : 0)
        .animation(.out, value: value)
        .animation(.easeOut(duration: 0.4), value: running)
        .allowsHitTesting(false)
    }
}

// MARK: - 空闲

private struct SearchIdle: View {
    @Environment(AppModel.self) private var app
    @State private var clearing = false

    var body: some View {
        let history = Array(app.library.searchHistory.keywords.prefix(18))
        let recent = app.recent.books
        VStack(alignment: .leading, spacing: 0) {
            if !history.isEmpty {
                SectionHeader(title: "最近搜索") {
                    Button(action: clear) {
                        Image(icon: "trash")
                            .font(.system(size: 16))
                            .foregroundStyle(Tok.fg3)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.press)
                    .accessibilityLabel("清空")
                }
                FlowLayout(spacing: 8) {
                    ForEach(Array(history.enumerated()), id: \.element) { index, keyword in
                        Button {
                            app.searchText = keyword
                            app.startSearch(keyword)
                        } label: {
                            Text(keyword)
                                .font(.ui(14))
                                .foregroundStyle(Tok.fg)
                                .lineLimit(1)
                                .padding(.horizontal, 15)
                                .frame(height: 36)
                                .raisedSurface(Capsule())
                        }
                        .buttonStyle(.press)
                        .contextMenu {
                            Button("删除", icon: "trash", role: .destructive) {
                                withAnimation(.snappy) { app.library.searchHistory.remove(keyword) }
                            }
                        }
                        .scaleEffect(clearing ? 0.6 : 1)
                        .opacity(clearing ? 0 : 1)
                        .animation(.easeIn(duration: 0.18).delay(Double(index) * 0.024), value: clearing)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 20)
            }
            if !recent.isEmpty {
                SectionHeader("最近浏览")
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(recent) { book in
                            RecentItem(book: book)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 6)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func clear() {
        let count = min(app.library.searchHistory.keywords.count, 18)
        clearing = true
        Task {
            try? await Task.sleep(for: .milliseconds(180 + count * 24))
            app.library.searchHistory.clear()
            clearing = false
        }
    }
}

private struct RecentItem: View {
    let book: Book
    @Environment(AppModel.self) private var app

    var body: some View {
        let id = "recent-\(book.bookUrl)"
        Button {
            app.openDetail(book, sourceID: id)
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                BookCover(book: book)
                    .frame(width: 92)
                    .coverShadow()
                    .zoomSource(id)
                Text(book.name.withoutEmoji)
                    .font(.ui(12))
                    .foregroundStyle(Tok.fg2)
                    .lineLimit(1)
                    .frame(width: 92, alignment: .leading)
            }
        }
        .buttonStyle(.pressSoft)
        .contextMenu {
            Button("移除", icon: "xmark") {
                withAnimation(.snappy) { app.recent.remove(book) }
            }
        }
    }
}

/// 书架里书名或作者匹配的书，点开直接继续阅读
private struct ShelfMatchItem: View {
    let book: Book
    @Environment(AppModel.self) private var app

    var body: some View {
        let id = "match-\(book.bookUrl)"
        Button {
            app.openReader(book, coverKey: id)
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                BookCover(book: book)
                    .frame(width: 72)
                    .coverShadow()
                    .coverFrame(id)
                Text(book.name.withoutEmoji)
                    .font(.ui(12))
                    .foregroundStyle(Tok.fg2)
                    .lineLimit(1)
                    .frame(width: 72, alignment: .leading)
            }
        }
        .buttonStyle(.pressSoft)
        .contextMenu {
            Button("书籍详情", icon: "info.circle") { app.openDetail(book) }
        }
    }
}

// MARK: - 结果

private struct SearchResults: View {
    let search: SearchModel
    @Environment(AppModel.self) private var app
    @State private var showFailures = false

    var body: some View {
        let results = search.results
        let finished = !search.isSearching
        let keyword = search.keyword
        let local = app.library.shelf.books.filter {
            $0.name.localizedCaseInsensitiveContains(keyword) || $0.author.localizedCaseInsensitiveContains(keyword)
        }
        LazyVStack(spacing: 0) {
            if !local.isEmpty {
                SectionHeader("书架")
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(local) { book in
                            ShelfMatchItem(book: book)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 6)
                }
                .scrollIndicators(.hidden)
                .padding(.bottom, 10)
            }
            ForEach(results) { book in
                SearchRow(book: book, keyword: search.keyword)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 18)), removal: .opacity))
            }
            if finished, search.canLoadMore, !results.isEmpty {
                ProgressView()
                    .frame(height: 64)
                    .onAppear { search.loadMore() }
            }
            if finished { footer(results.isEmpty) }
        }
        .padding(.top, 4)
        .animation(.snappy, value: results.map(\.id))
    }

    @ViewBuilder
    private func footer(_ empty: Bool) -> some View {
        if search.total == 0 {
            VStack(spacing: 16) {
                Image(icon: "square.stack.3d.up.slash")
                    .font(.system(size: 34, weight: .light))
                Text("没有启用的书源").font(.ui(14))
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
            .padding(.top, 150)
        } else if empty {
            VStack(spacing: 12) {
                Image(icon: "magnifyingglass").font(.system(size: 34, weight: .light))
                Text("无结果").font(.ui(14))
            }
            .foregroundStyle(Tok.fg3)
            .padding(.top, 150)
            .transition(.opacity)
        }
        if !search.failures.isEmpty {
            VStack(spacing: 10) {
                Button {
                    withAnimation(.snappy) { showFailures.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text("\(search.failures.count) 个书源出错")
                        Image(icon: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(showFailures ? 180 : 0))
                    }
                    .font(.ui(12))
                    .foregroundStyle(Tok.fg3)
                    .frame(height: 32)
                }
                .buttonStyle(.plain)
                if showFailures {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(search.failures) { failure in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(failure.sourceName).font(.ui(12, .medium)).foregroundStyle(Tok.fg2)
                                Text(failure.message).font(.ui(11)).foregroundStyle(Tok.fg3).lineLimit(2)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .transition(.opacity)
                }
            }
            .padding(.top, 16)
        }
    }
}

private struct SearchRow: View {
    let book: AggregatedBook
    let keyword: String
    @Environment(AppModel.self) private var app

    var body: some View {
        let id = "search-\(book.key)"
        Button {
            var target = book.primary.toBook()
            if target.coverUrl.nilIfEmpty == nil { target.coverUrl = book.coverUrl }
            app.openDetail(target, alternatives: book.items, sourceID: id)
        } label: {
            HStack(spacing: 14) {
                BookCover(title: book.name, author: book.author, url: book.coverUrl, book: book.primary.toBook())
                    .frame(width: 60)
                    .coverShadow()
                    .zoomSource(id)
                VStack(alignment: .leading, spacing: 5) {
                    Text(highlighted(book.name.withoutEmoji))
                        .font(.serif(18))
                        .foregroundStyle(Tok.fg)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.ui(13))
                        .foregroundStyle(Tok.fg2)
                        .lineLimit(1)
                    if let latest = book.latestChapterTitle {
                        Text(latest.withoutEmoji)
                            .font(.ui(12))
                            .foregroundStyle(Tok.fg3)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                SourceCount(count: book.sourceCount)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .buttonStyle(.row)
    }

    private var subtitle: String {
        BookText.join(book.author, BookText.kind(book.kind), book.wordCount)
    }

    private func highlighted(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard !keyword.isEmpty else { return result }
        var start = result.startIndex
        while start < result.endIndex, let range = result[start...].range(of: keyword) {
            result[range].foregroundColor = Tok.accentInk
            start = range.upperBound
        }
        return result
    }
}

/// 来源数：数字滚动，增加时轻弹一下（原型 `.s-src`）
private struct SourceCount: View {
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text("\(count)")
                .font(.num(15, .semibold))
                .foregroundStyle(Tok.fg)
                .contentTransition(.numericText(value: Double(count)))
            Text("源")
                .font(.ui(11))
                .foregroundStyle(Tok.fg3)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Tok.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .keyframeAnimator(initialValue: 1.0, trigger: count) { view, scale in
            view.scaleEffect(scale)
        } keyframes: { _ in
            CubicKeyframe(1.18, duration: 0.14)
            CubicKeyframe(1, duration: 0.18)
        }
        .animation(.snappy, value: count)
    }
}
