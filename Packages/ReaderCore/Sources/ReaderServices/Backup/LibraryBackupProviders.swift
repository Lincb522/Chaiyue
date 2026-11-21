import Foundation
import ReaderModels

extension LibraryServices {
    /// 内置类别，文件名与 Legado 备份一致，因此也能恢复 Legado 的备份
    func makeBackupService(directory: URL) -> BackupService {
        let service = BackupService(directory: directory)
        let shelf = shelf, sources = sources, replaceRules = replaceRules, txtTocRules = txtTocRules
        let searchHistory = searchHistory, localBooks = localBooks, httpTTS = httpTTS
        typealias File = LibraryBackupFile

        service.register(BackupProvider(.bookshelf, title: "书架", paths: [File.bookshelf, File.groups, File.pinned]) {
            var content = BackupContent(count: shelf.books.count)
            try content.add(File.bookshelf, json: shelf.books)
            try content.add(File.groups, json: shelf.groups)
            try content.add(File.pinned, json: shelf.pinned.sorted())
            return content
        } restore: { files in
            guard let books = try files.decodeList(Book.self, from: File.bookshelf) else { return nil }
            let groups = try files.decodeList(BookGroup.self, from: File.groups) ?? []
            let pinned = try files.decodeList(String.self, from: File.pinned) ?? []
            return BackupRestorePlan {
                // 没有原文件的本地书（换了设备又没备份本地书，或来自 Legado）无法阅读，不恢复
                let kept = books.filter { !$0.isLocal || localBooks.fileURL(for: $0) != nil }
                shelf.restore(books: kept, groups: groups, pinned: pinned)
                return kept.count
            }
        })

        service.register(BackupProvider(.bookmarks, title: "书签", paths: [File.bookmarks]) {
            var content = BackupContent(count: shelf.bookmarks.count)
            try content.add(File.bookmarks, json: shelf.bookmarks)
            return content
        } restore: { files in
            guard let items = try files.decodeList(Bookmark.self, from: File.bookmarks) else { return nil }
            return BackupRestorePlan {
                shelf.restoreBookmarks(items)
                return items.count
            }
        })

        service.register(BackupProvider(.bookSources, title: "书源", paths: [File.bookSources]) {
            var content = BackupContent(count: sources.sources.count)
            content.add(File.bookSources, data: try SourceImport.export(sources.sources, pretty: false))
            return content
        } restore: { files in
            guard let items = try files.decodeList(BookSource.self, from: File.bookSources) else { return nil }
            return BackupRestorePlan {
                sources.replaceAll(items)
                return items.count
            }
        })

        service.register(BackupProvider(.replaceRules, title: "替换规则", paths: [File.replaceRules]) {
            var content = BackupContent(count: replaceRules.rules.count)
            content.add(File.replaceRules, data: try SourceImport.export(replaceRules.rules, pretty: false))
            return content
        } restore: { files in
            guard let items = try files.decodeList(ReplaceRule.self, from: File.replaceRules) else { return nil }
            return BackupRestorePlan {
                replaceRules.replaceAll(items)
                return items.count
            }
        })

        service.register(BackupProvider(.txtTocRules, title: "目录规则", paths: [File.txtTocRules]) {
            var content = BackupContent(count: txtTocRules.rules.filter { !txtTocRules.isBuiltIn($0) }.count)
            try content.add(File.txtTocRules, json: txtTocRules.rules)
            return content
        } restore: { files in
            guard let items = try files.decodeList(TxtTocRule.self, from: File.txtTocRules) else { return nil }
            return BackupRestorePlan {
                txtTocRules.replaceAll(items)
                return txtTocRules.rules.filter { !txtTocRules.isBuiltIn($0) }.count
            }
        })

        service.register(BackupProvider(.httpTTS, title: "朗读源", paths: [File.httpTTS]) {
            var content = BackupContent(count: httpTTS.engines.count)
            content.add(File.httpTTS, data: try SourceImport.export(httpTTS.engines, pretty: false))
            return content
        } restore: { files in
            guard let items = try files.decodeList(HttpTTS.self, from: File.httpTTS) else { return nil }
            return BackupRestorePlan {
                httpTTS.replaceAll(items)
                return httpTTS.engines.count
            }
        })

        service.register(BackupProvider(.searchHistory, title: "搜索历史", paths: [File.searchHistory]) {
            let keywords = searchHistory.keywords
            let items = keywords.enumerated().map { SearchKeyword(word: $1, lastUseTime: Int64(keywords.count - $0)) }
            var content = BackupContent(count: items.count)
            try content.add(File.searchHistory, json: items)
            return content
        } restore: { files in
            guard let data = try files.data(File.searchHistory) else { return nil }
            let keywords = try SearchKeyword.words(from: data)
            return BackupRestorePlan {
                searchHistory.replaceAll(keywords)
                return searchHistory.keywords.count
            }
        })

        service.register(BackupProvider(.localBooks, title: "本地书籍", defaultEnabled: false,
                                        paths: [File.localBooks, File.localBookFiles]) {
            var content = BackupContent()
            var books: [Book] = []
            for book in shelf.books where book.isLocal {
                guard let id = LocalBookStore.id(of: book), let file = localBooks.fileURL(for: book) else { continue }
                let folder = File.localBookFiles + id + "/"
                content.add(folder + file.lastPathComponent, file: file)
                let cover = localBooks.directory(id).appendingPathComponent(LocalBookStore.coverName)
                if FileManager.default.fileExists(atPath: cover.path) {
                    content.add(folder + LocalBookStore.coverName, file: cover)
                }
                books.append(book)
            }
            content.count = books.count
            try content.add(File.localBooks, json: books)
            return content
        } restore: { files in
            guard let books = try files.decodeList(Book.self, from: File.localBooks) else { return nil }
            let candidates = books.compactMap { book in
                LocalBookStore.id(of: book).flatMap { files.url(File.localBookFiles + $0) }.map { (book, $0) }
            }
            let restored = try await offload {
                try candidates.filter { try localBooks.restore($0.0, from: $0.1) }.map(\.0)
            }
            return BackupRestorePlan {
                for book in restored where !shelf.contains(book.bookUrl) {
                    shelf.add(book)
                }
                return restored.count
            }
        })
        return service
    }
}

/// Legado 的搜索历史格式
private struct SearchKeyword: Codable {
    var word: String
    var usage = 1
    var lastUseTime: Int64 = 0

    init(word: String, lastUseTime: Int64) {
        self.word = word
        self.lastUseTime = lastUseTime
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        word = try c.decode(String.self, forKey: .word)
        usage = (try? c.decodeIfPresent(Int.self, forKey: .usage)) ?? 1
        lastUseTime = (try? c.decodeIfPresent(Int64.self, forKey: .lastUseTime)) ?? 0
    }

    /// 也接受纯字符串数组；按最近使用排序
    static func words(from data: Data) throws -> [String] {
        if let words = try? JSONDecoder().decode([String].self, from: data) { return words }
        guard let items = try? JSONDecoder().decode([Failable<SearchKeyword>].self, from: data) else {
            throw BackupError.corruptedFile(LibraryBackupFile.searchHistory)
        }
        return items.compactMap(\.value).enumerated()
            .sorted { ($0.element.lastUseTime, -$0.offset) > ($1.element.lastUseTime, -$1.offset) }
            .map(\.element.word)
    }
}

public extension BackupProvider {
    /// App 设置：备份 `defaults` 中的指定键（属性列表格式）。恢复时备份里没有的键会被移除
    @MainActor
    static func userDefaults(_ category: BackupCategory = .settings, title: String = "设置", fileName: String = "appSettings.plist",
                             keys: [String], defaults: UserDefaults = .standard, defaultEnabled: Bool = true) -> BackupProvider {
        BackupProvider(category, title: title, defaultEnabled: defaultEnabled, paths: [fileName]) {
            var values: [String: Any] = [:]
            for key in keys {
                if let value = defaults.object(forKey: key) { values[key] = value }
            }
            var content = BackupContent(count: values.count)
            content.add(fileName, data: try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0))
            return content
        } restore: { files in
            guard let data = try files.data(fileName) else { return nil }
            guard let values = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
                throw BackupError.corruptedFile(fileName)
            }
            return BackupRestorePlan {
                for key in keys {
                    if let value = values[key] {
                        defaults.set(value, forKey: key)
                    } else {
                        defaults.removeObject(forKey: key)
                    }
                }
                return keys.filter { values[$0] != nil }.count
            }
        }
    }
}
