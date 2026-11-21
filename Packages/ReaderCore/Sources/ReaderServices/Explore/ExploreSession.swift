import Foundation
import Observation
import ReaderModels
import RuleEngine

/// 发现页条目的交互类型
public enum ExploreItemRole: Equatable, Sendable {
    /// 分组标题
    case title
    /// 点击进入书单
    case category(url: String)
    /// 整个地址是一段 `{{脚本}}`（如打开登录页），点击直接执行
    case script(String)
    case select(options: [String])
    case toggle(options: [String])
    case text
    case button
}

public extension ExploreKind {
    var role: ExploreItemRole {
        switch type ?? "url" {
        case "select": return .select(options: chars ?? [])
        case "toggle": return .toggle(options: chars ?? [])
        case "text": return .text
        case "button": return .button
        default:
            let url = (url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if url.isEmpty { return .title }
            if url.hasPrefix("{{"), url.hasSuffix("}}"), url.components(separatedBy: "{{").count == 2 {
                let script = String(url.dropFirst(2).dropLast(2))
                if !script.contains("page") { return .script(script) }
            }
            return .category(url: url)
        }
    }
}

/// 一个书源的发现页：分类与筛选控件。控件的当前值按书源持久化，执行控件脚本时作为 `infoMap` 传入；
/// 脚本调用 `java.refreshExplore()` 时通过 `handle(_:)` 重新生成分类
@MainActor
@Observable
public final class ExploreSession {
    public let source: BookSource
    public private(set) var kinds: [ExploreKind] = []
    public private(set) var infoMap: [String: String]
    public private(set) var isLoading = false
    public private(set) var isRunningAction = false
    public private(set) var errorMessage: String?
    /// 分类被脚本或登录刷新过的次数。界面据此换掉已经作废的书单
    public private(set) var generation = 0
    @ObservationIgnored private let environment: SourceEnvironment
    @ObservationIgnored private var reloading = false
    @ObservationIgnored private var reloadPending = false

    public init(source: BookSource, environment: SourceEnvironment) {
        self.source = source
        self.environment = environment
        infoMap = ExploreInfoStore.load(environment.store, sourceUrl: source.bookSourceUrl)
    }

    private var webBook: WebBook { WebBook(source: source, environment: environment) }

    public func load(refresh: Bool = false) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            kinds = try await webBook.exploreKinds(refresh: refresh)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 控件当前值：用户设置过的值 → 书源默认值 → 第一个选项
    public func value(for kind: ExploreKind) -> String {
        infoMap[kind.title] ?? kind.defaultValue ?? kind.chars?.first ?? ""
    }

    /// 下拉选择：保存新值并执行控件脚本
    public func select(_ value: String, for kind: ExploreKind) async {
        setValue(value, for: kind)
        await run(kind.action)
    }

    /// 开关：切换到下一个选项并执行控件脚本
    public func toggle(_ kind: ExploreKind) async {
        let options = kind.chars ?? []
        guard !options.isEmpty else { return }
        let next = options.firstIndex(of: value(for: kind)).map { ($0 + 1) % options.count } ?? 0
        await select(options[next], for: kind)
    }

    /// 输入框：编辑时只保存，提交时再执行脚本
    public func setText(_ text: String, for kind: ExploreKind) {
        setValue(text, for: kind)
    }

    public func submit(_ kind: ExploreKind) async {
        await run(kind.action)
    }

    /// 按钮与脚本条目
    public func press(_ kind: ExploreKind) async {
        if case .script(let script) = kind.role {
            await run(script)
        } else {
            await run(kind.action)
        }
    }

    /// 重新生成分类（脚本要求刷新、登录状态变化）。进行中再次请求时等这次结束再来一次，避免旧结果后到覆盖新结果
    public func reload() async {
        guard !reloading else {
            reloadPending = true
            return
        }
        reloading = true
        defer { reloading = false }
        repeat {
            reloadPending = false
            await load(refresh: true)
        } while reloadPending
        generation += 1
    }

    public func handle(_ event: SourceEvent) async {
        if case .refreshExplore(let key) = event, key == source.bookSourceUrl {
            await reload()
        }
    }

    private func setValue(_ value: String, for kind: ExploreKind) {
        infoMap[kind.title] = value
        ExploreInfoStore.save(infoMap, store: environment.store, sourceUrl: source.bookSourceUrl)
    }

    private func run(_ action: String?) async {
        guard let action, !action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isRunningAction = true
        errorMessage = nil
        defer { isRunningAction = false }
        do {
            try await webBook.runExploreAction(action, infoMap: infoMap)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// 发现书单：逐页加载，按 bookUrl 去重；某页没有新书时视为到底（与 Legado 一致，不依赖地址里是否有页码）
@MainActor
@Observable
public final class ExploreBookList {
    public let source: BookSource
    public let url: String
    public private(set) var books: [SearchBook] = []
    public private(set) var isLoading = false
    public private(set) var isFinished = false
    public private(set) var errorMessage: String?
    @ObservationIgnored private let environment: SourceEnvironment
    @ObservationIgnored private var page = 1
    @ObservationIgnored private var known: Set<String> = []
    @ObservationIgnored private var generation = 0

    public init(source: BookSource, url: String, environment: SourceEnvironment) {
        self.source = source
        self.url = url
        self.environment = environment
    }

    public func loadMore() async {
        guard !isLoading, !isFinished else { return }
        isLoading = true
        errorMessage = nil
        let current = generation
        defer { if current == generation { isLoading = false } }
        do {
            let items = try await WebBook(source: source, environment: environment).exploreBook(url: url, page: page)
            guard current == generation else { return }
            let fresh = items.filter { known.insert($0.bookUrl).inserted }
            books += fresh
            page += 1
            if fresh.isEmpty { isFinished = true }
        } catch {
            guard current == generation else { return }
            errorMessage = error.localizedDescription
        }
    }

    public func reload() async {
        generation += 1
        books = []
        known = []
        page = 1
        isFinished = false
        isLoading = false
        await loadMore()
    }
}
