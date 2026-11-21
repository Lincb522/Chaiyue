import ReaderKit
import SwiftUI

/// 自定义阅读主题：点选即用，长按导出、复制、删除；新建时套用带注释的模板
struct ReaderThemesScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @State private var picking = false
    @State private var removing: CustomReaderTheme?
    @State private var savingKit = false

    private var store: ReaderThemeStore { ReaderThemeStore.shared }

    var body: some View {
        let settings = app.settings
        PageScaffold(title: "阅读主题") {
            CardGroup {
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    settings.customTheme = nil
                } label: {
                    SettingRow(icon: "paintpalette", title: "内置主题", chevron: false) {
                        if settings.customTheme == nil || store.theme(settings.customTheme) == nil { check }
                    }
                }
                .buttonStyle(.row)
            }
            .padding(.horizontal, 16)

            if !store.themes.isEmpty {
                CardGroup(separatorInset: 72) {
                    ForEach(store.themes) { theme in
                        row(theme, selected: settings.customTheme == theme.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            CardGroup {
                Button {
                    let theme = store.create(name: "我的主题", css: ReaderThemeStore.templateCSS, js: ReaderThemeStore.templateJS)
                    app.push(.readerThemeEditor(id: theme.id))
                } label: {
                    SettingRow(icon: "plus", title: "新建原生主题") { Text("CSS 子集") }
                }
                .buttonStyle(.row)
                Button {
                    let theme = store.create(name: "网页主题", css: ReaderThemeStore.webTemplateCSS, js: ReaderThemeStore.webTemplateJS,
                                             mode: .web, html: ReaderThemeStore.webTemplateHTML)
                    app.push(.readerThemeEditor(id: theme.id))
                } label: {
                    SettingRow(icon: "globe", title: "新建网页主题") { Text("HTML + CSS + JS") }
                }
                .buttonStyle(.row)
                Button {
                    picking = true
                } label: {
                    SettingRow(icon: "square.and.arrow.down", title: "导入主题") {
                        Text("主题包 / zip / css / html")
                    }
                }
                .buttonStyle(.row)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            Text("原生主题用样式表（CSS 子集）描述纸面、正文、章头与页眉页脚，翻页动画、朗读高亮、长按选字全都可用。网页主题整页交给 WebKit 渲染，完整的 HTML、CSS、JavaScript 都能用，可以加装饰层、动画和贴纸。字号、字体、行距始终以排版面板为准。主题包是 zip，解压后能在电脑上直接改。脚本都不能联网。")
                .font(.ui(13))
                .foregroundStyle(Tok.fg3)
                .padding(.horizontal, 32)
                .padding(.top, 14)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let kit = Self.devKitURL {
                CardGroup {
                    Button {
                        UISelectionFeedbackGenerator().selectionChanged()
                        savingKit = true
                    } label: {
                        SettingRow(icon: "shippingbox", title: "主题开发包") {
                            Text(ByteCountFormatter.string(fromByteCount: Self.fileSize(kit), countStyle: .file))
                        }
                    }
                    .buttonStyle(.row)
                }
                .padding(.horizontal, 16)
                .padding(.top, 22)

                Text("开发文档、9 套示例主题、电脑端预览和打包工具，外加一份给 AI 用的技能（skill）。把包里的 chaiyue-reader-theme 文件夹放进 Cursor、Claude Code、Codex 等工具的 skills 目录，直接说想要什么风格，AI 就能帮你设计和写主题。")
                    .font(.ui(13))
                    .foregroundStyle(Tok.fg3)
                    .padding(.horizontal, 32)
                    .padding(.top, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .confirmationDialog("主题开发包", isPresented: $savingKit, titleVisibility: .visible) {
            Button("存储到「文件」") { saveKit(share: false) }
            Button("分享 / 隔空投送") { saveKit(share: true) }
        } message: {
            Text("解压后先看 README.md")
        }
        .animation(.soft, value: store.themes)
        .onChange(of: picking) { _, on in
            guard on else { return }
            picking = false
            FilePicker.present(ReaderThemeStore.importTypes, multiple: true) { urls in
                importThemes(urls)
            }
        }
        .confirmationDialog("删除主题", isPresented: Binding { removing != nil } set: { if !$0 { removing = nil } },
                            titleVisibility: .visible, presenting: removing) { theme in
            Button("删除", role: .destructive) {
                if settings.customTheme == theme.id { settings.customTheme = nil }
                store.remove(theme)
            }
        } message: { theme in
            Text("「\(theme.name)」和它的图片会一起删除")
        }
    }

    private var check: some View {
        Image(icon: "checkmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(Tok.accent)
    }

    private func row(_ theme: CustomReaderTheme, selected: Bool) -> some View {
        let spec = store.spec(for: theme, dark: scheme == .dark)
        return HStack(spacing: 14) {
            Button {
                UISelectionFeedbackGenerator().selectionChanged()
                app.settings.use(theme)
            } label: {
                HStack(spacing: 14) {
                    ThemeMark(theme: spec, width: 44, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(theme.name).font(.ui(16)).foregroundStyle(Tok.fg).lineLimit(1)
                        Text(summary(theme)).font(.ui(12)).foregroundStyle(Tok.fg3).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if selected { check }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                app.push(.readerThemeEditor(id: theme.id))
            } label: {
                Image(icon: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Tok.fg2)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.press)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(minHeight: 64)
        .contextMenu {
            Button("编辑", icon: "slider.horizontal.3") { app.push(.readerThemeEditor(id: theme.id)) }
            Button("导出", icon: "square.and.arrow.up") { export(theme) }
            Button("复制", icon: "plus.square.on.square") { store.duplicate(theme) }
            Button("删除", icon: "trash", role: .destructive) { removing = theme }
        }
    }

    private func summary(_ theme: CustomReaderTheme) -> String {
        var parts: [String]
        if theme.mode == .web {
            parts = ["网页渲染"]
        } else {
            parts = [theme.js.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "样式表" : "样式表 + 脚本"]
            let issues = store.sheet(for: theme).diagnostics.count
            if issues > 0 { parts.append("\(issues) 处不支持") }
        }
        parts.append(theme.updated.formatted(.dateTime.month().day().hour().minute()))
        return parts.joined(separator: " · ")
    }

    // MARK: - 开发包

    /// 内置的开发包（docs/theme-dev/tools/build_kit.py 生成）
    private static var devKitURL: URL? {
        Bundle.main.url(forResource: "ChaiyueThemeKit", withExtension: "zip", subdirectory: "ThemeKit")
            ?? Bundle.main.url(forResource: "ChaiyueThemeKit", withExtension: "zip")
    }

    private static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    /// 先拷到临时目录换成中文文件名，再交给「文件」或分享面板
    private func saveKit(share: Bool) {
        guard let source = Self.devKitURL else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("柴阅主题开发包.zip")
        do {
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.copyItem(at: source, to: url)
        } catch {
            app.island.show("exclamationmark.triangle", "开发包读取失败", danger: true)
            return
        }
        if share {
            Share.present([url])
        } else {
            FilePicker.export(url) { _ in app.island.show("checkmark.circle", "已保存开发包") }
        }
    }

    private func export(_ theme: CustomReaderTheme) {
        do {
            Share.file(try store.exportData(theme), name: "\(theme.name).\(ReaderThemeStore.fileExtension)")
        } catch {
            app.island.show("exclamationmark.triangle", "导出失败", danger: true)
        }
    }

    private func importThemes(_ urls: [URL]) {
        var count = 0
        for url in urls {
            if (try? store.importFile(url)) != nil { count += 1 }
        }
        if count > 0 {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            app.island.show("paintpalette", "已导入 \(count) 个主题")
        } else {
            app.island.show("exclamationmark.triangle", "没有可导入的主题", danger: true)
        }
    }
}
