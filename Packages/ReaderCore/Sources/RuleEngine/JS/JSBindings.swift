import Foundation
import ReaderModels

/// 可存取变量的对象（书籍、章节、RuleData）
protocol VariableHolder: AnyObject {
    func putVariable(_ key: String, _ value: String?)
    func getVariable(_ key: String) -> String
}

/// 书籍引用。JS 中对 `book` 的修改直接写回这里。
final class BookRef: VariableHolder {
    var book: Book

    init(_ book: Book) { self.book = book }

    func putVariable(_ key: String, _ value: String?) {
        if let value { book.variableMap[key] = value } else { book.variableMap.removeValue(forKey: key) }
    }

    func getVariable(_ key: String) -> String { book.variableMap[key] ?? "" }
}

final class ChapterRef: VariableHolder {
    var chapter: BookChapter

    init(_ chapter: BookChapter) { self.chapter = chapter }

    func putVariable(_ key: String, _ value: String?) {
        if let value { chapter.variableMap[key] = value } else { chapter.variableMap.removeValue(forKey: key) }
    }

    func getVariable(_ key: String) -> String { chapter.variableMap[key] ?? "" }
}

/// 没有书籍时的变量容器（如搜索请求阶段）
final class RuleData: VariableHolder {
    var variables: [String: String] = [:]

    func putVariable(_ key: String, _ value: String?) {
        if let value { variables[key] = value } else { variables.removeValue(forKey: key) }
    }

    func getVariable(_ key: String) -> String { variables[key] ?? "" }
}

/// `java.getString` 等需要访问当前解析器的接口
protocol JSAnalyzerHost: AnyObject {
    var hostRuleData: VariableHolder? { get }
    var hostChapter: ChapterRef? { get }
    func jsGetString(_ rule: String, content: Any?, isUrl: Bool) throws -> String
    func jsGetStringList(_ rule: String, content: Any?, isUrl: Bool) throws -> [String]
    func jsGetElements(_ rule: String) throws -> [Any]
    func jsGetElement(_ rule: String) throws -> Any?
    func jsSetContent(_ content: Any?, baseUrl: String?) throws
    func jsPut(_ key: String, _ value: String) -> String
    func jsGet(_ key: String) -> String
}

/// 单次 JS 执行的绑定变量
struct JSBindings {
    weak var host: JSAnalyzerHost?
    var result: Any?
    var baseUrl: String?
    var src: Any?
    var book: BookRef?
    var chapter: ChapterRef?
    var title: String?
    var nextChapterUrl: String?
    var key: String?
    var page: Int?
    var speakText: String?
    var speakSpeed: Int?
    var extra: [String: Any] = [:]

    init(host: JSAnalyzerHost?) {
        self.host = host
    }

    static let keys = [
        "result", "baseUrl", "src", "book", "chapter", "title", "nextChapterUrl",
        "key", "page", "speakText", "speakSpeed",
    ]
}
