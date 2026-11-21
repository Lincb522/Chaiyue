import Foundation
import RuleEngine

/// WebDAV 网盘配置。`url` 为 WebDAV 根目录，备份文件放在其下的 `directory` 中
public struct WebDAVConfig: Codable, Hashable, Sendable, Identifiable {
    public static let defaultDirectory = "ReaderBackup"

    public var id: UUID
    public var name: String
    public var url: String
    public var username: String
    public var password: String
    public var directory: String

    public init(id: UUID = UUID(), name: String = "", url: String, username: String, password: String,
                directory: String = WebDAVConfig.defaultDirectory) {
        self.id = id
        self.name = name
        self.url = url
        self.username = username
        self.password = password
        self.directory = directory
    }

    /// 名称为空时显示服务器主机名
    public var displayName: String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        return URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines))?.host ?? url
    }
}

public struct WebDAVItem: Hashable, Sendable {
    /// 相对备份目录的路径，目录不带结尾的 `/`
    public var path: String
    public var isDirectory: Bool
    public var size: Int64?
    public var modified: Date?
}

public enum WebDAVError: LocalizedError, Sendable, Equatable {
    case invalidURL
    case unauthorized
    case httpStatus(Int)
    case notReachable(String)
    case cannotCreateDirectory
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "WebDAV 地址无效"
        case .unauthorized: "用户名或密码错误"
        case .httpStatus(let code): "WebDAV 服务器返回错误（HTTP \(code)）"
        case .notReachable(let reason): "无法连接 WebDAV 服务器：\(reason)"
        case .cannotCreateDirectory: "备份目录不存在且无法创建"
        case .invalidResponse: "无法解析 WebDAV 服务器的响应"
        }
    }
}

/// WebDAV 客户端（Basic 认证）。路径都相对于备份目录 `config.directory`
public struct WebDAVClient: Sendable {
    /// 校验服务器证书：请求带账号密码，不能像书源那样信任所有证书
    public static let defaultTransport: any HTTPTransport = URLSessionTransport(trustsAllCertificates: false)

    public let config: WebDAVConfig
    private let transport: any HTTPTransport

    public init(config: WebDAVConfig, transport: any HTTPTransport = WebDAVClient.defaultTransport) {
        self.config = config
        self.transport = transport
    }

    /// 备份目录地址（以 `/` 结尾）；服务器地址无效时为 nil
    public var rootURL: String? {
        try? url(directoryParts, isDirectory: true)
    }

    /// 检查服务器地址与账号（PROPFIND 服务器根目录）
    public func testConnection() async throws {
        let response = try await send("PROPFIND", try baseURL(), headers: Self.propfindHeaders(depth: "0"), body: Self.propfindBody)
        try Self.check(response)
    }

    /// 目录下的文件与子目录（不含目录本身）；目录不存在时返回空
    public func list(_ path: String = "") async throws -> [WebDAVItem] {
        let parts = Self.components(path)
        let requestURL = try url(directoryParts + parts, isDirectory: true)
        let response = try await send("PROPFIND", requestURL, headers: Self.propfindHeaders(depth: "1"), body: Self.propfindBody)
        if response.statusCode == 404 { return [] }
        try Self.check(response)
        let entries = try WebDAVPropfindParser.parse(response.body)
        let base = Self.collectionHref(of: entries) ?? Self.normalizedHref(requestURL)
        let prefix = parts.isEmpty ? "" : parts.joined(separator: "/") + "/"
        return entries.compactMap { entry in
            let href = Self.normalizedHref(entry.href)
            guard href.count > base.count, href.hasPrefix(base) else { return nil }
            let name = href.dropFirst(base.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !name.isEmpty, !name.contains("/") else { return nil }
            return WebDAVItem(path: prefix + name, isDirectory: entry.isCollection, size: entry.size, modified: entry.modified)
        }
    }

    /// 递归列出目录下的全部文件（逐级 Depth 1，很多服务器禁用了 Depth infinity）
    public func listTree(_ path: String = "") async throws -> [WebDAVItem] {
        var files: [WebDAVItem] = []
        var pending = [Self.components(path).joined(separator: "/")]
        var visited = Set<String>()
        while let directory = pending.popLast() {
            guard visited.insert(directory).inserted else { continue }
            for item in try await list(directory) {
                if item.isDirectory {
                    pending.append(item.path)
                } else {
                    files.append(item)
                }
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    /// 下载文件；文件不存在时返回 nil
    public func download(_ path: String) async throws -> Data? {
        let response = try await send("GET", try url(directoryParts + Self.components(path)))
        if response.statusCode == 404 { return nil }
        try Self.check(response)
        return response.body
    }

    /// 上传文件，所在目录需已存在（见 `makeDirectory`）
    public func upload(_ data: Data, to path: String) async throws {
        let response = try await send("PUT", try url(directoryParts + Self.components(path)),
                                      headers: ["Content-Type": "application/octet-stream"], body: data)
        try Self.check(response)
    }

    public func upload(fileAt fileURL: URL, to path: String) async throws {
        let data = try await offload { try Data(contentsOf: fileURL, options: .mappedIfSafe) }
        try await upload(data, to: path)
    }

    /// 删除文件或目录；不存在时视为成功
    public func delete(_ path: String) async throws {
        let response = try await send("DELETE", try url(directoryParts + Self.components(path)))
        if response.statusCode == 404 { return }
        try Self.check(response)
    }

    /// 逐级创建备份目录及其下的 `path`
    public func makeDirectory(_ path: String = "") async throws {
        let parts = directoryParts + Self.components(path)
        for level in parts.indices {
            try await createCollection(Array(parts[...level]))
        }
    }

    /// 创建一级目录（`parts` 从服务器根目录算起）。已存在时部分服务器返回 405 以外的状态码，再用 PROPFIND 确认
    func createCollection(_ parts: [String]) async throws {
        let target = try url(parts, isDirectory: true)
        let response = try await send("MKCOL", target)
        if (200..<300).contains(response.statusCode) || response.statusCode == 405 { return }
        let probe = try await send("PROPFIND", target, headers: Self.propfindHeaders(depth: "0"), body: Self.propfindBody)
        guard (200..<300).contains(probe.statusCode) else { throw WebDAVError.cannotCreateDirectory }
    }

    var directoryParts: [String] { Self.components(config.directory) }

    // MARK: - 请求

    private func send(_ method: String, _ url: String, headers: [String: String] = [:], body: Data? = nil) async throws -> HTTPResponse {
        var headers = headers
        if !config.username.isEmpty || !config.password.isEmpty {
            headers["Authorization"] = "Basic " + Data("\(config.username):\(config.password)".utf8).base64EncodedString()
        }
        let request = HTTPRequest(url: url, method: method, headers: headers, body: body, timeout: 60)
        let transport = transport
        let response: HTTPResponse
        do {
            response = try await offload { try transport.send(request) }
        } catch {
            throw WebDAVError.notReachable(error.localizedDescription)
        }
        if response.statusCode == 401 { throw WebDAVError.unauthorized }
        return response
    }

    private static func check(_ response: HTTPResponse) throws {
        guard (200..<300).contains(response.statusCode) else { throw WebDAVError.httpStatus(response.statusCode) }
    }

    private static let propfindBody = Data(#"<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>"#.utf8)

    private static func propfindHeaders(depth: String) -> [String: String] {
        ["Depth": depth, "Content-Type": "application/xml; charset=utf-8"]
    }

    // MARK: - 地址

    /// 服务器根目录（以 `/` 结尾）
    private func baseURL() throws -> String {
        let trimmed = config.url.trimmingCharacters(in: .whitespacesAndNewlines)
        let encoded = URL(string: trimmed)?.absoluteString
            ?? trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? trimmed
        guard let components = URLComponents(string: encoded), let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https", components.host?.isEmpty == false else {
            throw WebDAVError.invalidURL
        }
        return encoded.hasSuffix("/") ? encoded : encoded + "/"
    }

    private func url(_ parts: [String], isDirectory: Bool = false) throws -> String {
        let encoded = parts.map { $0.addingPercentEncoding(withAllowedCharacters: Self.segmentAllowed) ?? $0 }
        let url = try baseURL() + encoded.joined(separator: "/")
        return isDirectory && !parts.isEmpty ? url + "/" : url
    }

    private static let segmentAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/;")
        return set
    }()

    static func components(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init).filter { $0 != "." && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// href 统一为解码后的路径并以 `/` 结尾；服务器可能返回完整地址或路径、编码方式也不一致
    static func normalizedHref(_ href: String) -> String {
        var path = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: path), components.host != nil {
            path = components.percentEncodedPath
        } else if let range = path.range(of: "://") {
            let rest = path[range.upperBound...]
            path = rest.firstIndex(of: "/").map { String(rest[$0...]) } ?? "/"
        }
        path = path.removingPercentEncoding ?? path
        return path.hasSuffix("/") ? path : path + "/"
    }

    /// 请求的目录本身：其余条目的 href 都以它开头。用它计算子项名称，兼容反向代理改写了路径前缀的服务器
    static func collectionHref(of entries: [WebDAVPropfindParser.Entry]) -> String? {
        let hrefs = entries.map { normalizedHref($0.href) }
        guard let shortest = hrefs.min(by: { $0.count < $1.count }), hrefs.allSatisfy({ $0.hasPrefix(shortest) }) else {
            return nil
        }
        return entries.count == 1 && entries[0].isCollection == false ? nil : shortest
    }
}

/// 解析 PROPFIND 的 multistatus 响应（按本地名匹配，不依赖命名空间前缀）
final class WebDAVPropfindParser: NSObject, XMLParserDelegate {
    struct Entry: Sendable {
        var href = ""
        var isCollection = false
        var size: Int64?
        var modified: Date?
    }

    private var entries: [Entry] = []
    private var current: Entry?
    private var text = ""
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    static func parse(_ data: Data) throws -> [Entry] {
        let delegate = WebDAVPropfindParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        guard parser.parse() else { throw WebDAVError.invalidResponse }
        return delegate.entries
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        text = ""
        switch elementName.lowercased() {
        case "response": current = Entry()
        case "collection": current?.isCollection = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName.lowercased() {
        case "href":
            if current?.href.isEmpty == true { current?.href = value }
        case "getcontentlength":
            if let size = Int64(value) { current?.size = size }
        case "getlastmodified":
            if let date = dateFormatter.date(from: value) { current?.modified = date }
        case "response":
            if let current, !current.href.isEmpty { entries.append(current) }
            current = nil
        default:
            break
        }
        text = ""
    }
}
