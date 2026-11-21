import ReaderModels
import ReaderServices
import SwiftUI

/// 书源管理（原型 `page-sources`）：搜索、分组筛选、启用开关、校验、多选批量操作与导入
struct SourcesScreen: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var filter = SourcesScreen.all
    @State private var scrolled = false
    @State private var importing = false
    @State private var selecting = false
    @State private var selection: Set<String> = []
    @State private var opened: OpenedSource?
    @State private var grouping = false
    @State private var groupName = ""
    @State private var deleting = false
    @State private var appeared = false

    static let all = "全部"
    static let ungrouped = "未分组"

    private var repo: SourceRepository { app.library.sources }

    private var filters: [String] {
        var list = [Self.all] + repo.groups
        if repo.sources.contains(where: { $0.groups.isEmpty }) { list.append(Self.ungrouped) }
        return list
    }

    var body: some View {
        let filters = filters
        let current = filters.contains(filter) ? filter : Self.all
        let list = visible(current)
        ZStack(alignment: .top) {
            ScreenBackground()
            ScrollView {
                VStack(spacing: 0) {
                    header
                    SearchField(text: $query)
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                        .padding(.bottom, 14)
                    if filters.count > 2 {
                        chips(filters, current: current)
                    }
                    if list.isEmpty {
                        empty
                    } else {
                        rows(list)
                    }
                }
                .padding(.bottom, selecting ? 130 : 56)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .trackScroll($scrolled, threshold: 60)
            PageBar(title: "书源", scrolled: scrolled) { trailing(list) }
            ProgressLine(value: app.checker.total > 0 ? Double(app.checker.completed) / Double(app.checker.total) : 0,
                         done: !app.checker.isRunning)
                .padding(.horizontal, 20)
                .padding(.top, 46)
                .allowsHitTesting(false)
            if selecting {
                SourceBatchBar(count: selection.count, allSelected: !list.isEmpty && selection.isSuperset(of: list.map(\.id))) { action in
                    perform(action, visible: list)
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: selecting)
        .sheet(item: $opened) { item in
            SourceSheet(url: item.id)
        }
        .sheet(isPresented: $importing) {
            ImportSheet()
        }
        .alert("设置分组", isPresented: $grouping) {
            TextField("分组名", text: $groupName)
            Button("取消", role: .cancel) {}
            Button("确定") {
                let name = groupName.trimmingCharacters(in: .whitespaces)
                withAnimation(.snappy) { repo.setGroup(name, for: selection) }
                app.island.show("folder", name.isEmpty ? "已清除分组" : "已移入「\(name)」")
            }
        } message: {
            Text("多个分组用逗号分隔，留空则清除")
        }
        .confirmationDialog("删除 \(selection.count) 个书源", isPresented: $deleting, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                let count = selection.count
                withAnimation(.snappy) {
                    repo.delete(selection)
                    selection = []
                }
                app.island.show("trash", "已删除 \(count) 个书源", danger: true)
            }
        }
        .onAppear { appeared = true }
        .task { await debugOpen() }
    }

    private func debugOpen() async {
        #if DEBUG
        guard let action = DebugLaunch.flag("sheet") else { return }
        try? await Task.sleep(for: .milliseconds(1200))
        switch action {
        case "import": importing = true
        case "source":
            let name = DebugLaunch.flag("sourceName")
            opened = (repo.sources.first { name.map($0.bookSourceName.contains) ?? true }).map { OpenedSource(id: $0.id) }
        case "select":
            selecting = true
            selection = Set(repo.sources.prefix(1).map(\.id))
        case "check": check(repo.sources.map(\.id))
        default: break
        }
        #endif
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("书源").font(.serif(34)).tracking(0.5).foregroundStyle(Tok.fg)
            Text("\(repo.sources.count)")
                .font(.num(15))
                .foregroundStyle(Tok.fg3)
                .contentTransition(.numericText())
                .animation(.snappy, value: repo.sources.count)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 50)
        .padding(.bottom, 14)
    }

    private func chips(_ filters: [String], current: String) -> some View {
        let index = Binding<Int> {
            filters.firstIndex(of: current) ?? 0
        } set: { value in
            filter = filters[value]
        }
        return ScrollView(.horizontal) {
            SegmentedChips(items: filters.map { SourceName.full($0) }, selection: index)
        }
        .scrollIndicators(.hidden)
        .contentMargins(.horizontal, 20)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private func trailing(_ list: [BookSource]) -> some View {
        if selecting {
            CircleButton(systemName: "checkmark") {
                selecting = false
                selection = []
            }
            .transition(.scale.combined(with: .opacity))
        } else {
            Menu {
                if app.checker.isRunning {
                    Button("停止校验", icon: "stop.circle") { app.checker.cancel() }
                } else {
                    Button("校验", icon: "checkmark.seal") { check(list.map(\.id)) }
                }
                Button("多选", icon: "checkmark.circle") { selecting = true }
                Button("新建", icon: "square.and.pencil") { app.push(.sourceEditor(url: nil)) }
                Button("导出", icon: "square.and.arrow.up") { export(Set(list.map(\.id))) }
            } label: {
                Image(icon: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Tok.fg)
                    .glassCircle()
                    .frame(width: 44, height: 48)
                    .contentShape(Rectangle())
            }
            .menuOrder(.fixed)
            CircleButton(systemName: "plus") { importing = true }
        }
    }

    // MARK: - 列表

    private func rows(_ list: [BookSource]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(list.enumerated()), id: \.element.id) { index, source in
                SourceRow(source: source,
                          separator: index > 0,
                          selecting: selecting,
                          selected: selection.contains(source.id),
                          checking: app.checker.checking.contains(source.id),
                          note: app.checker.messages[source.id]) {
                    if selecting {
                        UISelectionFeedbackGenerator().selectionChanged()
                        if selection.contains(source.id) { selection.remove(source.id) } else { selection.insert(source.id) }
                    } else {
                        opened = OpenedSource(id: source.id)
                    }
                } onToggle: { on in
                    repo.setEnabled(on, for: [source.id])
                }
                .contextMenu { menu(source) }
                .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .cardSurface()
        .padding(.horizontal, 16)
        .animation(.snappy, value: list.map(\.id))
        .entrance(appeared, delay: 0.06, rise: 24)
    }

    @ViewBuilder
    private func menu(_ source: BookSource) -> some View {
        Button("编辑", icon: "curlybraces") { app.push(.sourceEditor(url: source.id)) }
        Button("置顶", icon: "arrow.up.to.line") { move(source.id, top: true) }
        Button("置底", icon: "arrow.down.to.line") { move(source.id, top: false) }
        Button("校验", icon: "checkmark.seal") { check([source.id]) }
        Button("分享", icon: "square.and.arrow.up") { export([source.id]) }
        Divider()
        Button("删除", icon: "trash", role: .destructive) {
            withAnimation(.snappy) { repo.delete([source.id]) }
        }
    }

    private var empty: some View {
        VStack(spacing: 18) {
            Image(icon: query.isEmpty ? "square.stack.3d.up.slash" : "magnifyingglass")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Tok.fg3)
            if repo.sources.isEmpty {
                AccentButton(title: "导入", icon: "plus") { importing = true }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
    }

    // MARK: - 操作

    private func visible(_ current: String) -> [BookSource] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return repo.sources.filter { source in
            switch current {
            case Self.all: break
            case Self.ungrouped: if !source.groups.isEmpty { return false }
            default: if !source.groups.contains(current) { return false }
            }
            guard !q.isEmpty else { return true }
            return source.bookSourceName.localizedCaseInsensitiveContains(q)
                || source.bookSourceUrl.localizedCaseInsensitiveContains(q)
                || (source.bookSourceComment ?? "").localizedCaseInsensitiveContains(q)
        }
    }

    private func check(_ urls: [String]) {
        app.checker.check(urls, library: app.library)
        if !app.checker.isRunning {
            app.island.show("exclamationmark.triangle", "没有可校验的书源", danger: true)
        }
    }

    private func move(_ url: String, top: Bool) {
        guard let index = repo.sources.firstIndex(where: { $0.id == url }) else { return }
        withAnimation(.snappy) {
            repo.move(fromOffsets: IndexSet(integer: index), toOffset: top ? 0 : repo.sources.count)
        }
    }

    private func export(_ urls: Set<String>) {
        guard !urls.isEmpty, let data = try? repo.export(urls) else { return }
        Share.file(data, name: "书源-\(Formats.stamp()).json")
    }

    private func perform(_ action: SourceBatchAction, visible list: [BookSource]) {
        let ids = list.map(\.id)
        switch action {
        case .selectAll:
            withAnimation(.snappy) {
                if selection.isSuperset(of: ids) { selection.subtract(ids) } else { selection.formUnion(ids) }
            }
        case .enable(let on):
            guard !selection.isEmpty else { return }
            repo.setEnabled(on, for: selection)
        case .group:
            guard !selection.isEmpty else { return }
            groupName = ""
            grouping = true
        case .check:
            guard !selection.isEmpty else { return }
            check(repo.sources.map(\.id).filter(selection.contains))
        case .export:
            export(selection)
        case .delete:
            guard !selection.isEmpty else { return }
            deleting = true
        }
    }
}

struct OpenedSource: Identifiable {
    let id: String
}

/// 搜索框（原型 `.field`）
struct SearchField: View {
    @Binding var text: String
    var placeholder = "搜索"

    var body: some View {
        HStack(spacing: 8) {
            Image(icon: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Tok.fg3)
            TextField(placeholder, text: $text)
                .font(.ui(16))
                .foregroundStyle(Tok.fg)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !text.isEmpty {
                Button {
                    withAnimation(.snappy) { text = "" }
                } label: {
                    Image(icon: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Tok.fg3)
                }
                .buttonStyle(.press)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Tok.fill, in: Capsule())
        .overlay(Capsule().strokeBorder(Tok.edge, lineWidth: 0.5))
        .animation(.snappy, value: text.isEmpty)
    }
}

// MARK: - 行

private struct SourceRow: View {
    let source: BookSource
    let separator: Bool
    let selecting: Bool
    let selected: Bool
    let checking: Bool
    var note: String?
    let onTap: () -> Void
    let onToggle: (Bool) -> Void

    var body: some View {
        ZStack {
            Button(action: onTap) { Color.clear }
                .buttonStyle(.row)
            HStack(spacing: 12) {
                if selecting {
                    Image(icon: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundStyle(selected ? Tok.accentInk : Tok.fg3)
                        .contentTransition(.symbolEffect(.replace))
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(SourceName.full(source.bookSourceName))
                            .font(.ui(16))
                            .foregroundStyle(source.isBroken ? Tok.fg2 : Tok.fg)
                            .lineLimit(1)
                        if source.hasLogin {
                            Image(icon: "key")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Tok.fg3)
                        }
                    }
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.num(12))
                            .foregroundStyle(Tok.fg3)
                            .lineLimit(1)
                            .contentTransition(.numericText())
                            .animation(.snappy, value: subtitle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)
                if !selecting {
                    Toggle("", isOn: Binding { source.enabled } set: { onToggle($0) })
                        .labelsHidden()
                        .tint(Tok.accent)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .padding(.leading, 20)
            .padding(.trailing, 14)
        }
        .frame(height: 64)
        .overlay(alignment: .leading) {
            StatusDot(broken: source.isBroken, checking: checking)
                .padding(.leading, 8)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .top) {
            if separator {
                Rectangle().fill(Tok.line).frame(height: 0.5).padding(.leading, 20)
            }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        let groups = source.groups.filter { $0 != SourceChecker.brokenGroup }.map(\.withoutEmoji).filter { !$0.isEmpty }
        if !groups.isEmpty {
            parts.append(groups.joined(separator: "、"))
        } else if let host = URL(string: source.bookSourceUrl)?.host() {
            parts.append(host)
        }
        if checking {
            parts.append("校验中")
        } else if note == SourceChecker.loginRequired {
            parts.append(SourceChecker.loginRequired)
        } else if source.isBroken {
            parts.append("失效")
        } else if let millis = source.checkedTime {
            parts.append("\(millis) ms")
        }
        return parts.joined(separator: " · ")
    }
}

/// 行首状态点：校验中呼吸，失效为强调色点加浅色外环（原型 `.src-dot`）
private struct StatusDot: View {
    let broken: Bool
    let checking: Bool

    var body: some View {
        ZStack {
            if checking {
                Circle()
                    .fill(Tok.fg3)
                    .phaseAnimator([0.2, 1.0]) { content, phase in
                        content.opacity(phase)
                    } animation: { _ in
                        .easeInOut(duration: 0.6)
                    }
                    .transition(.opacity)
            } else if broken {
                Circle()
                    .fill(Tok.accent)
                    .background(Circle().fill(Tok.accentSoft).padding(-3))
                    .transition(.scale(scale: 0.2).combined(with: .opacity))
            }
        }
        .frame(width: 6, height: 6)
        .animation(.bouncy, value: broken)
        .animation(.easeOut(duration: 0.2), value: checking)
    }
}

// MARK: - 批量操作栏

enum SourceBatchAction {
    case selectAll, enable(Bool), group, check, export, delete
}

private struct SourceBatchBar: View {
    let count: Int
    let allSelected: Bool
    let onAction: (SourceBatchAction) -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text(count > 0 ? "已选 \(count)" : "未选择")
                .font(.num(13, .medium))
                .foregroundStyle(Tok.fg2)
                .contentTransition(.numericText())
                .animation(.snappy, value: count)
            HStack(spacing: 0) {
                item(allSelected ? "取消全选" : "全选", allSelected ? "circle.dashed" : "checklist", .selectAll, enabled: true)
                Menu {
                    Button("启用", icon: "power") { onAction(.enable(true)) }
                    Button("停用", icon: "poweroff") { onAction(.enable(false)) }
                } label: {
                    label("启用", "power")
                }
                .disabled(count == 0)
                .opacity(count == 0 ? 0.4 : 1)
                item("分组", "folder", .group, enabled: count > 0)
                item("校验", "checkmark.seal", .check, enabled: count > 0)
                item("导出", "square.and.arrow.up", .export, enabled: count > 0)
                item("删除", "trash", .delete, enabled: count > 0, tint: Tok.accentInk)
            }
            .padding(.horizontal, 8)
            .frame(height: 64)
            .glassSurface(Capsule(), strong: true)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func item(_ title: String, _ symbol: String, _ action: SourceBatchAction, enabled: Bool, tint: Color = Tok.gFg) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onAction(action)
        } label: {
            label(title, symbol, tint: tint)
        }
        .buttonStyle(.press)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    private func label(_ title: String, _ symbol: String, tint: Color = Tok.gFg) -> some View {
        VStack(spacing: 4) {
            Image(icon: symbol)
                .font(.system(size: 18, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
            Text(title).font(.ui(10, .medium)).lineLimit(1)
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity, minHeight: 52)
        .contentShape(Rectangle())
    }
}
