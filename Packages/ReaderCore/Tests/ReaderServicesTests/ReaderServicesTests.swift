import Foundation
import ReaderModels
@testable import ReaderServices
import RuleEngine
import Testing

/// 按路由返回固定响应的模拟网络
final class StubTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [(String, @Sendable (HTTPRequest) -> HTTPResponse)] = []

    func on(_ prefix: String, _ handler: @escaping @Sendable (HTTPRequest) -> HTTPResponse) {
        lock.withLock { routes.append((prefix, handler)) }
    }

    func on(_ prefix: String, json: String) {
        on(prefix) { HTTPResponse(url: $0.url, headers: ["Content-Type": "application/json"], body: Data(json.utf8)) }
    }

    func send(_ request: HTTPRequest) throws -> HTTPResponse {
        let routes = lock.withLock { self.routes }
        for (prefix, handler) in routes.reversed() where request.url.hasPrefix(prefix) {
            return handler(request)
        }
        return HTTPResponse(url: request.url, statusCode: 404, body: Data())
    }
}

func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ReaderServicesTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func source(_ url: String, _ name: String, extra: String = "") throws -> BookSource {
    try SourceImport.bookSources(from: Data(#"{"bookSourceUrl":"\#(url)","bookSourceName":"\#(name)"\#(extra)}"#.utf8))[0]
}

@Suite("导入识别")
struct ImportServiceTests {
    @Test func 识别书源替换规则与朗读源() throws {
        let sources = try ImportService.classify(Data(#"[{"bookSourceUrl":"https://a.com","bookSourceName":"A"}]"#.utf8))
        guard case .bookSources(let items) = sources else { Issue.record("应识别为书源"); return }
        #expect(items.count == 1)

        let rules = try ImportService.classify(Data(#"{"id":1,"name":"去广告","pattern":"广告","replacement":""}"#.utf8))
        guard case .replaceRules = rules else { Issue.record("应识别为替换规则"); return }

        let tts = try ImportService.classify(Data(#"[{"id":1,"name":"朗读","url":"https://tts.com/{{speakText}}"}]"#.utf8))
        guard case .httpTTS = tts else { Issue.record("应识别为朗读源"); return }

        #expect(throws: ImportError.unsupported("订阅源")) {
            try ImportService.classify(Data(#"[{"sourceUrl":"https://r.com","sourceName":"R"}]"#.utf8))
        }
        #expect(throws: ImportError.notJSON) { try ImportService.classify(Data("hello".utf8)) }
    }

    @Test func 解析一键导入链接() {
        let link = URL(string: "yuedu://booksource/importonline?src=https://a.com/s.json")!
        #expect(ImportService.sourceURL(fromLink: link)?.absoluteString == "https://a.com/s.json")
        #expect(ImportService.sourceURL(fromLink: URL(string: "legado://import/bookSource")!) == nil)
    }
}

@Suite("书源与书架仓库")
@MainActor
struct RepositoryTests {
    @Test func 书源合并导入与持久化() throws {
        let file = tempDirectory().appendingPathComponent("sources.json")
        let repo = SourceRepository(fileURL: file)
        var summary = repo.importSources([try source("https://a.com", "A"), try source("https://b.com", "B")])
        #expect(summary == ImportSummary(added: 2))

        var changed = try source("https://a.com", "A2")
        changed.bookSourceGroup = "精选"
        summary = repo.importSources([changed, try source("https://b.com", "B"), try source("https://c.com", "C")])
        #expect(summary == ImportSummary(added: 1, updated: 1, unchanged: 1))
        #expect(repo.sources.map(\.bookSourceName) == ["A2", "B", "C"])
        #expect(repo.groups == ["精选"])

        repo.setEnabled(false, for: ["https://b.com"])
        repo.move(fromOffsets: [2], toOffset: 0)
        repo.flush()

        let reloaded = SourceRepository(fileURL: file)
        #expect(reloaded.sources.map(\.bookSourceName) == ["C", "A2", "B"])
        #expect(reloaded.enabledSources.count == 2)
    }

    @Test func 书架排序分组与进度() {
        let file = tempDirectory().appendingPathComponent("shelf.json")
        let shelf = BookshelfRepository(fileURL: file)
        var a = Book(bookUrl: "https://a.com/1", origin: "https://a.com", name: "甲", author: "作者")
        a.durChapterTime = 100
        var b = Book(bookUrl: "https://a.com/2", origin: "https://a.com", name: "乙", author: "作者")
        b.durChapterTime = 200
        shelf.add(a)
        shelf.add(b)
        #expect(shelf.sortedBooks().map(\.name) == ["乙", "甲"])

        shelf.togglePin(a.bookUrl)
        #expect(shelf.sortedBooks().map(\.name) == ["甲", "乙"])

        let g1 = shelf.addGroup("在读")!
        let g2 = shelf.addGroup("完结")!
        #expect(g1.groupId == 1 && g2.groupId == 2)
        shelf.setGroup(g1.groupId | g2.groupId, for: [b.bookUrl])
        #expect(shelf.sortedBooks(inGroup: g2.groupId).map(\.name) == ["乙"])
        #expect(shelf.sortedBooks(inGroup: 0).map(\.name) == ["甲"])
        shelf.deleteGroup(g1.groupId)
        #expect(shelf.book(b.bookUrl)?.group == g2.groupId)

        shelf.saveProgress(bookUrl: a.bookUrl, chapterIndex: 3, chapterPos: 120, chapterTitle: "第四章")
        shelf.flush()
        let reloaded = BookshelfRepository(fileURL: file)
        #expect(reloaded.book(a.bookUrl)?.durChapterIndex == 3)
        #expect(reloaded.book(a.bookUrl)?.durChapterPos == 120)
        #expect(reloaded.pinned.contains(a.bookUrl))
        #expect(reloaded.groups.map(\.groupName) == ["完结"])
    }
}

@Suite("正文处理与缓存")
struct ContentTests {
    @Test func 去重复标题替换与分段() {
        var rule = ReplaceRule(id: 1, name: "去广告", pattern: "【广告[^】]*】", replacement: "")
        rule.isRegex = true
        var plain = ReplaceRule(id: 2, name: "改名", pattern: "张三", replacement: "李四")
        plain.isRegex = false
        var other = ReplaceRule(id: 3, name: "别的书", pattern: "李四", replacement: "王五")
        other.scope = "另一本书"
        var titleRule = ReplaceRule(id: 4, name: "标题", pattern: "第(\\d+)章", replacement: "Chapter $1")
        titleRule.scopeTitle = true
        titleRule.scopeContent = false

        let book = Book(bookUrl: "u", origin: "https://a.com", name: "测试书", author: "")
        let processor = ContentProcessor(rules: [rule, plain, other, titleRule])
        let content = "  第1章 开始\n\n　　张三走了进来。【广告：xxx】\n  \n第二段  "
        let paragraphs = processor.paragraphs(content: content, chapterTitle: "第1章 开始", book: book)
        #expect(paragraphs == ["李四走了进来。", "第二段"])
        #expect(processor.displayTitle("第12章 开始", book: book) == "Chapter 12 开始")
    }

    @Test func 简繁转换() {
        #expect(ChineseConversion.toSimplified.apply("體驗") == "体验")
        #expect(ChineseConversion.toTraditional.apply("体验") == "體驗")
    }

    @Test func 章节缓存读写() {
        let store = ChapterStore(root: tempDirectory())
        let chapters = [BookChapter(url: "https://a.com/c1", title: "第一章", bookUrl: "b", index: 0),
                        BookChapter(url: "https://a.com/c2", title: "第二章", bookUrl: "b", index: 1)]
        store.saveChapters(chapters, bookUrl: "b")
        #expect(store.loadChapters(bookUrl: "b")?.map(\.title) == ["第一章", "第二章"])
        store.saveContent("正文", bookUrl: "b", chapter: chapters[1])
        #expect(store.content(bookUrl: "b", chapter: chapters[1]) == "正文")
        #expect(store.hasContent(bookUrl: "b", chapter: chapters[1]))
        #expect(!store.hasContent(bookUrl: "b", chapter: chapters[0]))
        #expect(store.cachedFileNames(bookUrl: "b") == [ChapterStore.fileName(for: chapters[1])])
        #expect(store.totalSize() > 0)
        store.clear(bookUrl: "b")
        #expect(store.loadChapters(bookUrl: "b") == nil)
    }
}

@Suite("搜索与超时")
@MainActor
struct SearchTests {
    /// 不在主线程上计时：同进程的 WebKit 测试可能阻塞主线程
    @Test nonisolated func 超时立即返回() async {
        let start = Date()
        do {
            _ = try await withTimeout(.milliseconds(200)) {
                // 模拟不响应取消的阻塞调用
                await withCheckedContinuation { (c: CheckedContinuation<Int, Never>) in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) { c.resume(returning: 1) }
                }
            }
            Issue.record("应当超时")
        } catch {
            #expect(error is TimeoutError)
        }
        #expect(Date().timeIntervalSince(start) < 1.5)
    }

    @Test func 多源聚合与排序() async throws {
        let transport = StubTransport()
        transport.on("https://a.com/search", json: #"[{"n":"三体","a":"刘慈欣"},{"n":"三体前传","a":"某人"}]"#)
        transport.on("https://b.com/search", json: #"[{"n":"三体","a":"刘慈欣"},{"n":"球状闪电","a":"刘慈欣"}]"#)
        let env = SourceEnvironment(http: transport, store: MemoryKeyValueStore(), deviceID: "test")
        let rule = #","searchUrl":"/search?q={{key}}","ruleSearch":{"bookList":"$[*]","name":"$.n","author":"$.a","bookUrl":"$.n"}"#
        // 与 Legado 一致：HTTP 错误码的响应仍会解析，因此用抛错的脚本模拟失败
        let broken = #","searchUrl":"@js:throw '坏了'","ruleSearch":{"bookList":"$[*]","name":"$.n"}"#
        let sources = [try source("https://a.com", "A", extra: rule),
                       try source("https://b.com", "B", extra: rule),
                       try source("https://c.com", "C", extra: broken)]

        let model = SearchModel(environment: env)
        model.search("三体", sources: sources)
        while model.isSearching { try await Task.sleep(for: .milliseconds(20)) }

        #expect(model.completed == 3)
        #expect(model.results.map(\.name) == ["三体", "三体前传", "球状闪电"])
        #expect(model.results.first?.sourceCount == 2)
        #expect(model.failures.map(\.sourceName) == ["C"])
        #expect(model.canLoadMore)
    }
}
