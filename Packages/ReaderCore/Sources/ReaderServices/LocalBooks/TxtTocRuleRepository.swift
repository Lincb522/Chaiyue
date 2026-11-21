import Foundation
import Observation
import ReaderModels

/// TXT 目录规则：内置规则（id 为负数）只能启用或停用，自定义规则可增删改。
/// 只持久化自定义规则与内置规则的启用状态，内置规则表随版本更新
@MainActor
@Observable
public final class TxtTocRuleRepository {
    struct State: Codable, Sendable {
        var custom: [TxtTocRule] = []
        var builtInEnabled: [String: Bool] = [:]
    }

    public private(set) var rules: [TxtTocRule] = []
    @ObservationIgnored private let store: JSONFileStore<State>

    public init(fileURL: URL) {
        store = JSONFileStore(url: fileURL) { State() }
        rebuild()
    }

    /// 自动识别使用的规则，按优先级排序
    public var enabledRules: [TxtTocRule] {
        rules.filter { $0.enable && !$0.rule.isEmpty }
    }

    public func isBuiltIn(_ rule: TxtTocRule) -> Bool {
        rule.id < 0 && TxtTocRule.defaults.contains { $0.id == rule.id }
    }

    public func setEnabled(_ enabled: Bool, for ids: Set<Int64>) {
        store.update { state in
            for id in ids {
                if TxtTocRule.defaults.contains(where: { $0.id == id }) {
                    state.builtInEnabled[String(id)] = enabled
                } else if let index = state.custom.firstIndex(where: { $0.id == id }) {
                    state.custom[index].enable = enabled
                }
            }
        }
        rebuild()
    }

    /// 保存自定义规则；内置规则只更新启用状态
    public func save(_ rule: TxtTocRule) {
        if isBuiltIn(rule) {
            setEnabled(rule.enable, for: [rule.id])
            return
        }
        store.update { state in
            var rule = rule
            if rule.id <= 0 { rule.id = Self.newID(existing: state.custom) }
            if let index = state.custom.firstIndex(where: { $0.id == rule.id }) {
                state.custom[index] = rule
            } else {
                if rule.serialNumber <= 0 {
                    rule.serialNumber = (TxtTocRule.defaults + state.custom).map(\.serialNumber).max().map { $0 + 1 } ?? 0
                }
                state.custom.append(rule)
            }
        }
        rebuild()
    }

    public func delete(_ ids: Set<Int64>) {
        store.update { $0.custom.removeAll { ids.contains($0.id) } }
        rebuild()
    }

    /// 导入 Legado 格式的规则：与内置规则同 id 的只同步启用状态，其余作为自定义规则按 id 合并
    @discardableResult
    public func importRules(_ incoming: [TxtTocRule]) -> ImportSummary {
        var summary = ImportSummary()
        store.update { state in
            for var rule in incoming where !rule.rule.isEmpty {
                if let builtIn = TxtTocRule.defaults.first(where: { $0.id == rule.id }), builtIn.rule == rule.rule {
                    let changed = (state.builtInEnabled[String(rule.id)] ?? builtIn.enable) != rule.enable
                    state.builtInEnabled[String(rule.id)] = rule.enable
                    if changed { summary.updated += 1 } else { summary.unchanged += 1 }
                    continue
                }
                if rule.id <= 0 { rule.id = Self.newID(existing: state.custom) }
                if let index = state.custom.firstIndex(where: { $0.id == rule.id }) {
                    if state.custom[index] == rule {
                        summary.unchanged += 1
                    } else {
                        state.custom[index] = rule
                        summary.updated += 1
                    }
                } else {
                    state.custom.append(rule)
                    summary.added += 1
                }
            }
        }
        rebuild()
        return summary
    }

    /// 恢复备份：自定义规则整体替换，内置规则按备份同步启用状态
    public func replaceAll(_ incoming: [TxtTocRule]) {
        var state = State()
        for var rule in incoming where !rule.rule.isEmpty {
            if let builtIn = TxtTocRule.defaults.first(where: { $0.id == rule.id }), builtIn.rule == rule.rule {
                state.builtInEnabled[String(rule.id)] = rule.enable
                continue
            }
            if rule.id <= 0 { rule.id = Self.newID(existing: state.custom) }
            if let index = state.custom.firstIndex(where: { $0.id == rule.id }) {
                state.custom[index] = rule
            } else {
                state.custom.append(rule)
            }
        }
        store.update { $0 = state }
        rebuild()
    }

    public func resetBuiltIns() {
        store.update { $0.builtInEnabled = [:] }
        rebuild()
    }

    public func flush() {
        store.flush()
    }

    private func rebuild() {
        let state = store.current
        let builtIns = TxtTocRule.defaults.map { rule in
            var rule = rule
            rule.enable = state.builtInEnabled[String(rule.id)] ?? rule.enable
            return rule
        }
        rules = (builtIns + state.custom).enumerated()
            .sorted { ($0.element.serialNumber, $0.offset) < ($1.element.serialNumber, $1.offset) }
            .map(\.element)
    }

    private static func newID(existing: [TxtTocRule]) -> Int64 {
        max(Int64(Date().timeIntervalSince1970 * 1000), (existing.map(\.id).max() ?? 0) + 1)
    }
}
