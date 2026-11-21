import ReaderModels
import SwiftUI

/// 书架顶部「继续阅读」卡：封面取色的渐变底 + 漂移色块 + 颗粒（原型 `.hero`）
struct HeroCard: View {
    let book: Book
    @Binding var palette: [Color]
    let onOpen: () -> Void
    let onRead: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var drift = false

    private var h: [Color] { palette.count >= 4 ? palette : ShelfPalette.fallback }

    var body: some View {
        let light = scheme == .light
        let fg = light ? h[1].blend(with: .black, by: 0.18) : .white
        let fg2 = light ? h[1].opacity(0.58) : .white.opacity(0.6)
        let shape = RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)

        HStack(spacing: 22) {
            BookCover(book: book, maxPixel: 420) { colors in
                guard colors.count >= 4, colors != palette else { return }
                withAnimation(.easeOut(duration: 0.8)) { palette = colors }
            }
            .frame(width: 114)
            .coverShadow(lifted: true)
            .zoomSource("hero-\(book.bookUrl)")
            .coverFrame("hero-\(book.bookUrl)")

            VStack(alignment: .leading, spacing: 0) {
                Text(book.chapterLabel)
                    .font(.num(13))
                    .tracking(0.5)
                    .foregroundStyle(fg2)
                    .contentTransition(.numericText())
                Text((ChapterTitle.display(book.durChapterTitle) ?? book.name).withoutEmoji)
                    .font(.serif(25))
                    .lineSpacing(2)
                    .foregroundStyle(fg)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .padding(.top, 6)
                HStack(spacing: 10) {
                    Hairline(value: book.readProgress,
                             track: light ? h[1].opacity(0.14) : .white.opacity(0.16),
                             tint: light ? h[0] : .white.opacity(0.92), height: 3)
                    Text("\(Int((book.readProgress * 100).rounded()))%")
                        .font(.num(12))
                        .foregroundStyle(fg2)
                }
                .padding(.top, 14)
                .padding(.bottom, 18)
                AccentButton(title: book.hasStarted ? "继续阅读" : "开始阅读", icon: "book", frosted: true, action: onRead)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .frame(height: 212)
        .background { background(light: light) }
        .clipShape(shape)
        .overlay(shape.strokeBorder(light ? Color(hex: 0x5A3C1E, alpha: 0.08) : .white.opacity(0.1), lineWidth: 0.5))
        .shadow(color: h[0].opacity(light ? 0.45 : 0.6), radius: light ? 22 : 26, y: light ? 18 : 22)
        .contentShape(shape)
        .onTapGesture(perform: onOpen)
        .onAppear {
            withAnimation(.easeInOut(duration: 18).repeatForever(autoreverses: true)) { drift = true }
        }
    }

    private func background(light: Bool) -> some View {
        ZStack {
            LinearGradient(colors: light
                ? [Color(hex: 0xFDFAF5).blend(with: h[0], by: 0.16), Color(hex: 0xF3EEE6).blend(with: h[2], by: 0.34)]
                : [h[0].blend(with: .black, by: 0.22), h[1].blend(with: .black, by: 0.08)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            GeometryReader { proxy in
                let w = proxy.size.width
                Circle().fill(h[2]).frame(width: 230, height: 230)
                    .opacity(light ? 0.32 : 0.55)
                    .blur(radius: 34)
                    .scaleEffect(drift ? 1.16 : 1)
                    .offset(x: -70 + (drift ? 34 : 0), y: -90 + (drift ? 22 : 0))
                Circle().fill(h[0]).frame(width: 200, height: 200)
                    .opacity(light ? 0.2 : 0.8)
                    .blur(radius: 34)
                    .scaleEffect(drift ? 0.9 : 1.08)
                    .offset(x: w - 150 + (drift ? -22 : 10), y: 212 - 90 + (drift ? 30 : 0))
                Circle().fill(h[3]).frame(width: 130, height: 130)
                    .opacity(light ? 0.7 : 0.18)
                    .blur(radius: 34)
                    .scaleEffect(drift ? 1.1 : 0.94)
                    .offset(x: w - 170 + (drift ? 18 : -10), y: -60 + (drift ? 16 : 0))
            }
            GrainOverlay(opacity: 0.14)
        }
    }
}

enum ShelfPalette {
    static let fallback: [Color] = [Color(hex: 0x6B3A2A), Color(hex: 0x2A1712), Color(hex: 0xC2703F), Color(hex: 0xF1D9B5)]
}

enum ChapterTitle {
    private static let prefix = try? NSRegularExpression(pattern: "^\\s*第\\s*[0-9零一二三四五六七八九十百千万两〇]+\\s*[章节回卷集部篇]\\s*[:：、.]?\\s*")

    /// 去掉开头的「第 N 章」，剩余为空时保留原标题
    static func display(_ title: String?) -> String? {
        guard let title, !title.isEmpty else { return nil }
        let ns = title as NSString
        guard let match = prefix?.firstMatch(in: title, range: NSRange(location: 0, length: ns.length)) else { return title }
        let rest = ns.substring(from: match.range.upperBound).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? title : rest
    }

    private static let numbered = try? NSRegularExpression(pattern: "^\\s*第\\s*([0-9零一二三四五六七八九十百千万两〇]+)\\s*([章节回卷集部篇])")

    /// 标题开头的序号，如「第五百零二章 夜雨」→「第 502 章」
    static func number(_ title: String?) -> String? {
        guard let title, let match = numbered?.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
              let digits = Range(match.range(at: 1), in: title), let unit = Range(match.range(at: 2), in: title),
              let value = Int(title[digits]) ?? chineseNumber(String(title[digits])) else { return nil }
        return "第 \(value) \(title[unit])"
    }

    /// 标题开头的序号数值，如「第五百零二章 夜雨」→ 502
    static func value(_ title: String?) -> Int? {
        guard let title, let match = numbered?.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
              let digits = Range(match.range(at: 1), in: title) else { return nil }
        return Int(title[digits]) ?? chineseNumber(String(title[digits]))
    }

    /// 中文数字：支持「一百零二」「两千三百」「一万二千」，也支持逐位写的「二〇二」
    static func chineseNumber(_ text: String) -> Int? {
        let digits: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
                                        "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        let units: [Character: Int] = ["十": 10, "百": 100, "千": 1000]
        if !text.contains(where: { units[$0] != nil || $0 == "万" }) {
            var value = 0
            for character in text {
                guard let digit = digits[character] else { return nil }
                value = value * 10 + digit
            }
            return value
        }
        var total = 0, section = 0, number = 0
        for character in text {
            if let digit = digits[character] {
                number = digit
            } else if let unit = units[character] {
                section += (number == 0 ? 1 : number) * unit
                number = 0
            } else if character == "万" {
                total += (section + number) * 10000
                section = 0
                number = 0
            } else {
                return nil
            }
        }
        return total + section + number
    }
}

extension Book {
    var hasStarted: Bool { durChapterIndex > 0 || durChapterPos > 0 }

    /// 已读完的章节加上当前章读到的比例；旧数据没有章节长度时只按章计
    var readProgress: Double {
        guard totalChapterNum > 0 else { return 0 }
        let within = durChapterLength > 0 ? min(1, Double(durChapterPos) / Double(durChapterLength)) : 0
        return min(1, (Double(durChapterIndex) + within) / Double(totalChapterNum))
    }

    /// 当前章的序号：优先取章节名里的「第 N 章」，没有时用目录位置
    var chapterLabel: String {
        ChapterTitle.number(durChapterTitle) ?? "第 \(durChapterIndex + 1) 章"
    }

    var isFinished: Bool { totalChapterNum > 0 && durChapterIndex >= totalChapterNum - 1 && hasStarted }
}

extension View {
    /// 记录封面在窗口中的位置，作为开书动画的起点
    func coverFrame(_ key: String) -> some View {
        modifier(CoverFrameRecorder(key: key))
    }
}

private struct CoverFrameRecorder: ViewModifier {
    let key: String
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { app.coverFrames[key] = $0 }
    }
}
