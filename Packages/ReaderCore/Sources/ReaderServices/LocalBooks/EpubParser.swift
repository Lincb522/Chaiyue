import Foundation
import ReaderModels
import RuleEngine
import SwiftSoup
import ZIPFoundation

/// EPUB 解析，章节划分与 Legado EpubFile 一致：
/// - 有目录（NCX 或 EPUB3 nav）时按目录分章，第一个目录项之前的 spine 页面作为卷首章节，有子目录的项标记为卷；
/// - 没有目录时每个 spine 页面一章；
/// - 一章的正文从本章页面拼接到下一章页面之前，同一页面内用 fragment 截取。正文只保留图片标签
final class EpubParser {
    struct TocEntry {
        var title: String
        var path: String
        var fragment: String?
        var children: [TocEntry]
    }

    private let archive: Archive
    private(set) var title: String?
    private(set) var authors: [String] = []
    private(set) var intro: String?
    private(set) var coverPath: String?
    /// spine 中的 HTML 页面（压缩包内路径），即阅读顺序
    private(set) var spine: [String] = []
    private(set) var toc: [TocEntry] = []

    private var opfPath = ""
    private var manifest: [String: (path: String, mediaType: String, properties: String)] = [:]

    init(url: URL) throws {
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw LocalBookError.invalidEpub("无法打开 EPUB 文件")
        }
        try parsePackage()
    }

    // MARK: - 资源

    func data(at path: String) throws -> Data {
        guard let entry = entry(at: path) else { throw LocalBookError.invalidEpub("EPUB 中缺少文件：\(path)") }
        var data = Data()
        _ = try archive.extract(entry, skipCRC32: true) { data.append($0) }
        return data
    }

    func contains(_ path: String) -> Bool {
        entry(at: path) != nil
    }

    private func entry(at path: String) -> Entry? {
        if let entry = archive[path] { return entry }
        let lowered = path.lowercased()
        return archive.first { $0.path.replacingOccurrences(of: "\\", with: "/").lowercased() == lowered }
    }

    /// XHTML 文本：优先 XML 声明中的编码，其次 UTF-8、GB18030
    func text(at path: String) throws -> String {
        let data = try data(at: path)
        let head = String(decoding: data.prefix(200), as: UTF8.self)
        if let declared = head.firstMatch(of: /encoding\s*=\s*["']([A-Za-z0-9_\-]+)["']/)?.1,
           let encoding = Charsets.encoding(named: String(declared)),
           let text = String(data: data, encoding: encoding) {
            return text
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: Charsets.gb18030) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - OPF

    private func parsePackage() throws {
        guard let container = try? text(at: "META-INF/container.xml"),
              let doc = try? SwiftSoup.parse(container, "", Parser.xmlParser()),
              let rootfile = Self.elements(doc, "rootfile").first,
              case let path = Self.attr(rootfile, "full-path"), !path.isEmpty
        else { throw LocalBookError.invalidEpub("EPUB 容器文件缺失") }
        opfPath = Self.resolve(path, relativeTo: "")
        guard let opf = try? text(at: opfPath), let package = try? SwiftSoup.parse(opf, "", Parser.xmlParser()) else {
            throw LocalBookError.invalidEpub("EPUB 目录文件缺失")
        }

        title = Self.elements(package, "title").lazy.compactMap { Self.text($0) }.first
        authors = Self.elements(package, "creator").compactMap { Self.text($0) }
            .map { $0.replacingOccurrences(of: #"^\s*,\s*|\s*,\s*$"#, with: "", options: .regularExpression) }
            .filter { !$0.isEmpty }
        if let description = Self.elements(package, "description").lazy.compactMap({ Self.text($0) }).first {
            intro = description.contains("<") ? ((try? SwiftSoup.parse(description).text()) ?? description) : description
        }

        for item in Self.elements(package, "item") {
            let id = Self.attr(item, "id")
            let href = Self.attr(item, "href")
            guard !id.isEmpty, !href.isEmpty else { continue }
            manifest[id] = (Self.resolve(href, relativeTo: opfPath), Self.attr(item, "media-type").lowercased(),
                            Self.attr(item, "properties").lowercased())
        }
        let spineElement = Self.elements(package, "spine").first
        spine = Self.elements(package, "itemref").compactMap { manifest[Self.attr($0, "idref")] }
            .filter { $0.mediaType.contains("htm") || Self.isHTMLPath($0.path) }
            .map(\.path)

        let ncxID = spineElement.map { Self.attr($0, "toc") } ?? ""
        let ncxPath = manifest[ncxID]?.path ?? manifest.values.first { $0.mediaType == "application/x-dtbncx+xml" }?.path
        if let ncxPath, let entries = try? parseNCX(ncxPath), !entries.isEmpty {
            toc = entries
        } else if let navPath = manifest.values.first(where: { $0.properties.split(separator: " ").contains("nav") })?.path,
                  let entries = try? parseNav(navPath) {
            toc = entries
        }
        coverPath = findCover(package)
    }

    private func findCover(_ package: Document) -> String? {
        if let item = manifest.values.first(where: { $0.properties.split(separator: " ").contains("cover-image") }) {
            return item.path
        }
        for meta in Self.elements(package, "meta") where Self.attr(meta, "name").lowercased() == "cover" {
            let content = Self.attr(meta, "content")
            if let item = manifest[content], Self.isImage(item.mediaType, item.path) { return item.path }
            let path = Self.resolve(content, relativeTo: opfPath)
            if Self.isImagePath(path), contains(path) { return path }
        }
        for reference in Self.elements(package, "reference") where Self.attr(reference, "type").lowercased() == "cover" {
            let path = Self.resolve(Self.attr(reference, "href"), relativeTo: opfPath)
            if Self.isImagePath(path) { return path }
            if let html = try? text(at: path), let doc = try? SwiftSoup.parse(html),
               let image = try? doc.select("img[src], image").first() {
                let src = Self.attr(image, "src").isEmpty ? Self.attr(image, "xlink:href") : Self.attr(image, "src")
                if !src.isEmpty { return Self.resolve(src, relativeTo: path) }
            }
        }
        return manifest.first { id, item in
            Self.isImage(item.mediaType, item.path) && (id.lowercased().contains("cover") || item.path.lowercased().contains("cover"))
        }?.value.path
    }

    // MARK: - 目录

    private func parseNCX(_ path: String) throws -> [TocEntry] {
        let doc = try SwiftSoup.parse(try text(at: path), "", Parser.xmlParser())
        guard let navMap = Self.elements(doc, "navmap").first else { return [] }
        func points(_ parent: Element) -> [TocEntry] {
            parent.children().array().filter { Self.localName($0) == "navpoint" }.compactMap { point in
                let label = point.children().array().first { Self.localName($0) == "navlabel" }
                let title = label.flatMap { Self.elements($0, "text").first }.flatMap(Self.text) ?? ""
                let src = point.children().array().first { Self.localName($0) == "content" }.map { Self.attr($0, "src") } ?? ""
                let children = points(point)
                guard !src.isEmpty || !children.isEmpty else { return nil }
                return TocEntry(title: title, path: src.isEmpty ? "" : Self.resolve(src, relativeTo: path),
                                fragment: Self.fragment(src), children: children)
            }
        }
        return points(navMap)
    }

    private func parseNav(_ path: String) throws -> [TocEntry] {
        let doc = try SwiftSoup.parse(try text(at: path))
        let navs = try doc.select("nav").array()
        guard let nav = navs.first(where: { Self.attr($0, "epub:type").contains("toc") }) ?? navs.first,
              let list = try nav.select("ol").first()
        else { return [] }
        func items(_ list: Element) -> [TocEntry] {
            list.children().array().filter { $0.tagName().lowercased() == "li" }.compactMap { li in
                let children = li.children().array()
                let link = children.first { $0.tagName().lowercased() == "a" }
                let label = link ?? children.first { $0.tagName().lowercased() == "span" }
                let href = link.map { Self.attr($0, "href") } ?? ""
                let nested = children.first { $0.tagName().lowercased() == "ol" }.map(items) ?? []
                guard !href.isEmpty || !nested.isEmpty else { return nil }
                return TocEntry(title: label.flatMap(Self.text) ?? "", path: href.isEmpty ? "" : Self.resolve(href, relativeTo: path),
                                fragment: Self.fragment(href), children: nested)
            }
        }
        return items(list)
    }

    // MARK: - 章节

    func chapters(bookUrl: String) -> [BookChapter] {
        var chapters: [BookChapter] = []
        if toc.isEmpty {
            for (i, path) in spine.enumerated() {
                var title = pageTitle(path)
                if title.isEmpty { title = i == 0 ? "封面" : "第\(i + 1)节" }
                chapters.append(BookChapter(url: path, title: title, bookUrl: bookUrl))
            }
        } else {
            if let first = Self.firstPath(toc) {
                for path in spine {
                    if path == first { break }
                    let title = pageTitle(path)
                    chapters.append(BookChapter(url: path, title: title.isEmpty ? "--卷首--" : title, bookUrl: bookUrl))
                }
            }
            flatten(toc, into: &chapters, bookUrl: bookUrl)
        }
        let linked = chapters.indices.map { i in chapters[(i + 1)...].first { !$0.url.isEmpty } }
        for i in chapters.indices {
            chapters[i].index = i
            if let next = linked[i] {
                chapters[i].endFragmentId = next.startFragmentId
                chapters[i].variableMap["nextUrl"] = next.url
            }
        }
        return chapters
    }

    private func flatten(_ entries: [TocEntry], into chapters: inout [BookChapter], bookUrl: String) {
        for entry in entries {
            if !entry.path.isEmpty, contains(entry.path) {
                var chapter = BookChapter(url: entry.path + (entry.fragment.map { "#" + $0 } ?? ""), title: entry.title,
                                          bookUrl: bookUrl)
                chapter.startFragmentId = entry.fragment
                chapters.append(chapter)
            } else if !entry.children.isEmpty {
                chapters.append(BookChapter(title: entry.title, bookUrl: bookUrl))
            }
            if !entry.children.isEmpty {
                chapters[chapters.count - 1].isVolume = true
                flatten(entry.children, into: &chapters, bookUrl: bookUrl)
            }
        }
    }

    private static func firstPath(_ entries: [TocEntry]) -> String? {
        for entry in entries {
            if !entry.path.isEmpty { return entry.path }
            if let path = firstPath(entry.children) { return path }
        }
        return nil
    }

    /// 页面标题：`<title>`，其次第一个 h1–h3
    private func pageTitle(_ path: String) -> String {
        guard let html = try? text(at: path) else { return "" }
        for pattern in [#"<title[^>]*>([\s\S]*?)</title>"#, #"<h[1-3][^>]*>([\s\S]*?)</h[1-3]>"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html)
            else { continue }
            let title = HTMLFormatter.format(String(html[range])).trimmingCharacters(in: CharacterSet(charactersIn: "\u{3000}").union(.whitespacesAndNewlines))
            if !title.isEmpty { return title }
        }
        return ""
    }

    // MARK: - 正文

    /// 一章的正文。`coverURL` 为封面图片地址（封面页显示为封面图），`resourceURL` 把压缩包内路径转成插图地址
    func content(of chapter: BookChapter, coverURL: String?, resourceURL: (String) -> String) throws -> String {
        let path = Self.stripFragment(chapter.url)
        guard !path.isEmpty else { return "" }
        let nextPath = Self.stripFragment(chapter.variableMap["nextUrl"] ?? "")
        let isLast = nextPath.isEmpty
        let start = chapter.startFragmentId
        let end = chapter.endFragmentId

        var parts: [String] = []
        var coverShown = false
        func append(_ page: String, start: String?, end: String?) throws {
            if page.contains("titlepage.xhtml") || page.contains("cover") {
                if let coverURL, !coverShown {
                    parts.append("<img src=\"\(coverURL)\">")
                    coverShown = true
                }
                return
            }
            if let html = try body(of: page, start: start, end: end, resourceURL: resourceURL) {
                parts.append(html)
            }
        }

        if let first = spine.firstIndex(of: path) {
            var index = first
            while index < spine.count {
                let page = spine[index]
                if index == first {
                    try append(page, start: start, end: end)
                    if !isLast, page == nextPath { break }
                } else if page != nextPath {
                    try append(page, start: nil, end: nil)
                } else {
                    if let end, !end.isEmpty { try append(page, start: nil, end: end) }
                    break
                }
                index += 1
            }
        } else {
            try append(path, start: start, end: end)
        }
        return HTMLFormatter.formatKeepImg(parts.joined(separator: "\n"))
    }

    private func body(of page: String, start: String?, end: String?, resourceURL: (String) -> String) throws -> String? {
        let doc = try SwiftSoup.parse(try text(at: page))
        guard let body = doc.body() else { return nil }
        try body.select("script, style").remove()
        if let start, !start.isEmpty, let element = try doc.getElementById(start) {
            Self.removeNodes(before: element, within: body)
        }
        if let end, !end.isEmpty, end != start, let element = try doc.getElementById(end) {
            Self.removeNodes(from: element, within: body)
        }
        try body.select("title").remove()
        try body.select("[style*=display:none]").remove()
        for image in try body.select("img, image").array() {
            var src = Self.attr(image, "src")
            if src.isEmpty { src = Self.attr(image, "xlink:href") }
            src = src.trimmingCharacters(in: .whitespaces)
            if src.isEmpty || src.hasPrefix("data:") {
                try image.remove()
                continue
            }
            for attribute in image.getAttributes()?.asList() ?? [] {
                try image.removeAttr(attribute.getKey())
            }
            try image.tagName("img")
            try image.attr("src", resourceURL(Self.resolve(src, relativeTo: page)))
        }
        return try body.html()
    }

    /// 保留 `element` 及其后的内容：沿祖先链删除每一层之前的兄弟节点
    private static func removeNodes(before element: Element, within body: Element) {
        var node: Node = element
        while let parent = node.parent() {
            for sibling in Array(parent.getChildNodes().prefix(node.siblingIndex)) {
                try? sibling.remove()
            }
            if parent === body { break }
            node = parent
        }
    }

    /// 删除 `element` 及其后的内容：沿祖先链删除每一层之后的兄弟节点
    private static func removeNodes(from element: Element, within body: Element) {
        var node: Node = element
        while let parent = node.parent() {
            for sibling in Array(parent.getChildNodes().dropFirst(node.siblingIndex + 1)) {
                try? sibling.remove()
            }
            if parent === body { break }
            node = parent
        }
        try? element.remove()
    }

    // MARK: - 工具

    static func resolve(_ href: String, relativeTo base: String) -> String {
        var reference = stripFragment(href)
        if let query = reference.firstIndex(of: "?") { reference = String(reference[..<query]) }
        reference = (reference.removingPercentEncoding ?? reference).replacingOccurrences(of: "\\", with: "/")
        var parts = reference.hasPrefix("/") ? [] : base.split(separator: "/").dropLast().map(String.init)
        for component in reference.split(separator: "/") {
            switch component {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(String(component))
            }
        }
        return parts.joined(separator: "/")
    }

    static func stripFragment(_ href: String) -> String {
        href.firstIndex(of: "#").map { String(href[..<$0]) } ?? href
    }

    static func fragment(_ href: String) -> String? {
        guard let hash = href.firstIndex(of: "#") else { return nil }
        let fragment = String(href[href.index(after: hash)...])
        return fragment.isEmpty ? nil : (fragment.removingPercentEncoding ?? fragment)
    }

    private static func isHTMLPath(_ path: String) -> Bool {
        ["html", "htm", "xhtml"].contains((path as NSString).pathExtension.lowercased())
    }

    private static func isImagePath(_ path: String) -> Bool {
        ["jpg", "jpeg", "jpe", "png", "gif", "webp", "bmp"].contains((path as NSString).pathExtension.lowercased())
    }

    private static func isImage(_ mediaType: String, _ path: String) -> Bool {
        mediaType.hasPrefix("image/") || isImagePath(path)
    }

    static func localName(_ element: Element) -> String {
        let tag = element.tagName().lowercased()
        return tag.split(separator: ":").last.map(String.init) ?? tag
    }

    static func elements(_ root: Element, _ name: String) -> [Element] {
        ((try? root.getAllElements().array()) ?? []).filter { localName($0) == name }
    }

    static func attr(_ element: Element, _ key: String) -> String {
        if let value = try? element.attr(key), !value.isEmpty { return value }
        let lowered = key.lowercased()
        return element.getAttributes()?.asList().first { $0.getKey().lowercased() == lowered }?.getValue() ?? ""
    }

    static func text(_ element: Element) -> String? {
        let text = ((try? element.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
