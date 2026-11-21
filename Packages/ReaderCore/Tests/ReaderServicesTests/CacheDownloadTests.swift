import Foundation
import ReaderModels
@testable import ReaderServices
import RuleEngine
import Testing

/// 记录请求顺序与同时进行的请求数
final class RecordingTransport: HTTPTransport, @unchecked Sendable {
    let base: StubTransport
    private let lock = NSLock()
    private var urls: [String] = []
    private var current = 0
    private var peak = 0

    init(base: StubTransport) {
        self.base = base
    }

    func send(_ request: HTTPRequest) throws -> HTTPResponse {
        lock.withLock {
            urls.append(request.url)
            current += 1
            peak = max(peak, current)
        }
        defer { lock.withLock { current -= 1 } }
        return try base.send(request)
    }

    var requested: [String] { lock.withLock { urls } }
    var maximumConcurrent: Int { lock.withLock { peak } }
}

@Suite("全本缓存")
@MainActor
struct CacheDownloadTests {
    let transport = StubTransport()
    let recorder: RecordingTransport
    let services: LibraryServices
    let src: BookSource

    init() throws {
        recorder = RecordingTransport(base: transport)
        services = LibraryServices(dataDirectory: tempDirectory(), cacheDirectory: tempDirectory(), http: recorder)
        src = try jsonSource()
        services.apply(.bookSources([src]))
    }

    func titles(_ count: Int) -> [String] {
        (1...count).map { "第\($0)章" }
    }

    /// 正文请求放慢，便于观察并发与暂停
    func slowContent(_ server: BookServer, delay: TimeInterval) {
        transport.on("\(server.host)/c/\(server.bookID)/") { request in
            Thread.sleep(forTimeInterval: delay)
            let title = BookServer.decode(String(request.url.split(separator: "/").last ?? ""))
            let body = try! JSONSerialization.data(withJSONObject: ["c": "\(title)\n　　正文。"])
            return HTTPResponse(url: request.url, headers: ["Content-Type": "application/json"], body: body)
        }
    }

    func isFinished(_ bookUrl: String) -> Bool {
        services.downloads.task(for: bookUrl)?.state == .finished
    }

    @Test func 全本缓存跳过已缓存章节() async throws {
        let server = BookServer(transport: transport, titles: titles(10))
        let book = server.book(origin: src.bookSourceUrl)
        let service = services.contentService(for: book)
        let (_, chapters) = try await service.chapters(for: book)
        _ = try await service.content(for: book, chapter: chapters[0], nextChapter: chapters[1])

        #expect(services.downloads.enqueue(book))
        #expect(services.downloads.isActive)
        try await waitUntil { isFinished(book.bookUrl) }
        let task = try #require(services.downloads.task(for: book.bookUrl))
        #expect(task.chapterCount == 10 && task.cachedCount == 10 && task.failedCount == 0)
        #expect(task.fractionCompleted == 1)
        #expect(server.hits.count("content") == 10)
        #expect(chapters.allSatisfy { services.chapterStore.hasContent(bookUrl: book.bookUrl, chapter: $0) })
        #expect(!services.downloads.isActive)
    }

    @Test func 限制同时进行的请求数() async throws {
        let server = BookServer(transport: transport, titles: titles(12))
        slowContent(server, delay: 0.05)
        let book = server.book(origin: src.bookSourceUrl)
        services.downloads.concurrency = 3
        services.downloads.enqueue(book)
        try await waitUntil { isFinished(book.bookUrl) }
        #expect(services.downloads.task(for: book.bookUrl)?.cachedCount == 12)
        #expect(recorder.maximumConcurrent <= 3)
        #expect(recorder.maximumConcurrent >= 2)
    }

    @Test func 多本书按加入顺序依次下载() async throws {
        let first = BookServer(transport: transport, bookID: 1, titles: titles(3))
        let second = BookServer(transport: transport, bookID: 2, titles: titles(3))
        services.downloads.concurrency = 1
        services.downloads.enqueue(first.book(origin: src.bookSourceUrl))
        services.downloads.enqueue(second.book(origin: src.bookSourceUrl))
        try await waitUntil { isFinished(first.bookUrl) && isFinished(second.bookUrl) }
        let urls = recorder.requested
        let lastOfFirst = try #require(urls.lastIndex { $0.hasPrefix("https://j.test/c/1/") })
        let firstOfSecond = try #require(urls.firstIndex { $0.hasPrefix(second.tocUrl) })
        #expect(lastOfFirst < firstOfSecond)
        #expect(services.downloads.tasks.map(\.cachedCount) == [3, 3])
    }

    @Test func 暂停后不再派发_继续后完成() async throws {
        let server = BookServer(transport: transport, titles: titles(8))
        slowContent(server, delay: 0.05)
        let book = server.book(origin: src.bookSourceUrl)
        let downloads = services.downloads
        downloads.concurrency = 1
        downloads.enqueue(book)
        try await waitUntil { (downloads.task(for: book.bookUrl)?.cachedCount ?? 0) >= 2 }
        downloads.pause(book.bookUrl)
        #expect(downloads.task(for: book.bookUrl)?.state == .paused)
        #expect(!downloads.isActive)
        try await waitUntil { downloads.runningRequests == 0 }
        let pausedCount = try #require(downloads.task(for: book.bookUrl)?.cachedCount)
        #expect(pausedCount < 8)
        try await Task.sleep(for: .milliseconds(200))
        #expect(downloads.task(for: book.bookUrl)?.cachedCount == pausedCount)

        downloads.resume(book.bookUrl)
        try await waitUntil { isFinished(book.bookUrl) }
        #expect(downloads.task(for: book.bookUrl)?.cachedCount == 8)
    }

    @Test func 失败章节自动重试后可手动重试() async throws {
        let server = BookServer(transport: transport, titles: titles(4))
        let badChapter = "\(server.host)/c/\(server.bookID)/\(BookServer.encode("第3章"))"
        let attempts = HitCounter()
        transport.on(badChapter) { request in
            attempts.hit("bad")
            return HTTPResponse(url: request.url, headers: ["Content-Type": "application/json"], body: Data(#"{"c":""}"#.utf8))
        }
        let book = server.book(origin: src.bookSourceUrl)
        let downloads = services.downloads
        downloads.enqueue(book)
        try await waitUntil { isFinished(book.bookUrl) }
        var task = try #require(downloads.task(for: book.bookUrl))
        #expect(task.cachedCount == 3 && task.failedCount == 1)
        #expect(attempts.count("bad") == CacheDownloadManager.maxRetries + 1)

        transport.on(badChapter) { request in
            HTTPResponse(url: request.url, headers: ["Content-Type": "application/json"], body: Data(#"{"c":"修好了"}"#.utf8))
        }
        downloads.retryFailed(book.bookUrl)
        #expect(downloads.task(for: book.bookUrl)?.state == .downloading)
        try await waitUntil { isFinished(book.bookUrl) }
        task = try #require(downloads.task(for: book.bookUrl))
        #expect(task.cachedCount == 4 && task.failedCount == 0)
    }

    @Test func 按范围缓存并合并后续请求() async throws {
        let server = BookServer(transport: transport, titles: titles(10))
        let book = server.book(origin: src.bookSourceUrl)
        let downloads = services.downloads
        downloads.enqueue(book, range: 0..<3)
        try await waitUntil { isFinished(book.bookUrl) }
        #expect(downloads.task(for: book.bookUrl)?.chapterCount == 3)

        downloads.enqueue(book, range: 2..<5)
        try await waitUntil { isFinished(book.bookUrl) }
        let task = try #require(downloads.task(for: book.bookUrl))
        #expect(task.chapterCount == 5 && task.cachedCount == 5)
        #expect(server.hits.count("content") == 5)

        downloads.enqueue(book, range: 8..<20)
        try await waitUntil { isFinished(book.bookUrl) }
        #expect(downloads.task(for: book.bookUrl)?.chapterCount == 7)
    }

    @Test func 目录失败_本地TXT_删除书籍() async throws {
        let downloads = services.downloads
        let orphan = Book(bookUrl: "https://gone.test/book/1", origin: "https://gone.test", name: "失联")
        downloads.enqueue(orphan)
        try await waitUntil {
            if case .failed = downloads.task(for: orphan.bookUrl)?.state { true } else { false }
        }

        let url = tempDirectory().appendingPathComponent("本地.txt")
        try Data("第一章 开端\n正文".utf8).write(to: url)
        let local = try await services.importLocalBook(at: url)
        #expect(!downloads.enqueue(local))
        #expect(downloads.task(for: local.bookUrl) == nil)

        let server = BookServer(transport: transport, titles: titles(30))
        slowContent(server, delay: 0.05)
        let book = server.book(origin: src.bookSourceUrl)
        services.shelf.add(book)
        downloads.enqueue(book)
        try await waitUntil { (downloads.task(for: book.bookUrl)?.cachedCount ?? 0) >= 1 }
        services.removeBooks([book.bookUrl])
        #expect(downloads.task(for: book.bookUrl) == nil)
        downloads.remove(orphan.bookUrl)
        #expect(downloads.tasks.isEmpty)
        try await waitUntil { downloads.runningRequests == 0 }
        #expect(services.chapterStore.cachedFileNames(bookUrl: book.bookUrl).isEmpty)
    }
}
