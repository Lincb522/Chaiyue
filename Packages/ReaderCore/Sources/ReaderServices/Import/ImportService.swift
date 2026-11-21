import Foundation
import ReaderModels

/// 识别出的导入内容
public enum ImportPayload: Sendable {
    case bookSources([BookSource])
    case replaceRules([ReplaceRule])
    case httpTTS([HttpTTS])

    public var count: Int {
        switch self {
        case .bookSources(let items): items.count
        case .replaceRules(let items): items.count
        case .httpTTS(let items): items.count
        }
    }

    public var kindName: String {
        switch self {
        case .bookSources: "书源"
        case .replaceRules: "替换规则"
        case .httpTTS: "朗读源"
        }
    }
}

public enum ImportError: LocalizedError, Equatable, Sendable {
    case notJSON
    case empty
    case unsupported(String)
    case badLink
    case download(String)

    public var errorDescription: String? {
        switch self {
        case .notJSON: "内容不是有效的 JSON"
        case .empty: "没有可导入的内容"
        case .unsupported(let kind): "暂不支持导入\(kind)"
        case .badLink: "链接格式不正确，缺少 src 参数"
        case .download(let message): "下载失败：\(message)"
        }
    }
}

public enum ImportService {
    /// 按内容识别导入类型（与链接的 host/path 无关）
    public static func classify(_ data: Data) throws -> ImportPayload {
        var payload = data
        if payload.starts(with: [0xEF, 0xBB, 0xBF]) { payload = payload.dropFirst(3) }
        guard let json = try? JSONSerialization.jsonObject(with: payload, options: [.fragmentsAllowed]) else {
            throw ImportError.notJSON
        }
        let sample: [String: Any]?
        if let array = json as? [Any] {
            sample = array.lazy.compactMap { $0 as? [String: Any] }.first
        } else {
            sample = json as? [String: Any]
        }
        guard let sample else { throw ImportError.empty }

        if sample["bookSourceUrl"] != nil {
            let items = try SourceImport.bookSources(from: payload)
            guard !items.isEmpty else { throw ImportError.empty }
            return .bookSources(items)
        }
        if sample["pattern"] != nil, sample["replacement"] != nil {
            let items = try SourceImport.replaceRules(from: payload)
            guard !items.isEmpty else { throw ImportError.empty }
            return .replaceRules(items)
        }
        if sample["sourceUrl"] != nil {
            throw ImportError.unsupported("订阅源")
        }
        if sample["url"] != nil, sample["name"] != nil {
            let items = try SourceImport.httpTTS(from: payload)
            guard !items.isEmpty else { throw ImportError.empty }
            return .httpTTS(items)
        }
        throw ImportError.unsupported("该类型的数据")
    }

    /// 识别文本：网址、一键导入链接或 JSON
    public static func classify(text: String) async throws -> ImportPayload {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ImportError.empty }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
            if scheme == "http" || scheme == "https" {
                return try classify(try await download(url))
            }
            if let src = sourceURL(fromLink: url) {
                return try classify(try await download(src))
            }
        }
        return try classify(Data(trimmed.utf8))
    }

    /// 解析一键导入链接中的 `src` 参数，例如 `yuedu://booksource/importonline?src=…`
    public static func sourceURL(fromLink url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let src = components.queryItems?.first(where: { $0.name == "src" })?.value,
              !src.isEmpty
        else { return nil }
        if let direct = URL(string: src), direct.scheme != nil { return direct }
        let encoded = src.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.union(["#", "%"]))
        return encoded.flatMap(URL.init(string:))
    }

    public static func download(_ url: URL, timeout: TimeInterval = 30) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
                         forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw ImportError.download("HTTP \(http.statusCode)")
            }
            return data
        } catch let error as ImportError {
            throw error
        } catch {
            throw ImportError.download(error.localizedDescription)
        }
    }
}
