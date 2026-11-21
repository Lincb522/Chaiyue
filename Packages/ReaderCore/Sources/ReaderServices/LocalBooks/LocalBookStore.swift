import Foundation
import ReaderModels

public enum LocalBookError: LocalizedError, Sendable, Equatable {
    case unsupportedFormat(String)
    case emptyFile
    case invalidPattern(String)
    case noChapterMatched
    case fileMissing
    case invalidEpub(String)
    case chapterListEmpty
    case notTextBook
    /// 文件损坏或结构不符，参数为完整的提示
    case corruptFile(String)
    /// 格式的某种变体暂不支持（HUFF/CDIC 压缩的 MOBI、漫画型 UMD 等），参数为完整的提示
    case unsupportedVariant(String)
    case drmProtected

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext): "暂不支持导入该格式（\(ext.isEmpty ? "无扩展名" : ext)）"
        case .emptyFile: "文件内容为空"
        case .invalidPattern: "目录规则不是有效的正则表达式"
        case .noChapterMatched: "目录规则没有匹配到章节"
        case .fileMissing: "书籍文件不存在，请重新导入"
        case .invalidEpub(let reason): reason
        case .chapterListEmpty: "未解析到可阅读章节"
        case .notTextBook: "只有 TXT 书籍可以重新分章"
        case .corruptFile(let reason): reason
        case .unsupportedVariant(let reason): reason
        case .drmProtected: "这本书受 DRM 加密保护，无法导入，请使用无 DRM 的版本"
        }
    }
}

public struct LocalBookImport: Sendable {
    public var book: Book
    public var chapters: [BookChapter]
}

/// 本地书文件：每本书一个目录 `<root>/<id>/`，存原文件 `book.<扩展名>`、目录 `chapters.json`、封面 `cover`，
/// TXT 另存解码后的正文 `content.txt`（UTF-8，章节的 start/end 为其中的字节偏移）；
/// MOBI、UMD、FB2、DOCX、HTML、Markdown、RTF 导入时整本转换，同样写 `content.txt`，插图导出到 `res/`。
/// 书籍地址为 `localbook://<id>`，封面与插图为 `localbook://<id>/<路径>`
public final class LocalBookStore: Sendable {
    public static let scheme = "localbook"
    public static let supportedExtensions: Set<String> = Set(["txt", "epub"])
        .union(LocalMediaImporter.extensions)
        .union(ConvertedBookFormat.extensions)
    static let coverName = "cover"

    public let root: URL

    public init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: - 导入

    /// 导入本地书，文件复制到书籍目录。`name`、`author` 为空时从文件名（EPUB 等从元数据）解析
    public func importBook(from url: URL, name: String? = nil, author: String? = nil, tocMode: TxtTocMode = .auto,
                           rules: [TxtTocRule] = TxtTocRule.defaults) throws -> LocalBookImport {
        let fileName = url.lastPathComponent
        let ext = Self.fileExtension(fileName)
        if LocalMediaImporter.handles(ext) || Self.isDirectory(url) {
            return try importMediaFiles(from: [url], name: name, author: author)
        }
        guard Self.supportedExtensions.contains(ext) else { throw LocalBookError.unsupportedFormat(ext) }
        let id = UUID().uuidString.lowercased()
        let dir = directory(id)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try fm.copyItem(at: url, to: dir.appendingPathComponent("book." + ext))
            var book = Book(bookUrl: "\(Self.scheme)://\(id)", origin: Book.localOrigin)
            book.originName = fileName
            book.canUpdate = false
            let parsed = Self.parseFileName(fileName)
            book.name = parsed.name
            book.author = parsed.author
            let result = if ext == "epub" {
                try buildEpub(book)
            } else if let format = ConvertedBookFormat.byExtension[ext] {
                try buildConverted(book, format: format, rules: rules)
            } else {
                try buildText(book, tocMode: tocMode, rules: rules)
            }
            book = result.book
            if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { book.name = name }
            if let author = author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty { book.author = author }
            if book.name.isEmpty { book.name = (fileName as NSString).deletingPathExtension }
            book.latestChapterTime = Int64(Date().timeIntervalSince1970 * 1000)
            return LocalBookImport(book: book, chapters: result.chapters)
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
    }

    /// TXT 重新分章（换目录规则、按长度分章，或指定编码重新解码），返回更新后的书籍（进度未调整）
    public func resplit(_ book: Book, tocMode: TxtTocMode, charset: String? = nil,
                        rules: [TxtTocRule] = TxtTocRule.defaults) throws -> LocalBookImport {
        guard isTextBook(book) else { throw LocalBookError.notTextBook }
        var book = book
        if let charset, !charset.isEmpty { book.charset = charset }
        return try buildText(book, tocMode: tocMode, rules: rules)
    }

    private func buildText(_ book: Book, tocMode: TxtTocMode, rules: [TxtTocRule]) throws -> LocalBookImport {
        guard let id = Self.id(of: book) else { throw LocalBookError.fileMissing }
        let source = directory(id).appendingPathComponent("book.txt")
        guard let data = try? Data(contentsOf: source, options: .mappedIfSafe) else { throw LocalBookError.fileMissing }
        guard !data.isEmpty else { throw LocalBookError.emptyFile }
        var book = book
        let charset = book.charset.nilIfEmpty ?? TextEncodingDetector.detect(data)
        let text = TextEncodingDetector.decode(data, charset: charset)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LocalBookError.emptyFile }
        let result = try TxtChapterSplitter.split(text, mode: tocMode, rules: rules,
                                                 splitLongChapter: book.readConfig?.splitLongChapter ?? true)
        guard !result.chapters.isEmpty else { throw LocalBookError.chapterListEmpty }

        let ns = TxtChapterSplitter.nativeString(text)
        var content = Data()
        var chapters: [BookChapter] = []
        chapters.reserveCapacity(result.chapters.count)
        for (index, span) in result.chapters.enumerated() {
            let body = Data(ns.substring(with: NSRange(location: span.range.lowerBound, length: span.range.count)).utf8)
            var chapter = BookChapter(url: Self.chapterURL(book: book, index: index, title: span.title), title: span.title,
                                      bookUrl: book.bookUrl, index: index)
            chapter.isVolume = span.isVolume
            chapter.start = Int64(content.count)
            content.append(body)
            chapter.end = Int64(content.count)
            chapters.append(chapter)
        }
        let dir = directory(id)
        try content.write(to: dir.appendingPathComponent("content.txt"), options: .atomic)
        try saveChapters(chapters, id: id)

        book.charset = charset
        book.tocUrl = result.pattern
        book.totalChapterNum = chapters.count
        book.latestChapterTitle = chapters.last?.title
        book.wordCount = Self.wordCountText(ns.length)
        if let intro = result.intro, book.intro.nilIfEmpty == nil { book.intro = intro }
        return LocalBookImport(book: book, chapters: chapters)
    }

    private func buildEpub(_ book: Book) throws -> LocalBookImport {
        guard let id = Self.id(of: book) else { throw LocalBookError.fileMissing }
        let dir = directory(id)
        let parser = try EpubParser(url: dir.appendingPathComponent("book.epub"))
        let chapters = parser.chapters(bookUrl: book.bookUrl)
        guard !chapters.isEmpty else { throw LocalBookError.chapterListEmpty }
        try saveChapters(chapters, id: id)

        var book = book
        if let title = parser.title { book.name = title }
        if let author = parser.authors.first { book.author = author }
        if let intro = parser.intro { book.intro = intro }
        if let coverPath = parser.coverPath, let cover = try? parser.data(at: coverPath), !cover.isEmpty {
            try cover.write(to: dir.appendingPathComponent(Self.coverName), options: .atomic)
            book.coverUrl = "\(Self.scheme)://\(id)/\(Self.coverName)"
        }
        book.totalChapterNum = chapters.count
        book.latestChapterTitle = chapters.last?.title
        return LocalBookImport(book: book, chapters: chapters)
    }

    /// MOBI、UMD、FB2、DOCX、HTML、Markdown、RTF：整本转换一次，正文按章写入 `content.txt`（与 TXT 相同的偏移读取），插图导出到 `res/`
    private func buildConverted(_ book: Book, format: ConvertedBookFormat, rules: [TxtTocRule]) throws -> LocalBookImport {
        guard let id = Self.id(of: book) else { throw LocalBookError.fileMissing }
        let dir = directory(id)
        let source = dir.appendingPathComponent(Self.fileName(of: book))
        guard FileManager.default.fileExists(atPath: source.path) else { throw LocalBookError.fileMissing }
        let resources = dir.appendingPathComponent(ConversionContext.resourceFolder, isDirectory: true)
        try? FileManager.default.removeItem(at: resources)
        let context = ConversionContext(directory: resources,
                                        urlPrefix: "\(Self.scheme)://\(id)/\(ConversionContext.resourceFolder)/", rules: rules)
        let converted = try format.convert(source, context: context)
        guard !converted.chapters.isEmpty else { throw LocalBookError.chapterListEmpty }

        var content = Data()
        var chapters: [BookChapter] = []
        var words = 0
        for (index, item) in converted.chapters.enumerated() {
            var chapter = BookChapter(url: Self.chapterURL(book: book, index: index, title: item.title), title: item.title,
                                      bookUrl: book.bookUrl, index: index)
            chapter.isVolume = item.isVolume
            chapter.start = Int64(content.count)
            content.append(Data(item.content.utf8))
            chapter.end = Int64(content.count)
            chapters.append(chapter)
            words += item.content.replacingOccurrences(of: #"<img[^>]*>|\s"#, with: "", options: .regularExpression).utf16.count
        }
        try content.write(to: dir.appendingPathComponent("content.txt"), options: .atomic)
        try saveChapters(chapters, id: id)

        var book = book
        let trimmed = { (text: String?) in text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
        if let title = trimmed(converted.title) { book.name = title }
        if let author = converted.authors.lazy.compactMap(trimmed).first { book.author = author }
        if let intro = trimmed(converted.intro) { book.intro = intro }
        if let cover = converted.cover, !cover.isEmpty {
            try cover.write(to: dir.appendingPathComponent(Self.coverName), options: .atomic)
            book.coverUrl = "\(Self.scheme)://\(id)/\(Self.coverName)"
        }
        book.totalChapterNum = chapters.count
        book.latestChapterTitle = chapters.last?.title
        book.wordCount = Self.wordCountText(words)
        return LocalBookImport(book: book, chapters: chapters)
    }

    // MARK: - 读取

    public func isEpub(_ book: Book) -> Bool {
        book.originName.lowercased().hasSuffix(".epub")
    }

    /// 原文件按 TXT 处理（可以重新分章、换编码）
    public func isTextBook(_ book: Book) -> Bool {
        Self.fileName(of: book) == "book.txt"
    }

    /// 文件扩展名（小写），`.fb2.zip` 视为 `fbz`
    public static func fileExtension(_ fileName: String) -> String {
        let lowered = fileName.lowercased()
        if lowered.hasSuffix(".fb2.zip") { return "fbz" }
        return (lowered as NSString).pathExtension
    }

    public static func canImport(_ url: URL) -> Bool {
        supportedExtensions.contains(fileExtension(url.lastPathComponent))
    }

    /// 目录；目录文件丢失时按书籍记录的编码与目录规则重建
    public func chapters(for book: Book) throws -> [BookChapter] {
        guard let id = Self.id(of: book) else { throw LocalBookError.fileMissing }
        let url = directory(id).appendingPathComponent("chapters.json")
        if let data = try? Data(contentsOf: url), let chapters = try? JSONDecoder().decode([BookChapter].self, from: data),
           !chapters.isEmpty {
            return chapters
        }
        if let media = try mediaChapters(for: book) { return media }
        if isEpub(book) { return try buildEpub(book).chapters }
        if let format = ConvertedBookFormat.byExtension[Self.fileExtension(book.originName)] {
            return try buildConverted(book, format: format, rules: TxtTocRule.defaults).chapters
        }
        return try buildText(book, tocMode: book.tocUrl.isEmpty ? .byLength : .pattern(book.tocUrl),
                             rules: TxtTocRule.defaults).chapters
    }

    /// 原始正文（EPUB 已转为纯文本并保留图片标签）
    public func content(for book: Book, chapter: BookChapter) throws -> String {
        guard let id = Self.id(of: book) else { throw LocalBookError.fileMissing }
        let dir = directory(id)
        if isEpub(book) {
            let parser = try EpubParser(url: dir.appendingPathComponent("book.epub"))
            let cover = FileManager.default.fileExists(atPath: dir.appendingPathComponent(Self.coverName).path)
                ? "\(Self.scheme)://\(id)/\(Self.coverName)" : nil
            return try parser.content(of: chapter, coverURL: cover) { path in
                "\(Self.scheme)://\(id)/" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)
            }
        }
        guard let start = chapter.start, let end = chapter.end, end >= start else { return "" }
        guard end > start else { return "" }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: dir.appendingPathComponent("content.txt"))
        } catch {
            throw LocalBookError.fileMissing
        }
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(start))
        let data = try handle.read(upToCount: Int(end - start)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    public static func handles(_ url: String) -> Bool {
        url.hasPrefix(scheme + "://")
    }

    /// 封面或 EPUB 插图
    public func resourceData(_ url: String) throws -> Data {
        guard Self.handles(url) else { throw LocalBookError.fileMissing }
        let rest = url.dropFirst(Self.scheme.count + 3)
        guard let slash = rest.firstIndex(of: "/"), Self.isValidID(rest[..<slash]) else { throw LocalBookError.fileMissing }
        let id = String(rest[..<slash])
        let path = String(rest[rest.index(after: slash)...])
        let decoded = path.removingPercentEncoding ?? path
        let dir = directory(id)
        if decoded == Self.coverName {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(Self.coverName)) else { throw LocalBookError.fileMissing }
            return data
        }
        if let media = try mediaResource(id: id, path: decoded) { return media }
        let resourcePrefix = ConversionContext.resourceFolder + "/"
        if decoded.hasPrefix(resourcePrefix) {
            let name = decoded.dropFirst(resourcePrefix.count)
            guard !name.isEmpty, !name.contains("/"), !name.hasPrefix("."),
                  let data = try? Data(contentsOf: dir.appendingPathComponent(ConversionContext.resourceFolder).appendingPathComponent(String(name)))
            else { throw LocalBookError.fileMissing }
            return data
        }
        let epub = dir.appendingPathComponent("book.epub")
        guard FileManager.default.fileExists(atPath: epub.path) else { throw LocalBookError.fileMissing }
        return try EpubParser(url: epub).data(at: decoded)
    }

    // MARK: - 管理

    public func remove(_ book: Book) {
        guard let id = Self.id(of: book) else { return }
        try? FileManager.default.removeItem(at: directory(id))
    }

    public func exists(_ book: Book) -> Bool {
        guard let id = Self.id(of: book) else { return false }
        return FileManager.default.fileExists(atPath: directory(id).path)
    }

    /// 原文件地址（分享、导出用）
    public func fileURL(for book: Book) -> URL? {
        guard let id = Self.id(of: book) else { return nil }
        let url = directory(id).appendingPathComponent(Self.fileName(of: book))
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 用备份中的书籍目录（原文件与可选的封面）恢复，备份中没有原文件时返回 false。
    /// 已有同样大小的原文件时保留现有目录；否则整体替换，目录与正文在首次打开时按书籍记录重建
    func restore(_ book: Book, from source: URL) throws -> Bool {
        guard let id = Self.id(of: book) else { return false }
        let name = Self.fileName(of: book)
        let file = source.appendingPathComponent(name)
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) else { return false }
        let dir = directory(id)
        let target = dir.appendingPathComponent(name)
        if let size = Self.fileSize(target), size == Self.fileSize(file) { return true }
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.copyItem(at: file, to: target)
        let cover = source.appendingPathComponent(Self.coverName)
        if fm.fileExists(atPath: cover.path) {
            try? fm.copyItem(at: cover, to: dir.appendingPathComponent(Self.coverName))
        }
        return true
    }

    static func fileName(of book: Book) -> String {
        let ext = fileExtension(book.originName)
        return "book." + (supportedExtensions.contains(ext) ? ext : "txt")
    }

    private static func fileSize(_ url: URL) -> Int? {
        try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }

    public func totalSize() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    public static func id(of book: Book) -> String? {
        guard book.isLocal, handles(book.bookUrl) else { return nil }
        let id = book.bookUrl.dropFirst(scheme.count + 3).prefix { $0 != "/" }
        return isValidID(id) ? String(id) : nil
    }

    /// 书籍地址可能来自备份等外部数据，只接受导入时生成的 UUID 字符，防止 `..` 之类的路径越出书籍目录
    static func isValidID(_ id: Substring) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    func directory(_ id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    private func saveChapters(_ chapters: [BookChapter], id: String) throws {
        try JSONEncoder().encode(chapters).write(to: directory(id).appendingPathComponent("chapters.json"), options: .atomic)
    }

    // MARK: - 文件名与字数

    private static let nameAuthorPatterns: [NSRegularExpression] = [
        #"(.*?)《([^《》]+)》.*?作者：(.*)"#,
        #"(.*?)《([^《》]+)》(.*)"#,
        #"(^)(.+) 作者：(.+)$"#,
        #"(^)(.+) by (.+)$"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    /// 从文件名解析书名与作者（Legado LocalBook.analyzeNameAuthor）
    public static func parseFileName(_ fileName: String) -> (name: String, author: String) {
        let base = fileName.contains(".") ? String(fileName[..<fileName.lastIndex(of: ".")!]) : fileName
        let range = NSRange(base.startIndex..., in: base)
        for pattern in nameAuthorPatterns {
            guard let match = pattern.firstMatch(in: base, range: range) else { continue }
            func group(_ i: Int) -> String {
                Range(match.range(at: i), in: base).map { String(base[$0]) } ?? ""
            }
            return (group(2), formatAuthor(group(1) + group(3)))
        }
        let name = base.replacingOccurrences(of: #"\s+作\s*者.*|\s+\S+\s+著"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let author = formatAuthor(name.isEmpty ? base : base.replacingOccurrences(of: name, with: ""))
        return (name, author.utf16.count == base.utf16.count ? "" : author)
    }

    private static func formatAuthor(_ author: String) -> String {
        author.replacingOccurrences(of: #"^\s*作\s*者[:：\s]+|\s+著"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func wordCountText(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        guard count > 10000 else { return "\(count)字" }
        let value = (Double(count) / 10000 * 10).rounded() / 10
        return (value == value.rounded() ? String(Int(value)) : String(value)) + "万字"
    }

    /// 章节标识（Legado：md5Encode16(originName + index + title)）
    static func chapterURL(book: Book, index: Int, title: String) -> String {
        String(Hashing.md5(book.originName + String(index) + title).dropFirst(8).prefix(16))
    }
}
