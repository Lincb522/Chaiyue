import Foundation
import ReaderModels
@testable import ReaderServices
import RuleEngine
import Testing

@Suite("章节对齐")
struct ChapterMatcherTests {
    func chapters(_ titles: [String]) -> [BookChapter] {
        titles.enumerated().map { BookChapter(url: "u\($0.offset)", title: $0.element, index: $0.offset) }
    }

    @Test func 中文数字() {
        #expect(ChapterMatcher.stringToInt("123") == 123)
        #expect(ChapterMatcher.stringToInt("１２３") == 123)
        #expect(ChapterMatcher.chineseNumber("一千零二十五") == 1025)
        #expect(ChapterMatcher.chineseNumber("十二") == 12)
        #expect(ChapterMatcher.chineseNumber("一零二五") == 1025)
        #expect(ChapterMatcher.chineseNumber("两百") == 200)
        #expect(ChapterMatcher.chineseNumber("三万五千") == 35000)
        #expect(ChapterMatcher.chineseNumber("一千二") == 1200)
        #expect(ChapterMatcher.chineseNumber("壹佰贰拾叁") == 123)
        #expect(ChapterMatcher.chineseNumber("abc") == -1)
    }

    @Test func 章节序号与净化() {
        #expect(ChapterMatcher.chapterNumber("第一百二十三章 雾港") == 123)
        #expect(ChapterMatcher.chapterNumber("第 12 章") == 12)
        #expect(ChapterMatcher.chapterNumber("12、雾港") == 12)
        #expect(ChapterMatcher.chapterNumber("12.雾港") == 12)
        #expect(ChapterMatcher.chapterNumber("雾港") == -1)
        #expect(ChapterMatcher.pureName("第一百二十三章 雾港（求月票）") == "雾港")
        #expect(ChapterMatcher.pureName("123、雾港") == "雾港")
        #expect(ChapterMatcher.pureName("第五章") == "第五章")
    }

    @Test func 相似度() {
        #expect(ChapterMatcher.jaroWinkler("雾港", "雾港") == 1)
        #expect(ChapterMatcher.jaroWinkler("abc", "") == 0)
        #expect(abs(ChapterMatcher.jaroWinkler("MARTHA", "MARHTA") - 0.9611) < 0.001)
    }

    @Test func 目录变动后找回章节() {
        let old = (1...10).map { "第\($0)章 " + ["甲", "乙", "丙", "丁", "戊", "己", "庚", "辛", "壬", "癸"][$0 - 1] }
        // 前面插入两章：按章节名找回
        let inserted = chapters(["公告", "序章"] + old)
        #expect(ChapterMatcher.index(oldIndex: 5, oldTitle: old[5], newChapters: inserted, oldCount: 10) == 7)
        // 章节改名：按序号找回
        var renamed = old
        renamed[5] = "第6章 改了名字"
        #expect(ChapterMatcher.index(oldIndex: 5, oldTitle: old[5], newChapters: chapters(["序章"] + renamed), oldCount: 10) == 6)
        // 完全对不上：保持原索引
        let unrelated = chapters((0..<10).map { "番外" + String(UnicodeScalar(0x4E00 + $0 * 7)!) })
        #expect(ChapterMatcher.index(oldIndex: 3, oldTitle: "另一个故事", newChapters: unrelated) == 3)
        #expect(ChapterMatcher.index(oldIndex: 0, oldTitle: old[0], newChapters: inserted) == 0)
        #expect(ChapterMatcher.index(oldIndex: 4, oldTitle: old[4], newChapters: []) == 4)
        #expect(ChapterMatcher.index(oldIndex: 30, oldTitle: "第31章", newChapters: chapters(old)) == 9)
    }
}

@Suite("章节文本坐标")
struct ChapterTextTests {
    @Test func 段落位置与稳定偏移互转() {
        // 稳定文本 "甲乙丙\n丁戊\n己庚辛壬"
        let text = ChapterText(index: 0, title: "第一章", paragraphs: ["甲乙丙", "丁戊", "己庚辛壬"])
        #expect(text.length == 11)
        #expect(text.location(of: 0) == (0, 0))
        #expect(text.location(of: 3) == (0, 3))
        #expect(text.location(of: 4) == (1, 0))
        #expect(text.location(of: 7) == (2, 0))
        #expect(text.location(of: 99) == (2, 4))
        #expect(text.offset(paragraph: 2, offset: 1) == 8)
        #expect(text.offset(paragraph: 1) == 4)
        #expect(text.offset(paragraph: 9, offset: 99) == 11)
        #expect(text.excerpt(from: 4, maxLength: 4) == "丁戊\n己")
    }

    @Test func 摘录不拆开代理对() {
        let text = ChapterText(index: 0, title: "", paragraphs: ["a😀b"])
        #expect(text.length == 4)
        #expect(text.excerpt(from: 2, maxLength: 1) == "😀")
        #expect(ChapterText(index: 0, title: "", paragraphs: []).length == 0)
    }
}

@Suite("阅读会话")
@MainActor
struct ReaderSessionTests {
    let transport = StubTransport()
    let server: BookServer
    let env: SourceEnvironment
    let shelf = BookshelfRepository(fileURL: tempDirectory().appendingPathComponent("shelf.json"))
    let store = ChapterStore(root: tempDirectory())
    let src: BookSource

    init() throws {
        server = BookServer(transport: transport, titles: ["第一章 起", "第二章 承", "第三章 转", "第四章 合"])
        env = SourceEnvironment(http: transport, store: MemoryKeyValueStore(), deviceID: "test")
        src = try jsonSource()
    }

    func makeSession(_ book: Book, rules: [ReplaceRule] = [], source: BookSource? = nil) -> ReaderSession {
        let service = BookContentService(source: source ?? src, environment: env, store: store)
        let session = ReaderSession(book: book, shelf: shelf, service: service, processor: ContentProcessor(rules: rules),
                                    preloadCount: 1)
        return session
    }

    func paragraphs(_ state: ChapterLoadState?) -> [String] {
        if case .loaded(let text) = state { return text.paragraphs }
        return []
    }

    @Test func 打开时加载目录与当前章() async throws {
        var book = server.book(origin: src.bookSourceUrl)
        book.durChapterIndex = 1
        book.durChapterPos = 3
        let session = makeSession(book)
        await session.open()

        #expect(session.tocState == .ready)
        #expect(session.chapters.count == 4)
        #expect(session.position == ReadingPosition(chapterIndex: 1, offset: 3))
        guard case .loaded(let text) = await session.load(1) else {
            Issue.record("当前章应加载成功")
            return
        }
        #expect(text.title == "第二章 承")
        #expect(text.paragraphs == ["第二章 承的第一段，张三。", "第二段。"])
        #expect(paragraphs(await session.load(0)).count == 2)
        #expect(paragraphs(await session.load(2)).count == 2)
        #expect(session.text(of: 3) == nil)
    }

    @Test func 读过的书自动加入书架并保存进度() async throws {
        let book = server.book(origin: src.bookSourceUrl)
        let session = makeSession(book)
        await session.open()
        #expect(shelf.book(book.bookUrl) == nil)

        session.updatePosition(ReadingPosition(chapterIndex: 2, offset: 5))
        #expect(shelf.book(book.bookUrl)?.durChapterIndex == 2)
        #expect(shelf.book(book.bookUrl)?.durChapterPos == 5)
        #expect(session.book.durChapterIndex == 2)

        session.addToShelf()
        #expect(shelf.book(book.bookUrl)?.durChapterIndex == 2)
        #expect(shelf.book(book.bookUrl)?.durChapterPos == 5)
        #expect(shelf.book(book.bookUrl)?.totalChapterNum == 4)

        session.updatePosition(ReadingPosition(chapterIndex: 3))
        #expect(shelf.book(book.bookUrl)?.durChapterIndex == 3)
        #expect(shelf.book(book.bookUrl)?.durChapterTitle == "第四章 合")

        session.updatePosition(ReadingPosition(chapterIndex: 99))
        #expect(session.position.chapterIndex == 3)
        #expect(session.moveToNextChapter() == false)
        await session.load(2)
        let previous = try #require(session.text(of: 2))
        #expect(session.moveToPreviousChapter(toEnd: true))
        #expect(session.position == ReadingPosition(chapterIndex: 2, offset: previous.length))
    }

    @Test func 关闭自动加入书架时只保存阅读记录() async throws {
        let book = server.book(origin: src.bookSourceUrl)
        let records = ReadingRecordStore(fileURL: tempDirectory().appendingPathComponent("readingRecords.json"))
        let session = makeSession(book)
        session.autoAddToShelf = { false }
        session.readingRecords = records
        await session.open()

        session.updatePosition(ReadingPosition(chapterIndex: 2, offset: 5))
        #expect(shelf.book(book.bookUrl) == nil)
        #expect(records.book(book.bookUrl)?.durChapterIndex == 2)
        #expect(records.book(book.bookUrl)?.durChapterPos == 5)
        #expect(records.restored(book).durChapterIndex == 2)

        session.close()
        #expect(shelf.books.isEmpty)
    }

    @Test func 更换处理规则不重新下载() async throws {
        let session = makeSession(server.book(origin: src.bookSourceUrl))
        await session.open()
        for index in 0...1 { await session.load(index) }
        let hits = server.hits.count("content")
        #expect(hits == 2)

        var rule = ReplaceRule(id: 1, name: "改名", pattern: "张三", replacement: "李四")
        rule.isRegex = false
        session.updateProcessor(ContentProcessor(rules: [rule]))
        #expect(paragraphs(await session.load(0)).first == "第一章 起的第一段，李四。")

        session.updateReadConfig { $0.useReplaceRule = false }
        #expect(paragraphs(await session.load(0)).first == "第一章 起的第一段，张三。")
        #expect(server.hits.count("content") == hits)

        await session.load(0, refresh: true)
        #expect(server.hits.count("content") == hits + 1)
    }

    @Test func 刷新目录按章节名找回位置() async throws {
        let book = server.book(origin: src.bookSourceUrl)
        let session = makeSession(book)
        await session.open()
        session.updatePosition(ReadingPosition(chapterIndex: 2, offset: 10))

        server.serveToc(["公告", "序章", "第一章 起", "第二章 承", "第三章 转", "第四章 合"])
        await session.refreshToc()
        #expect(session.chapters.count == 6)
        #expect(session.position == ReadingPosition(chapterIndex: 4, offset: 10))
        #expect(session.currentChapter?.title == "第三章 转")

        await session.load(4)
        let bookmark = try #require(session.addBookmark(at: ReadingPosition(chapterIndex: 4, offset: 0), note: "记一下"))
        #expect(bookmark.chapterName == "第三章 转")
        #expect(bookmark.bookText.hasPrefix("第三章 转的第一段"))
        #expect(bookmark.content == "记一下")
        #expect(shelf.bookmarks(for: session.book).count == 1)
    }

    @Test func 书源缺失时目录加载失败() async {
        let book = Book(bookUrl: "https://gone.test/book/1", origin: "https://gone.test", name: "失联", author: "")
        let service = BookContentService(source: nil, environment: env, store: store)
        let session = ReaderSession(book: book, shelf: shelf, service: service, processor: ContentProcessor())
        await session.open()
        guard case .failed(let message) = session.tocState else {
            Issue.record("应当失败")
            return
        }
        #expect(message.contains("找不到书源"))
    }
}
