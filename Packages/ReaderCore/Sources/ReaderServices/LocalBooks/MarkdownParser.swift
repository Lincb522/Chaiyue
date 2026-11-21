import Foundation

/// Markdown：`#`–`###`（以及 `===`/`---` 下划线式）标题处分章，去掉强调、链接、代码等标记；
/// 开头的 YAML front matter 读取 title、author。只保留网络图片
enum MarkdownParser {
    static func convert(_ url: URL, context: ConversionContext) throws -> ConvertedBook {
        guard let data = try? Data(contentsOf: url) else { throw LocalBookError.fileMissing }
        guard !data.isEmpty else { throw LocalBookError.emptyFile }
        let source = TextEncodingDetector.decode(data, charset: TextEncodingDetector.detect(data))
        var book = ConvertedBook(chapters: [])
        let result = lines(source)
        book.title = result.meta["title"]
        book.authors = result.meta["author"].map { [$0] } ?? []
        book.intro = result.meta["description"]
        book.chapters = try ConvertedText.chapters(result.lines.joined(separator: "\n"), rules: context.rules)
        return book
    }

    static func lines(_ source: String) -> (lines: [String], meta: [String: String]) {
        var raw = source.components(separatedBy: "\n")
        var meta: [String: String] = [:]
        if raw.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = raw.dropFirst().firstIndex(where: { ["---", "..."].contains($0.trimmingCharacters(in: .whitespaces)) }) {
            for line in raw[1..<end] {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !value.isEmpty { meta[key] = value }
            }
            raw.removeSubrange(0...end)
        }

        var out: [String] = []
        var inCode = false
        var previousIsText = false
        for line in raw {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inCode.toggle()
                previousIsText = false
                continue
            }
            if inCode {
                out.append(line)
                continue
            }
            if trimmed.isEmpty {
                previousIsText = false
                continue
            }
            // 下划线式标题：上一行是普通文字
            if previousIsText, let underline = trimmed.wholeMatch(of: /(=+|-+)/), let last = out.popLast() {
                out.append(ConvertedText.marker(level: underline.1.hasPrefix("=") ? 1 : 2, title: last))
                previousIsText = false
                continue
            }
            if trimmed.wholeMatch(of: /([-*_]\s*){3,}/) != nil {
                previousIsText = false
                continue
            }
            if let heading = trimmed.wholeMatch(of: /(#{1,6})\s+(.*?)\s*#*/) {
                let title = inline(String(heading.2))
                out.append(heading.1.count <= 3 ? ConvertedText.marker(level: heading.1.count, title: title) : title)
                previousIsText = false
                continue
            }
            if trimmed.wholeMatch(of: /\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?/) != nil { continue }
            var text = trimmed.replacingOccurrences(of: #"^(>\s?)+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^[-*+]\s+(\[[ xX]\]\s+)?"#, with: "• ", options: .regularExpression)
            if text.hasPrefix("|") { text = text.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "  ") }
            var cursor = text.startIndex
            for match in text.matches(of: /!\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+["'][^"']*["'])?\s*\)/) where ConvertedText.isRemote(String(match.1)) {
                out.append(inline(String(text[cursor..<match.range.lowerBound])))
                out.append("<img src=\"\(match.1)\">")
                cursor = match.range.upperBound
            }
            out.append(inline(String(text[cursor...])))
            previousIsText = true
        }
        return (out, meta)
    }

    /// 行内标记：图片（非网络）、链接、强调、行内代码、HTML 标签与转义
    static func inline(_ text: String) -> String {
        var text = text
        let rules: [(String, String)] = [
            (#"!\[([^\]]*)\]\([^)]*\)"#, ""),
            (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),
            (#"\[([^\]]+)\]\[[^\]]*\]"#, "$1"),
            (#"`([^`]+)`"#, "$1"),
            (#"(\*\*|__)(.+?)\1"#, "$2"),
            (#"(?<![\\*])\*(?![\s*])([^*]+?)(?<![\s\\])\*(?!\*)"#, "$1"),
            (#"(?<![\w_])_(?!\s)([^_]+?)_(?![\w_])"#, "$1"),
            (#"~~(.+?)~~"#, "$1"),
            (#"</?[a-zA-Z][^>]*>"#, ""),
            (#"\\([\\`*_{}\[\]()#+\-.!|>~])"#, "$1"),
        ]
        for (pattern, template) in rules {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
