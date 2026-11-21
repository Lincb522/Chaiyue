import ReaderModels
import SwiftUI

extension String {
    /// 书源文字里的 emoji（连同变体选择符、肤色、组合序列）一律不显示；去掉后合并多余空格，保留换行
    nonisolated var withoutEmoji: String {
        guard contains(where: \.isEmojiGlyph) else { return self }
        let lines = split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.filter { !$0.isEmojiGlyph }.split(separator: " ").joined(separator: " ")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Character {
    /// 数字、#、©、™ 等也带 isEmoji 属性，按码位排除
    nonisolated var isEmojiGlyph: Bool {
        unicodeScalars.contains { scalar in
            scalar.properties.isEmojiPresentation || (scalar.properties.isEmoji && scalar.value > 0x238C)
                || scalar.value == 0xFE0F || scalar.value == 0x20E3
        }
    }
}

/// 书源返回的书籍文字整理：分类只取前两项、简介压成一行
enum BookText {
    static func kind(_ text: String?) -> String? {
        guard let text = text?.withoutEmoji else { return nil }
        let parts = text.split(whereSeparator: { ",，、 \n\t".contains($0) }).prefix(2)
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    static func oneLine(_ text: String?) -> String? {
        guard let text = text?.withoutEmoji else { return nil }
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return line.isEmpty ? nil : line
    }

    static func join(_ parts: String?...) -> String {
        parts.compactMap { ($0?.withoutEmoji).nilIfEmpty }.joined(separator: " · ")
    }

    static func subtitle(_ book: SearchBook) -> String {
        join(book.author, kind(book.kind), book.wordCount)
    }
}

/// 书源名常带 emoji、版本号和括号说明，界面上只显示主体
extension BookText {
    /// 发现分类名常用符号包边（如「°✧ 排行榜 ✧°」），只保留首尾之间的文字；括号算作文字，避免「[小说] 频道」被拆坏
    static func label(_ text: String) -> String {
        let text = text.withoutEmoji
        let kept = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "[]【】()（）《》<>「」『』"))
        let trimmed = text.trimmingCharacters(in: kept.inverted)
        return trimmed.isEmpty ? text : trimmed
    }
}

enum SourceName {
    /// 完整书源名，只去掉 emoji（列表、详情等需要区分版本的地方）
    static func full(_ name: String) -> String {
        let text = name.withoutEmoji
        return text.isEmpty ? name : text
    }

    static func display(_ name: String) -> String {
        var text = name.withoutEmoji
        for (open, close) in [("(", ")"), ("（", "）"), ("[", "]"), ("【", "】"), ("《", "》"), ("<", ">")] {
            while let start = text.range(of: open),
                  let end = text.range(of: close, range: start.upperBound..<text.endIndex) {
                text.removeSubrange(start.lowerBound..<end.upperBound)
            }
        }
        text = text.replacingOccurrences(of: #"[vV]?\d+(\.\d+)+"#, with: "", options: .regularExpression)
        text = String(text.unicodeScalars.filter { scalar in
            !(scalar.properties.isEmojiPresentation || scalar.properties.generalCategory == .otherSymbol)
        }.map(Character.init))
        text = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return text.isEmpty ? name : text
    }
}

enum ChipStyle: Hashable {
    case raised, solid, accent
}

/// 胶囊标签（原型 `.ek`）：凸起、选中实心、强调三种底色之间渐变
private struct Chip: ViewModifier {
    let style: ChipStyle
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let fill: Color = switch style {
        case .raised: Tok.raise
        case .solid: Tok.fg
        case .accent: Tok.accentSoft
        }
        let raised = style == .raised
        content
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(fill, in: Capsule())
            .overlay(Capsule().strokeBorder(scheme == .dark ? Color.white.opacity(0.08) : Color(hex: 0x5A3C1E, alpha: 0.06),
                                            lineWidth: 0.5).opacity(raised ? 1 : 0))
            .shadow(color: Color(hex: 0x5A3C1E).opacity(raised && scheme == .light ? 0.12 : 0), radius: 7, y: 4)
            .animation(.easeOut(duration: 0.25), value: style)
    }
}

extension View {
    func chip(_ style: ChipStyle) -> some View { modifier(Chip(style: style)) }
}
