import Foundation
import ReaderModels
@testable import ReaderServices
import RuleEngine
import Testing
import ZIPFoundation

/// 内存中的 WebDAV 服务器：校验 Basic 认证，支持 PROPFIND（Depth 0/1）、MKCOL、PUT、GET、DELETE。
/// 目录的 href 返回完整地址、文件返回路径，覆盖两种常见形式
final class MemoryWebDAV: HTTPTransport, @unchecked Sendable {
    static let host = "https://dav.test"
    static let directory = "阅读 备份/测试"

    let username = "reader"
    let password = "密码 123"
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var directories: Set<String> = ["/dav"]
    private var log: [String] = []
    private var failingSuffix: String?
    private var offline = false

    func config(directory: String = MemoryWebDAV.directory, password: String? = nil) -> WebDAVConfig {
        WebDAVConfig(url: Self.host + "/dav", username: username, password: password ?? self.password, directory: directory)
    }

    var requests: [String] { lock.withLock { log } }

    func failUploads(endingWith suffix: String?) {
        lock.withLock { failingSuffix = suffix }
    }

    func setOffline(_ value: Bool) {
        lock.withLock { offline = value }
    }

    func removeAll() {
        lock.withLock {
            files = [:]
            directories = ["/dav"]
        }
    }

    /// 备份目录下全部文件的相对路径
    func remotePaths(directory: String = MemoryWebDAV.directory) -> Set<String> {
        let prefix = "/dav/\(directory)/"
        return lock.withLock { Set(files.keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }) }
    }

    func directoryExists(_ path: String, directory: String = MemoryWebDAV.directory) -> Bool {
        lock.withLock { directories.contains("/dav/\(directory)/\(path)") }
    }

    /// 在服务器根目录下放一个与备份无关的文件，自动创建上级目录
    func addFile(_ path: String) {
        lock.withLock {
            var current = "/dav"
            for part in path.split(separator: "/").dropLast() {
                current += "/\(part)"
                directories.insert(current)
            }
            files["/dav/\(path)"] = Data("x".utf8)
        }
    }

    func fileExists(_ path: String) -> Bool {
        lock.withLock { files["/dav/\(path)"] != nil }
    }

    func send(_ request: HTTPRequest) throws -> HTTPResponse {
        let (offline, failing) = lock.withLock { (self.offline, failingSuffix) }
        if offline { throw RuleError.network("网络不可用") }
        let auth = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        guard request.headers["Authorization"] == auth else { return status(request, 401) }
        guard request.url.hasPrefix(Self.host), var path = URLComponents(string: request.url)?.path else { return status(request, 404) }
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return lock.withLock {
            log.append("\(request.method) \(path)")
            switch request.method {
            case "PROPFIND":
                return propfind(request, path)
            case "MKCOL":
                if directories.contains(path) || files[path] != nil { return status(request, 405) }
                guard directories.contains(parent(path)) else { return status(request, 409) }
                directories.insert(path)
                return status(request, 201)
            case "PUT":
                guard directories.contains(parent(path)) else { return status(request, 409) }
                if let failing, path.hasSuffix(failing) { return status(request, 507) }
                files[path] = request.body ?? Data()
                return status(request, 201)
            case "GET":
                guard let data = files[path] else { return status(request, 404) }
                return HTTPResponse(url: request.url, body: data)
            case "DELETE":
                if files.removeValue(forKey: path) != nil { return status(request, 204) }
                guard directories.contains(path) else { return status(request, 404) }
                directories = directories.filter { $0 != path && !$0.hasPrefix(path + "/") }
                files = files.filter { !$0.key.hasPrefix(path + "/") }
                return status(request, 204)
            default:
                return status(request, 405)
            }
        }
    }

    private func propfind(_ request: HTTPRequest, _ path: String) -> HTTPResponse {
        var entries: [(path: String, isDirectory: Bool, size: Int)] = []
        if directories.contains(path) {
            entries.append((path, true, 0))
            if request.headers["Depth"] == "1" {
                entries += directories.filter { $0 != path && parent($0) == path }.sorted().map { ($0, true, 0) }
                entries += files.filter { parent($0.key) == path }.sorted { $0.key < $1.key }.map { ($0.key, false, $0.value.count) }
            }
        } else if let data = files[path] {
            entries.append((path, false, data.count))
        } else {
            return status(request, 404)
        }
        let body = entries.map { entry in
            let href = entry.isDirectory ? Self.host + encode(entry.path) + "/" : encode(entry.path)
            let props = entry.isDirectory
                ? "<D:resourcetype><D:collection/></D:resourcetype>"
                : "<D:resourcetype/><D:getcontentlength>\(entry.size)</D:getcontentlength>"
            return "<D:response><D:href>\(href)</D:href><D:propstat><D:prop>\(props)"
                + "<D:getlastmodified>Sat, 07 Nov 2026 08:00:00 GMT</D:getlastmodified></D:prop>"
                + "<D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"
        }.joined()
        let xml = #"<?xml version="1.0" encoding="utf-8"?><D:multistatus xmlns:D="DAV:">"# + body + "</D:multistatus>"
        return HTTPResponse(url: request.url, statusCode: 207, headers: ["Content-Type": "application/xml"], body: Data(xml.utf8))
    }

    private func encode(_ path: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return path.split(separator: "/").map { "/" + ($0.addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0)) }.joined()
    }

    private func parent(_ path: String) -> String {
        path.lastIndex(of: "/").map { String(path[..<$0]) } ?? ""
    }

    private func status(_ request: HTTPRequest, _ code: Int) -> HTTPResponse {
        HTTPResponse(url: request.url, statusCode: code, body: Data())
    }
}

@MainActor
final class ProgressRecorder {
    var items: [BackupProgress] = []
}

private let paragraph = "　　风吹过山岗，河水静静流淌。\n"

private func chapterText(_ titles: [String]) -> String {
    titles.map { $0 + "\n" + String(repeating: paragraph, count: 80) }.joined()
}

private func writeZip(_ files: [(String, Data)]) throws -> URL {
    let url = tempDirectory().appendingPathComponent("backup.zip")
    let archive = try Archive(url: url, accessMode: .create)
    for (path, data) in files {
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, size in
            data.subdata(in: Int(position)..<Int(position) + size)
        }
    }
    return url
}

private func temporaryDefaults() throws -> (UserDefaults, String) {
    let name = "ReaderServicesTests.Backup.\(UUID().uuidString)"
    return (try #require(UserDefaults(suiteName: name)), name)
}

@MainActor
private func makeServices(_ data: URL = tempDirectory()) -> LibraryServices {
    LibraryServices(dataDirectory: data, cacheDirectory: tempDirectory(), http: StubTransport())
}

/// 各类别都有数据：两个书源、替换规则、自定义与停用的目录规则、两本网络书（进度、分组、置顶）、书签、搜索历史、一本本地 TXT
@MainActor
@discardableResult
private func populate(_ services: LibraryServices) async throws -> Book {
    services.sources.importSources([try source("https://a.test", "甲源"),
                                    try source("https://b.test", "乙源", extra: #","bookSourceGroup":"常用""#)])
    var rule = ReplaceRule(id: 7, name: "去广告", pattern: "广告", replacement: "")
    rule.order = 1
    services.replaceRules.importRules([rule])
    services.txtTocRules.save(TxtTocRule(id: 0, name: "卷标题", rule: "^卷.+$"))
    services.txtTocRules.setEnabled(false, for: [-1])
    let group = try #require(services.shelf.addGroup("在读"))
    var first = Book(bookUrl: "https://a.test/book/1", origin: "https://a.test", name: "第一本", author: "甲")
    first.durChapterIndex = 3
    first.durChapterPos = 120
    first.durChapterTitle = "第四章"
    first.group = group.groupId
    services.shelf.add(first)
    services.shelf.add(Book(bookUrl: "https://b.test/book/2", origin: "https://b.test", name: "第二本", author: "乙"))
    services.shelf.togglePin(first.bookUrl)
    services.shelf.addBookmark(Bookmark(time: 1, bookName: "第一本", bookAuthor: "甲", chapterIndex: 3, chapterPos: 120,
                                        chapterName: "第四章", bookText: "一句话"))
    services.searchHistory.record("旧词")
    services.searchHistory.record("新词")
    services.httpTTS.importEngines([HttpTTS(id: 9, name: "朗读", url: "https://tts.test/?t={{speakText}}")])

    let file = tempDirectory().appendingPathComponent("《本地》作者：某人.txt")
    try Data(chapterText(["第一章 开端", "第二章 发展", "第三章 结局"]).utf8).write(to: file)
    var local = try await services.importLocalBook(at: file)
    local.durChapterIndex = 1
    local.durChapterPos = 8
    services.shelf.update(local)
    return local
}

@Suite("本地备份与恢复")
@MainActor
struct LocalBackupTests {
    @Test func 完整备份恢复并覆盖现有数据() async throws {
        let a = makeServices()
        let local = try await populate(a)
        let keys = ["theme", "fontSize"]
        let (defaultsA, nameA) = try temporaryDefaults()
        defer { defaultsA.removePersistentDomain(forName: nameA) }
        defaultsA.set("dark", forKey: "theme")
        defaultsA.set(18, forKey: "fontSize")
        a.backup.register(.userDefaults(keys: keys, defaults: defaultsA))
        a.backup.deviceName = "测试机"

        let archive = try await a.backup.exportArchive(categories: Set(a.backup.categories), to: tempDirectory())
        #expect(archive.pathExtension == "zip" && archive.lastPathComponent.hasPrefix("备份_"))

        let b = makeServices()
        b.sources.importSources([try source("https://old.test", "旧书源")])
        b.shelf.add(Book(bookUrl: "https://old.test/book", origin: "https://old.test", name: "旧书", author: "某人"))
        b.searchHistory.record("会被覆盖")
        let (defaultsB, nameB) = try temporaryDefaults()
        defer { defaultsB.removePersistentDomain(forName: nameB) }
        defaultsB.set("light", forKey: "theme")
        defaultsB.set(true, forKey: "deviceOnly")
        b.backup.register(.userDefaults(keys: keys, defaults: defaultsB))

        let package = try await b.backup.openArchive(at: archive)
        defer { package.discard() }
        let manifest = package.manifest
        #expect(manifest.version == BackupManifest.currentVersion && manifest.deviceName == "测试机")
        #expect(manifest.deviceId == a.backup.deviceId && manifest.includesLocalBooks)
        #expect(manifest.counts == ["bookshelf": 3, "bookmarks": 1, "bookSources": 2, "replaceRules": 1, "txtTocRules": 1,
                                    "searchHistory": 2, "httpTTS": 1, "localBooks": 1, "settings": 2])

        let result = try await b.backup.restore(package)
        #expect(Set(result.restored.keys) == Set(a.backup.categories))
        #expect(b.sources.sources == a.sources.sources)
        #expect(b.shelf.books == a.shelf.books)
        #expect(b.shelf.groups == a.shelf.groups && b.shelf.pinned == a.shelf.pinned)
        #expect(b.shelf.bookmarks == a.shelf.bookmarks)
        #expect(b.replaceRules.rules == a.replaceRules.rules)
        #expect(b.httpTTS.engines == a.httpTTS.engines && b.httpTTS.engines.count == 1)
        #expect(b.txtTocRules.rules == a.txtTocRules.rules)
        #expect(b.searchHistory.keywords == ["新词", "旧词"])
        #expect(defaultsB.string(forKey: "theme") == "dark" && defaultsB.integer(forKey: "fontSize") == 18)
        #expect(defaultsB.bool(forKey: "deviceOnly"))

        // 本地书的目录与正文在首次打开时按书籍记录重建
        let restored = try #require(b.shelf.book(local.bookUrl))
        #expect(restored.durChapterIndex == 1 && restored.durChapterPos == 8)
        let service = b.contentService(for: restored)
        let (_, chapters) = try await service.chapters(for: restored)
        #expect(chapters.map(\.title) == ["第一章 开端", "第二章 发展", "第三章 结局"])
        let text = try await service.content(for: restored, chapter: chapters[1], nextChapter: nil)
        #expect(text.contains("风吹过山岗"))
    }

    @Test func 按类别备份恢复与勾选记忆() async throws {
        let data = tempDirectory()
        let a = makeServices(data)
        try await populate(a)
        #expect(a.backup.isSelected(.bookshelf) && !a.backup.isSelected(.localBooks))
        a.backup.setSelected(false, for: .searchHistory)
        a.backup.setSelected(true, for: .localBooks)

        let reopened = makeServices(data)
        #expect(reopened.backup.deviceId == a.backup.deviceId)
        #expect(reopened.backup.selectedCategories == Set(a.backup.categories).subtracting([.searchHistory]))
        let (defaults, name) = try temporaryDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        reopened.backup.register(.userDefaults(keys: ["k"], defaults: defaults))
        #expect(reopened.backup.isSelected(.settings))

        let archive = try await a.backup.exportArchive(categories: [.bookSources, .bookmarks], to: tempDirectory())
        let b = makeServices()
        let kept = Book(bookUrl: "https://c.test/book", origin: "https://c.test", name: "保留", author: "丙")
        b.shelf.add(kept)
        b.searchHistory.record("保留")
        let package = try await b.backup.openArchive(at: archive)
        defer { package.discard() }
        #expect(Set(package.manifest.categories ?? []) == ["bookSources", "bookmarks"])
        #expect(!package.manifest.includesLocalBooks)

        let result = try await b.backup.restore(package, categories: [.bookSources, .bookshelf, .searchHistory])
        #expect(result.restored == [.bookSources: 2])
        #expect(b.sources.sources == a.sources.sources)
        #expect(b.shelf.books.map(\.bookUrl) == [kept.bookUrl] && b.shelf.bookmarks.isEmpty)
        #expect(b.searchHistory.keywords == ["保留"])

        await #expect(throws: BackupError.nothingSelected) {
            try await a.backup.exportArchive(categories: [], to: tempDirectory())
        }
    }

    @Test func 无效备份与损坏数据不改动现有数据() async throws {
        let services = makeServices()
        let notZip = tempDirectory().appendingPathComponent("x.zip")
        try Data("不是压缩包".utf8).write(to: notZip)
        await #expect(throws: BackupError.invalidArchive) { try await services.backup.openArchive(at: notZip) }

        let noManifest = try writeZip([("readme.txt", Data("hi".utf8))])
        await #expect(throws: BackupError.missingManifest) { try await services.backup.openArchive(at: noManifest) }

        let future = try writeZip([("manifest.json", Data(#"{"version":99}"#.utf8))])
        await #expect(throws: BackupError.versionMismatch(99)) { try await services.backup.openArchive(at: future) }

        // 外层多套一层文件夹也能识别；书架数据损坏时其他类别也不写回
        services.sources.importSources([try source("https://keep.test", "原有")])
        let before = services.sources.sources
        let broken = try writeZip([
            ("备份/manifest.json", Data(#"{"version":1,"id":"x"}"#.utf8)),
            ("备份/bookSource.json", Data(#"[{"bookSourceUrl":"https://new.test","bookSourceName":"新"}]"#.utf8)),
            ("备份/bookshelf.json", Data("{坏数据".utf8)),
        ])
        let package = try await services.backup.openArchive(at: broken)
        defer { package.discard() }
        await #expect(throws: BackupError.corruptedFile("bookshelf.json")) { try await services.backup.restore(package) }
        #expect(services.sources.sources == before)

        // 来自备份的本地书地址不能越出书籍目录
        let escaping = Book(bookUrl: "localbook://../evil", origin: Book.localOrigin)
        #expect(LocalBookStore.id(of: escaping) == nil)
    }

    @Test func 恢复Legado备份() async throws {
        let services = makeServices()
        let books = #"[{"bookUrl":"https://a.test/book/1","origin":"https://a.test","originName":"甲源","name":"网络书","author":"甲","durChapterIndex":5,"durChapterPos":42,"group":4},{"bookUrl":"/storage/emulated/0/Books/本地.txt","origin":"loc_book","name":"本地","author":""}]"#
        let groups = #"[{"groupId":-1,"groupName":"全部","order":-10},{"groupId":4,"groupName":"追更","order":1,"show":true}]"#
        let bookmarks = #"[{"time":5,"bookName":"网络书","bookAuthor":"甲","chapterIndex":5,"chapterPos":42,"chapterName":"第六章","bookText":"摘录","content":""}]"#
        let history = #"[{"word":"旧","usage":3,"lastUseTime":100},{"word":"新","usage":1,"lastUseTime":200}]"#
        var builtIn = TxtTocRule.defaults[1]
        builtIn.enable = false
        let tocRules = try JSONEncoder().encode([builtIn, TxtTocRule(id: 9, name: "自定义", rule: "^话.+$", serialNumber: 30)])
        let archive = try writeZip([
            ("bookshelf.json", Data(books.utf8)),
            ("bookGroup.json", Data(groups.utf8)),
            ("bookSource.json", Data(#"[{"bookSourceUrl":"https://a.test","bookSourceName":"甲源"}]"#.utf8)),
            ("bookmark.json", Data(bookmarks.utf8)),
            ("replaceRule.json", Data(#"[{"id":3,"name":"去空行","pattern":"\\n+","replacement":"\n","isRegex":true}]"#.utf8)),
            ("txtTocRule.json", tocRules),
            ("searchHistory.json", Data(history.utf8)),
            ("config.xml", Data("<map/>".utf8)),
        ])

        let package = try await services.backup.openArchive(at: archive)
        defer { package.discard() }
        #expect(package.manifest.deviceName == "Legado" && package.manifest.categories == nil)
        #expect(package.manifest.counts["bookshelf"] == 2 && package.manifest.counts["bookSources"] == 1)

        let result = try await services.backup.restore(package)
        #expect(result.restored[.bookshelf] == 1 && result.restored[.localBooks] == nil)
        let book = try #require(services.shelf.books.first)
        #expect(services.shelf.books.count == 1)
        #expect(book.durChapterIndex == 5 && book.durChapterPos == 42 && book.group == 4)
        #expect(services.shelf.groups.map(\.groupName) == ["追更"])
        #expect(services.sources.sources.map(\.bookSourceUrl) == ["https://a.test"])
        #expect(services.shelf.bookmarks.map(\.chapterName) == ["第六章"])
        #expect(services.replaceRules.rules.map(\.id) == [3])
        #expect(services.txtTocRules.rules.first { $0.id == -2 }?.enable == false)
        #expect(services.txtTocRules.rules.contains { $0.id == 9 && $0.name == "自定义" })
        #expect(services.searchHistory.keywords == ["新", "旧"])
    }
}

@Suite("WebDAV 备份与恢复")
@MainActor
struct WebDAVBackupTests {
    @Test func 测试连接与错误() async throws {
        let dav = MemoryWebDAV()
        try await WebDAVClient(config: dav.config(), transport: dav).testConnection()
        await #expect(throws: WebDAVError.unauthorized) {
            try await WebDAVClient(config: dav.config(password: "错的"), transport: dav).testConnection()
        }
        await #expect(throws: WebDAVError.invalidURL) {
            try await WebDAVClient(config: WebDAVConfig(url: "dav.test/dav", username: "", password: ""), transport: dav).testConnection()
        }
        dav.setOffline(true)
        do {
            try await WebDAVClient(config: dav.config(), transport: dav).testConnection()
            Issue.record("断网时应失败")
        } catch WebDAVError.notReachable {
        } catch {
            Issue.record("应为无法连接：\(error)")
        }
        #expect(WebDAVConfig(url: "https://dav.jianguoyun.com/dav/", username: "u", password: "p").displayName == "dav.jianguoyun.com")
    }

    @Test func 增量备份断点续传与清理() async throws {
        let dav = MemoryWebDAV()
        let client = WebDAVClient(config: dav.config(), transport: dav)
        let a = makeServices()
        let local = try await populate(a)
        let id = try #require(LocalBookStore.id(of: local))
        let categories: Set<BackupCategory> = [.bookshelf, .bookmarks, .bookSources, .localBooks]

        let recorder = ProgressRecorder()
        var result = try await a.backup.backup(to: client, categories: categories) { recorder.items.append($0) }
        #expect(result.uploaded == 7 && result.skipped == 0 && result.deleted == 0)
        #expect(dav.remotePaths() == ["bookshelf.json", "bookGroup.json", "pinnedBooks.json", "bookmark.json", "bookSource.json",
                                      "localBooks.json", "localBooks/\(id)/book.txt", "manifest.json"])
        #expect(dav.requests.last { $0.hasPrefix("PUT ") }?.hasSuffix("/manifest.json") == true)
        #expect(recorder.items.first == BackupProgress(stage: .uploading, completed: 0, total: 7))
        #expect(recorder.items.last == BackupProgress(stage: .uploading, completed: 7, total: 7))
        let manifest = try #require(try await a.backup.remoteManifest(from: client))
        #expect(manifest.id == result.manifest.id && manifest.includesLocalBooks)

        result = try await a.backup.backup(to: client, categories: categories)
        #expect(result.uploaded == 0 && result.skipped == 7)

        // 中断后远端清单标记为未完成，再次备份只补传没传完的文件
        let previous = result.manifest.id
        a.sources.importSources([try source("https://c.test", "丙源")])
        a.shelf.addBookmark(Bookmark(time: 2, bookName: "第二本", bookAuthor: "乙", chapterIndex: 0, chapterPos: 0,
                                     chapterName: "序", bookText: "开头"))
        dav.failUploads(endingWith: "bookmark.json")
        let reason = WebDAVError.httpStatus(507).localizedDescription
        await #expect(throws: BackupError.interrupted(uploaded: 1, reason: reason)) {
            try await a.backup.backup(to: client, categories: categories)
        }
        let unfinished = try #require(try await a.backup.remoteManifest(from: client))
        #expect(!unfinished.isComplete && unfinished.id != previous)
        dav.failUploads(endingWith: nil)
        result = try await a.backup.backup(to: client, categories: categories)
        #expect(result.uploaded == 1 && result.skipped == 6)
        #expect(try await a.backup.remoteManifest(from: client)?.isComplete == true)

        // 删除的本地书在远端一并删除，连同变空的目录
        a.removeBooks([local.bookUrl])
        result = try await a.backup.backup(to: client, categories: categories)
        #expect(result.uploaded == 2 && result.deleted == 1)
        #expect(!dav.remotePaths().contains("localBooks/\(id)/book.txt"))
        #expect(!dav.directoryExists("localBooks/\(id)") && !dav.directoryExists("localBooks"))

        result = try await a.backup.backup(to: client, categories: categories, forceFull: true)
        #expect(result.uploaded == 6 && result.skipped == 0)
    }

    @Test func 下载恢复与列出() async throws {
        let dav = MemoryWebDAV()
        let client = WebDAVClient(config: dav.config(), transport: dav)
        let a = makeServices()
        let local = try await populate(a)
        let id = try #require(LocalBookStore.id(of: local))
        try await a.backup.backup(to: client, categories: Set(a.backup.categories))

        let tree = try await client.listTree()
        #expect(tree.map(\.path).contains("localBooks/\(id)/book.txt"))
        #expect((tree.first { $0.path == "manifest.json" }?.size ?? 0) > 0)
        #expect(try await client.list().contains { $0.path == "localBooks" && $0.isDirectory })

        // 只下载选中类别的文件
        let b = makeServices()
        let partial = try await b.backup.download(from: client, categories: [.bookshelf, .bookSources])
        #expect(partial.files.contains("bookshelf.json") && !partial.files.contains("bookmark.json"))
        #expect(!partial.files.contains("localBooks/\(id)/book.txt"))
        try await b.backup.restore(partial, categories: [.bookshelf, .bookSources])
        partial.discard()
        #expect(b.shelf.books == a.shelf.books.filter { !$0.isLocal })
        #expect(b.sources.sources == a.sources.sources && b.shelf.bookmarks.isEmpty)

        let recorder = ProgressRecorder()
        let full = try await b.backup.download(from: client) { recorder.items.append($0) }
        defer { full.discard() }
        #expect(recorder.items.last?.stage == .downloading && recorder.items.last?.completed == recorder.items.last?.total)
        try await b.backup.restore(full)
        #expect(b.shelf.books == a.shelf.books)
        #expect(b.searchHistory.keywords == a.searchHistory.keywords)
        let restored = try #require(b.shelf.book(local.bookUrl))
        let (_, chapters) = try await b.contentService(for: restored).chapters(for: restored)
        #expect(chapters.count == 3)

        let empty = WebDAVClient(config: dav.config(directory: "空目录"), transport: dav)
        #expect(try await b.backup.remoteManifest(from: empty) == nil)
        await #expect(throws: BackupError.noRemoteBackup) { try await b.backup.download(from: empty) }
        #expect(try await empty.listTree().isEmpty)
    }

    @Test func 多设备与远端变化() async throws {
        let dav = MemoryWebDAV()
        let client = WebDAVClient(config: dav.config(), transport: dav)
        let categories: Set<BackupCategory> = [.bookSources, .bookmarks]
        let a = makeServices()
        let local = try await populate(a)
        let id = try #require(LocalBookStore.id(of: local))
        let b = makeServices()
        b.sources.importSources([try source("https://b.test", "乙源")])

        #expect(try await a.backup.backup(to: client, categories: categories.union([.localBooks])).uploaded == 4)
        // B 的备份不含本地书，A 留在远端的本地书随之删除
        let result = try await b.backup.backup(to: client, categories: categories)
        #expect(result.uploaded == 2 && result.deleted == 2)
        #expect(dav.remotePaths() == ["bookSource.json", "bookmark.json", "manifest.json"])
        #expect(!dav.directoryExists("localBooks/\(id)") && !dav.directoryExists("localBooks"))
        // 远端清单已是 B 的，A 的记录作废
        #expect(try await a.backup.backup(to: client, categories: categories).uploaded == 2)
        #expect(try await a.backup.backup(to: client, categories: categories).uploaded == 0)

        // B 中断时已覆盖了部分文件，A 不能再按自己的记录跳过
        b.sources.importSources([try source("https://d.test", "丁源")])
        dav.failUploads(endingWith: "bookmark.json")
        await #expect(throws: BackupError.self) { try await b.backup.backup(to: client, categories: categories) }
        dav.failUploads(endingWith: nil)
        #expect(try await a.backup.backup(to: client, categories: categories).uploaded == 2)
        let c = makeServices()
        let package = try await c.backup.download(from: client)
        defer { package.discard() }
        try await c.backup.restore(package)
        #expect(c.sources.sources == a.sources.sources && c.shelf.bookmarks == a.shelf.bookmarks)

        dav.removeAll()
        #expect(try await a.backup.backup(to: client, categories: categories).uploaded == 2)

        var moved = client.config
        moved.directory = "新目录"
        #expect(try await a.backup.backup(to: WebDAVClient(config: moved, transport: dav), categories: categories).uploaded == 2)
        #expect(dav.remotePaths(directory: "新目录").contains("manifest.json"))
    }

    @Test func 备份目录为网盘根目录时不碰其他文件() async throws {
        let dav = MemoryWebDAV()
        dav.addFile("照片/2026/1.jpg")
        dav.addFile("笔记.txt")
        let client = WebDAVClient(config: dav.config(directory: ""), transport: dav)
        let a = makeServices()
        try await populate(a)
        try await a.backup.backup(to: client, categories: [.bookSources, .localBooks])
        let result = try await a.backup.backup(to: client, categories: [.bookSources], forceFull: true)
        #expect(result.uploaded == 1 && result.deleted == 2)

        let package = try await a.backup.download(from: client)
        defer { package.discard() }
        #expect(package.files.contains("bookSource.json") && !package.files.contains("localBooks.json"))
        #expect(dav.fileExists("照片/2026/1.jpg") && dav.fileExists("笔记.txt"))
        #expect(!dav.requests.contains { $0.contains("照片") || $0.contains("笔记") })
    }

    @Test func PROPFIND兼容不同服务器() async throws {
        // 反向代理改写了路径前缀、默认命名空间、未编码的中文、目录不带结尾斜杠、缺失属性单独返回 404
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <multistatus xmlns="DAV:">
        <response><href>/remote.php/dav/files/u/ReaderBackup/</href><propstat><prop><resourcetype><collection/></resourcetype></prop><status>HTTP/1.1 200 OK</status></propstat></response>
        <response><href>/remote.php/dav/files/u/ReaderBackup/manifest.json</href><propstat><prop><resourcetype/><getcontentlength>120</getcontentlength><getlastmodified>Sat, 07 Nov 2026 08:00:00 GMT</getlastmodified></prop><status>HTTP/1.1 200 OK</status></propstat></response>
        <response><href>/remote.php/dav/files/u/ReaderBackup/本地%20书</href><propstat><prop><resourcetype><collection/></resourcetype></prop><status>HTTP/1.1 200 OK</status></propstat><propstat><prop><getcontentlength/></prop><status>HTTP/1.1 404 Not Found</status></propstat></response>
        </multistatus>
        """
        let transport = StubTransport()
        transport.on("https://cloud.test/dav/ReaderBackup/") { HTTPResponse(url: $0.url, statusCode: 207, body: Data(xml.utf8)) }
        let client = WebDAVClient(config: WebDAVConfig(url: "https://cloud.test/dav", username: "u", password: "p"), transport: transport)
        let items = try await client.list()
        #expect(items.map(\.path) == ["manifest.json", "本地 书"])
        #expect(items.first?.size == 120 && items.first?.isDirectory == false && items.first?.modified != nil)
        #expect(items.last?.isDirectory == true && items.last?.size == nil)
    }
}
