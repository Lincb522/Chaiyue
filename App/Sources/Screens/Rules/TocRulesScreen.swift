import ReaderModels
import ReaderServices
import SwiftUI

// MARK: - 目录规则

/// TXT 目录规则：内置规则只能启用或停用，自定义规则可编辑、删除。自动识别时只试启用的规则
struct TocRulesScreen: View {
    @Environment(AppModel.self) private var app
    @State private var scrolled = false
    @State private var editing: EditingTocRule?
    @State private var appeared = false

    private var repo: TxtTocRuleRepository { app.library.txtTocRules }

    var body: some View {
        let rules = repo.rules
        let enabled = repo.enabledRules.count
        ZStack(alignment: .top) {
            ScreenBackground()
            ScrollView {
                VStack(spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("目录规则").font(.serif(34)).tracking(0.5).foregroundStyle(Tok.fg)
                        Text("\(enabled)/\(rules.count)")
                            .font(.num(15))
                            .foregroundStyle(Tok.fg3)
                            .contentTransition(.numericText())
                            .animation(.snappy, value: enabled)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 50)
                    .padding(.bottom, 14)
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                            let builtIn = repo.isBuiltIn(rule)
                            TocRuleRow(rule: rule, builtIn: builtIn, separator: index > 0) {
                                editing = EditingTocRule(rule: rule)
                            } onToggle: { on in
                                repo.setEnabled(on, for: [rule.id])
                            }
                            .contextMenu {
                                Button(builtIn ? "查看" : "编辑", icon: builtIn ? "eye" : "pencil") {
                                    editing = EditingTocRule(rule: rule)
                                }
                                if !builtIn {
                                    Button("删除", icon: "trash", role: .destructive) {
                                        withAnimation(.snappy) { repo.delete([rule.id]) }
                                    }
                                }
                            }
                            .transition(.opacity)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
                    .cardSurface()
                    .padding(.horizontal, 16)
                    .animation(.snappy, value: rules.map(\.id))
                    .entrance(appeared, delay: 0.06, rise: 24)
                }
                .padding(.bottom, 56)
            }
            .scrollIndicators(.hidden)
            .trackScroll($scrolled, threshold: 60)
            PageBar(title: "目录规则", scrolled: scrolled) {
                Menu {
                    Button("全部启用", icon: "power") { repo.setEnabled(true, for: Set(rules.map(\.id))) }
                    Button("全部停用", icon: "poweroff") { repo.setEnabled(false, for: Set(rules.map(\.id))) }
                    Button("恢复默认", icon: "arrow.counterclockwise") {
                        withAnimation(.snappy) { repo.resetBuiltIns() }
                    }
                } label: {
                    Image(icon: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Tok.fg)
                        .glassCircle()
                }
                .menuOrder(.fixed)
                CircleButton(systemName: "plus") { editing = EditingTocRule(rule: TxtTocRule(id: 0, name: "", rule: "")) }
            }
        }
        .sheet(item: $editing) { item in
            TocRuleEditorSheet(rule: item.rule)
        }
        .onAppear { appeared = true }
    }
}

struct EditingTocRule: Identifiable {
    let id = UUID()
    var rule: TxtTocRule
}

private struct TocRuleRow: View {
    let rule: TxtTocRule
    let builtIn: Bool
    let separator: Bool
    let onTap: () -> Void
    let onToggle: (Bool) -> Void

    var body: some View {
        let example = rule.example.nilIfEmpty
        ZStack {
            Button(action: onTap) { Color.clear }
                .buttonStyle(.row)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(rule.name.isEmpty ? rule.rule : rule.name)
                            .font(.ui(16))
                            .foregroundStyle(rule.enable ? Tok.fg : Tok.fg2)
                            .lineLimit(1)
                        if !builtIn {
                            Text("自定义")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Tok.fg2)
                                .padding(.horizontal, 5)
                                .frame(height: 16)
                                .background(Tok.fill2, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }
                    }
                    Text(example ?? rule.rule)
                        .font(example == nil ? .system(size: 12, design: .monospaced) : .ui(12))
                        .foregroundStyle(Tok.fg3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)
                Toggle("", isOn: Binding { rule.enable } set: { onToggle($0) })
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

/// 目录规则编辑：名称、正则与示例（内置规则只读）。下方输入几行文字，即时标出会被当作章节标题的行
struct TocRuleEditorSheet: View {
    @State private var rule: TxtTocRule
    @State private var sample: String
    @State private var deleting = false
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    init(rule: TxtTocRule) {
        _rule = State(initialValue: rule)
        _sample = State(initialValue: rule.example ?? "")
    }

    private var repo: TxtTocRuleRepository { app.library.txtTocRules }
    private var isNew: Bool { !repo.rules.contains { $0.id == rule.id } }
    private var builtIn: Bool { repo.isBuiltIn(rule) }
    private var valid: Bool { !rule.rule.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: isNew ? "新建规则" : builtIn ? "内置规则" : "编辑规则") {
                if !isNew, !builtIn {
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
                Button(action: save) {
                    Image(icon: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Tok.onAccent)
                        .frame(width: 36, height: 36)
                        .background(Tok.accent, in: Circle())
                }
                .buttonStyle(.press)
                .disabled(!valid)
                .opacity(valid ? 1 : 0.4)
            }
            ScrollView {
                VStack(spacing: 12) {
                    Group {
                        field("名称", text: $rule.name)
                        TextField("正则", text: $rule.rule, axis: .vertical)
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundStyle(Tok.gFg)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .lineLimit(1...6)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 15)
                            .background(Tok.gFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        field("示例", text: Binding { rule.example ?? "" } set: { rule.example = $0.isEmpty ? nil : $0 })
                    }
                    .disabled(builtIn)
                    .opacity(builtIn ? 0.7 : 1)
                    CardGroup(separatorInset: 14) {
                        ToggleRow(title: "自动识别", isOn: $rule.enable)
                    }
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
                repo.delete([rule.id])
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

    /// 每行单独匹配；命中的行用强调色标出
    private var preview: some View {
        let regex = try? NSRegularExpression(pattern: rule.rule, options: [.anchorsMatchLines])
        let lines = sample.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return VStack(alignment: .leading, spacing: 10) {
            TextField("试一试", text: $sample, axis: .vertical)
                .font(.serif(15))
                .foregroundStyle(Tok.gFg)
                .lineLimit(1...8)
            if !lines.isEmpty {
                Rectangle().fill(Tok.gLine).frame(height: 0.5)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        let hit = regex.map { Self.matches($0, line) } ?? false
                        HStack(spacing: 8) {
                            Image(icon: hit ? "list.number" : "minus")
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 16)
                            Text(line)
                                .font(.serif(15))
                                .lineLimit(1)
                        }
                        .foregroundStyle(hit ? Tok.gAccent : Tok.gFg3)
                        .animation(.easeOut(duration: 0.2), value: hit)
                    }
                }
            }
        }
        .padding(18)
        .background(Tok.gFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .animation(.snappy, value: lines.isEmpty)
    }

    private static func matches(_ regex: NSRegularExpression, _ line: String) -> Bool {
        regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    private func save() {
        guard valid else { return }
        if builtIn {
            repo.setEnabled(rule.enable, for: [rule.id])
        } else {
            guard (try? NSRegularExpression(pattern: rule.rule, options: [.anchorsMatchLines])) != nil else {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                app.island.show("exclamationmark.triangle", "正则表达式有误", danger: true)
                return
            }
            if rule.name.trimmingCharacters(in: .whitespaces).isEmpty { rule.name = rule.rule }
            repo.save(rule)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        dismiss()
    }
}

// MARK: - 重新分章

extension AppModel {
    /// 只有本地 TXT 能重新分章
    func canResplit(_ book: Book) -> Bool {
        book.isLocal && library.localBooks.isTextBook(book) && LocalMediaImporter.kind(of: book) == nil
    }
}

/// TXT 重新分章：自动识别、指定目录规则或按长度分章，可换编码；下方即时预览分章结果
struct TxtSplitSheet: View {
    let book: Book
    var onDone: (Book) -> Void = { _ in }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var mode = 0
    @State private var ruleID: Int64?
    @State private var charset: Int
    @State private var source: DecodedText?
    @State private var preview: SplitPreview?
    @State private var working = false

    private static let modes = ["自动识别", "目录规则", "按长度"]
    private static let charsets: [(title: String, value: String)] = [
        ("UTF-8", "UTF-8"), ("GBK", "GB18030"), ("Big5", "Big5"), ("UTF-16LE", "UTF-16LE"), ("UTF-16BE", "UTF-16BE"),
    ]

    init(book: Book, onDone: @escaping (Book) -> Void = { _ in }) {
        self.book = book
        self.onDone = onDone
        let current = (book.charset ?? "").lowercased()
        let index = Self.charsets.firstIndex { $0.value.lowercased() == current } ?? (current.hasPrefix("gb") ? 1 : 0)
        _charset = State(initialValue: index)
    }

    private var rules: [TxtTocRule] { app.library.txtTocRules.rules }

    private var selectedRule: TxtTocRule? {
        let rules = rules
        if let ruleID, let rule = rules.first(where: { $0.id == ruleID }) { return rule }
        let pattern = (preview?.pattern).nilIfEmpty ?? book.tocUrl
        return rules.first { $0.rule == pattern } ?? rules.first(where: \.enable)
    }

    private var tocMode: TxtTocMode? {
        switch mode {
        case 1: selectedRule.map { .pattern($0.rule) }
        case 2: .byLength
        default: .auto
        }
    }

    var body: some View {
        let selected = mode == 1 ? selectedRule : nil
        VStack(spacing: 0) {
            SheetHeader(title: "重新分章") {
                Button(action: apply) {
                    ZStack {
                        Image(icon: "checkmark")
                            .font(.system(size: 16, weight: .bold))
                            .opacity(working ? 0 : 1)
                        if working { ProgressView().tint(Tok.onAccent) }
                    }
                    .foregroundStyle(Tok.onAccent)
                    .frame(width: 36, height: 36)
                    .background(Tok.accent, in: Circle())
                }
                .buttonStyle(.press)
                .disabled(!canApply)
                .opacity(canApply ? 1 : 0.4)
            }
            ScrollView {
                VStack(spacing: 14) {
                    SegmentedChips(items: Self.modes, selection: $mode, height: 36, glass: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    CardGroup(separatorInset: 14) {
                        Menu {
                            Picker("编码", selection: $charset) {
                                ForEach(Self.charsets.indices, id: \.self) { Text(Self.charsets[$0].title).tag($0) }
                            }
                        } label: {
                            SettingRow(title: "编码") {
                                RollingText(text: Self.charsets[charset].title)
                            }
                        }
                    }
                    previewCard
                    if mode == 1 {
                        ruleList(selected: selected?.id)
                            .transition(.opacity.combined(with: .offset(y: 12)))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
                .animation(.snappy, value: mode)
            }
            .scrollIndicators(.hidden)
        }
        .environment(\.onGlass, true)
        .qSheet([.fraction(0.72), .large])
        .task(id: PreviewKey(mode: tocMode, charset: Self.charsets[charset].value)) { await refresh() }
        .onChange(of: mode) { _, value in
            if value == 1, ruleID == nil { ruleID = selectedRule?.id }
        }
        .task {
            #if DEBUG
            if let value = DebugLaunch.flag("splitMode").flatMap(Int.init) {
                try? await Task.sleep(for: .milliseconds(1200))
                mode = value
            }
            if DebugLaunch.flag("splitApply") != nil {
                for _ in 0..<40 where !canApply || preview?.pattern.isEmpty == false && mode == 2 {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                try? await Task.sleep(for: .milliseconds(1500))
                apply()
            }
            #endif
        }
    }

    private var canApply: Bool {
        !working && tocMode != nil && preview?.error == nil && preview != nil
    }

    // MARK: 预览

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let preview, preview.error == nil {
                    Text("\(preview.count)")
                        .font(.num(26, .semibold))
                        .foregroundStyle(Tok.gFg)
                        .contentTransition(.numericText())
                    Text("章").font(.ui(14)).foregroundStyle(Tok.gFg2)
                    Spacer(minLength: 8)
                    Text(ruleName(preview))
                        .font(.ui(13))
                        .foregroundStyle(Tok.gFg3)
                        .lineLimit(1)
                } else if let error = preview?.error {
                    Image(icon: "exclamationmark.triangle")
                        .font(.system(size: 14, weight: .semibold))
                    Text(error).font(.ui(14))
                    Spacer(minLength: 0)
                } else {
                    ProgressView().tint(Tok.gFg3)
                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(preview?.error == nil ? Tok.gFg : Tok.gAccent)
            .frame(minHeight: 32)
            if let preview, preview.error == nil {
                Rectangle().fill(Tok.gLine).frame(height: 0.5)
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(preview.titles.enumerated()), id: \.offset) { index, title in
                        HStack(spacing: 12) {
                            Text("\(index + 1)")
                                .font(.num(12))
                                .foregroundStyle(Tok.gFg3)
                                .frame(width: 18, alignment: .trailing)
                            Text(title)
                                .font(.serif(15, bold: false))
                                .foregroundStyle(Tok.gFg2)
                                .lineLimit(1)
                        }
                    }
                    if preview.count > preview.titles.count {
                        Image(icon: "ellipsis")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Tok.gFg3)
                            .padding(.leading, 30)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tok.gFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .animation(.snappy, value: preview)
    }

    private func ruleName(_ preview: SplitPreview) -> String {
        guard !preview.pattern.isEmpty else { return "按长度" }
        return rules.first { $0.rule == preview.pattern }?.name ?? "自定义"
    }

    private func ruleList(selected: Int64?) -> some View {
        CardGroup(separatorInset: 50) {
            ForEach(rules) { rule in
                Button {
                    guard rule.id != selected else { return }
                    UISelectionFeedbackGenerator().selectionChanged()
                    ruleID = rule.id
                } label: {
                    HStack(spacing: 14) {
                        Image(icon: rule.id == selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20))
                            .foregroundStyle(rule.id == selected ? Tok.gAccent : Tok.gFg3)
                            .contentTransition(.symbolEffect(.replace))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(rule.name.isEmpty ? rule.rule : rule.name)
                                .font(.ui(15))
                                .foregroundStyle(Tok.gFg)
                                .lineLimit(1)
                            if let example = rule.example.nilIfEmpty {
                                Text(example)
                                    .font(.ui(12))
                                    .foregroundStyle(Tok.gFg3)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 56)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.row)
            }
        }
    }

    private func refresh() async {
        guard let tocMode else {
            preview = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(160))
        guard !Task.isCancelled else { return }
        let encoding = Self.charsets[charset].value
        let text: String
        if let source, source.charset == encoding {
            text = source.text
        } else {
            let url = app.library.localBooks.fileURL(for: book)
            let decoded = await Task.detached(priority: .userInitiated) { () -> String? in
                guard let url, let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
                return TextEncodingDetector.decode(data, charset: encoding)
            }.value
            guard !Task.isCancelled else { return }
            guard let decoded else {
                preview = SplitPreview(error: LocalBookError.fileMissing.localizedDescription)
                return
            }
            source = DecodedText(charset: encoding, text: decoded)
            text = decoded
        }
        let rules = app.library.txtTocRules.enabledRules
        let splitLong = book.readConfig?.splitLongChapter ?? true
        let result = await Task.detached(priority: .userInitiated) { () -> SplitPreview in
            do {
                let result = try TxtChapterSplitter.split(text, mode: tocMode, rules: rules, splitLongChapter: splitLong)
                return SplitPreview(count: result.chapters.count, titles: result.chapters.prefix(6).map(\.title),
                                    pattern: result.pattern)
            } catch {
                return SplitPreview(error: error.localizedDescription)
            }
        }.value
        guard !Task.isCancelled else { return }
        preview = result
    }

    private func apply() {
        guard canApply, let tocMode else { return }
        working = true
        let encoding = Self.charsets[charset].value
        Task {
            do {
                let updated = try await app.library.resplitLocalBook(book, tocMode: tocMode, charset: encoding)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                app.island.show("list.number", "已分为 \(updated.totalChapterNum) 章")
                dismiss()
                onDone(updated)
            } catch {
                working = false
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                app.island.show("exclamationmark.triangle", error.localizedDescription, danger: true)
            }
        }
    }
}

private struct PreviewKey: Hashable {
    var mode: TxtTocMode?
    var charset: String
}

private struct DecodedText {
    var charset: String
    var text: String
}

private struct SplitPreview: Equatable, Sendable {
    var count = 0
    var titles: [String] = []
    var pattern = ""
    var error: String?
}
