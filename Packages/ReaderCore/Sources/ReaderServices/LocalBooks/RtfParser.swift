import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// RTF：用系统的 NSAttributedString 转为纯文本后按 TXT 规则分章（内嵌图片不保留）
enum RtfParser {
    static func convert(_ url: URL, context: ConversionContext) throws -> ConvertedBook {
        guard let data = try? Data(contentsOf: url) else { throw LocalBookError.fileMissing }
        guard !data.isEmpty else { throw LocalBookError.emptyFile }
        guard data.starts(with: Array("{\\rtf".utf8)),
              let attributed = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                       documentAttributes: nil)
        else { throw LocalBookError.corruptFile("无法解析 RTF 文件") }
        let text = attributed.string.replacingOccurrences(of: "\u{FFFC}", with: "")
        return ConvertedBook(chapters: try ConvertedText.plainChapters(text, rules: context.rules))
    }
}
