import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import ReaderModels
@testable import ReaderServices
import RuleEngine
import Testing
import ZIPFoundation

// MARK: - 样本

/// 写一段静音（`ext` 决定格式：wav 为 PCM，m4a 为 AAC）
private func writeTone(_ url: URL, seconds: Double = 1) throws {
    let settings: [String: Any] = url.pathExtension == "m4a"
        ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 22050, AVNumberOfChannelsKey: 1]
        : [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 8000, AVNumberOfChannelsKey: 1,
           AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    let format = file.processingFormat
    let frames = AVAudioFrameCount(format.sampleRate * seconds)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    try file.write(from: buffer)
}

private func png(_ width: Int = 8, _ height: Int = 12) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 0.4, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

private func writeZip(_ url: URL, _ files: [(String, Data)]) throws {
    let archive = try Archive(url: url, accessMode: .create)
    for (path, data) in files {
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, size in
            data.subdata(in: Int(position)..<Int(position) + size)
        }
    }
}

/// 每页 200×300 点；`outline` 为（标题，页码）
private func writePDF(_ url: URL, pages: Int, outline: [(String, Int)] = [], rotate: Int = 0) throws {
    let raw = url.deletingPathExtension().appendingPathExtension("raw.pdf")
    var box = CGRect(x: 0, y: 0, width: 200, height: 300)
    let context = CGContext(raw as CFURL, mediaBox: &box, nil)!
    for _ in 0..<pages {
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 20, y: 20, width: 60, height: 60))
        context.endPDFPage()
    }
    context.closePDF()
    let document = try #require(PDFDocument(url: raw))
    if !outline.isEmpty {
        let root = PDFOutline()
        for (index, (title, page)) in outline.enumerated() {
            let item = PDFOutline()
            item.label = title
            item.destination = PDFDestination(page: document.page(at: page)!, at: .zero)
            root.insertChild(item, at: index)
        }
        document.outlineRoot = root
    }
    if rotate != 0 {
        for index in 0..<document.pageCount { document.page(at: index)?.rotation = rotate }
    }
    #expect(document.write(to: url))
}

private func pixelSize(_ data: Data) -> [Int]? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
    return [width, height]
}

/// 记录所有请求：本地媒体不应发出任何请求
private final class OfflineTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [String] = []
    var requests: [String] { lock.withLock { urls } }

    func send(_ request: HTTPRequest) throws -> HTTPResponse {
        lock.withLock { urls.append(request.url) }
        return HTTPResponse(url: request.url, statusCode: 404, body: Data())
    }
}

// MARK: - 排序与分章

@Suite struct LocalMediaLogicTests {
    @Test func naturalOrder() {
        let less = LocalMediaImporter.naturalLess
        #expect(["10.mp3", "2.mp3", "1.mp3"].sorted(by: less) == ["1.mp3", "2.mp3", "10.mp3"])
        #expect(["第11集.mp3", "第2集.mp3", "第1集.mp3"].sorted(by: less) == ["第1集.mp3", "第2集.mp3", "第11集.mp3"])
        #expect(["a/10/1.png", "a/2/10.png", "a/2/9.png"].sorted(by: less) == ["a/2/9.png", "a/2/10.png", "a/10/1.png"])
        #expect(["B.mp3", "a.mp3"].sorted(by: less) == ["a.mp3", "B.mp3"])
    }

    @Test func commonName() {
        #expect(LocalMediaImporter.commonName(["三体 01", "三体 02", "三体 10"]) == "三体")
        #expect(LocalMediaImporter.commonName(["凡人修仙传-第001集", "凡人修仙传-第002集"]) == "凡人修仙传")
        #expect(LocalMediaImporter.commonName(["01", "02"]) == nil)
        #expect(LocalMediaImporter.commonName(["独一份"]) == nil)
    }

    @Test func markerChapters() {
        typealias Marker = LocalMediaImporter.AudioMarker
        let chapters = LocalMediaImporter.markerChapters([
            Marker(title: "第二章", start: 60, end: 120),
            Marker(title: "第一章", start: 0, end: 60),
            Marker(title: "  ", start: 120, end: 180),
            Marker(title: "空", start: 120.2, end: 120.2),
        ], duration: 180)
        #expect(chapters.map(\.title) == ["第一章", "第二章", "第 3 章"])
        #expect(chapters.map(\.start) == [0, 60, 120])
        // 每章到下一章起点；最后一章播到文件结束
        #expect(chapters.map(\.end) == [60, 120, nil])
        #expect(LocalMediaImporter.markerChapters([Marker(title: "唯一", start: 0, end: 180)], duration: 180).isEmpty)
        // 时长未知时最后一章同样播到结束
        #expect(LocalMediaImporter.markerChapters([Marker(title: "a", start: 0, end: nil), Marker(title: "b", start: 5, end: nil)],
                                                  duration: .nan).map(\.end) == [5, nil])
    }

    @Test func localMediaKind() {
        var book = Book(bookUrl: "localbook://x", origin: Book.localOrigin)
        #expect(book.mediaKind() == .text)
        book.type = 1
        #expect(book.mediaKind() == .audio)
        book.type = 2
        #expect(book.mediaKind() == .comic)
        book.type = 3
        #expect(book.mediaKind() == .text)
    }

    @Test func extensionsMerged() {
        for ext in ["txt", "epub", "mp3", "m4b", "flac", "cbz", "zip", "pdf"] {
            #expect(LocalBookStore.supportedExtensions.contains(ext))
        }
    }
}

// MARK: - 有声书

@Suite struct LocalAudioBookTests {
    @Test func folderBecomesOneBook() async throws {
        let folder = tempDirectory().appendingPathComponent("我的有声书", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["10 尾声.wav", "2 中段.wav", "1 开始.wav"] {
            try writeTone(folder.appendingPathComponent(name))
        }
        try png().write(to: folder.appendingPathComponent("cover.png"))
        try Data("忽略".utf8).write(to: folder.appendingPathComponent("说明.txt"))

        let store = LocalBookStore(root: tempDirectory())
        let result = try await store.importMedia(from: [folder])
        let book = result.book
        #expect(book.type == BookSourceType.audio.rawValue)
        #expect(book.mediaKind() == .audio)
        #expect(book.name == "我的有声书")
        #expect(book.originName == "我的有声书.m3u")
        #expect(book.coverUrl == book.bookUrl + "/cover")
        #expect(result.chapters.map(\.title) == ["1 开始", "2 中段", "10 尾声"])
        #expect(book.totalChapterNum == 3)

        let playback = try store.mediaPlayback(for: book, chapter: result.chapters[2])
        #expect(playback.url.isFileURL)
        #expect(FileManager.default.fileExists(atPath: playback.url.path))
        #expect(playback.headers.isEmpty)
        #expect(playback.start == 0 && playback.end == nil)
        // 播放列表作为书籍文件，备份与恢复时据此判断原文件是否存在
        #expect(store.fileURL(for: book)?.lastPathComponent == "book.m3u")

        let id = try #require(LocalBookStore.id(of: book))
        try FileManager.default.removeItem(at: store.directory(id).appendingPathComponent("chapters.json"))
        let rebuilt = try store.chapters(for: book)
        #expect(rebuilt.map(\.title) == result.chapters.map(\.title))
        #expect(rebuilt.map(\.resourceUrl) == result.chapters.map(\.resourceUrl))
    }

    @Test func multipleFilesUseCommonName() async throws {
        let dir = tempDirectory()
        let files = ["三体 10.wav", "三体 02.wav", "三体 01.wav"].map { dir.appendingPathComponent($0) }
        for file in files { try writeTone(file, seconds: 0.5) }
        let store = LocalBookStore(root: tempDirectory())
        let result = try await store.importMedia(from: files)
        #expect(result.book.name == "三体")
        #expect(result.chapters.map(\.title) == ["三体 01", "三体 02", "三体 10"])
        #expect(result.chapters.map(\.resourceUrl) == ["audio/0001.wav", "audio/0002.wav", "audio/0003.wav"])
    }

    @Test func singleFileWithoutMarkersIsOneChapter() async throws {
        let url = tempDirectory().appendingPathComponent("测试书 作者：某人.m4a")
        try writeTone(url, seconds: 2)
        let store = LocalBookStore(root: tempDirectory())
        let result = try await store.importMedia(from: [url])
        #expect(result.book.name == "测试书")
        #expect(result.book.author == "某人")
        #expect(result.chapters.count == 1)
        #expect(result.chapters[0].resourceUrl == "book.m4a")
        #expect(result.chapters[0].start == nil && result.chapters[0].end == nil)

        // 按章节标记分章时只播章内区间（毫秒存储，秒给播放器）
        var chapter = result.chapters[0]
        chapter.start = 1500
        chapter.end = 3000
        let playback = try store.mediaPlayback(for: result.book, chapter: chapter)
        #expect(playback.start == 1.5 && playback.end == 3)
    }

    @Test func rejectsUnsupported() throws {
        let store = LocalBookStore(root: tempDirectory())
        let cbr = tempDirectory().appendingPathComponent("a.cbr")
        try Data("Rar!".utf8).write(to: cbr)
        #expect(throws: LocalMediaError.rarArchive) { try store.importBook(from: cbr) }
        let m3u = tempDirectory().appendingPathComponent("a.m3u")
        try Data("#EXTM3U".utf8).write(to: m3u)
        #expect(throws: LocalBookError.unsupportedFormat("m3u")) { try store.importBook(from: m3u) }
        #expect(throws: LocalMediaError.noAudio) { try store.importMediaFiles(from: [tempDirectory()]) }
        // 导入失败不留下书籍目录
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: store.root.path)) ?? []).isEmpty)
    }

    @Test func unplayableAudioIsReported() async throws {
        let url = tempDirectory().appendingPathComponent("坏文件.ogg")
        try Data("not audio".utf8).write(to: url)
        let store = LocalBookStore(root: tempDirectory())
        await #expect(throws: LocalMediaError.unplayable("ogg")) { try await store.importMedia(from: [url]) }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: store.root.path)) ?? []).isEmpty)
    }

    @MainActor @Test func sessionPlaysLocalFileWithoutNetwork() async throws {
        let transport = OfflineTransport()
        let services = LibraryServices(dataDirectory: tempDirectory(), cacheDirectory: tempDirectory(), http: transport)
        let url = tempDirectory().appendingPathComponent("单本.wav")
        try writeTone(url)
        let book = try await services.importLocalMedia([url])
        #expect(services.shelf.contains(book.bookUrl))
        let session = services.mediaSession(for: book)
        #expect(session.kind == .audio)
        await session.open()
        #expect(session.tocState == .ready)
        let playback = try await session.playback(at: 0)
        #expect(playback.url.isFileURL && playback.headers.isEmpty)
        session.update(index: 0, position: 400, length: 1000)
        #expect(services.shelf.book(book.bookUrl)?.durChapterPos == 400)
        #expect(transport.requests.isEmpty)
    }
}

// MARK: - 漫画

@Suite struct LocalComicTests {
    @Test func cbzChaptersByFolder() throws {
        let url = tempDirectory().appendingPathComponent("海贼.cbz")
        let image = png()
        try writeZip(url, [
            ("海贼/第10话/10.png", image),
            ("海贼/第10话/2.png", png(4, 4)),
            ("海贼/第2话/1.png", image),
            ("__MACOSX/海贼/第2话/._1.png", Data("x".utf8)),
            ("海贼/说明.txt", Data("x".utf8)),
        ])
        let store = LocalBookStore(root: tempDirectory())
        let result = try store.importBook(from: url)
        let book = result.book
        #expect(book.type == BookSourceType.image.rawValue)
        #expect(book.mediaKind() == .comic)
        #expect(book.name == "海贼")
        #expect(book.coverUrl != nil)
        #expect(result.chapters.map(\.title) == ["第2话", "第10话"])

        let images = try store.mediaImages(for: book, chapter: result.chapters[1])
        #expect(images.map { $0.removingPercentEncoding ?? $0 }
            == ["2.png", "10.png"].map { "\(book.bookUrl)/cbz/海贼/第10话/\($0)" })
        #expect(try store.resourceData(images[1]) == image)
        #expect(pixelSize(try store.resourceData(images[0])) == [4, 4])
    }

    @Test func zipWithoutFoldersIsOneChapter() throws {
        let url = tempDirectory().appendingPathComponent("短篇.zip")
        try writeZip(url, [("3.jpg", png()), ("1.jpg", png()), ("20.jpg", png())])
        let store = LocalBookStore(root: tempDirectory())
        let result = try store.importBook(from: url)
        #expect(result.chapters.map(\.title) == ["全本"])
        let images = try store.mediaImages(for: result.book, chapter: result.chapters[0])
        #expect(images.map { String($0.split(separator: "/").last!) } == ["1.jpg", "3.jpg", "20.jpg"])
    }

    @Test func archiveWithoutImagesFails() throws {
        let url = tempDirectory().appendingPathComponent("空.zip")
        try writeZip(url, [("a.txt", Data("x".utf8))])
        let store = LocalBookStore(root: tempDirectory())
        #expect(throws: LocalMediaError.noImages) { try store.importBook(from: url) }
    }

    @Test func pdfChaptersFromOutline() throws {
        let url = tempDirectory().appendingPathComponent("画册.pdf")
        try writePDF(url, pages: 5, outline: [("第一章", 1), ("第二章", 3)])
        let store = LocalBookStore(root: tempDirectory())
        let result = try store.importBook(from: url)
        #expect(result.book.type == BookSourceType.image.rawValue)
        #expect(result.chapters.map(\.title) == ["开篇", "第一章", "第二章"])
        #expect(result.chapters.map(\.start) == [0, 1, 3])
        #expect(result.chapters.map(\.end) == [1, 3, 5])
        #expect(result.book.coverUrl != nil)

        let images = try store.mediaImages(for: result.book, chapter: result.chapters[2])
        #expect(images == ["\(result.book.bookUrl)/pdf/3", "\(result.book.bookUrl)/pdf/4"])
        let page = try store.resourceData(images[0])
        // 200 点宽按渲染宽度放大，放大倍数上限 4
        #expect(pixelSize(page) == [800, 1200])
        let id = try #require(LocalBookStore.id(of: result.book))
        let cached = store.directory(id).appendingPathComponent("pages/3.jpg")
        #expect(FileManager.default.fileExists(atPath: cached.path))
        #expect(try store.resourceData(images[0]) == page)
        #expect(throws: LocalMediaError.invalidPDF) { try store.resourceData("\(result.book.bookUrl)/pdf/99") }
    }

    @Test func pdfWithoutOutlineSplitsByPages() throws {
        let store = LocalBookStore(root: tempDirectory())
        let long = tempDirectory().appendingPathComponent("长.pdf")
        try writePDF(long, pages: 45)
        let result = try store.importBook(from: long)
        #expect(result.chapters.map(\.title) == ["第 1–20 页", "第 21–40 页", "第 41–45 页"])
        #expect(result.chapters.last?.end == 45)

        let short = tempDirectory().appendingPathComponent("短.pdf")
        try writePDF(short, pages: 3)
        #expect(try store.importBook(from: short).chapters.map(\.title) == ["全本"])
    }

    @Test func rotatedPDFPage() throws {
        let url = tempDirectory().appendingPathComponent("横.pdf")
        try writePDF(url, pages: 1, rotate: 90)
        let store = LocalBookStore(root: tempDirectory())
        let result = try store.importBook(from: url)
        let images = try store.mediaImages(for: result.book, chapter: result.chapters[0])
        #expect(pixelSize(try store.resourceData(images[0])) == [1200, 800])
    }

    @Test func rebuildsComicChapters() throws {
        let url = tempDirectory().appendingPathComponent("重建.pdf")
        try writePDF(url, pages: 4, outline: [("甲", 0), ("乙", 2)])
        let store = LocalBookStore(root: tempDirectory())
        let result = try store.importBook(from: url)
        let id = try #require(LocalBookStore.id(of: result.book))
        try FileManager.default.removeItem(at: store.directory(id).appendingPathComponent("chapters.json"))
        #expect(try store.chapters(for: result.book).map(\.title) == ["甲", "乙"])
    }
}
