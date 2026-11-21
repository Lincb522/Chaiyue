import Foundation
import Observation

/// 搜索历史：最近的在前，重复搜索移到最前，超出上限丢弃最旧的
@MainActor
@Observable
public final class SearchHistoryStore {
    public private(set) var keywords: [String]
    public var limit = 30
    @ObservationIgnored private let store: JSONFileStore<[String]>

    public init(fileURL: URL) {
        store = JSONFileStore(url: fileURL) { [] }
        keywords = store.current
    }

    public func record(_ keyword: String) {
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        keywords.removeAll { $0 == keyword }
        keywords.insert(keyword, at: 0)
        if keywords.count > limit { keywords.removeLast(keywords.count - limit) }
        persist()
    }

    public func remove(_ keyword: String) {
        keywords.removeAll { $0 == keyword }
        persist()
    }

    /// 恢复备份：整体替换（最近的在前）
    public func replaceAll(_ items: [String]) {
        var seen = Set<String>()
        keywords = Array(items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(limit))
        persist()
    }

    public func clear() {
        keywords = []
        persist()
    }

    public func flush() {
        store.flush()
    }

    private func persist() {
        let keywords = keywords
        store.update { $0 = keywords }
    }
}
