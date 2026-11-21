import Foundation
import SwiftSoup
import ZIPFoundation

/// DOCX 解析：读取 `word/document.xml` 的段落，标题样式（Heading 1/2、标题 1/2，或大纲级别 1/2）处分章，
/// 没有标题样式时按 TXT 目录规则识别、再按长度分章；`word/media` 中被引用的图片导出为文件
enum DocxParser {
    static func convert(_ url: URL, context: ConversionContext) throws -> ConvertedBook {
        guard let archive = ConvertedText.openArchive(url) else { throw LocalBookError.corruptFile("无法打开 DOCX 文件") }
        func read(_ path: String) -> Data? {
            guard let entry = archive[path] ?? archive.first(where: { $0.path.lowercased() == path.lowercased() }) else { return nil }
            var data = Data()
            guard (try? archive.extract(entry, skipCRC32: true) { data.append($0) }) != nil else { return nil }
            return data
        }
        func xml(_ path: String) -> Document? {
            read(path).flatMap { try? SwiftSoup.parse(String(decoding: $0, as: UTF8.self), "", Parser.xmlParser()) }
        }
        guard let document = xml("word/document.xml"), let body = EpubParser.elements(document, "body").first else {
            throw LocalBookError.corruptFile("DOCX 中缺少正文（word/document.xml）")
        }

        let styles = Styles(xml("word/styles.xml"))
        var targets: [String: String] = [:]
        if let rels = xml("word/_rels/document.xml.rels") {
            for rel in EpubParser.elements(rels, "relationship") where EpubParser.attr(rel, "TargetMode").lowercased() != "external" {
                targets[EpubParser.attr(rel, "Id")] = EpubParser.resolve(EpubParser.attr(rel, "Target"), relativeTo: "word/document.xml")
            }
        }
        var urls: [String: String?] = [:]
        func imageURL(_ id: String) -> String? {
            guard let path = targets[id] else { return nil }
            if let cached = urls[path] { return cached }
            let url = read(path).flatMap { context.addResource($0, name: (path as NSString).lastPathComponent) }
            urls[path] = url
            return url
        }

        var lines: [String] = []
        for paragraph in body.getAllElementsArray() where paragraph.tagName().lowercased() == "w:p" && !paragraph.isInFallback {
            var text = ""
            var images: [String] = []
            collect(paragraph, text: &text, images: &images)
            let title = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if let level = styles.headingLevel(of: paragraph), level <= 2, !title.isEmpty {
                lines.append(ConvertedText.marker(level: level, title: title))
            } else {
                lines += text.components(separatedBy: "\n")
            }
            lines += images.compactMap(imageURL).map { "<img src=\"\($0)\">" }
        }

        var book = ConvertedBook(chapters: try ConvertedText.chapters(lines.joined(separator: "\n"), rules: context.rules))
        if let core = xml("docProps/core.xml") {
            book.title = EpubParser.elements(core, "title").first.flatMap(EpubParser.text)
            book.authors = EpubParser.elements(core, "creator").compactMap(EpubParser.text)
            book.intro = EpubParser.elements(core, "description").first.flatMap(EpubParser.text)
        }
        return book
    }

    /// 段落中的文字与图片引用；不进入嵌套段落（文本框）、删除的修订与兼容块的备用内容
    private static func collect(_ element: Element, text: inout String, images: inout [String]) {
        for child in element.children().array() {
            switch child.tagName().lowercased() {
            case "w:t":
                text += child.textNodes().map { $0.getWholeText() }.joined()
            case "w:tab":
                text += " "
            case "w:br", "w:cr":
                if EpubParser.attr(child, "w:type") != "page" { text += "\n" }
            case "w:p", "w:txbxcontent", "w:del", "w:instrtext", "w:deltext", "mc:fallback", "w:ppr", "w:rpr":
                continue
            case "a:blip":
                let id = EpubParser.attr(child, "r:embed")
                if !id.isEmpty { images.append(id) }
            case "v:imagedata":
                let id = EpubParser.attr(child, "r:id")
                if !id.isEmpty { images.append(id) }
            default:
                collect(child, text: &text, images: &images)
            }
        }
    }

    /// 段落样式：样式 ID 或名称为 Heading N / 标题 N，或带大纲级别；沿 basedOn 继承
    private struct Styles {
        private var styles: [String: (name: String, outline: Int?, basedOn: String?)] = [:]

        init(_ document: Document?) {
            guard let document else { return }
            for style in EpubParser.elements(document, "style") {
                let id = EpubParser.attr(style, "w:styleId")
                guard !id.isEmpty else { continue }
                let name = EpubParser.elements(style, "name").first.map { EpubParser.attr($0, "w:val") } ?? ""
                let outline = EpubParser.elements(style, "outlinelvl").first.flatMap { Int(EpubParser.attr($0, "w:val")) }
                let basedOn = EpubParser.elements(style, "basedon").first.map { EpubParser.attr($0, "w:val") }
                styles[id] = (name, outline, basedOn)
            }
        }

        func headingLevel(of paragraph: Element) -> Int? {
            guard let properties = paragraph.children().array().first(where: { $0.tagName().lowercased() == "w:ppr" }) else { return nil }
            let children = properties.children().array()
            if let outline = children.first(where: { $0.tagName().lowercased() == "w:outlinelvl" }).flatMap({ Int(EpubParser.attr($0, "w:val")) }) {
                return outline < 9 ? outline + 1 : nil
            }
            guard let style = children.first(where: { $0.tagName().lowercased() == "w:pstyle" }).map({ EpubParser.attr($0, "w:val") }) else {
                return nil
            }
            return level(style, depth: 0)
        }

        private func level(_ id: String, depth: Int) -> Int? {
            if let level = Self.level(named: id) { return level }
            guard let style = styles[id], depth < 8 else { return nil }
            if let level = Self.level(named: style.name) { return level }
            if let outline = style.outline { return outline < 9 ? outline + 1 : nil }
            return style.basedOn.flatMap { level($0, depth: depth + 1) }
        }

        private static func level(named name: String) -> Int? {
            let compact = name.lowercased().replacingOccurrences(of: " ", with: "")
            guard let match = compact.wholeMatch(of: /(?:heading|标题)([1-9])/) else { return nil }
            return Int(match.1)
        }
    }
}

private extension Element {
    func getAllElementsArray() -> [Element] {
        (try? getAllElements().array()) ?? []
    }

    /// 兼容块（mc:AlternateContent）的备用内容与首选内容重复
    var isInFallback: Bool {
        var node = parent()
        while let current = node {
            if current.tagName().lowercased() == "mc:fallback" { return true }
            node = current.parent()
        }
        return false
    }
}
