import Foundation
import Observation
import ReaderModels
import ReaderServices
import RuleEngine

/// 书源校验：用固定关键词搜索并计时。成功写回响应时间并移出「失效」分组，失败加入「失效」分组
/// （沿用 Legado 的约定，可按分组筛选后批量清理）
@Observable
final class SourceChecker {
    static let brokenGroup = "失效"
    static let loginRequired = "需要登录"
    private static let keyword = "我的"

    private(set) var checking: Set<String> = []
    private(set) var completed = 0
    private(set) var total = 0
    private(set) var isRunning = false
    /// 最近一次失败的原因，按书源地址
    private(set) var messages: [String: String] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var runID = 0

    func check(_ urls: [String], library: LibraryServices) {
        cancel()
        let list = urls.compactMap { library.sources.source(for: $0) }
            .filter { !($0.searchUrl ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        guard !list.isEmpty else { return }
        runID += 1
        let id = runID
        completed = 0
        total = list.count
        isRunning = true
        let env = library.environment
        let keyword = Self.keyword
        task = Task { [weak self] in
            await withTaskGroup(of: (String, Result<Int64, Error>).self) { group in
                var iterator = list.makeIterator()
                func addNext() -> String? {
                    guard let source = iterator.next() else { return nil }
                    group.addTask {
                        (source.bookSourceUrl, await Self.probe(source, keyword: keyword, env: env))
                    }
                    return source.bookSourceUrl
                }
                for _ in 0..<6 {
                    if let url = addNext() { self?.checking.insert(url) }
                }
                while let (url, result) = await group.next() {
                    guard let self, self.runID == id, !Task.isCancelled else {
                        group.cancelAll()
                        return
                    }
                    self.finish(url, result, library: library)
                    if let next = addNext() { self.checking.insert(next) }
                }
            }
            guard let self, self.runID == id else { return }
            self.isRunning = false
            self.checking = []
            self.task = nil
        }
    }

    func cancel() {
        runID += 1
        task?.cancel()
        task = nil
        checking = []
        isRunning = false
    }

    nonisolated private static func probe(_ source: BookSource, keyword: String, env: SourceEnvironment) async -> Result<Int64, Error> {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let books = try await withTimeout(.seconds(20)) {
                try await WebBook(source: source, environment: env).searchBook(keyword)
            }
            guard !books.isEmpty else { return .failure(CheckError.empty) }
            return .success(Int64((clock.now - start) / .milliseconds(1)))
        } catch {
            return .failure(error)
        }
    }

    private func finish(_ url: String, _ result: Result<Int64, Error>, library: LibraryServices) {
        completed += 1
        checking.remove(url)
        guard var source = library.sources.source(for: url) else { return }
        var groups = source.groups
        switch result {
        case .success(let millis):
            messages[url] = nil
            source.respondTime = millis
            groups.removeAll { $0 == Self.brokenGroup }
        case .failure(let error):
            // 需要登录的书源在登录前搜索必然失败，不算失效
            if source.hasLogin, library.webBook(for: source).savedLoginInfo.isEmpty {
                messages[url] = Self.loginRequired
                groups.removeAll { $0 == Self.brokenGroup }
            } else {
                messages[url] = error.localizedDescription
                source.respondTime = 180_000
                if !groups.contains(Self.brokenGroup) { groups.append(Self.brokenGroup) }
            }
        }
        source.bookSourceGroup = groups.isEmpty ? nil : groups.joined(separator: ",")
        library.sources.save(source)
    }

    nonisolated private enum CheckError: LocalizedError {
        case empty
        var errorDescription: String? { "搜索无结果" }
    }
}

extension BookSource {
    var isBroken: Bool { groups.contains(SourceChecker.brokenGroup) }

    /// 校验过的响应时间（毫秒）；180000 为 Legado 的未校验默认值
    var checkedTime: Int64? {
        respondTime > 0 && respondTime < 180_000 ? respondTime : nil
    }
}
