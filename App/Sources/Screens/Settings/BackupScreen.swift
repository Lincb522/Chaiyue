import ReaderServices
import Security
import SwiftUI
import UniformTypeIdentifiers

/// 备份与同步：WebDAV 网盘（增量备份、下载恢复）、本地备份文件、备份内容勾选
struct BackupScreen: View {
    @Environment(AppModel.self) private var app
    @State private var config = WebDAVAccount.load()
    @State private var remote: BackupManifest?
    @State private var remoteLoaded = false
    @State private var progress: BackupProgress?
    @State private var busy: BackupTask?
    @State private var editing = false
    @State private var restoring: RestoreItem?
    @State private var picking = false
    @State private var leaving = false

    private var backup: BackupService { app.library.backup }

    var body: some View {
        PageScaffold(title: "备份与同步") {
            cloud
                .padding(.horizontal, 16)

            CardGroup {
                Button {
                    Task { await exportFile() }
                } label: {
                    SettingRow(icon: "square.and.arrow.up", title: "导出备份文件", chevron: false) {
                        if busy == .exporting { ProgressView().controlSize(.small) }
                    }
                }
                .buttonStyle(.row)
                Button {
                    picking = true
                } label: {
                    SettingRow(icon: "square.and.arrow.down", title: "从备份文件恢复", chevron: false)
                }
                .buttonStyle(.row)
            }
            .disabled(busy != nil)
            .padding(.horizontal, 16)
            .padding(.top, 16)

            GroupLabel("备份内容")
            CardGroup(separatorInset: 14) {
                ForEach(backup.categories) { category in
                    ToggleRow(title: backup.provider(for: category)?.title ?? category.rawValue, isOn: Binding {
                        backup.isSelected(category)
                    } set: { on in
                        backup.setSelected(on, for: category)
                    })
                }
            }
            .padding(.horizontal, 16)
        }
        .sheet(isPresented: $editing) {
            WebDAVSheet(initial: config) { saved in
                config = saved
                WebDAVAccount.save(saved)
                remote = nil
                remoteLoaded = false
                Task { await loadRemote() }
            }
        }
        .sheet(item: $restoring) { item in
            RestoreSheet(package: item.package)
        }
        .onChange(of: picking) { _, on in
            guard on else { return }
            picking = false
            FilePicker.present([.zip]) { urls in
                Task { await openFile(urls[0]) }
            }
        }
        .confirmationDialog("断开 WebDAV", isPresented: $leaving, titleVisibility: .visible) {
            Button("断开", role: .destructive) {
                if let config { backup.clearSyncState(for: config) }
                WebDAVAccount.save(nil)
                withAnimation(.soft) {
                    config = nil
                    remote = nil
                }
            }
        } message: {
            Text("网盘上的备份不会删除")
        }
        .task { await loadRemote() }
    }

    // MARK: - 网盘卡片

    private var cloud: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(icon: config == nil ? "icloud.slash" : "icloud")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Tok.fg)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44, height: 44)
                    .background(Tok.tile, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(config?.displayName ?? "WebDAV")
                        .font(.ui(17, .semibold))
                        .foregroundStyle(Tok.fg)
                        .lineLimit(1)
                    if config != nil {
                        Text(remoteText)
                            .font(.num(12))
                            .foregroundStyle(Tok.fg3)
                            .lineLimit(1)
                            .contentTransition(.opacity)
                    }
                }
                Spacer(minLength: 8)
                if config != nil {
                    Menu {
                        Button("编辑", icon: "pencil") { editing = true }
                        Button("下次完整上传", icon: "arrow.triangle.2.circlepath") {
                            if let config { backup.clearSyncState(for: config) }
                        }
                        Divider()
                        Button("断开", icon: "xmark.circle", role: .destructive) { leaving = true }
                    } label: {
                        Image(icon: "ellipsis")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Tok.fg2)
                            .frame(width: 34, height: 34)
                            .background(Tok.fill, in: Circle())
                    }
                }
            }
            if let progress {
                VStack(alignment: .leading, spacing: 8) {
                    Hairline(value: progress.total > 0 ? Double(progress.completed) / Double(progress.total) : 0,
                             track: Tok.fill2, tint: Tok.accent, height: 3)
                        .animation(.out, value: progress.completed)
                    Text(progress.text)
                        .font(.num(12))
                        .foregroundStyle(Tok.fg3)
                        .contentTransition(.numericText())
                }
                .padding(.top, 16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            HStack(spacing: 10) {
                if config == nil {
                    AccentButton(title: "连接", icon: "link", wide: true) { editing = true }
                } else {
                    AccentButton(title: busy == .uploading ? "备份中" : "备份", icon: "icloud.and.arrow.up", wide: true) {
                        Task { await upload() }
                    }
                    .disabled(busy != nil)
                    Button {
                        Task { await download() }
                    } label: {
                        Label(busy == .downloading ? "下载中" : "恢复", icon: "icloud.and.arrow.down")
                            .font(.ui(16, .semibold))
                            .foregroundStyle(Tok.fg)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(Tok.fill, in: Capsule())
                    }
                    .buttonStyle(.press)
                    .disabled(busy != nil || (remoteLoaded && remote == nil))
                    .opacity(remoteLoaded && remote == nil ? 0.45 : 1)
                }
            }
            .padding(.top, 20)
        }
        .padding(20)
        .cardSurface()
        .animation(.soft, value: progress != nil)
        .animation(.soft, value: config)
    }

    private var remoteText: String {
        if !remoteLoaded { return "…" }
        guard let remote else { return "暂无备份" }
        return BookText.join(Formats.relative(remote.date), remote.deviceName)
    }

    // MARK: - 操作

    private func client() -> WebDAVClient? {
        config.map { WebDAVClient(config: $0) }
    }

    private func loadRemote() async {
        guard let client = client() else { return }
        let manifest = try? await backup.remoteManifest(from: client)
        withAnimation(.soft) {
            remote = manifest
            remoteLoaded = true
        }
    }

    private func upload() async {
        guard let client = client() else { return }
        busy = .uploading
        defer {
            busy = nil
            withAnimation(.soft) { progress = nil }
        }
        do {
            let result = try await backup.backup(to: client) { value in progress = value }
            withAnimation(.soft) {
                remote = result.manifest
                remoteLoaded = true
            }
            BackupClock.mark()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            app.island.show("icloud.and.arrow.up", result.uploaded == 0 ? "已是最新" : "已备份 \(result.uploaded) 个文件")
        } catch {
            app.island.show("exclamationmark.icloud", error.localizedDescription, danger: true)
        }
    }

    private func download() async {
        guard let client = client() else { return }
        busy = .downloading
        defer {
            busy = nil
            withAnimation(.soft) { progress = nil }
        }
        do {
            let package = try await backup.download(from: client) { value in progress = value }
            restoring = RestoreItem(package: package)
        } catch {
            app.island.show("exclamationmark.icloud", error.localizedDescription, danger: true)
        }
    }

    private func exportFile() async {
        busy = .exporting
        defer { busy = nil }
        do {
            let url = try await backup.exportArchive(to: FileManager.default.temporaryDirectory,
                                                     fileName: BackupService.archiveFileName(prefix: "柴阅备份"))
            Share.present([url])
        } catch {
            app.island.show("exclamationmark.triangle", error.localizedDescription, danger: true)
        }
    }

    private func openFile(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            restoring = RestoreItem(package: try await backup.openArchive(at: url))
        } catch {
            app.island.show("exclamationmark.triangle", error.localizedDescription, danger: true)
        }
    }
}

private enum BackupTask: Equatable {
    case uploading, downloading, exporting
}

struct RestoreItem: Identifiable {
    let id = UUID()
    let package: BackupPackage
}

// MARK: - 恢复确认

/// 恢复前确认：备份时间、来源设备与各类别条目数，可取消勾选不想覆盖的类别
private struct RestoreSheet: View {
    let package: BackupPackage
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<BackupCategory> = []
    @State private var restoring = false

    private var categories: [BackupCategory] {
        app.library.backup.categories.filter { package.manifest.includes($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "恢复")
            Text(BookText.join(Formats.relative(package.manifest.date), package.manifest.deviceName))
                .font(.num(13))
                .foregroundStyle(Tok.gFg3)
                .padding(.horizontal, 24)
                .padding(.top, -6)
                .padding(.bottom, 14)
            ScrollView {
                CardGroup(separatorInset: 14) {
                    ForEach(categories) { category in
                        SettingRow(title: app.library.backup.provider(for: category)?.title ?? category.rawValue, chevron: false) {
                            HStack(spacing: 12) {
                                if let count = package.manifest.counts[category.rawValue] {
                                    Text("\(count)")
                                }
                                Toggle("", isOn: Binding {
                                    selected.contains(category)
                                } set: { on in
                                    if on { selected.insert(category) } else { selected.remove(category) }
                                })
                                .labelsHidden()
                                .tint(Tok.accent)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            AccentButton(title: restoring ? "恢复中" : "恢复", icon: "arrow.counterclockwise", wide: true) {
                Task { await restore() }
            }
            .disabled(selected.isEmpty || restoring)
            .opacity(selected.isEmpty ? 0.5 : 1)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .environment(\.onGlass, true)
        .qSheet([.medium, .large])
        .onAppear { selected = Set(categories) }
        .onDisappear { package.discard() }
    }

    private func restore() async {
        restoring = true
        defer { restoring = false }
        do {
            let result = try await app.library.backup.restore(package, categories: selected)
            if result.restored[.settings] != nil {
                app.settings.reload()
                app.appearance.reload()
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            app.island.show("arrow.counterclockwise", "已恢复 \(result.totalCount) 项")
            dismiss()
        } catch {
            app.island.show("exclamationmark.triangle", error.localizedDescription, danger: true)
        }
    }
}

// MARK: - WebDAV 账号

/// 填写 WebDAV 地址与账号，连接成功后才保存
private struct WebDAVSheet: View {
    let initial: WebDAVConfig?
    let onSave: (WebDAVConfig) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var directory = WebDAVConfig.defaultDirectory
    @State private var testing = false

    private static let presets = [("坚果云", "https://dav.jianguoyun.com/dav/")]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "WebDAV")
            ScrollView {
                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        ForEach(Self.presets, id: \.0) { preset in
                            Button {
                                withAnimation(.snappy) { url = preset.1 }
                            } label: {
                                Text(preset.0)
                                    .font(.ui(14, url == preset.1 ? .semibold : .regular))
                                    .foregroundStyle(url == preset.1 ? Tok.gFg : Tok.gFg2)
                                    .padding(.horizontal, 14)
                                    .frame(height: 32)
                                    .background(url == preset.1 ? Tok.gFill2 : Tok.gFill, in: Capsule())
                            }
                            .buttonStyle(.press)
                        }
                        Spacer()
                    }
                    field("地址", text: $url, keyboard: .URL)
                    field("账号", text: $username, keyboard: .emailAddress)
                    SecureField("密码", text: $password)
                        .modifier(FieldStyle())
                    field("目录", text: $directory, keyboard: .default)
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
            AccentButton(title: testing ? "连接中" : "连接", icon: nil, wide: true) {
                Task { await connect() }
            }
            .disabled(testing || url.isEmpty)
            .opacity(url.isEmpty ? 0.5 : 1)
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .qSheet([.large])
        .onAppear {
            guard let initial else { return }
            url = initial.url
            username = initial.username
            password = initial.password
            directory = initial.directory
        }
    }

    private func field(_ title: String, text: Binding<String>, keyboard: UIKeyboardType) -> some View {
        TextField(title, text: text)
            .keyboardType(keyboard)
            .modifier(FieldStyle())
    }

    private func connect() async {
        testing = true
        defer { testing = false }
        var config = initial ?? WebDAVConfig(url: "", username: "", password: "")
        config.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        config.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        config.password = password
        let folder = directory.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        config.directory = folder.isEmpty ? WebDAVConfig.defaultDirectory : folder
        do {
            try await WebDAVClient(config: config).testConnection()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onSave(config)
            dismiss()
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            app.island.show("exclamationmark.icloud", error.localizedDescription, danger: true)
        }
    }
}

private struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.ui(16))
            .foregroundStyle(Tok.gFg)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 18)
            .frame(height: 50)
            .background(Tok.gFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// WebDAV 账号存在钥匙串里
enum WebDAVAccount {
    private static let service = "com.linchengbo.chaiyue.webdav"

    static func load() -> WebDAVConfig? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(WebDAVConfig.self, from: data)
    }

    static func save(_ config: WebDAVConfig?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        guard let config, let data = try? JSONEncoder().encode(config) else { return }
        var item = base
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}
