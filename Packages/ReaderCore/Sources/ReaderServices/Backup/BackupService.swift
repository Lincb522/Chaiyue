import CryptoKit
import Foundation
import Observation
import ZIPFoundation

/// 备份与恢复：本地 zip 备份文件与 WebDAV 网盘。
/// 各类别以 `BackupProvider` 注册；恢复直接写回各仓库，界面随之刷新，无需重启
@MainActor
@Observable
public final class BackupService {
    public private(set) var providers: [BackupProvider] = []
    /// 写入清单的 App 版本与设备名，由 App 层设置
    public var appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    public var deviceName = ""
    public let deviceId: String

    struct Preferences: Codable, Sendable {
        var deviceId = UUID().uuidString
        var enabled: [String] = []
        /// 用户设置过勾选状态时已注册的类别；之后新增的类别按其默认值
        var known: [String] = []
    }

    private var enabled: Set<String>
    private var known: Set<String>
    @ObservationIgnored private let preferences: JSONFileStore<Preferences>
    @ObservationIgnored private let directory: URL

    /// `directory` 存勾选状态与 WebDAV 同步记录
    public init(directory: URL) {
        self.directory = directory
        let url = directory.appendingPathComponent("backup.json")
        let isNew = !FileManager.default.fileExists(atPath: url.path)
        preferences = JSONFileStore(url: url) { Preferences() }
        let current = preferences.current
        deviceId = current.deviceId
        enabled = Set(current.enabled)
        known = Set(current.known)
        if isNew {
            preferences.update { _ in }
            preferences.flush()
        }
    }

    // MARK: - 类别

    /// 注册类别；同一类别重复注册时替换
    public func register(_ provider: BackupProvider) {
        if let index = providers.firstIndex(where: { $0.category == provider.category }) {
            providers[index] = provider
        } else {
            providers.append(provider)
        }
    }

    public var categories: [BackupCategory] { providers.map(\.category) }

    public func provider(for category: BackupCategory) -> BackupProvider? {
        providers.first { $0.category == category }
    }

    public func isSelected(_ category: BackupCategory) -> Bool {
        if known.contains(category.rawValue) { return enabled.contains(category.rawValue) }
        return provider(for: category)?.defaultEnabled ?? false
    }

    /// 当前勾选的类别：备份时打包这些类别，恢复时也只还原这些类别
    public var selectedCategories: Set<BackupCategory> {
        Set(categories.filter(isSelected))
    }

    public func setSelected(_ selected: Bool, for category: BackupCategory) {
        for provider in providers where !known.contains(provider.category.rawValue) {
            known.insert(provider.category.rawValue)
            if provider.defaultEnabled { enabled.insert(provider.category.rawValue) }
        }
        known.insert(category.rawValue)
        if selected {
            enabled.insert(category.rawValue)
        } else {
            enabled.remove(category.rawValue)
        }
        let snapshot = (enabled: enabled.sorted(), known: known.sorted())
        preferences.update {
            $0.enabled = snapshot.enabled
            $0.known = snapshot.known
        }
        preferences.flush()
    }

    // MARK: - 本地备份文件

    /// 把类别（默认为当前勾选的类别）打包为 zip 备份文件，返回文件地址
    public func exportArchive(categories: Set<BackupCategory>? = nil, to directory: URL, fileName: String? = nil) async throws -> URL {
        let snapshot = try await collect(categories ?? selectedCategories)
        let url = directory.appendingPathComponent(fileName ?? Self.archiveFileName(date: snapshot.manifest.date))
        let manifest = try BackupCoding.encode(snapshot.manifest)
        let items = snapshot.items
        try await offload { try BackupArchive.write(items, manifest: manifest, to: url) }
        return url
    }

    public nonisolated static func archiveFileName(prefix: String = "备份", date: Date = Date(), pathExtension: String = "zip") -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmm"
        return "\(prefix)_\(formatter.string(from: date)).\(pathExtension)"
    }

    /// 解压备份文件并读取清单，供恢复前确认。也接受 Legado 的备份 zip
    public func openArchive(at url: URL) async throws -> BackupPackage {
        let directory = Self.temporaryDirectory()
        return try await offload { try BackupArchive.open(url, into: directory) }
    }

    /// 用备份覆盖当前数据：只恢复 `categories`（为 nil 时全部）与备份实际包含的类别的交集。
    /// 先读取校验全部类别再统一写回，任一类别的数据损坏时不改动任何数据
    @discardableResult
    public func restore(_ package: BackupPackage, categories: Set<BackupCategory>? = nil) async throws -> BackupRestoreResult {
        var plans: [(BackupCategory, BackupRestorePlan)] = []
        for provider in providers
        where package.manifest.includes(provider.category) && categories?.contains(provider.category) != false {
            if let plan = try await provider.prepareRestore(package.files) {
                plans.append((provider.category, plan))
            }
        }
        var restored: [BackupCategory: Int] = [:]
        for (category, plan) in plans {
            restored[category] = plan.apply()
        }
        return BackupRestoreResult(manifest: package.manifest, restored: restored)
    }

    // MARK: - WebDAV

    /// 增量备份到 WebDAV：只上传变化的文件，每个文件上传成功后立即记录，中断后再次备份从断点继续；清单最后上传。
    /// 远端清单不是本机记录所依据的那一份（其他设备备份过、被删除或换了目录）时完整上传；`forceFull` 强制完整上传。
    /// 远端不再属于本次备份的文件（如已删除的本地书、取消勾选的类别）会被删除
    @discardableResult
    public func backup(to client: WebDAVClient, categories: Set<BackupCategory>? = nil, forceFull: Bool = false,
                       progress: (@MainActor @Sendable (BackupProgress) -> Void)? = nil) async throws -> WebDAVBackupResult {
        let snapshot = try await collect(categories ?? selectedCategories)
        return try await WebDAVSync.upload(snapshot, client: client, ownedPaths: providers.flatMap(\.paths),
                                           stateURL: syncStateURL(client.config), forceFull: forceFull, progress: progress)
    }

    /// 网盘上备份的清单（备份时间、条目数）；没有备份时返回 nil
    public func remoteManifest(from client: WebDAVClient) async throws -> BackupManifest? {
        guard let data = try await client.download(BackupManifest.fileName) else { return nil }
        return try BackupManifest.decode(data)
    }

    /// 下载网盘上的备份到临时目录，确认后用 `restore` 恢复。只下载备份包含的类别，`categories` 不为 nil 时再限定为这些类别
    public func download(from client: WebDAVClient, categories: Set<BackupCategory>? = nil,
                         progress: (@MainActor @Sendable (BackupProgress) -> Void)? = nil) async throws -> BackupPackage {
        guard let data = try await client.download(BackupManifest.fileName) else { throw BackupError.noRemoteBackup }
        let manifest = try BackupManifest.decode(data)
        let paths = providers
            .filter { manifest.includes($0.category) && categories?.contains($0.category) != false }
            .flatMap(\.paths)
        return try await WebDAVSync.download(client: client, manifest: manifest, manifestData: data, paths: paths,
                                             into: Self.temporaryDirectory(), progress: progress)
    }

    /// 清除同步记录，下次备份完整上传
    public func clearSyncState(for config: WebDAVConfig) {
        try? FileManager.default.removeItem(at: syncStateURL(config))
    }

    // MARK: - 内部

    struct Snapshot: Sendable {
        var manifest: BackupManifest
        var items: [String: BackupContent.Item]
    }

    func collect(_ categories: Set<BackupCategory>) async throws -> Snapshot {
        let selected = providers.filter { categories.contains($0.category) }
        guard !selected.isEmpty else { throw BackupError.nothingSelected }
        var items: [String: BackupContent.Item] = [:]
        var counts: [String: Int] = [:]
        for provider in selected {
            let content = try await provider.export()
            for (path, item) in content.items {
                assert(provider.owns(path) && path != BackupManifest.fileName, "\(provider.category.rawValue) 未声明路径 \(path)")
                items[path] = item
            }
            counts[provider.category.rawValue] = content.count
        }
        let manifest = BackupManifest(appVersion: appVersion, deviceName: deviceName, deviceId: deviceId, counts: counts,
                                      categories: selected.map(\.category.rawValue))
        return Snapshot(manifest: manifest, items: items)
    }

    func syncStateURL(_ config: WebDAVConfig) -> URL {
        directory.appendingPathComponent("webdav-\(config.id.uuidString.lowercased()).json")
    }

    nonisolated static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupRestore", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

/// Legado 备份 zip 中与内置类别对应的文件
enum LibraryBackupFile {
    static let bookshelf = "bookshelf.json"
    static let groups = "bookGroup.json"
    static let pinned = "pinnedBooks.json"
    static let bookmarks = "bookmark.json"
    static let bookSources = "bookSource.json"
    static let replaceRules = "replaceRule.json"
    static let txtTocRules = "txtTocRule.json"
    static let searchHistory = "searchHistory.json"
    static let httpTTS = "httpTTS.json"
    static let localBooks = "localBooks.json"
    static let localBookFiles = "localBooks/"

    static let legado: [(file: String, category: BackupCategory)] = [
        (bookshelf, .bookshelf), (bookmarks, .bookmarks), (bookSources, .bookSources),
        (replaceRules, .replaceRules), (txtTocRules, .txtTocRules), (searchHistory, .searchHistory),
    ]
}

// MARK: - zip

enum BackupArchive {
    static func write(_ items: [String: BackupContent.Item], manifest: Data, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: url)
        do {
            let archive = try Archive(url: url, accessMode: .create)
            for (path, item) in items.sorted(by: { $0.key < $1.key }) {
                // EPUB 本身已压缩
                let method: CompressionMethod = path.lowercased().hasSuffix(".epub") ? .none : .deflate
                switch item {
                case .data(let data): try add(data, as: path, to: archive, method: method)
                case .file(let file): try archive.addEntry(with: path, fileURL: file, compressionMethod: method)
                }
            }
            try add(manifest, as: BackupManifest.fileName, to: archive, method: .deflate)
        } catch {
            try? fm.removeItem(at: url)
            throw error
        }
    }

    private static func add(_ data: Data, as path: String, to archive: Archive, method: CompressionMethod) throws {
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: method) { position, size in
            data.subdata(in: Int(position)..<Int(position) + size)
        }
    }

    /// 解压到 `directory` 并读取清单。清单可以在根目录或唯一的子目录中（压缩时多套了一层文件夹）；
    /// 没有清单但有 Legado 备份文件时按 Legado 备份处理
    static func open(_ url: URL, into directory: URL) throws -> BackupPackage {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try fm.unzipItem(at: url, to: directory)
        } catch {
            try? fm.removeItem(at: directory)
            throw BackupError.invalidArchive
        }
        do {
            guard let located = locateRoot(directory) else { throw BackupError.missingManifest }
            let (root, isLegado) = located
            let manifest: BackupManifest
            if isLegado {
                manifest = legadoManifest(root, date: (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? Date())
            } else {
                manifest = try BackupManifest.decode(try Data(contentsOf: root.appendingPathComponent(BackupManifest.fileName)))
            }
            return BackupPackage(manifest: manifest, files: BackupFiles(root: root), directory: directory)
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
    }

    /// 备份内容所在目录，以及是否为 Legado 备份
    private static func locateRoot(_ directory: URL) -> (URL, Bool)? {
        let fm = FileManager.default
        func isLegado(_ dir: URL) -> Bool? {
            if fm.fileExists(atPath: dir.appendingPathComponent(BackupManifest.fileName).path) { return false }
            if LibraryBackupFile.legado.contains(where: { fm.fileExists(atPath: dir.appendingPathComponent($0.file).path) }) {
                return true
            }
            return nil
        }
        if let legado = isLegado(directory) { return (directory, legado) }
        let children = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && $0.lastPathComponent != "__MACOSX" }
        if children.count == 1, let legado = isLegado(children[0]) { return (children[0], legado) }
        return nil
    }

    private static func legadoManifest(_ root: URL, date: Date) -> BackupManifest {
        var counts: [String: Int] = [:]
        for (file, category) in LibraryBackupFile.legado {
            guard let data = try? Data(contentsOf: root.appendingPathComponent(file)),
                  let list = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { continue }
            counts[category.rawValue] = list.count
        }
        return BackupManifest(id: "", createdAt: Int64(date.timeIntervalSince1970 * 1000), deviceName: "Legado", counts: counts)
    }
}

// MARK: - WebDAV 同步

struct WebDAVSyncState: Codable, Sendable {
    /// 备份目录地址：换了服务器或目录时记录作废
    var location: String?
    /// 记录所依据的远端清单：远端清单变了（其他设备备份过或被删除）时记录作废
    var base: String?
    /// 相对路径 → 签名；空字符串表示远端已有、内容未知
    var files: [String: String] = [:]
}

enum WebDAVSync {
    static func upload(_ snapshot: BackupService.Snapshot, client: WebDAVClient, ownedPaths: [String], stateURL: URL,
                       forceFull: Bool, progress: (@MainActor @Sendable (BackupProgress) -> Void)?) async throws -> WebDAVBackupResult {
        guard let location = client.rootURL else { throw WebDAVError.invalidURL }
        try await client.makeDirectory()
        let remote = try await client.download(BackupManifest.fileName).flatMap { try? JSONDecoder().decode(BackupManifest.self, from: $0) }
        var state = loadState(stateURL)
        if forceFull || remote == nil || state.location != location || state.base != remote?.id {
            // 记录不可信时以远端现有文件为准：全部重传，不再属于本次备份的随后删除
            state = WebDAVSyncState(location: location)
            for path in try await ownedFiles(client: client, paths: ownedPaths) {
                state.files[path] = ""
            }
        }

        let items = snapshot.items
        let signatures = try await offload { try items.mapValues(signature) }
        let pending = signatures.keys.filter { state.files[$0] != signatures[$0] }.sorted()
        let stale = state.files.keys.filter { signatures[$0] == nil }.sorted()
        if !pending.isEmpty || !stale.isEmpty {
            // 改动文件前先换掉远端清单：其他设备的记录随之作废，不会把这次可能中断的上传当成已同步而跳过
            var provisional = snapshot.manifest
            provisional.id = UUID().uuidString
            provisional.isComplete = false
            try await uploadManifest(provisional, client: client, uploaded: 0)
            state.base = provisional.id
            saveState(state, to: stateURL)
        }

        let root = client.directoryParts
        var created = Set<String>()
        var uploaded = 0
        await progress?(BackupProgress(stage: .uploading, completed: 0, total: pending.count))
        for path in pending {
            try Task.checkCancellation()
            do {
                let parts = WebDAVClient.components(path)
                for level in parts.indices.dropLast() {
                    let directory = root + parts[...level]
                    if created.insert(directory.joined(separator: "/")).inserted {
                        try await client.createCollection(directory)
                    }
                }
                switch items[path] {
                case .data(let data): try await client.upload(data, to: path)
                case .file(let url): try await client.upload(fileAt: url, to: path)
                case nil: continue
                }
            } catch {
                throw BackupError.interrupted(uploaded: uploaded, reason: error.localizedDescription)
            }
            state.files[path] = signatures[path]
            saveState(state, to: stateURL)
            uploaded += 1
            await progress?(BackupProgress(stage: .uploading, completed: uploaded, total: pending.count))
        }

        for path in stale {
            try Task.checkCancellation()
            do {
                try await client.delete(path)
            } catch {
                throw BackupError.interrupted(uploaded: uploaded, reason: error.localizedDescription)
            }
            state.files[path] = nil
            saveState(state, to: stateURL)
        }
        let emptied = Set(stale.flatMap(ancestors)).filter { dir in !state.files.keys.contains { $0.hasPrefix(dir + "/") } }
        for directory in emptied.sorted(by: { $0.count > $1.count }) {
            try? await client.delete(directory)
        }

        try await uploadManifest(snapshot.manifest, client: client, uploaded: uploaded)
        state.base = snapshot.manifest.id
        saveState(state, to: stateURL)
        return WebDAVBackupResult(manifest: snapshot.manifest, uploaded: uploaded, skipped: signatures.count - pending.count,
                                  deleted: stale.count)
    }

    static func download(client: WebDAVClient, manifest: BackupManifest, manifestData: Data, paths: [String], into directory: URL,
                         progress: (@MainActor @Sendable (BackupProgress) -> Void)?) async throws -> BackupPackage {
        let fm = FileManager.default
        do {
            let files = try await ownedFiles(client: client, paths: paths)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try manifestData.write(to: directory.appendingPathComponent(BackupManifest.fileName))
            let root = BackupFiles(root: directory)
            await progress?(BackupProgress(stage: .downloading, completed: 0, total: files.count))
            for (index, path) in files.enumerated() {
                try Task.checkCancellation()
                if let target = root.url(path), let data = try await client.download(path) {
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: target, options: .atomic)
                }
                await progress?(BackupProgress(stage: .downloading, completed: index + 1, total: files.count))
            }
            return BackupPackage(manifest: manifest, files: root, directory: directory)
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
    }

    /// 远端属于 `paths` 的文件。只列出这些位置，备份目录设为网盘根目录时也不会遍历整个网盘
    static func ownedFiles(client: WebDAVClient, paths: [String]) async throws -> [String] {
        let files = Set(paths.filter { !$0.hasSuffix("/") })
        var result = Set<String>()
        for directory in Set(files.map { parent($0) ?? "" }).sorted() {
            for item in try await client.list(directory) where !item.isDirectory && files.contains(item.path) {
                result.insert(item.path)
            }
        }
        for prefix in Set(paths.filter { $0.hasSuffix("/") }).sorted() {
            result.formUnion(try await client.listTree(prefix).map(\.path))
        }
        return result.sorted()
    }

    private static func uploadManifest(_ manifest: BackupManifest, client: WebDAVClient, uploaded: Int) async throws {
        do {
            try await client.upload(try BackupCoding.encode(manifest), to: BackupManifest.fileName)
        } catch {
            throw BackupError.interrupted(uploaded: uploaded, reason: error.localizedDescription)
        }
    }

    /// 内容数据用 MD5；本机文件（本地书）用大小与修改时间，避免每次读完整文件
    static func signature(_ item: BackupContent.Item) throws -> String {
        switch item {
        case .data(let data):
            return "md5:" + Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case .file(let url):
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let modified = values.contentModificationDate.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
            return "file:\(values.fileSize ?? 0):\(modified)"
        }
    }

    private static func parent(_ path: String) -> String? {
        guard let slash = path.lastIndex(of: "/") else { return nil }
        return String(path[..<slash])
    }

    private static func ancestors(_ path: String) -> [String] {
        Array(sequence(first: path, next: parent).dropFirst())
    }

    private static func loadState(_ url: URL) -> WebDAVSyncState {
        guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(WebDAVSyncState.self, from: data) else {
            return WebDAVSyncState()
        }
        return state
    }

    private static func saveState(_ state: WebDAVSyncState, to url: URL) {
        guard let data = try? BackupCoding.encode(state) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
