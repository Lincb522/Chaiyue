import Foundation
import ReaderModels
import ReaderServices
import UniformTypeIdentifiers

extension AppModel {
    /// 书架导入里追加的有声书与漫画类型；CBR、OGG 等也列出来，选中后给出明确提示
    static let mediaImportTypes: [UTType] = {
        let named: [UTType] = [.audio, .mp3, .mpeg4Audio, .wav, .aiff, .pdf, .zip]
        let byExtension = ["m4b", "aac", "flac", "caf", "ogg", "opus", "cbz", "cbr"].compactMap {
            UTType(filenameExtension: $0)
        }
        var seen = Set<String>()
        return (named + byExtension).filter { seen.insert($0.identifier).inserted }
    }()

    /// 书架导入：选中的多个音频合成一本有声书（按文件名自然排序，每个文件一章），其余逐个导入
    func importFiles(_ urls: [URL]) async {
        let audio = urls.filter { LocalMediaImporter.audioExtensions.contains($0.pathExtension.lowercased()) }
        guard audio.count > 1 else {
            for url in urls { await importFile(url) }
            return
        }
        await importMedia(audio)
        for url in urls where !audio.contains(url) { await importFile(url) }
    }

    /// 有声书（单个或多个音频、文件夹）或漫画（CBZ/ZIP、PDF）。文件夹来自非副本方式的选择器，复制完成前保持安全作用域
    func importMedia(_ urls: [URL]) async {
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        if urls.count > 1 || urls.contains(where: \.hasDirectoryPath) {
            island.show("headphones", "正在导入有声书…")
        }
        do {
            let book = try await library.importLocalMedia(urls)
            island.show(book.mediaKind().symbol, "已导入《\(book.name)》")
        } catch {
            island.show("exclamationmark.triangle", error.localizedDescription, danger: true)
        }
    }
}
