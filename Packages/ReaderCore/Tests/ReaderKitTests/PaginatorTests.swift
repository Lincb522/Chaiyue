import Foundation
@testable import ReaderKit
import ReaderModels
import Testing

#if canImport(AppKit)
import AppKit
#endif

@Suite("分页")
struct PaginatorTests {
    func makeLayout(paragraphCount: Int) -> ChapterLayout {
        let paragraphs = (0..<paragraphCount).map { i in
            String(repeating: "这是第\(i)段的正文内容，用来测试分页是否连续完整。", count: 4)
        } + ["<img src=\"https://a.com/1.jpg\">"]
        var typography = ReaderTypography()
        typography.fontSize = 18
        let content = ChapterPaginator.attributedText(
            title: "第一章 测试", paragraphs: paragraphs, typography: typography,
            textColor: .black, secondaryColor: .gray
        )
        return ChapterPaginator.layout(chapterIndex: 0, title: "第一章 测试", content: content,
                                       pageSize: CGSize(width: 330, height: 560))
    }

    @Test func 分页连续且覆盖全文() {
        let layout = makeLayout(paragraphCount: 40)
        #expect(layout.pageCount > 3)
        #expect(layout.pageRanges.first?.location == 0)
        for i in 1..<layout.pageCount {
            #expect(layout.pageRanges[i].location == NSMaxRange(layout.pageRanges[i - 1]))
        }
        #expect(NSMaxRange(layout.pageRanges.last!) == layout.length)
        #expect(layout.titleLength == ("第一章 测试\n" as NSString).length)
        #expect(layout.pageText(layout.pageCount - 1).hasSuffix(ChapterPaginator.imagePlaceholder))
    }

    @Test func 按字符偏移定位页码() {
        let layout = makeLayout(paragraphCount: 40)
        #expect(layout.pageIndex(forCharacterOffset: 0) == 0)
        let third = layout.pageRanges[2]
        #expect(layout.pageIndex(forCharacterOffset: third.location) == 2)
        #expect(layout.pageIndex(forCharacterOffset: third.location + 1) == 2)
        #expect(layout.pageIndex(forCharacterOffset: layout.length + 100) == layout.pageCount - 1)
    }

    @Test func 稳定偏移跨页往返() {
        let layout = makeLayout(paragraphCount: 40)
        var previousUpper = 0
        for page in 0..<layout.pageCount {
            let range = layout.stableRange(ofPage: page)
            #expect(range.lowerBound == previousUpper)
            #expect(layout.pageIndex(forStableOffset: range.lowerBound) == page)
            previousUpper = range.upperBound
        }
        #expect(previousUpper == layout.offsets.stableLength)
    }

    @Test func 竖向对齐不改断页且末行贴齐页底() {
        let paragraphs = (0..<60).map { i in
            String(repeating: "第\(i)段，长短不一的正文", count: i % 5 + 1)
        }
        var typography = ReaderTypography()
        typography.fontSize = 19
        typography.lineSpacing = 0.62
        typography.paragraphSpacing = 0.5
        let content = ChapterPaginator.attributedText(title: "第一章 测试", paragraphs: paragraphs, typography: typography,
                                                      textColor: .black, secondaryColor: .gray)
        let size = CGSize(width: 341, height: 640)
        let plain = ChapterPaginator.layout(chapterIndex: 0, title: "", content: content, pageSize: size)
        let justified = ChapterPaginator.layout(chapterIndex: 0, title: "", content: content, pageSize: size, justify: true)
        #expect(plain.pageCount > 3)
        #expect(plain.pageRanges == justified.pageRanges)

        var baselines: [CGFloat] = []
        for page in 0..<(justified.pageCount - 1) {
            let manager = justified.layoutManager
            let glyphs = manager.glyphRange(for: justified.containers[page])
            let last = NSMaxRange(glyphs) - 1
            baselines.append(manager.lineFragmentRect(forGlyphAt: last, effectiveRange: nil).minY + manager.location(forGlyphAt: last).y)
        }
        // 各页末行基线一致，且只比页底高一个下沉
        let spread = (baselines.max() ?? 0) - (baselines.min() ?? 0)
        #expect(spread < 1)
        #expect(size.height - (baselines.min() ?? 0) < 19 * 0.5)

        // 复刻排版（选字层）与原排版行位置一致
        let manager = NSLayoutManager()
        let storage = NSTextStorage(attributedString: justified.text)
        justified.prepare(manager)
        storage.addLayoutManager(manager)
        for page in 0..<justified.pageCount {
            let container = justified.makeContainer(forPage: page)
            manager.addTextContainer(container)
            #expect(manager.glyphRange(for: container) == justified.layoutManager.glyphRange(for: justified.containers[page]))
        }
        let probe = justified.pageRanges[1].location + 30
        #expect(manager.lineFragmentRect(forGlyphAt: probe, effectiveRange: nil)
            == justified.layoutManager.lineFragmentRect(forGlyphAt: probe, effectiveRange: nil))
    }

    @Test func 空章节至少一页() {
        let content = ChapterPaginator.attributedText(
            title: "", paragraphs: [], typography: ReaderTypography(), textColor: .black, secondaryColor: .gray
        )
        let layout = ChapterPaginator.layout(chapterIndex: 0, title: "", content: content,
                                             pageSize: CGSize(width: 300, height: 500))
        #expect(layout.pageCount == 1)
        #expect(layout.stableRange(ofPage: 0) == 0..<0)
    }
}

private func picture(_ width: CGFloat, _ height: CGFloat) -> PlatformImage {
    #if canImport(AppKit)
    NSImage(size: NSSize(width: width, height: height))
    #else
    UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { _ in }
    #endif
}

@Suite("正文插图排版")
struct InlineImageLayoutTests {
    let pageSize = CGSize(width: 300, height: 500)

    func content(_ paragraphs: [String], maxImageSize: CGSize? = nil,
                 images: [String: PlatformImage]) -> ChapterAttributedText {
        ChapterPaginator.attributedText(title: "第一章", paragraphs: paragraphs, typography: ReaderTypography(),
                                        textColor: .black, secondaryColor: .gray, maxImageSize: maxImageSize ?? pageSize,
                                        image: { images[$0] })
    }

    func attachments(_ text: NSAttributedString) -> [NSTextAttachment] {
        var result: [NSTextAttachment] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let attachment = value as? NSTextAttachment { result.append(attachment) }
        }
        return result
    }

    @Test func 按比例缩放且小图不放大() throws {
        let built = content(["甲", "<img src=\"wide\">", "<img src=\"small\">", "<img src=\"tall\">", "<img src=\"none\">"],
                            images: ["wide": picture(600, 400), "small": picture(100, 50), "tall": picture(200, 2000)])
        let items = attachments(built.text)
        #expect(items.count == 3)
        #expect(items[0].bounds.size == CGSize(width: 300, height: 200))
        #expect(items[1].bounds.size == CGSize(width: 100, height: 50))
        let tall = items[2].bounds.size
        #expect(tall.height < pageSize.height - 17 && tall.height > pageSize.height - 120)
        #expect(abs(tall.width / tall.height - 0.1) < 0.01)
        // 取不到的图片显示占位文字
        #expect(built.text.string.hasSuffix(ChapterPaginator.imagePlaceholder))
        // 图片段落单独成段、居中
        let style = try #require(built.text.attribute(.paragraphStyle, at: ("第一章\n甲\n" as NSString).length,
                                                      effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.alignment == .center && style.firstLineHeadIndent == 0)
    }

    @Test func 图片只占一个字符_进度落在段首() {
        // 稳定文本："甲乙\n<img src=\"x\">\n丙"（2 + 1 + 13 + 1 + 1 = 18）；排版文本："第一章\n甲乙\n\u{FFFC}\n丙"（4 + 2 + 1 + 1 + 1 + 1 = 10）
        let map = content(["甲乙", "<img src=\"x\">", "丙"], images: ["x": picture(50, 50)]).offsets
        #expect(map.stableLength == 18 && map.layoutLength == 10)
        #expect(map.layoutOffset(forStable: 3) == 7)
        #expect(map.layoutOffset(forStable: 9) == 7)
        #expect(map.layoutOffset(forStable: 16) == 8)
        #expect(map.layoutOffset(forStable: 17) == 9)
        #expect(map.stableOffset(forLayout: 7) == 3)
        #expect(map.stableOffset(forLayout: 8) == 16)
    }

    @Test func 超高图片分页时缩到一页内_不丢后续文字() {
        let paragraphs = ["<img src=\"huge\">"] + (0..<30).map { "第\($0)段，" + String(repeating: "正文", count: 30) }
        let built = content(paragraphs, maxImageSize: .zero, images: ["huge": picture(1000, 5000)])
        #expect(attachments(built.text).first?.bounds.height == 5000)
        let layout = ChapterPaginator.layout(chapterIndex: 0, title: "第一章", content: built, pageSize: pageSize)
        #expect(attachments(built.text).first.map { $0.bounds.height < pageSize.height } == true)
        #expect(layout.pageCount > 2)
        #expect(NSMaxRange(layout.pageRanges.last!) == layout.length)
        for i in 1..<layout.pageCount {
            #expect(layout.pageRanges[i].location == NSMaxRange(layout.pageRanges[i - 1]))
        }
    }

    @Test func 滚动模式测量包含图片高度() {
        let built = content(["<img src=\"x\">"], images: ["x": picture(600, 400)])
        let rect = built.text.boundingRect(with: CGSize(width: pageSize.width, height: .greatestFiniteMagnitude),
                                           options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        #expect(rect.height >= 200)
    }
}

@Suite("稳定偏移")
struct TextOffsetMapTests {
    // 稳定文本："甲乙丙\n<img src="x">\n丁戊"（3 + 1 + 13 + 1 + 2 = 20）
    // 排版文本："第一章 测试\n甲乙丙\n［图片］\n丁戊"（7 + 3 + 1 + 4 + 1 + 2 = 18）
    let map = ChapterPaginator.attributedText(
        title: "第一章 测试", paragraphs: ["甲乙丙", "<img src=\"x\">", "丁戊"], typography: ReaderTypography(),
        textColor: .black, secondaryColor: .gray
    ).offsets

    @Test func 长度() {
        #expect(map.titleLength == 7)
        #expect(map.stableLength == 20)
        #expect(map.layoutLength == 18)
    }

    @Test func 稳定到排版() {
        #expect(map.layoutOffset(forStable: 0) == 7)
        #expect(map.layoutOffset(forStable: 2) == 9)
        #expect(map.layoutOffset(forStable: 3) == 10)
        #expect(map.layoutOffset(forStable: 4) == 11)
        #expect(map.layoutOffset(forStable: 10) == 11)
        #expect(map.layoutOffset(forStable: 17) == 15)
        #expect(map.layoutOffset(forStable: 18) == 16)
        #expect(map.layoutOffset(forStable: 20) == 18)
        #expect(map.layoutOffset(forStable: 999) == 18)
        #expect(map.layoutOffset(forStable: -5) == 7)
    }

    @Test func 排版到稳定() {
        #expect(map.stableOffset(forLayout: 0) == 0)
        #expect(map.stableOffset(forLayout: 5) == 0)
        #expect(map.stableOffset(forLayout: 9) == 2)
        #expect(map.stableOffset(forLayout: 11) == 4)
        #expect(map.stableOffset(forLayout: 13) == 4)
        #expect(map.stableOffset(forLayout: 15) == 17)
        #expect(map.stableOffset(forLayout: 16) == 18)
        #expect(map.stableOffset(forLayout: 18) == 20)
        #expect(map.stableOffset(forLayout: 999) == 20)
    }
}

@Suite("段评气泡与点按")
struct ParagraphCommentLayoutTests {
    let comment = ParagraphComment(count: "120", action: "java.showReadingBrowser('u','段评')")
    let pageSize = CGSize(width: 330, height: 560)

    func content(badge: Bool) -> ChapterAttributedText {
        ChapterPaginator.attributedText(
            title: "第一章", paragraphs: ["甲乙丙", "丁戊"], typography: ReaderTypography(),
            textColor: .black, secondaryColor: .gray, maxImageSize: pageSize,
            extras: [0: ParagraphExtras(comment: comment)],
            commentBadge: badge ? { _ in picture(30, 14) } : nil
        )
    }

    /// 第一个附件字符在第一页的位置
    func attachmentRect(_ layout: ChapterLayout, _ built: ChapterAttributedText) -> CGRect {
        var range = NSRange(location: NSNotFound, length: 0)
        built.text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: built.text.length)) { value, found, stop in
            if value != nil { range = found; stop.pointee = true }
        }
        let glyphs = layout.layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return layout.layoutManager.boundingRect(forGlyphRange: glyphs, in: layout.containers[0])
    }

    @Test func 气泡不占稳定偏移() {
        // 排版文本："第一章\n甲乙丙[气泡]\n丁戊"
        let map = content(badge: true).offsets
        #expect(map.stableLength == 6)
        #expect(map.layoutLength == 4 + 4 + 1 + 2)
        #expect(map.layoutOffset(forStable: 3) == 7)
        #expect(map.layoutOffset(forStable: 4) == 9)
        #expect(map.stableOffset(forLayout: 7) == 3)
        #expect(map.stableOffset(forLayout: 8) == 3)
        #expect(map.stableOffset(forLayout: 9) == 4)

        // 关闭段评时没有气泡
        let plain = content(badge: false).offsets
        #expect(plain.layoutLength == 4 + 3 + 1 + 2)
    }

    @Test func 点按气泡命中段评() throws {
        let built = content(badge: true)
        let layout = ChapterPaginator.layout(chapterIndex: 0, title: "第一章", content: built, pageSize: pageSize)
        let rect = attachmentRect(layout, built)
        #expect(layout.tapTarget(at: CGPoint(x: rect.midX, y: rect.midY), page: 0) == .comment(comment))
        #expect(layout.tapTarget(at: CGPoint(x: rect.maxX + 4, y: rect.midY), page: 0) == .comment(comment))
        #expect(layout.tapTarget(at: CGPoint(x: 2, y: pageSize.height - 2), page: 0) == nil)
    }

    @Test func 动作图片可点按() {
        let src = #"https://a.test/card.svg,{"style":"FULL","js":"showCmt('u')"}"#
        let built = ChapterPaginator.attributedText(
            title: "", paragraphs: ["<img src=\"\(src)\">"], typography: ReaderTypography(),
            textColor: .black, secondaryColor: .gray, maxImageSize: pageSize,
            image: { _ in picture(100, 20) }
        )
        let layout = ChapterPaginator.layout(chapterIndex: 0, title: "", content: built, pageSize: pageSize)
        let rect = attachmentRect(layout, built)
        // FULL 铺满正文宽度
        #expect(abs(rect.width - pageSize.width) < 12)
        #expect(layout.tapTarget(at: CGPoint(x: rect.midX, y: rect.midY), page: 0) == .image(source: src, action: "showCmt('u')"))
    }
}
