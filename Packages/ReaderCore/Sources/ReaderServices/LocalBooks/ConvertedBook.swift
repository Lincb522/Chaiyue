import Foundation
import ReaderModels
import RuleEngine
import SwiftSoup
import ZIPFoundation

/// 导入时整本转换一次的格式。转换结果每章是纯文本段落（插图为单独一行的 `<img src>`），
/// 统一写入 `content.txt` 按偏移读取，插图导出到书籍目录的 `res/`，之后不再解析原文件
enum ConvertedBookFormat: String, Sendable {
    case mobi, umd, fb2, docx, html, markdown, rtf

    static let byExtension: [String: ConvertedBookFormat] = [
        "mobi": .mobi, "azw": .mobi, "azw3": .mobi, "prc": .mobi,
        "umd": .umd,
        "fb2": .fb2, "fbz": .fb2,
        "docx": .docx,
        "html": .html, "htm": .html, "xhtml": .html,
        "md": .markdown, "markdown": .markdown,
        "rtf": .rtf,
    ]
    static let extensions = Set(byExtension.keys)

    func convert(_ url: URL, context: ConversionContext) throws -> ConvertedBook {
        switch self {
        case .mobi: try MobiParser.convert(url, context: context)
        case .umd: try UmdParser.convert(url, context: context)
        case .fb2: try Fb2Parser.convert(url, context: context)
        case .docx: try DocxParser.convert(url, context: context)
        case .html: try HtmlBookParser.convert(url, context: context)
        case .markdown: try MarkdownParser.convert(url, context: context)
        case .rtf: try RtfParser.convert(url, context: context)
        }
    }
}

struct ConvertedChapter: Equatable, Sendable {
    var title: String
    var content: String
    var isVolume = false
}

struct ConvertedBook {
    var title: String?
    var authors: [String] = []
    var intro: String?
    var cover: Data?
    var chapters: [ConvertedChapter]
}

/// 转换过程中的插图导出与分章规则
final class ConversionContext {
    static let resourceFolder = "res"

    let rules: [TxtTocRule]
    private let directory: URL
    private let urlPrefix: String
    private var names: Set<String> = []

    init(directory: URL, urlPrefix: String, rules: [TxtTocRule]) {
        self.directory = directory
        self.urlPrefix = urlPrefix
        self.rules = rules
    }

    /// 写入插图，返回正文中使用的 `localbook://` 地址；文件名只保留安全字符，重名时加序号
    func addResource(_ data: Data, name: String) -> String? {
        guard !data.isEmpty else { return nil }
        var safe = String(name.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") ? $0 : "_" })
        while safe.hasPrefix(".") { safe.removeFirst() }
        if safe.isEmpty { safe = "image" }
        if (safe as NSString).pathExtension.isEmpty, let ext = ConvertedText.imageExtension(data) { safe += "." + ext }
        if names.contains(safe) { safe = "\(names.count)_" + safe }
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        guard (try? data.write(to: directory.appendingPathComponent(safe))) != nil else { return nil }
        names.insert(safe)
        return urlPrefix + safe
    }
}

/// 转换结果的文本工具：段落规整、章节标记与分章
enum ConvertedText {
    /// 章节标记：单独一行的 `\u{E000}<层级>\u{E001}<标题>`，标题为空时取本章第一行
    static let markerStart = "\u{E000}"
    static let markerSeparator = "\u{E001}"

    static func marker(level: Int, title: String) -> String {
        markerStart + String(level) + markerSeparator
            + title.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    static func markerHTML(level: Int, title: String) -> String {
        "<p>" + escapeHTML(marker(level: level, title: title)) + "</p>"
    }

    static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let blank = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{3000}\u{FEFF}"))

    /// 非空行去掉首尾空白，每段以两个全角空格缩进
    static func paragraphs<S: Sequence>(_ lines: S) -> String where S.Element: StringProtocol {
        lines.lazy.map { $0.trimmingCharacters(in: blank) }.filter { !$0.isEmpty }.map { "\u{3000}\u{3000}" + $0 }
            .joined(separator: "\n")
    }

    static func paragraphs(_ text: String) -> String {
        paragraphs(text.split(omittingEmptySubsequences: true) { $0 == "\n" || $0 == "\r" || $0 == "\u{2029}" || $0 == "\u{2028}" })
    }

    /// 分章：有章节标记时按标记分（第一个标记前的内容为「前言」，没有正文的章节标记为卷）；
    /// 没有标记时按 TXT 目录规则自动识别，识别不到按长度分章
    static func chapters(_ text: String, rules: [TxtTocRule]) throws -> [ConvertedChapter] {
        var preface: [String] = []
        var sections: [(title: String, lines: [String])] = []
        for raw in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: blank)
            guard !line.isEmpty else { continue }
            if line.hasPrefix(markerStart), let separator = line.range(of: markerSeparator) {
                sections.append((String(line[separator.upperBound...]).trimmingCharacters(in: blank), []))
            } else if sections.isEmpty {
                preface.append(line)
            } else {
                sections[sections.count - 1].lines.append(line)
            }
        }
        guard !sections.isEmpty else { return try plainChapters(text, rules: rules) }

        var chapters: [ConvertedChapter] = []
        if !preface.isEmpty { chapters.append(ConvertedChapter(title: "前言", content: paragraphs(preface))) }
        for (i, section) in sections.enumerated() {
            var title = section.title
            var lines = section.lines
            if title.isEmpty {
                // 无标题的分页：第一行较短时当作标题
                guard let first = lines.first else { continue }
                if first.count <= 40, !first.hasPrefix("<img") {
                    title = first
                    lines.removeFirst()
                } else {
                    title = "第\(chapters.count + 1)节"
                }
            } else if lines.first == title {
                // 目录定位到标题元素时，正文第一行就是标题
                lines.removeFirst()
            }
            chapters.append(ConvertedChapter(title: title, content: paragraphs(lines),
                                             isVolume: lines.isEmpty && i + 1 < sections.count))
        }
        guard !chapters.isEmpty else { throw LocalBookError.chapterListEmpty }
        return chapters
    }

    /// 纯文本按 TXT 规则分章
    static func plainChapters(_ text: String, rules: [TxtTocRule]) throws -> [ConvertedChapter] {
        let normalized = paragraphs(text)
        guard !normalized.isEmpty else { throw LocalBookError.emptyFile }
        let result = try TxtChapterSplitter.split(normalized, mode: .auto, rules: rules)
        let ns = TxtChapterSplitter.nativeString(normalized)
        let chapters = result.chapters.map { span in
            let body = ns.substring(with: NSRange(location: span.range.lowerBound, length: span.range.count))
            return ConvertedChapter(title: span.title, content: body.trimmingCharacters(in: .newlines), isVolume: span.isVolume)
        }
        guard !chapters.isEmpty else { throw LocalBookError.chapterListEmpty }
        return chapters
    }

    // MARK: - HTML

    /// HTML 转为段落文本：去掉脚本与隐藏内容，`levels` 内的 h1–h6 转为章节标记，
    /// `image` 返回插图地址（nil 时去掉该图）。实体已解码
    static func text(fromHTML html: String, headingLevels levels: ClosedRange<Int>? = nil,
                     image: (Element) -> String?) -> String {
        guard let doc = try? SwiftSoup.parse(html), let body = doc.body() else { return "" }
        return text(fromBody: body, headingLevels: levels, image: image)
    }

    static func text(fromBody body: Element, headingLevels levels: ClosedRange<Int>? = nil,
                     image: (Element) -> String?) -> String {
        _ = try? body.select("script, style, title, head, noscript").remove()
        _ = try? body.select("[style*=display:none], [style*=display: none]").remove()
        for element in (try? body.select("img, image").array()) ?? [] {
            guard let src = image(element), !src.isEmpty else {
                _ = try? element.remove()
                continue
            }
            for attribute in element.getAttributes()?.asList() ?? [] {
                _ = try? element.removeAttr(attribute.getKey())
            }
            _ = try? element.tagName("img")
            _ = try? element.attr("src", src)
        }
        if let levels {
            for heading in (try? body.select("h1, h2, h3, h4, h5, h6").array()) ?? [] {
                guard let level = Int(heading.tagName().dropFirst()), levels.contains(level),
                      let title = EpubParser.text(heading)
                else { continue }
                _ = try? heading.before(markerHTML(level: level, title: title))
                _ = try? heading.remove()
            }
        }
        let formatted = HTMLFormatter.formatKeepImg((try? body.html()) ?? "")
        return formatted.contains("&") ? ((try? Entities.unescape(formatted)) ?? formatted) : formatted
    }

    /// HTML 元素中的图片地址（`src` 或 SVG 的 `xlink:href`）
    static func imageSource(_ element: Element) -> String {
        let src = EpubParser.attr(element, "src")
        if !src.isEmpty { return src.trimmingCharacters(in: .whitespaces) }
        return (element.getAttributes()?.asList().first { $0.getKey().lowercased().hasSuffix("href") }?.getValue() ?? "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// `data:image/png;base64,...` 内嵌图片
    static func dataURI(_ src: String) -> Data? {
        guard src.hasPrefix("data:"), let comma = src.firstIndex(of: ","), src[..<comma].hasSuffix(";base64") else { return nil }
        return Data(base64Encoded: String(src[src.index(after: comma)...]), options: .ignoreUnknownCharacters)
    }

    static func isRemote(_ src: String) -> Bool {
        let lowered = src.lowercased()
        return lowered.hasPrefix("http://") || lowered.hasPrefix("https://")
    }

    // MARK: - 二进制工具

    static func imageExtension(_ data: Data) -> String? {
        let head = [UInt8](data.prefix(12))
        guard head.count >= 4 else { return nil }
        if head[0] == 0xFF, head[1] == 0xD8, head[2] == 0xFF { return "jpg" }
        if head[0] == 0x89, head[1] == 0x50, head[2] == 0x4E, head[3] == 0x47 { return "png" }
        if head[0] == 0x47, head[1] == 0x49, head[2] == 0x46, head[3] == 0x38 { return "gif" }
        if head[0] == 0x42, head[1] == 0x4D { return "bmp" }
        if head.count >= 12, head[0...3] == [0x52, 0x49, 0x46, 0x46], head[8...11] == [0x57, 0x45, 0x42, 0x50] { return "webp" }
        return nil
    }

    /// zlib 流（带 2 字节头与 Adler-32 尾）或裸 deflate 流解压
    static func inflate(_ bytes: [UInt8]) -> Data? {
        var raw = bytes[...]
        if raw.count > 6, raw[raw.startIndex] & 0x0F == 8,
           (Int(raw[raw.startIndex]) << 8 | Int(raw[raw.startIndex + 1])) % 31 == 0 {
            raw = raw.dropFirst(2).dropLast(4)
        }
        return try? (Data(raw) as NSData).decompressed(using: .zlib) as Data
    }

    static func openArchive(_ url: URL) -> Archive? {
        do {
            return try Archive(url: url, accessMode: .read)
        } catch {
            return nil
        }
    }

    /// 按声明或探测的编码解码文本（XML/HTML 声明优先）
    static func decode(_ data: Data, declared: String?) -> String {
        if let declared, let encoding = Charsets.encoding(named: declared), let text = String(data: data, encoding: encoding) {
            return text
        }
        return TextEncodingDetector.decode(data, charset: TextEncodingDetector.detect(data))
    }
}

extension Array where Element == UInt8 {
    func beU16(_ offset: Int) -> Int {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        return Int(self[offset]) << 8 | Int(self[offset + 1])
    }

    func beU32(_ offset: Int) -> Int {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        return Int(self[offset]) << 24 | Int(self[offset + 1]) << 16 | Int(self[offset + 2]) << 8 | Int(self[offset + 3])
    }

    func leU16(_ offset: Int) -> Int {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        return Int(self[offset]) | Int(self[offset + 1]) << 8
    }

    func leU32(_ offset: Int) -> Int {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        return Int(self[offset]) | Int(self[offset + 1]) << 8 | Int(self[offset + 2]) << 16 | Int(self[offset + 3]) << 24
    }

    func ascii(_ range: Range<Int>) -> String {
        guard range.lowerBound >= 0, range.upperBound <= count else { return "" }
        return String(decoding: self[range], as: UTF8.self)
    }
}
