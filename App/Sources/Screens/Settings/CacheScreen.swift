import ReaderModels
import ReaderServices
import SwiftUI

/// 缓存管理：占用总览、正在进行的全本缓存、按书查看与清理
struct CacheScreen: View {
    @Environment(AppModel.self) private var app
    @State private var usage: CacheUsage?
    @State private var scrolled = false
    @State private var confirming = false
    @State private var appeared = false

    private var downloads: CacheDownloadManager { app.library.downloads }

    var body: some View {
        ZStack(alignment: .top) {
            ScreenBackground()
            ScrollView {
                VStack(spacing: 0) {
                    HStack {
                        Text("缓存").font(.serif(34)).tracking(0.5).foregroundStyle(Tok.fg)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 50)
                    .padding(.bottom, 14)

                    UsageCard(usage: usage, shown: appeared)
                        .padding(.horizontal, 16)

                    if !downloads.tasks.isEmpty {
                        tasks
                    }
                    if let books = usage?.books, !books.isEmpty {
                        CardGroup(separatorInset: 70) {
                            ForEach(books) { item in
                                BookCacheRow(item: item, task: downloads.task(for: item.id)) {
                                    app.cacheBook(item.book)
                                }
                                .contextMenu {
                                    Button("缓存全本", icon: "arrow.down.circle") { app.cacheBook(item.book) }
                                    Button("清除缓存", icon: "trash", role: .destructive) { clear(item) }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .entrance(appeared, delay: 0.1, rise: 20)
                    }
                    if (usage?.total ?? 0) > 0 {
                        Button {
                            confirming = true
                        } label: {
                            Text("清除全部缓存")
                                .font(.ui(16))
                                .foregroundStyle(Tok.accentInk)
                                .frame(maxWidth: .infinity, minHeight: 56)
                        }
                        .buttonStyle(.row)
                        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
                        .cardSurface()
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .transition(.opacity)
                    }
                }
                .padding(.bottom, 56)
                .animation(.snappy, value: usage?.books.map(\.id))
            }
            .scrollIndicators(.hidden)
            .trackScroll($scrolled, threshold: 60)
            PageBar(title: "缓存", scrolled: scrolled)
        }
        .confirmationDialog("清除全部缓存", isPresented: $confirming, titleVisibility: .visible) {
            Button("清除", role: .destructive) { Task { await clearAll() } }
        } message: {
            Text("已下载的章节与封面都会删除，书架不受影响")
        }
        .task {
            appeared = true
            await refresh()
        }
        .onChange(of: downloads.tasks.map(\.cachedCount)) { _, _ in
            Task { await refresh() }
        }
    }

    private var tasks: some View {
        CardGroup(separatorInset: 70) {
            ForEach(downloads.tasks) { task in
                DownloadRow(task: task, book: app.library.shelf.books.first { $0.bookUrl == task.bookUrl }) {
                    switch task.state {
                    case .downloading, .waiting: downloads.pause(task.bookUrl)
                    case .paused: downloads.resume(task.bookUrl)
                    case .failed: downloads.retryFailed(task.bookUrl)
                    case .finished:
                        if task.failedCount > 0 { downloads.retryFailed(task.bookUrl) } else { downloads.remove(task.bookUrl) }
                    }
                }
                .contextMenu {
                    Button("移除任务", icon: "xmark") { downloads.remove(task.bookUrl) }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    private func refresh() async {
        let next = await CacheUsage.measure(app)
        withAnimation(.soft) { usage = next }
    }

    private func clear(_ item: BookUsage) {
        let store = app.library.chapterStore
        downloads.remove(item.id)
        Task {
            await Task.detached(priority: .userInitiated) { store.clear(bookUrl: item.id) }.value
            app.island.show("trash", "已清除 \(Formats.size(item.size))", danger: true)
            await refresh()
        }
    }

    private func clearAll() async {
        let freed = usage?.total ?? 0
        let store = app.library.chapterStore
        downloads.pauseAll()
        await Task.detached(priority: .userInitiated) { store.clearAll() }.value
        await app.library.images.clear()
        ImagePipeline.shared.clearMemory()
        downloads.removeFinished()
        app.island.show("trash", "已清除 \(Formats.size(freed))", danger: true)
        await refresh()
    }
}

// MARK: - 数据

nonisolated struct BookUsage: Identifiable, Equatable, Sendable {
    let book: Book
    let size: Int64
    let cached: Int
    var id: String { book.bookUrl }
}

nonisolated struct CacheUsage: Equatable, Sendable {
    var chapters: Int64
    var images: Int64
    var books: [BookUsage]
    var total: Int64 { chapters + images }

    @MainActor
    static func measure(_ app: AppModel) async -> CacheUsage {
        let store = app.library.chapterStore
        let books = app.library.shelf.books.filter { !$0.isLocal }
        let (chapters, items) = await Task.detached(priority: .utility) { () -> (Int64, [BookUsage]) in
            let items = books.compactMap { book -> BookUsage? in
                let cached = store.cachedFileNames(bookUrl: book.bookUrl).count
                guard cached > 0 else { return nil }
                return BookUsage(book: book, size: directorySize(store.directory(for: book.bookUrl)), cached: cached)
            }
            return (store.totalSize(), items.sorted { $0.size > $1.size })
        }.value
        return CacheUsage(chapters: chapters, images: await app.library.images.totalSize(), books: items)
    }

    nonisolated private static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

// MARK: - 总览

/// 占用总数 + 正文与封面的比例条
private struct UsageCard: View {
    let usage: CacheUsage?
    let shown: Bool

    var body: some View {
        let total = usage?.total ?? 0
        let chapters = usage?.chapters ?? 0
        let images = usage?.images ?? 0
        VStack(alignment: .leading, spacing: 16) {
            Text(usage == nil ? " " : Formats.size(total))
                .font(.system(size: 42, weight: .light))
                .monospacedDigit()
                .tracking(-1.2)
                .foregroundStyle(Tok.fg)
                .contentTransition(.numericText())
            GeometryReader { proxy in
                let width = proxy.size.width
                let first = total > 0 ? width * CGFloat(chapters) / CGFloat(total) : 0
                let second = total > 0 ? width * CGFloat(images) / CGFloat(total) : 0
                HStack(spacing: 2) {
                    Capsule().fill(Tok.accent).frame(width: shown ? max(first - 1, 0) : 0)
                    Capsule().fill(Tok.fg3).frame(width: shown ? max(second - 1, 0) : 0)
                    Spacer(minLength: 0)
                }
                .frame(width: width, height: 8, alignment: .leading)
                .background(Tok.fill, in: Capsule())
            }
            .frame(height: 8)
            HStack(spacing: 18) {
                legend("正文", chapters, Tok.accent)
                legend("封面", images, Tok.fg3)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .animation(.soft, value: usage)
        .animation(.soft.delay(0.15), value: shown)
    }

    private func legend(_ title: String, _ value: Int64, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.ui(13)).foregroundStyle(Tok.fg2)
            Text(usage == nil ? "" : Formats.size(value))
                .font(.num(13))
                .foregroundStyle(Tok.fg3)
                .contentTransition(.numericText())
        }
    }
}

// MARK: - 行

private struct BookCacheRow: View {
    let item: BookUsage
    let task: CacheTask?
    let onDownload: () -> Void

    var body: some View {
        let total = item.book.totalChapterNum
        HStack(spacing: 14) {
            BookCover(book: item.book, maxPixel: 120)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.book.name.withoutEmoji)
                    .font(.ui(16))
                    .foregroundStyle(Tok.fg)
                    .lineLimit(1)
                Text(BookText.join(total > 0 ? "\(item.cached) / \(total) 章" : "\(item.cached) 章", Formats.size(item.size)))
                    .font(.num(12))
                    .foregroundStyle(Tok.fg3)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 8)
            if task == nil, total == 0 || item.cached < total {
                Button(action: onDownload) {
                    Image(icon: "arrow.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Tok.fg2)
                        .frame(width: 34, height: 34)
                        .background(Tok.fill, in: Circle())
                }
                .buttonStyle(.press)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct DownloadRow: View {
    let task: CacheTask
    let book: Book?
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let book {
                    BookCover(book: book, maxPixel: 120)
                } else {
                    BookCover(title: task.bookName, author: "", url: nil, book: nil, maxPixel: 120)
                }
            }
            .frame(width: 36)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(task.bookName)
                        .font(.ui(16))
                        .foregroundStyle(Tok.fg)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(status)
                        .font(.num(12))
                        .foregroundStyle(isFailed ? Tok.accentInk : Tok.fg3)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: status)
                }
                Hairline(value: task.fractionCompleted, track: Tok.fill2, tint: task.state == .paused ? Tok.fg3 : Tok.accent, height: 3)
                    .animation(.out, value: task.fractionCompleted)
            }
            Button(action: onTap) {
                Image(icon: symbol)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Tok.fg2)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 34, height: 34)
                    .background(Tok.fill, in: Circle())
            }
            .buttonStyle(.press)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var isFailed: Bool {
        if case .failed = task.state { return true }
        return task.failedCount > 0 && task.state == .finished
    }

    private var status: String {
        switch task.state {
        case .waiting: return task.chapterCount == 0 ? "排队" : "\(task.cachedCount)/\(task.chapterCount)"
        case .downloading: return "\(task.cachedCount)/\(task.chapterCount)"
        case .paused: return "暂停 · \(task.cachedCount)/\(task.chapterCount)"
        case .finished: return task.failedCount > 0 ? "\(task.failedCount) 章失败" : "完成"
        case .failed(let message): return message
        }
    }

    private var symbol: String {
        switch task.state {
        case .waiting, .downloading: "pause.fill"
        case .paused: "play.fill"
        case .failed: "arrow.clockwise"
        case .finished: task.failedCount > 0 ? "arrow.clockwise" : "checkmark"
        }
    }
}
