import ReaderModels
import ReaderServices
import SwiftUI

/// 替换净化规则：与书源页同一套布局，点按编辑，长按排序与分享
struct ReplaceRulesScreen: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var filter = SourcesScreen.all
    @State private var scrolled = false
    @State private var importing = false
    @State private var editing: EditingRule?
    @State private var appeared = false

    private var repo: ReplaceRuleRepository { app.library.replaceRules }

    private var filters: [String] {
        var list = [SourcesScreen.all] + repo.groups
        if repo.rules.contains(where: { ReplaceRule.groups($0.group).isEmpty }) { list.append(SourcesScreen.ungrouped) }
        return list
    }

    var body: some View {
        let filters = filters
        let current = filters.contains(filter) ? filter : SourcesScreen.all
        let list = visible(current)
        ZStack(alignment: .top) {
            ScreenBackground()
            ScrollView {
                VStack(spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("替换净化").font(.serif(34)).tracking(0.5).foregroundStyle(Tok.fg)
                        Text("\(repo.rules.count)")
                            .font(.num(15))
                            .foregroundStyle(Tok.fg3)
                            .contentTransition(.numericText())
                            .animation(.snappy, value: repo.rules.count)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 50)
                    .padding(.bottom, 14)
                    if !repo.rules.isEmpty {
                        SearchField(text: $query)
                            .padding(.horizontal, 20)
                            .padding(.top, 4)
                            .padding(.bottom, 14)
                    }
                    if filters.count > 2 {
                        let index = Binding<Int> { filters.firstIndex(of: current) ?? 0 } set: { filter = filters[$0] }
                        ScrollView(.horizontal) {
                            SegmentedChips(items: filters, selection: index)
                        }
                        .scrollIndicators(.hidden)
                        .contentMargins(.horizontal, 20)
                        .padding(.bottom, 14)
                    }
                    if list.isEmpty {
                        empty
                    } else {
                        rows(list)
                    }
                }
                .padding(.bottom, 56)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .trackScroll($scrolled, threshold: 60)
            PageBar(title: "替换净化", scrolled: scrolled) {
                Menu {
                    Button("新建", icon: "square.and.pencil") { editing = EditingRule(rule: ReplaceRule()) }
                    Button("全部启用", icon: "power") { repo.setEnabled(true, for: Set(list.map(\.id))) }
                    Button("全部停用", icon: "poweroff") { repo.setEnabled(false, for: Set(list.map(\.id))) }
                    Button("导出", icon: "square.and.arrow.up") { export(Set(list.map(\.id))) }
                } label: {
                    Image(icon: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Tok.fg)
                        .glassCircle()
                }
                .menuOrder(.fixed)
                CircleButton(systemName: "plus") { importing = true }
            }
        }
        .sheet(item: $editing) { item in
            RuleEditorSheet(rule: item.rule)
        }
        .sheet(isPresented: $importing) {
            ImportSheet(title: "导入规则")
        }
        .onAppear { appeared = true }
        .task { await debugOpen() }
    }

    private func debugOpen() async {
        #if DEBUG
        guard DebugLaunch.flag("sheet") == "rule" else { return }
        try? await Task.sleep(for: .milliseconds(1200))
        var rule = ReplaceRule(name: "去站点尾巴", pattern: "^.*(请记住|最新章节).*$", replacement: "")
        rule.group = "净化"
        editing = EditingRule(rule: rule)
        #endif
    }

    private func rows(_ list: [ReplaceRule]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(list.enumerated()), id: \.element.id) { index, rule in
                RuleRow(rule: rule, separator: index > 0) {
                    editing = EditingRule(rule: rule)
                } onToggle: { on in
                    repo.setEnabled(on, for: [rule.id])
                }
                .contextMenu {
                    Button("编辑", icon: "pencil") { editing = EditingRule(rule: rule) }
                    Button("置顶", icon: "arrow.up.to.line") { move(rule.id, top: true) }
                    Button("置底", icon: "arrow.down.to.line") { move(rule.id, top: false) }
                    Button("分享", icon: "square.and.arrow.up") { export([rule.id]) }
                    Divider()
                    Button("删除", icon: "trash", role: .destructive) {
                        withAnimation(.snappy) { repo.delete([rule.id]) }
                    }
                }
                .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .cardSurface()
        .padding(.horizontal, 16)
        .animation(.snappy, value: list.map(\.id))
        .entrance(appeared, delay: 0.06, rise: 24)
    }

    private var empty: some View {
        VStack(spacing: 18) {
            Image(icon: query.isEmpty ? "wand.and.stars" : "magnifyingglass")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Tok.fg3)
            if repo.rules.isEmpty {
                HStack(spacing: 12) {
                    AccentButton(title: "新建", icon: "plus") { editing = EditingRule(rule: ReplaceRule()) }
                    Button {
                        importing = true
                    } label: {
                        Label("导入", icon: "square.and.arrow.down")
                            .font(.ui(16, .semibold))
                            .foregroundStyle(Tok.fg)
                            .padding(.horizontal, 20)
                            .frame(height: 46)
                            .raisedSurface(Capsule())
                    }
                    .buttonStyle(.press)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
    }

    private func visible(_ current: String) -> [ReplaceRule] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return repo.rules.filter { rule in
            let groups = ReplaceRule.groups(rule.group)
            switch current {
            case SourcesScreen.all: break
            case SourcesScreen.ungrouped: if !groups.isEmpty { return false }
            default: if !groups.contains(current) { return false }
            }
            guard !q.isEmpty else { return true }
            return rule.name.localizedCaseInsensitiveContains(q) || rule.pattern.localizedCaseInsensitiveContains(q)
        }
    }

    private func move(_ id: Int64, top: Bool) {
        guard let index = repo.rules.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.snappy) {
            repo.move(fromOffsets: IndexSet(integer: index), toOffset: top ? 0 : repo.rules.count)
        }
    }

    private func export(_ ids: Set<Int64>) {
        guard !ids.isEmpty, let data = try? repo.export(ids) else { return }
        Share.file(data, name: "替换规则-\(Formats.stamp()).json")
    }
}

struct EditingRule: Identifiable {
    let id = UUID()
    var rule: ReplaceRule
}

extension ReplaceRule {
    static func groups(_ group: String?) -> [String] {
        (group ?? "")
            .components(separatedBy: CharacterSet(charactersIn: ",;，；"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 按规则处理一段文字（编辑页的即时预览）
    func apply(to text: String) -> String {
        guard !pattern.isEmpty else { return text }
        if isRegex {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return text }
            return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
        }
        return text.replacingOccurrences(of: pattern, with: replacement)
    }
}

private struct RuleRow: View {
    let rule: ReplaceRule
    let separator: Bool
    let onTap: () -> Void
    let onToggle: (Bool) -> Void

    var body: some View {
        ZStack {
            Button(action: onTap) { Color.clear }
                .buttonStyle(.row)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(rule.name.isEmpty ? rule.pattern : rule.name)
                        .font(.ui(16))
                        .foregroundStyle(rule.isEnabled ? Tok.fg : Tok.fg2)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if rule.isRegex {
                            Text(".*")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Tok.fg2)
                                .padding(.horizontal, 4)
                                .frame(height: 15)
                                .background(Tok.fill2, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }
                        Text(rule.pattern)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Tok.fg3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)
                Toggle("", isOn: Binding { rule.isEnabled } set: { onToggle($0) })
                    .labelsHidden()
                    .tint(Tok.accent)
            }
            .padding(.leading, 20)
            .padding(.trailing, 14)
        }
        .frame(height: 64)
        .overlay(alignment: .top) {
            if separator {
                Rectangle().fill(Tok.line).frame(height: 0.5).padding(.leading, 20)
            }
        }
    }
}

// MARK: - 编辑

/// 规则编辑：名称、匹配与替换、范围，底部即时预览
struct RuleEditorSheet: View {
    @State var rule: ReplaceRule
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var sample = ""
    @State private var deleting = false

    private var isNew: Bool { !app.library.replaceRules.rules.contains { $0.id == rule.id } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(isNew ? "新建规则" : "编辑规则").font(.serif(22)).foregroundStyle(Tok.gFg)
                Spacer()
                if !isNew {
                    Button {
                        deleting = true
                    } label: {
                        Image(icon: "trash")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Tok.gAccent)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.press)
                }
                Button {
                    save()
                } label: {
                    Image(icon: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Tok.onAccent)
                        .frame(width: 36, height: 36)
                        .background(Tok.accent, in: Circle())
                }
                .buttonStyle(.press)
                .disabled(rule.pattern.isEmpty)
                .opacity(rule.pattern.isEmpty ? 0.4 : 1)
            }
            .padding(.leading, 24)
            .padding(.trailing, 16)
            .padding(.top, 24)
            .padding(.bottom, 12)
            ScrollView {
                VStack(spacing: 12) {
                    field("名称", text: $rule.name)
                    field("分组", text: Binding { rule.group ?? "" } set: { rule.group = $0.isEmpty ? nil : $0 })
                    code("匹配", text: $rule.pattern)
                    code("替换为", text: $rule.replacement)
                    CardGroup(separatorInset: 14) {
                        ToggleRow(title: "正则", isOn: $rule.isRegex)
                        ToggleRow(title: "作用于标题", isOn: $rule.scopeTitle)
                        ToggleRow(title: "作用于正文", isOn: $rule.scopeContent)
                    }
                    field("范围（书名或书源，逗号分隔）", text: Binding { rule.scope ?? "" } set: { rule.scope = $0.isEmpty ? nil : $0 })
                    field("排除", text: Binding { rule.excludeScope ?? "" } set: { rule.excludeScope = $0.isEmpty ? nil : $0 })
                    preview
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
        .environment(\.onGlass, true)
        .qSheet([.large])
        .confirmationDialog("删除规则", isPresented: $deleting) {
            Button("删除", role: .destructive) {
                app.library.replaceRules.delete([rule.id])
                dismiss()
            }
        }
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .font(.ui(16))
            .foregroundStyle(Tok.gFg)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 18)
            .frame(height: 50)
            .background(Tok.gFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func code(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text, axis: .vertical)
            .font(.system(size: 14, design: .monospaced))
            .foregroundStyle(Tok.gFg)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .lineLimit(1...6)
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            .background(Tok.gFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// 输入一段样例，下方即时显示替换后的结果
    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("试一试", text: $sample, axis: .vertical)
                .font(.serif(15))
                .foregroundStyle(Tok.gFg)
                .lineLimit(1...5)
            if !sample.isEmpty {
                Rectangle().fill(Tok.gLine).frame(height: 0.5)
                Text(rule.apply(to: sample))
                    .font(.serif(15))
                    .foregroundStyle(Tok.gAccent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.2), value: rule.apply(to: sample))
            }
        }
        .padding(18)
        .background(Tok.gFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .animation(.snappy, value: sample.isEmpty)
    }

    private func save() {
        guard !rule.pattern.isEmpty else { return }
        if rule.isRegex, (try? NSRegularExpression(pattern: rule.pattern)) == nil {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            app.island.show("exclamationmark.triangle", "正则表达式有误", danger: true)
            return
        }
        app.library.replaceRules.save(rule)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }
}
