import Foundation
import ReaderModels
@testable import ReaderServices
import RuleEngine

/// 线程安全的请求计数
final class HitCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Int] = [:]

    func hit(_ key: String) { lock.withLock { values[key, default: 0] += 1 } }
    func count(_ key: String) -> Int { lock.withLock { values[key] ?? 0 } }
}

/// 详情、目录、正文都用 JSONPath 规则的书源
func jsonSource(_ host: String = "https://j.test", name: String = "J", extra: String = "") throws -> BookSource {
    try source(host, name, extra: #","searchUrl":"/search?q={{key}}","ruleSearch":{"bookList":"$[*]","name":"$.n","author":"$.a","bookUrl":"$.u"},"ruleBookInfo":{"name":"$.n","author":"$.a","tocUrl":"$.toc","lastChapter":"$.last"},"ruleToc":{"chapterList":"$[*]","chapterName":"$.t","chapterUrl":"$.u"},"ruleContent":{"content":"$.c"}"# + extra)
}

/// 模拟书站：目录可随时替换；正文地址由章节名编码而来，同名章节在目录变化前后地址不变
struct BookServer {
    let transport: StubTransport
    let host: String
    let bookID: Int
    let hits = HitCounter()

    var bookUrl: String { "\(host)/book/\(bookID)" }
    var tocUrl: String { "\(host)/toc/\(bookID)" }

    init(transport: StubTransport, host: String = "https://j.test", bookID: Int = 1, titles: [String]) {
        self.transport = transport
        self.host = host
        self.bookID = bookID
        let hits = hits
        transport.on("\(host)/c/\(bookID)/") { request in
            hits.hit("content")
            let title = BookServer.decode(String(request.url.split(separator: "/").last ?? ""))
            let text = "\(title)\n　　\(title)的第一段，张三。\n　　第二段。"
            let body = try! JSONSerialization.data(withJSONObject: ["c": text])
            return HTTPResponse(url: request.url, headers: ["Content-Type": "application/json"], body: body)
        }
        serveToc(titles)
    }

    func serveToc(_ titles: [String]) {
        let items = titles.map { ["t": $0, "u": "\(host)/c/\(bookID)/\(Self.encode($0))"] }
        let body = try! JSONSerialization.data(withJSONObject: items)
        let hits = hits
        transport.on(tocUrl) { request in
            hits.hit("toc")
            return HTTPResponse(url: request.url, headers: ["Content-Type": "application/json"], body: body)
        }
    }

    func book(origin: String) -> Book {
        var book = Book(bookUrl: bookUrl, origin: origin, name: "测试书", author: "作者")
        book.tocUrl = tocUrl
        return book
    }

    static func encode(_ title: String) -> String {
        Data(title.utf8).map { String(format: "%02x", $0) }.joined()
    }

    static func decode(_ hex: String) -> String {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex), index < hex.endIndex {
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// 轮询直到条件成立（用于等待引擎线程经主线程分发的事件）。
/// 同进程的 WebKit 测试启动网页进程时会阻塞主线程（实测可达十几秒），所以按轮询次数而不是经过的时间计算超时，
/// 阻塞期间不消耗等待时间
@MainActor
func waitUntil(timeout: Duration = .seconds(15), _ condition: () -> Bool) async throws {
    let interval = Duration.milliseconds(20)
    var remaining = Int(timeout / interval)
    while !condition(), remaining > 0 {
        try await Task.sleep(for: interval)
        remaining -= 1
    }
}
