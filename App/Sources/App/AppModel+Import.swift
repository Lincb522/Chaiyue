import Foundation
import ReaderModels
import ReaderServices
import UniformTypeIdentifiers

extension AppModel {
    /// 书架导入里追加的电子书类型；MOBI、UMD、FB2 等没有系统类型，按扩展名取 Info.plist 中声明的类型
    static let bookImportTypes: [UTType] = {
        let named: [UTType] = [.html, .rtf] + ["public.xhtml", "org.openxmlformats.wordprocessingml.document"].compactMap { UTType($0) }
        let byExtension = ["mobi", "azw", "azw3", "prc", "umd", "fb2", "fbz", "docx", "htm", "xhtml", "md", "markdown"].compactMap {
            UTType(filenameExtension: $0)
        }
        var seen = Set<String>()
        return (named + byExtension).filter { seen.insert($0.identifier).inserted }
    }()

    /// 外部打开：一键导入链接（yuedu://、legado://、qingjian://）、书源 JSON 文件、本地书
    func handleOpenURL(_ url: URL) async {
        if url.isFileURL {
            await importFile(url)
            return
        }
        guard ImportService.sourceURL(fromLink: url) != nil else {
            island.show("exclamationmark.triangle", "无法识别的链接", danger: true)
            return
        }
        await importText(url.absoluteString)
    }

    func importFile(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let ext = LocalBookStore.fileExtension(url.lastPathComponent)
        if ext == ReaderThemeStore.fileExtension {
            do {
                let theme = try ReaderThemeStore.shared.importFile(url)
                settings.use(theme)
                island.show("paintpalette", "已导入并使用「\(theme.name)」")
            } catch {
                island.show("exclamationmark.triangle", "主题包无法读取", danger: true)
            }
            return
        }
        if LocalMediaImporter.handles(ext) {
            await importMedia([url])
            return
        }
        if LocalBookStore.canImport(url) {
            do {
                let book = try await library.importLocalBook(at: url)
                island.show("folder", "已导入《\(book.name)》")
            } catch {
                island.show("exclamationmark.triangle", error.localizedDescription, danger: true)
            }
            return
        }
        importData(at: url)
    }

    /// 只按书源、规则等 JSON 处理，不把 TXT 当作书籍导入（书源管理里的「文件」）
    func importConfigFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        importData(at: url)
    }

    private func importData(at url: URL) {
        do {
            let data = try Data(contentsOf: url)
            apply(try ImportService.classify(data))
        } catch {
            island.show("exclamationmark.triangle", error.localizedDescription, danger: true)
        }
    }

    func importText(_ text: String) async {
        do {
            apply(try await ImportService.classify(text: text))
        } catch {
            island.show("exclamationmark.triangle", error.localizedDescription, danger: true)
        }
    }

    private func apply(_ payload: ImportPayload) {
        guard let summary = library.apply(payload) else {
            island.show("exclamationmark.triangle", "暂不支持导入\(payload.kindName)", danger: true)
            return
        }
        island.show("square.and.arrow.down", "\(payload.kindName) · \(summary.text)")
    }
}
