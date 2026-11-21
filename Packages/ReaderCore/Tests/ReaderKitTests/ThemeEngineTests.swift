import Foundation
@testable import ReaderKit
import Testing

#if canImport(AppKit)
import AppKit
#endif

@Suite("主题样式表")
struct ThemeStyleSheetTests {
    @Test func 解析正文章头与纸面() {
        let sheet = ReaderStyleSheet(css: """
        /* 注释 */
        :root { --ink: #2b2622; --gap: 30px; }
        body { font: 20px/1.8 "Songti SC", serif; color: var(--ink); letter-spacing: .02em; }
        p { text-indent: 2em; margin-bottom: .6em; text-align: justify; }
        .chap-no { font-size: 13px; color: rgba(0, 0, 0, .45); letter-spacing: .2em; }
        .chap-title { font-size: 1.5em; font-weight: bold; margin-bottom: 34px; }
        .page { background: #F2EBDD url("paper.jpg") cover; padding: var(--gap) 24px 26px; --grain: .5; }
        .footer { display: none; }
        p.dialog { color: #8a5a2b; font-style: italic; }
        """)
        #expect(sheet.diagnostics.isEmpty)
        let style = sheet.resolve(dark: false)
        #expect(style.body.fontFamily == ["Songti SC", "serif"])
        #expect(style.body.fontSize == .px(20))
        #expect(style.body.lineHeight == .number(1.8))
        #expect(style.body.color?.rgb == 0x2B2622)
        #expect(style.body.textIndent == .em(2))
        #expect(style.body.marginBottom == .em(0.6))
        #expect(style.body.textAlign == .justify)
        #expect(style.chapterNumber.color.map { abs($0.alpha - 0.45) < 0.001 } == true)
        #expect(style.chapterTitle.isBold == true)
        #expect(style.chapterTitle.fontSize?.points(fontSize: 20) == 30)
        #expect(style.page.background?.rgb == 0xF2EBDD)
        #expect(style.page.backgroundImage == "paper.jpg")
        #expect(style.page.paddingTop == 30)
        #expect(style.page.paddingLeft == 24)
        #expect(style.page.paddingBottom == 26)
        #expect(style.page.grain == 0.5)
        #expect(style.footer.hidden == true)
        #expect(style.classes["dialog"]?.italic == true)
    }

    @Test func 深浅外观分开() {
        let sheet = ReaderStyleSheet(css: """
        .page { background-color: #fff; }
        @media (prefers-color-scheme: dark) {
          .page { background-color: #111; }
          body { color: #999; }
        }
        """)
        #expect(sheet.resolve(dark: false).page.background?.rgb == 0xFFFFFF)
        #expect(sheet.resolve(dark: false).body.color == nil)
        #expect(sheet.resolve(dark: true).page.background?.rgb == 0x111111)
        #expect(sheet.resolve(dark: true).body.color?.rgb == 0x999999)
    }

    @Test func 不支持的内容记进诊断且不影响其余规则() {
        let sheet = ReaderStyleSheet(css: """
        body { color: #333; float: left; }
        div > span { color: red; }
        @font-face { font-family: x; }
        .header { color: notacolor; font-size: 12px; }
        """)
        let lines = sheet.diagnostics.map(\.line)
        #expect(lines.contains(1))
        #expect(lines.contains(2))
        #expect(lines.contains(3))
        #expect(lines.contains(4))
        let style = sheet.resolve(dark: false)
        #expect(style.body.color?.rgb == 0x333333)
        #expect(style.header.fontSize == .px(12))
    }
}

@Suite("主题脚本")
struct ThemeScriptTests {
    let ctx = ReaderScriptContext(book: "雪中", author: "某人", chapter: "第一章", chapterIndex: 0, chapterCount: 10,
                                  page: 2, pages: 9, percent: 1.5, time: "21:30", battery: 80)

    @Test func 页眉页脚与段落分类() {
        let script = ReaderThemeScript(source: """
        function header(ctx) { return ctx.book + ' · ' + ctx.chapter; }
        function footer(ctx) { return { left: ctx.page + '/' + ctx.pages, right: ctx.time }; }
        function paragraphClass(text, i) { return text.indexOf('“') === 0 ? 'dialog' : null; }
        """)
        #expect(script.error == nil)
        #expect(script.header(ctx) == ReaderChromeText(left: "雪中 · 第一章"))
        #expect(script.footer(ctx) == ReaderChromeText(left: "2/9", right: "21:30"))
        #expect(script.paragraphClasses(["旁白", "“你好。”", "又一句"]) == [1: "dialog"])
    }

    @Test func 语法错误与死循环不会卡住() {
        let broken = ReaderThemeScript(source: "function header( {")
        #expect(broken.error != nil)
        #expect(broken.header(ctx) == nil)

        let loop = ReaderThemeScript(source: "function footer(ctx) { while (true) {} }")
        #expect(loop.error == nil)
        let start = Date()
        #expect(loop.footer(ctx) == nil)
        #expect(Date().timeIntervalSince(start) < 1)
        #expect(loop.isUsable == false)
    }

    @Test func 没有网络与定时器() {
        let script = ReaderThemeScript(source: """
        function header(ctx) { return [typeof fetch, typeof XMLHttpRequest, typeof setTimeout].join(','); }
        """)
        #expect(script.header(ctx)?.left == "undefined,undefined,undefined")
    }
}

@Suite("段落外观")
struct ParagraphLookTests {
    @Test func 类样式只改字形不改行高() {
        var typography = ReaderTypography()
        typography.fontSize = 19
        typography.lineHeight = 1.9
        let content = ChapterPaginator.attributedText(
            title: "", paragraphs: ["旁白一句", "“对话一句”"], typography: typography, textColor: .black, secondaryColor: .gray,
            looks: [1: ParagraphLook(color: .red, italic: true)])
        let text = content.text
        let second = (text.string as NSString).range(of: "“对话一句”")
        #expect(text.attribute(.obliqueness, at: second.location, effectiveRange: nil) as? CGFloat == 0.18)
        #expect(text.attribute(.obliqueness, at: 0, effectiveRange: nil) == nil)
        let style = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        // 1.9 倍行高：固定行高 + 行距 = 36.1
        #expect(abs((style?.minimumLineHeight ?? 0) + (style?.lineSpacing ?? 0) - 36.1) < 0.01)
    }
}
