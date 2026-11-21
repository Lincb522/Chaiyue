import Foundation
import ReaderModels

/// TXT 分章方式
public enum TxtTocMode: Hashable, Sendable {
    /// 用启用的目录规则自动识别，识别不到时按长度分章
    case auto
    /// 指定目录正则（多行模式）
    case pattern(String)
    /// 按固定长度分章
    case byLength
}

/// 分章结果中的一章。`range` 是正文（不含标题行）在全文中的 UTF-16 范围
public struct TxtChapterSpan: Hashable, Sendable {
    public var title: String
    public var range: Range<Int>
    public var isVolume: Bool

    public init(title: String, range: Range<Int>, isVolume: Bool = false) {
        self.title = title
        self.range = range
        self.isVolume = isVolume
    }
}

public struct TxtSplitResult: Sendable {
    public var chapters: [TxtChapterSpan]
    /// 实际使用的目录正则（保存为 `book.tocUrl`），按长度分章时为空
    public var pattern: String
    /// 第一个标题之前的内容（最多 500 字），用作简介
    public var intro: String?
}

/// TXT 分章，算法与 Legado TextFile 一致：
/// - 自动识别：对开头一段文本逐条试启用的规则，只统计相距超过 1000 字的匹配，取数量最多的（同数量取优先级高的）；
/// - 第一个标题前有内容时作为「前言」；标题后没有正文的章节标记为卷；
/// - 超长章节（拆分开启时）按长度拆成「标题(1)」「标题(2)」…，原标题保留为卷；
/// - 按长度分章时在达到长度后的第一个换行处断开，末尾不超过 100 字的余量并入上一章
public enum TxtChapterSplitter {
    public static let detectionSampleLength = 200_000
    public static let lengthPerChapter = 5_000
    public static let maxChapterLength = 50_000

    public static func split(_ text: String, mode: TxtTocMode, rules: [TxtTocRule] = TxtTocRule.defaults,
                             splitLongChapter: Bool = true) throws -> TxtSplitResult {
        let ns = nativeString(text)
        switch mode {
        case .byLength:
            return TxtSplitResult(chapters: lengthChapters(ns, range: 0..<ns.length), pattern: "", intro: nil)
        case .pattern(let pattern):
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else {
                throw LocalBookError.invalidPattern(pattern)
            }
            guard let result = split(ns, regex: regex, splitLongChapter: splitLongChapter) else {
                throw LocalBookError.noChapterMatched
            }
            return result
        case .auto:
            if let rule = detectRule(in: ns, rules: rules),
               let regex = try? NSRegularExpression(pattern: rule.rule, options: .anchorsMatchLines),
               let result = split(ns, regex: regex, splitLongChapter: splitLongChapter) {
                return result
            }
            return TxtSplitResult(chapters: lengthChapters(ns, range: 0..<ns.length), pattern: "", intro: nil)
        }
    }

    /// 自动识别目录规则（导入页预览用）
    public static func detectRule(in text: String, rules: [TxtTocRule] = TxtTocRule.defaults) -> TxtTocRule? {
        detectRule(in: nativeString(text), rules: rules)
    }

    static func detectRule(in text: NSString, rules: [TxtTocRule]) -> TxtTocRule? {
        let sampleLength = min(text.length, detectionSampleLength)
        let range = text.rangeOfComposedCharacterSequences(for: NSRange(location: 0, length: sampleLength))
        var best: TxtTocRule?
        var maxCount = 1
        for rule in rules.filter(\.enable).sorted(by: { $0.serialNumber < $1.serialNumber }).reversed() {
            guard !rule.rule.isEmpty,
                  let regex = try? NSRegularExpression(pattern: rule.rule, options: .anchorsMatchLines)
            else { continue }
            var lastEnd = 0
            var count = 0
            regex.enumerateMatches(in: text as String, range: range) { match, _, _ in
                guard let match else { return }
                if lastEnd == 0 || match.range.location - lastEnd > 1000 {
                    count += 1
                    lastEnd = match.range.location + match.range.length
                }
            }
            if count >= maxCount {
                maxCount = count
                best = rule
            }
        }
        return best
    }

    /// 按正则分章；没有任何匹配时返回 nil
    static func split(_ text: NSString, regex: NSRegularExpression, splitLongChapter: Bool) -> TxtSplitResult? {
        let matches = regex.matches(in: text as String, range: NSRange(location: 0, length: text.length))
            .filter { $0.range.length > 0 }
        guard !matches.isEmpty else { return nil }
        var chapters: [TxtChapterSpan] = []
        var intro: String?
        /// 当前最后一个标题章节在 `chapters` 中的位置与标题起点
        var open: (index: Int, titleStart: Int)?

        func close(at end: Int) {
            guard let current = open else { return }
            var chapter = chapters[current.index]
            chapter.range = chapter.range.lowerBound..<end
            chapter.isVolume = isBlank(text, chapter.range)
            if splitLongChapter, end - current.titleStart > maxChapterLength {
                let parts = lengthRanges(text, range: chapter.range)
                chapter.range = chapter.range.lowerBound..<chapter.range.lowerBound
                chapter.isVolume = true
                chapters[current.index] = chapter
                for (i, part) in parts.enumerated() {
                    chapters.append(TxtChapterSpan(title: "\(chapter.title)(\(i + 1))", range: part))
                }
            } else {
                chapters[current.index] = chapter
            }
            open = nil
        }

        for match in matches {
            let titleStart = match.range.location
            let titleEnd = titleStart + match.range.length
            if open != nil {
                close(at: titleStart)
            } else if titleStart > 0 {
                let preface = 0..<titleStart
                if splitLongChapter, titleStart > maxChapterLength {
                    chapters.append(contentsOf: lengthChapters(text, range: preface))
                } else if !isBlank(text, preface) {
                    chapters.append(TxtChapterSpan(title: "前言", range: preface))
                    let introRange = text.rangeOfComposedCharacterSequences(for: NSRange(location: 0, length: min(titleStart, 500)))
                    intro = text.substring(with: introRange).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            let title = text.substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines)
            chapters.append(TxtChapterSpan(title: title, range: titleEnd..<titleEnd))
            open = (chapters.count - 1, titleStart)
        }
        close(at: text.length)
        return TxtSplitResult(chapters: chapters, pattern: regex.pattern, intro: intro?.isEmpty == false ? intro : nil)
    }

    static func lengthChapters(_ text: NSString, range: Range<Int>) -> [TxtChapterSpan] {
        lengthRanges(text, range: range).enumerated().map { i, part in
            TxtChapterSpan(title: "第\(i + 1)节", range: part)
        }
    }

    static func lengthRanges(_ text: NSString, range: Range<Int>, length: Int = lengthPerChapter) -> [Range<Int>] {
        var parts: [Range<Int>] = []
        var start = range.lowerBound
        while range.upperBound - start > length {
            let searchStart = start + length
            let found = text.range(of: "\n", options: .literal,
                                   range: NSRange(location: searchStart, length: range.upperBound - searchStart))
            let end = found.location == NSNotFound ? range.upperBound : found.location
            parts.append(start..<end)
            start = end
        }
        let rest = range.upperBound - start
        if rest > 100 || (parts.isEmpty && rest > 0) {
            parts.append(start..<range.upperBound)
        } else if rest > 0, let last = parts.popLast() {
            parts.append(last.lowerBound..<range.upperBound)
        }
        return parts
    }

    private static func isBlank(_ text: NSString, _ range: Range<Int>) -> Bool {
        guard !range.isEmpty else { return true }
        let nonBlank = text.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted, options: .literal,
                                             range: NSRange(location: range.lowerBound, length: range.count))
        return nonBlank.location == NSNotFound
    }

    /// 转成连续 UTF-16 存储的 NSString，正则匹配与截取不再经过 Swift 字符串的桥接索引
    static func nativeString(_ text: String) -> NSString {
        let units = Array(text.utf16)
        return NSString(characters: units, length: units.count)
    }
}
