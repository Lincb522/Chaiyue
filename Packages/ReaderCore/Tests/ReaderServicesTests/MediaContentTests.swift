import Foundation
import Testing
@testable import ReaderModels
@testable import ReaderServices

@Suite struct MediaContentTests {
    @Test func linkWholeContent() {
        #expect(MediaContent.link(in: " https://a.test/x.mp3?t=1 \n") == "https://a.test/x.mp3?t=1")
        let withOption = #"https://a.test/v.m3u8,{"headers":{"Referer":"https://a.test"}}"#
        #expect(MediaContent.link(in: withOption) == withOption)
    }

    @Test func linkInsideText() {
        #expect(MediaContent.link(in: "播放直链：\nhttps://a.test/v.mp4 结束") == "https://a.test/v.mp4")
        #expect(MediaContent.link(in: #"<audio src="https://a.test/a.m4a"></audio>"#) == "https://a.test/a.m4a")
        #expect(MediaContent.link(in: "您今日免登录访问次数已达上限") == nil)
    }

    @Test func mediaKind() {
        var book = Book(bookUrl: "https://a.test/1", origin: "https://a.test", name: "书")
        #expect(book.mediaKind() == .text)
        book.type = 1
        #expect(book.mediaKind() == .audio)
        book.type = 2
        #expect(book.mediaKind() == .comic)
        book.type = 3
        #expect(book.mediaKind() == .video)
        #expect(book.mediaKind(sourceType: BookSourceType.file.rawValue) == .text)
        book.type = 32
        #expect(book.mediaKind() == .audio)
        book.type = 64
        #expect(book.mediaKind() == .comic)
        book.type = 8
        #expect(book.mediaKind() == .text)
    }

    @Test func typeSurvivesCachedToc() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ChapterStore(root: root)
        store.saveChapters([BookChapter(url: "u1", title: "第1集", bookUrl: "b", index: 0)], bookUrl: "b")
        store.saveBookType(3, bookUrl: "b")
        #expect(store.bookType(bookUrl: "b") == 3)
    }
}
