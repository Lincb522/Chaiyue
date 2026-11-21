import Foundation
import ReaderModels
@testable import ReaderServices
import RuleEngine
import Testing
import ZIPFoundation

/// 16 个 UTF-16 单元，不含任何目录规则会匹配的关键字
private let filler = "　　风吹过山岗，河水静静流淌。\n"

private func body(_ length: Int = 1200) -> String {
    String(repeating: filler, count: length / filler.utf16.count + 1)
}

/// 每章正文超过 1000 字，保证自动识别时每个标题都被计数
private func novel(_ titles: [String], preface: String? = nil) -> String {
    (preface.map { $0 + "\n" } ?? "") + titles.map { $0 + "\n" + body() }.joined()
}

private func encoding(_ name: String) -> String.Encoding {
    Charsets.encoding(named: name)!
}

private func slice(_ text: String, _ range: Range<Int>) -> String {
    (text as NSString).substring(with: NSRange(location: range.lowerBound, length: range.count))
}

private func writeFile(_ name: String, _ data: Data) throws -> URL {
    let url = tempDirectory().appendingPathComponent(name)
    try data.write(to: url)
    return url
}

// MARK: - EPUB 样本

private let coverPNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data("cover".utf8)
private let mapPNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data("map".utf8)
private let coverJPEG = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data("jpeg".utf8)

private func container(_ opfPath: String) -> String {
    #"<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="\#(opfPath)" media-type="application/oebps-package+xml"/></rootfiles></container>"#
}

private func xhtml(title: String?, _ body: String) -> String {
    #"<?xml version="1.0" encoding="utf-8"?><!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml"><head>"#
        + (title.map { "<title>\($0)</title>" } ?? "") + "<style>p{margin:0}</style></head><body>\(body)</body></html>"
}

private func writeEpub(_ name: String, _ files: [(String, Data)]) throws -> URL {
    let url = tempDirectory().appendingPathComponent(name)
    let archive = try Archive(url: url, accessMode: .create)
    let entries = [("mimetype", Data("application/epub+zip".utf8))] + files
    for (index, (path, data)) in entries.enumerated() {
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count),
                             compressionMethod: index == 0 ? .none : .deflate) { position, size in
            data.subdata(in: Int(position)..<Int(position) + size)
        }
    }
    return url
}

/// EPUB2：NCX 目录（卷与同页 fragment）、封面页、卷首页、带空格的插图路径
private func ncxEpub() throws -> URL {
    let opf = """
    <?xml version="1.0" encoding="UTF-8"?>
    <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
    <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
    <dc:title>测试之书</dc:title><dc:creator opf:role="aut">佚名</dc:creator>
    <dc:description>&lt;p&gt;一本&lt;b&gt;测试&lt;/b&gt;用书&lt;/p&gt;</dc:description>
    <meta name="cover" content="cover-img"/>
    </metadata>
    <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="cover-img" href="Images/cover.png" media-type="image/png"/>
    <item id="map" href="Images/map%20one.png" media-type="image/png"/>
    <item id="coverpage" href="Text/cover.xhtml" media-type="application/xhtml+xml"/>
    <item id="intro" href="Text/intro.xhtml" media-type="application/xhtml+xml"/>
    <item id="c1" href="Text/part1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="Text/part2.xhtml" media-type="application/xhtml+xml"/>
    </manifest>
    <spine toc="ncx"><itemref idref="coverpage"/><itemref idref="intro"/><itemref idref="c1"/><itemref idref="c2"/></spine>
    </package>
    """
    let ncx = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><docTitle><text>测试之书</text></docTitle>
    <navMap>
    <navPoint id="v1"><navLabel><text>第一卷 起</text></navLabel><content src="Text/part1.xhtml"/>
    <navPoint id="n1"><navLabel><text>第一章 相遇</text></navLabel><content src="Text/part1.xhtml#s1"/></navPoint>
    <navPoint id="n2"><navLabel><text>第二章 别离</text></navLabel><content src="Text/part1.xhtml#s2"/></navPoint>
    </navPoint>
    <navPoint id="n3"><navLabel><text>第三章 重逢</text></navLabel><content src="Text/part2.xhtml"/></navPoint>
    </navMap>
    </ncx>
    """
    let part1 = xhtml(title: "第一卷", """
    <h1>第一卷 起</h1><p>卷首语：故事开始了。</p>
    <div id="s1"><h2>第一章 相遇</h2><p>春天，他们在桥上相遇。</p><p><img src="../Images/map%20one.png" alt="地图"/></p></div>
    <div id="s2"><h2>第二章 别离</h2><p>秋天，他们在渡口别离。</p><script>document.write("脚本")</script><p style="display:none">隐藏文字</p></div>
    """)
    return try writeEpub("测试之书.epub", [
        ("META-INF/container.xml", Data(container("OEBPS/content.opf").utf8)),
        ("OEBPS/content.opf", Data(opf.utf8)),
        ("OEBPS/toc.ncx", Data(ncx.utf8)),
        ("OEBPS/Images/cover.png", coverPNG),
        ("OEBPS/Images/map one.png", mapPNG),
        ("OEBPS/Text/cover.xhtml", Data(xhtml(title: nil, #"<div><img src="../Images/cover.png"/></div>"#).utf8)),
        ("OEBPS/Text/intro.xhtml", Data(xhtml(title: "内容简介", "<h1>内容简介</h1><p>这是一本测试用书。</p>").utf8)),
        ("OEBPS/Text/part1.xhtml", Data(part1.utf8)),
        ("OEBPS/Text/part2.xhtml", Data(xhtml(title: "第三章", "<h2>第三章 重逢</h2><p>多年以后，他们再次重逢。</p>").utf8)),
    ])
}

/// EPUB3：nav 目录（无链接的卷）、cover-image 属性
private func navEpub() throws -> URL {
    let opf = """
    <?xml version="1.0" encoding="UTF-8"?>
    <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
    <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>导航之书</dc:title><dc:creator>甲, </dc:creator></metadata>
    <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="img" href="cover.jpg" media-type="image/jpeg" properties="cover-image"/>
    <item id="a" href="a.xhtml" media-type="application/xhtml+xml"/>
    <item id="b" href="b.xhtml" media-type="application/xhtml+xml"/>
    </manifest>
    <spine><itemref idref="a"/><itemref idref="b"/></spine>
    </package>
    """
    let nav = """
    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>
    <nav epub:type="toc"><ol>
    <li><a href="a.xhtml">甲章</a></li>
    <li><span>乙卷</span><ol><li><a href="b.xhtml#top">乙一</a></li></ol></li>
    </ol></nav></body></html>
    """
    return try writeEpub("导航.epub", [
        ("META-INF/container.xml", Data(container("EPUB/package.opf").utf8)),
        ("EPUB/package.opf", Data(opf.utf8)),
        ("EPUB/nav.xhtml", Data(nav.utf8)),
        ("EPUB/cover.jpg", coverJPEG),
        ("EPUB/a.xhtml", Data(xhtml(title: "甲", "<p>甲章正文。</p>").utf8)),
        ("EPUB/b.xhtml", Data(xhtml(title: "乙", #"<p>乙之前言</p><h2 id="top">乙一</h2><p>乙一正文。</p>"#).utf8)),
    ])
}

/// 没有目录与元数据：按 spine 分章
private func spineEpub() throws -> URL {
    let opf = """
    <?xml version="1.0" encoding="UTF-8"?>
    <package xmlns="http://www.idpf.org/2007/opf" version="2.0">
    <metadata/>
    <manifest>
    <item id="p1" href="p1.html" media-type="application/xhtml+xml"/>
    <item id="p2" href="p2.html" media-type="application/xhtml+xml"/>
    <item id="p3" href="p3.html" media-type="application/xhtml+xml"/>
    </manifest>
    <spine><itemref idref="p1"/><itemref idref="p2"/><itemref idref="p3"/></spine>
    </package>
    """
    return try writeEpub("无目录.epub", [
        ("META-INF/container.xml", Data(container("content.opf").utf8)),
        ("content.opf", Data(opf.utf8)),
        ("p1.html", Data(xhtml(title: nil, "<p>第一页的正文。</p>").utf8)),
        ("p2.html", Data(xhtml(title: "第二页", "<p>第二页的正文。</p>").utf8)),
        ("p3.html", Data(xhtml(title: nil, "<h1>尾声</h1><p>结束。</p>").utf8)),
    ])
}

// MARK: - 编码

@Suite("TXT 编码识别")
struct TextEncodingTests {
    @Test func 识别BOM并统一换行() throws {
        let text = "第一章 开端\r\n　　风吹过山岗。\r"
        let expected = "第一章 开端\n　　风吹过山岗。\n"
        let utf8 = Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
        #expect(TextEncodingDetector.detect(utf8) == "UTF-8")
        #expect(TextEncodingDetector.decode(utf8, charset: "UTF-8") == expected)
        let le = Data([0xFF, 0xFE]) + (try #require(text.data(using: .utf16LittleEndian)))
        #expect(TextEncodingDetector.detect(le) == "UTF-16LE")
        #expect(TextEncodingDetector.decode(le, charset: "UTF-16LE") == expected)
        let be = Data([0xFE, 0xFF]) + (try #require(text.data(using: .utf16BigEndian)))
        #expect(TextEncodingDetector.detect(be) == "UTF-16BE")
        #expect(TextEncodingDetector.decode(be, charset: "UTF-16BE") == expected)
    }

    @Test func 识别无BOM的UTF16() throws {
        let text = String(repeating: "Chapter 1 Hello world. 第一章\n", count: 10)
        #expect(TextEncodingDetector.detect(try #require(text.data(using: .utf16LittleEndian))) == "UTF-16LE")
        #expect(TextEncodingDetector.detect(try #require(text.data(using: .utf16BigEndian))) == "UTF-16BE")
    }

    @Test func 区分UTF8与GB18030与Big5() throws {
        let simplified = "第一章 开端\n　　风吹过山岗，河水静静流淌。他们在桥上相遇，谁也没有说话。\n"
        #expect(TextEncodingDetector.detect(Data(simplified.utf8)) == "UTF-8")
        let gbk = try #require(simplified.data(using: encoding("GB18030")))
        #expect(TextEncodingDetector.detect(gbk) == "GB18030")
        #expect(TextEncodingDetector.decode(gbk, charset: "GB18030") == simplified)

        let traditional = "第一章 風雲際會\n　　這是一個關於江湖與俠客的故事，從前有一座山，山裡住著一位老人。\n第二章 劍氣縱橫\n　　他們在橋上相遇，誰也沒有說話。\n"
        let big5 = try #require(traditional.data(using: encoding("Big5")))
        #expect(TextEncodingDetector.detect(big5) == "Big5")
        #expect(TextEncodingDetector.decode(big5, charset: "Big5") == traditional)
        // GBK 中繁体字的第二字节也常小于 0xA1，但不能按 Big5 严格解码
        let gbTraditional = try #require(traditional.data(using: encoding("GB18030")))
        #expect(TextEncodingDetector.detect(gbTraditional) == "GB18030")
    }

    @Test func 采样截断在多字节字符中间时仍识别为UTF8() {
        var text = "a"
        while text.utf8.count < TextEncodingDetector.sampleSize + 1000 { text += filler }
        #expect(TextEncodingDetector.detect(Data(text.utf8)) == "UTF-8")
    }

    @Test func 非法字节有损解码() throws {
        var data = try #require("第一章 开端\n".data(using: encoding("GB18030")))
        data.append(contentsOf: [0xFF, 0xFF])
        data.append(try #require("正文".data(using: encoding("GB18030"))))
        let text = TextEncodingDetector.decode(data, charset: "GB18030")
        #expect(text.hasPrefix("第一章 开端\n"))
        #expect(text.hasSuffix("正文"))
    }
}

// MARK: - 分章

@Suite("TXT 分章")
struct TxtSplitTests {
    @Test func 内置规则与导入格式() throws {
        #expect(TxtTocRule.defaults.count == 25)
        #expect(Set(TxtTocRule.defaults.filter(\.enable).map(\.id)) == [-1, -2, -8, -9, -11, -12, -14, -16, -17, -21, -22, -24])
        for rule in TxtTocRule.defaults {
            #expect((try? NSRegularExpression(pattern: rule.rule, options: .anchorsMatchLines)) != nil, "\(rule.name)")
        }
        let json = #"[{"id":-2,"enable":false,"name":"目录","rule":"^第.章","serialNumber":1},{"id":"7","name":"自定义","rule":"^卷.+$"}]"#
        let decoded = try JSONDecoder().decode([TxtTocRule].self, from: Data(json.utf8))
        #expect(decoded[0].id == -2 && !decoded[0].enable && decoded[0].serialNumber == 1)
        #expect(decoded[1].id == 7 && decoded[1].enable && decoded[1].example == nil)
        let roundTrip = try JSONDecoder().decode([TxtTocRule].self, from: JSONEncoder().encode(decoded))
        #expect(roundTrip == decoded)
    }

    @Test func 自动识别目录并生成前言() throws {
        let text = novel(["第一章 开端", "第二章 发展", "第三章 结局"], preface: "本书简介：一个测试故事。")
        let result = try TxtChapterSplitter.split(text, mode: .auto)
        #expect(result.chapters.map(\.title) == ["前言", "第一章 开端", "第二章 发展", "第三章 结局"])
        #expect(result.chapters.allSatisfy { !$0.isVolume })
        #expect(result.intro == "本书简介：一个测试故事。")
        #expect(!result.pattern.isEmpty)
        #expect(slice(text, result.chapters[0].range) == "本书简介：一个测试故事。\n")
        #expect(slice(text, result.chapters[2].range) == "\n" + body())
        #expect(result.chapters.last?.range.upperBound == text.utf16.count)
    }

    @Test func 识别常见目录格式() {
        let cases: [([String], Int64)] = [
            (["Chapter 1 Begin", "Chapter 2 Middle", "Chapter 3 End"], -12),
            (["1、开始", "2、继续", "3、结束"], -8),
            (["☆、初遇", "☆、重逢", "☆、离别"], -16),
        ]
        for (titles, id) in cases {
            #expect(TxtChapterSplitter.detectRule(in: novel(titles))?.id == id, "\(titles)")
        }
        #expect(TxtChapterSplitter.detectRule(in: body(5000)) == nil)
    }

    @Test func 没有正文的标题标记为卷() throws {
        let text = "测试小说\n第一卷 风起\n第一章 开端\n" + body() + "第二章 发展\n" + body() + "第二卷 云涌\n第三章 结局\n" + body()
        let result = try TxtChapterSplitter.split(text, mode: .auto)
        #expect(result.chapters.map(\.title) == ["前言", "第一卷 风起", "第一章 开端", "第二章 发展", "第二卷 云涌", "第三章 结局"])
        #expect(result.chapters.map(\.isVolume) == [false, true, false, false, true, false])
        #expect(result.intro == "测试小说")
    }

    @Test func 超长章节按长度拆分() throws {
        let long = body(60_000)
        let text = "第一章 漫长\n" + long + "第二章 短暂\n" + body()
        let result = try TxtChapterSplitter.split(text, mode: .auto)
        #expect(result.chapters.first?.title == "第一章 漫长")
        #expect(result.chapters.first?.isVolume == true)
        #expect(result.chapters.first?.range.isEmpty == true)
        #expect(result.chapters.last?.title == "第二章 短暂")
        let parts = Array(result.chapters.dropFirst().dropLast())
        #expect(parts.count == 12)
        #expect(parts.enumerated().allSatisfy { $1.title == "第一章 漫长(\($0 + 1))" && !$1.isVolume })
        #expect(parts.map(\.range.count).reduce(0, +) == long.utf16.count + 1)
        #expect(parts.dropLast().allSatisfy { $0.range.count >= TxtChapterSplitter.lengthPerChapter })

        let whole = try TxtChapterSplitter.split(text, mode: .auto, splitLongChapter: false)
        #expect(whole.chapters.map(\.title) == ["第一章 漫长", "第二章 短暂"])
    }

    @Test func 无目录时按长度分章() throws {
        let text = String(repeating: String(repeating: "字", count: 99) + "\n", count: 120)
        let result = try TxtChapterSplitter.split(text, mode: .auto)
        #expect(result.pattern.isEmpty)
        #expect(result.chapters.map(\.title) == ["第1节", "第2节", "第3节"])
        #expect(result.chapters.map(\.range) == [0..<5099, 5099..<10099, 10099..<12000])

        // 末尾不超过 100 字的余量并入上一章
        let short = String(repeating: "字", count: 5000) + "\n" + String(repeating: "字", count: 50)
        #expect(try TxtChapterSplitter.split(short, mode: .byLength).chapters.map(\.range) == [0..<5051])
    }

    @Test func 指定目录规则() throws {
        let text = novel(["Chapter 1 Begin", "Chapter 2 End"])
        let result = try TxtChapterSplitter.split(text, mode: .pattern(#"^Chapter \d+.*$"#))
        #expect(result.chapters.map(\.title) == ["Chapter 1 Begin", "Chapter 2 End"])
        #expect(result.pattern == #"^Chapter \d+.*$"#)
        #expect(throws: LocalBookError.invalidPattern("[")) { try TxtChapterSplitter.split(text, mode: .pattern("[")) }
        #expect(throws: LocalBookError.noChapterMatched) { try TxtChapterSplitter.split(text, mode: .pattern("^第.章$")) }
    }

    @Test func 文件名解析与字数() {
        func parsed(_ fileName: String) -> String {
            let result = LocalBookStore.parseFileName(fileName)
            return result.name + "|" + result.author
        }
        #expect(parsed("《三体》作者：刘慈欣.txt") == "三体|刘慈欣")
        #expect(parsed("斗破苍穹 作者：天蚕土豆.txt") == "斗破苍穹|天蚕土豆")
        #expect(parsed("Harry Potter by J.K. Rowling.txt") == "Harry Potter|J.K. Rowling")
        #expect(parsed("凡人修仙传 忘语 著.txt") == "凡人修仙传|忘语")
        #expect(parsed("诛仙.txt") == "诛仙|")

        #expect(LocalBookStore.wordCountText(0) == nil)
        #expect(LocalBookStore.wordCountText(9999) == "9999字")
        #expect(LocalBookStore.wordCountText(12345) == "1.2万字")
        #expect(LocalBookStore.wordCountText(20000) == "2万字")
    }
}

// MARK: - 本地书文件

@Suite("本地书文件")
struct LocalBookStoreTests {
    let store = LocalBookStore(root: tempDirectory())

    @Test func 导入GB18030编码的TXT() throws {
        let text = novel(["第一章 开端", "第二章 发展", "第三章 结局"], preface: "简介：测试。")
        let raw = try #require(text.data(using: encoding("GB18030")))
        let result = try store.importBook(from: try writeFile("斗破苍穹 作者：天蚕土豆.txt", raw))
        let book = result.book
        #expect(book.isLocal && LocalBookStore.handles(book.bookUrl))
        #expect(book.name == "斗破苍穹" && book.author == "天蚕土豆")
        #expect(book.originName == "斗破苍穹 作者：天蚕土豆.txt")
        #expect(book.charset == "GB18030")
        #expect(!book.canUpdate)
        #expect(book.totalChapterNum == 4)
        #expect(book.latestChapterTitle == "第三章 结局")
        #expect(book.intro == "简介：测试。")
        #expect(book.wordCount == LocalBookStore.wordCountText(text.utf16.count))
        #expect(result.chapters.map(\.title) == ["前言", "第一章 开端", "第二章 发展", "第三章 结局"])
        #expect(Set(result.chapters.map(\.url)).count == 4)
        #expect(try store.content(for: book, chapter: result.chapters[2]) == "\n" + body())
        #expect(try Data(contentsOf: try #require(store.fileURL(for: book))) == raw)

        #expect(try store.chapters(for: book) == result.chapters)
        let id = try #require(LocalBookStore.id(of: book))
        try FileManager.default.removeItem(at: store.directory(id).appendingPathComponent("chapters.json"))
        #expect(try store.chapters(for: book).map(\.title) == result.chapters.map(\.title))

        #expect(store.totalSize() > Int64(raw.count))
        store.remove(book)
        #expect(!store.exists(book))
        #expect(throws: LocalBookError.fileMissing) { try store.content(for: book, chapter: result.chapters[2]) }
    }

    @Test func 重新分章() throws {
        let imported = try store.importBook(from: try writeFile("重分.txt", Data(novel(["第一章 开端", "第二章 发展"]).utf8)),
                                            tocMode: .byLength)
        #expect(imported.book.tocUrl.isEmpty)
        #expect(imported.chapters.map(\.title) == ["第1节"])

        let resplit = try store.resplit(imported.book, tocMode: .auto)
        #expect(resplit.chapters.map(\.title) == ["第一章 开端", "第二章 发展"])
        #expect(!resplit.book.tocUrl.isEmpty)
        #expect(try store.chapters(for: resplit.book).count == 2)
        #expect(try store.content(for: resplit.book, chapter: resplit.chapters[1]) == "\n" + body())

        #expect(throws: LocalBookError.invalidPattern("(")) { try store.resplit(resplit.book, tocMode: .pattern("(")) }
        #expect(try store.chapters(for: resplit.book).count == 2)
    }

    @Test func 拒绝不支持或空的文件() throws {
        #expect(throws: LocalBookError.unsupportedFormat("xyz")) { try store.importBook(from: try writeFile("a.xyz", Data("x".utf8))) }
        #expect(throws: LocalMediaError.invalidPDF) { try store.importBook(from: try writeFile("坏.pdf", Data("x".utf8))) }
        #expect(throws: LocalBookError.emptyFile) { try store.importBook(from: try writeFile("空.txt", Data())) }
        #expect(throws: LocalBookError.emptyFile) { try store.importBook(from: try writeFile("空白.txt", Data("  \n\n ".utf8))) }
        #expect(throws: LocalBookError.invalidEpub("无法打开 EPUB 文件")) {
            try store.importBook(from: try writeFile("坏.epub", Data("not a zip".utf8)))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.path).isEmpty)
    }
}

@Suite("EPUB 解析")
struct EpubTests {
    let store = LocalBookStore(root: tempDirectory())

    @Test func 按NCX目录分章并截取同页片段() throws {
        let result = try store.importBook(from: try ncxEpub())
        let book = result.book
        let id = try #require(LocalBookStore.id(of: book))
        #expect(book.name == "测试之书" && book.author == "佚名")
        #expect(book.intro == "一本测试用书")
        #expect(book.coverUrl == "localbook://\(id)/cover")
        #expect(try store.resourceData("localbook://\(id)/cover") == coverPNG)

        let chapters = result.chapters
        #expect(chapters.map(\.title) == ["--卷首--", "内容简介", "第一卷 起", "第一章 相遇", "第二章 别离", "第三章 重逢"])
        #expect(chapters.map(\.isVolume) == [false, false, true, false, false, false])
        #expect(chapters.map(\.index) == Array(0..<6))
        #expect(chapters[3].startFragmentId == "s1" && chapters[3].endFragmentId == "s2")
        #expect(book.totalChapterNum == 6 && book.latestChapterTitle == "第三章 重逢")

        func content(_ index: Int) throws -> String { try store.content(for: book, chapter: chapters[index]) }
        #expect(try content(0) == "<img src=\"localbook://\(id)/cover\">")
        #expect(try content(1).contains("这是一本测试用书。"))
        let volume = try content(2)
        #expect(volume.contains("卷首语：故事开始了。") && !volume.contains("春天"))
        let first = try content(3)
        #expect(first.contains("春天，他们在桥上相遇。"))
        #expect(!first.contains("卷首语") && !first.contains("秋天"))
        let image = "localbook://\(id)/OEBPS/Images/map%20one.png"
        #expect(first.contains("<img src=\"\(image)\">"))
        #expect(try store.resourceData(image) == mapPNG)
        let second = try content(4)
        #expect(second.contains("秋天，他们在渡口别离。"))
        #expect(!second.contains("脚本") && !second.contains("隐藏文字") && !second.contains("多年以后"))
        #expect(try content(5).contains("多年以后，他们再次重逢。"))
    }

    @Test func 按EPUB3导航分章() throws {
        let result = try store.importBook(from: try navEpub())
        let chapters = result.chapters
        #expect(result.book.name == "导航之书" && result.book.author == "甲")
        #expect(chapters.map(\.title) == ["甲章", "乙卷", "乙一"])
        #expect(chapters[1].isVolume && chapters[1].url.isEmpty)
        let id = try #require(LocalBookStore.id(of: result.book))
        #expect(try store.resourceData("localbook://\(id)/cover") == coverJPEG)

        let first = try store.content(for: result.book, chapter: chapters[0])
        #expect(first.contains("甲章正文。") && first.contains("乙之前言") && !first.contains("乙一正文"))
        #expect(try store.content(for: result.book, chapter: chapters[1]).isEmpty)
        let last = try store.content(for: result.book, chapter: chapters[2])
        #expect(last.contains("乙一正文。") && !last.contains("乙之前言"))
    }

    @Test func 没有目录时按阅读顺序分章() throws {
        let result = try store.importBook(from: try spineEpub())
        #expect(result.book.name == "无目录")
        #expect(result.book.coverUrl == nil)
        #expect(result.chapters.map(\.title) == ["封面", "第二页", "尾声"])
        #expect(try store.content(for: result.book, chapter: result.chapters[1]).contains("第二页的正文。"))
        #expect(throws: LocalBookError.notTextBook) { try store.resplit(result.book, tocMode: .byLength) }
    }
}

// MARK: - 目录规则仓库

@Suite("目录规则仓库")
@MainActor
struct TxtTocRuleRepositoryTests {
    @Test func 内置规则只改启用状态_自定义规则可增删() {
        let url = tempDirectory().appendingPathComponent("txtTocRules.json")
        let repository = TxtTocRuleRepository(fileURL: url)
        #expect(repository.rules.count == 25)
        #expect(repository.enabledRules.count == 12)

        repository.setEnabled(false, for: [-1])
        var builtIn = repository.rules[0]
        builtIn.rule = "改不了"
        builtIn.enable = true
        repository.save(builtIn)
        #expect(repository.rules[0].rule == TxtTocRule.defaults[0].rule)
        #expect(repository.rules[0].enable)
        repository.setEnabled(false, for: [-1])

        repository.save(TxtTocRule(id: 0, name: "自定义", rule: "^卷.+$"))
        let custom = try! #require(repository.rules.last)
        #expect(custom.id > 0 && custom.name == "自定义" && custom.serialNumber == 25)
        #expect(!repository.isBuiltIn(custom))
        repository.flush()

        let reloaded = TxtTocRuleRepository(fileURL: url)
        #expect(reloaded.rules.count == 26)
        #expect(reloaded.rules.first { $0.id == -1 }?.enable == false)
        #expect(reloaded.enabledRules.count == 12)

        reloaded.delete([custom.id, -2])
        #expect(reloaded.rules.count == 25)
        reloaded.resetBuiltIns()
        #expect(reloaded.rules.first { $0.id == -1 }?.enable == true)
    }

    @Test func 导入Legado规则() {
        let repository = TxtTocRuleRepository(fileURL: tempDirectory().appendingPathComponent("txtTocRules.json"))
        var builtIn = TxtTocRule.defaults[1]
        builtIn.enable = false
        let summary = repository.importRules([
            builtIn,
            TxtTocRule.defaults[2],
            TxtTocRule(id: 99, name: "分卷", rule: "^卷.+$", serialNumber: 30),
            TxtTocRule(id: 100, name: "空规则", rule: ""),
        ])
        #expect(summary == ImportSummary(added: 1, updated: 1, unchanged: 1))
        #expect(repository.rules.first { $0.id == -2 }?.enable == false)
        #expect(repository.rules.last?.id == 99)
        #expect(repository.importRules([TxtTocRule(id: 99, name: "分卷", rule: "^卷.+$", serialNumber: 30)]) == ImportSummary(unchanged: 1))
    }
}

// MARK: - 接入书架与阅读

@Suite("本地书入库")
@MainActor
struct LocalLibraryTests {
    let services = LibraryServices(dataDirectory: tempDirectory(), cacheDirectory: tempDirectory(), http: StubTransport())

    func paragraphs(_ state: ChapterLoadState?) -> [String] {
        if case .loaded(let text) = state { return text.paragraphs }
        return []
    }

    @Test func 导入后阅读与删除() async throws {
        let url = try writeFile("《测试》作者：某人.txt", Data(novel(["第一章 开端", "第二章 发展", "第三章 结局"]).utf8))
        let book = try await services.importLocalBook(at: url)
        #expect(services.shelf.contains(book.bookUrl))
        #expect(book.name == "测试" && book.author == "某人")

        let session = services.readerSession(for: book)
        await session.open()
        #expect(session.tocState == .ready)
        #expect(session.chapters.map(\.title) == ["第一章 开端", "第二章 发展", "第三章 结局"])
        let lines = paragraphs(await session.load(1))
        #expect(!lines.isEmpty)
        #expect(lines.allSatisfy { $0 == "风吹过山岗，河水静静流淌。" })

        services.removeBooks([book.bookUrl])
        #expect(!services.shelf.contains(book.bookUrl))
        #expect(!services.localBooks.exists(book))
    }

    @Test func 重新分章按章节名找回进度() async throws {
        let text = "简介\n第一卷 风起\n第一章 开端\n" + body() + "第二章 发展\n" + body() + "第三章 结局\n" + body()
        var book = try await services.importLocalBook(at: try writeFile("进度.txt", Data(text.utf8)))
        #expect(book.totalChapterNum == 5)
        book.durChapterIndex = 3
        book.durChapterPos = 30
        book.durChapterTitle = "第二章 发展"
        services.shelf.update(book)
        let stale = BookChapter(title: "旧缓存", bookUrl: book.bookUrl)
        services.chapterStore.saveContent("旧", bookUrl: book.bookUrl, chapter: stale)

        let updated = try await services.resplitLocalBook(book, tocMode: .pattern("^第.章.*$"))
        #expect(updated.totalChapterNum == 4)
        #expect(updated.durChapterIndex == 2 && updated.durChapterPos == 30 && updated.durChapterTitle == "第二章 发展")
        #expect(services.shelf.book(book.bookUrl)?.tocUrl == "^第.章.*$")
        #expect(services.shelf.book(book.bookUrl)?.durChapterIndex == 2)
        #expect(services.chapterStore.content(bookUrl: book.bookUrl, chapter: stale) == nil)

        let byLength = try await services.resplitLocalBook(updated, tocMode: .byLength)
        #expect(byLength.tocUrl.isEmpty)
        #expect((0..<byLength.totalChapterNum).contains(byLength.durChapterIndex))
        #expect(byLength.durChapterPos == 0)
        await #expect(throws: LocalBookError.invalidPattern("(")) {
            try await services.resplitLocalBook(byLength, tocMode: .pattern("("))
        }
    }

    @Test func EPUB正文写入章节缓存并读取插图() async throws {
        let book = try await services.importLocalBook(at: try ncxEpub())
        let service = services.contentService(for: book)
        let (_, chapters) = try await service.chapters(for: book)
        #expect(chapters.count == 6)
        #expect(!services.chapterStore.hasContent(bookUrl: book.bookUrl, chapter: chapters[3]))
        let content = try await service.content(for: book, chapter: chapters[3], nextChapter: chapters[4])
        #expect(content.contains("春天，他们在桥上相遇。"))
        #expect(services.chapterStore.hasContent(bookUrl: book.bookUrl, chapter: chapters[3]))

        let cover = try #require(book.coverUrl)
        #expect(try await services.imageData(cover, for: book) == coverPNG)
    }

    @Test func EPUB插图在阅读会话中直接就绪() async throws {
        let book = try await services.importLocalBook(at: try ncxEpub())
        let session = services.readerSession(for: book)
        await session.open()
        let index = try #require(session.chapters.firstIndex { $0.title.contains("相遇") })
        guard case .loaded(let text) = await session.load(index) else {
            Issue.record("正文应加载成功")
            return
        }
        let src = try #require(text.imageSources.first { $0.hasSuffix("map%20one.png") })
        #expect(text.imagesLoaded)
        #expect(session.imageData(for: src) == mapPNG)
    }
}
