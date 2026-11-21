import Foundation
import SwiftSoup

/// HTML / HTM / XHTML 单文件：按 h1–h3 分章，没有标题时按 TXT 目录规则识别。
/// 单个文件没有同目录资源，只保留网络图片与 data URI 内嵌图片（导出为文件）
enum HtmlBookParser {
    static func convert(_ url: URL, context: ConversionContext) throws -> ConvertedBook {
        guard let data = try? Data(contentsOf: url) else { throw LocalBookError.fileMissing }
        guard !data.isEmpty else { throw LocalBookError.emptyFile }
        let head = String(decoding: data.prefix(2048), as: UTF8.self)
        let declared = head.firstMatch(of: /(?i)<meta[^>]+charset\s*=\s*["']?([A-Za-z0-9_\-]+)/).map { String($0.1) }
            ?? head.firstMatch(of: /encoding\s*=\s*["']([A-Za-z0-9_\-]+)["']/).map { String($0.1) }
        let html = ConvertedText.decode(data, declared: declared)
        guard let doc = try? SwiftSoup.parse(html), let body = doc.body() else { throw LocalBookError.corruptFile("无法解析 HTML 文件") }

        var count = 0
        let text = ConvertedText.text(fromBody: body, headingLevels: 1...3) { element in
            let src = ConvertedText.imageSource(element)
            if ConvertedText.isRemote(src) { return src }
            guard let image = ConvertedText.dataURI(src) else { return nil }
            count += 1
            return context.addResource(image, name: "image\(count)")
        }
        var book = ConvertedBook(chapters: try ConvertedText.chapters(text, rules: context.rules))
        book.title = ((try? doc.title()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let author = try? doc.select("meta[name=author]").first()?.attr("content"), !author.isEmpty {
            book.authors = [author]
        }
        if let description = try? doc.select("meta[name=description]").first()?.attr("content"), !description.isEmpty {
            book.intro = description
        }
        return book
    }
}
