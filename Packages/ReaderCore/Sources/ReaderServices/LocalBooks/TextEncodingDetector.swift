import Foundation
import RuleEngine

/// 本地文本的编码识别与解码
public enum TextEncodingDetector {
    public static let sampleSize = 512_000

    /// 识别编码，返回 Legado `book.charset` 使用的名称（UTF-8、UTF-16LE、UTF-16BE、GB18030、Big5）
    public static func detect(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(sampleSize))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return "UTF-8" }
        if bytes.starts(with: [0xFF, 0xFE]) { return "UTF-16LE" }
        if bytes.starts(with: [0xFE, 0xFF]) { return "UTF-16BE" }
        if let utf16 = utf16WithoutBOM(bytes) { return utf16 }

        // 采样截断在多字节字符中间时会导致校验失败；0x0A 不会出现在 UTF-8/GBK/Big5 的后续字节里
        var sample = bytes[...]
        if data.count > bytes.count, let lastNewline = bytes.lastIndex(of: 0x0A) {
            sample = bytes[...lastNewline]
        }
        if String(bytes: sample, encoding: .utf8) != nil { return "UTF-8" }
        if looksLikeBig5(sample), let big5 = Charsets.encoding(named: "Big5"), String(bytes: sample, encoding: big5) != nil {
            return "Big5"
        }
        return "GB18030"
    }

    /// 按编码解码全文：去掉 BOM，非法字节有损替换，统一换行为 `\n`
    public static func decode(_ data: Data, charset: String) -> String {
        let encoding = Charsets.encoding(named: charset) ?? .utf8
        var body = data
        switch encoding {
        case .utf8 where data.starts(with: [0xEF, 0xBB, 0xBF]):
            body = data.dropFirst(3)
        case .utf16LittleEndian where data.starts(with: [0xFF, 0xFE]),
             .utf16BigEndian where data.starts(with: [0xFE, 0xFF]):
            body = data.dropFirst(2)
        default:
            break
        }
        let text: String
        if encoding == .utf8 {
            text = String(decoding: body, as: UTF8.self)
        } else if let strict = String(data: body, encoding: encoding) {
            text = strict
        } else {
            text = lossyDecode(Data(body), encoding: encoding)
        }
        return normalizeNewlines(text)
    }

    public static func normalizeNewlines(_ text: String) -> String {
        guard text.contains("\r") else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    private static func lossyDecode(_ data: Data, encoding: String.Encoding) -> String {
        var converted: NSString?
        var lossy: ObjCBool = false
        _ = NSString.stringEncoding(for: data, encodingOptions: [
            .suggestedEncodingsKey: [encoding.rawValue],
            .useOnlySuggestedEncodingsKey: true,
            .allowLossyKey: true,
        ], convertedString: &converted, usedLossyConversion: &lossy)
        return converted.map { String($0) } ?? String(decoding: data, as: UTF8.self)
    }

    /// 没有 BOM 的 UTF-16：英文与标点的高位字节为 0，集中出现在奇数位（LE）或偶数位（BE）
    private static func utf16WithoutBOM(_ bytes: [UInt8]) -> String? {
        let probe = bytes.prefix(4096)
        guard probe.count >= 64 else { return nil }
        var evenZeros = 0
        var oddZeros = 0
        for (i, byte) in probe.enumerated() where byte == 0 {
            if i.isMultiple(of: 2) { evenZeros += 1 } else { oddZeros += 1 }
        }
        let half = probe.count / 2
        if oddZeros * 10 > half * 3, evenZeros * 10 < half { return "UTF-16LE" }
        if evenZeros * 10 > half * 3, oddZeros * 10 < half { return "UTF-16BE" }
        return nil
    }

    /// Big5 常用字约四成的第二字节落在 0x40–0x7E；GBK 常用字（GB2312 区）的第二字节都不小于 0xA1
    private static func looksLikeBig5(_ bytes: ArraySlice<UInt8>) -> Bool {
        var pairs = 0
        var lowTrail = 0
        var i = bytes.startIndex
        while i < bytes.endIndex {
            if bytes[i] < 0x80 {
                i += 1
                continue
            }
            let next = bytes.index(after: i)
            guard next < bytes.endIndex else { break }
            pairs += 1
            if bytes[next] < 0xA1 { lowTrail += 1 }
            i = bytes.index(after: next)
        }
        return pairs >= 8 && lowTrail * 5 > pairs
    }
}
