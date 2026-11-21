import Foundation

/// UMD 解析（文本型）。文件以 0xDE9A9B89 开头，之后是两类数据块：
/// - `#` 功能块：类型（UInt16）、标志、总长度（UInt8）与数据，如 0x01 类型（1 文本、2 漫画）、0x02 书名、0x03 作者；
/// - `$` 附加块：校验号（UInt32）、总长度（UInt32）与数据，紧跟在 0x81 正文块索引、0x82 封面、0x83 章节偏移、0x84 章节标题等功能块之后；
///   不属于功能块的 `$` 块是 zlib 压缩的正文（UTF-16LE，段落分隔符 U+2029）。整数均为小端序
enum UmdParser {
    static let magic = 0xDE9A_9B89

    static func convert(_ url: URL, context: ConversionContext) throws -> ConvertedBook {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw LocalBookError.fileMissing }
        guard !data.isEmpty else { throw LocalBookError.emptyFile }
        let bytes = [UInt8](data)
        guard bytes.count > 9, bytes.leU32(0) == magic else { throw LocalBookError.corruptFile("不是有效的 UMD 文件") }

        var kind = 1
        var title: String?, author: String?
        var blocks: [(id: Int, data: [UInt8])] = []
        var blockOrder: [Int] = []
        var offsets: [Int] = []
        var titles: [String] = []
        var cover: Data?
        var pending: Int?
        var pos = 4
        while pos < bytes.count {
            switch bytes[pos] {
            case 0x23:
                let type = bytes.leU16(pos + 1), length = pos + 4 < bytes.count ? Int(bytes[pos + 4]) : 0
                guard length >= 5, pos + length <= bytes.count else { throw LocalBookError.corruptFile("UMD 文件结构损坏") }
                let body = Array(bytes[pos + 5..<pos + length])
                switch type {
                case 0x01: kind = Int(body.first ?? 1)
                case 0x02: title = utf16(body)
                case 0x03: author = utf16(body)
                default: break
                }
                pending = [0x81, 0x82, 0x83, 0x84, 0x86, 0x87].contains(type) ? type : nil
                pos += length
            case 0x24:
                let id = bytes.leU32(pos + 1), length = bytes.leU32(pos + 5)
                guard length >= 9, pos + length <= bytes.count else { throw LocalBookError.corruptFile("UMD 文件结构损坏") }
                let body = Array(bytes[pos + 9..<pos + length])
                switch pending {
                case 0x81: blockOrder = stride(from: 0, to: body.count - 3, by: 4).map { body.leU32($0) }
                case 0x82: cover = Data(body)
                case 0x83: offsets = stride(from: 0, to: body.count - 3, by: 4).map { body.leU32($0) }
                case 0x84:
                    var i = 0
                    while i < body.count {
                        let length = Int(body[i])
                        guard i + 1 + length <= body.count else { break }
                        titles.append(utf16(Array(body[i + 1..<i + 1 + length])))
                        i += 1 + length
                    }
                case nil: blocks.append((id, body))
                default: break
                }
                pending = nil
                pos += length
            default:
                throw LocalBookError.corruptFile("UMD 文件结构损坏")
            }
        }
        guard kind == 1 else { throw LocalBookError.unsupportedVariant("暂不支持漫画型 UMD，只能导入文本型 UMD") }

        // 有正文块索引且都能对上时按索引排序，否则按出现顺序
        let byID = Dictionary(blocks.map { ($0.id, $0.data) }, uniquingKeysWith: { first, _ in first })
        let ordered = !blockOrder.isEmpty && blockOrder.allSatisfy { byID[$0] != nil } ? blockOrder.compactMap { byID[$0] } : blocks.map(\.data)
        var text: [UInt8] = []
        for block in ordered {
            guard let inflated = ConvertedText.inflate(block) else { throw LocalBookError.corruptFile("UMD 正文解压失败") }
            text += inflated
        }
        guard !text.isEmpty else { throw LocalBookError.emptyFile }

        var chapters: [ConvertedChapter] = []
        let starts = offsets.filter { $0 < text.count }
        if !starts.isEmpty {
            for (i, start) in starts.enumerated() {
                let end = i + 1 < starts.count ? max(start, starts[i + 1]) : text.count
                let title = i < titles.count && !titles[i].isEmpty ? titles[i] : "第\(i + 1)章"
                // 正文通常以章节标题开头
                var lines = utf16(Array(text[start..<end])).components(separatedBy: "\n")
                if let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
                   lines[first].trimmingCharacters(in: .whitespaces) == title {
                    lines.removeSubrange(0...first)
                }
                let content = ConvertedText.paragraphs(lines)
                chapters.append(ConvertedChapter(title: title, content: content))
            }
        } else {
            chapters = try ConvertedText.plainChapters(utf16(text), rules: context.rules)
        }
        var book = ConvertedBook(chapters: chapters)
        book.title = title?.nilIfEmpty
        book.authors = author?.nilIfEmpty.map { [$0] } ?? []
        if let cover, ConvertedText.imageExtension(cover) != nil { book.cover = cover }
        return book
    }

    /// UTF-16LE，段落分隔符转为换行
    static func utf16(_ bytes: [UInt8]) -> String {
        let units = stride(from: 0, to: bytes.count - 1, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }
        return String(decoding: units, as: UTF16.self)
            .replacingOccurrences(of: "\u{2029}", with: "\n").replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespaces)
    }
}
