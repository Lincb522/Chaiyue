import Foundation
import Observation
import ReaderModels
import RuleEngine

/// 聚合后的搜索结果：同名同作者的书合并为一项，`items` 为各书源的结果
public struct AggregatedBook: Identifiable, Hashable, Sendable {
    public let key: String
    public var name: String
    public var author: String
    public var items: [SearchBook]
    /// 首次出现的顺序，排序时作为最后的比较依据，保证结果稳定
    let sequence: Int

    public var id: String { key }
    public var primary: SearchBook { items[0] }
    public var sourceCount: Int { items.count }
    public var coverUrl: String? { items.lazy.compactMap(\.coverUrl.nilIfEmpty).first }
    public var intro: String? { items.lazy.compactMap(\.intro.nilIfEmpty).first }
    public var kind: String? { items.lazy.compactMap(\.kind.nilIfEmpty).first }
    public var wordCount: String? { items.lazy.compactMap(\.wordCount.nilIfEmpty).first }
    public var latestChapterTitle: String? { items.lazy.compactMap(\.latestChapterTitle.nilIfEmpty).first }

    public static func key(name: String, author: String) -> String {
        normalize(name) + "\u{1}" + normalize(author)
    }

    static func normalize(_ text: String) -> String {
        text.filter { !$0.isWhitespace }.lowercased()
    }
}

public struct SearchFailure: Identifiable, Hashable, Sendable {
    public var sourceUrl: String
    public var sourceName: String
    public var message: String
    public var id: String { sourceUrl }
}

/// 多源并发搜索：限制并发数、单源超时、结果按书名+作者聚合并排序，可翻页与取消
@MainActor
@Observable
public final class SearchModel {
    public private(set) var keyword = ""
    public private(set) var results: [AggregatedBook] = []
    public private(set) var isSearching = false
    public private(set) var completed = 0
    public private(set) var total = 0
    public private(set) var failures: [SearchFailure] = []
    /// 精确搜索：只保留书名或作者包含关键字的结果
    public var precise = false
    public var concurrency = 8
    public var timeout: Duration = .seconds(30)

    @ObservationIgnored private let environment: SourceEnvironment
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var runID = 0
    @ObservationIgnored private var page = 1
    @ObservationIgnored private var sources: [BookSource] = []
    @ObservationIgnored private var sourcesWithMore: Set<String> = []
    @ObservationIgnored private var sequence = 0

    public init(environment: SourceEnvironment) {
        self.environment = environment
    }

    public var canLoadMore: Bool { !isSearching && !sourcesWithMore.isEmpty }

    public func search(_ keyword: String, sources: [BookSource]) {
        cancel()
        self.keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        results = []
        failures = []
        page = 1
        sequence = 0
        self.sources = sources.filter { !($0.searchUrl ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        guard !self.keyword.isEmpty else { return }
        run(self.sources, page: page)
    }

    public func loadMore() {
        guard canLoadMore else { return }
        page += 1
        run(sources.filter { sourcesWithMore.contains($0.bookSourceUrl) }, page: page)
    }

    public func cancel() {
        runID += 1
        task?.cancel()
        task = nil
        isSearching = false
    }

    public func clear() {
        cancel()
        keyword = ""
        results = []
        failures = []
        completed = 0
        total = 0
        sourcesWithMore = []
    }

    private func run(_ list: [BookSource], page: Int) {
        runID += 1
        let id = runID
        sourcesWithMore = []
        completed = 0
        total = list.count
        isSearching = !list.isEmpty
        let env = environment
        let keyword = keyword
        let timeout = timeout
        let limit = max(1, concurrency)
        task = Task { [weak self] in
            await withTaskGroup(of: (BookSource, Result<[SearchBook], Error>).self) { group in
                var iterator = list.makeIterator()
                func addNext() {
                    guard let source = iterator.next() else { return }
                    group.addTask {
                        (source, await Self.searchOne(source, keyword: keyword, page: page, env: env, timeout: timeout))
                    }
                }
                for _ in 0..<limit { addNext() }
                while let (source, result) = await group.next() {
                    guard let self, self.runID == id, !Task.isCancelled else {
                        group.cancelAll()
                        return
                    }
                    self.handle(source, result)
                    addNext()
                }
            }
            guard let self, self.runID == id else { return }
            self.isSearching = false
        }
    }

    nonisolated static func searchOne(_ source: BookSource, keyword: String, page: Int,
                                      env: SourceEnvironment, timeout: Duration) async -> Result<[SearchBook], Error> {
        do {
            let books = try await withTimeout(timeout) {
                try await WebBook(source: source, environment: env).searchBook(keyword, page: page)
            }
            return .success(books)
        } catch {
            return .failure(error)
        }
    }

    private func handle(_ source: BookSource, _ result: Result<[SearchBook], Error>) {
        completed += 1
        switch result {
        case .success(let books):
            if !books.isEmpty { sourcesWithMore.insert(source.bookSourceUrl) }
            merge(books)
        case .failure(let error):
            failures.append(SearchFailure(sourceUrl: source.bookSourceUrl, sourceName: source.bookSourceName,
                                          message: error.localizedDescription))
        }
    }

    func merge(_ books: [SearchBook]) {
        guard !books.isEmpty else { return }
        var indexByKey = Dictionary(results.enumerated().map { ($1.key, $0) }, uniquingKeysWith: { first, _ in first })
        for book in books {
            let name = book.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let author = book.author.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            if precise, !name.contains(keyword), !author.contains(keyword) { continue }
            let key = AggregatedBook.key(name: name, author: author)
            if let index = indexByKey[key] {
                if !results[index].items.contains(where: { $0.origin == book.origin }) {
                    results[index].items.append(book)
                }
            } else {
                sequence += 1
                indexByKey[key] = results.count
                results.append(AggregatedBook(key: key, name: name, author: author, items: [book], sequence: sequence))
            }
        }
        let keyword = keyword
        results.sort { a, b in
            let ta = Self.tier(a, keyword), tb = Self.tier(b, keyword)
            if ta != tb { return ta < tb }
            if a.sourceCount != b.sourceCount { return a.sourceCount > b.sourceCount }
            return a.sequence < b.sequence
        }
    }

    /// 0：书名或作者完全一致；1：包含关键字；2：其他
    nonisolated static func tier(_ book: AggregatedBook, _ keyword: String) -> Int {
        if book.name == keyword || book.author == keyword { return 0 }
        if book.name.contains(keyword) || book.author.contains(keyword) { return 1 }
        return 2
    }
}
