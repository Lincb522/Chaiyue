import SwiftUI

/// 字体：内置三种与导入的字体，点选即用；导入支持 ttf / otf / ttc / otc / woff / woff2 / dfont 与装着它们的 zip
struct FontsScreen: View {
    @Environment(AppModel.self) private var app
    @State private var picking = false
    @State private var importing = false
    @State private var removing: ImportedFont?

    private var store: FontStore { FontStore.shared }

    var body: some View {
        let settings = app.settings
        PageScaffold(title: "字体") {
            CardGroup {
                ForEach(ReaderFontChoice.allCases) { font in
                    row(name: font.name, preview: font.preview(20), selected: settings.importedFont == nil && settings.font == font) {
                        settings.customFont = nil
                        settings.font = font
                    }
                }
            }
            .padding(.horizontal, 16)

            if !store.fonts.isEmpty {
                CardGroup {
                    ForEach(store.fonts) { font in
                        row(name: font.name, preview: .custom(font.id, fixedSize: 20), selected: settings.importedFont == font) {
                            settings.customFont = font.id
                        }
                        .contextMenu {
                            Button("删除", icon: "trash", role: .destructive) { removing = font }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Button {
                picking = true
            } label: {
                HStack(spacing: 8) {
                    if importing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(icon: "plus")
                    }
                    Text("导入字体")
                }
                .font(.ui(16, .medium))
                .foregroundStyle(Tok.fg)
                .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.row)
            .disabled(importing)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
            .cardSurface()
            .padding(.horizontal, 16)
            .padding(.top, 16)
        }
        .animation(.soft, value: store.fonts)
        .onChange(of: picking) { _, on in
            guard on else { return }
            picking = false
            FilePicker.present(FontStore.importTypes, multiple: true) { urls in
                Task { await importFonts(urls) }
            }
        }
        .confirmationDialog("删除字体", isPresented: Binding { removing != nil } set: { if !$0 { removing = nil } },
                            titleVisibility: .visible, presenting: removing) { font in
            Button("删除", role: .destructive) {
                if settings.customFont == font.id { settings.customFont = nil }
                store.remove(font)
            }
        } message: { font in
            let siblings = store.fonts.filter { $0.file == font.file }.count
            Text(siblings > 1 ? "同一文件里的 \(siblings) 个字体会一起删除" : "「\(font.name)」")
        }
    }

    private func row(name: String, preview: Font, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            guard !selected else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.snappy) { action() }
        } label: {
            HStack(spacing: 14) {
                Text("永")
                    .font(preview)
                    .foregroundStyle(Tok.fg)
                    .frame(width: 40, height: 40)
                    .background(Tok.tile, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                Text(name)
                    .font(.ui(16))
                    .foregroundStyle(Tok.fg)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(icon: "checkmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Tok.accentInk)
                    .opacity(selected ? 1 : 0)
                    .scaleEffect(selected ? 1 : 0.5)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.row)
    }

    private func importFonts(_ urls: [URL]) async {
        importing = true
        defer { importing = false }
        do {
            let added = try await store.importFiles(urls)
            if let first = added.first {
                app.settings.customFont = first.id
                app.island.show("textformat", added.count > 1 ? "已导入 \(added.count) 个字体" : "已导入「\(first.name)」")
            } else {
                app.island.show("textformat", "这些字体已经导入过了")
            }
        } catch {
            app.island.show("exclamationmark.triangle", error.localizedDescription, danger: true)
        }
    }
}
