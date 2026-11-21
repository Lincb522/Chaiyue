import Foundation
import RuleEngine
import SwiftSoup

/// PalmDB 容器：78 字节头 + 记录表
struct PalmDatabase {
    let bytes: [UInt8]
    let name: String
    let type: String
    private let offsets: [Int]

    init(_ data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 78 else { throw LocalBookError.corruptFile("不是有效的 MOBI 文件") }
        let count = bytes.beU16(76)
        guard count > 0, 78 + count * 8 <= bytes.count else { throw LocalBookError.corruptFile("MOBI 文件记录表损坏") }
        let offsets = (0..<count).map { bytes.beU32(78 + $0 * 8) }
        guard zip(offsets, offsets.dropFirst()).allSatisfy({ $0 <= $1 }), offsets[count - 1] <= bytes.count else {
            throw LocalBookError.corruptFile("MOBI 文件记录表损坏")
        }
        self.bytes = bytes
        self.offsets = offsets
        type = bytes.ascii(60..<68)
        let rawName = bytes[0..<32].prefix { $0 != 0 }
        name = String(bytes: rawName, encoding: .utf8) ?? String(bytes: rawName, encoding: .windowsCP1252) ?? ""
    }

    var count: Int { offsets.count }

    func record(_ index: Int) -> [UInt8] {
        guard index >= 0, index < offsets.count else { return [] }
        let end = index + 1 < offsets.count ? offsets[index + 1] : bytes.count
        return Array(bytes[offsets[index]..<end])
    }
}

/// 记录 0 中的 PalmDOC 头、MOBI 头与 EXTH 元数据
struct MobiHeader {
    let record: [UInt8]
    let compression: Int
    let textLength: Int
    let textRecordCount: Int
    let encryption: Int
    let headerLength: Int
    let version: Int
    let encoding: String.Encoding
    let extraFlags: Int
    let fullName: String?
    private(set) var exth: [Int: [[UInt8]]] = [:]

    init(_ record: [UInt8]) throws {
        guard record.count >= 24, record.ascii(16..<20) == "MOBI" else { throw LocalBookError.corruptFile("MOBI 文件缺少 MOBI 头") }
        self.record = record
        compression = record.beU16(0)
        textLength = record.beU32(4)
        textRecordCount = record.beU16(8)
        encryption = record.beU16(12)
        headerLength = record.beU32(20)
        encoding = record.beU32(28) == 65001 ? .utf8 : .windowsCP1252
        version = record.beU32(36)
        extraFlags = headerLength >= 0xE4 && version >= 5 ? record.beU16(242) : 0
        let nameOffset = record.beU32(84), nameLength = record.beU32(88)
        if nameLength > 0, nameOffset + nameLength <= record.count {
            fullName = String(bytes: record[nameOffset..<nameOffset + nameLength], encoding: encoding)
        } else {
            fullName = nil
        }
        if record.beU32(128) & 0x40 != 0 {
            var pos = 16 + headerLength
            if record.ascii(pos..<pos + 4) == "EXTH" {
                let count = record.beU32(pos + 8)
                pos += 12
                for _ in 0..<count {
                    let type = record.beU32(pos), length = record.beU32(pos + 4)
                    guard length >= 8, pos + length <= record.count else { break }
                    exth[type, default: []].append(Array(record[pos + 8..<pos + length]))
                    pos += length
                }
            }
        }
    }

    /// MOBI 头中的 32 位字段（相对记录 0），超出头长度或为 0xFFFFFFFF 时为 nil
    func field(_ offset: Int) -> Int? {
        guard offset + 4 <= 16 + headerLength, offset + 4 <= record.count else { return nil }
        let value = record.beU32(offset)
        return value == 0xFFFF_FFFF ? nil : value
    }

    var firstImage: Int? { field(108) }
    var ncxIndex: Int? { field(244) }

    func string(_ bytes: [UInt8]) -> String {
        (String(bytes: bytes, encoding: encoding) ?? String(decoding: bytes, as: UTF8.self))
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
    }

    func exthStrings(_ type: Int) -> [String] {
        (exth[type] ?? []).map(string).filter { !$0.isEmpty }
    }

    func exthInt(_ type: Int) -> Int? {
        guard let value = exth[type]?.first, value.count == 4 else { return nil }
        let number = value.beU32(0)
        return number == 0xFFFF_FFFF ? nil : number
    }
}

/// MOBI / AZW / AZW3 / PRC 解析。正文为 PalmDOC 压缩的 HTML：
/// - KF6：按 NCX 索引的 filepos 分章，其次正文目录页（guide toc 或成组的 filepos 链接），再次 h1/h2 或 `<mbp:pagebreak>`；
/// - KF8（AZW3，以及 KF6/KF8 合并文件里的 KF8 部分）：按 skeleton/fragment 还原各 XHTML 文件，按 NCX 位置分章，没有 NCX 时每个文件一章；
/// - 纯 PalmDOC（TEXtREAd）按 TXT 分章。图片记录按需导出，HUFF/CDIC 压缩与 DRM 加密的书报错
enum MobiParser {
    static func convert(_ url: URL, context: ConversionContext) throws -> ConvertedBook {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw LocalBookError.fileMissing }
        guard !data.isEmpty else { throw LocalBookError.emptyFile }
        let db = try PalmDatabase(data)
        if db.type == "TEXtREAd" { return try convertPalmDoc(db, context: context) }
        guard db.type == "BOOKMOBI" else { throw LocalBookError.corruptFile("不是有效的 MOBI 文件") }

        let kf6 = try MobiHeader(db.record(0))
        var header = kf6
        var base = 0
        if let boundary = kf6.exthInt(121), boundary > 0, boundary < db.count,
           let kf8 = try? MobiHeader(db.record(boundary)), kf8.version >= 8 {
            header = kf8
            base = boundary
        }
        guard kf6.encryption == 0, header.encryption == 0 else { throw LocalBookError.drmProtected }

        let images = ImageRecords(db: db, bases: [header.firstImage.map { $0 + base }, header.firstImage, kf6.firstImage]
            .compactMap { $0 }, context: context)
        let text = header.version >= 8 ? try kf8Text(db, header: header, base: base, images: images)
            : try kf6Text(db, header: header, images: images)

        var book = ConvertedBook(chapters: try ConvertedText.chapters(text, rules: context.rules))
        book.title = (header.exthStrings(503).first ?? kf6.exthStrings(503).first ?? header.fullName ?? db.name).nilIfEmpty
        book.authors = header.exthStrings(100).nilIfEmpty ?? kf6.exthStrings(100)
        if let description = header.exthStrings(103).first ?? kf6.exthStrings(103).first {
            book.intro = (description.contains("<") ? HTMLFormatter.format(description) : description)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\u{3000}").union(.whitespacesAndNewlines)).nilIfEmpty
        }
        if let offset = header.exthInt(201) ?? kf6.exthInt(201) {
            book.cover = images.data(offset + 1)
        }
        return book
    }

    // MARK: - 正文

    /// 拼接并解压文本记录
    static func rawText(_ db: PalmDatabase, header: MobiHeader, base: Int) throws -> [UInt8] {
        switch header.compression {
        case 1, 2: break
        case 17480: throw LocalBookError.unsupportedVariant("暂不支持 HUFF/CDIC 压缩的 MOBI 文件，可先用 Calibre 转换为 EPUB 再导入")
        default: throw LocalBookError.corruptFile("未知的 MOBI 压缩方式（\(header.compression)）")
        }
        guard header.textRecordCount > 0 else { throw LocalBookError.emptyFile }
        var out: [UInt8] = []
        out.reserveCapacity(header.textLength)
        for index in 1...header.textRecordCount {
            let record = db.record(base + index)
            let body = record[0..<(record.count - trailingSize(record, flags: header.extraFlags))]
            if header.compression == 2 { out += palmDocDecompress(body) } else { out += body }
        }
        if header.textLength > 0, out.count > header.textLength { out.removeLast(out.count - header.textLength) }
        return out
    }

    /// PalmDOC LZ77 解压
    static func palmDocDecompress(_ input: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(input.count * 2)
        var i = input.startIndex
        while i < input.endIndex {
            let c = input[i]
            i += 1
            switch c {
            case 0x01...0x08:
                let end = min(i + Int(c), input.endIndex)
                out += input[i..<end]
                i = end
            case 0x80...0xBF:
                guard i < input.endIndex else { continue }
                let pair = (Int(c) << 8 | Int(input[i])) & 0x3FFF
                i += 1
                let distance = pair >> 3, length = (pair & 7) + 3
                guard distance > 0, distance <= out.count else { continue }
                let start = out.count - distance
                for k in 0..<length { out.append(out[start + k]) }
            case 0xC0...0xFF:
                out.append(0x20)
                out.append(c ^ 0x80)
            default:
                out.append(c)
            }
        }
        return out
    }

    /// 文本记录末尾的附加数据长度（extra data flags：高位各项为倒序变长长度，最低位为多字节字符补齐）
    static func trailingSize(_ record: [UInt8], flags: Int) -> Int {
        var size = 0
        var bits = flags >> 1
        while bits != 0 {
            if bits & 1 != 0 {
                var value = 0, shift = 0, pos = record.count - size
                while pos > 0 {
                    pos -= 1
                    let byte = Int(record[pos])
                    value |= (byte & 0x7F) << shift
                    shift += 7
                    if byte & 0x80 != 0 || shift >= 28 { break }
                }
                size += value
            }
            bits >>= 1
        }
        if flags & 1 != 0, record.count - size - 1 >= 0 {
            size += Int(record[record.count - size - 1] & 0x3) + 1
        }
        return min(max(size, 0), record.count)
    }

    // MARK: - KF6

    private static func kf6Text(_ db: PalmDatabase, header: MobiHeader, images: ImageRecords) throws -> String {
        let text = try rawText(db, header: header, base: 0)
        var markers: [(offset: Int, html: String)] = []
        if let ncx = header.ncxIndex {
            let index = MobiIndex(db: db, at: ncx, encoding: header.encoding)
            markers = index.entries.compactMap { entry in
                guard let offset = entry.tags[1]?.first else { return nil }
                return (offset, ConvertedText.markerHTML(level: (entry.tags[4]?.first ?? 0) + 1, title: index.label(entry)))
            }
        }
        if markers.isEmpty { markers = tocLinkMarkers(text, encoding: header.encoding) }
        var html = assemble(text, markers: markers, encoding: header.encoding)
        var levels: ClosedRange<Int>?
        if markers.isEmpty {
            if html.matches(of: /(?i)<h[12][\s>]/).count >= 2 {
                levels = 1...2
            } else {
                html = html.replacingOccurrences(of: #"(?i)<mbp:pagebreak[^>]*>"#, with: ConvertedText.markerHTML(level: 1, title: ""),
                                                 options: .regularExpression)
            }
        }
        return ConvertedText.text(fromHTML: "<html><body>" + html + "</body></html>", headingLevels: levels) { element in
            let index = ["recindex", "hirecindex", "lorecindex"].lazy.map { EpubParser.attr(element, $0) }.first { !$0.isEmpty }
            if let index, let number = Int(index) { return images.url(number) }
            let src = ConvertedText.imageSource(element)
            return ConvertedText.isRemote(src) ? src : nil
        }
    }

    /// 正文目录页：guide 中 type=toc 的 filepos 之后、或全书最大的一组 filepos 链接（至少 3 个、目标递增）
    static func tocLinkMarkers(_ text: [UInt8], encoding: String.Encoding) -> [(offset: Int, html: String)] {
        // ISO-8859-1 解码后字符位置与字节偏移一一对应
        guard let latin = String(bytes: text, encoding: .isoLatin1) else { return [] }
        let ns = latin as NSString
        let linkPattern = try! NSRegularExpression(pattern: #"<a\s[^>]*filepos\s*=\s*["']?0*(\d+)["']?[^>]*>([\s\S]*?)</a>"#,
                                                   options: .caseInsensitive)
        typealias Link = (location: Int, target: Int, title: String)
        let links: [Link] = linkPattern.matches(in: latin, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard let target = Int(ns.substring(with: match.range(at: 1))), target < text.count else { return nil }
            let titleRange = match.range(at: 2)
            let bytes = Array(text[titleRange.location..<titleRange.location + titleRange.length])
            let title = HTMLFormatter.format(String(bytes: bytes, encoding: encoding) ?? "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\u{3000}").union(.whitespacesAndNewlines))
            return title.isEmpty ? nil : (match.range.location, target, title)
        }
        guard !links.isEmpty else { return [] }
        var groups: [[Link]] = [[links[0]]]
        for link in links.dropFirst() {
            if link.location - groups[groups.count - 1].last!.location < 2000 { groups[groups.count - 1].append(link) } else { groups.append([link]) }
        }
        let tocPattern = try! NSRegularExpression(pattern: #"<reference\s[^>]*type\s*=\s*["']?toc["']?[^>]*filepos\s*=\s*["']?0*(\d+)"#,
                                                  options: .caseInsensitive)
        let tocPos = tocPattern.firstMatch(in: latin, range: NSRange(location: 0, length: ns.length))
            .flatMap { Int(ns.substring(with: $0.range(at: 1))) }
        let isIncreasing = { (group: [Link]) in zip(group, group.dropFirst()).allSatisfy { $0.target < $1.target } }
        let chosen: [Link]?
        if let tocPos, let group = groups.first(where: { $0.last!.location >= tocPos && $0.count >= 2 }) {
            chosen = group
        } else {
            chosen = groups.filter { $0.count >= 3 && isIncreasing($0) }.max { $0.count < $1.count }
        }
        guard let chosen else { return [] }
        var seen = Set<Int>()
        return chosen.filter { seen.insert($0.target).inserted }.map { ($0.target, ConvertedText.markerHTML(level: 1, title: $0.title)) }
    }

    // MARK: - KF8

    private static func kf8Text(_ db: PalmDatabase, header: MobiHeader, base: Int, images: ImageRecords) throws -> String {
        let raw = try rawText(db, header: header, base: base)
        var flow = raw
        if let fdst = header.field(192) {
            let record = db.record(base + fdst)
            if record.ascii(0..<4) == "FDST", record.beU32(8) > 0 {
                let start = record.beU32(12), end = min(record.beU32(16), raw.count)
                if start < end { flow = Array(raw[start..<end]) }
            }
        }
        let image: (Element) -> String? = { element in
            let src = ConvertedText.imageSource(element)
            if src.hasPrefix("kindle:embed:") {
                let code = src.dropFirst("kindle:embed:".count).prefix { $0.isLetter || $0.isNumber }
                return Int(code, radix: 32).flatMap(images.url)
            }
            return ConvertedText.isRemote(src) ? src : nil
        }
        guard let skeletonIndex = header.field(252), let fragmentIndex = header.field(248) else {
            let html = assemble(flow, markers: [], encoding: header.encoding)
            return ConvertedText.text(fromHTML: "<html><body>" + html + "</body></html>", headingLevels: 1...2, image: image)
        }
        let skeletons = MobiIndex(db: db, at: base + skeletonIndex, encoding: header.encoding).entries
        let fragments = MobiIndex(db: db, at: base + fragmentIndex, encoding: header.encoding).entries

        // 按 skeleton 逐个插入 fragment，还原原始 XHTML 文件；文件坐标与 fragment 的插入位置同为整段文本中的位置
        var parts: [(start: Int, bytes: [UInt8])] = []
        var fragmentPointer = 0
        for skeleton in skeletons {
            guard let count = skeleton.tags[1]?.first, let position = skeleton.tags[6], position.count >= 2,
                  position[0] + position[1] <= flow.count
            else { continue }
            let start = position[0]
            var part = Array(flow[start..<start + position[1]])
            var pointer = start + position[1]
            for _ in 0..<count where fragmentPointer < fragments.count {
                let fragment = fragments[fragmentPointer]
                fragmentPointer += 1
                guard let insert = Int(fragment.key), let length = fragment.tags[6]?.last, pointer <= flow.count else { continue }
                let slice = flow[pointer..<min(pointer + length, flow.count)]
                part.insert(contentsOf: slice, at: min(max(0, insert - start), part.count))
                pointer += length
            }
            parts.append((start, part))
        }
        guard !parts.isEmpty else { throw LocalBookError.corruptFile("AZW3 文件结构损坏") }

        var markers = Array(repeating: [(offset: Int, html: String)](), count: parts.count)
        if let ncx = header.ncxIndex {
            let index = MobiIndex(db: db, at: base + ncx, encoding: header.encoding)
            for entry in index.entries {
                var position: Int?
                if let posFid = entry.tags[6], posFid.count >= 2, posFid[0] < fragments.count, let insert = Int(fragments[posFid[0]].key) {
                    position = insert + posFid[1]
                } else {
                    position = entry.tags[1]?.first
                }
                guard let position,
                      let part = parts.firstIndex(where: { position >= $0.start && position < $0.start + $0.bytes.count })
                else { continue }
                markers[part].append((position - parts[part].start,
                                      ConvertedText.markerHTML(level: (entry.tags[4]?.first ?? 0) + 1, title: index.label(entry))))
            }
        }
        let hasNCX = markers.contains { !$0.isEmpty }
        let html = parts.indices.map { i in
            var partMarkers = markers[i]
            if !hasNCX { partMarkers = [(0, ConvertedText.markerHTML(level: 1, title: pageTitle(parts[i].bytes, encoding: header.encoding)))] }
            return assemble(parts[i].bytes, markers: partMarkers, encoding: header.encoding)
        }.joined(separator: "\n")
        return ConvertedText.text(fromHTML: "<html><body>" + html + "</body></html>", image: image)
    }

    private static func pageTitle(_ bytes: [UInt8], encoding: String.Encoding) -> String {
        let html = String(bytes: bytes, encoding: encoding) ?? String(decoding: bytes, as: UTF8.self)
        for pattern in [#"<title[^>]*>([\s\S]*?)</title>"#, #"<h[1-3][^>]*>([\s\S]*?)</h[1-3]>"#] {
            guard let range = html.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { continue }
            let title = HTMLFormatter.format(html[range].replacingOccurrences(of: #"^<[^>]*>|<[^>]*>$"#, with: "", options: .regularExpression))
                .trimmingCharacters(in: CharacterSet(charactersIn: "\u{3000}").union(.whitespacesAndNewlines))
            if !title.isEmpty { return title }
        }
        return ""
    }

    // MARK: - 拼装

    /// 取 `<body>` 内的 HTML，并在给定字节位置插入章节标记（落在标签内部时移到标签开头）
    static func assemble(_ bytes: [UInt8], markers: [(offset: Int, html: String)], encoding: String.Encoding) -> String {
        var start = 0, end = bytes.count
        if let open = find(bytes, "<body", from: 0), let close = bytes[open...].firstIndex(of: UInt8(ascii: ">")) {
            start = close + 1
        }
        if let close = findLast(bytes, "</body"), close >= start { end = close }
        let sorted = markers.enumerated().map { index, marker in
            (offset: adjust(bytes, min(max(marker.offset, start), end), lowerBound: start), html: marker.html, order: index)
        }.sorted { ($0.offset, $0.order) < ($1.offset, $1.order) }
        func decode(_ range: Range<Int>) -> String {
            guard !range.isEmpty else { return "" }
            let slice = bytes[range]
            return String(bytes: slice, encoding: encoding) ?? String(decoding: slice, as: UTF8.self)
        }
        var out = ""
        var position = start
        for marker in sorted {
            out += decode(position..<marker.offset)
            out += marker.html
            position = marker.offset
        }
        out += decode(position..<end)
        return out
    }

    private static func adjust(_ bytes: [UInt8], _ offset: Int, lowerBound: Int) -> Int {
        var i = offset
        // 落在标签内部时退到 `<`
        var j = offset - 1
        while j >= max(lowerBound, offset - 4096) {
            if bytes[j] == UInt8(ascii: ">") { break }
            if bytes[j] == UInt8(ascii: "<") {
                i = j
                break
            }
            j -= 1
        }
        // 不切开 UTF-8 多字节字符
        while i > lowerBound, i < bytes.count, bytes[i] & 0xC0 == 0x80 { i -= 1 }
        return i
    }

    private static func find(_ bytes: [UInt8], _ needle: String, from: Int) -> Int? {
        let pattern = Array(needle.utf8)
        guard bytes.count >= pattern.count else { return nil }
        var i = from
        while i <= bytes.count - pattern.count {
            if bytes[i] == pattern[0], zip(bytes[i..<i + pattern.count], pattern).allSatisfy({ ($0 | 0x20) == ($1 | 0x20) }) { return i }
            i += 1
        }
        return nil
    }

    private static func findLast(_ bytes: [UInt8], _ needle: String) -> Int? {
        let pattern = Array(needle.utf8)
        guard bytes.count >= pattern.count else { return nil }
        var i = bytes.count - pattern.count
        while i >= 0 {
            if bytes[i] == pattern[0], zip(bytes[i..<i + pattern.count], pattern).allSatisfy({ ($0 | 0x20) == ($1 | 0x20) }) { return i }
            i -= 1
        }
        return nil
    }

    // MARK: - PalmDOC

    private static func convertPalmDoc(_ db: PalmDatabase, context: ConversionContext) throws -> ConvertedBook {
        let record = db.record(0)
        guard record.count >= 16 else { throw LocalBookError.corruptFile("PalmDOC 文件头损坏") }
        let compression = record.beU16(0), count = record.beU16(8)
        guard compression == 1 || compression == 2 else { throw LocalBookError.corruptFile("未知的 PalmDOC 压缩方式（\(compression)）") }
        var bytes: [UInt8] = []
        for index in stride(from: 1, through: count, by: 1) {
            let body = db.record(index)
            bytes += compression == 2 ? palmDocDecompress(body[...]) : body
        }
        let data = Data(bytes)
        let text = TextEncodingDetector.decode(data, charset: TextEncodingDetector.detect(data))
        var book = ConvertedBook(chapters: try ConvertedText.plainChapters(text, rules: context.rules))
        book.title = db.name.nilIfEmpty
        return book
    }
}

/// 图片记录：`recindex` 与 `kindle:embed` 从 1 开始，相对第一个图片记录；按需导出到 `res/`
private final class ImageRecords {
    let db: PalmDatabase
    let bases: [Int]
    let context: ConversionContext
    private var urls: [Int: String?] = [:]

    init(db: PalmDatabase, bases: [Int], context: ConversionContext) {
        var seen = Set<Int>()
        self.db = db
        self.bases = bases.filter { seen.insert($0).inserted }
        self.context = context
    }

    func data(_ number: Int) -> Data? {
        guard number > 0 else { return nil }
        for base in bases {
            let data = Data(db.record(base + number - 1))
            if ConvertedText.imageExtension(data) != nil { return data }
        }
        return nil
    }

    func url(_ number: Int) -> String? {
        if let cached = urls[number] { return cached }
        let url = data(number).flatMap { context.addResource($0, name: String(format: "image%05d", number)) }
        urls[number] = url
        return url
    }
}

/// INDX 索引（NCX、skeleton、fragment）：头记录含 TAGX 标签表，其后为数据记录与 CNCX 字符串记录
struct MobiIndex {
    struct Entry {
        var key: String
        var tags: [Int: [Int]]
    }

    private(set) var entries: [Entry] = []
    private(set) var strings: [Int: String] = [:]

    init(db: PalmDatabase, at index: Int, encoding: String.Encoding) {
        let header = db.record(index)
        guard header.ascii(0..<4) == "INDX" else { return }
        let headerLength = header.beU32(4), recordCount = header.beU32(24), cncxCount = header.beU32(52)
        guard header.ascii(headerLength..<headerLength + 4) == "TAGX" else { return }
        let tagxLength = header.beU32(headerLength + 4), controlCount = header.beU32(headerLength + 8)
        var tagTable: [(tag: Int, values: Int, mask: Int, eof: Bool)] = []
        for pos in stride(from: headerLength + 12, to: headerLength + tagxLength, by: 4) where pos + 4 <= header.count {
            tagTable.append((Int(header[pos]), Int(header[pos + 1]), Int(header[pos + 2]), header[pos + 3] & 1 != 0))
        }
        for c in 0..<cncxCount {
            let record = db.record(index + recordCount + 1 + c)
            var pos = 0
            while pos < record.count {
                let (length, consumed) = Self.varint(record, at: pos)
                let start = pos + consumed
                guard consumed > 0, start + length <= record.count else { break }
                strings[c * 0x10000 + pos] = String(bytes: record[start..<start + length], encoding: encoding)
                    ?? String(decoding: record[start..<start + length], as: UTF8.self)
                pos = start + length
            }
        }
        guard recordCount > 0 else { return }
        for i in 1...recordCount {
            let record = db.record(index + i)
            guard record.ascii(0..<4) == "INDX" else { continue }
            let idxt = record.beU32(20), count = record.beU32(24)
            guard record.ascii(idxt..<idxt + 4) == "IDXT" else { continue }
            let offsets = (0..<count).map { record.beU16(idxt + 4 + $0 * 2) }
            for (j, start) in offsets.enumerated() {
                let end = j + 1 < offsets.count ? offsets[j + 1] : idxt
                guard start < end, end <= record.count else { continue }
                let keyLength = Int(record[start])
                guard start + 1 + keyLength <= end else { continue }
                let key = String(decoding: record[start + 1..<start + 1 + keyLength], as: UTF8.self)
                let tags = Self.tagMap(Array(record[start + 1 + keyLength..<end]), controlCount: controlCount, table: tagTable)
                entries.append(Entry(key: key, tags: tags))
            }
        }
    }

    func label(_ entry: Entry) -> String {
        entry.tags[3]?.first.flatMap { strings[$0] }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// 正序变长整数：每字节 7 位，最高位置 1 的字节为结尾
    static func varint(_ bytes: [UInt8], at offset: Int) -> (value: Int, length: Int) {
        var value = 0, i = offset
        while i < bytes.count {
            let byte = bytes[i]
            i += 1
            value = value << 7 | Int(byte & 0x7F)
            if byte & 0x80 != 0 { break }
        }
        return (value, i - offset)
    }

    private static func tagMap(_ data: [UInt8], controlCount: Int, table: [(tag: Int, values: Int, mask: Int, eof: Bool)]) -> [Int: [Int]] {
        guard data.count >= controlCount else { return [:] }
        var controls = Array(data[0..<controlCount])
        var pos = controlCount
        var pending: [(tag: Int, count: Int?, bytes: Int?, values: Int)] = []
        for entry in table {
            if entry.eof {
                if !controls.isEmpty { controls.removeFirst() }
                continue
            }
            guard let control = controls.first, entry.mask != 0 else { continue }
            var value = Int(control) & entry.mask
            guard value != 0 else { continue }
            if value == entry.mask {
                if entry.mask.nonzeroBitCount > 1 {
                    let (length, consumed) = varint(data, at: pos)
                    pos += consumed
                    pending.append((entry.tag, nil, length, entry.values))
                } else {
                    pending.append((entry.tag, 1, nil, entry.values))
                }
            } else {
                var mask = entry.mask
                while mask & 1 == 0 {
                    mask >>= 1
                    value >>= 1
                }
                pending.append((entry.tag, value, nil, entry.values))
            }
        }
        var result: [Int: [Int]] = [:]
        for item in pending {
            var values: [Int] = []
            if let count = item.count {
                for _ in 0..<count * item.values where pos < data.count {
                    let (value, consumed) = varint(data, at: pos)
                    pos += consumed
                    values.append(value)
                }
            } else if let length = item.bytes {
                var consumedTotal = 0
                while consumedTotal < length, pos < data.count {
                    let (value, consumed) = varint(data, at: pos)
                    pos += consumed
                    consumedTotal += consumed
                    values.append(value)
                }
            }
            result[item.tag] = values
        }
        return result
    }
}

extension Collection {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}
