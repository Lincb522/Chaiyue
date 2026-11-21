import Foundation
import ReaderModels
@testable import ReaderServices
import RuleEngine
import Testing

@Suite("换源")
@MainActor
struct ChangeSourceTests {
    let transport = StubTransport()

    func makeServices() -> LibraryServices {
        LibraryServices(dataDirectory: tempDirectory(), cacheDirectory: tempDirectory(), http: transport)
    }

    @Test func 按书名与作者筛选候选() async throws {
        transport.on("https://a.test/search", json: #"[{"n":"测试书","a":"作者","u":"https://a.test/book/1"}]"#)
        transport.on("https://b.test/search",
                     json: #"[{"n":"测试书","a":"作者","u":"https://b.test/book/1"},{"n":"测试书外传","a":"作者","u":"https://b.test/book/2"}]"#)
        transport.on("https://c.test/search", json: #"[{"n":"测试书","a":"别人","u":"https://c.test/book/1"}]"#)
        transport.on("https://d.test/search",
                     json: #"[{"n":" 测试书 ","a":"作者：作者","u":"https://d.test/book/1"},{"n":"测试书","a":"作者","u":"https://d.test/book/1"}]"#)
        let broken = #","searchUrl":"@js:throw '坏了'","ruleSearch":{"bookList":"$[*]","name":"$.n"}"#
        let services = makeServices()
        services.apply(.bookSources([
            try jsonSource("https://b.test", name: "B"),
            try jsonSource("https://d.test", name: "D"),
            try jsonSource("https://a.test", name: "A"),
            try jsonSource("https://c.test", name: "C"),
            try source("https://e.test", "E", extra: broken),
        ]))
        let book = Book(bookUrl: "https://a.test/book/1", origin: "https://a.test", name: "测试书", author: "作者")

        let model = services.changeSourceModel(for: book)
        model.start()
        #expect(model.isSearching && model.total == 5)
        try await waitUntil { !model.isSearching }
        #expect(model.completed == 5 && model.hasSearched)
        #expect(model.candidates.map(\.book.origin) == ["https://a.test", "https://b.test", "https://d.test"])
        #expect(model.candidates.map(\.isCurrent) == [true, false, false])
        #expect(model.candidates.allSatisfy { $0.book.respondTime >= 0 })
        #expect(model.failures.map(\.sourceName) == ["E"])

        model.checksAuthor = false
        #expect(model.candidates.map(\.book.origin) == ["https://a.test", "https://b.test", "https://d.test", "https://c.test"])

        // 再次打开同一本书复用已有结果，不重新搜索
        let reopened = services.changeSourceModel(for: book)
        #expect(reopened === model)
        reopened.start()
        #expect(!reopened.isSearching)
    }

    @Test func 作者与书名的规范化() {
        #expect(ChangeSourceModel.nameKey(" 三体 Ⅰ ") == ChangeSourceModel.nameKey("三体Ⅰ"))
        #expect(ChangeSourceModel.nameKey("ＡＢＣ") == "abc")
        #expect(ChangeSourceModel.authorMatches("刘慈欣", "作者：刘慈欣"))
        #expect(ChangeSourceModel.authorMatches("刘慈欣", "刘慈欣 著"))
        #expect(!ChangeSourceModel.authorMatches("作者", "别人"))
        #expect(ChangeSourceModel.authorMatches("", "任何人"))
        #expect(ChangeSourceModel.authorMatches("天蚕土豆", "土豆"))
        #expect(!ChangeSourceModel.authorMatches("刘慈欣", "王晋康"))
    }

    @Test func 复用搜索页已完成的结果() async throws {
        transport.on("https://b.test/search", json: #"[{"n":"测试书","a":"作者","u":"https://b.test/book/1"}]"#)
        let services = makeServices()
        services.apply(.bookSources([try jsonSource("https://b.test", name: "B")]))
        services.startSearch("测试书")
        try await waitUntil { !services.search.isSearching }

        let book = Book(bookUrl: "https://a.test/book/1", origin: "https://a.test", name: "测试书", author: "作者")
        let model = services.changeSourceModel(for: book)
        #expect(model.candidates.map(\.book.bookUrl) == ["https://b.test/book/1"])
        #expect(model.hasSearched)
        model.start()
        #expect(!model.isSearching)
        model.refresh()
        #expect(model.isSearching && model.candidates.isEmpty)
        try await waitUntil { !model.isSearching }
        #expect(model.candidates.count == 1)
    }

    @Test func 换源后找回进度并替换书架记录() async throws {
        let serverA = BookServer(transport: transport, host: "https://a.test", bookID: 1,
                                 titles: ["第一章 起", "第二章 承", "第三章 转", "第四章 合"])
        _ = BookServer(transport: transport, host: "https://b.test", bookID: 2,
                       titles: ["序章", "第一章 起", "第二章 承", "第三章 转", "第四章 合", "第五章 新"])
        transport.on("https://b.test/search", json: #"[{"n":"测试书","a":"作者","u":"https://b.test/book/2"}]"#)
        transport.on("https://b.test/book/2", json: #"{"n":"测试书","a":"作者","toc":"https://b.test/toc/2","last":"第五章 新"}"#)
        let services = makeServices()
        let srcA = try jsonSource("https://a.test", name: "A")
        let srcB = try jsonSource("https://b.test", name: "B")
        services.apply(.bookSources([srcA, srcB]))

        var old = serverA.book(origin: srcA.bookSourceUrl)
        let (_, oldChapters) = try await services.contentService(for: old).chapters(for: old)
        old.totalChapterNum = oldChapters.count
        old.durChapterIndex = 2
        old.durChapterTitle = "第三章 转"
        old.durChapterPos = 15
        old.group = 2
        old.customCoverUrl = "my-cover"
        services.shelf.add(old)
        services.shelf.togglePin(old.bookUrl)
        _ = try await services.contentService(for: old).content(for: old, chapter: oldChapters[2], nextChapter: oldChapters[3])
        #expect(services.chapterStore.hasContent(bookUrl: old.bookUrl, chapter: oldChapters[2]))

        let model = services.changeSourceModel(for: old)
        model.start()
        try await waitUntil { !model.isSearching }
        let candidate = try #require(model.candidates.first { $0.book.origin == srcB.bookSourceUrl })
        #expect(!candidate.isCurrent)

        let (book, chapters) = try await services.changeSource(of: old, to: candidate.book)
        #expect(book.origin == srcB.bookSourceUrl && book.bookUrl == "https://b.test/book/2")
        #expect(chapters.count == 6)
        #expect(book.durChapterIndex == 3 && book.durChapterTitle == "第三章 转" && book.durChapterPos == 15)
        #expect(book.totalChapterNum == 6 && book.latestChapterTitle == "第五章 新")
        #expect(book.group == 2 && book.customCoverUrl == "my-cover")
        #expect(services.shelf.book(old.bookUrl) == nil)
        #expect(services.shelf.book(book.bookUrl)?.durChapterIndex == 3)
        #expect(services.shelf.pinned.contains(book.bookUrl))
        #expect(services.chapterStore.loadChapters(bookUrl: book.bookUrl)?.count == 6)
        #expect(services.chapterStore.loadChapters(bookUrl: old.bookUrl) == nil)
        #expect(model.book.bookUrl == book.bookUrl)
        #expect(model.candidates.first { $0.book.origin == srcB.bookSourceUrl }?.isCurrent == true)

        let session = services.readerSession(for: book)
        await session.open()
        #expect(session.position.chapterIndex == 3)
        #expect(session.chapters.count == 6)
    }

    @Test func 本地书与缺失书源不能换源() async throws {
        let services = makeServices()
        let target = SearchBook(bookUrl: "https://z.test/book/1", origin: "https://z.test")
        let local = Book(bookUrl: "localbook://x", origin: Book.localOrigin, name: "本地")
        await #expect(throws: BookServiceError.localBookCannotChangeSource) {
            try await services.changeSource(of: local, to: target)
        }
        let online = Book(bookUrl: "https://a.test/book/1", origin: "https://a.test", name: "网络")
        await #expect(throws: BookServiceError.sourceMissing("https://z.test")) {
            try await services.changeSource(of: online, to: target)
        }
    }

    @Test func 迁移阅读设置() {
        var old = Book(bookUrl: "https://a.test/1", origin: "https://a.test", name: "书", author: "人")
        old.durChapterIndex = 1
        old.durChapterPos = 9
        old.totalChapterNum = 2
        old.canUpdate = false
        old.customTag = "标签"
        old.customIntro = "自定义简介"
        old.readConfig = BookReadConfig()
        old.readConfig?.splitLongChapter = false
        let new = Book(bookUrl: "https://b.test/1", origin: "https://b.test", name: "书", author: "人")
        let chapters = ["第一章 甲", "第二章 乙"].enumerated().map { BookChapter(url: "u\($0)", title: $1, bookUrl: new.bookUrl, index: $0) }
        let oldChapters = chapters.map { chapter in
            var chapter = chapter
            chapter.bookUrl = old.bookUrl
            return chapter
        }
        let migrated = LibraryServices.migrate(old, to: new, chapters: chapters, oldChapters: oldChapters)
        #expect(migrated.bookUrl == new.bookUrl && migrated.origin == new.origin)
        #expect(migrated.durChapterIndex == 1 && migrated.durChapterTitle == "第二章 乙" && migrated.durChapterPos == 9)
        #expect(!migrated.canUpdate && migrated.customTag == "标签" && migrated.customIntro == "自定义简介")
        #expect(migrated.readConfig?.splitLongChapter == false)
    }
}
