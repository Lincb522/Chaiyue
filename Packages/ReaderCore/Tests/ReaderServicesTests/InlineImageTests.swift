import Foundation
import ReaderModels
@testable import ReaderServices
@testable import RuleEngine
import Testing

/// 阻塞图片请求直到放行，用来确认文字先于图片发布
private final class Gate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func wait(seconds: Double = 20) { _ = semaphore.wait(timeout: .now() + seconds) }
    func open() { semaphore.signal(); semaphore.signal() }
}

private final class HeaderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: [String: String]] = [:]
    func record(_ request: HTTPRequest) { lock.withLock { items[request.url] = request.headers } }
    func headers(_ url: String) -> [String: String]? { lock.withLock { items[url] } }
}

@Suite("图片段落解析")
struct InlineImageParsingTests {
    @Test func 取地址() {
        #expect(InlineImage.source(of: #"<img src="https://a.test/1.jpg">"#) == "https://a.test/1.jpg")
        #expect(InlineImage.source(of: "<IMG SRC='/2.png'>") == "/2.png")
        let withOptions = #"<img src="https://a.test/3.jpg,{"headers":{"Referer":"https://a.test/"}}">"#
        #expect(InlineImage.source(of: withOptions) == #"https://a.test/3.jpg,{"headers":{"Referer":"https://a.test/"}}"#)
        #expect(InlineImage.source(of: #"<img src="a.jpg" alt="图">"#) == "a.jpg")
        #expect(InlineImage.source(of: "<img>") == nil)
        #expect(InlineImage.source(of: "文字<img src=\"a\">") == nil)
    }

    @Test func 点按动作图片() {
        #expect(InlineImage.isAction(#"data:image/svg+xml;base64,PHN2Zz4=,{"js":"showCmt('u','段评')","style":"FULL"}"#))
        #expect(InlineImage.isAction(#"https://a.test/c.svg,{"style":"FULL","click":"a()","js":"a()"}"#))
        #expect(InlineImage.isAction("https://a.test/c.svg,{'type':'qtbzs',\"js\":\"a()\",'style':'FULL'}"))
        #expect(!InlineImage.isAction(#"https://a.test/3.jpg,{"headers":{"Referer":"https://a.test/js/"}}"#))
        #expect(!InlineImage.isAction("data:image/png;base64,anM6"))

        // 点按动作图片（神评论卡片、本章说卡片）保留为图片段落，点按时再执行脚本
        let bubble = #"<img src="data:image/svg+xml;base64,PHN2Zz4=,{"js":"showCmt('u','段评' )","style":"FULL"}">"#
        let card = #"<img src="https://a.test/b.svg,{"style":"FULL","click":"a()","js":"a()"}">"#
        let content = "第一段" + bubble + "\n第二段\n" + card + "\n<img src=\"https://a.test/1.jpg\">"
        let paragraphs = ContentProcessor().paragraphs(content: content, chapterTitle: "", book: Book(bookUrl: "b", origin: "o"))
        #expect(paragraphs == ["第一段", bubble, "第二段", card, "<img src=\"https://a.test/1.jpg\">"])
    }

    @Test func 图片选项拆分() {
        let god = #"data:image/svg+xml;base64,PHN2Zz4=,{"js":"showCmt('https://s.test/c?a=1&b=2','番茄','段评')","style":"FULL"}"#
        let info = InlineImageSource(god)
        #expect(info.url == "data:image/svg+xml;base64,PHN2Zz4=")
        #expect(info.style == .full)
        #expect(info.action == "showCmt('https://s.test/c?a=1&b=2','番茄','段评')")
        #expect(info.requestURL == "data:image/svg+xml;base64,PHN2Zz4=")

        // 本章说卡片同时带 click 与 js，click 优先；安卓写法的单引号选项也能解析
        let card = InlineImageSource(#"https://a.test/c.svg,{"style":"FULL","click":"showFanqieComment(\"u\",\"本章说\")","js":"x()"}"#)
        #expect(card.action == #"showFanqieComment("u","本章说")"#)
        let android = InlineImageSource("https://a.test/c.svg,{'type':'qtbzs',\"js\":\"a('x')\",'style':'text'}")
        #expect(android.style == .text && android.action == "a('x')")
        #expect(android.requestURL == #"https://a.test/c.svg,{"type":"qtbzs"}"#)

        // 只有请求选项时原样保留，带样式时只去掉样式
        let headers = #"https://a.test/3.jpg,{"headers":{"Referer":"https://a.test/"}}"#
        #expect(InlineImageSource(headers).requestURL == headers && InlineImageSource(headers).style == nil)
        let styled = InlineImageSource(#"https://a.test/3.jpg,{"headers":{"Referer":"https://a.test/"},"style":"full"}"#)
        #expect(styled.style == .full)
        #expect(styled.requestURL == #"https://a.test/3.jpg,{"headers":{"Referer":"https://a.test/"}}"#)
        #expect(InlineImageSource("https://a.test/4.png").requestURL == "https://a.test/4.png")
    }

    @Test func data地址解码() {
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="5"></svg>"#
        let base64 = "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString() + #",{"style":"FULL","js":"a()"}"#
        #expect(InlineImage.dataURLContent(base64) == Data(svg.utf8))
        let encoded = "data:image/svg+xml;charset=utf-8," + svg.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        #expect(InlineImage.dataURLContent(encoded) == Data(svg.utf8))
        #expect(InlineImage.dataURLContent("https://a.test/1.png") == nil)
    }
    @Test func 夹在文字中的图片单独成段() {
        let content = "前文<img src=\"https://a.test/1.jpg\">后文\n<img src=\"x\"><img src=\"y\">"
        let paragraphs = ContentProcessor().paragraphs(content: content, chapterTitle: "", book: Book(bookUrl: "b", origin: "o"))
        #expect(paragraphs == ["前文", "<img src=\"https://a.test/1.jpg\">", "后文", "<img src=\"x\">", "<img src=\"y\">"])
        let text = ChapterText(index: 0, title: "", paragraphs: paragraphs + ["<img src=\"x\">"])
        #expect(text.imageSources == ["https://a.test/1.jpg", "x", "y"])
    }
}

@Suite("段评与图片段落")
struct ParagraphCommentTests {
    let book = Book(bookUrl: "b", origin: "o")

    @Test func 段评标记不进入稳定文本() throws {
        let content = """
        　　第一段文字。<comment count="12" onPress="java.showReadingBrowser('https://s.test/p?a=1&b=2','番茄段评')">
        　　第二段没有评论。
        　　第三段。<comment count="120" onPress="java.showReadingBrowser('https://s.test/q','番茄段评')"></comment>
        """
        let processed = ContentProcessor().process(content: content, chapterTitle: "", book: book)
        #expect(processed.paragraphs == ["第一段文字。", "第二段没有评论。", "第三段。"])
        let first = try #require(processed.extras[0]?.comment)
        #expect(first.count == "12" && first.label == "12")
        #expect(first.action == "java.showReadingBrowser('https://s.test/p?a=1&b=2','番茄段评')")
        #expect(processed.extras[1] == nil)
        #expect(processed.extras[2]?.comment?.label == "99+")

        // 偏移、摘录、朗读文本都只有正文
        let text = ChapterText(index: 0, title: "", paragraphs: processed.paragraphs, extras: processed.extras)
        #expect(text.content == "第一段文字。\n第二段没有评论。\n第三段。")
        #expect(text.length == (text.content as NSString).length)
        #expect(text.location(of: 7) == (1, 0))
        #expect(text.plainContent == text.content)
        #expect(!text.excerpt(from: 0).contains("comment"))
    }

    @Test func 原始段评标记用评论页地址() throws {
        let line = #"段落<comment ident="https://s.test/c?x=1" count="3" />"#
        let (stripped, comment) = ParagraphComment.extract(from: line)
        #expect(stripped == "段落")
        #expect(comment?.action == "java.showReadingBrowser('https://s.test/c?x=1','段评')")
        #expect(ParagraphComment.extract(from: #"段落<comment count="0" onPress="a()">"#).comment == nil)
        #expect(ParagraphComment.extract(from: "没有标记").text == "没有标记")
    }

    @Test func rsNative包裹的正文经格式化后成段() throws {
        let god = #"data:image/svg+xml;base64,PHN2Zz4=,{"js":"showCmt('https://s.test/g?i=1&amp;j=2','番茄','段评')","style":"FULL"}"#
        let html = """
        <div rs-native>第一段<comment count="5" onPress="java.showReadingBrowser('https://s.test/p?a=1&amp;b=2','番茄段评')"></div>\
        <div rs-native><img src="\(god)"></div><div rs-native>第二段</div>\
        <div rs-native><img src="https://img.test/1.jpg,{&quot;headers&quot;:{&quot;Referer&quot;:&quot;https://img.test/&quot;}}"></div>
        """
        var formatted = HTMLFormatter.formatKeepImg(html, baseURL: "https://s.test/chapter/1")
        formatted = formatted.contains("&") ? HTMLEntities.unescape(formatted) : formatted
        let processed = ContentProcessor().process(content: formatted, chapterTitle: "", book: book)
        #expect(processed.paragraphs.count == 4)
        #expect(processed.paragraphs[0] == "第一段")
        #expect(processed.extras[0]?.comment?.action == "java.showReadingBrowser('https://s.test/p?a=1&b=2','番茄段评')")
        let card = try #require(InlineImage.source(of: processed.paragraphs[1]))
        #expect(InlineImageSource(card).style == .full)
        #expect(InlineImageSource(card).action == "showCmt('https://s.test/g?i=1&j=2','番茄','段评')")
        #expect(InlineImage.dataURLContent(card) == Data("<svg>".utf8))
        #expect(processed.paragraphs[2] == "第二段")
        let picture = try #require(InlineImage.source(of: processed.paragraphs[3]))
        #expect(InlineImageSource(picture).requestURL == #"https://img.test/1.jpg,{"headers":{"Referer":"https://img.test/"}}"#)
    }

    @Test func TEXT样式小图留在段内() throws {
        let emoji = #"<img src="https://e.test/1.png,{"style":"text"}">"#
        let content = "前文" + emoji + "后文\n" + emoji + "\n大图<img src=\"https://e.test/big.png\">"
        let processed = ContentProcessor().process(content: content, chapterTitle: "", book: book)
        #expect(processed.paragraphs == ["前文\u{FFFC}后文", emoji, "大图", "<img src=\"https://e.test/big.png\">"])
        #expect(processed.extras[0]?.inlineImages == [2: #"https://e.test/1.png,{"style":"text"}"#])
        let text = ChapterText(index: 0, title: "", paragraphs: processed.paragraphs, extras: processed.extras)
        #expect(text.imageSources == [#"https://e.test/1.png,{"style":"text"}"#, "https://e.test/big.png"])
        // 朗读文本与稳定文本等长，图片换成空格
        #expect((text.plainContent as NSString).length == text.length)
        #expect(!text.plainContent.contains("<img") && !text.plainContent.contains("\u{FFFC}"))
    }
}

@Suite("大灰狼书源 jsLib", .enabled(if: FileManager.default.fileExists(atPath: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../_reference/sources/dahuilang/jsLib.js").standardized.path), "需要本地书源脚本"))
struct DahuilangScriptTests {
    /// 仓库里的书源公共脚本（离线，不发请求）
    static func jsLib() throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../_reference/sources/dahuilang/jsLib.js").standardized
        return try String(contentsOf: url, encoding: .utf8)
    }

    func makeSource() throws -> BookSource {
        let lib = try Self.jsLib()
        let data = try JSONSerialization.data(withJSONObject: [
            "bookSourceUrl": "https://dhl.test", "bookSourceName": "大灰狼", "jsLib": lib,
            "variable": "", "ruleContent": ["content": "$.c"],
        ])
        return try SourceImport.bookSources(from: data)[0]
    }

    @Test func iOS环境下段评与神评论的输出能被识别() async throws {
        let env = SourceEnvironment(http: StubTransport(), store: MemoryKeyValueStore(), deviceID: "test")
        let web = WebBook(source: try makeSource(), environment: env)
        #expect(try await web.evalJS("checkEnv()") == "苹果")

        let html = #"<p>第一段<comment ident="https://dhl.test/fanqie_comment?mode=paragraph&book_id=1&para=0" count="12" /></p>"#
            + #"<p>第二段</p><p><img ident="https://dhl.test/god?x=1" src="https://dhl.test/god.svg"/></p>"#
            + #"<note ident="https://dhl.test/note?i=2" text="写得真好[赞]"></note>"#
        let script = "paraForiOS(\(String(data: try JSONSerialization.data(withJSONObject: [html], options: .fragmentsAllowed), encoding: .utf8)!.dropFirst().dropLast()), '番茄')"
        let output = try await web.evalJS(script)
        #expect(output.contains("<div rs-native>第一段<comment count=\"12\""))

        var formatted = HTMLFormatter.formatKeepImg(output, baseURL: "https://dhl.test/content")
        formatted = formatted.contains("&") ? HTMLEntities.unescape(formatted) : formatted
        let processed = ContentProcessor().process(content: formatted, chapterTitle: "", book: Book(bookUrl: "b", origin: "o"))
        let texts = processed.paragraphs.filter { !InlineImage.isImage($0) }
        #expect(texts == ["第一段", "第二段"])
        let comment = try #require(processed.extras[processed.paragraphs.firstIndex(of: "第一段")!]?.comment)
        #expect(comment.label == "12")
        #expect(comment.action == "java.showReadingBrowser('https://dhl.test/fanqie_comment?mode=paragraph&book_id=1&para=0','番茄段评')")

        let images = processed.paragraphs.compactMap(InlineImage.source(of:)).map(InlineImageSource.init)
        #expect(images.count == 2)
        #expect(images.allSatisfy { $0.style == .full && $0.action?.hasPrefix("showCmt(") == true })
        #expect(images.contains { $0.url == "https://dhl.test/god.svg" })
        let note = try #require(images.first { $0.url.hasPrefix("data:image/svg+xml;base64,") })
        let svg = try #require(InlineImage.dataURLContent(note.raw).flatMap { String(data: $0, encoding: .utf8) })
        #expect(svg.hasPrefix("<svg") && svg.contains("神评论"))
    }

    @Test @MainActor func 点按脚本在书源环境里打开浮层() async throws {
        let ui = BrowserRecorder()
        let env = SourceEnvironment(http: StubTransport(), store: MemoryKeyValueStore(), deviceID: "test")
        env.setUIDelegate(ui)
        let web = WebBook(source: try makeSource(), environment: env)
        var book = Book(bookUrl: "https://dhl.test/book/1", origin: "https://dhl.test", name: "书")
        book.tocUrl = "https://dhl.test/toc/1"
        let chapter = BookChapter(url: "https://dhl.test/c/1", title: "第一章", bookUrl: book.bookUrl)
        try await web.runContentAction("java.showReadingBrowser('https://dhl.test/p?a=1&b=2','番茄段评')", book: book, chapter: chapter)
        try await web.runContentAction(#"showFanqieComment("https://dhl.test/chapter?x=1","本章说")"#, book: book, chapter: chapter)
        let sheets = ui.sheets
        #expect(sheets.map(\.url) == ["https://dhl.test/p?a=1&b=2", "https://dhl.test/chapter?x=1"])
        #expect(sheets.map(\.title) == ["番茄段评", "本章说"])
    }
}

/// 记录浮层浏览器请求
private final class BrowserRecorder: SourceUIDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [BrowserSheet] = []
    var sheets: [BrowserSheet] { lock.withLock { recorded } }

    func renderWebView(_ request: WebViewRequest) throws -> String { "" }
    func startBrowser(url: String, title: String, html: String?, sourceKey: String) {
        lock.withLock { recorded.append(BrowserSheet(url: url, title: title, html: html, js: nil, optionsJSON: nil, sourceKey: sourceKey)) }
    }
    func startBrowserAwait(url: String, title: String, html: String?, sourceKey: String) throws -> BrowserResult {
        BrowserResult(url: url, body: "")
    }
    func showBrowser(_ sheet: BrowserSheet) { lock.withLock { recorded.append(sheet) } }
    func verificationCode(imageURL: String, sourceKey: String) throws -> String { "" }
    func toast(_ message: String, long: Bool) {}
}


@Suite("正文插图")
@MainActor
struct ChapterImageTests {
    let transport = StubTransport()
    let env: SourceEnvironment
    let store = ChapterStore(root: tempDirectory())
    let imageDirectory = tempDirectory()
    let shelf = BookshelfRepository(fileURL: tempDirectory().appendingPathComponent("shelf.json"))

    init() {
        env = SourceEnvironment(http: transport, store: MemoryKeyValueStore(), deviceID: "test")
    }

    /// 一章正文，图片地址有相对地址、带请求头选项的地址
    func serve(_ content: String, source: BookSource? = nil) throws -> (Book, BookSource) {
        let src = try source ?? jsonSource()
        let toc = try JSONSerialization.data(withJSONObject: [["t": "第一章", "u": "https://j.test/c/1/1"]])
        transport.on("https://j.test/toc/1") { HTTPResponse(url: $0.url, headers: ["Content-Type": "application/json"], body: toc) }
        let body = try JSONSerialization.data(withJSONObject: ["c": content])
        transport.on("https://j.test/c/1/") { HTTPResponse(url: $0.url, headers: ["Content-Type": "application/json"], body: body) }
        var book = Book(bookUrl: "https://j.test/book/1", origin: src.bookSourceUrl, name: "书", author: "作者")
        book.tocUrl = "https://j.test/toc/1"
        return (book, src)
    }

    func makeSession(_ book: Book, source: BookSource) -> ReaderSession {
        let images = ImageCache(directory: imageDirectory, environment: env)
        let service = BookContentService(source: source, environment: env, store: store, images: images)
        return ReaderSession(book: book, shelf: shelf, service: service, processor: ContentProcessor(), preloadCount: 1)
    }

    @Test func 先发布文字_图片取完后发布新文本() async throws {
        let gate = Gate()
        let headers = HeaderLog()
        transport.on("https://j.test/img/a.png") { request in
            gate.wait()
            return HTTPResponse(url: request.url, body: Data("A".utf8))
        }
        transport.on("https://j.test/img/b.png") { request in
            headers.record(request)
            return HTTPResponse(url: request.url, body: Data("B".utf8))
        }
        let content = #"文字<img src="/img/a.png">后文"# + "\n" + #"<img src="https://j.test/img/b.png,{"headers":{"Referer":"https://j.test/r"}}">"#
        let (book, src) = try serve(content)
        let session = makeSession(book, source: src)
        await session.open()

        guard case .loaded(let first) = await session.load(0) else {
            Issue.record("正文应加载成功")
            return
        }
        let a = "https://j.test/img/a.png"
        let b = #"https://j.test/img/b.png,{"headers":{"Referer":"https://j.test/r"}}"#
        #expect(first.paragraphs == ["文字", "<img src=\"\(a)\">", "后文", "<img src=\"\(b)\">"])
        #expect(!first.imagesLoaded)
        #expect(session.imageData(for: a) == nil)

        gate.open()
        try await waitUntil { session.text(of: 0)?.imagesLoaded == true }
        let second = try #require(session.text(of: 0))
        #expect(second != first && second.paragraphs == first.paragraphs)
        #expect(session.imageData(for: a) == Data("A".utf8))
        #expect(session.imageData(for: b) == Data("B".utf8))
        #expect(headers.headers("https://j.test/img/b.png")?["Referer"] == "https://j.test/r")

        // 再次打开时插图已在磁盘缓存中，文字发布时就已就绪
        let reopened = makeSession(book, source: src)
        await reopened.open()
        guard case .loaded(let cached) = await reopened.load(0) else {
            Issue.record("正文应加载成功")
            return
        }
        #expect(cached.imagesLoaded)
        #expect(reopened.imageData(for: a) == Data("A".utf8))
    }

    @Test func 失败或超时的图片不阻塞() async throws {
        let gate = Gate()
        transport.on("https://j.test/img/slow.png") { request in
            gate.wait()
            return HTTPResponse(url: request.url, body: Data("S".utf8))
        }
        transport.on("https://j.test/img/ok.png") { HTTPResponse(url: $0.url, body: Data("O".utf8)) }
        let content = ["slow", "gone", "ok"].map { #"<img src="https://j.test/img/\#($0).png">"# }.joined(separator: "\n")
        let (book, src) = try serve(content)
        let session = makeSession(book, source: src)
        session.imageTimeout = .milliseconds(500)
        session.imageConcurrency = 3
        await session.open()
        await session.load(0)

        // 慢图被阻塞 20 秒，等待在此之前结束说明总超时生效
        try await waitUntil { session.text(of: 0)?.imagesLoaded == true }
        #expect(session.text(of: 0)?.imagesLoaded == true)
        #expect(session.imageData(for: "https://j.test/img/slow.png") == nil)
        #expect(session.imageData(for: "https://j.test/img/gone.png") == nil)
        #expect(session.imageData(for: "https://j.test/img/ok.png") == Data("O".utf8))
        gate.open()
    }

    @Test func 正文插图用imageDecode解密() async throws {
        transport.on("https://j.test/img/e.png") { HTTPResponse(url: $0.url, body: Data([1, 2, 3])) }
        let rules = #","ruleToc":{"chapterList":"$[*]","chapterName":"$.t","chapterUrl":"$.u"},"#
            + #""ruleContent":{"content":"$.c","imageDecode":"result.map(function(b){return b ^ 15})"},"coverDecodeJs":"null""#
        let (book, src) = try serve(#"<img src="https://j.test/img/e.png">"#, source: try source("https://j.test", "J", extra: rules))
        let session = makeSession(book, source: src)
        await session.open()
        await session.load(0)
        try await waitUntil { session.text(of: 0)?.imagesLoaded == true }
        #expect(session.imageData(for: "https://j.test/img/e.png").map(Array.init) == [14, 13, 12])
    }

    @Test func 没有插图的章节直接就绪() async throws {
        let (book, src) = try serve("只有文字。")
        let session = makeSession(book, source: src)
        await session.open()
        guard case .loaded(let text) = await session.load(0) else {
            Issue.record("正文应加载成功")
            return
        }
        #expect(text.imagesLoaded && text.imageSources.isEmpty)
    }
}
