import Foundation
import SwiftSoup
import ZIPFoundation

/// FB2（FictionBook 2）解析，`.fbz` / `.fb2.zip` 先解压出其中的 `.fb2`。
/// 第一个 body 按 section 分章（有子 section 的为卷），之后的 body（注释等）各成一章；
/// `<binary>` 中的封面与插图导出为文件
enum Fb2Parser {
    static func convert(_ url: URL, context: ConversionContext) throws -> ConvertedBook {
        guard var data = try? Data(contentsOf: url) else { throw LocalBookError.fileMissing }
        guard !data.isEmpty else { throw LocalBookError.emptyFile }
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            guard let archive = ConvertedText.openArchive(url),
                  let entry = archive.first(where: { $0.type == .file && $0.path.lowercased().hasSuffix(".fb2") })
            else { throw LocalBookError.corruptFile("压缩包中没有 FB2 文件") }
            data = Data()
            _ = try archive.extract(entry, skipCRC32: true) { data.append($0) }
        }
        let head = String(decoding: data.prefix(200), as: UTF8.self)
        let declared = head.firstMatch(of: /encoding\s*=\s*["']([A-Za-z0-9_\-]+)["']/).map { String($0.1) }
        let xml = ConvertedText.decode(data, declared: declared)
        guard let doc = try? SwiftSoup.parse(xml, "", Parser.xmlParser()),
              let root = EpubParser.elements(doc, "fictionbook").first
        else { throw LocalBookError.corruptFile("不是有效的 FB2 文件") }

        var binaries: [String: Element] = [:]
        for binary in root.children().array() where EpubParser.localName(binary) == "binary" {
            binaries[EpubParser.attr(binary, "id")] = binary
        }
        var urls: [String: String?] = [:]
        func imageData(_ href: String) -> Data? {
            let id = href.hasPrefix("#") ? String(href.dropFirst()) : href
            guard let binary = binaries[id] else { return nil }
            return Data(base64Encoded: binary.textNodes().map { $0.getWholeText() }.joined(), options: .ignoreUnknownCharacters)
        }
        func imageURL(_ element: Element) -> String? {
            let href = Self.href(element)
            if let cached = urls[href] { return cached }
            let url = imageData(href).flatMap { context.addResource($0, name: String(href.drop { $0 == "#" })) }
            urls[href] = url
            return url
        }

        var html = ""
        let bodies = root.children().array().filter { EpubParser.localName($0) == "body" }
        for (index, body) in bodies.enumerated() {
            if index == 0 {
                render(body, depth: 0, flatten: false, into: &html, image: imageURL)
            } else {
                let title = body.children().array().first { EpubParser.localName($0) == "title" }.flatMap(EpubParser.text)
                html += ConvertedText.markerHTML(level: 1, title: title ?? "注释")
                render(body, depth: 1, flatten: true, into: &html, image: imageURL)
            }
        }
        let text = ConvertedText.text(fromHTML: "<html><body>" + html + "</body></html>") { ConvertedText.imageSource($0) }

        var book = ConvertedBook(chapters: try ConvertedText.chapters(text, rules: context.rules))
        if let info = EpubParser.elements(root, "title-info").first {
            book.title = EpubParser.elements(info, "book-title").first.flatMap(EpubParser.text)
            book.authors = info.children().array().filter { EpubParser.localName($0) == "author" }.compactMap { author in
                let parts = ["first-name", "middle-name", "last-name"].compactMap { name in
                    author.children().array().first { EpubParser.localName($0) == name }.flatMap(EpubParser.text)
                }
                let name = parts.joined(separator: " ")
                return name.isEmpty ? EpubParser.elements(author, "nickname").first.flatMap(EpubParser.text) : name
            }
            if let annotation = EpubParser.elements(info, "annotation").first {
                book.intro = annotation.children().array().compactMap(EpubParser.text).joined(separator: "\n").nilIfEmpty
                    ?? EpubParser.text(annotation)
            }
            if let image = EpubParser.elements(info, "coverpage").first.flatMap({ EpubParser.elements($0, "image").first }) {
                book.cover = imageData(href(image))
            }
        }
        return book
    }

    private static func href(_ element: Element) -> String {
        element.getAttributes()?.asList().first { $0.getKey().lowercased().hasSuffix("href") }?.getValue() ?? ""
    }

    /// 输出为 HTML 段落：section 前插入章节标记（`flatten` 时标题只作普通段落）
    private static func render(_ element: Element, depth: Int, flatten: Bool, into html: inout String,
                               image: (Element) -> String?) {
        for child in element.children().array() {
            switch EpubParser.localName(child) {
            case "section":
                let title = child.children().array().first { EpubParser.localName($0) == "title" }
                    .map { $0.children().array().compactMap(EpubParser.text).joined(separator: " ") } ?? ""
                if flatten {
                    if !title.isEmpty { html += "<p>" + ConvertedText.escapeHTML(title) + "</p>" }
                } else {
                    html += ConvertedText.markerHTML(level: depth + 1, title: title)
                }
                render(child, depth: depth + 1, flatten: flatten, into: &html, image: image)
            case "title":
                continue
            case "p", "subtitle", "v", "text-author", "td", "th":
                if let text = EpubParser.text(child) { html += "<p>" + ConvertedText.escapeHTML(text) + "</p>" }
                for inline in EpubParser.elements(child, "image") {
                    if let src = image(inline) { html += "<p><img src=\"\(ConvertedText.escapeHTML(src))\"></p>" }
                }
            case "image":
                if let src = image(child) { html += "<p><img src=\"\(ConvertedText.escapeHTML(src))\"></p>" }
            case "empty-line", "binary":
                continue
            default:
                render(child, depth: depth, flatten: flatten, into: &html, image: image)
            }
        }
    }
}
