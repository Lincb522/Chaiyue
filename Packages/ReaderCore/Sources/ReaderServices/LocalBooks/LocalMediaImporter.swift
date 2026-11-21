import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import ReaderModels
import ZIPFoundation

public enum LocalMediaError: LocalizedError, Sendable, Equatable {
    case rarArchive
    case unplayable(String)
    case noAudio
    case noImages
    case invalidArchive
    case invalidPDF
    case lockedPDF

    public var errorDescription: String? {
        switch self {
        case .rarArchive: "暂不支持 CBR/RAR 压缩包，请转换为 CBZ 或 ZIP 后导入"
        case .unplayable(let ext): "系统无法播放 \(ext.uppercased()) 音频，请转换为 MP3 或 M4A 后导入"
        case .noAudio: "没有找到可播放的音频文件"
        case .noImages: "没有找到图片"
        case .invalidArchive: "无法打开压缩包"
        case .invalidPDF: "无法打开 PDF 文件"
        case .lockedPDF: "PDF 已加密，暂不支持"
        }
    }
}

/// 本地有声书与漫画。
/// 有声书（`type` 1）：单个文件存为 `book.<扩展名>`；多个文件按顺序存为 `audio/0001.<扩展名>`…，另写播放列表 `book.m3u` 作为书籍文件。
/// 章节的 `resourceUrl` 为音频相对路径，按章节标记分章时 `start`/`end` 为毫秒区间（最后一章 `end` 为空，播到文件结束）。
/// 漫画（`type` 2）：CBZ/ZIP 的章节 `resourceUrl` 为压缩包内目录，图片地址 `localbook://<id>/cbz/<条目路径>`；
/// PDF 的章节 `start`/`end` 为页码区间（不含 `end`），图片地址 `localbook://<id>/pdf/<页码>`，按需渲染并缓存到 `pages/`
public enum LocalMediaImporter {
    /// ogg/opus 先接收，导入时由系统判断能否播放
    public static let audioExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "wav", "flac", "aiff", "aif", "caf", "ogg", "oga", "opus",
    ]
    public static let comicExtensions: Set<String> = ["cbz", "zip", "pdf"]
    static let rarExtensions: Set<String> = ["cbr", "rar"]
    /// 多文件有声书的书籍文件，不接受直接导入
    static let playlistExtension = "m3u"
    public static let extensions = audioExtensions.union(comicExtensions).union(rarExtensions).union([playlistExtension])
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "bmp", "heic", "heif", "avif"]
    static let coverNames: Set<String> = ["cover", "folder", "front", "封面"]

    /// 没有大纲的 PDF：不超过 `pdfWholeLimit` 页时整本一章，否则每 `pdfChunk` 页一章
    static let pdfChunk = 20
    static let pdfWholeLimit = 30
    /// PDF 页渲染宽度（像素）
    static let pdfRenderWidth: CGFloat = 1440

    public static func handles(_ ext: String) -> Bool {
        extensions.contains(ext.lowercased())
    }

    /// 本地书按原文件扩展名判断形态；不是有声书或漫画时为 nil
    public static func kind(of book: Book) -> BookMediaKind? {
        guard book.isLocal else { return nil }
        let ext = (book.originName as NSString).pathExtension.lowercased()
        if audioExtensions.contains(ext) || ext == playlistExtension { return .audio }
        if comicExtensions.contains(ext) { return .comic }
        return nil
    }

    // MARK: - 排序与命名

    /// 按路径逐级比较，数字按数值（2 在 10 前）
    public static func naturalLess(_ a: String, _ b: String) -> Bool {
        let x = a.split(separator: "/"), y = b.split(separator: "/")
        for (p, q) in zip(x, y) {
            let order = p.compare(q, options: [.numeric, .caseInsensitive, .widthInsensitive])
            if order != .orderedSame { return order == .orderedAscending }
        }
        return x.count < y.count
    }

    /// 多个文件名的公共前缀去掉结尾的序号与分隔符，如「三体 01」「三体 02」得到「三体」
    static func commonName(_ names: [String]) -> String? {
        guard var prefix = names.first, names.count > 1 else { return nil }
        for name in names.dropFirst() {
            prefix = String(zip(prefix, name).prefix { $0 == $1 }.map(\.0))
        }
        let trimmed = prefix.replacingOccurrences(of: #"[\s\d第_\-—.,，、:：()（）\[\]【】#]+$"#, with: "",
                                                  options: .regularExpression)
        return trimmed.count >= 2 ? trimmed : nil
    }

    // MARK: - 章节标记

    struct AudioMarker: Equatable, Sendable {
        var title: String
        /// 秒
        var start: Double
        var end: Double?
    }

    /// 整理章节标记：去掉长度不足半秒的标记，按起点排序，每章到下一章起点为止，最后一章播到文件结束（`end` 为空）；
    /// 不足两章时返回空
    static func markerChapters(_ raw: [AudioMarker], duration: Double) -> [AudioMarker] {
        let total = duration.isFinite && duration > 0 ? duration : .infinity
        let sorted = raw.filter { marker in
            guard marker.start.isFinite, marker.start >= 0, marker.start < total - 0.5 else { return false }
            guard let end = marker.end, end.isFinite else { return true }
            return end - marker.start >= 0.5
        }.sorted { $0.start < $1.start }
        var kept: [AudioMarker] = []
        for marker in sorted where kept.last.map({ marker.start - $0.start >= 0.5 }) ?? true {
            kept.append(marker)
        }
        guard kept.count >= 2 else { return [] }
        return kept.enumerated().map { i, marker in
            let title = marker.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return AudioMarker(title: title.isEmpty ? "第 \(i + 1) 章" : title, start: marker.start,
                               end: i + 1 < kept.count ? kept[i + 1].start : nil)
        }
    }

    // MARK: - 图片

    static func isImage(_ path: String) -> Bool {
        imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    static func isHidden(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0.hasPrefix(".") || $0 == "__MACOSX" }
    }

    static func jpeg(_ image: CGImage, quality: Double = 0.85) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// 封面缩到 `maxPixel` 以内并转 JPEG；解不开时原样返回
    static func coverData(_ data: Data, maxPixel: Int = 900) -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel,
              ] as CFDictionary),
              let jpeg = jpeg(image) else { return data }
        return jpeg
    }

    /// 渲染 PDF 一页（`index` 从 0 开始）为 JPEG：按宽度缩放，总像素不超过 800 万，考虑页面旋转
    static func renderPDFPage(_ url: URL, index: Int, width: CGFloat) -> Data? {
        guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: index + 1) else { return nil }
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let angle = (Int(page.rotationAngle) % 360 + 360) % 360
        let size = angle % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
        var scale = min(4, width / size.width)
        let maxPixels: CGFloat = 8_000_000
        if size.width * size.height * scale * scale > maxPixels { scale = (maxPixels / (size.width * size.height)).squareRoot() }
        let pixelWidth = max(1, Int((size.width * scale).rounded())), pixelHeight = max(1, Int((size.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        // PDF 的 /Rotate 为顺时针角度
        switch angle {
        case 90:
            context.translateBy(x: 0, y: size.height)
            context.rotate(by: -.pi / 2)
        case 180:
            context.translateBy(x: size.width, y: size.height)
            context.rotate(by: .pi)
        case 270:
            context.translateBy(x: size.width, y: 0)
            context.rotate(by: .pi / 2)
        default:
            break
        }
        context.translateBy(x: -box.minX, y: -box.minY)
        context.clip(to: box)
        context.drawPDFPage(page)
        return context.makeImage().flatMap { jpeg($0) }
    }
}

// MARK: - 导入

extension LocalBookStore {
    /// 有声书（单个或多个音频、文件夹）或漫画（CBZ/ZIP、PDF）：复制文件、按文件分章后，读取音频的章节标记与元数据（书名、作者、封面）
    public func importMedia(from urls: [URL], name: String? = nil, author: String? = nil) async throws -> LocalBookImport {
        var result = try importMediaFiles(from: urls, name: name, author: author)
        guard result.book.type == BookSourceType.audio.rawValue, let id = Self.id(of: result.book) else { return result }
        do {
            result = try await refineAudio(result, id: id)
            Self.applyNames(&result.book, name: name, author: author)
            try saveMediaChapters(result.chapters, id: id)
            return result
        } catch {
            try? FileManager.default.removeItem(at: directory(id))
            throw error
        }
    }

    /// 同步部分：复制文件并生成目录。有声书只按文件分章，章节标记与元数据由 `importMedia(from:)` 读取
    func importMediaFiles(from urls: [URL], name: String? = nil, author: String? = nil) throws -> LocalBookImport {
        guard let first = urls.first else { throw LocalMediaError.noAudio }
        let ext = first.pathExtension.lowercased()
        let single = urls.count == 1 && !Self.isDirectory(first)
        if single, LocalMediaImporter.rarExtensions.contains(ext) { throw LocalMediaError.rarArchive }
        if single, ext == LocalMediaImporter.playlistExtension { throw LocalBookError.unsupportedFormat(ext) }
        let comic = single && LocalMediaImporter.comicExtensions.contains(ext)
        let audio = comic ? [] : Self.audioFiles(in: urls)
        guard comic || !audio.isEmpty else { throw LocalMediaError.noAudio }

        let id = UUID().uuidString.lowercased()
        let dir = directory(id)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            var book = Book(bookUrl: "\(Self.scheme)://\(id)", origin: Book.localOrigin)
            book.canUpdate = false
            var result = comic ? try buildComic(first, book: book, dir: dir)
                : try buildAudio(audio, folder: urls.count == 1 && !single ? first : nil, book: book, dir: dir)
            Self.applyNames(&result.book, name: name, author: author)
            book = result.book
            book.totalChapterNum = result.chapters.count
            book.latestChapterTitle = result.chapters.last?.title
            book.latestChapterTime = Int64(Date().timeIntervalSince1970 * 1000)
            result.book = book
            try saveMediaChapters(result.chapters, id: id)
            return result
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
    }

    static func applyNames(_ book: inout Book, name: String?, author: String?) {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { book.name = name }
        if let author = author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty { book.author = author }
        if book.name.isEmpty { book.name = (book.originName as NSString).deletingPathExtension }
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// 选中的音频与文件夹里（含子目录）的音频，按相对路径自然排序
    static func audioFiles(in urls: [URL]) -> [URL] {
        var files: [(url: URL, key: String)] = []
        for url in urls {
            if isDirectory(url) {
                let base = url.resolvingSymlinksInPath().path
                guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                for case let file as URL in enumerator where isAudio(file) {
                    let path = file.resolvingSymlinksInPath().path
                    files.append((file, path.hasPrefix(base) ? String(path.dropFirst(base.count)) : file.lastPathComponent))
                }
            } else if isAudio(url) {
                files.append((url, url.lastPathComponent))
            }
        }
        return files.sorted { LocalMediaImporter.naturalLess($0.key, $1.key) }.map(\.url)
    }

    private static func isAudio(_ url: URL) -> Bool {
        LocalMediaImporter.audioExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: 有声书

    private func buildAudio(_ files: [URL], folder: URL?, book: Book, dir: URL) throws -> LocalBookImport {
        let fm = FileManager.default
        var book = book
        book.type = BookSourceType.audio.rawValue
        var paths: [String] = []
        if files.count == 1 && folder == nil {
            let path = "book." + files[0].pathExtension.lowercased()
            try fm.copyItem(at: files[0], to: dir.appendingPathComponent(path))
            paths = [path]
            book.originName = files[0].lastPathComponent
            let parsed = Self.parseFileName(book.originName)
            book.name = parsed.name
            book.author = parsed.author
        } else {
            try fm.createDirectory(at: dir.appendingPathComponent("audio"), withIntermediateDirectories: true)
            for (index, file) in files.enumerated() {
                let path = String(format: "audio/%04d.", index + 1) + file.pathExtension.lowercased()
                try fm.copyItem(at: file, to: dir.appendingPathComponent(path))
                paths.append(path)
            }
            let bases = files.map { $0.deletingPathExtension().lastPathComponent }
            let title = folder?.lastPathComponent ?? LocalMediaImporter.commonName(bases) ?? bases[0]
            let parsed = Self.parseFileName(title + "." + LocalMediaImporter.playlistExtension)
            book.name = parsed.name
            book.author = parsed.author
            book.originName = title + "." + LocalMediaImporter.playlistExtension
            if let folder, let cover = Self.folderCover(folder), let data = try? Data(contentsOf: cover) {
                try LocalMediaImporter.coverData(data).write(to: dir.appendingPathComponent(Self.coverName), options: .atomic)
                book.coverUrl = "\(book.bookUrl)/\(Self.coverName)"
            }
        }
        let titles = files.map { $0.deletingPathExtension().lastPathComponent }
        let chapters = Self.audioChapters(book: book, titles: titles, paths: paths)
        if paths.count > 1 { try Self.writePlaylist(titles: titles, paths: paths, to: dir) }
        return LocalBookImport(book: book, chapters: chapters)
    }

    private static func audioChapters(book: Book, titles: [String], paths: [String]) -> [BookChapter] {
        zip(titles, paths).enumerated().map { index, item in
            var chapter = BookChapter(url: chapterURL(book: book, index: index, title: item.0), title: item.0,
                                      bookUrl: book.bookUrl, index: index)
            chapter.resourceUrl = item.1
            return chapter
        }
    }

    private static func writePlaylist(titles: [String], paths: [String], to dir: URL) throws {
        let lines = zip(titles, paths).map { "#EXTINF:-1,\($0)\n\($1)" }
        try ("#EXTM3U\n" + lines.joined(separator: "\n") + "\n").write(
            to: dir.appendingPathComponent("book." + LocalMediaImporter.playlistExtension), atomically: true, encoding: .utf8)
    }

    private static func readPlaylist(_ url: URL) -> (titles: [String], paths: [String]) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return ([], []) }
        var titles: [String] = [], paths: [String] = []
        var pending: String?
        for line in text.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.isEmpty {
            if line.hasPrefix("#EXTINF:") {
                pending = line.firstIndex(of: ",").map { String(line[line.index(after: $0)...]) }
            } else if !line.hasPrefix("#"), !line.contains("..") {
                paths.append(line)
                titles.append(pending ?? (line as NSString).deletingPathExtension)
                pending = nil
            }
        }
        return (titles, paths)
    }

    private static func folderCover(_ folder: URL) -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                  options: .skipsHiddenFiles)) ?? []
        let images = items.filter { LocalMediaImporter.isImage($0.lastPathComponent) }
        return images.first { LocalMediaImporter.coverNames.contains($0.deletingPathExtension().lastPathComponent.lowercased()) }
            ?? (images.count == 1 ? images[0] : nil)
    }

    /// 读取各音频的元数据：校验能否播放，单文件按章节标记分章，多文件在标题互不相同时用标题作章名
    private func refineAudio(_ result: LocalBookImport, id: String) async throws -> LocalBookImport {
        let dir = directory(id)
        let paths = result.chapters.compactMap(\.resourceUrl)
        var infos: [AudioInfo] = []
        for path in paths {
            infos.append(try await Self.audioInfo(dir.appendingPathComponent(path)))
        }
        guard let first = infos.first else { throw LocalMediaError.noAudio }
        var book = result.book
        var chapters = result.chapters
        if let name = paths.count == 1 ? first.album ?? first.title : first.album { book.name = name }
        if let artist = first.artist { book.author = artist }
        if let intro = first.intro { book.intro = intro }
        if paths.count == 1 {
            let markers = LocalMediaImporter.markerChapters(first.markers, duration: first.duration)
            if !markers.isEmpty {
                chapters = markers.enumerated().map { index, marker in
                    var chapter = BookChapter(url: Self.chapterURL(book: book, index: index, title: marker.title),
                                              title: marker.title, bookUrl: book.bookUrl, index: index)
                    chapter.resourceUrl = paths[0]
                    chapter.start = Int64((marker.start * 1000).rounded())
                    chapter.end = marker.end.map { Int64(($0 * 1000).rounded()) }
                    return chapter
                }
            }
        } else {
            let titles = infos.compactMap(\.title)
            if titles.count == infos.count, Set(titles).count == titles.count {
                chapters = Self.audioChapters(book: book, titles: titles, paths: paths)
                try Self.writePlaylist(titles: titles, paths: paths, to: dir)
            }
        }
        if let artwork = infos.lazy.compactMap(\.artwork).first {
            try LocalMediaImporter.coverData(artwork).write(to: dir.appendingPathComponent(Self.coverName), options: .atomic)
            book.coverUrl = "\(Self.scheme)://\(id)/\(Self.coverName)"
        }
        book.totalChapterNum = chapters.count
        book.latestChapterTitle = chapters.last?.title
        return LocalBookImport(book: book, chapters: chapters)
    }

    struct AudioInfo: Sendable {
        var duration: Double
        var title: String?
        var album: String?
        var artist: String?
        var intro: String?
        var artwork: Data?
        var markers: [LocalMediaImporter.AudioMarker] = []
    }

    static func audioInfo(_ url: URL) async throws -> AudioInfo {
        let ext = url.pathExtension.lowercased()
        let asset = AVURLAsset(url: url)
        let playable: Bool, duration: CMTime, metadata: [AVMetadataItem]
        do {
            (playable, duration, metadata) = try await asset.load(.isPlayable, .duration, .commonMetadata)
        } catch {
            throw LocalMediaError.unplayable(ext)
        }
        guard playable else { throw LocalMediaError.unplayable(ext) }
        func string(_ identifier: AVMetadataIdentifier, in items: [AVMetadataItem]) async -> String? {
            guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier).first,
                  let value = try? await item.load(.stringValue) else { return nil }
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        var info = AudioInfo(duration: duration.seconds)
        info.title = await string(.commonIdentifierTitle, in: metadata)
        info.album = await string(.commonIdentifierAlbumName, in: metadata)
        var artist = await string(.commonIdentifierArtist, in: metadata)
        if artist == nil { artist = await string(.commonIdentifierAuthor, in: metadata) }
        if artist == nil { artist = await string(.commonIdentifierCreator, in: metadata) }
        info.artist = artist
        info.intro = await string(.commonIdentifierDescription, in: metadata)
        if let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork).first,
           let data = try? await item.load(.dataValue), !data.isEmpty {
            info.artwork = data
        }
        let locales = (try? await asset.load(.availableChapterLocales)) ?? []
        let preferred = Locale.preferredLanguages.compactMap { Locale(identifier: $0).language.languageCode }
        if let locale = locales.first(where: { $0.language.languageCode.map(preferred.contains) ?? false }) ?? locales.first,
           let groups = try? await asset.loadChapterMetadataGroups(withTitleLocale: locale, containingItemsWithCommonKeys: []) {
            for group in groups {
                let title = await string(.commonIdentifierTitle, in: group.items) ?? ""
                info.markers.append(.init(title: title, start: group.timeRange.start.seconds, end: group.timeRange.end.seconds))
            }
        }
        return info
    }

    // MARK: 漫画

    private func buildComic(_ url: URL, book: Book, dir: URL) throws -> LocalBookImport {
        let ext = url.pathExtension.lowercased()
        let target = dir.appendingPathComponent("book." + ext)
        try FileManager.default.copyItem(at: url, to: target)
        var book = book
        book.type = BookSourceType.image.rawValue
        book.originName = url.lastPathComponent
        let parsed = Self.parseFileName(book.originName)
        book.name = parsed.name
        book.author = parsed.author
        let chapters: [BookChapter]
        var cover: Data?
        if ext == "pdf" {
            guard let document = PDFDocument(url: target), document.pageCount > 0 else { throw LocalMediaError.invalidPDF }
            guard !document.isLocked else { throw LocalMediaError.lockedPDF }
            let attributes = document.documentAttributes ?? [:]
            if let title = (attributes[PDFDocumentAttribute.titleAttribute] as? String)?.trimmingCharacters(in: .whitespaces),
               !title.isEmpty { book.name = title }
            if let author = (attributes[PDFDocumentAttribute.authorAttribute] as? String)?.trimmingCharacters(in: .whitespaces),
               !author.isEmpty { book.author = author }
            chapters = Self.pdfChapters(document, book: book)
            cover = LocalMediaImporter.renderPDFPage(target, index: 0, width: 600)
        } else {
            let result = try Self.archiveChapters(target, book: book)
            chapters = result.chapters
            cover = result.cover
        }
        guard !chapters.isEmpty else { throw LocalMediaError.noImages }
        if let cover {
            try LocalMediaImporter.coverData(cover).write(to: dir.appendingPathComponent(Self.coverName), options: .atomic)
            book.coverUrl = "\(book.bookUrl)/\(Self.coverName)"
        }
        return LocalBookImport(book: book, chapters: chapters)
    }

    private static func openArchive(_ url: URL) throws -> Archive {
        guard FileManager.default.fileExists(atPath: url.path) else { throw LocalBookError.fileMissing }
        do {
            return try Archive(url: url, accessMode: .read)
        } catch {
            throw LocalMediaError.invalidArchive
        }
    }

    private static func archiveImages(_ archive: Archive) -> [String] {
        archive.compactMap { entry in
            entry.type == .file && LocalMediaImporter.isImage(entry.path) && !LocalMediaImporter.isHidden(entry.path)
                ? entry.path : nil
        }
    }

    private static func parent(_ path: String) -> String {
        path.lastIndex(of: "/").map { String(path[..<$0]) } ?? ""
    }

    /// 按图片所在目录分章；只有一个目录时整本一章。返回首张图作封面
    static func archiveChapters(_ url: URL, book: Book) throws -> (chapters: [BookChapter], cover: Data?) {
        let archive = try openArchive(url)
        let groups = Dictionary(grouping: archiveImages(archive), by: parent)
        guard !groups.isEmpty else { throw LocalMediaError.noImages }
        let dirs = groups.keys.sorted(by: LocalMediaImporter.naturalLess)
        let chapters = dirs.enumerated().map { index, dir in
            let title = dirs.count == 1 ? "全本" : dir.isEmpty ? "封面" : (dir as NSString).lastPathComponent
            var chapter = BookChapter(url: chapterURL(book: book, index: index, title: title), title: title,
                                      bookUrl: book.bookUrl, index: index)
            chapter.resourceUrl = dir
            return chapter
        }
        var cover: Data?
        if let path = groups[dirs[0]]?.min(by: LocalMediaImporter.naturalLess), let entry = archive[path] {
            var data = Data()
            _ = try? archive.extract(entry, skipCRC32: true) { data.append($0) }
            cover = data.isEmpty ? nil : data
        }
        return (chapters, cover)
    }

    /// 按大纲分章（顶层只有一项时取其下一级）；没有大纲时按页数切分
    static func pdfChapters(_ document: PDFDocument, book: Book) -> [BookChapter] {
        let count = document.pageCount
        var starts: [(title: String, page: Int)] = []
        if var level = document.outlineRoot.map(children) {
            while level.count == 1, level[0].numberOfChildren > 0 { level = children(level[0]) }
            for item in level {
                guard let page = item.destination?.page ?? (item.action as? PDFActionGoTo)?.destination.page else { continue }
                let index = document.index(for: page)
                guard index >= 0, index < count, !starts.contains(where: { $0.page == index }) else { continue }
                starts.append(((item.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines), index))
            }
            starts.sort { $0.page < $1.page }
            if let first = starts.first, first.page > 0 { starts.insert(("开篇", 0), at: 0) }
        }
        var spans: [(title: String, range: Range<Int>)] = []
        if starts.isEmpty {
            let chunk = count <= LocalMediaImporter.pdfWholeLimit ? count : LocalMediaImporter.pdfChunk
            for start in stride(from: 0, to: count, by: chunk) {
                let end = min(count, start + chunk)
                spans.append((chunk == count ? "全本" : "第 \(start + 1)–\(end) 页", start..<end))
            }
        } else {
            for (i, item) in starts.enumerated() {
                let end = i + 1 < starts.count ? starts[i + 1].page : count
                spans.append((item.title.isEmpty ? "第 \(i + 1) 章" : item.title, item.page..<end))
            }
        }
        return spans.enumerated().map { index, span in
            var chapter = BookChapter(url: chapterURL(book: book, index: index, title: span.title), title: span.title,
                                      bookUrl: book.bookUrl, index: index)
            chapter.start = Int64(span.range.lowerBound)
            chapter.end = Int64(span.range.upperBound)
            return chapter
        }
    }

    private static func children(_ outline: PDFOutline) -> [PDFOutline] {
        (0..<outline.numberOfChildren).compactMap { outline.child(at: $0) }
    }

    // MARK: - 读取

    /// 目录文件丢失时重建（恢复备份后首次打开）；不是有声书或漫画时为 nil
    func mediaChapters(for book: Book) throws -> [BookChapter]? {
        guard let kind = LocalMediaImporter.kind(of: book), let id = Self.id(of: book) else { return nil }
        let dir = directory(id)
        let file = dir.appendingPathComponent(Self.fileName(of: book))
        guard FileManager.default.fileExists(atPath: file.path) else { throw LocalBookError.fileMissing }
        let chapters: [BookChapter]
        switch (kind, file.pathExtension) {
        case (.audio, LocalMediaImporter.playlistExtension):
            let list = Self.readPlaylist(file)
            chapters = Self.audioChapters(book: book, titles: list.titles, paths: list.paths)
        case (.audio, _):
            chapters = Self.audioChapters(book: book, titles: [(book.originName as NSString).deletingPathExtension],
                                          paths: [file.lastPathComponent])
        case (_, "pdf"):
            guard let document = PDFDocument(url: file) else { throw LocalMediaError.invalidPDF }
            chapters = Self.pdfChapters(document, book: book)
        default:
            chapters = try Self.archiveChapters(file, book: book).chapters
        }
        guard !chapters.isEmpty else { throw LocalBookError.chapterListEmpty }
        try saveMediaChapters(chapters, id: id)
        return chapters
    }

    private func saveMediaChapters(_ chapters: [BookChapter], id: String) throws {
        try JSONEncoder().encode(chapters).write(to: directory(id).appendingPathComponent("chapters.json"), options: .atomic)
    }

    /// 有声书一章的本地文件与章内区间
    public func mediaPlayback(for book: Book, chapter: BookChapter) throws -> MediaPlayback {
        guard let id = Self.id(of: book), let path = chapter.resourceUrl, !path.isEmpty, !path.contains("..") else {
            throw LocalBookError.fileMissing
        }
        let url = directory(id).appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw LocalBookError.fileMissing }
        return MediaPlayback(url: url, headers: [:], start: Double(chapter.start ?? 0) / 1000,
                             end: chapter.end.map { Double($0) / 1000 })
    }

    /// 漫画一章的图片地址
    public func mediaImages(for book: Book, chapter: BookChapter) throws -> [String] {
        guard let id = Self.id(of: book) else { throw LocalBookError.fileMissing }
        let base = "\(Self.scheme)://\(id)/"
        let file = directory(id).appendingPathComponent(Self.fileName(of: book))
        if file.pathExtension == "pdf" {
            guard let start = chapter.start, let end = chapter.end, end > start else { throw LocalMediaError.noImages }
            return (Int(start)..<Int(end)).map { base + "pdf/\($0)" }
        }
        let archive = try Self.openArchive(file)
        let dir = chapter.resourceUrl ?? ""
        let paths = Self.archiveImages(archive).filter { Self.parent($0) == dir }.sorted(by: LocalMediaImporter.naturalLess)
        guard !paths.isEmpty else { throw LocalMediaError.noImages }
        return paths.map { base + "cbz/" + ($0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0) }
    }

    /// 漫画图片：`cbz/<条目路径>` 从压缩包读取，`pdf/<页码>` 渲染后缓存到 `pages/`。不是这两类地址时为 nil
    func mediaResource(id: String, path: String) throws -> Data? {
        let dir = directory(id)
        if path.hasPrefix("pdf/"), let page = Int(path.dropFirst(4)), page >= 0 {
            let pdf = dir.appendingPathComponent("book.pdf")
            guard FileManager.default.fileExists(atPath: pdf.path) else { return nil }
            let cache = dir.appendingPathComponent("pages", isDirectory: true)
            let cached = cache.appendingPathComponent("\(page).jpg")
            if let data = try? Data(contentsOf: cached), !data.isEmpty { return data }
            guard let data = LocalMediaImporter.renderPDFPage(pdf, index: page, width: LocalMediaImporter.pdfRenderWidth) else {
                throw LocalMediaError.invalidPDF
            }
            try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try? data.write(to: cached, options: .atomic)
            return data
        }
        if path.hasPrefix("cbz/") {
            let fm = FileManager.default
            guard let file = ["cbz", "zip"].map({ dir.appendingPathComponent("book." + $0) })
                .first(where: { fm.fileExists(atPath: $0.path) }) else { return nil }
            let archive = try Self.openArchive(file)
            guard let entry = archive[String(path.dropFirst(4))] else { throw LocalBookError.fileMissing }
            var data = Data()
            _ = try archive.extract(entry, skipCRC32: true) { data.append($0) }
            return data
        }
        return nil
    }
}

extension LibraryServices {
    /// 导入有声书（单个或多个音频、文件夹）或漫画（CBZ/ZIP、PDF）并加入书架
    @discardableResult
    public func importLocalMedia(_ urls: [URL], name: String? = nil, author: String? = nil) async throws -> Book {
        let store = localBooks
        let result = try await Task.detached(priority: .userInitiated) {
            try await store.importMedia(from: urls, name: name, author: author)
        }.value
        shelf.add(result.book)
        return shelf.book(result.book.bookUrl) ?? result.book
    }
}
