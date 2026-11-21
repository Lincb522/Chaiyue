import Observation
import ReaderModels
import ReaderPlatform
import ReaderServices
import RuleEngine
import SwiftUI

enum MainTab: Int, CaseIterable, Identifiable {
    case shelf, explore, me

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .shelf: "书架"
        case .explore: "发现"
        case .me: "我的"
        }
    }

    var icon: String {
        switch self {
        case .shelf: "books.vertical"
        case .explore: "safari"
        case .me: "person"
        }
    }
}

struct DetailInput: Hashable {
    var book: Book
    /// 搜索结果里同一本书的其他来源，换源时直接列出
    var alternatives: [SearchBook] = []
    /// 缩放转场的来源封面
    var sourceID: String?
}

enum Route: Hashable {
    case detail(DetailInput)
    case sources
    case replaceRules
    case tocRules
    case cache
    case reading
    case fonts
    /// 自定义阅读主题列表与编辑
    case readerThemes
    case readerThemeEditor(id: String)
    case speech
    case backup
    case about
    case exploreList(sourceUrl: String, url: String, title: String)
    /// 书源 JSON 编辑；`url` 为空时新建
    case sourceEditor(url: String?)
}

/// 打开阅读器的请求。`origin` 为封面在窗口中的位置，用于开书动画
struct ReaderLaunch: Identifiable, Equatable {
    let id = UUID()
    var book: Book
    var origin: CGRect?
    /// 合书时按它取封面的最新位置（书架可能已重新排序）
    var coverKey: String?
}

/// 书源脚本发给界面的一次性信号；`loginData` 为空表示整体刷新
struct SourceSignal: Equatable {
    let id = UUID()
    var sourceKey: String
    var loginData: [String: String]?
}

struct MediaLaunch: Identifiable, Equatable {
    let id = UUID()
    var book: Book
    var kind: BookMediaKind
    /// 打开时封面在屏幕上的位置，播放页从这里展开
    var origin: CGRect?
}

@Observable
final class AppModel {
    let library: LibraryServices
    @ObservationIgnored let sourceUI: PlatformSourceUI
    @ObservationIgnored let presenter = SourcePresenter()
    let island = IslandCenter()
    let appearance = AppearanceStore()
    let settings = ReaderSettings()
    let stats = ReadingStats()
    let speech = SpeechController()
    let voices = VoiceCatalog()
    let localVoice = LocalVoice()
    let voiceStore = LocalVoiceStore()
    let recent = RecentBooks()
    let checker = SourceChecker()

    var path: [Route] = []
    var tab: MainTab = .shelf
    var searching = false
    /// 书架多选时批量操作栏占用标签栏的位置
    var tabBarHidden = false
    /// 欢迎页开始退场时置为 true，主界面随之放大落位
    var launched = false
    var searchText = ""
    var reader: ReaderLaunch?
    /// 听书、漫画、短剧的播放页
    var media: MediaLaunch?
    /// 听书播放器常驻：关掉播放页后继续后台播放，锁屏与灵动岛控制
    @ObservationIgnored private(set) lazy var audio = AudioBookPlayer(app: self)
    /// 正在朗读的书（阅读器关闭后灵动岛显示，点按回到阅读器）
    var speechBook: Book?
    /// 可见封面在窗口中的位置（开书动画的起点），不参与界面刷新
    @ObservationIgnored var coverFrames: [String: CGRect] = [:]
    /// 书源要求刷新登录界面（`java.reLoginView`/`java.upLoginData`）
    var loginSignal: SourceSignal?
    /// 书源要求阅读器重新加载当前章节（`java.refreshContent`）
    var contentSignal: SourceSignal?
    @ObservationIgnored private var openLogins: [String: Int] = [:]

    init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        library = LibraryServices(dataDirectory: support.appendingPathComponent("ReaderData", isDirectory: true),
                                  cacheDirectory: caches.appendingPathComponent("ReaderCache", isDirectory: true))
        sourceUI = PlatformSourceUI(environment: library.environment)
        library.environment.setUIDelegate(sourceUI)
        sourceUI.presenter = presenter
        library.chineseConversion = settings.conversion
        library.preloadCount = settings.preloadCount
        library.autoAddToShelf = settings.autoAddToShelf
        let island = island
        // 灵动岛只显示一行，书源提示常以换行开头
        sourceUI.onToast = { message, long in
            let text = message.withoutEmoji.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !text.isEmpty else { return }
            Task { @MainActor in island.show("info.circle", text, duration: long ? 3.5 : 2.2) }
        }
        library.onSourceEvent = { [weak self] event in self?.handle(event) }
        presenter.island = island
        presenter.resolvePlayback = { [weak self] url, sourceKey in
            guard let self else { return nil }
            var request = (url: url, headers: [String: String]())
            if let source = library.sources.source(for: sourceKey),
               let resolved = try? await library.webBook(for: source).playbackRequest(url) {
                request = resolved
            }
            return URL(string: request.url).map { ($0, request.headers) }
        }
        presenter.loadImage = { [weak self] url, sourceKey in
            guard let self else { return nil }
            let data: Data?
            if let source = library.sources.source(for: sourceKey) {
                data = try? await library.webBook(for: source).fetchImage(url)
            } else if let link = URL(string: url) {
                data = try? await URLSession.shared.data(from: link).0
            } else {
                data = nil
            }
            return data.flatMap(UIImage.init(data:))
        }
        speech.onChapterFinished = { [weak self] in self?.speechChapterFinished?() }
        speech.onOnlineFailure = { [weak self] message in
            self?.island.show("exclamationmark.triangle", "已改用系统语音：\(message)", danger: true)
        }
        library.backup.deviceName = UIDevice.current.name
        library.backup.register(.userDefaults(keys: ReaderSettings.backupKeys + [AppearanceStore.defaultsKey]))
    }

    /// 阅读器在打开期间接管「朗读读完一章」的处理
    @ObservationIgnored var speechChapterFinished: (() -> Void)?

    // MARK: - 导航

    func openDetail(_ book: Book, alternatives: [SearchBook] = [], sourceID: String? = nil) {
        path.append(.detail(DetailInput(book: book, alternatives: alternatives, sourceID: sourceID)))
        if !library.shelf.contains(book.bookUrl), !book.isLocal {
            // 等缩放转场取完来源位置再重排「最近浏览」
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                recent.record(book)
            }
        }
    }

    func push(_ route: Route) {
        path.append(route)
    }

    /// 按内容形态打开：文字书进阅读器，听书、漫画、短剧进各自的播放页
    func openReader(_ book: Book, coverKey: String? = nil) {
        let current = library.shelf.book(book.bookUrl) ?? book
        let origin = coverKey.flatMap { coverFrames[$0] }
        let kind = mediaKind(of: current)
        guard kind != .text else {
            reader = ReaderLaunch(book: current, origin: origin, coverKey: coverKey)
            return
        }
        media = MediaLaunch(book: current, kind: kind, origin: origin)
    }

    func closeReader() {
        reader = nil
    }

    func closeMedia() {
        media = nil
    }

    func mediaKind(of book: Book) -> BookMediaKind {
        book.mediaKind(sourceType: library.source(for: book)?.bookSourceType)
    }

    func reopenSpeechBook() {
        guard let speechBook else { return }
        openReader(speechBook)
    }

    /// 朗读设置里选中的在线朗读源，其次是本地神经语音；都没有时为 nil（用系统语音）
    var onlineSpeech: SpeechController.Online? {
        if let tts = selectedEngine {
            return .http(tts, speechRate: settings.speechRate, loader: library.speech)
        }
        guard usesLocalVoice else { return nil }
        return .local(settings.localVoice, speechRate: settings.speechRate, voice: localVoice)
    }

    /// 朗读中换了声音：立即从当前句改用新声音
    func applyVoiceChange() {
        guard speech.isActive else { return }
        speech.switchVoice(voiceID: settings.speechVoice, online: onlineSpeech)
    }

    /// 当前声音的名称
    var voiceName: String {
        onlineSpeech?.name ?? settings.speechVoice.flatMap { id in voices.voices.first { $0.id == id }?.name } ?? "系统语音"
    }

    /// 选中且启用的在线朗读源
    var selectedEngine: HttpTTS? {
        guard let id = settings.speechEngine, let tts = library.httpTTS.engine(id: id), tts.enabled else { return nil }
        return tts
    }

    var usesLocalVoice: Bool { selectedEngine == nil && settings.localVoice >= 0 && localVoiceReady }

    /// 读语音包状态以便下载完成后界面刷新
    var localVoiceReady: Bool { voiceStore.phase == .ready && LocalVoice.isAvailable }

    func startSearch(_ keyword: String) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchText = trimmed
        searching = true
        library.startSearch(trimmed)
    }

    // MARK: - 书架操作

    func addToShelf(_ book: Book) {
        confirmShelfAdd(book) { [self] replacing in
            if let replacing { library.shelf.replace(replacing, with: book) } else { library.shelf.add(book) }
        }
    }

    /// 书架上已有同名同作者的其它来源时先确认覆盖，`add` 收到被覆盖的书籍地址（没有冲突时为 nil）
    func confirmShelfAdd(_ book: Book, add commit: @escaping (_ replacing: String?) -> Void) {
        let add: (String?) -> Void = { [self] replacing in
            commit(replacing)
            library.callBack(.addBookShelf, book: library.shelf.book(book.bookUrl) ?? book)
        }
        guard let existing = library.shelf.sameBook(as: book) else {
            add(nil)
            island.show("checkmark", "已加入书架")
            return
        }
        let from = existing.isLocal ? "本地" : (existing.originName.isEmpty ? existing.origin : existing.originName)
        let to = book.isLocal ? "本地" : (book.originName.isEmpty ? book.origin : book.originName)
        let alert = UIAlertController(title: "书架上已有《\(existing.name)》",
                                      message: "来源「\(from)」，覆盖为「\(to)」？\n分组、置顶和阅读进度会保留。",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "覆盖", style: .destructive) { [self] _ in
            add(existing.bookUrl)
            island.show("arrow.triangle.2.circlepath", "已覆盖为「\(to)」")
        })
        SourcePresenter.topController()?.present(alert, animated: true)
    }

    func removeFromShelf(_ book: Book) {
        library.removeBooks([book.bookUrl])
        island.show("trash", "已移出书架", danger: true)
    }

    func cacheBook(_ book: Book) {
        let kind = mediaKind(of: book)
        if kind == .audio || kind == .video {
            island.show(kind.symbol, "\(kind.badge ?? "")在线播放，无需缓存")
            return
        }
        if library.downloads.enqueue(book) {
            island.show("arrow.down.circle", "开始缓存《\(book.name)》")
        } else {
            island.show("doc.text", "本地书无需缓存")
        }
    }

    /// 刷新一本书的目录（不受「检查更新」开关限制），提示新增的章数
    func refreshToc(_ book: Book) {
        let before = library.shelf.book(book.bookUrl)?.totalChapterNum ?? book.totalChapterNum
        Task {
            do {
                let result = try await library.contentService(for: book).chapters(for: book, refresh: true)
                library.shelf.mergeMetadata(from: result.book)
                let added = result.chapters.count - before
                island.show("arrow.clockwise", before > 0 && added > 0 ? "新增 \(added) 章" : "目录已刷新")
            } catch {
                island.show("exclamationmark.triangle", error.localizedDescription, danger: true)
            }
        }
    }

    /// 删除该书已缓存的章节，并移除它的缓存任务
    func clearCache(_ book: Book) {
        let store = library.chapterStore
        let url = book.bookUrl
        library.downloads.remove(url)
        Task {
            await Task.detached(priority: .userInitiated) { store.clear(bookUrl: url) }.value
            island.show("trash", "已清除缓存", danger: true)
        }
    }

    // MARK: - 书源事件

    private func handle(_ event: SourceEvent) {
        switch event {
        case .searchBook(let key, _):
            reader = nil
            path = []
            startSearch(key)
        case .open(let name, let url, let title, let sourceKey):
            switch name.lowercased() {
            case "login":
                presentLogin(sourceKey: sourceKey)
            case "search":
                guard let key = [title, url].compactMap({ $0 }).first(where: { !$0.isEmpty }) else { return }
                handle(.searchBook(key: key, sourceKey: sourceKey))
            default:
                guard let url, !url.isEmpty else { return }
                sourceUI.startBrowser(url: url, title: title ?? "", html: nil, sourceKey: sourceKey)
            }
        case .addBook(let bookUrl, let sourceKey):
            addBook(bookUrl, sourceKey: sourceKey)
        case .reLoginView(let sourceKey):
            presentLogin(sourceKey: sourceKey)
        case .upLoginData(let data, let sourceKey):
            loginSignal = SourceSignal(sourceKey: sourceKey, loginData: data)
        case .refreshContent(let sourceKey):
            contentSignal = SourceSignal(sourceKey: sourceKey)
        case .refreshExplore:
            break
        }
    }

    /// 打开书源登录界面；已打开时让它重新生成（JS 生成的 loginUi 随书源状态变化）
    func presentLogin(sourceKey: String) {
        if openLogins[sourceKey, default: 0] > 0 {
            loginSignal = SourceSignal(sourceKey: sourceKey)
            return
        }
        guard let source = library.sources.source(for: sourceKey) else { return }
        presenter.presentSheet(SourceLoginSheet(source: source).environment(self))
    }

    /// 登录界面出现、消失时登记，书源脚本据此决定刷新还是新开
    func loginVisible(_ sourceKey: String, _ visible: Bool) {
        openLogins[sourceKey, default: 0] += visible ? 1 : -1
    }

    /// `java.addBook`：用地址选项里的 origin（没有时用发起的书源）取详情，确认后加入书架
    private func addBook(_ bookUrl: String, sourceKey: String) {
        let origin = Self.urlOption(bookUrl, "origin")
        guard let source = origin.flatMap(library.sources.source(for:)) ?? library.sources.source(for: sourceKey) else {
            island.show("exclamationmark.triangle", "找不到书源", danger: true)
            return
        }
        if let existing = library.shelf.book(bookUrl) {
            island.show("books.vertical", "《\(existing.name.withoutEmoji)》已在书架")
            return
        }
        island.show("hourglass", "正在获取书籍信息")
        Task {
            do {
                var book = Book(bookUrl: bookUrl, origin: source.bookSourceUrl)
                book.originName = source.bookSourceName
                let info = try await library.loadBookInfo(book)
                confirmShelfAdd(info) { [self] replacing in
                    if let replacing { library.shelf.replace(replacing, with: info) } else { library.shelf.add(info) }
                }
            } catch {
                island.show("exclamationmark.triangle", error.localizedDescription, danger: true)
            }
        }
    }

    /// 书籍地址 `url,{json}` 选项里的字符串字段
    private static func urlOption(_ url: String, _ key: String) -> String? {
        guard let range = url.range(of: ",{"),
              let data = String(url[url.index(after: range.lowerBound)...]).data(using: .utf8),
              let options = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = options[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    /// 书籍所属书源开启了自定义按钮
    func customButtonSource(for book: Book) -> BookSource? {
        guard !book.isLocal, let source = library.source(for: book), source.customButton else { return nil }
        return source
    }

    /// 进入后台时写盘
    func flush() {
        library.flush()
        stats.flush()
    }
}

// MARK: - 灵动岛提示

@Observable
final class IslandCenter {
    struct Toast: Equatable, Identifiable {
        let id = UUID()
        var icon: String
        var text: String
        var danger: Bool
    }

    private(set) var current: Toast?
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    func show(_ icon: String, _ text: String, danger: Bool = false, duration: Double = 2.2) {
        let toast = Toast(icon: icon, text: text, danger: danger)
        current = toast
        IslandWindow.raise()
        hideTask?.cancel()
        // 长消息按字数多停留一会儿，最长 6 秒
        let visible = max(duration, min(6, 1.2 + Double(text.count) * 0.08))
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(visible))
            guard !Task.isCancelled, self?.current?.id == toast.id else { return }
            self?.current = nil
        }
    }

    func dismiss() {
        hideTask?.cancel()
        current = nil
    }
}
