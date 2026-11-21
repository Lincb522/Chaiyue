import Foundation
import ReaderModels

/// 备份类别。功能层内置书架、书签、书源等，App 层可注册自己的类别（设置、外观主题、字体等）
public struct BackupCategory: RawRepresentable, Hashable, Codable, Sendable, Identifiable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var id: String { rawValue }

    /// 书籍（含阅读进度）、分组、置顶
    public static let bookshelf = BackupCategory("bookshelf")
    public static let bookmarks = BackupCategory("bookmarks")
    public static let bookSources = BackupCategory("bookSources")
    public static let replaceRules = BackupCategory("replaceRules")
    public static let txtTocRules = BackupCategory("txtTocRules")
    public static let searchHistory = BackupCategory("searchHistory")
    /// 在线朗读源
    public static let httpTTS = BackupCategory("httpTTS")
    /// 本地书原文件，体积较大，默认不备份
    public static let localBooks = BackupCategory("localBooks")
    /// App 设置，由 App 层注册（见 `BackupProvider.userDefaults`）
    public static let settings = BackupCategory("settings")
}

/// 备份清单 `manifest.json`
public struct BackupManifest: Hashable, Sendable {
    public static let fileName = "manifest.json"
    public static let currentVersion = 1

    public var version: Int
    public var id: String
    public var appVersion: String
    /// 毫秒时间戳
    public var createdAt: Int64
    public var deviceName: String
    public var deviceId: String
    /// 类别 → 条目数
    public var counts: [String: Int]
    /// 本次包含的类别；为 nil 表示全部（Legado 备份没有清单，按全部处理）
    public var categories: [String]?
    /// 为 false 表示网盘上的这次备份尚未完成（正在上传或已中断），部分文件可能仍是上一次备份的
    public var isComplete: Bool

    public init(version: Int = BackupManifest.currentVersion, id: String = UUID().uuidString, appVersion: String = "",
                createdAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000), deviceName: String = "", deviceId: String = "",
                counts: [String: Int] = [:], categories: [String]? = nil, isComplete: Bool = true) {
        self.version = version
        self.id = id
        self.appVersion = appVersion
        self.createdAt = createdAt
        self.deviceName = deviceName
        self.deviceId = deviceId
        self.counts = counts
        self.categories = categories
        self.isComplete = isComplete
    }

    public var date: Date { Date(timeIntervalSince1970: Double(createdAt) / 1000) }

    public var totalCount: Int { counts.values.reduce(0, +) }

    public func includes(_ category: BackupCategory) -> Bool {
        categories?.contains(category.rawValue) ?? true
    }

    public var includesLocalBooks: Bool { categories?.contains(BackupCategory.localBooks.rawValue) ?? false }

    /// 解析清单；格式版本高于当前支持的版本时报错
    public static func decode(_ data: Data) throws -> BackupManifest {
        guard let manifest = try? JSONDecoder().decode(BackupManifest.self, from: data) else {
            throw BackupError.invalidManifest
        }
        guard manifest.version <= currentVersion else { throw BackupError.versionMismatch(manifest.version) }
        return manifest
    }
}

extension BackupManifest: Codable {
    private enum CodingKeys: String, CodingKey {
        case version, id, appVersion, createdAt, deviceName, deviceId, counts, categories, includesLocalBooks, complete
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        appVersion = (try? c.decodeIfPresent(String.self, forKey: .appVersion)) ?? ""
        createdAt = (try? c.decodeIfPresent(Int64.self, forKey: .createdAt)) ?? 0
        deviceName = (try? c.decodeIfPresent(String.self, forKey: .deviceName)) ?? ""
        deviceId = (try? c.decodeIfPresent(String.self, forKey: .deviceId)) ?? ""
        counts = (try? c.decodeIfPresent([String: Int].self, forKey: .counts)) ?? [:]
        categories = try? c.decodeIfPresent([String].self, forKey: .categories)
        isComplete = (try? c.decodeIfPresent(Bool.self, forKey: .complete)) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(id, forKey: .id)
        try c.encode(appVersion, forKey: .appVersion)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(deviceName, forKey: .deviceName)
        try c.encode(deviceId, forKey: .deviceId)
        try c.encode(counts, forKey: .counts)
        try c.encodeIfPresent(categories, forKey: .categories)
        try c.encode(includesLocalBooks, forKey: .includesLocalBooks)
        try c.encode(isComplete, forKey: .complete)
    }
}

/// 一个类别导出的文件：备份内相对路径 → 内容
public struct BackupContent: Sendable {
    public enum Item: Sendable, Hashable {
        case data(Data)
        /// 本机文件，打包或上传时才读取
        case file(URL)
    }

    public private(set) var items: [String: Item] = [:]
    /// 条目数，写入清单供恢复前确认
    public var count: Int

    public init(count: Int = 0) {
        self.count = count
    }

    public mutating func add(_ path: String, data: Data) {
        items[path] = .data(data)
    }

    public mutating func add(_ path: String, file: URL) {
        items[path] = .file(file)
    }

    public mutating func add<T: Encodable>(_ path: String, json value: T) throws {
        items[path] = .data(try BackupCoding.encode(value))
    }
}

enum BackupCoding {
    /// 键排序保证同样的数据得到同样的文件，增量备份才能跳过未变化的文件
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

/// 恢复时读取的备份内容（已解压或已下载到本机目录）
public struct BackupFiles: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// 备份内文件的本机地址；路径越出备份目录（`..`、绝对路径）时返回 nil
    public func url(_ path: String) -> URL? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !path.hasPrefix("/"), !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        return parts.reduce(root) { $0.appendingPathComponent(String($1)) }
    }

    public func contains(_ path: String) -> Bool {
        guard let url = url(path) else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    /// 文件内容；备份中没有该文件时返回 nil
    public func data(_ path: String) throws -> Data? {
        guard contains(path), let url = url(path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func decode<T: Decodable>(_ type: T.Type, from path: String) throws -> T? {
        guard let data = try data(path) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw BackupError.corruptedFile(path)
        }
    }

    /// 解析 JSON 数组（也接受单个对象），单条损坏时跳过该条
    public func decodeList<T: Decodable>(_ type: T.Type, from path: String) throws -> [T]? {
        guard let data = try data(path) else { return nil }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [] }
        do {
            return try SourceImport.decodeList(T.self, from: data)
        } catch {
            throw BackupError.corruptedFile(path)
        }
    }
}

/// 一个类别的写回操作，返回恢复的条目数
public struct BackupRestorePlan {
    let apply: @MainActor () -> Int

    public init(_ apply: @escaping @MainActor () -> Int) {
        self.apply = apply
    }
}

/// 一个备份类别：导出时提供文件，恢复时先读取校验、全部类别都读取成功后再统一写回。
/// 两个闭包都在主线程调用，耗时的文件操作应在内部转到后台
public struct BackupProvider {
    public let category: BackupCategory
    public let title: String
    public let defaultEnabled: Bool
    /// 该类别在备份中占用的文件与目录（目录以 `/` 结尾）。网盘上只列出、下载和清理这些位置的文件
    public let paths: [String]
    let export: @MainActor () async throws -> BackupContent
    let prepareRestore: @MainActor (BackupFiles) async throws -> BackupRestorePlan?

    /// `restore` 在备份中没有该类别的数据时返回 nil
    public init(_ category: BackupCategory, title: String, defaultEnabled: Bool = true, paths: [String],
                export: @escaping @MainActor () async throws -> BackupContent,
                restore: @escaping @MainActor (BackupFiles) async throws -> BackupRestorePlan?) {
        self.category = category
        self.title = title
        self.defaultEnabled = defaultEnabled
        self.paths = paths
        self.export = export
        self.prepareRestore = restore
    }

    func owns(_ path: String) -> Bool {
        Self.path(path, isOwnedBy: paths)
    }

    static func path(_ path: String, isOwnedBy paths: [String]) -> Bool {
        paths.contains { $0.hasSuffix("/") ? path.hasPrefix($0) : path == $0 }
    }
}

/// 已解压或已从网盘下载的备份。确认后用 `BackupService.restore` 恢复，用完调用 `discard()` 删除临时文件
public struct BackupPackage: Sendable {
    public let manifest: BackupManifest
    public let files: BackupFiles
    let directory: URL

    public func discard() {
        try? FileManager.default.removeItem(at: directory)
    }
}

public struct BackupRestoreResult: Sendable {
    public var manifest: BackupManifest
    /// 实际恢复的类别 → 条目数
    public var restored: [BackupCategory: Int]

    public var totalCount: Int { restored.values.reduce(0, +) }
}

public struct BackupProgress: Sendable, Equatable {
    public enum Stage: Sendable, Equatable {
        case uploading
        case downloading
    }

    public var stage: Stage
    public var completed: Int
    public var total: Int

    public var text: String {
        (stage == .uploading ? "正在上传" : "正在下载") + " \(completed)/\(total)"
    }
}

public struct WebDAVBackupResult: Sendable {
    public var manifest: BackupManifest
    /// 本次上传的数据文件数（不含清单）
    public var uploaded: Int
    /// 未变化而跳过的文件数
    public var skipped: Int
    /// 删除的远端旧文件数（如已删除的本地书）
    public var deleted: Int
}

public enum BackupError: LocalizedError, Sendable, Equatable {
    case nothingSelected
    case invalidArchive
    case missingManifest
    case invalidManifest
    case versionMismatch(Int)
    case corruptedFile(String)
    case noRemoteBackup
    case interrupted(uploaded: Int, reason: String)

    public var errorDescription: String? {
        switch self {
        case .nothingSelected: "没有选择要备份的内容"
        case .invalidArchive: "无法读取备份文件"
        case .missingManifest: "无效的备份文件，缺少 manifest.json"
        case .invalidManifest: "备份清单已损坏"
        case .versionMismatch(let version): "备份格式版本（\(version)）不兼容当前 App，请更新后再恢复"
        case .corruptedFile(let path): "备份数据已损坏：\(path)"
        case .noRemoteBackup: "网盘中没有找到备份"
        case .interrupted(let uploaded, let reason): "备份中断（已上传 \(uploaded) 个文件）：\(reason)\n再次备份可从断点继续"
        }
    }
}
